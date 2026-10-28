#include "internal.h"

#include <cstdio>
#include <cstdint>
#include <limits>

#ifdef _WIN32
#include <io.h>
#else
#include <sys/types.h>
#endif

extern "C" {
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mem.h>
}

namespace lazer::audio {

void LogProxy::write(LazerAudioLogLevel level, const char *message) const {
    if (handler_.on_log == nullptr || message == nullptr) return;
    handler_.on_log(handler_.context, static_cast<int32_t>(level), message);
}

void AudioFrame::reset() noexcept {
    if (frame_ != nullptr) {
        av_frame_free(&frame_);
        frame_ = nullptr;
    }
}

AudioFrame AudioFrame::allocate() {
    return AudioFrame(av_frame_alloc());
}

AudioFrame AudioFrame::clone() const {
    if (frame_ == nullptr) return AudioFrame();
    return AudioFrame(av_frame_clone(frame_));
}

FormatContext::~FormatContext() {
    reset();
}

void FormatContext::reset() noexcept {
    if (context_ != nullptr) {
        avformat_close_input(&context_);
        context_ = nullptr;
    }
}

CodecContext::~CodecContext() {
    reset();
}

void CodecContext::reset() noexcept {
    if (context_ != nullptr) {
        avcodec_free_context(&context_);
        context_ = nullptr;
    }
}

ResampleContext::~ResampleContext() {
    reset();
}

void ResampleContext::reset() noexcept {
    if (context_ != nullptr) {
        swr_free(&context_);
        context_ = nullptr;
    }
}

int bitsPerRawSample(const AVCodecContext *context, const AVFrame *frame) {
    if (frame != nullptr && frame->format == AV_SAMPLE_FMT_U8P) return 8;
    if (context == nullptr) return 0;
    if (context->bits_per_raw_sample > 0) return context->bits_per_raw_sample;
    switch (context->sample_fmt) {
        case AV_SAMPLE_FMT_U8:
        case AV_SAMPLE_FMT_U8P:
            return 8;
        case AV_SAMPLE_FMT_S16:
        case AV_SAMPLE_FMT_S16P:
            return 16;
        case AV_SAMPLE_FMT_S32:
        case AV_SAMPLE_FMT_S32P:
            return 32;
        case AV_SAMPLE_FMT_S64:
        case AV_SAMPLE_FMT_S64P:
            return 64;
        case AV_SAMPLE_FMT_FLT:
        case AV_SAMPLE_FMT_FLTP:
            return 32;
        case AV_SAMPLE_FMT_DBL:
        case AV_SAMPLE_FMT_DBLP:
            return 64;
        default:
            return 0;
    }
}

bool codecIsLossless(const AVCodec *codec) {
    if (codec == nullptr) return false;
    /* The flag lives on the descriptor, not the codec: AVCodec only publishes bitstream
     * capabilities, so asking the descriptor table is the only accurate lossless probe. */
    const AVCodecDescriptor *descriptor = avcodec_descriptor_get(codec->id);
    return descriptor != nullptr && (descriptor->props & AV_CODEC_PROP_LOSSLESS) != 0;
}

std::string formatContextError(int code) {
    char buffer[AV_ERROR_MAX_STRING_SIZE] = {0};
    if (av_strerror(code, buffer, sizeof(buffer)) == 0) {
        return std::string(buffer);
    }
    std::string text("FFmpeg error ");
    text += std::to_string(code);
    return text;
}

bool wideStringToUtf8(const wchar_t *value, std::string &out) {
    out.clear();
    if (value == nullptr) return true;

    const auto appendCodePoint = [&out](uint32_t codePoint) {
        if (codePoint <= 0x7fU) {
            out.push_back(static_cast<char>(codePoint));
        } else if (codePoint <= 0x7ffU) {
            out.push_back(static_cast<char>(0xc0U | (codePoint >> 6U)));
            out.push_back(static_cast<char>(0x80U | (codePoint & 0x3fU)));
        } else if (codePoint <= 0xffffU) {
            out.push_back(static_cast<char>(0xe0U | (codePoint >> 12U)));
            out.push_back(static_cast<char>(0x80U | ((codePoint >> 6U) & 0x3fU)));
            out.push_back(static_cast<char>(0x80U | (codePoint & 0x3fU)));
        } else {
            out.push_back(static_cast<char>(0xf0U | (codePoint >> 18U)));
            out.push_back(static_cast<char>(0x80U | ((codePoint >> 12U) & 0x3fU)));
            out.push_back(static_cast<char>(0x80U | ((codePoint >> 6U) & 0x3fU)));
            out.push_back(static_cast<char>(0x80U | (codePoint & 0x3fU)));
        }
    };

    for (size_t index = 0; value[index] != L'\0'; ++index) {
        uint32_t codePoint = static_cast<uint32_t>(value[index]);
        if constexpr (sizeof(wchar_t) == 2) {
            if (codePoint >= 0xd800U && codePoint <= 0xdbffU) {
                const uint32_t low = static_cast<uint32_t>(value[index + 1]);
                if (low < 0xdc00U || low > 0xdfffU) return false;
                codePoint = 0x10000U + ((codePoint - 0xd800U) << 10U) + (low - 0xdc00U);
                ++index;
            } else if (codePoint >= 0xdc00U && codePoint <= 0xdfffU) {
                return false;
            }
        } else if (codePoint >= 0xd800U && codePoint <= 0xdfffU) {
            return false;
        }
        if (codePoint > 0x10ffffU) return false;
        appendCodePoint(codePoint);
    }
    return true;
}

bool utf8StringToWide(const char *value, std::wstring &out) {
    out.clear();
    if (value == nullptr) return true;
    const auto *bytes = reinterpret_cast<const uint8_t *>(value);
    for (size_t index = 0; bytes[index] != 0;) {
        const uint8_t first = bytes[index++];
        uint32_t codePoint = 0;
        uint32_t continuationCount = 0;
        if (first <= 0x7fU) {
            codePoint = first;
        } else if (first >= 0xc2U && first <= 0xdfU) {
            codePoint = first & 0x1fU;
            continuationCount = 1;
        } else if (first >= 0xe0U && first <= 0xefU) {
            codePoint = first & 0x0fU;
            continuationCount = 2;
        } else if (first >= 0xf0U && first <= 0xf4U) {
            codePoint = first & 0x07U;
            continuationCount = 3;
        } else {
            out.clear();
            return false;
        }
        for (uint32_t continuation = 0; continuation < continuationCount; ++continuation) {
            const uint8_t next = bytes[index++];
            if (next == 0 || (next & 0xc0U) != 0x80U) {
                out.clear();
                return false;
            }
            codePoint = (codePoint << 6U) | (next & 0x3fU);
        }
        if ((continuationCount == 1 && codePoint < 0x80U) ||
            (continuationCount == 2 && codePoint < 0x800U) ||
            (continuationCount == 3 && codePoint < 0x10000U) ||
            codePoint > 0x10ffffU || (codePoint >= 0xd800U && codePoint <= 0xdfffU)) {
            out.clear();
            return false;
        }
        if constexpr (sizeof(wchar_t) == 2) {
            if (codePoint <= 0xffffU) {
                out.push_back(static_cast<wchar_t>(codePoint));
            } else {
                codePoint -= 0x10000U;
                out.push_back(static_cast<wchar_t>(0xd800U + (codePoint >> 10U)));
                out.push_back(static_cast<wchar_t>(0xdc00U + (codePoint & 0x3ffU)));
            }
        } else {
            out.push_back(static_cast<wchar_t>(codePoint));
        }
    }
    return true;
}

FILE *openWideFileForRead(const wchar_t *path) {
    if (path == nullptr) return nullptr;
#ifdef _WIN32
    FILE *file = nullptr;
    return _wfopen_s(&file, path, L"rb") == 0 ? file : nullptr;
#else
    std::string utf8;
    if (!wideStringToUtf8(path, utf8)) return nullptr;
    return std::fopen(utf8.c_str(), "rb");
#endif
}

int seekFile64(FILE *file, int64_t offset, int origin) {
    if (file == nullptr) return -1;
#ifdef _WIN32
    return _fseeki64(file, offset, origin);
#else
    if (offset < static_cast<int64_t>(std::numeric_limits<off_t>::min()) ||
        offset > static_cast<int64_t>(std::numeric_limits<off_t>::max())) return -1;
    return fseeko(file, static_cast<off_t>(offset), origin);
#endif
}

int64_t tellFile64(FILE *file) {
    if (file == nullptr) return -1;
#ifdef _WIN32
    return _ftelli64(file);
#else
    const off_t position = ftello(file);
    if (position < 0 || static_cast<uint64_t>(position) >
        static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) return -1;
    return static_cast<int64_t>(position);
#endif
}

LazerAudioLogLevel mapAvLogLevel(int level) {
    if (level <= AV_LOG_ERROR) return LazerAudioLogError;
    if (level <= AV_LOG_WARNING) return LazerAudioLogWarning;
    if (level <= AV_LOG_INFO) return LazerAudioLogInfo;
    return LazerAudioLogDebug;
}

}  // namespace lazer::audio
