/* The read side of the engine: a byte source (file or the caller's own stream), the demuxer, the
 * decoder and the resampler, all driven by one thread that hands finished PCM blocks to a consumer.
 *
 * The source deliberately knows nothing about audio devices. It only knows how to turn a container
 * into interleaved blocks of the format the engine asked for. */
#ifndef LAZER_AUDIO_SOURCE_H
#define LAZER_AUDIO_SOURCE_H

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#include "dff_dsf_reader.h"
#include "dop_packer.h"
#include "internal.h"
#include "native_dsd_packer.h"

namespace lazer::audio {

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
        const AVSampleFormat format = avFormat();
        const int32_t bytes = format == AV_SAMPLE_FMT_U8 ? 1
            : format == AV_SAMPLE_FMT_S16 ? 2 : 4;
        return std::max(channels, 1) * bytes;
    }
    [[nodiscard]] AVSampleFormat avFormat() const noexcept {
        if (isFloat()) return AV_SAMPLE_FMT_FLT;
        if (bitsPerSample <= 8) return AV_SAMPLE_FMT_U8;
        if (bitsPerSample <= 16) return AV_SAMPLE_FMT_S16;
        return AV_SAMPLE_FMT_S32;
    }
};

class SourceConsumer {
public:
    virtual ~SourceConsumer() = default;

    /* Returns the number of frames accepted; 0 means the consumer is full and the source must wait. */
    virtual int32_t accept(const uint8_t *bytes, int32_t frameCount) = 0;

    /* False parks the source (pause): it stops asking FFmpeg for data but keeps its state. */
    virtual bool shouldPump() const = 0;

    /* True ends the pump loop immediately, used by stop, seek and teardown. */
    virtual bool isCancelled() const = 0;

    /* Called by the source's owner thread after a seek was applied successfully. */
    virtual void onSeekApplied() {}
};

/* Owns one open stream. After open/format setup exactly one decoder worker pumps it; control paths
 * communicate through atomics and the separate caller-reader interruption callback. */
class AudioSource {
public:
    explicit AudioSource(LogProxy *log);
    ~AudioSource();

    AudioSource(const AudioSource &) = delete;
    AudioSource &operator=(const AudioSource &) = delete;

    /* Either path may be opened; opening again closes what was open. */
    int32_t openFile(const wchar_t *path, const LazerAudioOpenParams &params);
    /* Binds a caller reader before its slot is published to cancellation paths. */
    int32_t prepareReader(const LazerAudioReader &reader);
    int32_t openReader(const LazerAudioReader &reader, const LazerAudioOpenParams &params);
    void close();
    /* Wakes a blocking caller reader without releasing FFmpeg state or the reader context. */
    void interruptReader();

    int32_t setTargetFormat(TargetFormat format);
    [[nodiscard]] const TargetFormat &targetFormat() const noexcept { return target_; }

    int32_t pump(SourceConsumer &consumer);

    /* A seek request is answered by the pump thread; the caller only flags it. */
    void requestSeek(int64_t positionMillis);
    [[nodiscard]] bool hasPendingSeek() const noexcept {
        return seekRequest_.load(std::memory_order_acquire) >= 0;
    }
    [[nodiscard]] int64_t seekTargetMillis() const noexcept {
        return seekBaseMillis_.load(std::memory_order_acquire);
    }

    [[nodiscard]] const StreamDescription &description() const noexcept { return description_; }
    /* Overrides estimated DSD timing with an authoritative container bit count and bit clock. */
    void setExactDsdDuration(int64_t dsdBitCount, int64_t dsdBitRate) noexcept;
    /* Returns the exact output PCM frame count when the container provides an authoritative
     * sample count; zero means the duration is unknown. */
    [[nodiscard]] int64_t totalOutputFrames() const noexcept;
    [[nodiscard]] const std::string &lastError() const noexcept { return lastError_; }
    [[nodiscard]] int64_t producedFrames() const noexcept {
        return producedFrames_.load(std::memory_order_acquire);
    }
    [[nodiscard]] double bufferedFraction() const noexcept;
    [[nodiscard]] bool reachedEndOfStream() const noexcept {
        return endOfStream_.load(std::memory_order_acquire);
    }

private:
    int32_t openCommon(const LazerAudioOpenParams &params);
    int32_t openDffAvio(const LazerAudioOpenParams &params);
    int32_t openDffDst(const LazerAudioOpenParams &params);
    int32_t configureDecoder();
    int32_t configureDstDecoder();
    int32_t configureResampler();
    int32_t decodePacket(AVPacket *packet, SourceConsumer &consumer);
    int32_t emitAVFrame(AVFrame *frame, SourceConsumer &consumer);
    int32_t drainResampler(SourceConsumer &consumer);
    int32_t deliverSamples(const uint8_t *bytes, int32_t sampleCount, SourceConsumer &consumer);
    int32_t applySeek(int64_t positionMillis);
    /* A blocking caller read is turned into an AVIO result here; -1 from the caller means the stream
     * is finished, and that answer is sticky so FFmpeg never re-asks a closed download. */
    int readFromSource(uint8_t *buffer, int bufferSize);
    int64_t seekInSource(int64_t offset, int whence);
    int readFromDff(uint8_t *buffer, int bufferSize);
    int64_t seekInDff(int64_t offset, int whence);
    int32_t reopenDstDecoder();
    void releaseAvio();

