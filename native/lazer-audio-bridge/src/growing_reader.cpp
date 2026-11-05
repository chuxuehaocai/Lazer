/* Growing-file reader bridge for the Lazer native audio engine.
 *
 * The engine pulls audio through `LazerAudioReader` callbacks that run on its own
 * decode thread and must return synchronously (positive byte count, 0 for "not
 * yet", -1 for clean EOF, -2 for a terminal failure). Dart cannot service that:
 * `dart:ffi` callbacks either run on the isolate's own thread (`isolateLocal`,
 * illegal from an engine thread) or are asynchronous (`listener`, no return
 * value). So the blocking byte source lives here, next to the engine, and Dart
 * only appends to the cache file and signals progress.
 *
 * The file is not necessarily a prefix: a seek into a region the linear download
 * has not reached makes the downloader restart its request at that byte offset
 * (`Range:`), which leaves a hole between what the first pass wrote and what the
 * redirected window is writing. [Reader::prefix_end] and [Reader::window_start]
 * describe those two written ranges, and a demand callback tells Dart when the
 * engine needs a byte that is in neither - that is what turns "seek waits for
 * the whole download" into "seek fetches the requested range".
 *
 * Nothing here knows about the engine: it exports plain C functions with exactly
 * the signatures the engine calls, plus the accessors Dart uses to build the
 * reader struct. That keeps this library independent of the engine's headers and
 * of FFmpeg.
 */
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include <chrono>
#include <condition_variable>
#include <mutex>
#include <new>
#include <string>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

#if defined(_WIN32)
#define LAZER_BRIDGE_API extern "C" __declspec(dllexport)
#else
#define LAZER_BRIDGE_API extern "C" __attribute__((visibility("default")))
#endif

/* The downloader's answer to "I need the byte at this offset": `kind` is kDemandRead when the
 * engine's decoder is waiting there, kDemandSeek when a seek landed outside the written ranges.
 * Called on the engine's decode thread, so it must not call back into this reader synchronously. */
typedef void (*LazerBridgeDemandCallback)(void *context, int64_t offset, int32_t kind);

namespace {

/* Reader return values, mirrored from lazer_audio_api.h. */
constexpr int32_t kReaderEof = -1;
constexpr int32_t kReaderIoError = -2;

/* Demand kinds reported to the downloader. */
constexpr int32_t kDemandRead = 0;
constexpr int32_t kDemandSeek = 1;

/* How long a read/seek waits for new bytes before handing control back to the engine. The engine
 * re-issues the call, so this is a latency knob, not a timeout: a slow download simply returns
 * "nothing yet" repeatedly instead of failing. */
constexpr std::chrono::milliseconds kWaitSlice(20);

/* Longest a single call parks the engine's decode thread before answering "nothing yet" (0). The
 * engine's pump loop can then apply a seek that arrived while this call was waiting, which is what
 * makes seeking out of a starved region possible at all: a call that blocks until the download
 * catches up also blocks every seek behind it. */
constexpr std::chrono::milliseconds kCallSlice(150);

/* A cache file that has not produced any bytes for this long is treated as a stalled download so a
 * hung response cannot park the engine's decode thread forever. Dart reports real failures
 * explicitly long before this. */
constexpr std::chrono::seconds kStallDeadline(45);

/* Seeking past the downloaded region waits for the downloader to fetch that byte range. This bounds
 * that wait: a server that ignores `Range` cannot fill the hole, and clamping to what exists is
 * better than parking the decoder until the linear download gets there. */
constexpr std::chrono::seconds kSeekDeadline(12);

/* Repeat a demand only after the downloader has moved past this much, so a decoder waiting in a
 * hole does not post one request per retry. */
constexpr int64_t kDemandRepeatBytes(64 * 1024);

struct Reader {
    std::mutex mutex;
    std::condition_variable changed;

    std::wstring wide_path;
    std::string utf8_path;

