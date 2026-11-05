/* Deterministic probe for the growing-file reader's seek policy.
 *
 * The reader serves exactly what the download has written: it never fetches a
 * range of its own, so a caller that must not land somewhere else decides that
 * before asking. These cases pin the contract the engine's decode thread depends
 * on:
 *
 *   - a read of the written prefix returns the bytes and its own length;
 *   - a read with nothing past it hands control back within a bounded slice, so a
 *     seek behind it is not parked until the download catches up;
 *   - the size announced through `set_length` is what makes the end of the track
 *     addressable, even though the file is not that long yet;
 *   - a seek past the written bytes waits for the download and lands when it
 *     arrives, and clamps to what exists once the download can no longer grow;
 *   - a failed download keeps its bytes readable and then reports a terminal
 *     error instead of pretending the track ended.
 *
 * Build it with `-DLAZER_AUDIO_NATIVE_PROBES=ON` and run `ctest -R lazer-audio-bridge`;
 * the probe needs no FFmpeg, no engine and no audio device.
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
#include <stdexcept>
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
void lazer_bridge_reader_set_length(void *handle, int64_t expected_bytes);
int32_t lazer_bridge_reader_read(void *context, uint8_t *destination, int32_t length);
int64_t lazer_bridge_reader_seek(void *context, int64_t position_bytes);
int64_t lazer_bridge_reader_length(void *context);
void lazer_bridge_reader_close(void *context);
void lazer_bridge_reader_cancel(void *context);
}

namespace {

constexpr int64_t kTotalBytes = 100;
constexpr auto kCallSlice = std::chrono::milliseconds(150);

bool expect(bool condition, const char *message) {
    if (condition) return true;
    std::cerr << "FAIL: " << message << '\n';
    return false;
}

class TempFile {
public:
    TempFile() {
        const std::filesystem::path directory = std::filesystem::temp_directory_path();
        const std::string name =
            "lazer-seek-policy-probe-" + std::to_string(std::chrono::steady_clock::now()
                .time_since_epoch().count()) + ".bin";
        path_ = directory / name;
        utf8_ = std::string(reinterpret_cast<const char *>(path_.u8string().c_str()));
    }

    ~TempFile() {
        std::error_code ignored;
        std::filesystem::remove(path_, ignored);
    }

    const std::string &utf8() const { return utf8_; }

    /* Writes the track's own bytes for `[start, start + length)` at file offset `file_offset`,
     * exactly as the downloader does when it appends what it fetched. */
    void write(int64_t file_offset, int64_t start, int64_t length) {
        std::fstream file(path_, std::ios::in | std::ios::out | std::ios::binary);
        if (!file.is_open()) {
            file.open(path_, std::ios::out | std::ios::binary);
            file.close();
            file.open(path_, std::ios::in | std::ios::out | std::ios::binary);
        }
        file.seekp(file_offset);
        std::vector<char> bytes(static_cast<size_t>(length));
        for (int64_t index = 0; index < length; index++) {
            bytes[static_cast<size_t>(index)] = pattern(start + index);
        }
        file.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
        file.flush();
    }

    void truncate(int64_t length) {
        std::error_code ignored;
        std::filesystem::resize_file(path_, static_cast<uintmax_t>(length), ignored);
    }

    int64_t length() {
        std::error_code ignored;
        const uintmax_t size = std::filesystem::file_size(path_, ignored);
        return ignored ? -1 : static_cast<int64_t>(size);
    }

    static char pattern(int64_t offset) {
        return static_cast<char>((offset % 251) + 1);
    }

private:
    std::filesystem::path path_;
    std::string utf8_;
};

/* Creates the cache file, a reader over it and the exported state the engine uses. */
struct Fixture {
    TempFile file;
    void *reader = nullptr;

    Fixture(int64_t writtenBytes = 40, int64_t announcedBytes = kTotalBytes) {
        file.write(0, 0, writtenBytes);
        if (lazer_bridge_reader_create(file.utf8().c_str(), announcedBytes, &reader) != 0 ||
            reader == nullptr) {
            throw std::runtime_error("reader creation failed");
        }
    }

    ~Fixture() {
        if (reader != nullptr) lazer_bridge_reader_destroy(reader);
    }

    int32_t read(std::vector<uint8_t> &buffer) {
        return lazer_bridge_reader_read(reader, buffer.data(), static_cast<int32_t>(buffer.size()));
    }
};

