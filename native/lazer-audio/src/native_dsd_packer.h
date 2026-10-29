/* Groups interleaved raw DSD bytes into the native word widths used by ALSA. */
#ifndef LAZER_AUDIO_NATIVE_DSD_PACKER_H
#define LAZER_AUDIO_NATIVE_DSD_PACKER_H

#include <array>
#include <cstddef>
#include <cstdint>

namespace lazer::audio {

enum class NativeDsdPackStatus {
    Ok,
    NeedMoreInput,
    OutputFull,
    InvalidChannelCount,
    InvalidWordBytes,
    InvalidArgument,
    SizeOverflow,
};

struct NativeDsdPackResult {
    NativeDsdPackStatus status = NativeDsdPackStatus::Ok;
    size_t consumedInputFrames = 0;
    size_t producedOutputFrames = 0;
};

/* Each input frame contains one decoded DSD byte per channel. A native ALSA DSD_U16/U32
 * output frame groups two/four successive bytes per channel. Big-endian words preserve the
 * decoder's MSB-first byte order; little-endian words reverse bytes within each channel word.
 * Incomplete final words are padded with the DSD silence pattern (0x69). */
class NativeDsdPacker {
public:
    NativeDsdPacker() noexcept = default;
    NativeDsdPacker(size_t channels, size_t wordBytes, bool bigEndian) noexcept;

    void reset() noexcept;

    [[nodiscard]] NativeDsdPackResult pack(const uint8_t *interleavedDsd,
        size_t inputFrameCount, uint8_t *nativeDsd, size_t outputCapacityFrames) noexcept;

    [[nodiscard]] NativeDsdPackResult flush(uint8_t *nativeDsd,
        size_t outputCapacityFrames) noexcept;

    [[nodiscard]] size_t channels() const noexcept { return channels_; }
    [[nodiscard]] size_t wordBytes() const noexcept { return wordBytes_; }
    [[nodiscard]] bool hasPendingInput() const noexcept { return pendingFrames_ != 0; }

private:
    void writePending(uint8_t *destination) const noexcept;

    size_t channels_ = 0;
    size_t wordBytes_ = 0;
    bool bigEndian_ = true;
    size_t pendingFrames_ = 0;
    std::array<uint8_t, 8> pending_{};
};

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_NATIVE_DSD_PACKER_H
