#include "audio_output.h"
#include "log_proxy.h"
#include <aaudio/AAudio.h>

#include <algorithm>
#include <array>
#include <deque>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

struct AAudioStreamBuilder {
    int32_t format = AAUDIO_FORMAT_PCM_FLOAT;
    int32_t rate = 0;
    int32_t channels = 2;
    AAudioStream_errorCallback errorCallback = nullptr;
    void *errorUserData = nullptr;
};
struct AAudioStream {
    int32_t format = AAUDIO_FORMAT_PCM_FLOAT;
    int32_t rate = 48000;
    int32_t channels = 2;
    int32_t buffer = 960;
    int32_t device = 7;
    int64_t written = 0, read = 0;
    int32_t state = AAUDIO_STREAM_STATE_OPEN;
};

namespace {
AAudioStream *active = nullptr;
int builders = 0, streams = 0;
int openAttempts = 0, pauses = 0, starts = 0;
int negotiatedRate = 48000, negotiatedChannels = 2;
bool rejectFloat = false, rejectAll = false, waitDisconnect = false;
bool resizeFails = false;
int requestedRate = -1;
AAudioStream_errorCallback activeErrorCallback = nullptr;
void *activeErrorUserData = nullptr;
std::deque<int32_t> writes;
std::vector<uint8_t> received;

void require(bool value, const char *message) {
    if (!value) throw std::runtime_error(message);
}

void LAZER_AUDIO_CALL captureLine(void *context, int32_t, const char *message) {
    auto *lines = static_cast<std::vector<std::string> *>(context);
    lines->emplace_back(message == nullptr ? std::string() : std::string(message));
}

size_t countContaining(const std::vector<std::string> &lines, const char *needle) {
    return static_cast<size_t>(std::count_if(lines.begin(), lines.end(),
        [needle](const std::string &line) { return line.find(needle) != std::string::npos; }));
}

void defaults() {
    require(builders == 0 && streams == 0, "native resources leaked");
    openAttempts = pauses = starts = 0;
    negotiatedRate = 48000;
    negotiatedChannels = 2;
    rejectFloat = rejectAll = waitDisconnect = resizeFails = false;
    requestedRate = -1;
    activeErrorCallback = nullptr;
    activeErrorUserData = nullptr;
    writes.clear();
    received.clear();
}

void lifecycle() {
    using namespace lazer::audio;
    defaults();
    auto output = createPlatformAudioOutput();
    AudioOutputRequest request;
    StreamDescription source;
    source.sampleRate = 44100;
    source.channels = 2;
    AudioOutputSession session;
    std::string error;
    require(output->open(request, source, session, error, nullptr) == LazerAudioOk, "open failed");
    require(requestedRate == 0, "normal PCM must use Android's preferred sample clock");
    require(session.target.sampleRate == 48000 && session.target.isFloat(), "negotiated PCM not reported");
    require(session.writeMode == OutputWriteMode::Variable && !session.primeBeforeStart,
        "variable PCM must be accounted for by the render loop, not the fixed-period priming ledger");
    require(!session.exclusive && !session.doP && !session.nativeDsd, "unsupported direct output advertised");
    require(session.formatSelection == LazerAudioFormatSelectionSharedMix, "shared output negotiation not reported");
    require(output->start(error) == LazerAudioOk, "start failed");
    require(output->start(error) == LazerAudioOk && starts == 1, "start must be idempotent");
    std::array<uint8_t, 80> bytes{};
    for (size_t i = 0; i < bytes.size(); ++i) bytes[i] = static_cast<uint8_t>(i);
    writes = {3, 2, 5};
    require(output->write(bytes.data(), 10, error) == 10, "write must return frames, not a success code");
    require(received == std::vector<uint8_t>(bytes.begin(), bytes.end()), "short writes lost or repeated PCM bytes");
    require(output->queuedFrames(error) == 10, "queue depth is wrong");
    require(output->drain(error) == OutputDrainResult::Pending, "tail drained too early");
    require(output->stop(error) == LazerAudioOk, "pause failed");
    require(output->stop(error) == LazerAudioOk && pauses == 1, "pause must be idempotent");
    require(output->queuedFrames(error) == 10, "pause must preserve queued audio");
    require(output->start(error) == LazerAudioOk, "resume failed");
    active->read = active->written;
    require(output->drain(error) == OutputDrainResult::Drained, "tail did not drain");
    active->read += 100; // Underrun clocks may run ahead of submitted audio.
    require(output->queuedFrames(error) == 0, "underrun produced a negative queue");
    require(output->reset(error) == LazerAudioOk, "seek flush failed");
    require(active->state == AAUDIO_STREAM_STATE_FLUSHED, "seek did not finish flushing");
    require(output->start(error) == LazerAudioOk, "start after seek failed");
    output->close();
    require(!output->isOpen(), "close retained the stream");
    require(output->waitForReady(0, error) == OutputWaitResult::Error, "closed device must fail readiness");
    require(builders == 0 && streams == 0, "lifecycle leaked resources");
}

void failuresAndFallback() {
    using namespace lazer::audio;
    defaults();
    auto output = createPlatformAudioOutput();
    AudioOutputRequest request;
    StreamDescription source;
    source.sampleRate = 44100;
    source.channels = 2;
    AudioOutputSession session;
    std::string error;
    rejectFloat = true;
    require(output->open(request, source, session, error, nullptr) == LazerAudioOk, "I16 fallback failed");
    require(openAttempts == 2 && session.target.frameBytes() == 4, "I16 output format not reported");
    std::array<uint8_t, 40> bytes{};
    writes = {3, 7};
    require(output->write(bytes.data(), 10, error) == 10 && received.size() == bytes.size(), "I16 short writes corrupted bytes");
    writes = {0};
    require(output->write(bytes.data(), 10, error) < 0 && !error.empty(), "zero-write timeout was not reported");
    error = "previous timeout";
    require(output->writableFrames(error) >= 0 && error.empty(), "stale errors poisoned readiness");
    active->written = active->buffer;
    active->read = 0;
    require(output->waitForReady(0, error) == OutputWaitResult::Timeout, "full queue must not spin as ready");
    active->state = AAUDIO_STREAM_STATE_DISCONNECTED;
    require(output->drain(error) == OutputDrainResult::Error, "disconnection was ignored");
    output->close();

    rejectAll = true;
    require(output->open(request, source, session, error, nullptr) < 0 && !output->isOpen(), "failed open kept a stream");
    require(streams == 0 && builders == 0, "failed opens leaked resources");
    rejectFloat = rejectAll = false;
    resizeFails = true;
    require(output->open(request, source, session, error, nullptr) < 0 && streams == 0, "failed buffer resize ignored");
    resizeFails = false;
    negotiatedChannels = 0;
    require(output->open(request, source, session, error, nullptr) < 0 && streams == 0, "invalid channel count accepted");
    negotiatedChannels = 2;
    require(output->open(request, source, session, error, nullptr) == LazerAudioOk, "reopen failed");
    waitDisconnect = true;
    require(output->start(error) == LazerAudioOk, "asynchronous start request failed");
    require(output->writableFrames(error) < 0 && !error.empty(), "asynchronous start disconnection ignored");
    output->close();
    require(builders == 0 && streams == 0, "failure recovery leaked resources");
}

void unsupportedPolicies() {
    using namespace lazer::audio;
    defaults();
    auto output = createPlatformAudioOutput();
    StreamDescription source;
    AudioOutputSession session;
    std::string error;
    for (int policy = 0; policy < 3; ++policy) {
        AudioOutputRequest request;
        request.bitPerfect = policy == 0;
        request.requireDoP = policy == 1;
        request.requireNativeDsd = policy == 2;
        require(output->open(request, source, session, error, nullptr) == LazerAudioErrorUnsupported,
            "Android must reject unsupported direct-output guarantees");
    }
    require(openAttempts == 0, "unsupported policies opened a mixed endpoint");
}

/* The endpoint belongs to the platform, not to this stream: another player, a call, an unplugged
 * headset or a route change takes it away, and AAudio reports that through the error callback
 * before any write can fail. The backend has to turn that into an immediate, named, once-only
 * record — and a fresh open has to come up connected again. */
void reclaimedEndpointIsReported() {
    using namespace lazer::audio;
    defaults();
    auto output = createPlatformAudioOutput();
    AudioOutputRequest request;
    StreamDescription source;
    source.sampleRate = 48000;
    source.channels = 2;
    AudioOutputSession session;
    std::string error;
    std::vector<std::string> lines;
    LogProxy log;
    log.install({&captureLine, &lines});
    require(output->open(request, source, session, error, &log) == LazerAudioOk, "open failed");
    require(activeErrorCallback != nullptr, "the platform error callback was not registered");
    require(session.description.find("device 7") != std::string::npos,
        "the session record does not name the endpoint");
    require(countContaining(lines, "device 7") == 1, "the opened endpoint was not logged once");
    require(output->start(error) == LazerAudioOk, "start failed");

    // The platform reclaims the endpoint while the stream is live.
    activeErrorCallback(active, activeErrorUserData, AAUDIO_ERROR_DISCONNECTED);
    require(output->queuedFrames(error) < 0 &&
        error.find("AAUDIO_ERROR_DISCONNECTED") != std::string::npos,
        "a reclaimed endpoint was not reported before a write failed");
    std::array<uint8_t, 16> bytes{};
    require(output->write(bytes.data(), 4, error) < 0, "a reclaimed endpoint accepted a write");
    require(output->writableFrames(error) < 0, "a reclaimed endpoint still reported writable frames");
    require(output->start(error) < 0, "a reclaimed endpoint was restarted");
    require(countContaining(lines, "disconnected") == 1,
        "the disconnect record was repeated or missing");
    output->close();

    // A stream opened after the loss is a new one: it must not inherit the record.
    require(output->open(request, source, session, error, &log) == LazerAudioOk, "reopen failed");
    require(output->queuedFrames(error) == 0 && error.empty(), "a retired loss poisoned the new stream");
    require(output->start(error) == LazerAudioOk, "resume after reopen failed");
    output->close();
    require(builders == 0 && streams == 0, "reclaim handling leaked resources");
}
} // namespace

