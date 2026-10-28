/* Internal reader for DSDIFF audio. Raw DSD is adapted to FFmpeg's DSF demuxer; DST-compressed
 * sound data is exposed as one packet per DST frame for FFmpeg's DST decoder. */
#ifndef LAZER_AUDIO_DFF_DSF_READER_H
#define LAZER_AUDIO_DFF_DSF_READER_H

#include <array>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "internal.h"

namespace lazer::audio {

/* DFF stores DSD bytes interleaved by channel; DSF stores 4096-byte planar channel blocks.
 * This reader synthesizes the small DSF header and transposes one bounded block at a time. */
class DffDsfReader {
public:
    DffDsfReader() = default;
    ~DffDsfReader();

    DffDsfReader(const DffDsfReader &) = delete;
    DffDsfReader &operator=(const DffDsfReader &) = delete;

    static bool hasDffMagic(const wchar_t *path);
    int32_t openFile(const wchar_t *path, std::string &error);
    int32_t openReader(const LazerAudioReader *reader, std::string &error);

    [[nodiscard]] bool isDst() const noexcept { return isDst_; }
    [[nodiscard]] uint32_t bitRate() const noexcept { return bitRate_; }
    [[nodiscard]] int32_t channels() const noexcept { return channels_; }
    [[nodiscard]] int64_t rawDsdBitCount() const noexcept;
    [[nodiscard]] uint32_t dstFrameRate() const noexcept { return dstFrameRate_; }
    [[nodiscard]] uint32_t dstFrameCount() const noexcept { return dstFrameCount_; }

    /* DST packets are returned in file order. readDstFrame returns 0 at EOF and -1 on failure. */
    int32_t readDstFrame(std::vector<uint8_t> &destination, uint32_t &frameIndex);
    bool seekDstFrame(uint32_t frameIndex);

    /* AVIO callbacks call these after open. read returns 0 at virtual EOF and -1 on source error. */
    int read(uint8_t *destination, int capacity);
    int64_t seek(int64_t offset, int whence);
    [[nodiscard]] int64_t length() const noexcept;
    [[nodiscard]] const std::string &lastError() const noexcept { return lastError_; }
    void close() noexcept;

private:
    struct Chunk {
        char id[4]{};
        uint64_t size = 0;
        uint64_t payloadOffset = 0;
        uint64_t nextOffset = 0;
    };

    struct DstSeekPoint {
        uint32_t frameIndex = 0;
        uint64_t chunkOffset = 0;
    };

    int32_t parse(std::string &error);
    bool readAt(uint64_t offset, uint8_t *destination, size_t length);
    bool readChunk(uint64_t offset, uint64_t parentEnd, Chunk &chunk, std::string &error);
    bool parseProperties(const Chunk &chunk, std::string &error);
    bool parseDstData(const Chunk &chunk, std::string &error);
    bool loadBlock(uint64_t blockIndex);
    void setError(std::string text, std::string *out = nullptr);

    FILE *file_ = nullptr;
    const LazerAudioReader *reader_ = nullptr; /* borrowed; AudioSource owns its close callback */
    int64_t sourceLength_ = -1;
    uint64_t dataOffset_ = 0;
    uint64_t dataBytes_ = 0;
    uint64_t bytesPerChannel_ = 0;
    uint64_t paddedBytesPerChannel_ = 0;
    uint64_t virtualLength_ = 0;
    uint64_t virtualPosition_ = 0;
    uint32_t bitRate_ = 0;
    int channels_ = 0;
    bool unsupported_ = false;
    bool compressionIsDst_ = false;
    bool isDst_ = false;
    uint64_t dstDataStart_ = 0;
    uint64_t dstDataEnd_ = 0;
    uint64_t dstNextChunkOffset_ = 0;
    uint32_t dstFrameRate_ = 0;
    uint32_t dstFrameCount_ = 0;
    uint32_t dstFrameCursor_ = 0;
    std::vector<DstSeekPoint> dstSeekPoints_;
    int64_t cachedBlock_ = -1;
    std::array<uint8_t, 92> header_{};
    std::vector<uint8_t> blockCache_;
    std::vector<uint8_t> interleavedCache_;
    std::string lastError_;
};

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_DFF_DSF_READER_H
