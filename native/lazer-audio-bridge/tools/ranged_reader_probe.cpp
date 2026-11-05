/* Deterministic probe for the ranged growing-file reader.
 *
 * The reader serves two written ranges - the prefix the linear download landed and the window a
 * redirected `Range:` request is filling - and turns anything else into a demand the downloader can
 * answer. These cases pin the contract the engine's decode thread depends on:
 *
 *   - a read in a hole reports "nothing yet" (0) instead of serving zeros, and asks for the byte;
 *   - a read that is merely at the download frontier hands control back within a bounded time, so a
 *     seek behind it is not parked until the download catches up;
 *   - a seek into an unwritten region asks for that offset and completes once the downloader moves
 *     the window there;
 *   - a server that ignores `Range` clamps such a seek immediately instead of waiting;
 *   - a finished download ends with a clean EOF.
 *
 * Build it with `-DLAZER_AUDIO_NATIVE_PROBES=ON` and run `ctest -R lazer-audio-bridge`; the probe
 * needs no FFmpeg, no engine and no audio device.
 */
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

/* The bridge exports plain C entry points; this probe links its translation unit directly. */
extern "C" {
int32_t lazer_bridge_reader_create(const char *path_utf8, int64_t expected_bytes, void **out_reader);
void lazer_bridge_reader_notify(void *handle);
void lazer_bridge_reader_finish(void *handle, int32_t failed);
void lazer_bridge_reader_destroy(void *handle);
int64_t lazer_bridge_reader_bytes_available(void *handle);
void lazer_bridge_reader_set_window(
    void *handle, int64_t prefix_end, int64_t window_start, int64_t window_end,
    int64_t window_file_start, int32_t range_supported);
void lazer_bridge_reader_set_demand_listener(
    void *handle, void (*callback)(void *, int64_t, int32_t), void *context);
void lazer_bridge_reader_set_length(void *handle, int64_t expected_bytes);
int32_t lazer_bridge_reader_read(void *context, uint8_t *destination, int32_t length);
int64_t lazer_bridge_reader_seek(void *context, int64_t position_bytes);
int64_t lazer_bridge_reader_length(void *context);
void lazer_bridge_reader_close(void *context);
void lazer_bridge_reader_cancel(void *context);
}

namespace {

constexpr int32_t kDemandRead = 0;
constexpr int32_t kDemandSeek = 1;
constexpr int64_t kTotalBytes = 100;
constexpr auto kCallSlice = std::chrono::milliseconds(150);

bool expect(bool condition, const char *message) {
    if (condition) return true;
    std::cerr << "FAIL: " << message << '\n';
    return false;
}

/* What the downloader was asked for, and how to answer it. */
struct Demands {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<std::pair<int64_t, int32_t>> seen;

    void record(int64_t offset, int32_t kind) {
        std::lock_guard<std::mutex> lock(mutex);
        seen.emplace_back(offset, kind);
        changed.notify_all();
    }

    bool waitFor(int64_t offset, int32_t kind, std::chrono::milliseconds timeout) {
        std::unique_lock<std::mutex> lock(mutex);
        return changed.wait_for(lock, timeout, [&] {
            return std::find(seen.begin(), seen.end(), std::make_pair(offset, kind)) != seen.end();
        });
    }

    size_t countOf(int32_t kind) {
        std::lock_guard<std::mutex> lock(mutex);
        return static_cast<size_t>(std::count_if(seen.begin(), seen.end(),
            [kind](const std::pair<int64_t, int32_t> &entry) { return entry.second == kind; }));
    }
};

void onDemand(void *context, int64_t offset, int32_t kind) {
    static_cast<Demands *>(context)->record(offset, kind);
}

class TempFile {
public:
    TempFile() {
        const std::filesystem::path directory = std::filesystem::temp_directory_path();
        const std::string name =
            "lazer-ranged-reader-probe-" + std::to_string(std::chrono::steady_clock::now()
                .time_since_epoch().count()) + ".bin";
        path_ = directory / name;
        utf8_ = std::string(reinterpret_cast<const char *>(path_.u8string().c_str()));
    }

    ~TempFile() {
        std::error_code ignored;
        std::filesystem::remove(path_, ignored);
    }

    const std::string &utf8() const { return utf8_; }
    const std::filesystem::path &path() const { return path_; }

    /* Writes the track's own bytes for `[track_start, track_start + length)` at file offset
     * `file_offset`, exactly as the downloader does: the prefix from the file's start, a redirected
     * window appended after it. */
    void write(int64_t file_offset, int64_t track_start, int64_t length) {
        std::fstream file(path_, std::ios::in | std::ios::out | std::ios::binary);
        if (!file.is_open()) {
            file.open(path_, std::ios::out | std::ios::binary);
            file.close();
            file.open(path_, std::ios::in | std::ios::out | std::ios::binary);
        }
        file.seekp(file_offset);
        std::vector<char> bytes(static_cast<size_t>(length));
        for (int64_t index = 0; index < length; index++) {
            bytes[static_cast<size_t>(index)] = pattern(track_start + index);
        }
        file.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
        file.flush();
    }

