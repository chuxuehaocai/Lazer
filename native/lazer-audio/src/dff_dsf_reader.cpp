#include "dff_dsf_reader.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <climits>
#include <cstring>
#include <limits>
#include <thread>

namespace lazer::audio {

namespace {

constexpr uint64_t kDsfBlockBytes = 4096;
constexpr uint64_t kDsfHeaderBytes = 92;
constexpr size_t kReadChunkBytes = 64 * 1024;
constexpr uint32_t kDffDstFrameRate = 75;
constexpr uint32_t kDstSeekIntervalFrames = 750; /* at most ten seconds of packet scanning per seek */

uint32_t readBe32(const uint8_t *bytes) {
    return (static_cast<uint32_t>(bytes[0]) << 24) |
        (static_cast<uint32_t>(bytes[1]) << 16) |
        (static_cast<uint32_t>(bytes[2]) << 8) |
        static_cast<uint32_t>(bytes[3]);
}

uint64_t readBe64(const uint8_t *bytes) {
    uint64_t value = 0;
    for (int index = 0; index < 8; ++index) value = (value << 8) | bytes[index];
    return value;
}

void appendLe32(std::array<uint8_t, kDsfHeaderBytes> &bytes, size_t &offset, uint32_t value) {
    for (int index = 0; index < 4; ++index) {
        bytes[offset++] = static_cast<uint8_t>(value >> (index * 8));
    }
}

void appendLe64(std::array<uint8_t, kDsfHeaderBytes> &bytes, size_t &offset, uint64_t value) {
    for (int index = 0; index < 8; ++index) {
        bytes[offset++] = static_cast<uint8_t>(value >> (index * 8));
    }
}

void appendId(std::array<uint8_t, kDsfHeaderBytes> &bytes, size_t &offset, const char id[4]) {
    std::memcpy(bytes.data() + offset, id, 4);
    offset += 4;
}

bool isId(const char id[4], const char expected[5]) {
    return std::memcmp(id, expected, 4) == 0;
}

bool checkedAdd(uint64_t left, uint64_t right, uint64_t &result) {
    if (right > std::numeric_limits<uint64_t>::max() - left) return false;
    result = left + right;
    return true;
}

bool checkedMultiply(uint64_t left, uint64_t right, uint64_t &result) {
    if (left != 0 && right > std::numeric_limits<uint64_t>::max() / left) return false;
    result = left * right;
    return true;
}

int32_t supportedDsdMultiplier(uint32_t bitRate) {
    if (bitRate % 44'100 != 0) return 0;
    const uint32_t multiplier = bitRate / 44'100;
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

}  // namespace

DffDsfReader::~DffDsfReader() {
    close();
}

int64_t DffDsfReader::rawDsdBitCount() const noexcept {
    if (isDst_ || bytesPerChannel_ == 0 ||
        bytesPerChannel_ > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) / 8U) {
        return 0;
    }
    return static_cast<int64_t>(bytesPerChannel_ * 8U);
}

bool DffDsfReader::hasDffMagic(const wchar_t *path) {
    if (path == nullptr) return false;
    FILE *file = openWideFileForRead(path);
    if (file == nullptr) return false;
    uint8_t magic[4]{};
    const size_t count = std::fread(magic, 1, sizeof(magic), file);
    std::fclose(file);
    return count == sizeof(magic) && std::memcmp(magic, "FRM8", 4) == 0;
}

int32_t DffDsfReader::openFile(const wchar_t *path, std::string &error) {
    close();
    if (path == nullptr) {
        error = "DFF path is null";
        return LazerAudioErrorInvalidArgument;
    }
    file_ = openWideFileForRead(path);
    if (file_ == nullptr || seekFile64(file_, 0, SEEK_END) != 0) {
        setError("could not open or size the DFF file", &error);
        close();
        return LazerAudioErrorSource;
    }
    const int64_t length = tellFile64(file_);
    if (length < 0 || seekFile64(file_, 0, SEEK_SET) != 0) {
        setError("could not determine the DFF file length", &error);
        close();
        return LazerAudioErrorSource;
    }
    sourceLength_ = static_cast<int64_t>(length);
    return parse(error);
}

int32_t DffDsfReader::openReader(const LazerAudioReader *reader, std::string &error) {
    close();
    if (reader == nullptr || reader->read == nullptr || reader->seek == nullptr ||
        reader->length == nullptr) {
        error = "DFF requires a reader with absolute seek and a known length";
        return LazerAudioErrorUnsupported;
    }
    const int64_t length = reader->length(reader->context);
    if (length < 16) {
        error = "DFF reader reports an invalid or incomplete length";
        return LazerAudioErrorSource;
    }
    reader_ = reader;
    sourceLength_ = length;
    return parse(error);
}

void DffDsfReader::setError(std::string text, std::string *out) {
    lastError_ = std::move(text);
    if (out != nullptr) *out = lastError_;
}

bool DffDsfReader::readAt(uint64_t offset, uint8_t *destination, size_t length) {
    if (sourceLength_ < 0 || offset > static_cast<uint64_t>(sourceLength_) ||
        length > static_cast<uint64_t>(sourceLength_) - offset) return false;
    if (length == 0) return true;
    if (file_ != nullptr) {
        if (offset > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) ||
            seekFile64(file_, static_cast<int64_t>(offset), SEEK_SET) != 0) return false;
        return std::fread(destination, 1, length, file_) == length;
    }
    if (reader_ == nullptr || reader_->seek == nullptr || reader_->read == nullptr ||
        offset > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) return false;
    if (reader_->seek(reader_->context, static_cast<int64_t>(offset)) !=
        static_cast<int64_t>(offset)) return false;
    size_t remaining = length;
    while (remaining > 0) {
        const int32_t request = static_cast<int32_t>(std::min(remaining, kReadChunkBytes));
        const int32_t count = reader_->read(
            reader_->context, destination + (length - remaining), request);
        if (count < 0 || count > request) return false;
        if (count == 0) {
            /* A seekable, known-length reader can temporarily have no data available even though
             * the requested range is in bounds. Keep reading until it produces bytes or EOF. */
            std::this_thread::sleep_for(std::chrono::milliseconds(3));
            continue;
        }
        remaining -= static_cast<size_t>(count);
    }
    return true;
}

bool DffDsfReader::readChunk(
    uint64_t offset, uint64_t parentEnd, Chunk &chunk, std::string &error) {
    if (offset > parentEnd || parentEnd - offset < 12) {
        setError("truncated DFF chunk header", &error);
        return false;
    }
    std::array<uint8_t, 12> header{};
    if (!readAt(offset, header.data(), header.size())) {
        setError("could not read DFF chunk header", &error);
        return false;
    }
    std::memcpy(chunk.id, header.data(), 4);
    chunk.size = readBe64(header.data() + 4);
    chunk.payloadOffset = offset + 12;
    uint64_t payloadEnd = 0;
    if (!checkedAdd(chunk.payloadOffset, chunk.size, payloadEnd) || payloadEnd > parentEnd) {
        setError("DFF chunk exceeds its parent boundary", &error);
        return false;
    }
    chunk.nextOffset = payloadEnd;
    if ((chunk.size & 1) != 0) {
        uint8_t pad = 0;
        if (payloadEnd >= parentEnd || !readAt(payloadEnd, &pad, 1) || pad != 0) {
            setError("DFF odd-sized chunk is missing its required zero pad byte", &error);
            return false;
        }
        ++chunk.nextOffset;
    }
    return true;
}

bool DffDsfReader::parseProperties(const Chunk &chunk, std::string &error) {
    unsupported_ = false;
    compressionIsDst_ = false;
    isDst_ = false;
    dstDataStart_ = 0;
    dstDataEnd_ = 0;
    dstNextChunkOffset_ = 0;
    dstFrameRate_ = 0;
    dstFrameCount_ = 0;
    dstFrameCursor_ = 0;
    dstSeekPoints_.clear();
    if (chunk.size < 4) {
        setError("DFF PROP chunk has no property type", &error);
        return false;
    }
    std::array<uint8_t, 4> type{};
    if (!readAt(chunk.payloadOffset, type.data(), type.size()) ||
        std::memcmp(type.data(), "SND ", 4) != 0) {
        setError("DFF PROP chunk is not a sound property", &error);
        return false;
    }
    const uint64_t end = chunk.payloadOffset + chunk.size;
    uint64_t position = chunk.payloadOffset + 4;
    bool haveFs = false;
    bool haveChannels = false;
    bool haveCompression = false;
    uint32_t bitRate = 0;
    uint8_t channelCount = 0;
    std::array<std::array<char, 4>, 2> channelIds{};
    std::array<char, 4> compressionId{};

    while (position < end) {
        Chunk property{};
        if (!readChunk(position, end, property, error)) return false;
        if (isId(property.id, "FS  ")) {
            if (haveFs || property.size != 4) {
                setError("DFF PROP has a duplicate or malformed FS field", &error);
                return false;
            }
            std::array<uint8_t, 4> value{};
            if (!readAt(property.payloadOffset, value.data(), value.size())) {
                setError("could not read DFF FS field", &error);
                return false;
            }
            bitRate = readBe32(value.data());
            haveFs = true;
        } else if (isId(property.id, "CHNL")) {
            if (haveChannels || property.size < 2) {
                setError("DFF PROP has a duplicate or malformed CHNL field", &error);
                return false;
            }
            std::array<uint8_t, 2> value{};
            if (!readAt(property.payloadOffset, value.data(), value.size())) {
                setError("could not read DFF CHNL field", &error);
                return false;
            }
            const uint16_t count = static_cast<uint16_t>(
                (static_cast<uint16_t>(value[0]) << 8) | value[1]);
            if (count == 0 || property.size != 2 + 4 * count) {
                setError("DFF CHNL count does not match its channel identifier list", &error);
                return false;
            }
            if (count > 2) {
                unsupported_ = true;
                setError("this DFF reader supports only mono or stereo CHNL entries", &error);
                return false;
            }
            channelCount = static_cast<uint8_t>(count);
            std::array<uint8_t, 8> ids{};
            if (!readAt(property.payloadOffset + 2, ids.data(), 4 * count)) {
                setError("could not read DFF channel identifiers", &error);
                return false;
            }
            for (uint16_t index = 0; index < count; ++index) {
                std::memcpy(channelIds[index].data(), ids.data() + index * 4, 4);
            }
            haveChannels = true;
        } else if (isId(property.id, "CMPR")) {
            if (haveCompression || property.size < 5) {
                setError("DFF PROP has a duplicate or malformed CMPR field", &error);
                return false;
            }
            std::array<uint8_t, 5> value{};
            if (!readAt(property.payloadOffset, value.data(), value.size())) {
                setError("could not read DFF CMPR field", &error);
                return false;
            }
            const uint8_t nameLength = value[4];
            const bool hasNulTerminator = property.size == 6 + nameLength;
            if (property.size != 5 + nameLength && !hasNulTerminator) {
                setError("DFF CMPR name length does not match its chunk size", &error);
                return false;
            }
            if (hasNulTerminator) {
                uint8_t terminator = 0xff;
                if (!readAt(property.payloadOffset + 5 + nameLength, &terminator, 1) ||
                    terminator != 0) {
                    setError("DFF CMPR optional name terminator is not zero", &error);
                    return false;
                }
            }
            std::memcpy(compressionId.data(), value.data(), 4);
            haveCompression = true;
        }
        position = property.nextOffset;
    }
    if (position != end || !haveFs || !haveChannels || !haveCompression) {
        setError("DFF PROP must contain exactly one FS, CHNL and CMPR field", &error);
        return false;
    }
    if (std::memcmp(compressionId.data(), "DSD ", 4) == 0) {
        compressionIsDst_ = false;
    } else if (std::memcmp(compressionId.data(), "DST ", 4) == 0) {
        compressionIsDst_ = true;
    } else {
        unsupported_ = true;
        setError("unsupported DFF compression identifier", &error);
        return false;
    }
    if (bitRate == 0 || bitRate % 8 != 0) {
        setError("DFF FS rate must be a nonzero bit rate divisible by eight", &error);
        return false;
    }
    if (supportedDsdMultiplier(bitRate) == 0) {
        unsupported_ = true;
        setError("DFF DSD rate is outside the supported DSD64–DSD1024 rates", &error);
        return false;
    }
    if (channelCount == 1) {
        if (std::memcmp(channelIds[0].data(), "C   ", 4) != 0) {
            unsupported_ = true;
            setError("DFF mono channel ID cannot be represented safely by the DSF demuxer", &error);
            return false;
        }
    } else if (std::memcmp(channelIds[0].data(), "SLFT", 4) != 0 ||
        std::memcmp(channelIds[1].data(), "SRGT", 4) != 0) {
        unsupported_ = true;
        setError("DFF stereo channel order must be SLFT, SRGT", &error);
        return false;
    }

    channels_ = channelCount;
    bitRate_ = bitRate;
    return true;
}

int32_t DffDsfReader::parse(std::string &error) {
    lastError_.clear();
    if (sourceLength_ < 16) {
        setError("DFF file is shorter than its form header", &error);
        close();
        return LazerAudioErrorSource;
    }
    std::array<uint8_t, 16> form{};
    if (!readAt(0, form.data(), form.size()) || std::memcmp(form.data(), "FRM8", 4) != 0 ||
        std::memcmp(form.data() + 12, "DSD ", 4) != 0) {
        setError("file does not contain a DSDIFF FRM8 form", &error);
        close();
        return LazerAudioErrorUnsupported;
    }
    const uint64_t formSize = readBe64(form.data() + 4);
    uint64_t formEnd = 0;
    if (formSize < 4 || !checkedAdd(12, formSize, formEnd) ||
        formEnd > static_cast<uint64_t>(sourceLength_)) {
        setError("DFF FRM8 size is invalid or truncated", &error);
        close();
        return LazerAudioErrorSource;
    }

    bool haveFver = false;
    bool haveProp = false;
    bool haveData = false;
    bool sawDst = false;
    uint32_t fileVersion = 0;
    uint64_t position = 16;
    while (position < formEnd) {
        Chunk chunk{};
        if (!readChunk(position, formEnd, chunk, error)) {
            close();
            return LazerAudioErrorSource;
        }
        if (!haveFver) {
            if (!isId(chunk.id, "FVER") || chunk.size != 4) {
                setError("FVER must be the first DFF chunk and contain a 32-bit version", &error);
                close();
                return LazerAudioErrorSource;
            }
            std::array<uint8_t, 4> versionBytes{};
            if (!readAt(chunk.payloadOffset, versionBytes.data(), versionBytes.size())) {
                setError("could not read the DFF format version", &error);
                close();
                return LazerAudioErrorSource;
            }
            fileVersion = readBe32(versionBytes.data());
            if (fileVersion != 0x01050000 && fileVersion != 0x01040000) {
                setError("unsupported DSDIFF version; only 1.4.0.0 DST and 1.5.0.0 files are accepted", &error);
                close();
                return LazerAudioErrorUnsupported;
            }
            haveFver = true;
        } else if (isId(chunk.id, "FVER")) {
            setError("DFF contains duplicate FVER chunks", &error);
            close();
            return LazerAudioErrorSource;
        }

        if (isId(chunk.id, "PROP")) {
            if (haveProp || haveData) {
                setError("DFF PROP must occur once before the sound data", &error);
                close();
                return LazerAudioErrorSource;
            }
            if (!parseProperties(chunk, error)) {
                const bool unsupported = unsupported_;
                close();
                return unsupported ? LazerAudioErrorUnsupported : LazerAudioErrorSource;
            }
            if (fileVersion == 0x01040000 && !compressionIsDst_) {
                setError("raw DSDIFF 1.4.0.0 is not enabled; the raw adapter is verified for 1.5.0.0", &error);
                close();
                return LazerAudioErrorUnsupported;
            }
            haveProp = true;
        } else if (isId(chunk.id, "DSD ") || isId(chunk.id, "DST ")) {
            if (!haveProp || haveData) {
                setError("DFF sound data must occur once after PROP", &error);
                close();
                return LazerAudioErrorSource;
            }
            const bool soundIsDst = isId(chunk.id, "DST ");
            if (soundIsDst != compressionIsDst_) {
                setError("DFF CMPR and sound chunk types do not agree", &error);
                close();
                return LazerAudioErrorSource;
            }
            if (soundIsDst) {
                if (!parseDstData(chunk, error)) {
                    const bool unsupported = unsupported_;
                    close();
                    return unsupported ? LazerAudioErrorUnsupported : LazerAudioErrorSource;
                }
                sawDst = true;
            } else {
                if (chunk.size == 0 || chunk.size % static_cast<uint64_t>(channels_) != 0) {
                    setError("DFF raw DSD data must contain complete channel clusters", &error);
                    close();
                    return LazerAudioErrorSource;
                }
                dataOffset_ = chunk.payloadOffset;
                dataBytes_ = chunk.size;
                bytesPerChannel_ = dataBytes_ / static_cast<uint64_t>(channels_);
            }
            haveData = true;
        }
        position = chunk.nextOffset;
    }
    if (position != formEnd || !haveFver || !haveProp || !haveData ||
        (compressionIsDst_ != sawDst)) {
        setError("DFF form is missing FVER, PROP or its matching sound data chunk", &error);
        close();
        return LazerAudioErrorSource;
    }

    if (sawDst) {
        isDst_ = true;
        lastError_.clear();
        return LazerAudioOk;
    }

    uint64_t sampleCount = 0;
    if (!checkedMultiply(bytesPerChannel_, 8, sampleCount)) {
        setError("DFF DSD sample count overflows DSF's 64-bit field", &error);
        close();
        return LazerAudioErrorSource;
    }
    const uint64_t blocks = bytesPerChannel_ / kDsfBlockBytes +
        (bytesPerChannel_ % kDsfBlockBytes != 0 ? 1 : 0);
    if (!checkedMultiply(blocks, kDsfBlockBytes, paddedBytesPerChannel_)) {
        setError("DFF audio is too large for the virtual DSF block map", &error);
        close();
        return LazerAudioErrorSource;
    }
    uint64_t paddedAudioBytes = 0;
    uint64_t dataChunkSize = 0;
    if (!checkedMultiply(paddedBytesPerChannel_, static_cast<uint64_t>(channels_), paddedAudioBytes) ||
        !checkedAdd(12, paddedAudioBytes, dataChunkSize) ||
        !checkedAdd(kDsfHeaderBytes, paddedAudioBytes, virtualLength_) ||
        virtualLength_ > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
        setError("DFF audio is too large for FFmpeg's DSF byte stream", &error);
        close();
        return LazerAudioErrorSource;
    }

    size_t out = 0;
    appendId(header_, out, "DSD ");
    appendLe64(header_, out, 28);
    appendLe64(header_, out, virtualLength_);
    appendLe64(header_, out, 0);
    appendId(header_, out, "fmt ");
    appendLe64(header_, out, 52);
    appendLe32(header_, out, 1); /* DSF version */
    appendLe32(header_, out, 0); /* DSD raw format */
    appendLe32(header_, out, channels_ == 1 ? 1 : 2); /* mono or stereo */
    appendLe32(header_, out, static_cast<uint32_t>(channels_));
    /* DSF records the DSD bit rate, not the byte clock used by FFmpeg's DSD decoder. */
    appendLe32(header_, out, bitRate_);
    appendLe32(header_, out, 8); /* MSB-first DSD bytes */
    appendLe64(header_, out, sampleCount);
    appendLe32(header_, out, static_cast<uint32_t>(kDsfBlockBytes));
    appendLe32(header_, out, 0);
    appendId(header_, out, "data");
    appendLe64(header_, out, dataChunkSize);
    if (out != header_.size()) {
        setError("internal DSF header construction failed", &error);
        close();
        return LazerAudioErrorSource;
    }
    try {
        const size_t blockSize = static_cast<size_t>(kDsfBlockBytes) *
            static_cast<size_t>(channels_);
        blockCache_.assign(blockSize, 0);
        interleavedCache_.resize(blockSize);
    } catch (...) {
        setError("out of memory allocating a DFF channel block", &error);
        close();
        return LazerAudioErrorNoMemory;
    }
    virtualPosition_ = 0;
    cachedBlock_ = -1;
    lastError_.clear();
    return LazerAudioOk;
}

bool DffDsfReader::parseDstData(const Chunk &chunk, std::string &error) {
    const uint64_t end = chunk.payloadOffset + chunk.size;
    Chunk frameRateChunk{};
    if (chunk.size < 18 || !readChunk(chunk.payloadOffset, end, frameRateChunk, error) ||
        !isId(frameRateChunk.id, "FRTE") || frameRateChunk.size != 6) {
        if (lastError_.empty()) {
            setError("DFF DST data must begin with a six-byte FRTE chunk", &error);
        }
        return false;
    }

    std::array<uint8_t, 6> frameRateData{};
    if (!readAt(frameRateChunk.payloadOffset, frameRateData.data(), frameRateData.size())) {
        setError("could not read the DFF FRTE frame count and rate", &error);
        return false;
    }
    const uint32_t declaredFrames = readBe32(frameRateData.data());
    const uint32_t frameRate = (static_cast<uint32_t>(frameRateData[4]) << 8) |
        static_cast<uint32_t>(frameRateData[5]);
    if (declaredFrames == 0 || frameRate != kDffDstFrameRate) {
        setError("DFF DST FRTE must declare a nonzero frame count at 75 frames per second", &error);
        return false;
    }

    dstDataStart_ = frameRateChunk.nextOffset;
    dstDataEnd_ = end;
    dstFrameRate_ = frameRate;
    dstFrameCount_ = declaredFrames;
    dstFrameCursor_ = 0;
    dstNextChunkOffset_ = dstDataStart_;
    dstSeekPoints_.clear();

    uint32_t parsedFrames = 0;
    uint32_t crcCount = 0;
    bool previousWasFrame = false;
    bool previousFrameHadCrc = false;
    bool sawCrc = false;
    uint64_t position = dstDataStart_;
    while (position < dstDataEnd_) {
        Chunk local{};
        if (!readChunk(position, dstDataEnd_, local, error)) return false;
        if (isId(local.id, "DSTF")) {
            if (local.size < 2 || local.size > static_cast<uint64_t>(
                    INT_MAX - AV_INPUT_BUFFER_PADDING_SIZE)) {
                setError("DFF DSTF frame size is outside the FFmpeg packet range", &error);
                return false;
            }
            if (previousWasFrame && sawCrc && !previousFrameHadCrc) {
                setError("DFF DSTC chunks must occur after every DSTF once CRCs are present", &error);
                return false;
            }
            if (parsedFrames >= declaredFrames) {
                setError("DFF DST sound data contains more frames than FRTE declares", &error);
                return false;
            }
            if (parsedFrames % kDstSeekIntervalFrames == 0) {
                try {
                    dstSeekPoints_.push_back({parsedFrames, position});
                } catch (...) {
                    setError("out of memory indexing DFF DST frames", &error);
                    unsupported_ = true;
                    return false;
                }
            }
            ++parsedFrames;
            previousWasFrame = true;
            previousFrameHadCrc = false;
        } else if (isId(local.id, "DSTC")) {
            if (!previousWasFrame || previousFrameHadCrc || local.size != 4) {
                setError("DFF DSTC must be a single four-byte chunk immediately after a DSTF", &error);
                return false;
            }
            ++crcCount;
            sawCrc = true;
            previousFrameHadCrc = true;
        } else {
            setError("unsupported chunk inside DFF DST sound data", &error);
            unsupported_ = true;
            return false;
        }
        position = local.nextOffset;
    }
    if (position != dstDataEnd_ || parsedFrames != declaredFrames ||
        (crcCount != 0 && crcCount != declaredFrames)) {
        setError("DFF FRTE frame count or optional DSTC sequence does not match DSTF data", &error);
        return false;
    }
    if (crcCount != 0) {
        /* FFmpeg's public DST decoder returns filtered float PCM, not the original DSD bytes needed
         * to recompute DSDIFF's per-frame CRC. Never accept checksum-bearing input without checking it. */
        unsupported_ = true;
        setError("DFF DSTC checksums are present but cannot be verified by the current FFmpeg decoder", &error);
        return false;
    }
    return true;
}

int32_t DffDsfReader::readDstFrame(std::vector<uint8_t> &destination, uint32_t &frameIndex) {
    if (!isDst_ || dstFrameCursor_ >= dstFrameCount_) return isDst_ ? 0 : -1;
    Chunk frame{};
    std::string error;
    if (!readChunk(dstNextChunkOffset_, dstDataEnd_, frame, error) ||
        !isId(frame.id, "DSTF") || frame.size < 2 || frame.size > static_cast<uint64_t>(
            INT_MAX - AV_INPUT_BUFFER_PADDING_SIZE)) {
        lastError_ = error.empty() ? "DFF DST frame index no longer points to a DSTF chunk" : error;
        return -1;
    }
    try {
        destination.resize(static_cast<size_t>(frame.size) + AV_INPUT_BUFFER_PADDING_SIZE);
    } catch (...) {
        lastError_ = "out of memory reading a DFF DST frame";
        return -1;
    }
    if (!readAt(frame.payloadOffset, destination.data(), static_cast<size_t>(frame.size))) {
        lastError_ = "could not read DFF DST frame payload";
        return -1;
    }
    std::memset(destination.data() + frame.size, 0, AV_INPUT_BUFFER_PADDING_SIZE);
    frameIndex = dstFrameCursor_++;
    dstNextChunkOffset_ = frame.nextOffset;
    return static_cast<int32_t>(destination.size());
}

bool DffDsfReader::seekDstFrame(uint32_t frameIndex) {
    if (!isDst_ || frameIndex > dstFrameCount_ || dstSeekPoints_.empty()) return false;
    if (frameIndex == dstFrameCount_) {
        dstFrameCursor_ = frameIndex;
        dstNextChunkOffset_ = dstDataEnd_;
        return true;
    }
    const DstSeekPoint *checkpoint = &dstSeekPoints_.front();
    for (const DstSeekPoint &candidate : dstSeekPoints_) {
        if (candidate.frameIndex > frameIndex) break;
        checkpoint = &candidate;
    }
    uint32_t cursor = checkpoint->frameIndex;
    uint64_t offset = checkpoint->chunkOffset;
    while (cursor < frameIndex) {
        Chunk skipped{};
        std::string error;
        if (!readChunk(offset, dstDataEnd_, skipped, error) || !isId(skipped.id, "DSTF")) {
            lastError_ = error.empty() ? "DFF DST seek crossed a non-DSTF chunk" : error;
            return false;
        }
        offset = skipped.nextOffset;
        ++cursor;
    }
    dstFrameCursor_ = cursor;
    dstNextChunkOffset_ = offset;
    return true;
}

bool DffDsfReader::loadBlock(uint64_t blockIndex) {
    if (blockIndex > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) return false;
    if (cachedBlock_ == static_cast<int64_t>(blockIndex)) return true;
    const uint64_t firstByte = blockIndex * kDsfBlockBytes;
    if (firstByte >= paddedBytesPerChannel_) return false;
    std::fill(blockCache_.begin(), blockCache_.end(), static_cast<uint8_t>(0));
    const uint64_t validBytes = std::min(kDsfBlockBytes, bytesPerChannel_ - firstByte);
    uint64_t rawOffset = 0;
    uint64_t rawCount = 0;
    if (!checkedMultiply(firstByte, static_cast<uint64_t>(channels_), rawOffset) ||
        !checkedAdd(dataOffset_, rawOffset, rawOffset) ||
        !checkedMultiply(validBytes, static_cast<uint64_t>(channels_), rawCount) ||
        rawCount > std::numeric_limits<size_t>::max()) return false;
    if (rawCount > interleavedCache_.size() ||
        !readAt(rawOffset, interleavedCache_.data(), static_cast<size_t>(rawCount))) {
        lastError_ = "could not read DFF audio data";
        return false;
    }
    for (uint64_t byte = 0; byte < validBytes; ++byte) {
        for (int channel = 0; channel < channels_; ++channel) {
            blockCache_[static_cast<size_t>(channel) * kDsfBlockBytes +
                static_cast<size_t>(byte)] = interleavedCache_[static_cast<size_t>(byte) * channels_ +
                static_cast<size_t>(channel)];
        }
    }
    cachedBlock_ = static_cast<int64_t>(blockIndex);
    return true;
}

int DffDsfReader::read(uint8_t *destination, int capacity) {
    if (destination == nullptr || capacity < 0) return -1;
    if (capacity == 0 || virtualPosition_ >= virtualLength_) return 0;
    const uint64_t available = virtualLength_ - virtualPosition_;
    const size_t wanted = static_cast<size_t>(std::min<uint64_t>(available,
        static_cast<uint64_t>(capacity)));
    size_t written = 0;
    while (written < wanted) {
        if (virtualPosition_ < kDsfHeaderBytes) {
            const size_t count = static_cast<size_t>(std::min<uint64_t>(wanted - written,
                kDsfHeaderBytes - virtualPosition_));
            std::memcpy(destination + written, header_.data() + virtualPosition_, count);
            virtualPosition_ += count;
            written += count;
            continue;
        }
        const uint64_t dataPosition = virtualPosition_ - kDsfHeaderBytes;
        const uint64_t blockBytes = kDsfBlockBytes * static_cast<uint64_t>(channels_);
        const uint64_t blockIndex = dataPosition / blockBytes;
        const uint64_t withinBlock = dataPosition % blockBytes;
        const int channel = static_cast<int>(withinBlock / kDsfBlockBytes);
        const uint64_t channelByte = withinBlock % kDsfBlockBytes;
        if (!loadBlock(blockIndex)) return -1;
        const size_t count = static_cast<size_t>(std::min<uint64_t>(wanted - written,
            kDsfBlockBytes - channelByte));
        const size_t cacheOffset = static_cast<size_t>(channel) * kDsfBlockBytes +
            static_cast<size_t>(channelByte);
        std::memcpy(destination + written, blockCache_.data() + cacheOffset, count);
        virtualPosition_ += count;
        written += count;
    }
    return static_cast<int>(written);
}

int64_t DffDsfReader::seek(int64_t offset, int whence) {
    if (whence == AVSEEK_SIZE) return length();
    whence &= ~AVSEEK_FORCE;
    int64_t base = 0;
    if (whence == SEEK_SET) {
        base = 0;
    } else if (whence == SEEK_CUR) {
        if (virtualPosition_ > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) return -1;
        base = static_cast<int64_t>(virtualPosition_);
    } else if (whence == SEEK_END) {
        base = length();
    } else {
        return -1;
    }
    if ((offset > 0 && base > std::numeric_limits<int64_t>::max() - offset) ||
        (offset < 0 && base < std::numeric_limits<int64_t>::min() - offset)) return -1;
    const int64_t target = base + offset;
    if (target < 0 || target > length()) return -1;
    virtualPosition_ = static_cast<uint64_t>(target);
    return target;
}

int64_t DffDsfReader::length() const noexcept {
    return virtualLength_ <= static_cast<uint64_t>(std::numeric_limits<int64_t>::max())
        ? static_cast<int64_t>(virtualLength_) : -1;
}

void DffDsfReader::close() noexcept {
    if (file_ != nullptr) {
        std::fclose(file_);
        file_ = nullptr;
    }
    reader_ = nullptr;
    sourceLength_ = -1;
    dataOffset_ = 0;
    dataBytes_ = 0;
    bytesPerChannel_ = 0;
    paddedBytesPerChannel_ = 0;
    virtualLength_ = 0;
    virtualPosition_ = 0;
    bitRate_ = 0;
    channels_ = 0;
    unsupported_ = false;
    compressionIsDst_ = false;
    isDst_ = false;
    dstDataStart_ = 0;
    dstDataEnd_ = 0;
    dstNextChunkOffset_ = 0;
    dstFrameRate_ = 0;
    dstFrameCount_ = 0;
    dstFrameCursor_ = 0;
    dstSeekPoints_.clear();
    cachedBlock_ = -1;
    header_.fill(0);
    blockCache_.clear();
    interleavedCache_.clear();
    lastError_.clear();
}

}  // namespace lazer::audio
