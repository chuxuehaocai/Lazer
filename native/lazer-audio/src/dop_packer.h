/* Small allocation-free converter from interleaved DSD bytes to 24-bit DoP carrier words.
 * This utility is intentionally independent of FFmpeg and every output backend. */
#ifndef LAZER_AUDIO_DOP_PACKER_H
#define LAZER_AUDIO_DOP_PACKER_H

#include <array>
#include <cstddef>
#include <cstdint>

namespace lazer::audio {

enum class DopPackStatus {
    Ok,
    NeedMoreInput,       /* An unmatched DSD input frame is retained for the next call. */
    OutputFull,          /* Some input remains unconsumed; retry from consumedInputFrames. */
    InvalidChannelCount, /* Only mono and stereo are supported. */
    InvalidArgument,
    SizeOverflow,
};

struct DopPackResult {
    DopPackStatus status = DopPackStatus::Ok;
    size_t consumedInputFrames = 0;
    size_t producedOutputFrames = 0;
};

/* Converts packed/interleaved MSB-first AV_SAMPLE_FMT_DSD bytes. One input frame contains one
 * DSD byte per channel. Each output carrier frame contains two successive DSD bytes per channel,
 * followed by the DoP marker: [first byte, second byte, marker]. Channel words are interleaved.
 *
 * The first marker after construction/reset is 0x05 and then alternates 0xFA/0x05 once per
 * produced carrier frame, identically for all channels. One unmatched input frame is retained
 * internally across calls. Input and output memory must not overlap.
 *
 * Output capacity is measured in carrier frames, not bytes. On OutputFull, the caller must retain
 * and retry input starting at consumedInputFrames; no complete DSD pair is consumed without room
 * for its complete output carrier frame. The class performs no dynamic allocation. */
class DopPacker {
public:
    explicit DopPacker(size_t channels) noexcept;

    void reset() noexcept;

    [[nodiscard]] DopPackResult pack(const uint8_t *interleavedDsd,
        size_t inputFrameCount, uint8_t *interleavedDop,
        size_t outputCapacityFrames) noexcept;

    /* Emits one final carrier frame when an odd DSD byte remains, padding its second byte with
     * DSD idle (0x69). A zero-capacity call leaves pending input intact. */
    [[nodiscard]] DopPackResult flush(uint8_t *interleavedDop,
        size_t outputCapacityFrames) noexcept;

    [[nodiscard]] size_t channels() const noexcept { return channels_; }
    [[nodiscard]] bool hasPendingInputFrame() const noexcept { return hasPendingFrame_; }
    [[nodiscard]] uint8_t nextMarker() const noexcept { return nextMarker_; }

private:
    size_t channels_;
    std::array<uint8_t, 2> pendingFrame_{};
    bool hasPendingFrame_ = false;
    uint8_t nextMarker_ = 0x05;
};

/* Formats one render submission for DoP. A fixed-period endpoint receives the whole writable
 * period, padded with DSD idle bytes when needed. A variable-period endpoint receives only the
 * available audio frames, except that a completely empty ring still sends an idle period. The
 * marker clock advances only across frames included in the returned submission count. Returns -1
 * for invalid dimensions or pointers. */
[[nodiscard]] int32_t prepareDopCarrierFrames(uint8_t *bytes,
    int32_t writableFrames, int32_t audioFrames, int32_t channels,
    bool fixedPeriod, uint8_t &nextMarker) noexcept;

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_DOP_PACKER_H
