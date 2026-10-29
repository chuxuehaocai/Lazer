#include "dsd_pcm_decoder.h"

#include <algorithm>
#include <cstring>
#include <limits>
#include <utility>

namespace lazer::audio {
namespace {

uint32_t readLe32(const uint8_t *bytes) {
    return static_cast<uint32_t>(bytes[0]) |
        (static_cast<uint32_t>(bytes[1]) << 8U) |
        (static_cast<uint32_t>(bytes[2]) << 16U) |
        (static_cast<uint32_t>(bytes[3]) << 24U);
}

uint64_t readLe64(const uint8_t *bytes) {
    return static_cast<uint64_t>(readLe32(bytes)) |
        (static_cast<uint64_t>(readLe32(bytes + 4)) << 32U);
}

int64_t readDsfBitCount(const LazerAudioReader &reader, int64_t &dsdBitRate) {
    dsdBitRate = 0;
    if (reader.read == nullptr || reader.seek == nullptr || reader.length == nullptr ||
        reader.length(reader.context) < 72 || reader.seek(reader.context, 0) != 0) return 0;
    uint8_t header[72]{};
    int32_t bytesRead = 0;
    while (bytesRead < static_cast<int32_t>(sizeof(header))) {
        const int32_t count = reader.read(reader.context, header + bytesRead,
            static_cast<int32_t>(sizeof(header)) - bytesRead);
        if (count <= 0 || count > static_cast<int32_t>(sizeof(header)) - bytesRead) break;
        bytesRead += count;
    }
    if (reader.seek(reader.context, 0) != 0 || bytesRead != static_cast<int32_t>(sizeof(header)) ||
        std::memcmp(header, "DSD ", 4) != 0 || std::memcmp(header + 28, "fmt ", 4) != 0) return 0;
    const uint32_t channels = readLe32(header + 52);
    const uint32_t sampleFrequency = readLe32(header + 56);
    const uint64_t sampleCount = readLe64(header + 64);
    if (channels == 0 || channels > 8 || sampleFrequency == 0 || sampleCount == 0 ||
        sampleCount > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) return 0;
    dsdBitRate = sampleFrequency;
    return static_cast<int64_t>(sampleCount);
}

}  // namespace

DsdPcmDecoder::DsdPcmDecoder() : source_(&log_) {}

DsdPcmDecoder::~DsdPcmDecoder() {
    close();
}

int32_t DsdPcmDecoder::open(
    const LazerAudioReader &reader, int32_t targetSampleRate, DsdPcmFormat &format, bool doP) {
    close();
    {
        std::lock_guard guard(mutex_);
        lastError_.clear();
        finished_ = false;
        endOfStream_ = false;
        cancelled_.store(false, std::memory_order_release);
    }
    if (reader.read == nullptr || targetSampleRate < 0) {
        setFailure("DSD decoder requires a readable source and a non-negative output sample rate");
        return LazerAudioErrorInvalidArgument;
    }

    reader_ = reader;
    int64_t dsfBitRate = 0;
    const int64_t dsfBitCount = readDsfBitCount(reader_, dsfBitRate);
    LazerAudioOpenParams params{};
    params.struct_size = sizeof(params);
    params.start_millis = 0;
    params.duration_hint_millis = 0;
    params.cue_start_frame75 = 0;
    params.cue_end_frame75 = 0;
    params.replay_gain_db = 0.0;

    int32_t result = source_.openReader(reader_, params);
    if (result != LazerAudioOk) {
        setFailure(source_.lastError().empty() ? "could not open DSD source" : source_.lastError());
        source_.close();
        return result;
    }
    if (dsfBitCount > 0 && dsfBitRate > 0) {
        source_.setExactDsdDuration(dsfBitCount, dsfBitRate);
    }
    const StreamDescription &description = source_.description();
    if (!description.dsd || description.channels <= 0 || description.channels > 8 ||
        description.dsdRateMultiplier < 64 || description.dsdRateMultiplier > 1024) {
        setFailure("source is not supported mono-to-7.1 DSD audio");
        source_.close();
        return LazerAudioErrorUnsupported;
    }

    if (doP) {
        if (!description.rawDsd || description.channels != 2 || description.sampleRate <= 0 ||
            description.sampleRate % 2 != 0) {
            setFailure("Android DoP requires raw stereo DSD with an exact carrier clock");
            source_.close();
            return LazerAudioErrorUnsupported;
        }
        const int32_t carrierRate = description.sampleRate / 2;
        if (targetSampleRate != 0 && targetSampleRate != carrierRate) {
            setFailure("DoP requires the exact 24-bit carrier rate at half the DSD byte clock");
            source_.close();
            return LazerAudioErrorUnsupported;
        }
        targetSampleRate = carrierRate;
    } else if (targetSampleRate == 0) {
        /* Keep DSD64 at the common 176.4 kHz PCM rate and cap higher-rate DSD at 192 kHz, which
         * AudioTrack devices commonly accept. Callers may still request a specific PCM rate. */
        targetSampleRate = std::min(description.sampleRate / 2, 192'000);
        if (targetSampleRate <= 0) {
            setFailure("DSD source rate cannot be mapped to an Android PCM output rate");
            source_.close();
            return LazerAudioErrorUnsupported;
        }
    }

    TargetFormat target{};
    target.sampleRate = targetSampleRate;
    target.channels = description.channels;
    target.bitsPerSample = doP ? 24 : 0;
    target.containerBitsPerSample = 0;
    target.doP = doP;
    result = source_.setTargetFormat(target);
    if (result != LazerAudioOk) {
        setFailure(source_.lastError().empty() ? "could not configure DSD-to-PCM conversion"
                                               : source_.lastError());
        source_.close();
        return result;
    }

    const int64_t bytesPerSample = doP ? 3 : static_cast<int64_t>(sizeof(float));
    const int64_t frameBytes = static_cast<int64_t>(description.channels) * bytesPerSample;
    if (frameBytes <= 0 || frameBytes > std::numeric_limits<int32_t>::max()) {
        setFailure("DSD output channel layout is invalid");
        source_.close();
        return LazerAudioErrorUnsupported;
    }
    {
        std::lock_guard guard(mutex_);
        frameBytes_ = static_cast<int32_t>(frameBytes);
        ring_.assign(static_cast<size_t>(kRingCapacityFrames) * frameBytes_, 0);
        clearQueuedFramesLocked();
        opened_ = true;
    }
    format.sampleRate = targetSampleRate;
    format.channels = description.channels;
    format.dsdRateMultiplier = description.dsdRateMultiplier;
    format.durationMillis = description.durationMillis;
    format.totalFrames = dsfBitCount > 0 && dsfBitRate > 0
        ? av_rescale_q_rnd(dsfBitCount, AVRational{1, static_cast<int>(dsfBitRate)},
            AVRational{1, targetSampleRate}, AV_ROUND_NEAR_INF)
        : source_.totalOutputFrames();

    try {
        worker_ = std::thread(&DsdPcmDecoder::pumpLoop, this);
    } catch (...) {
        {
            std::lock_guard guard(mutex_);
            opened_ = false;
        }
        setFailure("could not start the DSD decoder worker");
        source_.close();
        return LazerAudioErrorNoMemory;
    }
    return LazerAudioOk;
}

int32_t DsdPcmDecoder::readFrames(
    uint8_t *destination, int32_t capacityFrames, int32_t &frameCount, bool &endOfStream) {
    frameCount = 0;
    endOfStream = false;
    if (destination == nullptr || capacityFrames <= 0) {
        return LazerAudioErrorInvalidArgument;
    }

    std::unique_lock guard(mutex_);
    if (!opened_) return LazerAudioErrorState;
    if (frameBytes_ <= 0) return LazerAudioErrorState;
    changed_.wait(guard, [this, capacityFrames] {
        const int32_t wanted = std::min(capacityFrames, kPreferredReadFrames);
        return ringSizeFrames_ >= wanted || endOfStream_ || finished_ ||
            cancelled_.load(std::memory_order_acquire);
    });
    if (ringSizeFrames_ == 0) {
        if (!lastError_.empty()) return LazerAudioErrorDecode;
        endOfStream = endOfStream_ || finished_;
        return cancelled_.load(std::memory_order_acquire) && !endOfStream
            ? LazerAudioErrorCancelled : LazerAudioOk;
    }

    frameCount = std::min(capacityFrames, ringSizeFrames_);
    const int32_t firstFrames = std::min(frameCount, kRingCapacityFrames - ringReadFrame_);
    std::memcpy(destination,
        ring_.data() + static_cast<size_t>(ringReadFrame_) * frameBytes_,
        static_cast<size_t>(firstFrames) * frameBytes_);
    const int32_t secondFrames = frameCount - firstFrames;
    if (secondFrames > 0) {
        std::memcpy(destination + static_cast<size_t>(firstFrames) * frameBytes_, ring_.data(),
            static_cast<size_t>(secondFrames) * frameBytes_);
    }
    ringReadFrame_ = (ringReadFrame_ + frameCount) % kRingCapacityFrames;
    ringSizeFrames_ -= frameCount;
    endOfStream = endOfStream_ && ringSizeFrames_ == 0;
    changed_.notify_all();
    return LazerAudioOk;
}

int32_t DsdPcmDecoder::seek(int64_t positionMillis) {
    if (positionMillis < 0) return LazerAudioErrorInvalidArgument;
    {
        std::lock_guard guard(mutex_);
        if (!opened_ || cancelled_.load(std::memory_order_acquire)) return LazerAudioErrorState;
        source_.requestSeek(positionMillis);
        clearQueuedFramesLocked();
        endOfStream_ = false;
        finished_ = false;
        lastError_.clear();
    }
    changed_.notify_all();
    return LazerAudioOk;
}

void DsdPcmDecoder::close() {
    cancelled_.store(true, std::memory_order_release);
    {
        std::lock_guard guard(mutex_);
        opened_ = false;
        finished_ = true;
        endOfStream_ = false;
    }
    source_.interruptReader();
    changed_.notify_all();
    if (worker_.joinable()) worker_.join();
    source_.close();
    {
        std::lock_guard guard(mutex_);
        clearQueuedFramesLocked();
        ring_.clear();
        frameBytes_ = 0;
        reader_ = {};
    }
    changed_.notify_all();
}

int32_t DsdPcmDecoder::frameBytes() const {
    std::lock_guard guard(mutex_);
    return frameBytes_;
}

std::string DsdPcmDecoder::lastError() const {
    std::lock_guard guard(mutex_);
    return lastError_;
}

int32_t DsdPcmDecoder::accept(const uint8_t *bytes, int32_t frameCount) {
    if (bytes == nullptr || frameCount <= 0) return 0;
    int32_t accepted = 0;
    std::unique_lock guard(mutex_);
    if (!opened_ || frameBytes_ <= 0) return 0;
    while (accepted < frameCount &&
        !cancelled_.load(std::memory_order_acquire) && !source_.hasPendingSeek()) {
        changed_.wait(guard, [this] {
            return cancelled_.load(std::memory_order_acquire) || source_.hasPendingSeek() ||
                ringSizeFrames_ < kRingCapacityFrames;
        });
        if (cancelled_.load(std::memory_order_acquire) || source_.hasPendingSeek()) break;

        const int32_t frames = std::min(frameCount - accepted,
            kRingCapacityFrames - ringSizeFrames_);
        const int32_t firstFrames = std::min(frames, kRingCapacityFrames - ringWriteFrame_);
        const uint8_t *input = bytes + static_cast<size_t>(accepted) * frameBytes_;
        std::memcpy(ring_.data() + static_cast<size_t>(ringWriteFrame_) * frameBytes_, input,
            static_cast<size_t>(firstFrames) * frameBytes_);
        const int32_t secondFrames = frames - firstFrames;
        if (secondFrames > 0) {
            std::memcpy(ring_.data(), input + static_cast<size_t>(firstFrames) * frameBytes_,
                static_cast<size_t>(secondFrames) * frameBytes_);
        }
        ringWriteFrame_ = (ringWriteFrame_ + frames) % kRingCapacityFrames;
        ringSizeFrames_ += frames;
        accepted += frames;
        changed_.notify_all();
    }
    return accepted;
}

bool DsdPcmDecoder::shouldPump() const {
    return !cancelled_.load(std::memory_order_acquire);
}

bool DsdPcmDecoder::isCancelled() const {
    return cancelled_.load(std::memory_order_acquire);
}

void DsdPcmDecoder::onSeekApplied() {
    std::lock_guard guard(mutex_);
    clearQueuedFramesLocked();
    endOfStream_ = false;
    finished_ = false;
    lastError_.clear();
    changed_.notify_all();
}

void DsdPcmDecoder::pumpLoop() {
    for (;;) {
        if (cancelled_.load(std::memory_order_acquire)) break;
        const int32_t result = source_.pump(*this);
        if (cancelled_.load(std::memory_order_acquire)) break;
        if (result != LazerAudioOk) {
            setFailure(source_.lastError().empty() ? "DSD decoding failed" : source_.lastError());
            break;
        }
        if (!source_.reachedEndOfStream()) {
            if (source_.hasPendingSeek()) continue;
            setFailure("DSD decoder stopped before the source reached EOF");
            break;
        }

        {
            std::lock_guard guard(mutex_);
            endOfStream_ = true;
        }
        changed_.notify_all();
        std::unique_lock guard(mutex_);
        changed_.wait(guard, [this] {
            return cancelled_.load(std::memory_order_acquire) || source_.hasPendingSeek();
        });
        if (cancelled_.load(std::memory_order_acquire)) break;
        endOfStream_ = false;
        lastError_.clear();
    }
    {
        std::lock_guard guard(mutex_);
        finished_ = true;
        if (cancelled_.load(std::memory_order_acquire)) endOfStream_ = false;
    }
    changed_.notify_all();
}

void DsdPcmDecoder::setFailure(std::string message) {
    {
        std::lock_guard guard(mutex_);
        lastError_ = std::move(message);
        finished_ = true;
        endOfStream_ = false;
    }
    changed_.notify_all();
}

void DsdPcmDecoder::clearQueuedFramesLocked() {
    ringReadFrame_ = 0;
    ringWriteFrame_ = 0;
    ringSizeFrames_ = 0;
}

}  // namespace lazer::audio
