/* Internal shared facts for the engine modules: logging, FFmpeg RAII handles and the description of
 * the PCM the output stage expects. Never exported from the DLL. */
#ifndef LAZER_AUDIO_INTERNAL_H
#define LAZER_AUDIO_INTERNAL_H

#include <atomic>
#include <cstdio>
#include <cstdint>
#include <mutex>
#include <string>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/codec_desc.h>
#include <libavformat/avformat.h>
#include <libavutil/frame.h>
#include <libavutil/log.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
}

#include "lazer_audio_api.h"

namespace lazer::audio {

/* One logger for the whole engine. The Kotlin handler is installed at create time and may outlive
 * no engine, so every call checks the pointer under the engine's own lock-free assumption: the
 * handler is set once and never rewritten. */
class LogProxy {
public:
    void install(LazerAudioLogHandler handler) { handler_ = handler; }
    void write(LazerAudioLogLevel level, const char *message) const;
    void write(LazerAudioLogLevel level, const std::string &message) const {
        write(level, message.c_str());
    }

private:
    LazerAudioLogHandler handler_{};
};

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

/* A uniquely-owned AVFrame. */
class AudioFrame {
public:
    AudioFrame() noexcept = default;
    explicit AudioFrame(AVFrame *owned) noexcept : frame_(owned) {}
    AudioFrame(const AudioFrame &) = delete;
    AudioFrame &operator=(const AudioFrame &) = delete;
    AudioFrame(AudioFrame &&other) noexcept : frame_(other.frame_) { other.frame_ = nullptr; }
    AudioFrame &operator=(AudioFrame &&other) noexcept {
        if (this != &other) {
            reset();
            frame_ = other.frame_;
            other.frame_ = nullptr;
        }
        return *this;
    }
    ~AudioFrame() { reset(); }

    [[nodiscard]] AVFrame *get() const noexcept { return frame_; }
    [[nodiscard]] explicit operator bool() const noexcept { return frame_ != nullptr; }
    AVFrame *operator->() const noexcept { return frame_; }

    void reset() noexcept;
    [[nodiscard]] AudioFrame clone() const;

    static AudioFrame allocate();

private:
    AVFrame *frame_ = nullptr;
};

class FormatContext;
class CodecContext;

/* Wrappers free their FFmpeg objects exactly once, on whichever thread closed them. */
class FormatContext {
public:
    FormatContext() noexcept = default;
    explicit FormatContext(AVFormatContext *owned) noexcept : context_(owned) {}
    FormatContext(const FormatContext &) = delete;
    FormatContext &operator=(const FormatContext &) = delete;
    FormatContext(FormatContext &&other) noexcept : context_(other.context_) {
        other.context_ = nullptr;
    }
    FormatContext &operator=(FormatContext &&other) noexcept {
        if (this != &other) {
            reset();
            context_ = other.context_;
            other.context_ = nullptr;
        }
        return *this;
    }
    ~FormatContext();

    [[nodiscard]] AVFormatContext *get() const noexcept { return context_; }
    [[nodiscard]] explicit operator bool() const noexcept { return context_ != nullptr; }
    friend bool operator==(const FormatContext &left, std::nullptr_t) noexcept {
        return left.context_ == nullptr;
    }
    friend bool operator!=(const FormatContext &left, std::nullptr_t) noexcept {
        return left.context_ != nullptr;
    }
    AVFormatContext *operator->() const noexcept { return context_; }
    void reset() noexcept;

private:
    AVFormatContext *context_ = nullptr;
};

class CodecContext {
public:
    CodecContext() noexcept = default;
    explicit CodecContext(AVCodecContext *owned) noexcept : context_(owned) {}
    CodecContext(const CodecContext &) = delete;
    CodecContext &operator=(const CodecContext &) = delete;
    CodecContext(CodecContext &&other) noexcept : context_(other.context_) {
        other.context_ = nullptr;
    }
    CodecContext &operator=(CodecContext &&other) noexcept {
        if (this != &other) {
            reset();
            context_ = other.context_;
            other.context_ = nullptr;
        }
        return *this;
    }
    ~CodecContext();

    [[nodiscard]] AVCodecContext *get() const noexcept { return context_; }
    [[nodiscard]] explicit operator bool() const noexcept { return context_ != nullptr; }
    friend bool operator==(const CodecContext &left, std::nullptr_t) noexcept {
        return left.context_ == nullptr;
    }
    friend bool operator!=(const CodecContext &left, std::nullptr_t) noexcept {
        return left.context_ != nullptr;
    }
    AVCodecContext *operator->() const noexcept { return context_; }
    void reset() noexcept;

private:
    AVCodecContext *context_ = nullptr;
};

class ResampleContext {
public:
    ResampleContext() noexcept = default;
    explicit ResampleContext(SwrContext *owned) noexcept : context_(owned) {}
    ResampleContext(const ResampleContext &) = delete;
    ResampleContext &operator=(const ResampleContext &) = delete;
    ResampleContext(ResampleContext &&other) noexcept : context_(other.context_) {
        other.context_ = nullptr;
    }
    ResampleContext &operator=(ResampleContext &&other) noexcept {
        if (this != &other) {
            reset();
            context_ = other.context_;
            other.context_ = nullptr;
        }
        return *this;
    }
    ~ResampleContext();

    [[nodiscard]] SwrContext *get() const noexcept { return context_; }
    [[nodiscard]] explicit operator bool() const noexcept { return context_ != nullptr; }
    friend bool operator==(const ResampleContext &left, std::nullptr_t) noexcept {
        return left.context_ == nullptr;
    }
    friend bool operator!=(const ResampleContext &left, std::nullptr_t) noexcept {
        return left.context_ != nullptr;
    }
    void reset() noexcept;

private:
    SwrContext *context_ = nullptr;
};

/* Formats FFmpeg reports in a way the engine can reason about. */
int bitsPerRawSample(const AVCodecContext *context, const AVFrame *frame);
bool codecIsLossless(const AVCodec *codec);
std::string formatContextError(int code);
bool wideStringToUtf8(const wchar_t *value, std::string &out);
bool utf8StringToWide(const char *value, std::wstring &out);
FILE *openWideFileForRead(const wchar_t *path);
int seekFile64(FILE *file, int64_t offset, int origin);
int64_t tellFile64(FILE *file);

/* Turns an FFmpeg log level into the engine's four levels so the Kotlin side does not have to read
 * av_log internals. */
LazerAudioLogLevel mapAvLogLevel(int level);

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_INTERNAL_H
