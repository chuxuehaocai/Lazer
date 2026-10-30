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
#include "audio_format.h"
#include "log_proxy.h"

namespace lazer::audio {

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
