/* Contract test for the iOS RemoteIO backend.
 *
 * Compiles the production `output_remoteio.cpp` against a fake AudioUnit and a
 * fake AVAudioSession shim, so the backend's state machine — format choice,
 * queue accounting, underrun padding, start/stop/reset ordering and the honest
 * refusal of exclusive formats — is checked on every host, on every commit.
 * What this cannot check is whether the route really produces sound; see
 * docs/audio-engine-hardware-verification.md for the device checklist.
 */
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <AudioToolbox/AudioToolbox.h>

#include "audio_output.h"
#include "ios_audio_session.h"

namespace {

int failures = 0;

void check(bool condition, const char *what) {
    if (condition) return;
    std::printf("FAIL: %s\n", what);
    ++failures;
}

void checkEqual(int64_t actual, int64_t expected, const char *what) {
    if (actual == expected) return;
    std::printf("FAIL: %s (expected %lld, got %lld)\n", what,
        static_cast<long long>(expected), static_cast<long long>(actual));
    ++failures;
}

void checkNear(double actual, double expected, double tolerance, const char *what) {
    if (std::fabs(actual - expected) <= tolerance) return;
    std::printf("FAIL: %s (expected %f, got %f)\n", what, expected, actual);
    ++failures;
}

/* ------------------------------------------------------------------ */
/* Fake AudioUnit                                                      */
/* ------------------------------------------------------------------ */

struct FakeUnitState {
    AudioStreamBasicDescription format{};
    bool formatSet = false;
    UInt32 maximumFramesPerSlice = 0;
    AURenderCallbackStruct callback{};
    bool inputElementEnabled = true;
    bool initialized = false;
    bool running = false;
    int initializeCalls = 0;
    int uninitializeCalls = 0;
    int startCalls = 0;
    int stopCalls = 0;
    int resetCalls = 0;
    int disposeCalls = 0;
    int setFormatElement = -1;
    int setFormatScope = -1;
    double requestedSampleRate = 0.0;
};

FakeUnitState g_unit;
bool g_componentAvailable = true;
bool g_changeGrantedChannels = false;
int g_instancesCreated = 0;
int g_instancesDisposed = 0;
bool g_inRenderCallback = false;

/* Pulls `frames` from the backend's callback exactly as the device would. */
std::vector<float> pullAudio(int32_t frames, int32_t channels) {
    std::vector<float> samples(static_cast<size_t>(frames) * static_cast<size_t>(channels), -1.0f);
    AudioBufferList list{};
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = static_cast<UInt32>(channels);
    list.mBuffers[0].mDataByteSize = static_cast<UInt32>(samples.size() * sizeof(float));
    list.mBuffers[0].mData = samples.data();
    AudioUnitRenderActionFlags flags = 0;
    g_inRenderCallback = true;
    const OSStatus status = g_unit.callback.inputProc(g_unit.callback.inputProcRefCon, &flags,
        nullptr, 0, static_cast<UInt32>(frames), &list);
    g_inRenderCallback = false;
    checkEqual(status, noErr, "render callback returns noErr");
    return samples;
}

}  // namespace

/* Fake AudioToolbox implementation. */
AudioComponent AudioComponentFindNext(AudioComponent, const AudioComponentDescription *description) {
    if (!g_componentAvailable) return nullptr;
    check(description != nullptr && description->componentType == kAudioUnitType_Output,
        "looks up an output AudioUnit");
    check(description->componentSubType == kAudioUnitSubType_RemoteIO,
        "looks up RemoteIO specifically");
    return reinterpret_cast<AudioComponent>(&g_unit);
}

OSStatus AudioComponentInstanceNew(AudioComponent component, AudioUnit *outInstance) {
    check(!g_inRenderCallback, "the callback never creates an AudioUnit");
    if (component == nullptr || outInstance == nullptr) return -1;
    ++g_instancesCreated;
    g_unit = FakeUnitState{};
    *outInstance = reinterpret_cast<AudioUnit>(&g_unit);
    return noErr;
}