bool testWrittenPrefixAndFrontierYield() {
    Fixture fixture;
    std::vector<uint8_t> buffer(64, 0);
    const int32_t count = fixture.read(buffer);
    if (!expect(count == 40, "a written prefix read returned the wrong byte count")) return false;
    if (!expect(buffer[0] == TempFile::pattern(0) && buffer[39] == TempFile::pattern(39),
            "the prefix read returned the wrong bytes")) {
        return false;
    }
    /* Nothing past the read position: the call must hand control back so a pending seek is
     * answered instead of waiting for the download here. */
    const auto started_at = std::chrono::steady_clock::now();
    const int32_t frontier = fixture.read(buffer);
    const auto elapsed = std::chrono::steady_clock::now() - started_at;
    if (!expect(frontier == 0, "a starved read did not report \"nothing yet\"")) return false;
    if (!expect(elapsed >= kCallSlice && elapsed < std::chrono::seconds(3),
            "a starved read returned outside its call slice")) {
        return false;
    }
    return true;
}

bool testSeekWaitsForTheDownloadAndLands() {
    Fixture fixture;
    const auto started_at = std::chrono::steady_clock::now();
    std::thread downloader([&fixture] {
        std::this_thread::sleep_for(std::chrono::milliseconds(120));
        /* The download reaches the seek target: the reader must land on it. */
        fixture.file.write(40, 40, 60);
        fixture.file.truncate(kTotalBytes);
        lazer_bridge_reader_notify(fixture.reader);
    });
    const int64_t landed = lazer_bridge_reader_seek(fixture.reader, 90);
    downloader.join();
    if (!expect(landed == 90, "a seek past the download did not land once it arrived")) {
        return false;
    }
    if (!expect(std::chrono::steady_clock::now() - started_at >= std::chrono::milliseconds(100),
            "the seek did not wait for the download at all")) {
        return false;
    }
    std::vector<uint8_t> buffer(16, 0);
    const int32_t count = fixture.read(buffer);
    if (!expect(count == 10, "the read after the landed seek returned the wrong byte count")) {
        return false;
    }
    if (!expect(buffer[0] == TempFile::pattern(90), "the landed seek served the wrong bytes")) {
        return false;
    }
    return true;
}

bool testFinishedDownloadClampsAnUnreachableSeek() {
    Fixture fixture;
    /* The download ended well before the announced size: there is nothing left to
     * wait for, so the seek clamps to the end of what exists instead of parking the
     * decoder. */
    lazer_bridge_reader_finish(fixture.reader, 0);
    const auto started_at = std::chrono::steady_clock::now();
    const int64_t landed = lazer_bridge_reader_seek(fixture.reader, 90);
    const auto elapsed = std::chrono::steady_clock::now() - started_at;
    if (!expect(landed == 40, "an unreachable seek did not clamp to what exists")) return false;
    if (!expect(elapsed < std::chrono::seconds(2), "the clamped seek waited for bytes")) return false;
    return true;
}

bool testAnnouncedLengthMakesTheEndAddressable() {
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
    std::vector<uint8_t> buffer(64, 0x7f);
    ok = expect(lazer_bridge_reader_read(reader, buffer.data(), 64) == 40,
            "the prefix read after announcing the size failed") && ok;
    /* Seeking to the announced end is legal, and the read there is an immediate EOF
     * instead of a wait for bytes the announced size says cannot exist. */
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

bool testFailedDownloadKeepsBytesThenFails() {
    Fixture fixture;
    std::vector<uint8_t> buffer(64, 0);
    if (!expect(fixture.read(buffer) == 40, "the prefix read before the failure failed")) {
        return false;
    }
    lazer_bridge_reader_finish(fixture.reader, 1);
    if (!expect(fixture.read(buffer) == -2, "a failed download did not report an I/O error")) {
        return false;
    }
    return true;
}

}  // namespace

int main() {
    try {
        if (!testWrittenPrefixAndFrontierYield()) return 1;
        std::cout << "PASS: written prefix read and bounded frontier yield\n";
        if (!testSeekWaitsForTheDownloadAndLands()) return 1;
        std::cout << "PASS: a seek past the download waits for it and lands\n";
        if (!testFinishedDownloadClampsAnUnreachableSeek()) return 1;
        std::cout << "PASS: an unreachable seek clamps once the download has ended\n";
        if (!testAnnouncedLengthMakesTheEndAddressable()) return 1;
        std::cout << "PASS: an announced size makes the end of the track addressable\n";
        if (!testFailedDownloadKeepsBytesThenFails()) return 1;
        std::cout << "PASS: a failed download keeps its bytes and then reports an I/O error\n";
    } catch (const std::exception &error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
    return 0;
}
