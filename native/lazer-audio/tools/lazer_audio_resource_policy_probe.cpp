#include "audio_buffer_policy.h"
#include "beat_grid_capture.h"
#include "decoder_packet_flow.h"
#include "ring_buffer.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <thread>
#include <vector>

namespace {
using namespace lazer::audio;

bool expect(bool condition, const char *message) {
    if (!condition) std::cerr << "FAIL: " << message << '\n';
    return condition;
}

bool decoderBackpressure() {
    int sends = 0;
    int receives = 0;
    int delivered = 0;
    const auto result = pumpDecoderPacket([&] {
        return ++sends == 1 ? DecoderStep::Again : DecoderStep::Ready;
    }, [&] {
        ++receives;
        if ((receives & 1) == 0) return DecoderStep::Again;
        ++delivered;
        return DecoderStep::Ready;
    }, [] { return false; });
    if (!expect(result == DecoderFlowResult::Complete && sends == 2 && delivered == 2,
            "send-side backpressure lost the unaccepted packet or a decoded frame")) return false;
    int stalledSends = 0;
    const auto stalled = pumpDecoderPacket([&] {
        ++stalledSends;
        return DecoderStep::Again;
    }, [] { return DecoderStep::Again; }, [] { return false; });
    if (!expect(stalled == DecoderFlowResult::Stalled && stalledSends == 1,
            "a decoder with no progress spun indefinitely")) return false;
    bool cancelled = false;
    sends = 0;
    const auto cancellation = pumpDecoderPacket([&] {
        ++sends;
        return DecoderStep::Again;
    }, [&] {
        cancelled = true;
        return DecoderStep::Ready;
    }, [&] { return cancelled; });
    if (!expect(cancellation == DecoderFlowResult::Cancelled && sends == 1,
            "cancellation retried an unaccepted packet")) return false;
    const auto failed = pumpDecoderPacket([] { return DecoderStep::Ready; },
        [] { return DecoderStep::Failed; }, [] { return false; });
    return expect(failed == DecoderFlowResult::Failed, "frame delivery error was swallowed");
}

bool bufferBudgets() {
    constexpr int32_t maximum = std::numeric_limits<int32_t>::max();
    for (const int32_t rate : {44'100, 192'000, 384'000, 768'000, maximum}) {
        for (const int32_t frameBytes : {4, 8, 32, 256}) {
            for (const int32_t millis : {-1, 120, 30'000, maximum}) {
                const int32_t frames = outputRingFrames(rate, 960, frameBytes, millis);
                if (!expect(frames >= 2'880, "valid period did not fit the output ring")) return false;
                size_t rounded = 1;
                while (rounded < static_cast<size_t>(frames)) rounded *= 2;
                if (!expect(rounded * frameBytes <= kMaxOutputRingBytes,
                        "rounded output ring exceeded its byte budget")) return false;
                const size_t queued = queuedPcmCapacityFrames(rate, 960, frameBytes, maximum);
                if (!expect(queued * frameBytes <= kMaxQueuedPcmBytes,
                        "queued PCM exceeded its byte budget")) return false;
            }
        }
    }
    return expect(outputRingFrames(768'000, maximum, 32, maximum) == 0 &&
        outputRingFrames(0, 960, 8, 120) == 0 && normalizedBufferMillis(maximum) == 2'000,
        "invalid or overflowing output geometry was accepted");
}

bool boundedBeatCapture() {
    constexpr size_t channels = 8;
    constexpr int32_t blockFrames = 977; /* deliberately crosses analysis reduction groups */
    std::vector<float> block(blockFrames * channels);
    double referenceBpm = 0.0;
    double referencePhase = 0.0;
    for (const int32_t rate : {48'000, 96'000, 192'000, 384'000, 768'000}) {
        lazer_audio::BeatGridCapture capture;
        const int64_t frames = static_cast<int64_t>(rate) * 6;
        for (int64_t start = 0; start < frames; start += blockFrames) {
            const int32_t count = static_cast<int32_t>(std::min<int64_t>(blockFrames, frames - start));
            for (int32_t frame = 0; frame < count; ++frame) {
                const double phase = std::fmod(static_cast<double>(start + frame) / rate, 0.5);
                const float value = phase < 0.12 ? static_cast<float>(
                    0.8 * std::exp(-50.0 * phase) * std::sin(2.0 * 3.141592653589793 * 60.0 * phase)) : 0.0f;
                std::fill_n(block.data() + static_cast<size_t>(frame) * channels, channels, value);
            }
            const auto original = block;
            capture.append(block.data(), count, rate, channels);
            if (!expect(block == original, "tempo analysis modified playback samples")) return false;
        }
        if (!expect(capture.full() && capture.storageBytes() <= 6U * 48'000U * sizeof(float),
                "high-rate multichannel analysis exceeded its fixed memory budget")) return false;
        const auto grid = capture.estimate();
        if (!expect(grid.valid && grid.sampleRate == rate,
                "high-rate beat grid was invalid or used the analysis clock as the output clock")) return false;
        const double phase = static_cast<double>(grid.firstBeatFrame) / rate;
        if (referenceBpm == 0.0) {
            referenceBpm = grid.bpm;
            referencePhase = phase;
        }
        if (!expect(std::abs(grid.bpm - referenceBpm) < 0.5 &&
                std::abs(phase - referencePhase) < 0.015,
                "high-rate tempo or phase changed after bounded analysis reduction")) return false;
        const size_t retained = capture.storageBytes();
        capture.append(block.data(), blockFrames, rate, channels);
        if (!expect(capture.storageBytes() == retained, "completed beat capture continued growing")) return false;
        std::cout << "PASS: " << rate << " Hz / 8 channels beat capture: "
            << retained << " bytes, " << grid.bpm << " BPM\n";
    }
    return true;
}

bool seekFlushOwnership() {
    RingBuffer ring;
    ring.reset(2048, static_cast<int32_t>(sizeof(uint64_t)));
    std::vector<uint64_t> block(2048, 0);
    if (ring.write(reinterpret_cast<const uint8_t *>(block.data()), 2048) != 2048) return false;
    ring.clearForProducer();
    if (!expect(ring.writableFrames() == 0,
            "seek released storage before an in-progress consumer could finish copying")) return false;
    const int32_t discarded = ring.read(reinterpret_cast<uint8_t *>(block.data()), 2048);
    if (!expect(discarded == 0 && ring.readableFrames() == 0 &&
            ring.writableFrames() == 2048, "consumer did not acknowledge the pending seek")) return false;

    std::atomic<bool> finished{false};
    std::atomic<bool> failed{false};
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    std::thread producer([&] {
        std::vector<uint64_t> source(512);
        for (int iteration = 0; iteration < 10'000 && !failed.load(); ++iteration) {
            ring.clearForProducer();
            std::fill(source.begin(), source.end(), ring.flushSequence());
            while (ring.write(reinterpret_cast<const uint8_t *>(source.data()), 512) == 0) {
                if (std::chrono::steady_clock::now() >= deadline || failed.load()) {
                    failed.store(true);
                    break;
                }
                std::this_thread::yield();
            }
        }
        finished.store(true);
    });
    std::vector<uint64_t> destination(512);
    while (!failed.load() && (!finished.load() || ring.readableFrames() > 0)) {
        const uint64_t before = ring.flushSequence();
        const int32_t count = ring.read(reinterpret_cast<uint8_t *>(destination.data()), 512);
        const uint64_t after = ring.flushSequence();
        if (before == after && (after & 1U) == 0) {
            for (int32_t frame = 0; frame < count; ++frame) {
                if (destination[frame] != after) failed.store(true);
            }
        }
        if (ring.readableFrames() < 0 || ring.readableFrames() > ring.capacityFrames() ||
            std::chrono::steady_clock::now() >= deadline) failed.store(true);
        if (count == 0) std::this_thread::yield();
    }
    producer.join();
    return expect(!failed.load(), "concurrent seek/read resurrected stale frames or exceeded capacity");
}
}  // namespace

int main() {
    if (!decoderBackpressure() || !bufferBudgets() || !boundedBeatCapture() || !seekFlushOwnership()) return 1;
    std::cout << "PASS: decoder backpressure, byte budgets and concurrent seek flush ownership\n";
    return 0;
}