OSStatus AudioComponentInstanceDispose(AudioUnit unit) {
    check(!g_inRenderCallback, "the callback never disposes an AudioUnit");
    if (unit == nullptr) return -1;
    ++g_instancesDisposed;
    ++g_unit.disposeCalls;
    // The backend must not dispose a running unit.
    check(!g_unit.running, "disposes the unit only after stopping it");
    return noErr;
}

OSStatus AudioUnitSetProperty(AudioUnit unit, AudioUnitPropertyID id, AudioUnitScope scope,
    AudioUnitElement element, const void *data, UInt32 size) {
    if (unit == nullptr || data == nullptr) return -1;
    switch (id) {
        case kAudioOutputUnitProperty_EnableIO: {
            UInt32 enabled = 1;
            if (size == sizeof(enabled)) std::memcpy(&enabled, data, sizeof(enabled));
            checkEqual(element, 1, "EnableIO targets the input element");
            checkEqual(scope, kAudioUnitScope_Input, "EnableIO targets the input scope");
            checkEqual(enabled, 0, "the microphone side stays disabled");
            g_unit.inputElementEnabled = enabled != 0;
            return noErr;
        }
        case kAudioUnitProperty_StreamFormat: {
            if (size != sizeof(AudioStreamBasicDescription)) return -1;
            std::memcpy(&g_unit.format, data, sizeof(g_unit.format));
            g_unit.formatSet = true;
            g_unit.setFormatElement = static_cast<int>(element);
            g_unit.setFormatScope = static_cast<int>(scope);
            g_unit.requestedSampleRate = g_unit.format.mSampleRate;
            return noErr;
        }
        case kAudioUnitProperty_MaximumFramesPerSlice: {
            if (size != sizeof(UInt32)) return -1;
            std::memcpy(&g_unit.maximumFramesPerSlice, data, sizeof(UInt32));
            return noErr;
        }
        case kAudioUnitProperty_SetRenderCallback: {
            if (size != sizeof(AURenderCallbackStruct)) return -1;
            std::memcpy(&g_unit.callback, data, sizeof(g_unit.callback));
            return noErr;
        }
        default:
            return -1;
    }
}

OSStatus AudioUnitGetProperty(AudioUnit unit, AudioUnitPropertyID id, AudioUnitScope,
    AudioUnitElement, void *outData, UInt32 *ioDataSize) {
    if (unit == nullptr || outData == nullptr || ioDataSize == nullptr) return -1;
    if (id != kAudioUnitProperty_StreamFormat ||
        *ioDataSize < sizeof(AudioStreamBasicDescription) || !g_unit.formatSet) {
        return -1;
    }
    std::memcpy(outData, &g_unit.format, sizeof(g_unit.format));
    if (g_changeGrantedChannels) {
        static_cast<AudioStreamBasicDescription *>(outData)->mChannelsPerFrame = 1;
    }
    *ioDataSize = sizeof(g_unit.format);
    return noErr;
}

OSStatus AudioUnitInitialize(AudioUnit unit) {
    if (unit == nullptr) return -1;
    check(g_unit.formatSet, "initializes only after the format is set");
    check(g_unit.callback.inputProc != nullptr, "initializes only after the callback is set");
    check(!g_unit.inputElementEnabled, "initializes with the input element disabled");
    g_unit.initialized = true;
    ++g_unit.initializeCalls;
    return noErr;
}

OSStatus AudioUnitUninitialize(AudioUnit unit) {
    if (unit == nullptr) return -1;
    g_unit.initialized = false;
    ++g_unit.uninitializeCalls;
    return noErr;
}

OSStatus AudioUnitReset(AudioUnit unit, AudioUnitScope, AudioUnitElement) {
    if (unit == nullptr) return -1;
    check(!g_unit.running, "resets only while stopped");
    ++g_unit.resetCalls;
    return noErr;
}

OSStatus AudioOutputUnitStart(AudioUnit unit) {
    if (unit == nullptr) return -1;
    g_unit.running = true;
    ++g_unit.startCalls;
    return noErr;
}

