/* Device-neutral audio formats; output backends do not depend on FFmpeg headers. */
#ifndef LAZER_AUDIO_FORMAT_H
#define LAZER_AUDIO_FORMAT_H

#include <algorithm>
#include <cstdint>
#include <string>

namespace lazer::audio {

/* The PCM contract between the DSP stage and the output. Float32 interleaved is the engine's only
 * internal sample format; 16/24/32-bit integer output is produced at the device boundary so the DSP
 * never quantises twice. */
struct PcmFormat {
    int32_t sampleRate = 0;
    int32_t channels = 0;

    [[nodiscard]] constexpr int32_t frameSize() const noexcept {
        return channels * static_cast<int32_t>(sizeof(float));
    }
    [[nodiscard]] constexpr bool isValid() const noexcept {
        return sampleRate > 0 && channels > 0;
    }

    constexpr bool operator==(const PcmFormat &other) const noexcept {
        return sampleRate == other.sampleRate && channels == other.channels;
    }
};

/* Decoded facts about the open stream, published once the demuxer and decoder agree. */
struct StreamDescription {
    std::string codec;
    /* For PCM this is the decoded sample clock. For DSD this remains the decoder's byte-sample
     * clock (DSD bit rate / 8), used only to feed the DSD-to-PCM converter and choose an output
     * clock; callers must use dsdRateMultiplier rather than presenting it as PCM source metadata. */
    int32_t sampleRate = 0;
    int32_t channels = 0;
    int32_t bitsPerSample = 0;
    bool dsd = false;
    /* True only when the decoder emits packed AV_SAMPLE_FMT_DSD, not DST-decoded float PCM. */
    bool rawDsd = false;
    int32_t dsdRateMultiplier = 0;
    int32_t bitrateKbps = 0;
    bool lossless = false;
    /* True only when the decoder produces integer PCM; lossless codecs may decode to float. */
    bool integerPcm = false;
    bool canonicalChannelLayout = false;
    bool decoderFormatMatchesStream = false;
    int64_t durationMillis = 0;
    /* Exact decoded sample-frame count when the container publishes one, otherwise zero. */
    int64_t durationSamples = 0;
};

/* Blocks leave the source in the format the output declared, so the ring carries device bytes rather
 * than an assumed float layout. */
struct TargetFormat {
    int32_t sampleRate = 44100;
    int32_t channels = 2;
    /* Valid sample precision. Zero requests float32. */
    int32_t bitsPerSample = 0;
    /* Physical storage width used by the output device. Zero uses the packed width for valid bits. */
    int32_t containerBitsPerSample = 0;
    /* The 24-bit samples contain preformatted DoP carrier words and must bypass PCM conversion. */
    bool doP = false;
    /* Raw DSD bytes are grouped into exact ALSA DSD_U8/U16/U32 native words. */
    bool nativeDsd = false;
    bool nativeDsdBigEndian = true;
    /* Raw interleaved DSD byte frames for the Engine's session-level Native DSD packer. */
    bool nativeDsdRawBytes = false;
    /* Physical output word width for nativeDsdRawBytes seek alignment; zero keeps the generic byte grid. */
    int32_t nativeDsdWordBytes = 0;

    [[nodiscard]] bool isFloat() const noexcept { return bitsPerSample == 0; }
    [[nodiscard]] int32_t frameBytes() const noexcept {
        const int32_t containerBits = containerBitsPerSample > 0
            ? containerBitsPerSample
            : bitsPerSample == 0 ? 32 : bitsPerSample;
        const int32_t bytes = (containerBits + 7) / 8;
        return std::max(channels, 1) * std::max(bytes, 1);
    }
    /* FFmpeg has no packed 24-bit sample format; it converts 24-bit PCM through S32 and the source
     * packs the most-significant three bytes before handing frames to the output. */
    [[nodiscard]] int32_t conversionFrameBytes() const noexcept {
        const int32_t bytes = isFloat() ? 4 : bitsPerSample <= 8 ? 1 : bitsPerSample <= 16 ? 2 : 4;
        return std::max(channels, 1) * bytes;
    }
};

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_FORMAT_H
