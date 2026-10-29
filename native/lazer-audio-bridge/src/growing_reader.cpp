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

namespace {

/* Reader return values, mirrored from lazer_audio_api.h. */
constexpr int32_t kReaderEof = -1;
constexpr int32_t kReaderIoError = -2;

/* How long a read/seek waits for new bytes before handing control back to the engine. The engine
 * re-issues the call, so this is a latency knob, not a timeout: a slow download simply returns
 * "nothing yet" repeatedly instead of failing. */
constexpr std::chrono::milliseconds kWaitSlice(20);

/* A cache file that has not produced any bytes for this long is treated as a stalled download so a
 * hung response cannot park the engine's decode thread forever. Dart reports real failures
 * explicitly long before this. */
constexpr std::chrono::seconds kStallDeadline(45);

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
int64_t availableBytes(Reader &reader) {
    if (reader.final_bytes >= 0) return reader.final_bytes;
    if (!openFile(reader)) return -1;
    const int64_t size = fileBytes(reader);
    if (size < 0) return -1;
    reader.observed_bytes = size;
    return size;
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
    return availableBytes(*reader);
}

LAZER_BRIDGE_API int64_t lazer_bridge_reader_position(void *handle) {
    if (handle == nullptr) return -1;
    auto *reader = static_cast<Reader *>(handle);
    std::lock_guard<std::mutex> lock(reader->mutex);
    return reader->read_position;
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
        const int64_t available = availableBytes(*reader);
        if (available < 0) {
            /* The cache file is created by the downloader before the engine opens the source, so a
             * missing handle is a transient race: wait for the next notification. */
            if (std::chrono::steady_clock::now() - started_at > kStallDeadline) {
                return kReaderIoError;
            }
            reader->changed.wait_for(lock, kWaitSlice);
            continue;
        }
        if (reader->read_position < available) {
            const int64_t remaining = available - reader->read_position;
            const int64_t want = remaining < length ? remaining : length;
            const int64_t read = readAt(*reader, destination, reader->read_position, want);
            if (read < 0) return kReaderIoError;
            if (read > 0) {
                reader->read_position += read;
                return static_cast<int32_t>(read);
            }
            /* The file shrank under us (a truncated re-download); report nothing yet and retry. */
            reader->changed.wait_for(lock, kWaitSlice);
            continue;
        }
        if (reader->finished) return reader->failed ? kReaderIoError : kReaderEof;
        if (reader->failed) return kReaderIoError;
        if (std::chrono::steady_clock::now() - started_at > kStallDeadline) {
            return kReaderIoError;
        }
        /* Nothing past the read position yet. Block for one wait slice and retry: returning 0
         * ("no bytes right now") is legal too, but waiting keeps the downloader's wake-ups from
         * spinning the engine's decode thread. */
        reader->changed.wait_for(lock, kWaitSlice);
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
        const int64_t available = availableBytes(*reader);
        if (available < 0) {
            if (std::chrono::steady_clock::now() - started_at > kStallDeadline) return -1;
            reader->changed.wait_for(lock, kWaitSlice);
            continue;
        }
        if (target <= available) {
            reader->read_position = target;
            return target;
        }
        /* Seeking past the downloaded region waits for the download instead of clamping, so the
         * demuxer sees a slow file rather than a short one. A finished or failed download clamps to
         * what exists, which the engine treats as the end of the stream. */
        if (reader->finished || reader->failed ||
            std::chrono::steady_clock::now() - started_at > kStallDeadline) {
            reader->read_position = available;
            return available;
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
