#include "dsd_pcm_decoder.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <limits>
#include <new>
#include <string>
#include <vector>

#include <jni.h>
#include <unistd.h>

namespace {

struct FdReader {
    int descriptor = -1;
    int64_t startOffset = 0;
    int64_t length = -1;
    std::atomic<int64_t> position{0};
    std::atomic<bool> cancelled{false};
};

struct DecoderHandle {
    lazer::audio::DsdPcmDecoder decoder;
    lazer::audio::DsdPcmFormat format;
};

thread_local std::string lastOpenError;

int32_t LAZER_AUDIO_CALL readFd(void *opaque, uint8_t *destination, int32_t requested) {
    auto *reader = static_cast<FdReader *>(opaque);
    if (reader == nullptr || destination == nullptr || requested <= 0 ||
        reader->cancelled.load(std::memory_order_acquire)) {
        return LAZER_AUDIO_READER_IO_ERROR;
    }
    for (;;) {
        const int64_t position = reader->position.load(std::memory_order_acquire);
        if (position < 0 || reader->length < 0 || position > reader->length) {
            return LAZER_AUDIO_READER_IO_ERROR;
        }
        if (position == reader->length) return LAZER_AUDIO_READER_EOF;
        const int64_t remaining = reader->length - position;
        const size_t bytes = static_cast<size_t>(std::min<int64_t>(requested, remaining));
        const int64_t absolute = reader->startOffset + position;
        if (absolute < reader->startOffset || absolute > std::numeric_limits<off_t>::max()) {
            return LAZER_AUDIO_READER_IO_ERROR;
        }
        ssize_t count;
        do {
            count = pread(reader->descriptor, destination, bytes, static_cast<off_t>(absolute));
        } while (count < 0 && errno == EINTR &&
            !reader->cancelled.load(std::memory_order_acquire));
        if (count < 0) return LAZER_AUDIO_READER_IO_ERROR;
        if (count == 0) return LAZER_AUDIO_READER_EOF;
        int64_t expected = position;
        if (reader->position.compare_exchange_weak(expected, position + count,
                std::memory_order_acq_rel, std::memory_order_acquire)) {
            return static_cast<int32_t>(count);
        }
    }
}

int64_t LAZER_AUDIO_CALL seekFd(void *opaque, int64_t position) {
    auto *reader = static_cast<FdReader *>(opaque);
    if (reader == nullptr || reader->cancelled.load(std::memory_order_acquire) ||
        position < 0 || position > reader->length) return -1;
    reader->position.store(position, std::memory_order_release);
    return position;
}

int64_t LAZER_AUDIO_CALL lengthFd(void *opaque) {
    const auto *reader = static_cast<FdReader *>(opaque);
    return reader != nullptr ? reader->length : -1;
}

void LAZER_AUDIO_CALL cancelFd(void *opaque) {
    auto *reader = static_cast<FdReader *>(opaque);
    if (reader != nullptr) reader->cancelled.store(true, std::memory_order_release);
}

void LAZER_AUDIO_CALL closeFd(void *opaque) {
    auto *reader = static_cast<FdReader *>(opaque);
    if (reader == nullptr) return;
    if (reader->descriptor >= 0) close(reader->descriptor);
    delete reader;
}

jstring toJavaString(JNIEnv *environment, const std::string &value) {
    return environment->NewStringUTF(value.c_str());
}

DecoderHandle *fromHandle(jlong handle) {
    return reinterpret_cast<DecoderHandle *>(static_cast<intptr_t>(handle));
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_dev_naominet_lazer_AndroidDsdPcmNative_nativeOpen(
    JNIEnv *environment, jclass, jint descriptor, jlong startOffset, jlong length,
    jint targetSampleRate, jboolean doP, jlongArray outputInfo) {
    lastOpenError.clear();
    if (descriptor < 0 || startOffset < 0 || length <= 0 || targetSampleRate < 0 ||
        outputInfo == nullptr || environment->GetArrayLength(outputInfo) < 5 ||
        startOffset > std::numeric_limits<int64_t>::max() - length) {
        lastOpenError = "invalid DSD file descriptor or length";
        return 0;
    }
    const int ownedDescriptor = dup(descriptor);
    if (ownedDescriptor < 0) {
        lastOpenError = "could not duplicate the selected DSD file descriptor";
        return 0;
    }
    auto *readerContext = new (std::nothrow) FdReader();
    auto *handle = new (std::nothrow) DecoderHandle();
    if (readerContext == nullptr || handle == nullptr) {
        close(ownedDescriptor);
        delete readerContext;
        delete handle;
        lastOpenError = "not enough memory to initialize DSD playback";
        return 0;
    }
    readerContext->descriptor = ownedDescriptor;
    readerContext->startOffset = startOffset;
    readerContext->length = length;

    LazerAudioReader reader{};
    reader.read = &readFd;
    reader.seek = &seekFd;
    reader.length = &lengthFd;
    reader.close = &closeFd;
    reader.context = readerContext;
    reader.cancel = &cancelFd;
    const int32_t result = handle->decoder.open(reader, targetSampleRate, handle->format,
        doP == JNI_TRUE);
    if (result != LazerAudioOk) {
        lastOpenError = handle->decoder.lastError();
        if (lastOpenError.empty()) lastOpenError = "the selected file is not a supported DSD stream";
        handle->decoder.close();
        delete handle;
        return 0;
    }

    const jlong values[] = {
        handle->format.sampleRate,
        handle->format.channels,
        handle->format.dsdRateMultiplier,
        handle->format.durationMillis,
        handle->format.totalFrames,
    };
    environment->SetLongArrayRegion(outputInfo, 0, 5, values);
    if (environment->ExceptionCheck()) {
        handle->decoder.close();
        delete handle;
        lastOpenError = "could not publish the decoded DSD format";
        environment->ExceptionClear();
        return 0;
    }
    return static_cast<jlong>(reinterpret_cast<intptr_t>(handle));
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_naominet_lazer_AndroidDsdPcmNative_nativeRead(
    JNIEnv *environment, jclass, jlong rawHandle, jbyteArray destination, jint capacityFrames) {
    DecoderHandle *handle = fromHandle(rawHandle);
    if (handle == nullptr || destination == nullptr || capacityFrames <= 0 ||
        capacityFrames > 65'536) return LazerAudioErrorInvalidArgument;
    const int32_t frameBytes = handle->decoder.frameBytes();
    if (frameBytes <= 0 || static_cast<int64_t>(capacityFrames) * frameBytes >
            environment->GetArrayLength(destination)) {
        return LazerAudioErrorInvalidArgument;
    }
    std::vector<uint8_t> pcm;
    try {
        pcm.resize(static_cast<size_t>(capacityFrames) * static_cast<size_t>(frameBytes));
    } catch (...) {
        return LazerAudioErrorNoMemory;
    }
    int32_t frames = 0;
    bool endOfStream = false;
    const int32_t result = handle->decoder.readFrames(
        pcm.data(), capacityFrames, frames, endOfStream);
    if (result != LazerAudioOk) return result;
    if (frames > 0) {
        const jsize byteCount = static_cast<jsize>(frames * frameBytes);
        environment->SetByteArrayRegion(destination, 0, byteCount,
            reinterpret_cast<const jbyte *>(pcm.data()));
        if (environment->ExceptionCheck()) return LazerAudioErrorNoMemory;
        return frames;
    }
    return endOfStream ? 0 : LazerAudioErrorCancelled;
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_naominet_lazer_AndroidDsdPcmNative_nativeSeek(
    JNIEnv *, jclass, jlong rawHandle, jlong positionMillis) {
    DecoderHandle *handle = fromHandle(rawHandle);
    if (handle == nullptr) return LazerAudioErrorState;
    return handle->decoder.seek(positionMillis);
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_naominet_lazer_AndroidDsdPcmNative_nativeTotalFrames(JNIEnv *, jclass, jlong rawHandle) {
    DecoderHandle *handle = fromHandle(rawHandle);
    return handle != nullptr ? handle->format.totalFrames : 0;
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_naominet_lazer_AndroidDsdPcmNative_nativeSampleRate(JNIEnv *, jclass, jlong rawHandle) {
    DecoderHandle *handle = fromHandle(rawHandle);
    return handle != nullptr ? handle->format.sampleRate : 0;
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_naominet_lazer_AndroidDsdPcmNative_nativeLastError(
    JNIEnv *environment, jclass, jlong rawHandle) {
    DecoderHandle *handle = fromHandle(rawHandle);
    return toJavaString(environment, handle != nullptr ? handle->decoder.lastError() : lastOpenError);
}

extern "C" JNIEXPORT void JNICALL
Java_dev_naominet_lazer_AndroidDsdPcmNative_nativeClose(JNIEnv *, jclass, jlong rawHandle) {
    DecoderHandle *handle = fromHandle(rawHandle);
    if (handle == nullptr) return;
    handle->decoder.close();
    delete handle;
}