aaudio_result_t AAudio_createStreamBuilder(AAudioStreamBuilder **builder) {
    *builder = new AAudioStreamBuilder;
    ++builders;
    return AAUDIO_OK;
}
aaudio_result_t AAudioStreamBuilder_delete(AAudioStreamBuilder *builder) {
    delete builder;
    --builders;
    return AAUDIO_OK;
}
void AAudioStreamBuilder_setDirection(AAudioStreamBuilder *, aaudio_direction_t value) {
    require(value == AAUDIO_DIRECTION_OUTPUT, "wrong stream direction");
}
void AAudioStreamBuilder_setFormat(AAudioStreamBuilder *builder, aaudio_format_t format) { builder->format = format; }
void AAudioStreamBuilder_setSharingMode(AAudioStreamBuilder *, aaudio_sharing_mode_t mode) {
    require(mode == AAUDIO_SHARING_MODE_SHARED, "unexpected exclusive request");
}
void AAudioStreamBuilder_setPerformanceMode(AAudioStreamBuilder *, aaudio_performance_mode_t) {}
void AAudioStreamBuilder_setChannelCount(AAudioStreamBuilder *builder, int32_t channels) { builder->channels = channels; }
void AAudioStreamBuilder_setSampleRate(AAudioStreamBuilder *builder, int32_t rate) { builder->rate = rate; }
void AAudioStreamBuilder_setErrorCallback(AAudioStreamBuilder *builder,
    AAudioStream_errorCallback callback, void *userData) {
    builder->errorCallback = callback;
    builder->errorUserData = userData;
}
aaudio_result_t AAudioStreamBuilder_openStream(AAudioStreamBuilder *builder, AAudioStream **stream) {
    ++openAttempts;
    // Some implementations may return an allocated stream on failure.
    *stream = new AAudioStream;
    ++streams;
    active = *stream;
    active->format = builder->format;
    active->rate = negotiatedRate;
    active->channels = negotiatedChannels;
    requestedRate = builder->rate;
    activeErrorCallback = builder->errorCallback;
    activeErrorUserData = builder->errorUserData;
    return rejectAll || (rejectFloat && builder->format == AAUDIO_FORMAT_PCM_FLOAT)
        ? AAUDIO_ERROR_INVALID_FORMAT : AAUDIO_OK;
}
aaudio_result_t AAudioStream_close(AAudioStream *stream) {
    delete stream;
    active = nullptr;
    --streams;
    return AAUDIO_OK;
}
int32_t AAudioStream_getSampleRate(AAudioStream *stream) { return stream->rate; }
int32_t AAudioStream_getChannelCount(AAudioStream *stream) { return stream->channels; }
aaudio_format_t AAudioStream_getFormat(AAudioStream *stream) { return stream->format; }
int32_t AAudioStream_getBufferCapacityInFrames(AAudioStream *) { return 960; }
int32_t AAudioStream_getBufferSizeInFrames(AAudioStream *stream) { return stream->buffer; }
int32_t AAudioStream_getFramesPerBurst(AAudioStream *) { return 192; }
int32_t AAudioStream_getDeviceId(AAudioStream *stream) { return stream->device; }
int32_t AAudioStream_setBufferSizeInFrames(AAudioStream *stream, int32_t frames) {
    if (resizeFails) return AAUDIO_ERROR_DISCONNECTED;
    return stream->buffer = frames;
}
aaudio_result_t AAudioStream_requestStart(AAudioStream *stream) { ++starts; stream->state = AAUDIO_STREAM_STATE_STARTING; return AAUDIO_OK; }
aaudio_result_t AAudioStream_requestPause(AAudioStream *stream) { ++pauses; stream->state = AAUDIO_STREAM_STATE_PAUSING; return AAUDIO_OK; }
aaudio_result_t AAudioStream_requestFlush(AAudioStream *stream) { stream->state = AAUDIO_STREAM_STATE_FLUSHING; return AAUDIO_OK; }
aaudio_stream_state_t AAudioStream_getState(AAudioStream *stream) { return stream->state; }
aaudio_result_t AAudioStream_waitForStateChange(AAudioStream *stream, aaudio_stream_state_t,
    aaudio_stream_state_t *next, int64_t) {
    if (waitDisconnect) stream->state = AAUDIO_STREAM_STATE_DISCONNECTED;
    // Legacy AAudio needs a write to complete STARTING, especially on resume.
    else if (stream->state == AAUDIO_STREAM_STATE_PAUSING) stream->state = AAUDIO_STREAM_STATE_PAUSED;
    else if (stream->state == AAUDIO_STREAM_STATE_FLUSHING) {
        stream->state = AAUDIO_STREAM_STATE_FLUSHED;
        stream->read = stream->written;
    }
    *next = stream->state;
    return AAUDIO_OK;
}
int64_t AAudioStream_getFramesWritten(AAudioStream *stream) { return stream->written; }
int64_t AAudioStream_getFramesRead(AAudioStream *stream) { return stream->read; }
aaudio_result_t AAudioStream_write(AAudioStream *stream, const void *bytes, int32_t frames, int64_t) {
    if (stream->state == AAUDIO_STREAM_STATE_STARTING) stream->state = AAUDIO_STREAM_STATE_STARTED;
    const int32_t accepted = writes.empty() ? frames : writes.front();
    if (!writes.empty()) writes.pop_front();
    if (accepted <= 0) return accepted;
    require(accepted <= frames, "backend submitted fewer frames than expected");
    const auto *begin = static_cast<const uint8_t *>(bytes);
    const int32_t frameBytes = stream->channels * (stream->format == AAUDIO_FORMAT_PCM_FLOAT ? 4 : 2);
    received.insert(received.end(), begin, begin + accepted * frameBytes);
    stream->written += accepted;
    return accepted;
}
const char *AAudio_convertResultToText(aaudio_result_t result) {
    switch (result) {
        case AAUDIO_OK: return "AAUDIO_OK";
        case AAUDIO_ERROR_DISCONNECTED: return "AAUDIO_ERROR_DISCONNECTED";
        case AAUDIO_ERROR_TIMEOUT: return "AAUDIO_ERROR_TIMEOUT";
        case AAUDIO_ERROR_INVALID_FORMAT: return "AAUDIO_ERROR_INVALID_FORMAT";
        default: return "fake AAudio error";
    }
}

int main() {
    try {
        lifecycle();
        failuresAndFallback();
        unsupportedPolicies();
        reclaimedEndpointIsReported();
        std::cout << "AAudio backend contract: all checks passed\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
