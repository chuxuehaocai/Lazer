/* Platform-neutral timing policy for detecting a CoreAudio IOProc that stops calling back. */
#ifndef LAZER_AUDIO_COREAUDIO_CALLBACK_HEALTH_H
#define LAZER_AUDIO_COREAUDIO_CALLBACK_HEALTH_H

#include <cstdint>
#include <limits>

namespace lazer::audio {

constexpr uint64_t coreAudioCallbackStallTimeoutMillis(uint64_t periodFrames,
    uint64_t sampleRate) noexcept {
    if (sampleRate == 0) return 1000;
    constexpr uint64_t maximum = std::numeric_limits<uint64_t>::max();
    const uint64_t scaledFrames = periodFrames > maximum / 1000 ? maximum : periodFrames * 1000;
    const uint64_t periodMillis = scaledFrames / sampleRate +
        (scaledFrames % sampleRate == 0 ? 0 : 1);
    const uint64_t fourPeriods = periodMillis > maximum / 4 ? maximum : periodMillis * 4;
    if (fourPeriods < 250) return 250;
    if (fourPeriods > 1000) return 1000;
    return fourPeriods;
}

constexpr bool coreAudioCallbackIsStale(bool running, bool knownDead, uint64_t nowMillis,
    uint64_t lastCallbackMillis, uint64_t timeoutMillis) noexcept {
    if (knownDead) return true;
    if (!running || nowMillis < lastCallbackMillis) return false;
    return nowMillis - lastCallbackMillis >= timeoutMillis;
}

inline bool coreAudioCallbackHostTimeIsStale(bool running, bool knownDead,
    uint64_t nowHostTime, uint64_t lastCallbackHostTime, double hostClockFrequency,
    uint64_t timeoutMillis) noexcept {
    if (knownDead) return true;
    if (!running || nowHostTime < lastCallbackHostTime || !(hostClockFrequency > 0.0)) {
        return false;
    }
    const double elapsedMillis = static_cast<double>(nowHostTime - lastCallbackHostTime) *
        1000.0 / hostClockFrequency;
    return elapsedMillis >= static_cast<double>(timeoutMillis);
}

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_COREAUDIO_CALLBACK_HEALTH_H
