/* Integer PCM quantization and packing at the native output boundary. */
#ifndef LAZER_AUDIO_PCM_OUTPUT_H
#define LAZER_AUDIO_PCM_OUTPUT_H

#include <cstddef>
#include <cstdint>

namespace lazer::audio {

int64_t quantizeWithTpdf(float value, int32_t bits, uint64_t &state);
uint64_t convertIntegerPcm(const float *source, size_t sampleCount, int32_t validBits,
    int32_t containerBits, uint8_t *destination, uint64_t &ditherState);
int32_t samplePeakMilliDbfs(const float *source, size_t sampleCount) noexcept;

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_PCM_OUTPUT_H
