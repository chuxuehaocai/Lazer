/* Deterministic unit probe for the bounded decoded-PCM queue used by gapless predecode. */
#include "queued_pcm_buffer.h"

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

using lazer::audio::QueuedPcmBuffer;

constexpr size_t kFrameBytes = 2;
constexpr auto kWaitTimeout = std::chrono::seconds(2);

std::vector<uint8_t> makeFrames(uint16_t first, size_t count) {
    std::vector<uint8_t> bytes;
    bytes.reserve(count * kFrameBytes);
    for (size_t frame = 0; frame < count; ++frame) {
        const uint16_t value = static_cast<uint16_t>(first + frame);
        bytes.push_back(static_cast<uint8_t>(value & 0xff));
        bytes.push_back(static_cast<uint8_t>((value >> 8) & 0xff));
    }
    return bytes;
}

bool expect(bool condition, const char *message) {
    if (condition) return true;
    std::cerr << "FAIL: " << message << '\n';
    return false;
}

bool testWrapAndPartialConsumption() {
    QueuedPcmBuffer buffer(5, 2, kFrameBytes);
    const auto first = makeFrames(0x1000, 4);
    const auto wrapped = makeFrames(0x1004, 4);
    if (!expect(buffer.accept(first.data(), 4) == 4, "initial PCM write was not fully accepted")) return false;

    buffer.consumeFrames(3);
    if (!expect(buffer.queuedFrames() == 1, "partial consume did not leave one frame")) return false;
    if (!expect(buffer.accept(wrapped.data(), 4) == 4, "wrapped PCM write was not fully accepted")) return false;
    if (!expect(buffer.queuedFrames() == 5, "wrapped queue count is incorrect")) return false;

    std::vector<uint8_t> peeked(5 * kFrameBytes);
    if (!expect(buffer.peekFrames(peeked.data(), 5) == 5, "peek did not return all wrapped frames")) return false;
    if (!expect(peeked == makeFrames(0x1003, 5), "wrapped PCM order or bytes changed")) return false;

    std::vector<uint8_t> partial(2 * kFrameBytes);
    if (!expect(buffer.peekFrames(partial.data(), 2) == 2, "partial peek returned the wrong count")) return false;
    if (!expect(partial == makeFrames(0x1003, 2), "partial peek returned the wrong prefix")) return false;
    buffer.consumeFrames(2);
    if (!expect(buffer.peekFrames(peeked.data(), 5) == 3, "partial consume did not expose the remaining frames")) return false;
    if (!expect(std::vector<uint8_t>(peeked.begin(), peeked.begin() + 3 * kFrameBytes) ==
        makeFrames(0x1005, 3), "partial consume advanced to the wrong frame")) return false;
    return true;
}

bool testCapacityBackpressure() {
    QueuedPcmBuffer buffer(4, 2, kFrameBytes);
    const auto first = makeFrames(0x2000, 3);
    const auto rest = makeFrames(0x2003, 3);
    if (!expect(buffer.accept(first.data(), 3) == 3, "first capacity write was not accepted")) return false;
    if (!expect(buffer.accept(rest.data(), 3) == 1, "accept did not stop at available capacity")) return false;
    if (!expect(buffer.queuedFrames() == 4, "queue exceeded or missed its capacity")) return false;
    if (!expect(!buffer.shouldPump(), "full queue did not apply producer backpressure")) return false;
    if (!expect(buffer.accept(rest.data() + kFrameBytes, 1) == 0, "full queue accepted excess PCM")) return false;

    buffer.consumeFrames(2);
    if (!expect(buffer.shouldPump(), "queue did not resume producer after consumption")) return false;
    if (!expect(buffer.accept(rest.data() + kFrameBytes, 2) == 2, "producer did not refill released capacity")) return false;

    std::vector<uint8_t> output(4 * kFrameBytes);
    if (!expect(buffer.peekFrames(output.data(), 4) == 4, "backpressure queue returned the wrong frame count")) return false;
    if (!expect(output == makeFrames(0x2002, 4), "backpressure changed PCM order")) return false;
    return true;
}