    int64_t length() {
        std::error_code ignored;
        const uintmax_t size = std::filesystem::file_size(path_, ignored);
        return ignored ? -1 : static_cast<int64_t>(size);
    }

    void truncate(int64_t length) {
        std::error_code ignored;
        std::filesystem::resize_file(path_, static_cast<uintmax_t>(length), ignored);
    }

    static char pattern(int64_t offset) {
        return static_cast<char>((offset % 251) + 1);
    }

private:
    std::filesystem::path path_;
    std::string utf8_;
};

/* Creates the cache file, a reader over it and a demand recorder. */
struct Fixture {
    TempFile file;
    void *reader = nullptr;
    Demands demands;

    Fixture() {
        file.write(0, 0, kTotalBytes);
        file.truncate(40);
        if (lazer_bridge_reader_create(file.utf8().c_str(), kTotalBytes, &reader) != 0 ||
            reader == nullptr) {
            throw std::runtime_error("reader creation failed");
        }
        lazer_bridge_reader_set_demand_listener(reader, &onDemand, &demands);
        lazer_bridge_reader_set_window(reader, 40, 0, -1, 0, 1);
    }

    ~Fixture() {
        if (reader != nullptr) lazer_bridge_reader_destroy(reader);
    }

    int32_t read(std::vector<uint8_t> &buffer) {
        return lazer_bridge_reader_read(reader, buffer.data(), static_cast<int32_t>(buffer.size()));
    }
};

bool testContiguousPrefixAndFrontierYield() {
    Fixture fixture;
    std::vector<uint8_t> buffer(64, 0);
    const int32_t count = fixture.read(buffer);
    if (!expect(count == 40, "a contiguous prefix read returned the wrong byte count")) return false;
    if (!expect(buffer[0] == TempFile::pattern(0) && buffer[39] == TempFile::pattern(39),
            "the prefix read returned the wrong bytes")) {
        return false;
    }
    /* At the frontier: the call must hand control back so a pending seek is answered, and it must
     * have asked the downloader for the byte it is waiting on. */
    const auto started_at = std::chrono::steady_clock::now();
    const int32_t frontier = fixture.read(buffer);
    const auto elapsed = std::chrono::steady_clock::now() - started_at;
    if (!expect(frontier == 0, "a starved read did not report \"nothing yet\"")) return false;
    if (!expect(elapsed >= kCallSlice && elapsed < std::chrono::seconds(3),
            "a starved read returned outside its call slice")) {
        return false;
    }
    if (!expect(fixture.demands.waitFor(40, kDemandRead, std::chrono::seconds(1)),
            "the starved read did not ask for the byte at the frontier")) {
        return false;
    }
    return true;
}

bool testHoleIsNeverServedAsZeros() {
    Fixture fixture;
    /* The downloader redirected to 80: the file holds track [0, 40) and then, appended after it,
     * track [80, 100). Track offsets [40, 80) are a hole a decoder walking forward lands in. */
    fixture.file.write(40, 80, 20);
    lazer_bridge_reader_set_window(fixture.reader, 40, 80, 100, 40, 1);
    std::vector<uint8_t> buffer(64, 0x7f);
    const int32_t prefix = fixture.read(buffer);
    if (!expect(prefix == 40, "the prefix read returned the wrong byte count")) return false;
    const auto started_at = std::chrono::steady_clock::now();
    const int32_t inHole = fixture.read(buffer);
    const auto elapsed = std::chrono::steady_clock::now() - started_at;
    if (!expect(inHole == 0, "a read in a hole served bytes instead of asking for them")) {
        return false;
    }
    if (!expect(elapsed >= kCallSlice && elapsed < std::chrono::seconds(3),
            "the hole read returned outside its call slice")) {
        return false;
    }
    if (!expect(fixture.demands.waitFor(40, kDemandRead, std::chrono::seconds(1)),
            "the hole read did not ask for its own offset")) {
        return false;
    }
    return true;
}

bool testSeekIntoHoleIsFilledOnDemand() {
    Fixture fixture;
    fixture.file.write(40, 80, 20);
    lazer_bridge_reader_set_window(fixture.reader, 40, 80, 100, 40, 1);

    int64_t seekResult = -2;
    std::thread seeker([&] { seekResult = lazer_bridge_reader_seek(fixture.reader, 60); });
    const bool asked = fixture.demands.waitFor(60, kDemandSeek, std::chrono::seconds(2));
    if (!expect(asked, "an out-of-range seek did not ask the downloader for its offset")) {
        /* Unblock the seeker so the probe can still tear down cleanly. */
        lazer_bridge_reader_cancel(fixture.reader);
        seeker.join();
        return false;
    }
    /* Answer the demand the way the downloader does: restart the request at the offset, appending
     * its body to the file and moving the window there. The abandoned segment stays as garbage. */
    const int64_t segment = fixture.file.length();
    fixture.file.write(segment, 60, 40);
    lazer_bridge_reader_set_window(fixture.reader, 40, 60, 100, segment, 1);
    seeker.join();
    if (!expect(seekResult == 60, "the filled seek did not land on its target")) return false;

    std::vector<uint8_t> buffer(8, 0);
    const int32_t count = fixture.read(buffer);
    if (!expect(count == 8, "the read after the filled seek returned the wrong byte count")) {
        return false;
    }
    if (!expect(buffer[0] == TempFile::pattern(60),
            "the read after the filled seek served the wrong bytes")) {
        return false;
    }
    return true;
}

bool testRangeUnsupportedClampsImmediately() {
    Fixture fixture;
    lazer_bridge_reader_set_window(fixture.reader, 40, 0, -1, 0, 0);
    const auto started_at = std::chrono::steady_clock::now();
    const int64_t landed = lazer_bridge_reader_seek(fixture.reader, 90);
    const auto elapsed = std::chrono::steady_clock::now() - started_at;
    if (!expect(landed == 40, "a seek on a server without ranges did not clamp to what exists")) {
        return false;
    }
    if (!expect(elapsed < std::chrono::seconds(1), "the clamped seek waited for bytes")) return false;
    return true;
}

bool testFinishedDownloadEndsCleanly() {
    Fixture fixture;
    fixture.file.truncate(kTotalBytes);
    lazer_bridge_reader_set_window(fixture.reader, kTotalBytes, 0, -1, 0, 1);
    lazer_bridge_reader_finish(fixture.reader, 0);
    std::vector<uint8_t> buffer(64, 0);
    const int32_t first = fixture.read(buffer);
    if (!expect(first == 64, "the tail read returned the wrong byte count")) return false;
    const int32_t second = fixture.read(buffer);
    if (!expect(second == kTotalBytes - 64, "the final read returned the wrong byte count")) {
        return false;
    }
    const int32_t third = fixture.read(buffer);
    if (!expect(third == -1, "the finished download did not end with a clean EOF")) return false;
    if (!expect(lazer_bridge_reader_length(fixture.reader) == kTotalBytes,
            "the announced length changed")) {
        return false;
    }
    /* A failed download keeps its bytes readable and then reports a terminal error. */
    lazer_bridge_reader_finish(fixture.reader, 1);
    if (!expect(fixture.read(buffer) == -2, "a failed download did not report an I/O error")) {
        return false;
    }
    return true;
}

bool testAnnouncedLengthIsAddressable() {
    /* A reader created before the download announced its size reports no length,
     * which is what makes a demuxer unable to turn a seek timestamp into a byte
     * offset; the size is pushed as soon as the headers arrive. */
    TempFile file;
    file.write(0, 0, 40);
    void *reader = nullptr;
    if (lazer_bridge_reader_create(file.utf8().c_str(), -1, &reader) != 0 || reader == nullptr) {
        return expect(false, "reader creation failed");
    }
    bool ok = expect(lazer_bridge_reader_length(reader) == -1,
        "a reader without an announced size reported one");
    lazer_bridge_reader_set_length(reader, kTotalBytes);
    ok = expect(lazer_bridge_reader_length(reader) == kTotalBytes,
            "the announced size was not adopted") && ok;
    lazer_bridge_reader_set_window(reader, 40, 0, -1, 0, 1);
    std::vector<uint8_t> buffer(64, 0x7f);
    ok = expect(lazer_bridge_reader_read(reader, buffer.data(), 64) == 40,
            "the prefix read after announcing the size failed") && ok;
    /* Seeking to the announced end is legal even though the file stops short of it,
     * and the read there is an immediate EOF instead of a wait for bytes that the
     * announced size says cannot exist. */
    const auto started_at = std::chrono::steady_clock::now();
    ok = expect(lazer_bridge_reader_seek(reader, kTotalBytes) == kTotalBytes,
            "a seek to the announced end was refused") && ok;
    ok = expect(lazer_bridge_reader_read(reader, buffer.data(), 64) == -1,
            "a read past the announced size did not report EOF") && ok;
    ok = expect(std::chrono::steady_clock::now() - started_at < std::chrono::seconds(2),
            "the read past the announced size waited for a download") && ok;
    lazer_bridge_reader_destroy(reader);
    return ok;
}

}  // namespace

int main() {
    try {
        if (!testContiguousPrefixAndFrontierYield()) return 1;
        std::cout << "PASS: prefix read and bounded frontier yield\n";
        if (!testHoleIsNeverServedAsZeros()) return 1;
        std::cout << "PASS: a hole is demanded, never served as zeros\n";
        if (!testSeekIntoHoleIsFilledOnDemand()) return 1;
        std::cout << "PASS: seek into an unwritten region completed by its demand\n";
        if (!testRangeUnsupportedClampsImmediately()) return 1;
        std::cout << "PASS: no-range server clamps out-of-range seeks\n";
        if (!testFinishedDownloadEndsCleanly()) return 1;
        std::cout << "PASS: finished download ends with a clean EOF\n";
        if (!testAnnouncedLengthIsAddressable()) return 1;
        std::cout << "PASS: an announced size makes the end of the track addressable\n";
    } catch (const std::exception &error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
    return 0;
}
