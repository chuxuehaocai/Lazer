#ifndef LAZER_FAKE_AAUDIO_H
#define LAZER_FAKE_AAUDIO_H
#include <cstdint>

using aaudio_result_t = int32_t;
using aaudio_stream_state_t = int32_t;
using aaudio_format_t = int32_t;
using aaudio_direction_t = int32_t;
using aaudio_sharing_mode_t = int32_t;
using aaudio_performance_mode_t = int32_t;
struct AAudioStream;
struct AAudioStreamBuilder;

constexpr int32_t AAUDIO_OK = 0;
constexpr int32_t AAUDIO_ERROR_DISCONNECTED = -899;
constexpr int32_t AAUDIO_ERROR_TIMEOUT = -885;
constexpr int32_t AAUDIO_ERROR_INVALID_FORMAT = -883;
constexpr int32_t AAUDIO_DIRECTION_OUTPUT = 0;
constexpr int32_t AAUDIO_FORMAT_PCM_I16 = 1;
constexpr int32_t AAUDIO_FORMAT_PCM_FLOAT = 2;
constexpr int32_t AAUDIO_SHARING_MODE_SHARED = 1;
constexpr int32_t AAUDIO_PERFORMANCE_MODE_NONE = 10;
constexpr int32_t AAUDIO_STREAM_STATE_UNKNOWN = 1;
constexpr int32_t AAUDIO_STREAM_STATE_OPEN = 2;
constexpr int32_t AAUDIO_STREAM_STATE_STARTING = 3;
constexpr int32_t AAUDIO_STREAM_STATE_STARTED = 4;
constexpr int32_t AAUDIO_STREAM_STATE_PAUSING = 5;
constexpr int32_t AAUDIO_STREAM_STATE_PAUSED = 6;
constexpr int32_t AAUDIO_STREAM_STATE_FLUSHING = 7;
constexpr int32_t AAUDIO_STREAM_STATE_FLUSHED = 8;
constexpr int32_t AAUDIO_STREAM_STATE_DISCONNECTED = 13;

aaudio_result_t AAudio_createStreamBuilder(AAudioStreamBuilder **builder);
aaudio_result_t AAudioStreamBuilder_delete(AAudioStreamBuilder *builder);
void AAudioStreamBuilder_setDirection(AAudioStreamBuilder *, aaudio_direction_t);
void AAudioStreamBuilder_setFormat(AAudioStreamBuilder *, aaudio_format_t);
void AAudioStreamBuilder_setSharingMode(AAudioStreamBuilder *, aaudio_sharing_mode_t);
void AAudioStreamBuilder_setPerformanceMode(AAudioStreamBuilder *, aaudio_performance_mode_t);
void AAudioStreamBuilder_setChannelCount(AAudioStreamBuilder *, int32_t);
void AAudioStreamBuilder_setSampleRate(AAudioStreamBuilder *, int32_t);
aaudio_result_t AAudioStreamBuilder_openStream(AAudioStreamBuilder *, AAudioStream **);
aaudio_result_t AAudioStream_close(AAudioStream *);
int32_t AAudioStream_getSampleRate(AAudioStream *);
int32_t AAudioStream_getChannelCount(AAudioStream *);
aaudio_format_t AAudioStream_getFormat(AAudioStream *);
int32_t AAudioStream_getBufferCapacityInFrames(AAudioStream *);
int32_t AAudioStream_getBufferSizeInFrames(AAudioStream *);
int32_t AAudioStream_getFramesPerBurst(AAudioStream *);
int32_t AAudioStream_setBufferSizeInFrames(AAudioStream *, int32_t);
aaudio_result_t AAudioStream_requestStart(AAudioStream *);
aaudio_result_t AAudioStream_requestPause(AAudioStream *);
aaudio_result_t AAudioStream_requestFlush(AAudioStream *);
aaudio_stream_state_t AAudioStream_getState(AAudioStream *);
aaudio_result_t AAudioStream_waitForStateChange(AAudioStream *, aaudio_stream_state_t,
    aaudio_stream_state_t *, int64_t);
int64_t AAudioStream_getFramesWritten(AAudioStream *);
int64_t AAudioStream_getFramesRead(AAudioStream *);
aaudio_result_t AAudioStream_write(AAudioStream *, const void *, int32_t, int64_t);
const char *AAudio_convertResultToText(aaudio_result_t);
#endif
