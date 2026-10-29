/* Queue semantics for recovering an ALSA playback stream. Kept independent of alsa-lib so the
 * XRUN and suspend branches can be exercised with deterministic fake operations on every host. */
#ifndef LAZER_AUDIO_OUTPUT_ALSA_RECOVERY_H
#define LAZER_AUDIO_OUTPUT_ALSA_RECOVERY_H

#include <cstddef>
#include <cstdint>
#include <optional>
#include <utility>
#include <vector>

namespace lazer::audio {

/* ALSA recommends retrying resume after EAGAIN. Bound one recovery attempt to five one-second
 * waits so a permanently suspended device cannot hold the output mutex indefinitely. */
inline constexpr size_t kAlsaSuspendResumeMaxWaitIntervals = 5;

enum class AlsaRecoveryOutcome {
    XrunPrepared,
    SuspendResumed,
    SuspendPrepared,
    Failed,
};

struct AlsaRecoveryResult {
    AlsaRecoveryOutcome outcome = AlsaRecoveryOutcome::Failed;
    int error = 0;
};

template <typename Resume, typename Wait>
int resumeAlsaSuspendBounded(int errorCode, int suspendCode, int retryCode,
    Resume &&resume, Wait &&wait) {
    if (errorCode != suspendCode) return errorCode;

    size_t waitIntervals = 0;
    while (true) {
        const int result = resume();
        if (result != retryCode) return result;
        if (waitIntervals >= kAlsaSuspendResumeMaxWaitIntervals) return result;
        wait();
        ++waitIntervals;
    }
}

/* Direct DSD cannot use snd_pcm_prepare as a fallback: resetting ALSA would discard queued bytes
 * and make the next carrier marker or native DSD word phase unknowable. */
template <typename Resume, typename Wait>
AlsaRecoveryResult resumeAlsaDirectDsdSuspend(int errorCode, int suspendCode, int retryCode,
    Resume &&resume, Wait &&wait) {
    if (errorCode != suspendCode) return {AlsaRecoveryOutcome::Failed, errorCode};
    const int result = resumeAlsaSuspendBounded(errorCode, suspendCode, retryCode,
        std::forward<Resume>(resume), std::forward<Wait>(wait));
    return result >= 0
        ? AlsaRecoveryResult{AlsaRecoveryOutcome::SuspendResumed, 0}
        : AlsaRecoveryResult{AlsaRecoveryOutcome::Failed, result};
}

/* Direct DSD cannot be reset after an XRUN or an unsuccessful suspend resume: the byte/word
 * position in the source is no longer known to match the device. Keep this policy shared by DoP
 * and Native DSD so neither path falls back to prepare/replaying a potentially shifted stream. */
template <typename Resume, typename Wait>
AlsaRecoveryResult recoverAlsaDirectDsd(int errorCode, int xrunCode, int suspendCode,
    int retryCode, Resume &&resume, Wait &&wait) {
    if (errorCode == xrunCode) return {AlsaRecoveryOutcome::Failed, errorCode};
    return resumeAlsaDirectDsdSuspend(errorCode, suspendCode, retryCode,
        std::forward<Resume>(resume), std::forward<Wait>(wait));
}

template <typename Resume, typename Prepare, typename Wait>
AlsaRecoveryResult recoverAlsaPlayback(int errorCode, int xrunCode, int suspendCode,
    int retryCode, Resume &&resume, Prepare &&prepare, Wait &&wait) {
    if (errorCode == xrunCode) {
        const int result = prepare();
        return result >= 0
            ? AlsaRecoveryResult{AlsaRecoveryOutcome::XrunPrepared, 0}
            : AlsaRecoveryResult{AlsaRecoveryOutcome::Failed, result};
    }
    if (errorCode != suspendCode) return {AlsaRecoveryOutcome::Failed, errorCode};

    const int result = resumeAlsaSuspendBounded(errorCode, suspendCode, retryCode,
        std::forward<Resume>(resume), std::forward<Wait>(wait));
    if (result >= 0) return {AlsaRecoveryOutcome::SuspendResumed, 0};

    const int prepareResult = prepare();
    return prepareResult >= 0
        ? AlsaRecoveryResult{AlsaRecoveryOutcome::SuspendPrepared, 0}
        : AlsaRecoveryResult{AlsaRecoveryOutcome::Failed, prepareResult};
}

template <typename FrameCount, typename Recover, typename Query>
std::optional<FrameCount> queryAlsaAvailabilityWithRecovery(FrameCount xrunCode,
    FrameCount suspendCode, Recover &&recover, Query &&query) {
    const FrameCount firstResult = query();
    if (firstResult != xrunCode && firstResult != suspendCode) return firstResult;
    if (!recover(static_cast<int>(firstResult))) return std::nullopt;
    return query();
}

inline void reconcileAlsaRecoveryQueues(AlsaRecoveryOutcome outcome,
    std::vector<uint8_t> &stagedBytes, size_t &stagedOffsetFrames,
    std::vector<uint8_t> &submittedBytes, size_t &submittedOffsetFrames,
    size_t frameBytes) {
    if (outcome == AlsaRecoveryOutcome::XrunPrepared) {
        /* An XRUN means the playback queue ran empty. Its submitted mirror is already consumed. */
        submittedBytes.clear();
        submittedOffsetFrames = 0;
        return;
    }
    if (outcome != AlsaRecoveryOutcome::SuspendPrepared || frameBytes == 0) return;

    /* A resume failure followed by prepare resets the kernel queue. Replay the best-known pending
     * submitted suffix ahead of frames that had not reached ALSA yet. */
    const size_t submittedFrames = submittedBytes.size() / frameBytes;
    const size_t remainingSubmitted = submittedFrames > submittedOffsetFrames
        ? submittedFrames - submittedOffsetFrames : 0;
    const size_t stagedFrames = stagedBytes.size() / frameBytes;
    const size_t remainingStaged = stagedFrames > stagedOffsetFrames
        ? stagedFrames - stagedOffsetFrames : 0;
    std::vector<uint8_t> requeued;
    requeued.reserve((remainingSubmitted + remainingStaged) * frameBytes);
    if (remainingSubmitted > 0) {
        const size_t offset = submittedOffsetFrames * frameBytes;
        requeued.insert(requeued.end(),
            submittedBytes.begin() + static_cast<std::ptrdiff_t>(offset), submittedBytes.end());
    }
    if (remainingStaged > 0) {
        const size_t offset = stagedOffsetFrames * frameBytes;
        requeued.insert(requeued.end(),
            stagedBytes.begin() + static_cast<std::ptrdiff_t>(offset), stagedBytes.end());
    }
    stagedBytes.swap(requeued);
    stagedOffsetFrames = 0;
    submittedBytes.clear();
    submittedOffsetFrames = 0;
}

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_OUTPUT_ALSA_RECOVERY_H