OSStatus AudioOutputUnitStop(AudioUnit unit) {
    if (unit == nullptr) return -1;
    g_unit.running = false;
    ++g_unit.stopCalls;
    return noErr;
}

/* ------------------------------------------------------------------ */
/* Fake AVAudioSession shim                                            */
/* ------------------------------------------------------------------ */

namespace {

struct FakeSession {
    int32_t sampleRate = 48000;
    int32_t ioBufferFrames = 512;
    int32_t outputLatencyFrames = 1024;
    std::string route = "Speaker";
    int activateCalls = 0;
    int deactivateCalls = 0;
    int32_t requestedSampleRate = 0;
    int32_t requestedBufferMillis = 0;
    bool failActivation = false;
    bool notifyDuringActivation = false;
    int stateReads = 0;
    lazer::audio::IosSessionState state{};
};

FakeSession g_session;

}  // namespace

namespace lazer::audio {

IosSessionState iosSessionState() noexcept {
    check(!g_inRenderCallback, "the callback never polls the session lifecycle");
    ++g_session.stateReads;
    return g_session.state;
}

void iosSessionRequestResume() noexcept {
    check(!g_inRenderCallback, "the callback never requests session resumption");
    g_session.state.mayResume = true;
}

int32_t iosSessionActivate(int32_t preferredSampleRate, int32_t bufferMillis,
    IosSessionInfo &info, std::string &error) {
    check(!g_inRenderCallback, "the callback never activates the session");
    ++g_session.activateCalls;
    if (g_session.notifyDuringActivation) ++g_session.state.revision;
    g_session.requestedSampleRate = preferredSampleRate;
    g_session.requestedBufferMillis = bufferMillis;
    if (g_session.failActivation) {
        error = "fake session refused activation";
        return LazerAudioErrorDevice;
    }
    info = IosSessionInfo{};
    info.sampleRate = g_session.sampleRate;
    info.ioBufferFrames = g_session.ioBufferFrames;
    info.outputLatencyFrames = g_session.outputLatencyFrames;
    info.route = g_session.route;
    return LazerAudioOk;
}

void iosSessionDeactivate() { ++g_session.deactivateCalls; }

}  // namespace lazer::audio

/* ------------------------------------------------------------------ */
/* Tests                                                               */
/* ------------------------------------------------------------------ */