    /* Known total byte count of the finished file, or -1 when the server never reported one. */
    int64_t expected_bytes = -1;
    /* Byte count observed when `finish` was signalled; -1 while the file is still growing. */
    int64_t final_bytes = -1;

    int64_t read_position = 0;
    int64_t observed_bytes = 0;
    uint64_t revision = 0;

    /* Written ranges in *track* coordinates, plus where a redirected window lives in the file.
     *
     * The cache file is append-only: `[0, prefix_end)` holds the track's first bytes, and a window
     * the downloader restarted at a seek target is appended after them, holding track bytes
     * `[window_start, window_end)` at file offset `[window_file_start, ...)`. Reading a track offset
     * therefore maps through `fileOffsetOf`, and anything in neither range is a hole the downloader
     * has to fill on demand. `window_end < 0` means "the window is the rest of the file", which is
     * the plain linear download the reader starts with. */
    int64_t prefix_end = 0;
    int64_t window_start = 0;
    int64_t window_end = -1;
    int64_t window_file_start = 0;
    /* False once the server has been seen ignoring `Range`: a hole can then never be filled, so an
     * out-of-range seek clamps instead of waiting for bytes that will not come. */
    bool range_supported = true;

    /* Called (without the lock held) when the engine asks for a byte outside both ranges. */
    LazerBridgeDemandCallback demand = nullptr;
    void *demand_context = nullptr;
    int64_t demanded_offset = -1;
    int32_t demanded_kind = -1;