struct WaitState {
    std::mutex mutex;
    std::condition_variable changed;
    int started = 0;
    int completed = 0;
    bool readyResult = false;
    bool dataWaitSawCancel = false;
};

void markStarted(WaitState &state) {
    {
        std::lock_guard guard(state.mutex);
        ++state.started;
    }
    state.changed.notify_all();
}

bool testWatermarkAndShortEof() {
    QueuedPcmBuffer buffer(8, 4, kFrameBytes);
    WaitState state;
    std::thread waiter([&] {
        markStarted(state);
        const bool ready = buffer.waitUntilReady();
        {
            std::lock_guard guard(state.mutex);
            state.readyResult = ready;
            ++state.completed;
        }
        state.changed.notify_all();
    });

    {
        std::unique_lock guard(state.mutex);
        if (!state.changed.wait_for(guard, kWaitTimeout, [&] { return state.started == 1; })) {
            buffer.cancel();
            guard.unlock();
            waiter.join();
            return expect(false, "readiness waiter did not start");
        }
    }
    const auto belowWatermark = makeFrames(0x3000, 3);
    if (buffer.accept(belowWatermark.data(), 3) != 3) {
        buffer.cancel();
        waiter.join();
        return expect(false, "PCM below readiness watermark was not accepted");
    }
    bool returnedBelowWatermark = false;
    {
        std::unique_lock guard(state.mutex);
        returnedBelowWatermark = state.changed.wait_for(guard, std::chrono::milliseconds(75), [&] {
            return state.completed == 1;
        });
    }
    if (returnedBelowWatermark) {
        buffer.cancel();
        waiter.join();
        return expect(false, "readiness completed below its configured PCM watermark");
    }
    const auto finalFrame = makeFrames(0x3003, 1);
    if (buffer.accept(finalFrame.data(), 1) != 1) {
        buffer.cancel();
        waiter.join();
        return expect(false, "PCM at readiness watermark was not accepted");
    }
    bool completed = false;
    bool ready = false;
    {
        std::unique_lock guard(state.mutex);
        completed = state.changed.wait_for(guard, kWaitTimeout, [&] { return state.completed == 1; });
        ready = state.readyResult;
    }
    waiter.join();
    if (!expect(completed && ready, "readiness waiter did not complete at the watermark")) return false;

    QueuedPcmBuffer shortTrack(8, 5, kFrameBytes);
    const auto shortPcm = makeFrames(0x3100, 3);
    if (!expect(shortTrack.accept(shortPcm.data(), 3) == 3, "short-track PCM was not accepted")) return false;
    shortTrack.finish(LazerAudioOk, "", true);
    if (!expect(shortTrack.waitUntilReady(), "short EOS track did not become usable below the watermark")) return false;
    if (!expect(shortTrack.reachedEof() && shortTrack.finished(), "short EOS state was not retained")) return false;
    if (!expect(shortTrack.queuedFrames() == 3, "short EOS discarded its decoded PCM")) return false;

    QueuedPcmBuffer emptyTrack(8, 5, kFrameBytes);
    emptyTrack.finish(LazerAudioOk, "", true);
    if (!expect(!emptyTrack.waitUntilReady(), "empty EOS was incorrectly reported ready")) return false;
    return true;
}