    friend int readerPacketCallback(void *opaque, uint8_t *buffer, int bufferSize);
    friend int64_t readerSeekCallback(void *opaque, int64_t offset, int whence);
    friend int dffPacketCallback(void *opaque, uint8_t *buffer, int bufferSize);
    friend int64_t dffSeekCallback(void *opaque, int64_t offset, int whence);

    LogProxy *log_ = nullptr;
    DffDsfReader dffReader_;
    FormatContext format_;
    CodecContext codec_;
    const AVCodec *codecDescriptor_ = nullptr;
    ResampleContext resampler_;
    AVStream *audioStream_ = nullptr;   /* borrowed from format_ */
    AVRational inputTimeBase_{0, 1};
    uint8_t *avioBuffer_ = nullptr;     /* av_malloc'ed, owned alongside avio_ */
    AVIOContext *avio_ = nullptr;
    std::vector<uint8_t> readerBytes_;  /* staging for the caller's reader */
    const LazerAudioReader *reader_ = nullptr;
    mutable std::mutex readerCallbackMutex_;
    std::condition_variable readerCallbackFinished_;
    bool readerCancelInvoked_ = false;
    bool readerCloseInvoked_ = false;
    bool readerCancelInFlight_ = false;
    std::vector<uint8_t> readerProbePrefix_;
    size_t readerProbePrefixOffset_ = 0;
    int64_t readerPosition_ = 0; /* physical reader cursor, including bytes staged for sniffing */
    std::atomic<int64_t> readerPositionSnapshot_{0};
    bool readerOpening_ = false; /* AVFormat initialization cannot resume after a transient EAGAIN */
    bool readerFailed_ = false; /* a terminal caller-reader failure must never become clean EOF */
    std::vector<uint8_t> scratch_;      /* conversion output of one decoded block */
    std::vector<uint8_t> packedScratch_; /* packed 24-bit PCM frames when requested */
    std::vector<uint8_t> dstFrameBytes_;

    TargetFormat target_{};
    DopPacker dopPacker_{2};
    NativeDsdPacker nativeDsdPacker_{};
    StreamDescription description_{};
    int64_t exactDsdBitCount_ = 0;
    int64_t exactDsdBitRate_ = 0;
    int64_t durationHintMillis_ = 0;
    bool cueSegmentMode_ = false;
    bool cueBoundaryReached_ = false;
    int64_t cueStartSample_ = 0;
    int64_t cueEndSample_ = 0;
    int64_t cueSeekTargetSample_ = 0;
    int64_t physicalSampleCount_ = 0;
    int64_t fileSizeBytes_ = -1;
    std::atomic<int64_t> seekRequest_{-1};
    std::atomic<int64_t> seekBaseMillis_{0};
    std::atomic<int64_t> producedFrames_{0};
    std::atomic<bool> endOfStream_{false};
    int64_t seekOutputTargetMillis_ = -1; /* trim the preroll converted to PCM before this point */
    int64_t seekOutputFramesToDrop_ = -1;
    bool readerEnded_ = false;
    bool dstDffMode_ = false;
    bool dstDecodedToPcm_ = false;
    int32_t dstSamplesPerFrame_ = 0;
    std::string lastError_;
};

/* FFmpeg's read callback for the caller-supplied stream. Kept here so the semantics of a growing
 * cache file - a blocking read that only ever returns -1 when the download truly finished - live
 * next to the code that turns that into an AVIO result. */
int readerPacketCallback(void *opaque, uint8_t *buffer, int bufferSize);

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_SOURCE_H
