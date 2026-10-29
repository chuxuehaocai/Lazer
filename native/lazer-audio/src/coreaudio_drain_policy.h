/* Platform-independent drain estimate used by the CoreAudio callback backend. */
#ifndef LAZER_AUDIO_COREAUDIO_DRAIN_POLICY_H
#define LAZER_AUDIO_COREAUDIO_DRAIN_POLICY_H

#include <cstdint>
#include <limits>

namespace lazer::audio {

/*
 * Returns the frames that still block drain completion. When CoreAudio cannot provide a usable
 * clock for a submitted tail, retain at least one HAL period as pending. Likewise, a callback
 * that has dequeued frames but has not published its deadline must not make an empty queue look
 * drained.
 */
constexpr uint64_t coreAudioPendingFrames(uint64_t queueFrames, bool callbackInFlight,
    bool hasSubmittedTail, bool clockEvidenceAvailable, uint64_t framesUntilDeadline,
    uint64_t periodFrames) noexcept {
    uint64_t pending = queueFrames;
    if (clockEvidenceAvailable) {
        const uint64_t maximum = std::numeric_limits<uint64_t>::max();
        pending = framesUntilDeadline > maximum - pending
            ? maximum : pending + framesUntilDeadline;
    } else if (hasSubmittedTail && pending == 0) {
        pending = periodFrames > 0 ? periodFrames : 1;
    }
    if (callbackInFlight && pending == 0) pending = periodFrames > 0 ? periodFrames : 1;
    return pending;
}

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_COREAUDIO_DRAIN_POLICY_H