bool testErrorIsRetainedWithBufferedPcm() {
    QueuedPcmBuffer buffer(6, 4, kFrameBytes);
    const auto pcm = makeFrames(0x4000, 3);
    if (!expect(buffer.accept(pcm.data(), 3) == 3, "PCM before decoder error was not accepted")) return false;
    buffer.finish(LazerAudioErrorSource, "queued reader failed", false);
    if (!expect(buffer.finished(), "reader error did not finish the queue")) return false;
    if (!expect(buffer.result() == LazerAudioErrorSource, "reader error code was lost")) return false;
    if (!expect(buffer.error() == "queued reader failed", "reader error text was lost")) return false;
    if (!expect(!buffer.reachedEof(), "reader error was mislabeled as clean EOF")) return false;
    if (!expect(buffer.queuedFrames() == 3, "finishing with an error discarded buffered PCM")) return false;
    if (!expect(buffer.waitUntilReady(), "buffered PCM was unavailable after early terminal error")) return false;
    if (!expect(!buffer.shouldPump(), "terminal reader error left the producer active")) return false;
    if (!expect(buffer.accept(pcm.data(), 1) == 0, "terminal reader error accepted more PCM")) return false;

    std::vector<uint8_t> output(3 * kFrameBytes);
    if (!expect(buffer.peekFrames(output.data(), 3) == 3, "buffered PCM could not be read after error")) return false;
    if (!expect(output == pcm, "buffered PCM changed while error was retained")) return false;

    buffer.finish(LazerAudioOk, "", true);
    if (!expect(buffer.result() == LazerAudioErrorSource && buffer.error() == "queued reader failed" &&
        !buffer.reachedEof(), "later finish overwrote the original terminal error")) return false;
    return true;
}

bool testCancelWakesBlockedWaiters() {
    QueuedPcmBuffer buffer(8, 4, kFrameBytes);
    WaitState state;
    std::thread readyWaiter([&] {
        markStarted(state);
        const bool ready = buffer.waitUntilReady();
        {
            std::lock_guard guard(state.mutex);
            state.readyResult = ready;
            ++state.completed;
        }
        state.changed.notify_all();
    });
    std::thread dataWaiter([&] {
        markStarted(state);
        buffer.waitForDataOrFinish();
        {
            std::lock_guard guard(state.mutex);
            state.dataWaitSawCancel = buffer.cancelled();
            ++state.completed;
        }
        state.changed.notify_all();
    });

    bool bothStarted = false;
    {
        std::unique_lock guard(state.mutex);
        bothStarted = state.changed.wait_for(guard, kWaitTimeout, [&] { return state.started == 2; });
    }
    buffer.cancel();

    bool bothCompleted = false;
    bool readyResult = true;
    bool dataSawCancel = false;
    {
        std::unique_lock guard(state.mutex);
        bothCompleted = state.changed.wait_for(guard, kWaitTimeout, [&] { return state.completed == 2; });
        readyResult = state.readyResult;
        dataSawCancel = state.dataWaitSawCancel;
    }
    if (!bothCompleted) {
        /* A finish notification is a bounded cleanup path if a regression breaks cancel notify. */
        buffer.finish(LazerAudioErrorState, "probe cleanup", false);
        std::unique_lock guard(state.mutex);
        state.changed.wait_for(guard, kWaitTimeout, [&] { return state.completed == 2; });
        readyResult = state.readyResult;
        dataSawCancel = state.dataWaitSawCancel;
        guard.unlock();
        readyWaiter.join();
        dataWaiter.join();
        return expect(false, "cancel did not wake blocked PCM waiters promptly");
    }
    readyWaiter.join();
    dataWaiter.join();
    if (!expect(bothStarted, "blocked waiters did not start")) return false;
    if (!expect(!readyResult, "cancelled readiness wait reported success")) return false;
    if (!expect(dataSawCancel, "data waiter did not observe cancellation")) return false;
    if (!expect(!buffer.shouldPump(), "cancelled queue still requested producer PCM")) return false;
    return true;
}

}  // namespace

int main() {
    if (!testWrapAndPartialConsumption()) return 1;
    std::cout << "PASS: circular wrap and partial consumption\n";
    if (!testCapacityBackpressure()) return 1;
    std::cout << "PASS: bounded capacity backpressure\n";
    if (!testWatermarkAndShortEof()) return 1;
    std::cout << "PASS: PCM readiness watermark and short-track EOF\n";
    if (!testErrorIsRetainedWithBufferedPcm()) return 1;
    std::cout << "PASS: terminal reader error retention\n";
    if (!testCancelWakesBlockedWaiters()) return 1;
    std::cout << "PASS: cancellation wakes blocked waiters\n";
    return 0;
}
