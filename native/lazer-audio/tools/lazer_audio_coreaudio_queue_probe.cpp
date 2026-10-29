#include "coreaudio_pcm_queue.h"
#include "coreaudio_callback_health.h"
#include "coreaudio_drain_policy.h"
#include "coreaudio_dop_carrier.h"

#include <array>
#include <cstdint>
#include <iostream>

using lazer::audio::CoreAudioPcmQueue;
using lazer::audio::coreAudioCallbackHostTimeIsStale;
using lazer::audio::coreAudioCallbackIsStale;
using lazer::audio::coreAudioCallbackStallTimeoutMillis;
using lazer::audio::coreAudioPendingFrames;
using lazer::audio::prepareCoreAudioDoPCarrier;

namespace {

bool expect(bool condition, const char *message) {
    if (!condition) std::cerr << "FAIL: " << message << '\n';
    return condition;
}

}  // namespace

int main() {
    bool ok = true;
    ok &= expect(!coreAudioCallbackIsStale(false, false, 5000, 0, 250),
        "a stopped output is not treated as a lost device");
    ok &= expect(!coreAudioCallbackIsStale(true, false, 249, 0, 250),
        "the first IOProc callback receives its startup grace period");
    ok &= expect(coreAudioCallbackIsStale(true, false, 250, 0, 250),
        "a running IOProc with no callback becomes stale at the timeout");
    ok &= expect(!coreAudioCallbackIsStale(true, false, 449, 200, 250),
        "a newer callback refreshes the health window");
    ok &= expect(coreAudioCallbackIsStale(true, false, 450, 200, 250),
        "a refreshed health window expires at its timeout boundary");
    ok &= expect(!coreAudioCallbackIsStale(true, false, 99, 100, 250),
        "a monotonic clock discontinuity does not underflow the timeout");
    ok &= expect(coreAudioCallbackIsStale(false, true, 100, 100, 250),
        "a confirmed device loss remains terminal until restart");
    ok &= expect(!coreAudioCallbackHostTimeIsStale(true, false, 1249999999, 1000000000,
        1000000000.0, 250), "HAL host-time heartbeat remains healthy before its timeout");
    ok &= expect(coreAudioCallbackHostTimeIsStale(true, false, 1250000000, 1000000000,
        1000000000.0, 250), "HAL host-time heartbeat expires at the timeout boundary");
    ok &= expect(!coreAudioCallbackHostTimeIsStale(false, false, 2000000000, 1000000000,
        1000000000.0, 250), "a stopped output ignores host-time staleness");
    ok &= expect(!coreAudioCallbackHostTimeIsStale(true, false, 999999999, 1000000000,
        1000000000.0, 250), "host-time clock reversal does not underflow");
    ok &= expect(!coreAudioCallbackHostTimeIsStale(true, false, 2000000000, 1000000000,
        0.0, 250), "an unavailable HAL clock frequency is left to the sequence fallback");
    ok &= expect(coreAudioCallbackStallTimeoutMillis(128, 48000) == 250,
        "short HAL periods use the minimum callback timeout");
    ok &= expect(coreAudioCallbackStallTimeoutMillis(12000, 48000) == 1000,
        "long HAL periods clamp the callback timeout to one second");
    ok &= expect(coreAudioCallbackStallTimeoutMillis(1024, 0) == 1000,
        "an unknown sample rate uses the conservative maximum timeout");
    ok &= expect(coreAudioPendingFrames(0, true, false, false, 0, 128) == 128,
        "an empty queue with a callback in flight remains pending");
    ok &= expect(coreAudioPendingFrames(0, false, true, false, 0, 128) == 128,
        "a submitted tail without clock evidence remains pending");
    ok &= expect(coreAudioPendingFrames(0, false, true, true, 48, 128) == 48,
        "a future device deadline remains pending for its remaining frames");
    ok &= expect(coreAudioPendingFrames(0, false, true, true, 0, 128) == 0,
        "a reached deadline drains when no callback is in flight");
    ok &= expect(coreAudioPendingFrames(7, true, false, false, 0, 128) == 7,
        "queued PCM remains pending while a callback is in flight");

    CoreAudioPcmQueue queue;
    ok &= expect(queue.configure(3, 4), "configure a three-frame stereo S16 queue");

    const std::array<uint8_t, 12> first{{
        0x01, 0x02, 0x11, 0x12,
        0x03, 0x04, 0x13, 0x14,
        0x05, 0x06, 0x15, 0x16,
    }};
    ok &= expect(queue.write(first.data(), 4) == 3, "write is bounded by available capacity");
    ok &= expect(queue.queuedFrames() == 3 && queue.writableFrames() == 0,
        "queued and writable frame counts match the ring occupancy");

    std::array<uint8_t, 4> left{};
    std::array<uint8_t, 4> right{};
    std::array<uint8_t *, 2> planar{{left.data(), right.data()}};
    std::array<size_t, 2> planarCapacity{{left.size(), right.size()}};
    ok &= expect(queue.readToBuffers(planar.data(), planarCapacity.data(), 2, false,
        2, 2, true, 2) == 2, "read two frames into planar CoreAudio buffers");
    ok &= expect(left[0] == 0x01 && left[1] == 0x02 && left[2] == 0x03 && left[3] == 0x04,
        "left channel is deinterleaved without changing little-endian samples");
    ok &= expect(right[0] == 0x11 && right[1] == 0x12 && right[2] == 0x13 && right[3] == 0x14,
        "right channel is deinterleaved without changing little-endian samples");

    const std::array<uint8_t, 8> second{{
        0x07, 0x08, 0x17, 0x18,
        0x09, 0x0a, 0x19, 0x1a,
    }};
    ok &= expect(queue.write(second.data(), 2) == 2, "write wraps around the ring boundary");
    std::array<uint8_t, 12> interleaved{};
    std::array<uint8_t *, 1> output{{interleaved.data()}};
    std::array<size_t, 1> outputCapacity{{interleaved.size()}};
    ok &= expect(queue.readToBuffers(output.data(), outputCapacity.data(), 1, true,
        2, 2, true, 3) == 3, "read wrapped frames into an interleaved buffer");
    const std::array<uint8_t, 12> expected{{
        0x05, 0x06, 0x15, 0x16,
        0x07, 0x08, 0x17, 0x18,
        0x09, 0x0a, 0x19, 0x1a,
    }};
    ok &= expect(interleaved == expected, "wrapped reads preserve frame and channel order");

    CoreAudioPcmQueue bigEndianQueue;
    ok &= expect(bigEndianQueue.configure(1, 4), "configure a stereo S16 endian test queue");
    const std::array<uint8_t, 4> littleEndian{{0x34, 0x12, 0xcd, 0xab}};
    ok &= expect(bigEndianQueue.write(littleEndian.data(), 1) == 1,
        "write little-endian source samples");
    std::array<uint8_t, 4> bigEndian{};
    std::array<uint8_t *, 1> bigEndianOutput{{bigEndian.data()}};
    std::array<size_t, 1> bigEndianCapacity{{bigEndian.size()}};
    ok &= expect(bigEndianQueue.readToBuffers(bigEndianOutput.data(), bigEndianCapacity.data(),
        1, true, 2, 2, false, 1) == 1, "convert to the output ASBD byte order");
    const std::array<uint8_t, 4> expectedBigEndian{{0x12, 0x34, 0xab, 0xcd}};
    ok &= expect(bigEndian == expectedBigEndian, "sample bytes are swapped individually");
    ok &= expect(bigEndianQueue.queuedFrames() == 0, "consumed frames leave an empty queue");

    CoreAudioPcmQueue dopQueue;
    ok &= expect(dopQueue.configure(4, 6), "configure an interleaved stereo DoP queue");
    const std::array<uint8_t, 18> dopSource{{
        0x10, 0x11, 0x99, 0x20, 0x21, 0x99,
        0x12, 0x13, 0x99, 0x22, 0x23, 0x99,
        0x14, 0x15, 0x99, 0x24, 0x25, 0x99,
    }};
    ok &= expect(dopQueue.write(dopSource.data(), 2) == 2,
        "enqueue packed DoP words with arbitrary input markers");
    uint8_t nextDoPMarker = 0x05;
    std::array<uint8_t, 18> dopCallback{};
    const int32_t dopCopied = dopQueue.readInterleavedBytes(dopCallback.data(),
        dopCallback.size(), 3);
    ok &= expect(dopCopied == 2, "DoP queue reads complete frames without sample conversion");
    ok &= expect(prepareCoreAudioDoPCarrier(dopCallback.data(), 3,
        static_cast<size_t>(dopCopied), 2, nextDoPMarker),
        "format a callback with payload and idle frames");
    const std::array<uint8_t, 18> expectedDopCallback{{
        0x10, 0x11, 0x05, 0x20, 0x21, 0x05,
        0x12, 0x13, 0xFA, 0x22, 0x23, 0xFA,
        0x69, 0x69, 0x05, 0x69, 0x69, 0x05,
    }};
    ok &= expect(dopCallback == expectedDopCallback,
        "DoP callback preserves payload bytes, synchronizes markers and emits valid idle");
    ok &= expect(nextDoPMarker == 0xFA,
        "the callback-owned marker clock advances across both payload and idle frames");

    const std::array<uint8_t, 6> recoveredDopSource{{
        0x30, 0x31, 0x00, 0x40, 0x41, 0x00,
    }};
    ok &= expect(dopQueue.write(recoveredDopSource.data(), 1) == 1,
        "enqueue data after callback starvation");
    std::array<uint8_t, 12> recoveredDop{};
    const int32_t recoveredCopied = dopQueue.readInterleavedBytes(recoveredDop.data(),
        recoveredDop.size(), 2);
    ok &= expect(recoveredCopied == 1, "recovered callback reads the newly queued payload");
    ok &= expect(prepareCoreAudioDoPCarrier(recoveredDop.data(), 2,
        static_cast<size_t>(recoveredCopied), 2, nextDoPMarker),
        "format data recovery after an idle callback frame");
    const std::array<uint8_t, 12> expectedRecoveredDop{{
        0x30, 0x31, 0xFA, 0x40, 0x41, 0xFA,
        0x69, 0x69, 0x05, 0x69, 0x69, 0x05,
    }};
    ok &= expect(recoveredDop == expectedRecoveredDop && nextDoPMarker == 0xFA,
        "marker phase remains alternating and channel-synchronized after starvation");

    std::array<uint8_t, 12> emptyDop{};
    ok &= expect(dopQueue.readInterleavedBytes(emptyDop.data(), emptyDop.size(), 2) == 0,
        "an empty DoP queue reports starvation without consuming frames");
    ok &= expect(prepareCoreAudioDoPCarrier(emptyDop.data(), 2, 0, 2, nextDoPMarker),
        "format a completely empty DoP callback as idle");
    const std::array<uint8_t, 12> expectedEmptyDop{{
        0x69, 0x69, 0xFA, 0x69, 0x69, 0xFA,
        0x69, 0x69, 0x05, 0x69, 0x69, 0x05,
    }};
    ok &= expect(emptyDop == expectedEmptyDop && nextDoPMarker == 0xFA,
        "empty callbacks produce a valid 0x69 DoP idle stream with continuous markers");

    if (!ok) return 1;
    std::cout << "CoreAudio PCM SPSC queue probe passed\n";
    return 0;
}