    bool finished = false;
    bool failed = false;
    bool cancelled = false;
    bool closed = false;

#if defined(_WIN32)
    HANDLE handle = INVALID_HANDLE_VALUE;
#else
    int fd = -1;
#endif
};

#if defined(_WIN32)
bool openFile(Reader &reader) {
    if (reader.handle != INVALID_HANDLE_VALUE) return true;
    /* The downloader holds the same file open for append, so every sharing flag it may have asked
     * for is granted here; a transient sharing violation is retried on the next call instead of
     * failing the stream. */
    HANDLE handle = CreateFileW(
        reader.wide_path.c_str(),
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        nullptr);
    if (handle == INVALID_HANDLE_VALUE) return false;
    reader.handle = handle;
    return true;
}

int64_t fileBytes(Reader &reader) {
    LARGE_INTEGER size{};
    if (reader.handle == INVALID_HANDLE_VALUE) return -1;
    if (!GetFileSizeEx(reader.handle, &size)) return -1;
    return static_cast<int64_t>(size.QuadPart);
}

int64_t readAt(Reader &reader, uint8_t *destination, int64_t offset, int64_t length) {
    LARGE_INTEGER position{};
    position.QuadPart = offset;
    if (!SetFilePointerEx(reader.handle, position, nullptr, FILE_BEGIN)) return -1;
    int64_t total = 0;
    while (total < length) {
        const int64_t remaining = length - total;
        DWORD chunk = static_cast<DWORD>(remaining > (1 << 30) ? (1 << 30) : remaining);
        DWORD read = 0;
        if (!ReadFile(reader.handle, destination + total, chunk, &read, nullptr)) return -1;
        if (read == 0) break;
        total += static_cast<int64_t>(read);
    }
    return total;
}
#else
bool openFile(Reader &reader) {
    if (reader.fd >= 0) return true;
    const int fd = ::open(reader.utf8_path.c_str(), O_RDONLY);
    if (fd < 0) return false;
    reader.fd = fd;
    return true;
}

int64_t fileBytes(Reader &reader) {
    if (reader.fd < 0) return -1;
    struct stat info {};
    if (::fstat(reader.fd, &info) != 0) return -1;
    return static_cast<int64_t>(info.st_size);
}

int64_t readAt(Reader &reader, uint8_t *destination, int64_t offset, int64_t length) {
    int64_t total = 0;
    while (total < length) {
        const ssize_t read = ::pread(reader.fd, destination + total,
                                     static_cast<size_t>(length - total),
                                     static_cast<off_t>(offset + total));
        if (read < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (read == 0) break;
        total += static_cast<int64_t>(read);
    }
    return total;
}

std::wstring utf8ToWide(const char *text) {
    return text == nullptr ? std::wstring() : std::wstring();
}
#endif

#if defined(_WIN32)
std::wstring utf8ToWide(const char *text) {
    if (text == nullptr || text[0] == '\0') return std::wstring();
    const int length = MultiByteToWideChar(CP_UTF8, 0, text, -1, nullptr, 0);
    if (length <= 0) return std::wstring();
    std::wstring wide(static_cast<size_t>(length - 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text, -1, wide.data(), length);
    return wide;
}
#endif

void closeHandle(Reader &reader) {
#if defined(_WIN32)
    if (reader.handle != INVALID_HANDLE_VALUE) {
        CloseHandle(reader.handle);
        reader.handle = INVALID_HANDLE_VALUE;
    }
#else
    if (reader.fd >= 0) {
        ::close(reader.fd);
        reader.fd = -1;
    }
#endif
}

/* Bytes the cache file holds right now: the announced final size once the download finished, so a
 * short final write cannot make the reader loop on data that will never arrive. Returns -1 when the
 * file is not open yet. */
int64_t fileBytesNow(Reader &reader) {
    if (reader.final_bytes >= 0) return reader.final_bytes;
    if (!openFile(reader)) return -1;
    const int64_t size = fileBytes(reader);
    if (size < 0) return -1;
    reader.observed_bytes = size;
    return size;
}

/* Exclusive end of the readable range that contains `position`, or -1 when the position falls in a
 * hole. [file_size] is what the cache file holds right now. */
int64_t readableEnd(const Reader &reader, int64_t position, int64_t file_size) {
    if (position < reader.prefix_end) return reader.prefix_end;
    const int64_t window_end = reader.window_end >= 0 ? reader.window_end : file_size;
    if (position >= reader.window_start && position < window_end) return window_end;
    return -1;
}

/* Where a readable track offset lives in the cache file. */
int64_t fileOffsetOf(const Reader &reader, int64_t position) {
    if (position < reader.prefix_end) return position;
    return reader.window_file_start + (position - reader.window_start);
}

/* The last byte the reader can serve at or before `position`: what an unsatisfiable seek clamps to
 * (the engine treats it as the end of what the source currently holds). */
int64_t clampEnd(const Reader &reader, int64_t position, int64_t file_size) {
    const int64_t window_end = reader.window_end >= 0 ? reader.window_end : file_size;
    if (position < reader.window_start) return reader.prefix_end;
    return window_end;
}

/* The demand to report for this offset, or nullptr when it was already asked for. The caller must
 * release the lock before invoking the returned callback (see `announceDemand`). */
LazerBridgeDemandCallback takeDemand(Reader &reader, int64_t offset, int32_t kind) {
    if (reader.demand == nullptr) return nullptr;
    if (reader.demanded_kind == kind && reader.demanded_offset >= 0 &&
        offset >= reader.demanded_offset && offset - reader.demanded_offset < kDemandRepeatBytes) {
        return nullptr;
    }
    reader.demanded_offset = offset;
    reader.demanded_kind = kind;
    return reader.demand;
}

}  // namespace

/* ----------------------------------------------------------------------------------------------
 * Lifecycle, called from Dart.
 * -------------------------------------------------------------------------------------------- */

LAZER_BRIDGE_API int32_t lazer_bridge_reader_create(
    const char *path_utf8, int64_t expected_bytes, void **out_reader) {
    if (path_utf8 == nullptr || path_utf8[0] == '\0' || out_reader == nullptr) {
        return -1;
    }
    auto *reader = new (std::nothrow) Reader();
    if (reader == nullptr) return -3;
    reader->utf8_path = path_utf8;
    reader->wide_path = utf8ToWide(path_utf8);
    reader->expected_bytes = expected_bytes > 0 ? expected_bytes : -1;
    *out_reader = reader;
    return 0;
}

LAZER_BRIDGE_API void lazer_bridge_reader_notify(void *handle) {
    if (handle == nullptr) return;
    auto *reader = static_cast<Reader *>(handle);
    std::lock_guard<std::mutex> lock(reader->mutex);
    reader->revision += 1;
    reader->changed.notify_all();
}

/* Signals that no further bytes will be appended. `failed` keeps the bytes already on disk readable
 * and then reports a terminal read failure, which is what the engine expects for a broken download;
 * without it the reader ends with a clean EOF. */
LAZER_BRIDGE_API void lazer_bridge_reader_finish(void *handle, int32_t failed) {
    if (handle == nullptr) return;
    auto *reader = static_cast<Reader *>(handle);
    std::lock_guard<std::mutex> lock(reader->mutex);
    reader->finished = true;
    reader->failed = failed != 0;
    const int64_t size = openFile(*reader) ? fileBytes(*reader) : -1;
    reader->final_bytes = size >= 0 ? size : reader->observed_bytes;
    reader->revision += 1;
    reader->changed.notify_all();
}

LAZER_BRIDGE_API void lazer_bridge_reader_destroy(void *handle) {
    if (handle == nullptr) return;
    auto *reader = static_cast<Reader *>(handle);
    {
        std::lock_guard<std::mutex> lock(reader->mutex);
        reader->closed = true;
        reader->revision += 1;
        reader->changed.notify_all();
        closeHandle(*reader);
    }
    delete reader;
}

LAZER_BRIDGE_API int64_t lazer_bridge_reader_bytes_available(void *handle) {
    if (handle == nullptr) return -1;
    auto *reader = static_cast<Reader *>(handle);
    std::lock_guard<std::mutex> lock(reader->mutex);
    const int64_t size = fileBytesNow(*reader);
    if (size < 0) return -1;
    const int64_t window_end = reader->window_end >= 0 ? reader->window_end : size;
    return std::max(reader->prefix_end, window_end);
}

LAZER_BRIDGE_API int64_t lazer_bridge_reader_position(void *handle) {
    if (handle == nullptr) return -1;
    auto *reader = static_cast<Reader *>(handle);
    std::lock_guard<std::mutex> lock(reader->mutex);
    return reader->read_position;
}

/* Tells the reader which byte ranges of the track the cache file currently holds.
 *
 * `prefix_end` is the end of the range written from byte zero. A redirected download appends its
 * bytes after that prefix: the range `[window_start, window_end)` of the track lives at file offset
 * `window_file_start` (`window_end < 0` means it runs to the end of the file, which is the plain
 * linear download). `range_supported` is false once the server has ignored a `Range` request:
 * out-of-range seeks then clamp immediately instead of waiting for bytes that cannot arrive. */
LAZER_BRIDGE_API void lazer_bridge_reader_set_window(
    void *handle, int64_t prefix_end, int64_t window_start, int64_t window_end,
    int64_t window_file_start, int32_t range_supported) {
    if (handle == nullptr) return;
    auto *reader = static_cast<Reader *>(handle);
    std::lock_guard<std::mutex> lock(reader->mutex);
    reader->prefix_end = std::max<int64_t>(0, prefix_end);
    reader->window_start = std::max<int64_t>(0, window_start);
    reader->window_end = window_end;
    reader->window_file_start = std::max<int64_t>(0, window_file_start);
    reader->range_supported = range_supported != 0;
    /* The downloader answered the last demand, so the next one is reported immediately. */
    reader->demanded_offset = -1;
    reader->demanded_kind = -1;
    reader->revision += 1;
    reader->changed.notify_all();
}

/* Installs the downloader callback that fills a byte the engine asked for. */
LAZER_BRIDGE_API void lazer_bridge_reader_set_demand_listener(
    void *handle, LazerBridgeDemandCallback callback, void *context) {
    if (handle == nullptr) return;
    auto *reader = static_cast<Reader *>(handle);
    std::lock_guard<std::mutex> lock(reader->mutex);
    reader->demand = callback;
    reader->demand_context = context;
    reader->demanded_offset = -1;
    reader->demanded_kind = -1;
    reader->changed.notify_all();
}

/* Announces the track's total size once the download learns it.
 *
 * The engine reports this to a demuxer as the source length, and a demuxer is what turns a seek's
 * timestamp into the byte offset this reader is asked for: without a length, seeking a format whose
 * index does not carry byte offsets fails outright. The size usually arrives with the response
 * headers, which is later than the reader's creation, so it is pushed here rather than being a
 * constructor argument only. */
LAZER_BRIDGE_API void lazer_bridge_reader_set_length(void *handle, int64_t expected_bytes) {
    if (handle == nullptr || expected_bytes <= 0) return;
    auto *reader = static_cast<Reader *>(handle);
    std::lock_guard<std::mutex> lock(reader->mutex);
    reader->expected_bytes = expected_bytes;
    reader->revision += 1;
    reader->changed.notify_all();
}

/* ----------------------------------------------------------------------------------------------
 * Engine callbacks. These run on the engine's decode thread and must never throw.
 * -------------------------------------------------------------------------------------------- */

LAZER_BRIDGE_API int32_t lazer_bridge_reader_read(
    void *context, uint8_t *destination, int32_t length) {
    if (context == nullptr) return kReaderIoError;
    auto *reader = static_cast<Reader *>(context);
    if (destination == nullptr || length <= 0) return kReaderIoError;

    const auto started_at = std::chrono::steady_clock::now();
    for (;;) {
        std::unique_lock<std::mutex> lock(reader->mutex);
        if (reader->cancelled || reader->closed) return kReaderIoError;
        if (reader->expected_bytes > 0 && reader->read_position >= reader->expected_bytes) {
            /* Past the announced end there is nothing left, even when the written ranges stop
             * short of it: the tail of a redirected download can leave a gap that a later read
             * fills on demand. */
            return reader->failed ? kReaderIoError : kReaderEof;
        }
        const int64_t size = fileBytesNow(*reader);
        if (size >= 0) {
            const int64_t end = readableEnd(*reader, reader->read_position, size);
            if (end > reader->read_position) {
                const int64_t remaining = end - reader->read_position;
                const int64_t want = remaining < length ? remaining : length;
                const int64_t read = readAt(*reader, destination,
                    fileOffsetOf(*reader, reader->read_position), want);
                if (read < 0) return kReaderIoError;
                if (read > 0) {
                    reader->read_position += read;
                    return static_cast<int32_t>(read);
                }
                /* The file shrank under us (a truncated re-download); report nothing yet and
                 * retry. */
                reader->changed.wait_for(lock, kWaitSlice);
                continue;
            }
            if (end < 0 && !reader->finished && !reader->failed) {
                /* A hole: the downloader has to fetch this offset before the read can be served.
                 * Asking for it is what makes a seek into an undownloaded region work at all. */
                const LazerBridgeDemandCallback notify =
                    takeDemand(*reader, reader->read_position, kDemandRead);
                if (notify != nullptr) {
                    const int64_t position = reader->read_position;
                    void *demand_context = reader->demand_context;
                    lock.unlock();
                    notify(demand_context, position, kDemandRead);
                    lock.lock();
                    continue;
                }
            }
        }
        if (reader->finished) return reader->failed ? kReaderIoError : kReaderEof;
        if (reader->failed) return kReaderIoError;
        if (std::chrono::steady_clock::now() - started_at > kStallDeadline) {
            return kReaderIoError;
        }
        /* Nothing at the read position yet: wait one slice for the downloader, then hand control
         * back with "nothing yet" (0) so the engine can answer a seek that arrived meanwhile
         * instead of waiting here until the download catches up. The engine re-issues the read. */
        reader->changed.wait_for(lock, kWaitSlice);
        if (std::chrono::steady_clock::now() - started_at > kCallSlice) return 0;
    }
}

LAZER_BRIDGE_API int64_t lazer_bridge_reader_seek(void *context, int64_t position_bytes) {
    if (context == nullptr) return -1;
    auto *reader = static_cast<Reader *>(context);
    const int64_t target = position_bytes > 0 ? position_bytes : 0;
    const auto started_at = std::chrono::steady_clock::now();
    for (;;) {
        std::unique_lock<std::mutex> lock(reader->mutex);
        if (reader->cancelled || reader->closed) return -1;
        const int64_t size = fileBytesNow(*reader);
        if (size < 0) {
            if (std::chrono::steady_clock::now() - started_at > kStallDeadline) return -1;
            reader->changed.wait_for(lock, kWaitSlice);
            continue;
        }
        const int64_t end = readableEnd(*reader, target, size);
        /* A target at the end of a written range is a legal "seek to the end": the next read is
         * EOF. Anything past it has to be fetched. The file's own size only ends the track while
         * the window is the plain linear download; once a redirected segment is mapped, the file
         * also holds bytes that belong elsewhere in the track. */
        const bool atEnd = target == reader->prefix_end ||
            (reader->window_end >= 0 ? target == reader->window_end : target == size) ||
            (reader->expected_bytes > 0 && target >= reader->expected_bytes);
        if (end > target || atEnd) {
            reader->read_position = target;
            reader->demanded_offset = -1;
            reader->demanded_kind = -1;
            return target;
        }
        if (reader->finished || reader->failed) {
            const int64_t clamped = std::min(target, clampEnd(*reader, target, size));
            reader->read_position = std::max<int64_t>(0, clamped);
            return reader->read_position;
        }
        if (!reader->range_supported) {
            /* The server ignores `Range`, so the linear download is the only source: land on what
             * it has instead of parking the decoder for a hole that can never be filled. */
            const int64_t clamped = std::min(target, clampEnd(*reader, target, size));
            reader->read_position = std::max<int64_t>(0, clamped);
            return reader->read_position;
        }
        const LazerBridgeDemandCallback notify = takeDemand(*reader, target, kDemandSeek);
        if (notify != nullptr) {
            void *demand_context = reader->demand_context;
            lock.unlock();
            notify(demand_context, target, kDemandSeek);
            lock.lock();
            continue;
        }
        if (std::chrono::steady_clock::now() - started_at > kSeekDeadline) {
            /* The downloader never delivered this offset: clamp to the end of what exists, which
             * the engine treats as the end of the stream. */
            const int64_t clamped = std::min(target, clampEnd(*reader, target, size));
            reader->read_position = std::max<int64_t>(0, clamped);
            return reader->read_position;
        }
        reader->changed.wait_for(lock, kWaitSlice);
    }
}

LAZER_BRIDGE_API int64_t lazer_bridge_reader_length(void *context) {
    if (context == nullptr) return -1;
    auto *reader = static_cast<Reader *>(context);
    std::lock_guard<std::mutex> lock(reader->mutex);
    if (reader->expected_bytes > 0) return reader->expected_bytes;
    if (reader->finished && reader->final_bytes >= 0) return reader->final_bytes;
    return -1;
}

LAZER_BRIDGE_API void lazer_bridge_reader_close(void *context) {
    if (context == nullptr) return;
    auto *reader = static_cast<Reader *>(context);
    std::lock_guard<std::mutex> lock(reader->mutex);
    reader->closed = true;
    reader->revision += 1;
    closeHandle(*reader);
    reader->changed.notify_all();
}

LAZER_BRIDGE_API void lazer_bridge_reader_cancel(void *context) {
    if (context == nullptr) return;
    auto *reader = static_cast<Reader *>(context);
    std::lock_guard<std::mutex> lock(reader->mutex);
    reader->cancelled = true;
    reader->revision += 1;
    closeHandle(*reader);
    reader->changed.notify_all();
}
