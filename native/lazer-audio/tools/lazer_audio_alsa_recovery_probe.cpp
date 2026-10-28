/* Deterministic recovery tests for the ALSA output queue, with fake alsa-lib operations. */
#include <cstddef>
#include <cstdio>
#include <initializer_list>
#include <string>
#include <vector>

#include "output_alsa_recovery.h"

namespace {

constexpr int kXrun = -32;
constexpr int kSuspend = -86;
constexpr int kTryAgain = -11;
constexpr int kNotSupported = -38;
constexpr int kPrepareFailed = -5;

bool fail(const std::string &message) {
    std::fprintf(stderr, "FAIL: %s\n", message.c_str());
    return false;
}

bool expectBytes(const std::vector<uint8_t> &actual,
    std::initializer_list<uint8_t> expected, const char *message) {
    if (actual == std::vector<uint8_t>(expected)) return true;
    return fail(message);
}

bool testXrunDiscardsSubmittedFrames() {
    std::vector<uint8_t> staged{0xb0, 0xb1};
    size_t stagedOffset = 0;
    std::vector<uint8_t> submitted{0xa0, 0xa1};
    size_t submittedOffset = 0;
    int prepareCalls = 0;
    const auto result = lazer::audio::recoverAlsaPlayback(
        kXrun, kXrun, kSuspend, kTryAgain,
        []() { return kNotSupported; },
        [&prepareCalls]() { ++prepareCalls; return 0; },
        []() {});
    lazer::audio::reconcileAlsaRecoveryQueues(result.outcome,
        staged, stagedOffset, submitted, submittedOffset, 2);

    return result.outcome == lazer::audio::AlsaRecoveryOutcome::XrunPrepared &&
        prepareCalls == 1 && submitted.empty() && submittedOffset == 0 &&
        stagedOffset == 0 && expectBytes(staged, {0xb0, 0xb1},
            "XRUN recovery replayed frames already consumed by the hardware");
}

bool testSuccessfulSuspendResumePreservesSubmittedFrames() {
    std::vector<uint8_t> staged{0xb0, 0xb1};
    size_t stagedOffset = 0;
    std::vector<uint8_t> submitted{0xa0, 0xa1};
    size_t submittedOffset = 0;
    int prepareCalls = 0;
    int waitCalls = 0;
    const auto result = lazer::audio::recoverAlsaPlayback(
        kSuspend, kXrun, kSuspend, kTryAgain,
        []() { return 0; },
        [&prepareCalls]() { ++prepareCalls; return 0; },
        [&waitCalls]() { ++waitCalls; });
    lazer::audio::reconcileAlsaRecoveryQueues(result.outcome,
        staged, stagedOffset, submitted, submittedOffset, 2);

    return result.outcome == lazer::audio::AlsaRecoveryOutcome::SuspendResumed &&
        prepareCalls == 0 && waitCalls == 0 && submittedOffset == 0 && stagedOffset == 0 &&
        expectBytes(submitted, {0xa0, 0xa1},
            "successful suspend resume must retain the existing hardware queue") &&
        expectBytes(staged, {0xb0, 0xb1},
            "successful suspend resume must not copy submitted frames into the staged queue");
}

bool testSuspendPrepareFallbackRequeuesOnlyPendingFramesInOrder() {
    std::vector<uint8_t> staged{0x7e, 0x7f, 0xb0, 0xb1};
    size_t stagedOffset = 1;
    std::vector<uint8_t> submitted{0x6e, 0x6f, 0xa0, 0xa1};
    size_t submittedOffset = 1;
    int prepareCalls = 0;
    int resumeCalls = 0;
    int waitCalls = 0;
    const auto result = lazer::audio::recoverAlsaPlayback(
        kSuspend, kXrun, kSuspend, kTryAgain,
        [&resumeCalls]() { return ++resumeCalls == 1 ? kTryAgain : kNotSupported; },
        [&prepareCalls]() { ++prepareCalls; return 0; },
        [&waitCalls]() { ++waitCalls; });
    lazer::audio::reconcileAlsaRecoveryQueues(result.outcome,
        staged, stagedOffset, submitted, submittedOffset, 2);

    return result.outcome == lazer::audio::AlsaRecoveryOutcome::SuspendPrepared &&
        resumeCalls == 2 && waitCalls == 1 && prepareCalls == 1 &&
        submitted.empty() && submittedOffset == 0 && stagedOffset == 0 &&
        expectBytes(staged, {0xa0, 0xa1, 0xb0, 0xb1},
            "prepare fallback must replay the pending submitted suffix exactly once before staged frames");
}

bool testSuspendResumeRetriesEagainBeforePreservingQueue() {
    int resumeCalls = 0;
    int waitCalls = 0;
    int prepareCalls = 0;
    const auto result = lazer::audio::recoverAlsaPlayback(
        kSuspend, kXrun, kSuspend, kTryAgain,
        [&resumeCalls]() { return ++resumeCalls <= 2 ? kTryAgain : 0; },
        [&prepareCalls]() { ++prepareCalls; return 0; },
        [&waitCalls]() { ++waitCalls; });

    return result.outcome == lazer::audio::AlsaRecoveryOutcome::SuspendResumed &&
        resumeCalls == 3 && waitCalls == 2 && prepareCalls == 0;
}

bool testPcmSuspendResumeRetryLimitFallsBackToPrepareAndRequeuesPendingFrames() {
    std::vector<uint8_t> staged{0xb0, 0xb1};
    size_t stagedOffset = 0;
    std::vector<uint8_t> submitted{0xa0, 0xa1};
    size_t submittedOffset = 0;
    int resumeCalls = 0;
    int waitCalls = 0;
    int prepareCalls = 0;
    const auto result = lazer::audio::recoverAlsaPlayback(
        kSuspend, kXrun, kSuspend, kTryAgain,
        [&resumeCalls]() { ++resumeCalls; return kTryAgain; },
        [&prepareCalls]() { ++prepareCalls; return 0; },
        [&waitCalls]() { ++waitCalls; });
    lazer::audio::reconcileAlsaRecoveryQueues(result.outcome,
        staged, stagedOffset, submitted, submittedOffset, 2);

    return result.outcome == lazer::audio::AlsaRecoveryOutcome::SuspendPrepared &&
        resumeCalls == static_cast<int>(lazer::audio::kAlsaSuspendResumeMaxWaitIntervals + 1) &&
        waitCalls == static_cast<int>(lazer::audio::kAlsaSuspendResumeMaxWaitIntervals) &&
        prepareCalls == 1 && submitted.empty() && submittedOffset == 0 && stagedOffset == 0 &&
        expectBytes(staged, {0xa0, 0xa1, 0xb0, 0xb1},
            "PCM retry exhaustion must prepare once and preserve pending frames in order");
}

bool testDopSuspendResumeRetryLimitFailsWithoutResettingQueue() {
    int resumeCalls = 0;
    int waitCalls = 0;
    const auto result = lazer::audio::resumeAlsaDirectDsdSuspend(
        kSuspend, kSuspend, kTryAgain,
        [&resumeCalls]() { ++resumeCalls; return kTryAgain; },
        [&waitCalls]() { ++waitCalls; });

    return result.outcome == lazer::audio::AlsaRecoveryOutcome::Failed &&
        result.error == kTryAgain &&
        resumeCalls == static_cast<int>(lazer::audio::kAlsaSuspendResumeMaxWaitIntervals + 1) &&
        waitCalls == static_cast<int>(lazer::audio::kAlsaSuspendResumeMaxWaitIntervals);
}

bool testDopSuspendResumePreservesQueueAfterTransientEagain() {
    int resumeCalls = 0;
    int waitCalls = 0;
    const auto result = lazer::audio::resumeAlsaDirectDsdSuspend(
        kSuspend, kSuspend, kTryAgain,
        [&resumeCalls]() { return ++resumeCalls <= 2 ? kTryAgain : 0; },
        [&waitCalls]() { ++waitCalls; });

    return result.outcome == lazer::audio::AlsaRecoveryOutcome::SuspendResumed &&
        result.error == 0 && resumeCalls == 3 && waitCalls == 2;
}

bool testNativeDsdXrunFailsWithoutResumeOrWait() {
    std::vector<uint8_t> staged{0xb0, 0xb1};
    size_t stagedOffset = 0;
    std::vector<uint8_t> submitted{0xa0, 0xa1};
    size_t submittedOffset = 0;
    int resumeCalls = 0;
    int waitCalls = 0;
    const auto result = lazer::audio::recoverAlsaDirectDsd(
        kXrun, kXrun, kSuspend, kTryAgain,
        [&resumeCalls]() { ++resumeCalls; return 0; },
        [&waitCalls]() { ++waitCalls; });
    lazer::audio::reconcileAlsaRecoveryQueues(result.outcome,
        staged, stagedOffset, submitted, submittedOffset, 2);
    return result.outcome == lazer::audio::AlsaRecoveryOutcome::Failed &&
        result.error == kXrun && resumeCalls == 0 && waitCalls == 0 &&
        expectBytes(submitted, {0xa0, 0xa1},
            "Native DSD XRUN modified the submitted mirror") &&
        expectBytes(staged, {0xb0, 0xb1},
            "Native DSD XRUN modified the staged queue");
}

bool testNativeDsdSuspendResumePreservesQueues() {
    std::vector<uint8_t> staged{0xb0, 0xb1};
    size_t stagedOffset = 0;
    std::vector<uint8_t> submitted{0xa0, 0xa1};
    size_t submittedOffset = 0;
    int resumeCalls = 0;
    int waitCalls = 0;
    const auto result = lazer::audio::recoverAlsaDirectDsd(
        kSuspend, kXrun, kSuspend, kTryAgain,
        [&resumeCalls]() { return ++resumeCalls <= 2 ? kTryAgain : 0; },
        [&waitCalls]() { ++waitCalls; });
    lazer::audio::reconcileAlsaRecoveryQueues(result.outcome,
        staged, stagedOffset, submitted, submittedOffset, 2);
    return result.outcome == lazer::audio::AlsaRecoveryOutcome::SuspendResumed &&
        result.error == 0 && resumeCalls == 3 && waitCalls == 2 &&
        submittedOffset == 0 && stagedOffset == 0 &&
        expectBytes(submitted, {0xa0, 0xa1},
            "Native DSD suspend resume lost or replayed already submitted frames") &&
        expectBytes(staged, {0xb0, 0xb1},
            "Native DSD suspend resume changed frames still in the staging queue");
}

bool testNativeDsdSuspendFailureIsTerminalWithoutRequeue() {
    std::vector<uint8_t> staged{0xb0, 0xb1};
    size_t stagedOffset = 0;
    std::vector<uint8_t> submitted{0xa0, 0xa1};
    size_t submittedOffset = 0;
    int resumeCalls = 0;
    int waitCalls = 0;
    const auto result = lazer::audio::recoverAlsaDirectDsd(
        kSuspend, kXrun, kSuspend, kTryAgain,
        [&resumeCalls]() { ++resumeCalls; return kNotSupported; },
        [&waitCalls]() { ++waitCalls; });
    lazer::audio::reconcileAlsaRecoveryQueues(result.outcome,
        staged, stagedOffset, submitted, submittedOffset, 2);
    return result.outcome == lazer::audio::AlsaRecoveryOutcome::Failed &&
        result.error == kNotSupported && resumeCalls == 1 && waitCalls == 0 &&
        expectBytes(submitted, {0xa0, 0xa1},
            "failed Native DSD resume modified submitted bytes") &&
        expectBytes(staged, {0xb0, 0xb1},
            "failed Native DSD resume modified staged bytes");
}

bool testNativeDsdSuspendRetryExhaustionStopsWithoutReprepare() {
    std::vector<uint8_t> staged{0xb0, 0xb1};
    size_t stagedOffset = 0;
    std::vector<uint8_t> submitted{0xa0, 0xa1};
    size_t submittedOffset = 0;
    int resumeCalls = 0;
    int waitCalls = 0;
    const auto result = lazer::audio::recoverAlsaDirectDsd(
        kSuspend, kXrun, kSuspend, kTryAgain,
        [&resumeCalls]() { ++resumeCalls; return kTryAgain; },
        [&waitCalls]() { ++waitCalls; });
    lazer::audio::reconcileAlsaRecoveryQueues(result.outcome,
        staged, stagedOffset, submitted, submittedOffset, 2);
    return result.outcome == lazer::audio::AlsaRecoveryOutcome::Failed &&
        result.error == kTryAgain &&
        resumeCalls == static_cast<int>(lazer::audio::kAlsaSuspendResumeMaxWaitIntervals + 1) &&
        waitCalls == static_cast<int>(lazer::audio::kAlsaSuspendResumeMaxWaitIntervals) &&
        expectBytes(submitted, {0xa0, 0xa1},
            "Native DSD retry exhaustion modified submitted bytes") &&
        expectBytes(staged, {0xb0, 0xb1},
            "Native DSD retry exhaustion modified staged bytes");
}

bool testAvailabilityIsQueriedAgainAfterXrunAndSuspendRecovery() {
    const auto checkRecovery = [](int firstError, int availableAfterRecovery,
                                  const char *message) {
        int queryCalls = 0;
        int recoverCalls = 0;
        int recoveredError = 0;
        const auto available = lazer::audio::queryAlsaAvailabilityWithRecovery(
            kXrun, kSuspend,
            [&recoverCalls, &recoveredError](int error) {
                ++recoverCalls;
                recoveredError = error;
                return true;
            },
            [&queryCalls, firstError, availableAfterRecovery]() {
                ++queryCalls;
                return queryCalls == 1 ? firstError : availableAfterRecovery;
            });
        return available.has_value() && *available == availableAfterRecovery &&
            queryCalls == 2 && recoverCalls == 1 && recoveredError == firstError
            ? true : fail(message);
    };

    return checkRecovery(kXrun, 128,
            "availability must be re-read after XRUN preparation to report the empty hardware queue") &&
        checkRecovery(kSuspend, 124,
            "availability must be re-read after suspend resume to report retained hardware frames");
}

bool testPrepareFailureLeavesMirrorsForErrorHandling() {
    std::vector<uint8_t> staged{0xb0, 0xb1};
    size_t stagedOffset = 0;
    std::vector<uint8_t> submitted{0xa0, 0xa1};
    size_t submittedOffset = 0;
    int prepareCalls = 0;
    const auto result = lazer::audio::recoverAlsaPlayback(
        kSuspend, kXrun, kSuspend, kTryAgain,
        []() { return kNotSupported; },
        [&prepareCalls]() { ++prepareCalls; return kPrepareFailed; },
        []() {});
    lazer::audio::reconcileAlsaRecoveryQueues(result.outcome,
        staged, stagedOffset, submitted, submittedOffset, 2);

    return result.outcome == lazer::audio::AlsaRecoveryOutcome::Failed &&
        result.error == kPrepareFailed && prepareCalls == 1 &&
        expectBytes(staged, {0xb0, 0xb1}, "failed recovery modified staged audio") &&
        expectBytes(submitted, {0xa0, 0xa1}, "failed recovery modified the submitted mirror");
}

}  // namespace

int main() {
    bool passed = true;
    passed &= testXrunDiscardsSubmittedFrames();
    passed &= testSuccessfulSuspendResumePreservesSubmittedFrames();
    passed &= testSuspendPrepareFallbackRequeuesOnlyPendingFramesInOrder();
    passed &= testSuspendResumeRetriesEagainBeforePreservingQueue();
    passed &= testPcmSuspendResumeRetryLimitFallsBackToPrepareAndRequeuesPendingFrames();
    passed &= testDopSuspendResumeRetryLimitFailsWithoutResettingQueue();
    passed &= testDopSuspendResumePreservesQueueAfterTransientEagain();
    passed &= testNativeDsdXrunFailsWithoutResumeOrWait();
    passed &= testNativeDsdSuspendResumePreservesQueues();
    passed &= testNativeDsdSuspendFailureIsTerminalWithoutRequeue();
    passed &= testNativeDsdSuspendRetryExhaustionStopsWithoutReprepare();
    passed &= testAvailabilityIsQueriedAgainAfterXrunAndSuspendRecovery();
    passed &= testPrepareFailureLeavesMirrorsForErrorHandling();
    if (!passed) return 1;
    std::puts("PASS: ALSA XRUN and suspend recovery queue semantics");
    return 0;
}