namespace {

using lazer::audio::AudioOutput;
using lazer::audio::AudioOutputRequest;
using lazer::audio::AudioOutputSession;
using lazer::audio::OutputWaitResult;
using lazer::audio::createPlatformAudioOutput;
using lazer::audio::OutputWriteMode;
using lazer::audio::StreamDescription;

AudioOutputRequest request() {
    AudioOutputRequest value{};
    value.bufferMillis = 120;
    value.desired.sampleRate = 44100;
    return value;
}

StreamDescription source() {
    StreamDescription value{};
    value.codec = "flac";
    value.sampleRate = 44100;
    value.channels = 2;
    value.bitsPerSample = 16;
    value.lossless = true;
    return value;
}

void openDefault(AudioOutput &output, AudioOutputSession &session, std::string &error,
    AudioOutputRequest requested = request(), StreamDescription described = source()) {
    const int32_t status = output.open(requested, described, session, error, nullptr);
    checkEqual(status, LazerAudioOk, "opens the RemoteIO output");
    check(error.empty(), "a successful open leaves no error text");
}

void testRefusesFormatsIOSCannotDeliver() {
    g_componentAvailable = true;
    auto output = createPlatformAudioOutput();
    check(output != nullptr, "creates a platform output");
    for (int variant = 0; variant < 3; ++variant) {
        AudioOutputRequest asked = request();
        asked.bitPerfect = variant == 0;
        asked.requireDoP = variant == 1;
        asked.requireNativeDsd = variant == 2;
        AudioOutputSession session{};
        std::string error;
        const int32_t status = output->open(asked, source(), session, error, nullptr);
        checkEqual(status, LazerAudioErrorUnsupported, "refuses an exclusive format request");
        check(!error.empty(), "explains why the exclusive request was refused");
        checkEqual(g_session.activateCalls, 0, "does not touch the session for a refused request");
    }
}

void testReportsGrantedFacts() {
    g_session = FakeSession{};
    auto output = createPlatformAudioOutput();
    AudioOutputSession session{};
    std::string error;
    openDefault(*output, session, error);

    checkEqual(g_session.activateCalls, 1, "activates the audio session once");
    checkEqual(g_session.requestedSampleRate, 44100, "asks for the source sample rate");
    checkEqual(g_session.requestedBufferMillis, 120, "asks for the requested buffer");
    checkNear(g_unit.requestedSampleRate, 48000.0, 0.5,
        "opens the unit at the rate the route granted, not the rate requested");
    checkEqual(g_unit.format.mBitsPerChannel, 32, "uses 32-bit float samples");
    checkEqual(g_unit.format.mChannelsPerFrame, 2, "keeps stereo");
    checkEqual(static_cast<int64_t>(g_unit.format.mFormatFlags & kAudioFormatFlagIsFloat),
        static_cast<int64_t>(kAudioFormatFlagIsFloat), "sets the float flag");
    checkEqual(g_unit.setFormatElement, 0, "sets the format on the output element");
    checkEqual(g_unit.setFormatScope, 1, "sets the format on the input scope of that element");
    check(g_unit.maximumFramesPerSlice >= 1024, "leaves slice headroom above one IO period");

    checkEqual(session.target.sampleRate, 48000, "reports the granted sample rate");
    checkEqual(session.target.channels, 2, "reports stereo");
    checkEqual(session.target.bitsPerSample, 0, "reports the engine's float format");
    checkEqual(session.target.frameBytes(), 8, "reports 8 bytes per frame");
    checkEqual(session.exclusive, false, "never claims exclusive access");
    checkEqual(session.formatSelection, LazerAudioFormatSelectionSharedMix,
        "reports the shared-mix selection");
    checkEqual(static_cast<int64_t>(session.writeMode),
        static_cast<int64_t>(OutputWriteMode::Variable), "uses variable writes");
    checkEqual(session.periodFrames, 512, "reports the IO period in frames");
    check(session.queueDepthAvailable, "reports queue depth");
    check(!session.primeBeforeStart, "leaves priming to the engine render loop");
    check(session.description.find("RemoteIO") != std::string::npos,
        "describes the backend");
    check(session.description.find("Speaker") != std::string::npos,
        "names the route it opened on");
    output->close();
    checkEqual(g_session.deactivateCalls, 1, "releases the session on close");
}

void testQueuesAndDeliversFrames() {
    g_session = FakeSession{};
    auto output = createPlatformAudioOutput();
    AudioOutputSession session{};
    std::string error;
    openDefault(*output, session, error);

    const int32_t capacity = output->queuedFrames(error) + output->writableFrames(error);
    check(capacity > 512, "the queue holds more than one IO period");

    // Two frames of known content, then the device pulls four: the tail of the
    // missing ones must be silence, never stale memory.
    const float written[4] = {0.25f, -0.25f, 1.0f, -1.0f};
    checkEqual(output->write(reinterpret_cast<const uint8_t *>(written), 2, error), 2,
        "accepts the frames it has room for");
    checkEqual(output->queuedFrames(error), 2, "counts the queued frames");
    checkEqual(static_cast<int64_t>(output->drain(error)),
        static_cast<int64_t>(lazer::audio::OutputDrainResult::Pending),
        "reports pending while audio is queued");

    checkEqual(output->start(error), LazerAudioOk, "starts the unit");
    checkEqual(g_unit.startCalls, 1, "starts the unit once");
    checkEqual(output->start(error), LazerAudioOk, "starting twice is harmless");
    checkEqual(g_unit.startCalls, 1, "does not restart a running unit");

    const std::vector<float> pulled = pullAudio(4, 2);
    checkNear(pulled[0], 0.25, 1e-6, "delivers the first sample unchanged");
    checkNear(pulled[1], -0.25, 1e-6, "delivers the second channel unchanged");
    checkNear(pulled[2], 1.0, 1e-6, "delivers the third sample unchanged");
    checkNear(pulled[3], -1.0, 1e-6, "delivers the fourth sample unchanged");
    checkNear(pulled[4], 0.0, 1e-6, "pads an underrun with silence");
    checkNear(pulled[5], 0.0, 1e-6, "pads every missing channel with silence");
    checkEqual(output->queuedFrames(error), 0, "the callback consumed the queue");
    checkEqual(static_cast<int64_t>(output->drain(error)),
        static_cast<int64_t>(lazer::audio::OutputDrainResult::Drained),
        "reports drained once the callback emptied the queue");

    // A full queue reports back-pressure instead of dropping frames silently.
    std::vector<float> block(static_cast<size_t>(capacity) * 2, 0.5f);
    checkEqual(output->write(reinterpret_cast<const uint8_t *>(block.data()), capacity, error),
        capacity, "fills the queue");
    checkEqual(output->writableFrames(error), 0, "reports no room when full");
    checkEqual(output->write(reinterpret_cast<const uint8_t *>(block.data()), 16, error), 0,
        "accepts nothing when full");

    checkEqual(output->stop(error), LazerAudioOk, "stops the unit");
    check(!g_unit.running, "the unit is stopped");
    checkEqual(output->reset(error), LazerAudioOk, "resets the unit");
    checkEqual(output->queuedFrames(error), 0, "a reset drops what was queued");
    checkEqual(g_unit.resetCalls, 1, "resets the AudioUnit once");
    check(!g_unit.running, "reset leaves the unit stopped");
    output->close();
}

void testWaitForReadySeesTheDeviceDrain() {
    g_session = FakeSession{};
    auto output = createPlatformAudioOutput();
    AudioOutputSession session{};
    std::string error;
    openDefault(*output, session, error);
    checkEqual(output->start(error), LazerAudioOk, "starts the unit");

    const int32_t capacity = output->writableFrames(error);
    std::vector<float> block(static_cast<size_t>(capacity) * 2, 0.0f);
    checkEqual(output->write(reinterpret_cast<const uint8_t *>(block.data()), capacity, error),
        capacity, "fills the queue");
    checkEqual(static_cast<int64_t>(output->waitForReady(5, error)),
        static_cast<int64_t>(OutputWaitResult::Timeout),
        "waits out a full queue instead of blocking forever");

    pullAudio(512, 2);
    checkEqual(static_cast<int64_t>(output->waitForReady(10, error)),
        static_cast<int64_t>(OutputWaitResult::Ready),
        "reports ready once the device has drained a period");
    output->close();
}

void testMissingUnitAndSessionFailureAreReported() {
    g_session = FakeSession{};
    g_componentAvailable = false;
    auto output = createPlatformAudioOutput();
    AudioOutputSession session{};
    std::string error;
    const int32_t status = output->open(request(), source(), session, error, nullptr);
    check(status != LazerAudioOk, "fails when RemoteIO is unavailable");
    check(!error.empty(), "explains the missing AudioUnit");
    checkEqual(g_session.deactivateCalls, 1, "releases the session it had activated");
    g_componentAvailable = true;

    g_session = FakeSession{};
    g_session.failActivation = true;
    AudioOutputSession second{};
    error.clear();
    const int32_t refused = output->open(request(), source(), second, error, nullptr);
    checkEqual(refused, LazerAudioErrorDevice, "reports a session that refuses activation");
    check(!error.empty(), "explains the refused activation");

    g_session = FakeSession{};
    AudioOutputSession third{};
    error.clear();
    openDefault(*output, third, error);
    const int32_t invalid = output->write(nullptr, 4, error);
    checkEqual(invalid, LazerAudioErrorInvalidArgument, "rejects a null write");
    output->close();
    checkEqual(output->stop(error), LazerAudioOk, "stopping a closed output is harmless");
    checkEqual(output->reset(error), LazerAudioOk, "resetting a closed output is harmless");
}

void testRejectsChangedCallbackLayout() {
    g_session = FakeSession{};
    g_changeGrantedChannels = true;
    auto output = createPlatformAudioOutput();
    AudioOutputSession session{};
    std::string error;
    const int32_t status = output->open(request(), source(), session, error, nullptr);
    checkEqual(status, LazerAudioErrorDevice, "rejects a changed callback channel layout");
    check(!error.empty(), "explains the incompatible callback layout");
    checkEqual(g_unit.disposeCalls, 1, "disposes a unit with incompatible layout");
    g_changeGrantedChannels = false;
}


void testRouteChangesKeepTheClientClockAndQueuedPcm() {
    g_session = FakeSession{};
    g_session.sampleRate = 44100;
    auto output = createPlatformAudioOutput();
    AudioOutputSession session{};
    std::string error;
    openDefault(*output, session, error);
    checkEqual(output->start(error), LazerAudioOk, "starts before a route change");
    const int initialInstances = g_instancesCreated;
    const float frames[] = {0.125f, -0.125f, 0.5f, -0.5f};
    for (int pass = 0; pass < 2; ++pass) {
        checkEqual(output->write(reinterpret_cast<const uint8_t *>(frames), 2, error), 2,
            "queues source PCM before changing the route");
        g_session.sampleRate = pass == 0 ? 48000 : 44100;
        g_session.ioBufferFrames = pass == 0 ? 960 : 512;
        g_session.route = pass == 0 ? "BluetoothA2DP" : "Speaker";
        ++g_session.state.revision;
        g_unit.running = false; // The OS may stop it without changing running_.
        check(output->writableFrames(error) > 0, "producer poll recovers the changed route");
        check(error.empty(), "a recoverable route change is not a file error");
        checkEqual(g_instancesCreated, initialInstances + pass + 1,
            "creates exactly one replacement AudioUnit per route change");
        check(g_unit.running, "restarts after an OS stop even if the old running flag was true");
        checkNear(g_unit.format.mSampleRate, 44100, 0.5,
            "44.1/48 kHz hardware changes preserve the original client clock");
        checkEqual(session.engineFormat.sampleRate, 44100,
            "the engine's published clock stays valid after a route change");
        checkEqual(g_session.requestedSampleRate, 0,
            "recovery lets the system choose its hardware clock");
        checkEqual(output->queuedFrames(error), 2, "route recreation preserves queued PCM frames");
        const auto samples = pullAudio(2, 2);
        check(std::memcmp(samples.data(), frames, sizeof(frames)) == 0,
            "queued samples survive recreation bit-for-bit and in order");
    }
}

void testInterruptionBackPressureAndResume() {
    g_session = FakeSession{};
    auto output = createPlatformAudioOutput();
    AudioOutputSession session{};
    std::string error;
    openDefault(*output, session, error);
    output->start(error);
    const float first[] = {0.25f, -0.25f};
    const float inFlight[] = {0.75f, -0.75f};
    output->write(reinterpret_cast<const uint8_t *>(first), 1, error);
    const int instances = g_instancesCreated;
    g_session.state.interrupted = true;
    ++g_session.state.revision;
    checkEqual(output->writableFrames(error), 0, "interruption applies producer back-pressure");
    check(error.empty(), "interruption does not turn into a device/file error");
    check(output->isOpen(), "an interrupted output remains logically open");
    check(!g_unit.running, "an interruption stops the old unit");
    checkEqual(output->write(reinterpret_cast<const uint8_t *>(inFlight), 1, error), 1,
        "retains the block granted capacity immediately before interruption");
    checkEqual(output->queuedFrames(error), 2, "interruption retains both queued and in-flight PCM");
    checkEqual(static_cast<int64_t>(output->waitForReady(2, error)),
        static_cast<int64_t>(OutputWaitResult::Timeout), "wait times out while interrupted");
    check(error.empty(), "waiting during an interruption is not an error");
    checkEqual(g_instancesCreated, instances, "does not recreate units during an interruption");
    g_session.state.interrupted = false;
    ++g_session.state.revision;
    checkEqual(output->queuedFrames(error), 2, "queue observation performs interruption recovery");
    check(g_unit.running, "ShouldResume resumes a previously playing output");
    checkEqual(g_instancesCreated, instances + 1, "interruption end recreates the unit once");
    const auto samples = pullAudio(2, 2);
    checkNear(samples[0], first[0], 1e-6, "resumed playback keeps the first block");
    checkNear(samples[2], inFlight[0], 1e-6, "resumed playback keeps the in-flight block");
}

void testNoResumeAndPausedOutputsStayStopped() {
    g_session = FakeSession{};
    auto output = createPlatformAudioOutput();
    AudioOutputSession session{};
    std::string error;
    openDefault(*output, session, error);
    output->start(error);
    g_session.state.interrupted = true;
    ++g_session.state.revision;
    output->writableFrames(error);
    output->stop(error); // User paused while the system interruption was active.
    g_session.state.interrupted = false;
    ++g_session.state.revision;
    output->writableFrames(error);
    check(!g_unit.running, "ending an interruption never overrides an explicit pause");
    checkEqual(g_unit.startCalls, 0, "a paused output's replacement unit stays stopped");
    output->start(error);
    g_session.state.interrupted = true;
    ++g_session.state.revision;
    output->writableFrames(error);
    g_session.state.interrupted = false;
    g_session.state.mayResume = false; // Interruption ended without ShouldResume.
    ++g_session.state.revision;
    checkEqual(output->writableFrames(error), 0, "ShouldResume=false keeps back-pressure");
    check(!g_unit.running, "ShouldResume=false prevents automatic playback");
    checkEqual(output->start(error), LazerAudioOk, "an explicit play request can resume later");
    check(g_unit.running, "explicit play starts after a no-resume interruption");
    g_session.state.mayResume = false; // OldDeviceUnavailable (headset removed).
    ++g_session.state.revision;
    output->queuedFrames(error);
    check(!g_unit.running, "removing headphones never resumes on the speaker automatically");
    checkEqual(output->writableFrames(error), 0, "removed headphones retain back-pressure");
    checkEqual(output->start(error), LazerAudioOk, "explicit play acknowledges headphone removal");
    check(g_unit.running, "explicit play can intentionally use the new speaker route");
    ++g_session.state.revision;
    output->writableFrames(error);
    check(g_unit.running, "later route notifications do not reinstate stale no-resume state");
    output->stop(error);
    ++g_session.state.revision;
    output->writableFrames(error);
    check(!g_unit.running, "a route change keeps a manually paused output stopped");
    output->close();
    const int activations = g_session.activateCalls;
    ++g_session.state.revision;
    checkEqual(output->start(error), LazerAudioErrorInvalidArgument,
        "closed output cannot resume because of a notification");
    checkEqual(g_session.activateCalls, activations, "a closed output never reactivates the session");
}

void testMediaServicesLossResetAndActivationEpoch() {
    g_session = FakeSession{};
    g_session.notifyDuringActivation = true;
    auto output = createPlatformAudioOutput();
    AudioOutputSession session{};
    std::string error;
    openDefault(*output, session, error);
    output->start(error);
    const float frame[] = {0.125f, -0.375f};
    output->write(reinterpret_cast<const uint8_t *>(frame), 1, error);
    const int instances = g_instancesCreated;
    g_session.state.mediaServicesAvailable = false;
    ++g_session.state.revision;
    checkEqual(output->writableFrames(error), 0, "lost media services block producer writes");
    checkEqual(output->queuedFrames(error), 1, "lost media services preserve queued PCM");
    checkEqual(static_cast<int64_t>(output->waitForReady(1, error)),
        static_cast<int64_t>(OutputWaitResult::Timeout), "media services loss remains a temporary wait");
    check(error.empty(), "media services loss is not a terminal song error");
    checkEqual(g_instancesCreated, instances, "does not create units while media services are lost");
    g_session.state.mediaServicesAvailable = true;
    ++g_session.state.revision;
    // write() also consumes lifecycle changes without depending on a query first.
    checkEqual(output->write(reinterpret_cast<const uint8_t *>(frame), 1, error), 1,
        "reset recovery accepts more source PCM");
    checkEqual(g_instancesCreated, instances + 1, "services reset recreates the invalid AudioUnit");
    check(g_unit.running, "reset restarts playback that was running before media loss");
    const int activations = g_session.activateCalls;
    const int recreated = g_instancesCreated;
    for (int repeat = 0; repeat < 20; ++repeat) {
        output->queuedFrames(error);
        output->writableFrames(error);
    }
    checkEqual(g_session.activateCalls, activations,
        "activation-generated notifications do not trigger an activation loop");
    checkEqual(g_instancesCreated, recreated,
        "activation-generated notifications do not cause repeated AudioUnit rebuilding");
    checkEqual(output->queuedFrames(error), 2, "services reset keeps old and new PCM in one queue");
    const auto samples = pullAudio(2, 2);
    checkNear(samples[0], frame[0], 1e-6, "services reset preserves the old queued sample");
    checkNear(samples[2], frame[0], 1e-6, "services reset appends the new queued sample");
}

void testRecoveryFailureIsTemporaryAndCallbackDoesNoRecovery() {
    g_session = FakeSession{};
    auto output = createPlatformAudioOutput();
    AudioOutputSession session{};
    std::string error;
    openDefault(*output, session, error);
    output->start(error);
    const float frame[] = {0.375f, -0.375f};
    output->write(reinterpret_cast<const uint8_t *>(frame), 1, error);
    ++g_session.state.revision;
    const int reads = g_session.stateReads;
    const int instances = g_instancesCreated;
    const int activations = g_session.activateCalls;
    const auto samples = pullAudio(1, 2);
    checkNear(samples[0], frame[0], 1e-6, "callback continues copying queued PCM with a pending event");
    checkEqual(g_session.stateReads, reads, "callback never polls session notifications");
    checkEqual(g_instancesCreated, instances, "callback never recreates an AudioUnit");
    checkEqual(g_session.activateCalls, activations, "callback never activates an audio session");
    g_session.failActivation = true;
    checkEqual(output->writableFrames(error), 0, "temporary reactivation failure applies back-pressure");
    check(error.empty(), "temporary reactivation failure does not poison the playing song");
    check(output->isOpen(), "reactivation failure keeps the output logically open");
    checkEqual(static_cast<int64_t>(output->waitForReady(1, error)),
        static_cast<int64_t>(OutputWaitResult::Timeout), "failed recovery is a wait, not a file error");
    g_session.failActivation = false;
    ++g_session.state.revision;
    check(output->writableFrames(error) > 0, "later session notification retries a failed recovery");
    check(g_unit.running, "successful retry restarts previously running playback");
}

}  // namespace

int main() {
    testRefusesFormatsIOSCannotDeliver();
    testReportsGrantedFacts();
    testQueuesAndDeliversFrames();
    testWaitForReadySeesTheDeviceDrain();
    testMissingUnitAndSessionFailureAreReported();
    testRejectsChangedCallbackLayout();
    testRouteChangesKeepTheClientClockAndQueuedPcm();
    testInterruptionBackPressureAndResume();
    testNoResumeAndPausedOutputsStayStopped();
    testMediaServicesLossResetAndActivationEpoch();
    testRecoveryFailureIsTemporaryAndCallbackDoesNoRecovery();
    if (failures != 0) {
        std::printf("%d RemoteIO contract check(s) failed\n", failures);
        return 1;
    }
    std::printf("RemoteIO contract checks passed\n");
    return 0;
}
