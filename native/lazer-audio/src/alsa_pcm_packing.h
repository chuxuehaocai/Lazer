/* Pure byte-layout conversion used at the ALSA PCM write boundary. This header intentionally has
 * no alsa-lib dependency so the same output packing contract can be tested on every host. */
#ifndef LAZER_AUDIO_ALSA_PCM_PACKING_H
#define LAZER_AUDIO_ALSA_PCM_PACKING_H

#include <cstddef>
#include <cstdint>
#include <vector>

namespace lazer::audio {

inline void appendAlsaOutputFrames(std::vector<uint8_t> &stagedBytes, const uint8_t *bytes,
    size_t frameCount, size_t channelCount, int32_t frameBytes, bool doP,
    bool shift24ToLow) {
    const size_t byteCount = frameCount * static_cast<size_t>(frameBytes);
    if (doP || !shift24ToLow) {
        /* DoP carrier bytes contain their own marker. Keep every byte in order and do not reinterpret
         * the signed 24-bit carrier words as ordinary PCM samples. */
        stagedBytes.insert(stagedBytes.end(), bytes, bytes + byteCount);
        return;
    }

    /* Shared integer PCM conversion stores 24 valid bits left-aligned in 32 bits. ALSA S24_LE
     * expects those bits low-aligned in a 32-bit container with the sign extended into byte four. */
    const size_t sampleCount = frameCount * channelCount;
    const size_t offset = stagedBytes.size();
    stagedBytes.resize(offset + byteCount);
    for (size_t sample = 0; sample < sampleCount; ++sample) {
        const uint8_t sign = (bytes[sample * 4 + 3] & 0x80U) != 0 ? 0xffU : 0x00U;
        stagedBytes[offset + sample * 4] = bytes[sample * 4 + 1];
        stagedBytes[offset + sample * 4 + 1] = bytes[sample * 4 + 2];
        stagedBytes[offset + sample * 4 + 2] = bytes[sample * 4 + 3];
        stagedBytes[offset + sample * 4 + 3] = sign;
    }
}

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_ALSA_PCM_PACKING_H
