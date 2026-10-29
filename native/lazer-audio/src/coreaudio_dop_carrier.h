/* Re-time the DoP marker clock at the final CoreAudio callback boundary. */
#ifndef LAZER_AUDIO_COREAUDIO_DOP_CARRIER_H
#define LAZER_AUDIO_COREAUDIO_DOP_CARRIER_H

#include <cstddef>
#include <cstdint>
#include <limits>

namespace lazer::audio {

/* `audioFrames` at the front of the interleaved buffer contain DSD payload. Remaining frames are
 * valid DoP idle (0x69 payload). Markers are rewritten for every output frame so callback-created
 * idle frames cannot desynchronize the next queued payload. The DSD payload bytes are untouched. */
inline bool prepareCoreAudioDoPCarrier(uint8_t *bytes, size_t outputFrames, size_t audioFrames,
    int32_t channels, uint8_t &nextMarker) noexcept {
    if ((channels != 1 && channels != 2) || audioFrames > outputFrames ||
        (outputFrames > 0 && bytes == nullptr) ||
        (nextMarker != 0x05 && nextMarker != 0xFA) ||
        outputFrames > std::numeric_limits<size_t>::max() /
            (static_cast<size_t>(channels) * 3)) {
        return false;
    }
    for (size_t frame = 0; frame < outputFrames; ++frame) {
        for (int32_t channel = 0; channel < channels; ++channel) {
            uint8_t *word = bytes + (frame * static_cast<size_t>(channels) +
                static_cast<size_t>(channel)) * 3;
            if (frame >= audioFrames) {
                word[0] = 0x69;
                word[1] = 0x69;
            }
            word[2] = nextMarker;
        }
        nextMarker = nextMarker == 0x05 ? 0xFA : 0x05;
    }
    return true;
}

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_COREAUDIO_DOP_CARRIER_H
