#include "source.h"

#include <algorithm>
#include <chrono>
#include <cerrno>
#include <cstring>
#include <limits>
#include <numeric>
#include <string>
#include <thread>

extern "C" {
#include <libavutil/channel_layout.h>
#include <libavutil/dict.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
}

namespace lazer::audio {

namespace {

constexpr int kAvioBufferSize = 64 * 1024;
constexpr AVRational kMillisTimeBase{1, 1000};
/* AVIO's whence values are the C stdio seek constants plus AVSEEK_SIZE; naming the constant here
 * keeps the reader contract readable without pulling stdio macros into this file. */
constexpr int64_t kAvioSeekSet = 0;

bool isDsdCodec(AVCodecID codecId) {
    switch (codecId) {
        case AV_CODEC_ID_DSD_LSBF:
        case AV_CODEC_ID_DSD_MSBF:
        case AV_CODEC_ID_DSD_LSBF_PLANAR:
        case AV_CODEC_ID_DSD_MSBF_PLANAR:
            return true;
        default:
            return false;
    }
}

int32_t dsdMultiplierForSampleRate(int32_t sampleRate) {
    if (sampleRate <= 0) return 0;
    const int64_t dsdBitsPerSecond = static_cast<int64_t>(sampleRate) * 8;
    if (dsdBitsPerSecond % 44'100 != 0) return 0;
    const int64_t multiplier = dsdBitsPerSecond / 44'100;
    switch (multiplier) {
        case 64:
        case 128:
        case 256:
        case 512:
        case 1024:
            return static_cast<int32_t>(multiplier);
        default:
            return 0;
    }
}

void sleepBriefly() {
    std::this_thread::sleep_for(std::chrono::milliseconds(3));
}

/* libavformat's file protocol expects UTF-8, so a Windows wchar_t path is converted here instead of
 * assuming the ANSI code page can express the user's folder name. */
std::string pathToUtf8(const wchar_t *path) {
    std::string text;
    if (path == nullptr || !wideStringToUtf8(path, text)) return {};
    return text;
}

}  // namespace

int readerPacketCallback(void *opaque, uint8_t *buffer, int bufferSize) {
    auto *source = static_cast<AudioSource *>(opaque);
    return source->readFromSource(buffer, bufferSize);
}

int64_t readerSeekCallback(void *opaque, int64_t offset, int whence) {
    auto *source = static_cast<AudioSource *>(opaque);
    return source->seekInSource(offset, whence);
}

int dffPacketCallback(void *opaque, uint8_t *buffer, int bufferSize) {
    auto *source = static_cast<AudioSource *>(opaque);
    return source->readFromDff(buffer, bufferSize);
}

int64_t dffSeekCallback(void *opaque, int64_t offset, int whence) {
    auto *source = static_cast<AudioSource *>(opaque);
    return source->seekInDff(offset, whence);
}

AudioSource::AudioSource(LogProxy *log) : log_(log) {}

AudioSource::~AudioSource() {
    close();
}

int32_t AudioSource::openFile(const wchar_t *path, const LazerAudioOpenParams &params) {
    close();
    lastError_.clear();
    if (path == nullptr) return LazerAudioErrorInvalidArgument;
    if (DffDsfReader::hasDffMagic(path)) {
        const int32_t result = dffReader_.openFile(path, lastError_);
        if (result != LazerAudioOk) return result;
        if (dffReader_.isDst()) return openDffDst(params);
        return openDffAvio(params);
    }
    AVFormatContext *context = nullptr;
    /* FFmpeg opens the path itself, so a completed cache file is read with normal file I/O and no
     * callback crosses the JVM boundary. The URL is a Windows path, converted where the API layer
     * received it, and libavformat's file protocol takes UTF-8. */
    const std::string utf8Path = pathToUtf8(path);
    if (utf8Path.empty()) {
        lastError_ = "the file path could not be encoded for FFmpeg";
        return LazerAudioErrorInvalidArgument;
    }
    const int result = avformat_open_input(&context, utf8Path.c_str(), nullptr, nullptr);
    if (result < 0 || context == nullptr) {
        lastError_ = formatContextError(result);
        return LazerAudioErrorSource;
    }
    format_ = FormatContext(context);
    return openCommon(params);
}

int32_t AudioSource::prepareReader(const LazerAudioReader &reader) {
    close();
    lastError_.clear();
    if (reader.read == nullptr) {
        lastError_ = "audio reader has no read callback";
        return LazerAudioErrorInvalidArgument;
    }
    {
        std::lock_guard guard(readerCallbackMutex_);
        reader_ = &reader;
        readerCancelInvoked_ = false;
        readerCloseInvoked_ = false;
        readerCancelInFlight_ = false;
    }
    return LazerAudioOk;
}

int32_t AudioSource::openReader(
    const LazerAudioReader &reader, const LazerAudioOpenParams &params) {
    bool alreadyPrepared = false;
    bool alreadyCancelled = false;
    {
        std::lock_guard guard(readerCallbackMutex_);
        alreadyPrepared = reader_ == &reader;
        alreadyCancelled = alreadyPrepared && readerCancelInvoked_;
    }
    if (!alreadyPrepared) {
        const int32_t prepared = prepareReader(reader);
        if (prepared != LazerAudioOk) return prepared;
    } else {
        lastError_.clear();
    }
    if (alreadyCancelled) {
        lastError_ = "audio reader was cancelled before stream opening began";
        close();
        return LazerAudioErrorCancelled;
    }

    /* Peek only four bytes so DFF can use its random-access adapter. For ordinary non-seekable
     * readers the bytes are replayed to AVIO below, so stream input keeps its existing contract. */
    readerProbePrefix_.clear();
    readerProbePrefixOffset_ = 0;
    readerProbePrefix_.resize(4);
    const int64_t sourceLength = reader.length != nullptr ? reader.length(reader.context) : -1;
    const bool knownLengthHasHeader = sourceLength >= 16;
    int zeroReadRetries = 0;
    constexpr int kReaderProbeZeroReadRetries = 100;
    while (readerProbePrefix_.size() > 0 && readerProbePrefixOffset_ < 4) {
        const int32_t remaining = static_cast<int32_t>(4 - readerProbePrefixOffset_);
        const int32_t count = reader.read(reader.context,
            readerProbePrefix_.data() + readerProbePrefixOffset_, remaining);
        if (count < 0) {
            if (count != LAZER_AUDIO_READER_EOF) {
                lastError_ = "audio reader reported an I/O error while probing its header";
                close();
                return LazerAudioErrorSource;
            }
            readerEnded_ = true;
            break;
        }
        if (count == 0) {
            if (!knownLengthHasHeader && ++zeroReadRetries >= kReaderProbeZeroReadRetries) break;
            sleepBriefly();
            continue;
        }
        if (count > remaining) {
            lastError_ = "audio reader returned more bytes than requested while probing the format";
            close();
            return LazerAudioErrorSource;
        }
        readerProbePrefixOffset_ += static_cast<size_t>(count);
        zeroReadRetries = 0;
    }
    readerProbePrefix_.resize(readerProbePrefixOffset_);
    readerProbePrefixOffset_ = 0;
    readerPosition_ = static_cast<int64_t>(readerProbePrefix_.size());
    readerPositionSnapshot_.store(readerPosition_, std::memory_order_release);
    const bool canReadDff = reader.seek != nullptr && sourceLength >= 16;
    if (canReadDff && readerProbePrefix_.size() < 4 &&
        (sourceLength >= 4 || readerEnded_)) {
        lastError_ = "audio reader could not provide a complete format header";
        close();
        return LazerAudioErrorSource;
    }
    const bool isDff = readerProbePrefix_.size() == 4 &&
        std::memcmp(readerProbePrefix_.data(), "FRM8", 4) == 0;
    if (isDff) {
        if (reader.seek == nullptr || reader.length == nullptr ||
            reader.seek(reader.context, 0) != 0) {
            lastError_ = "DFF reader input requires absolute seek and a known length";
            close();
            return LazerAudioErrorUnsupported;
        }
        readerEnded_ = false;
        readerPosition_ = 0;
        readerPositionSnapshot_.store(0, std::memory_order_release);
        readerProbePrefix_.clear();
        const int32_t result = dffReader_.openReader(&reader, lastError_);
        if (result != LazerAudioOk) {
            close();
            return result;
        }
        if (dffReader_.isDst()) return openDffDst(params);
        return openDffAvio(params);
    }
    if (reader.seek != nullptr && reader.seek(reader.context, 0) == 0) {
        readerProbePrefix_.clear();
        readerPosition_ = 0;
        readerPositionSnapshot_.store(0, std::memory_order_release);
        readerEnded_ = false;
    }

    uint8_t *buffer = static_cast<uint8_t *>(av_malloc(kAvioBufferSize));
    if (buffer == nullptr) {
        lastError_ = "out of memory allocating the read buffer";
        close();
        return LazerAudioErrorNoMemory;
    }
    avio_ = avio_alloc_context(
        buffer, kAvioBufferSize, 0, this, &readerPacketCallback, nullptr, &readerSeekCallback);
    if (avio_ == nullptr) {
        av_free(buffer);
        lastError_ = "out of memory allocating the IO context";
        close();
        return LazerAudioErrorNoMemory;
    }
    avioBuffer_ = buffer;

    AVFormatContext *context = avformat_alloc_context();
    if (context == nullptr) {
        releaseAvio();
        lastError_ = "out of memory allocating the demuxer";
        close();
        return LazerAudioErrorNoMemory;
    }
    context->pb = avio_;
    context->flags |= AVFMT_FLAG_CUSTOM_IO;
    /* Probing reads a few kilobytes through the caller's stream, so a growing cache file is already
     * usable: the download thread keeps the read unblocked until real bytes land. */
    readerOpening_ = true;
    AVFormatContext *opened = context;
    const int result = avformat_open_input(&opened, nullptr, nullptr, nullptr);
    if (result < 0 || opened == nullptr) {
        /* A failed open frees the format context but never the custom AVIO, which stays ours. */
        const bool readerFailed = readerFailed_;
        releaseAvio();
        lastError_ = readerFailed
            ? "audio reader reported an I/O error while opening the media stream"
            : formatContextError(result);
        close();
        return LazerAudioErrorSource;
    }
    format_ = FormatContext(opened);
    /* A custom IO context stays ours: libavformat marks the stream as caller-owned and leaves the
     * AVIOContext alone on close, so avio_ keeps pointing at what we allocated. */
    const int32_t commonResult = openCommon(params);
    readerOpening_ = false;
    return commonResult;
}

int32_t AudioSource::openDffAvio(const LazerAudioOpenParams &params) {
    if (params.cue_start_frame75 != 0 || params.cue_end_frame75 != 0) {
        lastError_ = "CUE segments do not support DSD input";
        return LazerAudioErrorUnsupported;
    }
    const AVInputFormat *dsf = av_find_input_format("dsf");
    if (dsf == nullptr) {
        lastError_ = "FFmpeg was built without the DSF demuxer required by the DFF adapter";
        close();
        return LazerAudioErrorUnsupported;
    }
    uint8_t *buffer = static_cast<uint8_t *>(av_malloc(kAvioBufferSize));
    if (buffer == nullptr) {
        lastError_ = "out of memory allocating the DFF read buffer";
        close();
        return LazerAudioErrorNoMemory;
    }
    avio_ = avio_alloc_context(
        buffer, kAvioBufferSize, 0, this, &dffPacketCallback, nullptr, &dffSeekCallback);
    if (avio_ == nullptr) {
        av_free(buffer);
        lastError_ = "out of memory allocating the DFF IO context";
        close();
        return LazerAudioErrorNoMemory;
    }
    avioBuffer_ = buffer;

    AVFormatContext *context = avformat_alloc_context();
    if (context == nullptr) {
        lastError_ = "out of memory allocating the DFF demuxer";
        close();
        return LazerAudioErrorNoMemory;
    }
    context->pb = avio_;
    context->flags |= AVFMT_FLAG_CUSTOM_IO;
    AVFormatContext *opened = context;
    const int result = avformat_open_input(&opened, nullptr, dsf, nullptr);
    if (result < 0 || opened == nullptr) {
        releaseAvio();
        lastError_ = "the virtual DSF stream could not be opened: " + formatContextError(result);
        close();
        return LazerAudioErrorSource;
    }
    format_ = FormatContext(opened);
    const int32_t commonResult = openCommon(params);
    if (commonResult == LazerAudioOk && description_.dsd && description_.rawDsd) {
        const int64_t bitCount = dffReader_.rawDsdBitCount();
        if (bitCount > 0) setExactDsdDuration(bitCount, dffReader_.bitRate());
    }
    return commonResult;
}

int32_t AudioSource::openDffDst(const LazerAudioOpenParams &params) {
    if (params.cue_start_frame75 != 0 || params.cue_end_frame75 != 0) {
        lastError_ = "CUE segments do not support DSD input";
        return LazerAudioErrorUnsupported;
    }
    const uint32_t bitRate = dffReader_.bitRate();
    const int32_t channels = dffReader_.channels();
    if (bitRate % 8 != 0 || channels <= 0 || dffReader_.dstFrameRate() != 75 ||
        dffReader_.dstFrameCount() == 0) {
        lastError_ = "DFF DST metadata is incomplete";
        close();
        return LazerAudioErrorSource;
    }
    const uint32_t sampleRate = bitRate / 8;
    const int32_t multiplier = dsdMultiplierForSampleRate(static_cast<int32_t>(sampleRate));
    if (multiplier == 0) {
        lastError_ = "DFF DST rate is outside the supported DSD64–DSD1024 rates";
        close();
        return LazerAudioErrorUnsupported;
    }
    if (sampleRate % dffReader_.dstFrameRate() != 0 ||
        sampleRate / dffReader_.dstFrameRate() > static_cast<uint32_t>(INT_MAX)) {
        lastError_ = "DFF DST frame timing cannot be represented by the current decoder";
        close();
        return LazerAudioErrorUnsupported;
    }

    dstDffMode_ = true;
    dstDecodedToPcm_ = true;
    dstSamplesPerFrame_ = static_cast<int32_t>(sampleRate / dffReader_.dstFrameRate());
    inputTimeBase_ = AVRational{1, static_cast<int>(sampleRate)};
    const int32_t decoderResult = configureDstDecoder();
    if (decoderResult != LazerAudioOk) {
        close();
        return decoderResult;
    }

    description_.codec = "dst";
    description_.sampleRate = static_cast<int32_t>(sampleRate);
    description_.channels = channels;
    description_.bitsPerSample = 0;
    description_.dsd = true;
    description_.dsdRateMultiplier = multiplier;
    description_.bitrateKbps = 0;
    description_.lossless = true;
    description_.integerPcm = false;
    description_.canonicalChannelLayout = channels == 1 || channels == 2;
    description_.decoderFormatMatchesStream = false;
    description_.durationMillis = static_cast<int64_t>(dffReader_.dstFrameCount()) * 1000 / 75;
    description_.durationSamples = static_cast<int64_t>(dffReader_.dstFrameCount()) *
        dstSamplesPerFrame_;

    durationHintMillis_ = params.duration_hint_millis > 0 ? params.duration_hint_millis : 0;
    fileSizeBytes_ = -1;
    if (target_.sampleRate <= 0 || target_.channels <= 0) {
        target_.sampleRate = 44'100;
        target_.channels = channels;
    }
    const int32_t resamplerResult = configureResampler();
    if (resamplerResult != LazerAudioOk) {
        close();
        return resamplerResult;
    }

    seekBaseMillis_.store(std::max<int64_t>(0, params.start_millis), std::memory_order_release);
    producedFrames_.store(0, std::memory_order_release);
    endOfStream_.store(false, std::memory_order_release);
    if (params.start_millis > 0) {
        seekRequest_.store(params.start_millis, std::memory_order_release);
    }
    return LazerAudioOk;
}

int32_t AudioSource::configureDstDecoder() {
    const AVCodec *descriptor = avcodec_find_decoder(AV_CODEC_ID_DST);
    if (descriptor == nullptr) {
        lastError_ = "FFmpeg was built without the DST decoder";
        return LazerAudioErrorUnsupported;
    }
    AVCodecContext *context = avcodec_alloc_context3(descriptor);
    if (context == nullptr) {
        lastError_ = "out of memory allocating the DST decoder context";
        return LazerAudioErrorNoMemory;
    }
    context->codec_id = AV_CODEC_ID_DST;
    context->sample_rate = static_cast<int>(dffReader_.bitRate() / 8);
    context->pkt_timebase = AVRational{1, context->sample_rate};
    av_channel_layout_default(&context->ch_layout, dffReader_.channels());
    const int result = avcodec_open2(context, descriptor, nullptr);
    if (result < 0) {
        avcodec_free_context(&context);
        lastError_ = "could not initialise the FFmpeg DST decoder: " + formatContextError(result);
        return LazerAudioErrorDecode;
    }
    if (context->sample_fmt != AV_SAMPLE_FMT_FLT) {
        avcodec_free_context(&context);
        lastError_ = "the FFmpeg DST decoder did not produce float PCM";
        return LazerAudioErrorUnsupported;
    }
    codecDescriptor_ = descriptor;
    codec_ = CodecContext(context);
    return LazerAudioOk;
}

int32_t AudioSource::reopenDstDecoder() {
    codec_.reset();
    codecDescriptor_ = nullptr;
    return configureDstDecoder();
}

int32_t AudioSource::openCommon(const LazerAudioOpenParams &params) {
    AVFormatContext *context = format_.get();
    /* A bounded probe keeps the first audible frame close to the requested position while still
     * covering the header spread of CBR VBR and ID3-heavy MP3 and FLAC files. */
    context->probesize = 5 * 1024 * 1024;
    context->max_analyze_duration = 5 * AV_TIME_BASE;

    int result = avformat_find_stream_info(context, nullptr);
    if (result < 0) {
        const bool readerFailed = readerFailed_;
        lastError_ = readerFailed
            ? "audio reader reported an I/O error while probing the media stream"
            : formatContextError(result);
        close();
        return readerFailed ? LazerAudioErrorSource : LazerAudioErrorDecode;
    }

    const int streamIndex = av_find_best_stream(context, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
    if (streamIndex < 0) {
        lastError_ = "the file holds no audio stream";
        close();
        return LazerAudioErrorUnsupported;
    }
    audioStream_ = context->streams[streamIndex];
    inputTimeBase_ = audioStream_->time_base;

    result = configureDecoder();
    if (result != LazerAudioOk) {
        close();
        return result;
    }

    durationHintMillis_ = params.duration_hint_millis > 0 ? params.duration_hint_millis : 0;
    int64_t durationMillis = 0;
    if (context->duration > 0) {
        durationMillis = context->duration / (AV_TIME_BASE / 1000);
    } else if (audioStream_->duration > 0 && audioStream_->time_base.den > 0) {
        durationMillis = av_rescale_q(audioStream_->duration, audioStream_->time_base, kMillisTimeBase);
    }
    if (durationMillis <= 0) durationMillis = durationHintMillis_;

    const AVCodecParameters *parameters = audioStream_->codecpar;
    description_.codec = codecDescriptor_ != nullptr ? codecDescriptor_->name : "unknown";
    description_.dsd = isDsdCodec(parameters->codec_id);
    description_.rawDsd = description_.dsd && codec_->sample_fmt == AV_SAMPLE_FMT_DSD;
    description_.sampleRate = parameters->sample_rate > 0
        ? parameters->sample_rate : codec_->sample_rate;
    description_.channels = parameters->ch_layout.nb_channels > 0
        ? parameters->ch_layout.nb_channels : codec_->ch_layout.nb_channels;
    if (description_.dsd) {
        description_.bitsPerSample = 0;
    } else if (parameters->bits_per_raw_sample > 0) {
        description_.bitsPerSample = parameters->bits_per_raw_sample;
    } else if (parameters->bits_per_coded_sample > 0) {
        description_.bitsPerSample = parameters->bits_per_coded_sample;
    } else {
        description_.bitsPerSample = bitsPerRawSample(codec_.get(), nullptr);
    }
    if (description_.dsd) {
        description_.dsdRateMultiplier = dsdMultiplierForSampleRate(description_.sampleRate);
        if (description_.dsdRateMultiplier == 0) {
            lastError_ = "unsupported DSD rate; supported rates are DSD64 through DSD1024";
            close();
            return LazerAudioErrorUnsupported;
        }
        /* Keep DSD bytes as DSD until libswresample explicitly converts them. A decoder that emits
         * any other format is not allowed to flow into the generic PCM pipeline. */
        if (codec_->sample_fmt != AV_SAMPLE_FMT_DSD) {
            lastError_ = "the FFmpeg DSD decoder did not preserve the DSD bitstream";
            close();
            return LazerAudioErrorUnsupported;
        }
    }
    const AVSampleFormat packedSampleFormat = av_get_packed_sample_fmt(codec_->sample_fmt);
    description_.integerPcm = packedSampleFormat == AV_SAMPLE_FMT_U8 ||
        packedSampleFormat == AV_SAMPLE_FMT_S16 || packedSampleFormat == AV_SAMPLE_FMT_S32;
    const bool decoderDepthMatchesStream =
        (description_.bitsPerSample == 16 && packedSampleFormat == AV_SAMPLE_FMT_S16) ||
        ((description_.bitsPerSample == 24 || description_.bitsPerSample == 32) &&
            packedSampleFormat == AV_SAMPLE_FMT_S32);
    const AVChannelLayout &streamLayout = parameters->ch_layout.nb_channels > 0
        ? parameters->ch_layout : codec_->ch_layout;
    AVChannelLayout canonicalLayout{};
    av_channel_layout_default(&canonicalLayout, description_.channels);
    const bool implicitLayout = streamLayout.nb_channels <= 0 ||
        streamLayout.order == AV_CHANNEL_ORDER_UNSPEC;
    description_.canonicalChannelLayout = implicitLayout
        ? description_.channels == 1 || description_.channels == 2
        : av_channel_layout_compare(&canonicalLayout, &streamLayout) == 0;
    const bool decoderLayoutMatchesStream = codec_->ch_layout.nb_channels <= 0 ||
        codec_->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC || streamLayout.nb_channels <= 0 ||
        streamLayout.order == AV_CHANNEL_ORDER_UNSPEC ||
        av_channel_layout_compare(&codec_->ch_layout, &streamLayout) == 0;
    description_.decoderFormatMatchesStream = decoderDepthMatchesStream &&
        codec_->sample_rate == description_.sampleRate &&
        (codec_->ch_layout.nb_channels <= 0 ||
            codec_->ch_layout.nb_channels == description_.channels) && decoderLayoutMatchesStream;
    av_channel_layout_uninit(&canonicalLayout);
    const int64_t bitRate = parameters->bit_rate > 0
        ? parameters->bit_rate
        : (context->bit_rate > 0 ? context->bit_rate : 0);
    description_.bitrateKbps = static_cast<int32_t>(bitRate / 1000);
    description_.lossless = description_.dsd || codecIsLossless(codecDescriptor_);
    description_.durationMillis = durationMillis;
    if (audioStream_->duration > 0 && audioStream_->time_base.num > 0 &&
        audioStream_->time_base.den > 0) {
        description_.durationSamples = av_rescale_q_rnd(audioStream_->duration,
            audioStream_->time_base, AVRational{1, description_.sampleRate}, AV_ROUND_NEAR_INF);
    }

    if (description_.sampleRate <= 0 || description_.channels <= 0) {
        lastError_ = "the audio stream reports no sample rate or channel count";
        close();
        return LazerAudioErrorUnsupported;
    }

    const bool cueParamsPresent = params.cue_start_frame75 != 0 ||
        params.cue_end_frame75 != 0;
    if (cueParamsPresent) {
        const char *formatName = context->iformat != nullptr ? context->iformat->name : nullptr;
        const bool supportedContainer = formatName != nullptr &&
            (std::strcmp(formatName, "wav") == 0 || std::strcmp(formatName, "flac") == 0);
        const bool supportedCodec = parameters->codec_id == AV_CODEC_ID_FLAC ||
            (codecDescriptor_ != nullptr && codecDescriptor_->name != nullptr &&
                std::strncmp(codecDescriptor_->name, "pcm_", 4) == 0);
        if (!supportedContainer || !supportedCodec || description_.dsd || !description_.lossless) {
            lastError_ = "CUE segments currently require lossless PCM WAV or FLAC input";
            close();
            return LazerAudioErrorUnsupported;
        }
        if (params.cue_start_frame75 < 0 || params.cue_end_frame75 < -1 ||
            (params.cue_end_frame75 != -1 &&
                params.cue_end_frame75 <= params.cue_start_frame75)) {
            lastError_ = "CUE segment frame range is malformed";
            close();
            return LazerAudioErrorInvalidArgument;
        }
        if (audioStream_->duration <= 0 || audioStream_->time_base.num <= 0 ||
            audioStream_->time_base.den <= 0) {
            lastError_ = "CUE segment input has no authoritative decoded sample count";
            close();
            return LazerAudioErrorUnsupported;
        }
        physicalSampleCount_ = av_rescale_q_rnd(audioStream_->duration,
            audioStream_->time_base, AVRational{1, description_.sampleRate}, AV_ROUND_NEAR_INF);
        if (physicalSampleCount_ <= 0) {
            lastError_ = "CUE segment input reports an invalid physical sample count";
            close();
            return LazerAudioErrorUnsupported;
        }
        const AVRational frame75TimeBase{1, 75};
        if (av_compare_ts(params.cue_start_frame75, frame75TimeBase,
                physicalSampleCount_, AVRational{1, description_.sampleRate}) >= 0) {
            lastError_ = "CUE segment starts at or beyond physical media EOF";
            close();
            return LazerAudioErrorInvalidArgument;
        }
        if (params.cue_end_frame75 > 0 && av_compare_ts(params.cue_end_frame75,
                frame75TimeBase, physicalSampleCount_,
                AVRational{1, description_.sampleRate}) > 0) {
            lastError_ = "CUE segment end is beyond physical media EOF";
            close();
            return LazerAudioErrorInvalidArgument;
        }

        cueSegmentMode_ = true;
        cueStartSample_ = av_rescale_q_rnd(params.cue_start_frame75,
            frame75TimeBase, AVRational{1, description_.sampleRate}, AV_ROUND_NEAR_INF);
        cueEndSample_ = params.cue_end_frame75 == -1 ? physicalSampleCount_
            : std::min<int64_t>(physicalSampleCount_, av_rescale_q_rnd(
                params.cue_end_frame75, frame75TimeBase,
                AVRational{1, description_.sampleRate}, AV_ROUND_NEAR_INF));
        if (cueStartSample_ < 0 || cueStartSample_ >= cueEndSample_) {
            lastError_ = "CUE segment is shorter than one decoded sample";
            close();
            return LazerAudioErrorInvalidArgument;
        }
    description_.durationMillis = av_rescale_q(
        cueEndSample_ - cueStartSample_, AVRational{1, description_.sampleRate},
        kMillisTimeBase);
    description_.durationSamples = cueEndSample_ - cueStartSample_;
    } else {
        cueSegmentMode_ = false;
        physicalSampleCount_ = 0;
    }

    if (format_->pb != nullptr) {
        const int64_t size = avio_size(format_->pb);
        fileSizeBytes_ = size > 0 ? size : -1;
        const int64_t position = avio_tell(format_->pb);
        readerPositionSnapshot_.store(std::max<int64_t>(position, 0),
            std::memory_order_release);
    }

    if (target_.sampleRate <= 0 || target_.channels <= 0) {
        TargetFormat initial;
        initial.sampleRate = description_.sampleRate;
        initial.channels = description_.channels;
        /* The engine normally installs a target before opening; a float target keeps the fallback
         * path inside the same DSP pipeline the UI expects. */
        target_ = initial;
    }
    result = configureResampler();
    if (result != LazerAudioOk) {
        close();
        return result;
    }

    cueBoundaryReached_ = false;
    cueSeekTargetSample_ = cueSegmentMode_
        ? cueStartSample_ + av_rescale_q_rnd(std::max<int64_t>(0, params.start_millis),
            kMillisTimeBase, AVRational{1, description_.sampleRate}, AV_ROUND_NEAR_INF)
        : 0;
    if (cueSegmentMode_) cueSeekTargetSample_ = std::clamp(
        cueSeekTargetSample_, cueStartSample_, cueEndSample_);
    seekBaseMillis_.store(std::max<int64_t>(0, params.start_millis), std::memory_order_release);
    producedFrames_.store(0, std::memory_order_release);
    endOfStream_.store(false, std::memory_order_release);
    if (cueSegmentMode_ || params.start_millis > 0) {
        seekRequest_.store(params.start_millis, std::memory_order_release);
    }
    return LazerAudioOk;
}

int32_t AudioSource::configureDecoder() {
    AVCodecContext *context = avcodec_alloc_context3(nullptr);
    if (context == nullptr) {
        lastError_ = "out of memory allocating the codec context";
        return LazerAudioErrorNoMemory;
    }
    int result = avcodec_parameters_to_context(context, audioStream_->codecpar);
    if (result < 0) {
        avcodec_free_context(&context);
        lastError_ = formatContextError(result);
        return LazerAudioErrorDecode;
    }
    context->pkt_timebase = audioStream_->time_base;

    const AVCodecID codecId = context->codec_id;
    const bool dsdCodec = isDsdCodec(codecId);
    if (codecId == AV_CODEC_ID_DST) {
        avcodec_free_context(&context);
        lastError_ = "DST-compressed DSD is not supported by the current PCM conversion path";
        return LazerAudioErrorUnsupported;
    }
#if LIBAVCODEC_VERSION_MAJOR < 64
    if (dsdCodec) {
        /* FFmpeg 63 otherwise selects a legacy in-decoder DSD->PCM route by default. Preserve the
         * bitstream and make the single explicit DSD->PCM conversion in our resampler instead. */
        context->request_sample_fmt = AV_SAMPLE_FMT_DSD;
    }
#endif
    const AVCodec *descriptor = avcodec_find_decoder(codecId);
    if (descriptor == nullptr) {
        avcodec_free_context(&context);
        lastError_ = "no decoder for codec id " + std::to_string(static_cast<int>(codecId));
        return LazerAudioErrorUnsupported;
    }
    result = avcodec_open2(context, descriptor, nullptr);
    if (result < 0) {
        avcodec_free_context(&context);
        lastError_ = formatContextError(result);
        return LazerAudioErrorDecode;
    }
    codecDescriptor_ = descriptor;
    codec_ = CodecContext(context);
    return LazerAudioOk;
}

int32_t AudioSource::configureResampler() {
    resampler_.reset();
    if (codec_ == nullptr) {
        lastError_ = "no decoder to resample from";
        return LazerAudioErrorDecode;
    }

    if (target_.doP && target_.nativeDsd) {
        lastError_ = "DoP and Native DSD are separate output formats";
        return LazerAudioErrorInvalidArgument;
    }

    if (target_.nativeDsdRawBytes) {
        if (target_.doP || target_.nativeDsd || !description_.dsd || !description_.rawDsd ||
            dstDecodedToPcm_ || codec_->sample_fmt != AV_SAMPLE_FMT_DSD ||
            target_.channels != description_.channels ||
            (description_.channels != 1 && description_.channels != 2) ||
            target_.sampleRate != description_.sampleRate || target_.bitsPerSample != 8 ||
            target_.containerBitsPerSample != 8 ||
            dsdMultiplierForSampleRate(description_.sampleRate) !=
                description_.dsdRateMultiplier) {
            lastError_ = "raw Native DSD queue staging requires exact interleaved DSD byte frames";
            return LazerAudioErrorUnsupported;
        }
        return LazerAudioOk;
    }

    if (target_.nativeDsd) {
        const size_t wordBytes = static_cast<size_t>(target_.containerBitsPerSample / 8);
        const int32_t supportedMultipliers[] = {64, 128, 256, 512, 1024};
        if (!description_.dsd || !description_.rawDsd || dstDecodedToPcm_ ||
            codec_->sample_fmt != AV_SAMPLE_FMT_DSD || target_.channels != description_.channels ||
            (description_.channels != 1 && description_.channels != 2) ||
            std::find(std::begin(supportedMultipliers), std::end(supportedMultipliers),
                description_.dsdRateMultiplier) == std::end(supportedMultipliers) ||
            static_cast<int64_t>(description_.sampleRate) * 8 !=
                static_cast<int64_t>(44'100) * description_.dsdRateMultiplier ||
            (wordBytes != 1 && wordBytes != 2 && wordBytes != 4) ||
            target_.bitsPerSample != static_cast<int32_t>(wordBytes * 8) ||
            target_.containerBitsPerSample != target_.bitsPerSample ||
            static_cast<int64_t>(target_.sampleRate) * wordBytes != description_.sampleRate) {
            lastError_ = "Native DSD requires raw mono/stereo DSD and the exact ALSA DSD word clock";
            return LazerAudioErrorUnsupported;
        }
        nativeDsdPacker_ = NativeDsdPacker(static_cast<size_t>(description_.channels),
            wordBytes, target_.nativeDsdBigEndian);
        return LazerAudioOk;
    }

    if (target_.doP) {
        if (!description_.dsd || !description_.rawDsd || dstDecodedToPcm_ ||
            codec_->sample_fmt != AV_SAMPLE_FMT_DSD || target_.bitsPerSample != 24 ||
            (target_.containerBitsPerSample != 0 && target_.containerBitsPerSample != 24) ||
            target_.channels != description_.channels || target_.sampleRate <= 0 ||
            target_.sampleRate * 2 != description_.sampleRate ||
            (description_.channels != 1 && description_.channels != 2)) {
            lastError_ = "DoP requires raw mono/stereo DSD and an exact 24-bit carrier at half the DSD byte clock";
            return LazerAudioErrorUnsupported;
        }
        target_.containerBitsPerSample = 24;
        dopPacker_ = DopPacker(static_cast<size_t>(description_.channels));
        return LazerAudioOk;
    }

    /* The decoder's layout is borrowed, so a defaulted stand-in is used when a container left it
     * unset; av_channel_layout_default initialises both and both are uninitialised again here. */
    AVChannelLayout outputLayout{};
    av_channel_layout_default(&outputLayout, std::max(target_.channels, 1));
    AVChannelLayout inputLayout = codec_->ch_layout;
    bool ownedInputLayout = false;
    if (inputLayout.nb_channels <= 0) {
        av_channel_layout_default(&inputLayout, std::max(description_.channels, 1));
        ownedInputLayout = true;
    }

    SwrContext *context = nullptr;
    int result = swr_alloc_set_opts2(&context, &outputLayout, target_.avFormat(),
        target_.sampleRate, &inputLayout, codec_->sample_fmt, codec_->sample_rate, 0, nullptr);
    av_channel_layout_uninit(&outputLayout);
    if (ownedInputLayout) av_channel_layout_uninit(&inputLayout);
    if (result < 0 || context == nullptr) {
        lastError_ = formatContextError(result < 0 ? result : AVERROR(ENOMEM));
        return LazerAudioErrorDecode;
    }
    result = swr_init(context);
    if (result < 0) {
        swr_free(&context);
        lastError_ = formatContextError(result);
        return LazerAudioErrorDecode;
    }
    resampler_ = ResampleContext(context);
    return LazerAudioOk;
}

int32_t AudioSource::setTargetFormat(TargetFormat format) {
    if (format.sampleRate <= 0) {
        format.sampleRate = description_.sampleRate > 0 ? description_.sampleRate : 44100;
    }
    if (format.channels <= 0) {
        format.channels = description_.channels > 0 ? description_.channels : 2;
    }
    target_ = format;
    if (target_.nativeDsd) target_.doP = false;
    /* Called from the control path only while the pump is parked; the engine rebuilds the resampler
     * before the next block reaches the ring. */
    if (codec_ != nullptr) {
        const int32_t result = configureResampler();
        if (result != LazerAudioOk) {
            if (log_ != nullptr) log_->write(LazerAudioLogError, "resampler rebuild failed: " + lastError_);
            return result;
        }
    }
    return LazerAudioOk;
}

void AudioSource::requestSeek(int64_t positionMillis) {
    seekRequest_.store(std::max<int64_t>(0, positionMillis), std::memory_order_release);
}

void AudioSource::setExactDsdDuration(int64_t dsdBitCount, int64_t dsdBitRate) noexcept {
    if (!description_.dsd || !description_.rawDsd || dsdBitCount <= 0 || dsdBitRate <= 0 ||
        dsdBitRate > std::numeric_limits<int>::max() || description_.sampleRate <= 0) return;
    exactDsdBitCount_ = dsdBitCount;
    exactDsdBitRate_ = dsdBitRate;
    description_.durationSamples = av_rescale_q_rnd(dsdBitCount,
        AVRational{1, static_cast<int>(dsdBitRate)},
        AVRational{1, description_.sampleRate}, AV_ROUND_NEAR_INF);
    description_.durationMillis = av_rescale_q_rnd(dsdBitCount,
        AVRational{1, static_cast<int>(dsdBitRate)}, kMillisTimeBase, AV_ROUND_NEAR_INF);
}

int64_t AudioSource::totalOutputFrames() const noexcept {
    if (exactDsdBitCount_ > 0 && exactDsdBitRate_ > 0 && target_.sampleRate > 0) {
        return av_rescale_q_rnd(exactDsdBitCount_,
            AVRational{1, static_cast<int>(exactDsdBitRate_)},
            AVRational{1, target_.sampleRate}, AV_ROUND_NEAR_INF);
    }
    if (description_.durationSamples <= 0 || description_.sampleRate <= 0 ||
        target_.sampleRate <= 0) return 0;
    return av_rescale_q_rnd(description_.durationSamples,
        AVRational{1, description_.sampleRate}, AVRational{1, target_.sampleRate},
        AV_ROUND_NEAR_INF);
}

int32_t AudioSource::applySeek(int64_t positionMillis) {
    if (dstDffMode_) {
        /* The DST decoder's PCM low-pass filter has state. Start a fresh decoder two seconds early,
         * then trim to the first output sample on the same source/output clock grid as linear play. */
        constexpr int64_t kDsdSeekPrerollMillis = 2'000;
        const int64_t demuxSeekMillis = std::max<int64_t>(0,
            positionMillis - kDsdSeekPrerollMillis);
        const int64_t requestedFrame = av_rescale_q(
            demuxSeekMillis, kMillisTimeBase, AVRational{1, 75});
        if (requestedFrame < 0 || requestedFrame > dffReader_.dstFrameCount() ||
            !dffReader_.seekDstFrame(static_cast<uint32_t>(requestedFrame))) {
            lastError_ = dffReader_.lastError().empty()
                ? "DFF DST seek frame is outside the declared FRTE range"
                : dffReader_.lastError();
            return LazerAudioErrorSource;
        }
        int32_t result = reopenDstDecoder();
        if (result != LazerAudioOk) return result;
        result = configureResampler();
        if (result != LazerAudioOk) return result;
        endOfStream_.store(false, std::memory_order_release);
        producedFrames_.store(0, std::memory_order_release);
        seekBaseMillis_.store(positionMillis, std::memory_order_release);
        seekOutputTargetMillis_ = positionMillis;
        seekOutputFramesToDrop_ = -1;
        if (log_ != nullptr) {
            log_->write(LazerAudioLogDebug,
                "DST seek applied to " + std::to_string(positionMillis) + " ms");
        }
        return LazerAudioOk;
    }

    AVFormatContext *context = format_.get();
    if (context == nullptr || codec_ == nullptr) return LazerAudioErrorState;

    if (cueSegmentMode_) {
        const int64_t requestedOffset = av_rescale_q_rnd(
            std::max<int64_t>(0, positionMillis), kMillisTimeBase,
            AVRational{1, description_.sampleRate}, AV_ROUND_NEAR_INF);
        cueSeekTargetSample_ = std::min(cueStartSample_ + requestedOffset, cueEndSample_);
        const int64_t relativeSample = cueSeekTargetSample_ - cueStartSample_;
        const int64_t relativeMillis = av_rescale_q(
            relativeSample, AVRational{1, description_.sampleRate}, kMillisTimeBase);
        seekBaseMillis_.store(std::min(relativeMillis, description_.durationMillis),
            std::memory_order_release);
        producedFrames_.store(0, std::memory_order_release);
        endOfStream_.store(false, std::memory_order_release);
        cueBoundaryReached_ = cueSeekTargetSample_ >= cueEndSample_;
        seekOutputTargetMillis_ = -1;
        seekOutputFramesToDrop_ = -1;
        if (cueBoundaryReached_) {
            endOfStream_.store(true, std::memory_order_release);
            return LazerAudioOk;
        }
        const int64_t streamStart = audioStream_->start_time != AV_NOPTS_VALUE
            ? audioStream_->start_time : 0;
        const int64_t targetTimestamp = streamStart + av_rescale_q(cueSeekTargetSample_,
            AVRational{1, description_.sampleRate}, audioStream_->time_base);
        int cueSeekResult = av_seek_frame(context, audioStream_->index, targetTimestamp,
            AVSEEK_FLAG_BACKWARD);
        if (cueSeekResult < 0) {
            const int64_t absoluteMillis = av_rescale_q(targetTimestamp,
                audioStream_->time_base, kMillisTimeBase);
            cueSeekResult = av_seek_frame(context, -1,
                av_rescale_q(absoluteMillis, kMillisTimeBase, AV_TIME_BASE_Q),
                AVSEEK_FLAG_BACKWARD);
        }
        if (cueSeekResult < 0) {
            lastError_ = "CUE segment seek failed: " + formatContextError(cueSeekResult);
            return LazerAudioErrorSource;
        }
        avcodec_flush_buffers(codec_.get());
        if (resampler_ != nullptr) {
            const int initResult = swr_init(resampler_.get());
            if (initResult < 0) {
                lastError_ = "resampler could not reset for CUE segment seek: " +
                    formatContextError(initResult);
                return LazerAudioErrorDecode;
            }
        }
        if (avio_ != nullptr) avio_->eof_reached = 0;
        readerEnded_ = false;
        endOfStream_.store(false, std::memory_order_release);
        if (log_ != nullptr) {
            log_->write(LazerAudioLogDebug,
                "CUE segment seek applied to " + std::to_string(relativeMillis) + " ms");
        }
        return LazerAudioOk;
    }

    /* Give the DSD-to-PCM filter history time to warm up and reach a source sample whose converted
     * position aligns with the output frame grid. DSF seeks commonly land on coarse block starts;
     * a non-integer DSD/SRC ratio can otherwise change the resampler phase after a seek. */
    constexpr int64_t kDsdSeekPrerollMillis = 2'000;
    const int64_t demuxSeekMillis = description_.dsd
        ? std::max<int64_t>(0, positionMillis - kDsdSeekPrerollMillis)
        : positionMillis;
    int result = av_seek_frame(context, -1,
        av_rescale_q(demuxSeekMillis, kMillisTimeBase, AV_TIME_BASE_Q), AVSEEK_FLAG_BACKWARD);
    if (result < 0 && audioStream_ != nullptr) {
        /* Some containers only answer a stream-local seek, so retry against the audio stream. */
        result = av_seek_frame(
            context, audioStream_->index, av_rescale_q(demuxSeekMillis, kMillisTimeBase,
                audioStream_->time_base), AVSEEK_FLAG_BACKWARD);
    }
    if (result < 0) {
        lastError_ = "seek failed: " + formatContextError(result);
        return LazerAudioErrorSource;
    }
    avcodec_flush_buffers(codec_.get());
    if (target_.doP) dopPacker_.reset();
    if (target_.nativeDsd) nativeDsdPacker_.reset();
    if (resampler_ != nullptr) {
        /* Re-initialising drops the filter history, which is what a hard position change needs; a
         * carried-over delay would smear the first millisecond of the new location. */
        swr_init(resampler_.get());
    }
    if (avio_ != nullptr) {
        avio_->eof_reached = 0;
    }
    readerEnded_ = false;
    endOfStream_.store(false, std::memory_order_release);
    producedFrames_.store(0, std::memory_order_release);
    seekBaseMillis_.store(positionMillis, std::memory_order_release);
    seekOutputTargetMillis_ = description_.dsd ? positionMillis : -1;
    seekOutputFramesToDrop_ = -1;
    if (log_ != nullptr) {
        log_->write(
            LazerAudioLogDebug, "seek applied to " + std::to_string(positionMillis) + " ms");
    }
    return LazerAudioOk;
}

double AudioSource::bufferedFraction() const noexcept {
    if (fileSizeBytes_ <= 0) return 1.0;
    const int64_t position = readerPositionSnapshot_.load(std::memory_order_acquire);
    if (position <= 0) return 0.0;
    return std::clamp(
        static_cast<double>(position) / static_cast<double>(fileSizeBytes_), 0.0, 1.0);
}

int32_t AudioSource::pump(SourceConsumer &consumer) {
    AVFormatContext *context = format_.get();
    if ((!dstDffMode_ && context == nullptr) || codec_ == nullptr) return LazerAudioErrorState;

    AVPacket *packet = av_packet_alloc();
    if (packet == nullptr) {
        lastError_ = "out of memory allocating a packet";
        return LazerAudioErrorNoMemory;
    }

    int32_t outcome = LazerAudioOk;
    int consecutiveErrors = 0;
    while (!consumer.isCancelled()) {
        const int64_t pendingSeek = seekRequest_.exchange(-1, std::memory_order_acq_rel);
        if (pendingSeek >= 0) {
            const int32_t seeked = applySeek(pendingSeek);
            if (seeked != LazerAudioOk) {
                outcome = seeked;
                break;
            }
            consumer.onSeekApplied();
            if (cueBoundaryReached_) break;
        }
        if (!consumer.shouldPump()) {
            sleepBriefly();
            continue;
        }

        int readResult = AVERROR_EOF;
        if (dstDffMode_) {
            av_packet_unref(packet);
            uint32_t frameIndex = 0;
            const int32_t frameBytes = dffReader_.readDstFrame(dstFrameBytes_, frameIndex);
            if (frameBytes < 0) {
                lastError_ = dffReader_.lastError().empty()
                    ? "could not read the next DFF DST frame"
                    : dffReader_.lastError();
                outcome = LazerAudioErrorSource;
                break;
            }
            if (frameBytes > 0) {
                packet->data = dstFrameBytes_.data();
                packet->size = frameBytes;
                packet->pts = static_cast<int64_t>(frameIndex) * dstSamplesPerFrame_;
                packet->dts = packet->pts;
                packet->duration = dstSamplesPerFrame_;
                packet->stream_index = 0;
                readResult = 0;
            }
        } else {
            readResult = av_read_frame(context, packet);
            if (context->pb != nullptr) {
                const int64_t position = avio_tell(context->pb);
                readerPositionSnapshot_.store(std::max<int64_t>(position, 0),
                    std::memory_order_release);
            }
        }
        if (readResult == AVERROR_EOF) {
            if (readerFailed_) {
                if (lastError_.empty()) lastError_ = "audio reader reported an I/O error";
                outcome = LazerAudioErrorSource;
                break;
            }
            /* Flush whatever the decoder still holds, then report the real end. A caller stream that
             * has not finished downloading simply has not returned -1 yet, so it never lands here. */
            const int32_t decoderFlush = decodePacket(nullptr, consumer);
            if (decoderFlush != LazerAudioOk) {
                outcome = decoderFlush;
                break;
            }
            const int32_t resamplerFlush = drainResampler(consumer);
            if (resamplerFlush != LazerAudioOk) {
                outcome = resamplerFlush;
                break;
            }
            if (seekOutputTargetMillis_ >= 0) {
                /* The target can be at the known media end, where the demuxer has no later frame
                 * from which to establish the output alignment. Treat that position as clean EOF.
                 * For an in-range target, retain the unsupported result after flushing because a
                 * delayed decoder frame may still have supplied the required aligned preroll. */
                const bool targetAtOrPastEnd = description_.durationMillis > 0 &&
                    seekOutputTargetMillis_ >= description_.durationMillis;
                if (!targetAtOrPastEnd) {
                    lastError_ = "DSD seek reached EOF before finding an output-aligned preroll sample";
                    outcome = LazerAudioErrorUnsupported;
                    break;
                }
                seekOutputTargetMillis_ = -1;
                seekOutputFramesToDrop_ = -1;
            }
            if (target_.doP && dopPacker_.hasPendingInputFrame()) {
                const size_t carrierBytes = static_cast<size_t>(target_.frameBytes());
                packedScratch_.resize(carrierBytes);
                const DopPackResult flushed = dopPacker_.flush(packedScratch_.data(), 1);
                if (flushed.status != DopPackStatus::Ok || flushed.producedOutputFrames != 1) {
                    lastError_ = "the final unmatched DSD byte could not be padded into a DoP carrier";
                    outcome = LazerAudioErrorDecode;
                    break;
                }
                const int32_t delivered = deliverSamples(packedScratch_.data(), 1, consumer);
                if (delivered != LazerAudioOk) {
                    outcome = delivered;
                    break;
                }
            } else if (target_.nativeDsd && nativeDsdPacker_.hasPendingInput()) {
                const size_t frameBytes = static_cast<size_t>(target_.frameBytes());
                packedScratch_.resize(frameBytes);
                const NativeDsdPackResult flushed =
                    nativeDsdPacker_.flush(packedScratch_.data(), 1);
                if (flushed.status != NativeDsdPackStatus::Ok ||
                    flushed.producedOutputFrames != 1) {
                    lastError_ = "the final DSD bytes could not be padded into a native output word";
                    outcome = LazerAudioErrorDecode;
                    break;
                }
                const int32_t delivered = deliverSamples(packedScratch_.data(), 1, consumer);
                if (delivered != LazerAudioOk) {
                    outcome = delivered;
                    break;
                }
            }
            endOfStream_.store(true, std::memory_order_release);
            break;
        }
        if (readResult < 0) {
            if (readerFailed_) {
                if (lastError_.empty()) lastError_ = "audio reader reported an I/O error";
                outcome = LazerAudioErrorSource;
                break;
            }
            if (readResult == AVERROR(EAGAIN) || readResult == AVERROR_EXIT) {
                if (readResult == AVERROR_EXIT) break;
                sleepBriefly();
                continue;
            }
            lastError_ = "read failed: " + formatContextError(readResult);
            if (++consecutiveErrors > 8) {
                outcome = LazerAudioErrorSource;
                break;
            }
            continue;
        }
        consecutiveErrors = 0;

        if (!dstDffMode_ && packet->stream_index != audioStream_->index) {
            av_packet_unref(packet);
            continue;
        }
        const int32_t decoded = decodePacket(packet, consumer);
        av_packet_unref(packet);
        if (decoded < 0) {
            outcome = decoded;
            break;
        }
        if (cueBoundaryReached_) {
            const int32_t resamplerFlush = drainResampler(consumer);
            if (resamplerFlush != LazerAudioOk) {
                outcome = resamplerFlush;
                break;
            }
            endOfStream_.store(true, std::memory_order_release);
            break;
        }
    }

    av_packet_free(&packet);
    return outcome;
}

int32_t AudioSource::decodePacket(AVPacket *packet, SourceConsumer &consumer) {
    int result = avcodec_send_packet(codec_.get(), packet);
    if (result == AVERROR(EAGAIN)) {
        /* The decoder wants to drain first: run the receive loop below, which is exactly what it is
         * asking for, and the caller's next packet arrives with the queue cleared. */
        result = 0;
    } else if (result == AVERROR_EOF) {
        result = 0;
    } else if (result < 0) {
        lastError_ = "decode failed: " + formatContextError(result);
        return LazerAudioErrorDecode;
    }
    if (result < 0) {
        lastError_ = "decode failed: " + formatContextError(result);
        return LazerAudioErrorDecode;
    }

    while (!consumer.isCancelled()) {
        AudioFrame frame = AudioFrame::allocate();
        if (!frame) {
            lastError_ = "out of memory allocating a frame";
            return LazerAudioErrorNoMemory;
        }
        result = avcodec_receive_frame(codec_.get(), frame.get());
        if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
            return LazerAudioOk;
        }
        if (result < 0) {
            lastError_ = "decode failed: " + formatContextError(result);
            return LazerAudioErrorDecode;
        }
        const int32_t emitted = emitAVFrame(frame.get(), consumer);
        if (emitted < 0) return emitted;
        if (cueBoundaryReached_) return LazerAudioOk;
    }
    return LazerAudioOk;
}

int32_t AudioSource::emitAVFrame(AVFrame *frame, SourceConsumer &consumer) {
    if ((!target_.doP && !target_.nativeDsd && !target_.nativeDsdRawBytes &&
        resampler_ == nullptr) ||
        frame->nb_samples <= 0) return LazerAudioOk;
    if (description_.dsd &&
        ((dstDecodedToPcm_ ? frame->format != AV_SAMPLE_FMT_FLT
                           : frame->format != AV_SAMPLE_FMT_DSD) ||
            (frame->sample_rate > 0 && frame->sample_rate != description_.sampleRate) ||
            (frame->ch_layout.nb_channels > 0 &&
                frame->ch_layout.nb_channels != description_.channels))) {
        lastError_ = "the DSD decoder changed sample encoding, rate or channel count";
        return LazerAudioErrorUnsupported;
    }

    int inputSamples = frame->nb_samples;
    std::vector<const uint8_t *> cueInputData;
    const uint8_t **inputData = const_cast<const uint8_t **>(frame->extended_data);
    if (cueSegmentMode_) {
        const int64_t frameTimestamp = frame->pts != AV_NOPTS_VALUE
            ? frame->pts : frame->best_effort_timestamp;
        if (frameTimestamp == AV_NOPTS_VALUE || inputTimeBase_.num <= 0 ||
            inputTimeBase_.den <= 0 || frame->sample_rate != description_.sampleRate) {
            lastError_ = "CUE segment frame lacks a stable PCM timestamp or sample rate";
            return LazerAudioErrorUnsupported;
        }
        const int64_t streamStart = audioStream_ != nullptr &&
            audioStream_->start_time != AV_NOPTS_VALUE ? audioStream_->start_time : 0;
        const int64_t frameStartSample = av_rescale_q_rnd(
            frameTimestamp - streamStart, inputTimeBase_,
            AVRational{1, description_.sampleRate}, AV_ROUND_NEAR_INF);
        const int64_t frameEndSample = frameStartSample + frame->nb_samples;
        if (frameEndSample <= cueSeekTargetSample_) return LazerAudioOk;
        if (frameStartSample > cueSeekTargetSample_) {
            lastError_ = "CUE segment seek landed after its exact decoded sample boundary";
            return LazerAudioErrorSource;
        }
        const int64_t trimStart = cueSeekTargetSample_ - frameStartSample;
        const int64_t availableFromStart = frame->nb_samples - trimStart;
        const int64_t availableToEnd = cueEndSample_ - cueSeekTargetSample_;
        inputSamples = static_cast<int>(std::min(availableFromStart, availableToEnd));
        if (inputSamples <= 0) {
            cueBoundaryReached_ = true;
            return LazerAudioOk;
        }
        const auto sampleFormat = static_cast<AVSampleFormat>(frame->format);
        const int bytesPerSample = av_get_bytes_per_sample(sampleFormat);
        const int channels = frame->ch_layout.nb_channels > 0
            ? frame->ch_layout.nb_channels : description_.channels;
        if (bytesPerSample <= 0 || channels <= 0 || frame->extended_data == nullptr) {
            lastError_ = "CUE segment decoder returned invalid PCM planes";
            return LazerAudioErrorUnsupported;
        }
        const bool planar = av_sample_fmt_is_planar(sampleFormat) != 0;
        const int planeCount = planar ? channels : 1;
        cueInputData.reserve(static_cast<size_t>(planeCount));
        for (int plane = 0; plane < planeCount; ++plane) {
            if (frame->extended_data[plane] == nullptr) {
                lastError_ = "CUE segment decoder returned an empty PCM plane";
                return LazerAudioErrorUnsupported;
            }
            const size_t stride = static_cast<size_t>(bytesPerSample) *
                static_cast<size_t>(planar ? 1 : channels);
            cueInputData.push_back(frame->extended_data[plane] +
                static_cast<size_t>(trimStart) * stride);
        }
        inputData = cueInputData.data();
        cueSeekTargetSample_ += inputSamples;
        cueBoundaryReached_ = cueSeekTargetSample_ >= cueEndSample_;
    }
    std::vector<const uint8_t *> alignedDsdData;
    if (seekOutputTargetMillis_ >= 0 && description_.dsd) {
        const int64_t frameTimestamp = frame->pts != AV_NOPTS_VALUE
            ? frame->pts : frame->best_effort_timestamp;
        if (frameTimestamp == AV_NOPTS_VALUE || inputTimeBase_.num <= 0 ||
            inputTimeBase_.den <= 0) {
            lastError_ = "DSD seek cannot align its preroll because frame timestamps are unavailable";
            return LazerAudioErrorUnsupported;
        } else {
            const int32_t inputRate = frame->sample_rate > 0
                ? frame->sample_rate : codec_->sample_rate;
            if (inputRate <= 0) {
                lastError_ = "the DSD decoder reports no rate for seek alignment";
                return LazerAudioErrorUnsupported;
            }
            const int64_t streamStartTimestamp = audioStream_ != nullptr &&
                audioStream_->start_time != AV_NOPTS_VALUE ? audioStream_->start_time : 0;
            const int64_t inputIndex = av_rescale_q(
                frameTimestamp - streamStartTimestamp, inputTimeBase_,
                AVRational{1, inputRate});
            const bool hasNativeDsdWordWidth = target_.nativeDsdRawBytes &&
                target_.nativeDsdWordBytes != 0;
            if (hasNativeDsdWordWidth &&
                ((target_.nativeDsdWordBytes != 1 && target_.nativeDsdWordBytes != 2 &&
                    target_.nativeDsdWordBytes != 4) ||
                    inputRate % target_.nativeDsdWordBytes != 0)) {
                lastError_ = "Native DSD seek has an invalid output word clock";
                return LazerAudioErrorUnsupported;
            }
            const bool nativeDsdWordAligned = hasNativeDsdWordWidth;
            const int64_t commonRate = nativeDsdWordAligned
                ? inputRate / target_.nativeDsdWordBytes
                : std::gcd(inputRate, target_.sampleRate);
            const int64_t phasePeriod = nativeDsdWordAligned
                ? target_.nativeDsdWordBytes : inputRate / commonRate;
            const int64_t phaseRemainder = ((inputIndex % phasePeriod) + phasePeriod) % phasePeriod;
            const int64_t inputSamplesToAlign =
                (phasePeriod - phaseRemainder) % phasePeriod;
            if (inputSamplesToAlign >= inputSamples) {
                /* Wait for an input sample index whose converted output position lands on the
                 * same integer output frame as uninterrupted decoding. */
                return LazerAudioOk;
            }
            if (inputSamplesToAlign > 0) {
                const int32_t channelCount = std::max(description_.channels, 1);
                const int bytesPerSample = av_get_bytes_per_sample(
                    static_cast<AVSampleFormat>(frame->format));
                if (bytesPerSample <= 0 || frame->extended_data[0] == nullptr) {
                    lastError_ = "DSD seek frame has no packed sample plane";
                    return LazerAudioErrorUnsupported;
                }
                /* FFmpeg's raw AV_SAMPLE_FMT_DSD and DST decoder's AV_SAMPLE_FMT_FLT frames are
                 * packed/interleaved. inputSamplesToAlign counts samples per channel, so skip one
                 * complete interleaved frame stride for each aligned input sample. */
                const size_t inputFrameBytes = static_cast<size_t>(channelCount) *
                    static_cast<size_t>(bytesPerSample);
                alignedDsdData.reserve(1);
                alignedDsdData.push_back(frame->extended_data[0] +
                    static_cast<size_t>(inputSamplesToAlign) * inputFrameBytes);
                inputSamples -= static_cast<int>(inputSamplesToAlign);
                /* No pre-alignment frames were sent to swr, so reinitializing here starts the
                 * filter at an absolute source position on the target output's sample grid. */
                if (resampler_ != nullptr) {
                    const int initResult = swr_init(resampler_.get());
                    if (initResult < 0) {
                        lastError_ = "resampler could not align at the DSD seek point: " +
                            formatContextError(initResult);
                        return LazerAudioErrorDecode;
                    }
                }
            }
            const int64_t alignedInputIndex = inputIndex + inputSamplesToAlign;
            const int32_t outputRate = nativeDsdWordAligned
                ? inputRate / target_.nativeDsdWordBytes : target_.sampleRate;
            const int64_t alignedOutputIndex = nativeDsdWordAligned
                ? alignedInputIndex / phasePeriod
                : (alignedInputIndex / phasePeriod) * (target_.sampleRate / commonRate);
            const int64_t targetOutputIndex = av_rescale_q_rnd(
                seekOutputTargetMillis_, kMillisTimeBase, AVRational{1, outputRate},
                AV_ROUND_NEAR_INF);
            if (alignedOutputIndex > targetOutputIndex && log_ != nullptr) {
                log_->write(LazerAudioLogWarning,
                    "DSD demux seek did not provide enough preroll for sample alignment");
            }
            if (alignedOutputIndex > targetOutputIndex) {
                lastError_ = "DSD seek landed after the requested position and cannot be sample-aligned";
                return LazerAudioErrorUnsupported;
            }
            const int64_t outputFramesToDrop = targetOutputIndex - alignedOutputIndex;
            if (nativeDsdWordAligned && outputFramesToDrop >
                std::numeric_limits<int64_t>::max() / target_.nativeDsdWordBytes) {
                lastError_ = "Native DSD seek target exceeds the raw-frame range";
                return LazerAudioErrorUnsupported;
            }
            seekOutputFramesToDrop_ = nativeDsdWordAligned
                ? outputFramesToDrop * target_.nativeDsdWordBytes : outputFramesToDrop;
            seekOutputTargetMillis_ = -1;
        }
    }

    if (target_.nativeDsdRawBytes) {
        if (frame->format != AV_SAMPLE_FMT_DSD || frame->extended_data == nullptr ||
            frame->extended_data[0] == nullptr) {
            lastError_ = "raw Native DSD queue staging requires packed DSD decoder frames";
            return LazerAudioErrorUnsupported;
        }
        const uint8_t *input = alignedDsdData.empty()
            ? frame->extended_data[0] : alignedDsdData[0];
        return deliverSamples(input, inputSamples, consumer);
    }

    if (target_.doP) {
        if (frame->format != AV_SAMPLE_FMT_DSD || frame->extended_data == nullptr ||
            frame->extended_data[0] == nullptr) {
            lastError_ = "DoP requires packed raw DSD decoder frames";
            return LazerAudioErrorUnsupported;
        }
        const int32_t inputCapacity = std::max(inputSamples / 2 + 1, 1);
        packedScratch_.resize(static_cast<size_t>(inputCapacity) *
            static_cast<size_t>(target_.frameBytes()));
        const uint8_t *input = alignedDsdData.empty()
            ? frame->extended_data[0] : alignedDsdData[0];
        const DopPackResult packed = dopPacker_.pack(input,
            static_cast<size_t>(inputSamples), packedScratch_.data(),
            static_cast<size_t>(inputCapacity));
        if (packed.consumedInputFrames != static_cast<size_t>(inputSamples) ||
            packed.status == DopPackStatus::OutputFull ||
            packed.status == DopPackStatus::InvalidChannelCount ||
            packed.status == DopPackStatus::InvalidArgument ||
            packed.status == DopPackStatus::SizeOverflow) {
            lastError_ = "the DSD-to-DoP packer could not preserve a complete carrier frame";
            return LazerAudioErrorDecode;
        }
        return deliverSamples(packedScratch_.data(),
            static_cast<int32_t>(packed.producedOutputFrames), consumer);
    }

    if (target_.nativeDsd) {
        if (frame->format != AV_SAMPLE_FMT_DSD || frame->extended_data == nullptr ||
            frame->extended_data[0] == nullptr) {
            lastError_ = "Native DSD requires packed raw DSD decoder frames";
            return LazerAudioErrorUnsupported;
        }
        const size_t wordBytes = nativeDsdPacker_.wordBytes();
        const int32_t outputCapacity = std::max(
            static_cast<int32_t>(inputSamples / static_cast<int>(wordBytes) + 1), 1);
        packedScratch_.resize(static_cast<size_t>(outputCapacity) *
            static_cast<size_t>(target_.frameBytes()));
        const uint8_t *input = alignedDsdData.empty()
            ? frame->extended_data[0] : alignedDsdData[0];
        const NativeDsdPackResult packed = nativeDsdPacker_.pack(input,
            static_cast<size_t>(inputSamples), packedScratch_.data(),
            static_cast<size_t>(outputCapacity));
        if (packed.consumedInputFrames != static_cast<size_t>(inputSamples) ||
            packed.status == NativeDsdPackStatus::OutputFull ||
            packed.status == NativeDsdPackStatus::InvalidChannelCount ||
            packed.status == NativeDsdPackStatus::InvalidWordBytes ||
            packed.status == NativeDsdPackStatus::InvalidArgument ||
            packed.status == NativeDsdPackStatus::SizeOverflow) {
            lastError_ = "the native DSD formatter could not preserve a complete device word";
            return LazerAudioErrorDecode;
        }
        return deliverSamples(packedScratch_.data(),
            static_cast<int32_t>(packed.producedOutputFrames), consumer);
    }

    const int32_t conversionFrameBytes = target_.conversionFrameBytes();
    const int64_t capacity = std::max<int64_t>(
        std::max<int64_t>(swr_get_out_samples(resampler_.get(), frame->nb_samples) + 256,
            frame->nb_samples), 1024);
    scratch_.resize(static_cast<size_t>(capacity) * conversionFrameBytes);
    uint8_t *const begin = scratch_.data();
    const int room = static_cast<int>(capacity);

    const AVSampleFormat framePackedFormat = av_get_packed_sample_fmt(
        static_cast<AVSampleFormat>(frame->format));
    const int bytesPerSample = av_get_bytes_per_sample(
        static_cast<AVSampleFormat>(frame->format));
    const AVChannelLayout &streamLayout = audioStream_ != nullptr &&
        audioStream_->codecpar->ch_layout.nb_channels > 0
        ? audioStream_->codecpar->ch_layout : codec_->ch_layout;
    const bool frameLayoutMatchesStream = frame->ch_layout.nb_channels <= 0 ||
        frame->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC || streamLayout.nb_channels <= 0 ||
        streamLayout.order == AV_CHANNEL_ORDER_UNSPEC ||
        av_channel_layout_compare(&frame->ch_layout, &streamLayout) == 0;
    const bool exactIntegerFrame = description_.lossless && description_.integerPcm &&
        description_.decoderFormatMatchesStream && frame->sample_rate == target_.sampleRate &&
        frame->ch_layout.nb_channels == target_.channels &&
        frameLayoutMatchesStream && framePackedFormat == target_.avFormat() && bytesPerSample > 0 &&
        target_.bitsPerSample != 0;
    if (target_.bitsPerSample != 0 && !exactIntegerFrame) {
        lastError_ = "the decoded integer frame does not match the negotiated bit-perfect format";
        return LazerAudioErrorUnsupported;
    }
    int samplesOut = 0;
    if (exactIntegerFrame) {
        /* Keep a matching decoded integer frame byte-exact. libswresample is reserved for format,
         * channel or sample-rate conversion; planar decoder output is only interleaved here. */
        samplesOut = inputSamples;
        const size_t channelCount = static_cast<size_t>(target_.channels);
        const size_t sampleBytes = static_cast<size_t>(bytesPerSample);
        if (av_sample_fmt_is_planar(static_cast<AVSampleFormat>(frame->format))) {
            for (int sample = 0; sample < samplesOut; ++sample) {
                for (int channel = 0; channel < target_.channels; ++channel) {
                    const size_t outputOffset =
                        (static_cast<size_t>(sample) * channelCount + static_cast<size_t>(channel)) *
                        sampleBytes;
                    const uint8_t *plane = inputData[channel];
                    std::memcpy(begin + outputOffset,
                        plane + static_cast<size_t>(sample) * sampleBytes, sampleBytes);
                }
            }
        } else {
            std::memcpy(begin, inputData[0],
                static_cast<size_t>(samplesOut) * conversionFrameBytes);
        }
    } else {
        const uint8_t **conversionInputData = alignedDsdData.empty()
            ? inputData : alignedDsdData.data();
        samplesOut = swr_convert(
            resampler_.get(), &begin, room, conversionInputData, inputSamples);
        if (samplesOut < 0) {
            lastError_ = "resample failed: " + formatContextError(samplesOut);
            return LazerAudioErrorDecode;
        }

    }

    return deliverSamples(begin, samplesOut, consumer);
}

int32_t AudioSource::drainResampler(SourceConsumer &consumer) {
    if (resampler_ == nullptr) return LazerAudioOk;
    const int32_t conversionFrameBytes = target_.conversionFrameBytes();
    while (!consumer.isCancelled()) {
        const int available = swr_get_out_samples(resampler_.get(), 0);
        if (available < 0) {
            lastError_ = "resampler flush sizing failed: " + formatContextError(available);
            return LazerAudioErrorDecode;
        }
        if (available == 0) return LazerAudioOk;
        const int room = std::max(available, 256);
        scratch_.resize(static_cast<size_t>(room) * conversionFrameBytes);
        uint8_t *output = scratch_.data();
        const int samplesOut = swr_convert(resampler_.get(), &output, room, nullptr, 0);
        if (samplesOut < 0) {
            lastError_ = "resampler flush failed: " + formatContextError(samplesOut);
            return LazerAudioErrorDecode;
        }
        if (samplesOut == 0) return LazerAudioOk;
        const int32_t delivered = deliverSamples(output, samplesOut, consumer);
        if (delivered != LazerAudioOk) return delivered;
    }
    return LazerAudioOk;
}

int32_t AudioSource::deliverSamples(
    const uint8_t *bytes, int32_t sampleCount, SourceConsumer &consumer) {
    if (sampleCount <= 0) return LazerAudioOk;
    const int32_t outputFrameBytes = target_.frameBytes();

    const uint8_t *cursor = bytes;
    if (seekOutputFramesToDrop_ > 0) {
        const int32_t dropped = static_cast<int32_t>(std::min<int64_t>(
            seekOutputFramesToDrop_, sampleCount));
        cursor += static_cast<size_t>(dropped) * outputFrameBytes;
        sampleCount -= dropped;
        seekOutputFramesToDrop_ -= dropped;
        if (sampleCount <= 0) return LazerAudioOk;
    }
    if (seekOutputFramesToDrop_ == 0) seekOutputFramesToDrop_ = -1;
    if (!target_.doP && target_.bitsPerSample == 24 &&
        target_.frameBytes() == target_.channels * 3 &&
        sampleCount > 0) {
        const size_t samples = static_cast<size_t>(sampleCount) *
            static_cast<size_t>(std::max(target_.channels, 1));
        packedScratch_.resize(samples * 3);
        for (size_t sample = 0; sample < samples; ++sample) {
            const size_t sourceOffset = sample * sizeof(int32_t);
            const size_t targetOffset = sample * 3;
            /* FFmpeg's S32 representation is signed little-endian PCM. Dropping the least
             * significant byte yields the packed 24-bit integer expected by WASAPI. */
            packedScratch_[targetOffset] = bytes[sourceOffset + 1];
            packedScratch_[targetOffset + 1] = bytes[sourceOffset + 2];
            packedScratch_[targetOffset + 2] = bytes[sourceOffset + 3];
        }
        cursor = packedScratch_.data();
    }

    int32_t remaining = sampleCount;
    while (remaining > 0 && !consumer.isCancelled()) {
        if (hasPendingSeek()) break;
        if (!consumer.shouldPump()) {
            sleepBriefly();
            continue;
        }
        const int32_t accepted = consumer.accept(cursor, remaining);
        if (accepted > 0) {
            cursor += static_cast<size_t>(accepted) * outputFrameBytes;
            remaining -= accepted;
            producedFrames_.fetch_add(static_cast<int64_t>(accepted), std::memory_order_release);
            continue;
        }
        sleepBriefly();
    }
    return LazerAudioOk;
}

void AudioSource::releaseAvio() {
    if (avio_ == nullptr) {
        avioBuffer_ = nullptr;
        return;
    }
    /* FFmpeg may replace the caller's initial buffer while probing or seeking; its context holds
     * the current allocation that must be freed after the context. */
    uint8_t *buffer = avio_->buffer;
    avio_context_free(&avio_);
    av_free(buffer);
    avioBuffer_ = nullptr;
}

void AudioSource::close() {
    codec_.reset();
    codecDescriptor_ = nullptr;
    resampler_.reset();
    audioStream_ = nullptr;
    inputTimeBase_ = AVRational{0, 1};
    format_.reset();
    releaseAvio();
    dffReader_.close();
    void(LAZER_AUDIO_CALL *closeCallback)(void *) = nullptr;
    void *readerContext = nullptr;
    {
        std::unique_lock guard(readerCallbackMutex_);
        readerCallbackFinished_.wait(guard, [this] { return !readerCancelInFlight_; });
        if (reader_ != nullptr && !readerCloseInvoked_) {
            readerCloseInvoked_ = true;
            closeCallback = reader_->close;
            readerContext = reader_->context;
        }
        reader_ = nullptr;
    }
    if (closeCallback != nullptr) closeCallback(readerContext);
    readerOpening_ = false;
    readerFailed_ = false;
    readerProbePrefix_.clear();
    readerProbePrefixOffset_ = 0;
    readerPosition_ = 0;
    readerPositionSnapshot_.store(0, std::memory_order_release);
    readerEnded_ = false;
    dstDffMode_ = false;
    dstDecodedToPcm_ = false;
    dstSamplesPerFrame_ = 0;
    dstFrameBytes_.clear();
    description_ = StreamDescription{};
    exactDsdBitCount_ = 0;
    exactDsdBitRate_ = 0;
    durationHintMillis_ = 0;
    cueSegmentMode_ = false;
    cueBoundaryReached_ = false;
    cueStartSample_ = 0;
    cueEndSample_ = 0;
    cueSeekTargetSample_ = 0;
    physicalSampleCount_ = 0;
    fileSizeBytes_ = -1;
    seekRequest_.store(-1, std::memory_order_release);
    seekBaseMillis_.store(0, std::memory_order_release);
    seekOutputTargetMillis_ = -1;
    seekOutputFramesToDrop_ = -1;
    dopPacker_.reset();
    nativeDsdPacker_.reset();
    producedFrames_.store(0, std::memory_order_release);
    endOfStream_.store(false, std::memory_order_release);
}

void AudioSource::interruptReader() {
    void(LAZER_AUDIO_CALL *cancelCallback)(void *) = nullptr;
    void *readerContext = nullptr;
    {
        std::lock_guard guard(readerCallbackMutex_);
        if (reader_ != nullptr && !readerCancelInvoked_) {
            readerCancelInvoked_ = true;
            cancelCallback = reader_->cancel;
            readerContext = reader_->context;
            readerCancelInFlight_ = cancelCallback != nullptr;
        }
    }
    if (cancelCallback != nullptr) {
        cancelCallback(readerContext);
        {
            std::lock_guard guard(readerCallbackMutex_);
            readerCancelInFlight_ = false;
        }
        readerCallbackFinished_.notify_all();
    }
}

int AudioSource::readFromSource(uint8_t *buffer, int bufferSize) {
    if (buffer == nullptr || bufferSize <= 0) return 0;
    int copied = 0;
    if (readerProbePrefixOffset_ < readerProbePrefix_.size()) {
        copied = static_cast<int>(std::min<size_t>(static_cast<size_t>(bufferSize),
            readerProbePrefix_.size() - readerProbePrefixOffset_));
        std::memcpy(buffer, readerProbePrefix_.data() + readerProbePrefixOffset_,
            static_cast<size_t>(copied));
        readerProbePrefixOffset_ += static_cast<size_t>(copied);
        if (copied == bufferSize) return copied;
    }
    if (readerFailed_) return copied > 0 ? copied : AVERROR(EIO);
    if (reader_ == nullptr || reader_->read == nullptr || readerEnded_) {
        return copied > 0 ? copied : AVERROR_EOF;
    }
    int32_t count = 0;
    do {
        count = reader_->read(reader_->context, buffer + copied, bufferSize - copied);
        if (count == 0 && readerOpening_) {
            /* avformat_open_input/find_stream_info are synchronous: they treat AVERROR(EAGAIN)
             * as a failed open instead of retaining a resumable probe. The reader API defines zero
             * as temporary unavailability, so wait only during initialization. Once the stream is
             * open, return EAGAIN to the pump, which can retry without blocking its worker. */
            sleepBriefly();
        }
    } while (count == 0 && readerOpening_);
    if (count < 0) {
        if (count == LAZER_AUDIO_READER_EOF) {
            /* Sticky: the source finished, so a later probe from FFmpeg must not re-block. */
            readerEnded_ = true;
            return copied > 0 ? copied : AVERROR_EOF;
        }
        readerFailed_ = true;
        lastError_ = "audio reader reported an I/O error";
        return copied > 0 ? copied : AVERROR(EIO);
    }
    if (count == 0) return copied > 0 ? copied : AVERROR(EAGAIN);
    if (count > bufferSize - copied) {
        lastError_ = "audio reader returned more bytes than requested";
        return AVERROR(EIO);
    }
    if (readerPosition_ <= std::numeric_limits<int64_t>::max() - count) {
        readerPosition_ += count;
        readerPositionSnapshot_.store(readerPosition_, std::memory_order_release);
    } else {
        lastError_ = "audio reader position overflowed";
        return AVERROR(EOVERFLOW);
    }
    return copied + count;
}

int64_t AudioSource::seekInSource(int64_t offset, int whence) {
    if (reader_ == nullptr) return -1;
    whence &= ~AVSEEK_FORCE;
    if (whence == AVSEEK_SIZE) {
        if (reader_->length == nullptr) return -1;
        const int64_t length = reader_->length(reader_->context);
        return length >= 0 ? length : -1;
    }
    if (reader_->seek == nullptr) return -1;
    int64_t base = 0;
    if (whence == kAvioSeekSet) {
        base = 0;
    } else if (whence == SEEK_CUR) {
        base = readerPosition_;
    } else if (whence == SEEK_END) {
        if (reader_->length == nullptr) return -1;
        base = reader_->length(reader_->context);
        if (base < 0) return -1;
    } else {
        return -1;
    }
    if ((offset > 0 && base > std::numeric_limits<int64_t>::max() - offset) ||
        (offset < 0 && base < std::numeric_limits<int64_t>::min() - offset)) return -1;
    const int64_t target = base + offset;
    if (target < 0) return -1;
    const int64_t position = reader_->seek(reader_->context, target);
    if (position >= 0) {
        readerPosition_ = position;
        readerPositionSnapshot_.store(position, std::memory_order_release);
        readerProbePrefixOffset_ = readerProbePrefix_.size();
        readerEnded_ = false;
    }
    return position >= 0 ? position : -1;
}

int AudioSource::readFromDff(uint8_t *buffer, int bufferSize) {
    const int count = dffReader_.read(buffer, bufferSize);
    if (count > 0) return count;
    if (count == 0) return AVERROR_EOF;
    lastError_ = dffReader_.lastError().empty()
        ? "failed to read virtual DSF bytes from the DFF source"
        : dffReader_.lastError();
    return AVERROR(EIO);
}

int64_t AudioSource::seekInDff(int64_t offset, int whence) {
    return dffReader_.seek(offset, whence);
}

}  // namespace lazer::audio
