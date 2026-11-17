// Runs the real Release FFmpeg/reader/RemoteIO path in a foreground iOS app.
// This checks decoded PCM and the device-driven clock, not physical audibility.
#import <UIKit/UIKit.h>

#include "lazer_audio_api.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

extern "C" {
int32_t lazer_bridge_reader_create(const char *, int64_t, void **);
void lazer_bridge_reader_notify(void *);
void lazer_bridge_reader_finish(void *, int32_t);
void lazer_bridge_reader_destroy(void *);
int32_t lazer_bridge_reader_read(void *, uint8_t *, int32_t);
int64_t lazer_bridge_reader_seek(void *, int64_t);
int64_t lazer_bridge_reader_length(void *);
void lazer_bridge_reader_close(void *);
void lazer_bridge_reader_cancel(void *);
}

namespace {

void require(bool condition, const std::string &message) {
    if (!condition) throw std::runtime_error(message);
}

void logNative(void *, int32_t level, const char *message) {
    std::fprintf(stderr, "native[%d] %s\n", level, message == nullptr ? "" : message);
}

// A deterministic non-silent PCM16 WAV, without an external encoder/download.
std::vector<uint8_t> wavFixture() {
    constexpr uint32_t frames = 44100 * 4;
    constexpr uint32_t dataBytes = frames * 4;
    std::vector<uint8_t> bytes(44 + dataBytes);
    auto put16 = [&bytes](size_t offset, uint16_t value) {
        bytes[offset] = value & 255;
        bytes[offset + 1] = value >> 8;
    };
    auto put32 = [&bytes](size_t offset, uint32_t value) {
        for (int i = 0; i < 4; ++i) bytes[offset + i] = (value >> (i * 8)) & 255;
    };
    std::memcpy(bytes.data(), "RIFF", 4);
    put32(4, dataBytes + 36);
    std::memcpy(bytes.data() + 8, "WAVEfmt ", 8);
    put32(16, 16);
    put16(20, 1);
    put16(22, 2);
    put32(24, 44100);
    put32(28, 44100 * 4);
    put16(32, 4);
    put16(34, 16);
    std::memcpy(bytes.data() + 36, "data", 4);
    put32(40, dataBytes);
    for (uint32_t frame = 0; frame < frames; ++frame) {
        const auto sample = static_cast<int16_t>(
            std::sin(static_cast<double>(frame) * 440.0 * 6.283185307179586 / 44100.0) * 4096);
        put16(44 + frame * 4, static_cast<uint16_t>(sample));
        put16(46 + frame * 4, static_cast<uint16_t>(sample));
    }
    return bytes;
}

struct EngineOwner {
    LazerAudioEngine engine = nullptr;
    EngineOwner() {
        LazerAudioEngineConfig config{};
        config.abi_version = LAZER_AUDIO_ABI_VERSION;
        config.struct_size = sizeof(config);
        config.device.buffer_millis = 120;
        config.log.on_log = &logNative;
        engine = lazer_audio_create(&config);
        require(engine != nullptr, "engine creation failed");
    }
    ~EngineOwner() { lazer_audio_destroy(engine); }
};

std::string failure(LazerAudioEngine engine, const char *stage, int32_t result) {
    const char *detail = lazer_audio_last_error(engine);
    return std::string(stage) + " status=" + std::to_string(result) + ": " +
        (detail == nullptr ? "no native detail" : detail);
}

int64_t provePlayback(LazerAudioEngine engine) {
    LazerAudioStreamInfo info{};
    require(lazer_audio_stream_info(engine, &info) == LazerAudioOk, "stream info failed");
    require(info.source_sample_rate == 44100 && info.source_channels == 2,
        "FFmpeg did not decode the fixture format");
    require(info.output_format_initialized && info.output_sample_rate > 0,
        "RemoteIO did not initialize an output format");
    const int32_t played = lazer_audio_play(engine);
    require(played == LazerAudioOk, failure(engine, "play", played));
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(8);
    while (std::chrono::steady_clock::now() < deadline) {
        LazerAudioSnapshot snapshot{};
        const int32_t status = lazer_audio_snapshot(engine, &snapshot);
        require(status == LazerAudioOk, failure(engine, "snapshot", status));
        require(snapshot.error == LazerAudioOk && snapshot.state != LazerAudioStateFailed,
            failure(engine, "render", snapshot.error));
        if (snapshot.position_millis >= 300) {
            require(lazer_audio_stream_info(engine, &info) == LazerAudioOk,
                "rendered stream info failed");
            require(info.output_telemetry_valid && info.output_peak_millidbfs > -60000,
                "the source produced no non-silent decoded PCM");
            std::fprintf(stderr, "clock=%lld ms codec=%s output=%d Hz peak=%d mdBFS\n",
                static_cast<long long>(snapshot.position_millis), info.codec,
                info.output_sample_rate, info.output_peak_millidbfs);
            return snapshot.position_millis;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    throw std::runtime_error(failure(engine, "RemoteIO clock did not advance", -1));
}

int64_t testFile(NSString *directory, const std::vector<uint8_t> &wav) {
    NSString *path = [directory stringByAppendingPathComponent:@"file.wav"];
    require([[NSData dataWithBytes:wav.data() length:wav.size()] writeToFile:path atomically:YES],
        "could not write file fixture");
    EngineOwner owner;
    LazerAudioOpenParams params{};
    params.struct_size = sizeof(params);
    const int32_t opened = lazer_audio_open_file_utf8(owner.engine, path.UTF8String, &params);
    require(opened == LazerAudioOk, failure(owner.engine, "file open", opened));
    return provePlayback(owner.engine);
}

int64_t testGrowingReader(NSString *directory, const std::vector<uint8_t> &wav) {
    NSString *path = [directory stringByAppendingPathComponent:@"reader.wav"];
    FILE *sink = std::fopen(path.UTF8String, "wb");
    require(sink != nullptr, "could not create growing fixture");
    void *handle = nullptr;
    const int32_t created = lazer_bridge_reader_create(path.UTF8String, wav.size(), &handle);
    if (created != 0 || handle == nullptr) {
        std::fclose(sink);
        throw std::runtime_error("reader bridge creation failed");
    }
    // Real POSIX growing-file reads, including a first read before bytes arrive.
    std::thread feeder([&wav, sink, handle] {
        std::this_thread::sleep_for(std::chrono::milliseconds(180));
        bool failed = false;
        for (size_t offset = 0; offset < wav.size();) {
            const size_t count = std::min<size_t>(8192, wav.size() - offset);
            if (std::fwrite(wav.data() + offset, 1, count, sink) != count ||
                std::fflush(sink) != 0) {
                failed = true;
                break;
            }
            offset += count;
            lazer_bridge_reader_notify(handle);
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
        std::fclose(sink);
        lazer_bridge_reader_finish(handle, failed ? 1 : 0);
    });
    int64_t position = 0;
    try {
        // Destroying the engine must join its readers before the handle is freed.
        EngineOwner owner;
        LazerAudioReader reader{&lazer_bridge_reader_read, &lazer_bridge_reader_seek,
            &lazer_bridge_reader_length, &lazer_bridge_reader_close, handle,
            &lazer_bridge_reader_cancel};
        LazerAudioOpenParams params{};
        params.struct_size = sizeof(params);
        const int32_t opened = lazer_audio_open_reader(owner.engine, &reader, &params);
        require(opened == LazerAudioOk, failure(owner.engine, "growing reader open", opened));
        position = provePlayback(owner.engine);
    } catch (...) {
        feeder.join();
        lazer_bridge_reader_destroy(handle);
        throw;
    }
    feeder.join();
    lazer_bridge_reader_destroy(handle);
    return position;
}

void runSmoke() {
    @autoreleasepool {
        NSString *directory = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
            withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *result;
        try {
            require(lazer_audio_abi_version() == LAZER_AUDIO_ABI_VERSION, "native ABI mismatch");
            const auto wav = wavFixture();
            const auto filePosition = testFile(directory, wav);
            const auto readerPosition = testGrowingReader(directory, wav);
            result = [NSString stringWithFormat:@"PASS file=%lldms reader=%lldms ABI=%u\n",
                static_cast<long long>(filePosition), static_cast<long long>(readerPosition),
                LAZER_AUDIO_ABI_VERSION];
        } catch (const std::exception &error) {
            result = [NSString stringWithFormat:@"FAIL %s\n", error.what()];
        }
        std::fprintf(stderr, "%s", result.UTF8String);
        [result writeToFile:[directory stringByAppendingPathComponent:@"smoke-result.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

} // namespace

@interface AudioSmokeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation AudioSmokeDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}
- (void)applicationDidBecomeActive:(UIApplication *)application {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ runSmoke(); });
    });
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AudioSmokeDelegate class]));
    }
}
