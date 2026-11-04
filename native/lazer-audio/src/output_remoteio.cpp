/* iOS output through the RemoteIO AudioUnit.
 *
 * The macOS backend in this directory is a CoreAudio HAL client (device
 * enumeration, Hog Mode, AudioDevice IOProcs); none of that exists on iOS.
 * RemoteIO is the iOS shape of the same idea: one system-chosen route, a render
 * callback the OS drives, and AVAudioSession owning the route. The callback
 * pulls interleaved Float32 frames out of the engine's SPSC queue, which is the
 * same queue the HAL backend fills, so the engine's render thread sees the
 * familiar "write, report capacity, wait" contract.
 *
 * Precision is honestly downgraded here: iOS has no exclusive access, so
 * bit-perfect, DoP and native DSD requests are refused the way AAudio refuses
 * them, and the session reports SharedMix.
 */
#include "audio_output.h"
#include "coreaudio_pcm_queue.h"
#include "ios_audio_session.h"

#include <AudioToolbox/AudioToolbox.h>
#include <AudioUnit/AudioUnit.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
#include <sstream>
#include <thread>

namespace lazer::audio {
namespace {

constexpr int32_t kMaximumChannels = 2;
/* RemoteIO output element; the input element is bus 1 and stays disabled. */
constexpr AudioUnitElement kOutputBus = 0;
constexpr AudioUnitElement kInputBus = 1;
/* Bounds on the software queue: at least four IO callbacks, at most four seconds. */
constexpr int64_t kMinimumQueueFrames = 2048;
constexpr int64_t kMaximumQueueSeconds = 4;

std::string statusText(const char *operation, OSStatus status) {
    std::ostringstream text;
    text << operation << " failed (OSStatus " << status << ')';
    return text.str();
}

class RemoteIOOutput final : public AudioOutput {
public:
    ~RemoteIOOutput() override { close(); }

    int32_t open(const AudioOutputRequest &request, const StreamDescription &source,
        AudioOutputSession &session, std::string &error, LogProxy *) override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        error.clear();
        closeForReplacement();
        session = AudioOutputSession{};

        if (request.bitPerfect || request.requireDoP || request.requireNativeDsd) {
            error = "iOS audio is always mixed; exclusive, bit-perfect and direct DSD output "
                    "are unavailable";
            return LazerAudioErrorUnsupported;
        }

        const int32_t channels = std::clamp(
            source.channels > 0 ? source.channels : 2, 1, kMaximumChannels);
        const int32_t wantedRate = request.desired.sampleRate > 0
            ? request.desired.sampleRate : source.sampleRate;

        IosSessionInfo info;
        int32_t failure = iosSessionActivate(wantedRate,
            std::clamp(request.bufferMillis, 20, 1000), info, error);
        if (failure != LazerAudioOk) return failure;
        sessionActive_ = true;

        if (info.sampleRate <= 0) {
            error = "iOS reported no output sample clock";
            close();
            return LazerAudioErrorDevice;
        }

        const int32_t ioFrames = info.ioBufferFrames > 0 ? info.ioBufferFrames : 512;
        const int64_t requestedFrames = static_cast<int64_t>(info.sampleRate) *
            std::clamp(request.bufferMillis, 20, 1000) / 1000;
        const int64_t queueFrames = std::clamp<int64_t>(
            std::max<int64_t>(requestedFrames, static_cast<int64_t>(ioFrames) * 4),
            kMinimumQueueFrames,
            std::max<int64_t>(kMinimumQueueFrames,
                static_cast<int64_t>(info.sampleRate) * kMaximumQueueSeconds));
        target_ = TargetFormat{};
        target_.sampleRate = info.sampleRate;
        target_.channels = channels;
        target_.bitsPerSample = 0;  // Float32, the engine's internal format.
        target_.containerBitsPerSample = 32;
        if (!queue_.configure(static_cast<size_t>(queueFrames),
                static_cast<size_t>(target_.frameBytes()))) {
            error = "Could not allocate the iOS output queue";
            close();
            return LazerAudioErrorDevice;
        }

        if (createUnit(info, error) != LazerAudioOk) {
            close();
            return LazerAudioErrorDevice;
        }
        opened_ = true;
        bufferMillis_ = std::clamp(request.bufferMillis, 20, 1000);
        // Activation and preference changes may emit their own notifications.
        // Consume that epoch once, after setup, rather than rebuilding forever.
        sessionRevision_ = iosSessionState().revision;
        frameBytes_.store(target_.frameBytes(), std::memory_order_release);
        session = AudioOutputSession{};
        session.target = target_;
        session.engineFormat = PcmFormat{target_.sampleRate, target_.channels};
        session.formatSelection = LazerAudioFormatSelectionSharedMix;
        session.exclusive = false;
        session.periodFrames = ioFrames;
        session.bufferFrames = static_cast<int32_t>(
            std::min<int64_t>(queueFrames, std::numeric_limits<int32_t>::max()));
        session.writeMode = OutputWriteMode::Variable;
        session.queueDepthAvailable = true;
        // The render loop primes one period itself; pre-filling here would
        // double-count that ledger, exactly as on the other callback backends.
        session.primeBeforeStart = false;
        session.description = "iOS RemoteIO shared PCM (" + info.route + ", " +
            std::to_string(target_.sampleRate) + " Hz)";
        return LazerAudioOk;
    }

    void close() override { closeOutput(true); }

    void closeForReplacement() override { closeOutput(false); }

    void closeOutput(bool releaseSession) {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        requestedRunning_ = false;
        opened_ = false;
        rebuildRequired_ = false;
        disposeUnit();
        queue_.reset();
        frameBytes_.store(0, std::memory_order_release);
        // Deactivating between tracks relinquishes the background playback
        // session; iOS can then refuse the next activation while locked. Keep
        // it through replacements and release it only on stop or teardown.
        if (sessionActive_ && releaseSession) {
            iosSessionDeactivate();
            sessionActive_ = false;
        }
        target_ = TargetFormat{};
    }

    int32_t start(std::string &error) override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        error.clear();
        if (!opened_) return LazerAudioErrorInvalidArgument;
        iosSessionRequestResume();
        requestedRunning_ = true;
        nextRecoveryAttempt_ = {};
        // An interrupted/unavailable device is temporary back-pressure, not a
        // bad music file. A later producer poll performs the eventual restart.
        if (!synchronizeSession(false)) return LazerAudioOk;
        if (running_) return LazerAudioOk;
        const OSStatus status = AudioOutputUnitStart(unit_);
        if (status != noErr) {
            error = statusText("AudioOutputUnitStart", status);
            return LazerAudioErrorDevice;
        }
        running_ = true;
        return LazerAudioOk;
    }

    int32_t stop(std::string &error) override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        error.clear();
        requestedRunning_ = false;
        if (unit_ == nullptr || !running_) return LazerAudioOk;
        const OSStatus status = AudioOutputUnitStop(unit_);
        running_ = false;
        if (status != noErr) {
            error = statusText("AudioOutputUnitStop", status);
            return LazerAudioErrorDevice;
        }
        return LazerAudioOk;
    }

    int32_t reset(std::string &error) override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        error.clear();
        requestedRunning_ = false;
        if (!opened_) return LazerAudioOk;
        if (running_) {
            const int32_t stopped = stop(error);
            if (stopped != LazerAudioOk) return stopped;
        }
        // Dropping the queue is the point of a reset: what is left in it was
        // meant for a position the listener has already left.
        queue_.reset();
        if (unit_ == nullptr) return LazerAudioOk;
        const OSStatus status = AudioUnitReset(unit_, kAudioUnitScope_Global, kOutputBus);
        if (status != noErr) {
            error = statusText("AudioUnitReset", status);
            return LazerAudioErrorDevice;
        }
        return LazerAudioOk;
    }

    OutputWaitResult waitForReady(int32_t timeoutMillis, std::string &error) override {
        // Never hold the device lock while sleeping: pause and teardown must not
        // wait behind a full queue. The callback drains it in the background.
        if (writableFrames(error) > 0) return OutputWaitResult::Ready;
        if (!error.empty()) return OutputWaitResult::Error;
        const int32_t slice = std::clamp(timeoutMillis, 0, 20);
        for (int32_t waited = 0; waited < slice; waited += 1) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            if (writableFrames(error) > 0) return OutputWaitResult::Ready;
            if (!error.empty()) return OutputWaitResult::Error;
        }
        return OutputWaitResult::Timeout;
    }

    int32_t writableFrames(std::string &error) override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        error.clear();
        if (!opened_) {
            error = "iOS audio output disconnected";
            return -1;
        }
        if (!synchronizeSession()) return 0;
        return static_cast<int32_t>(std::min<size_t>(
            queue_.writableFrames(), static_cast<size_t>(std::numeric_limits<int32_t>::max())));
    }

    int32_t queuedFrames(std::string &error) override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        error.clear();
        if (!opened_) {
            error = "iOS audio output disconnected";
            return -1;
        }
        synchronizeSession();
        return static_cast<int32_t>(std::min<size_t>(
            queue_.queuedFrames(), static_cast<size_t>(std::numeric_limits<int32_t>::max())));
    }

    OutputDrainResult drain(std::string &error) override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        const int32_t queued = queuedFrames(error);
        if (queued < 0) return OutputDrainResult::Error;
        // One IO period may still be inside the AudioUnit after the queue is
        // empty; the engine's stop path tolerates that as it does on AAudio.
        return queued == 0 ? OutputDrainResult::Drained : OutputDrainResult::Pending;
    }

    int32_t write(const uint8_t *bytes, int32_t frameCount, std::string &error) override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        error.clear();
        if (!opened_ || bytes == nullptr || frameCount < 0) {
            return LazerAudioErrorInvalidArgument;
        }
        synchronizeSession();
        if (frameCount == 0) return 0;
        // A notification can arrive after writableFrames() granted capacity.
        // Retain that in-flight producer block even while the unit is stopped;
        // subsequent writable queries apply back-pressure until recovery.
        return queue_.write(bytes, frameCount);
    }

    bool isOpen() const noexcept override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        return opened_;
    }

private:
    // Only control / render-producer callers enter these helpers. Stopping
    // and disposing the unit synchronizes its callback before queue reset or
    // destruction. A route rebuild deliberately leaves the SPSC PCM untouched.
    void disposeUnit() {
        if (unit_ == nullptr) return;
        if (running_) AudioOutputUnitStop(unit_);
        running_ = false;
        if (initialized_) AudioUnitUninitialize(unit_);
        initialized_ = false;
        AudioComponentInstanceDispose(unit_);
        unit_ = nullptr;
    }

    int32_t createUnit(const IosSessionInfo &info, std::string &error) {
        const int32_t channels = target_.channels;
        AudioComponentDescription description{};
        description.componentType = kAudioUnitType_Output;
        description.componentSubType = kAudioUnitSubType_RemoteIO;
        description.componentManufacturer = kAudioUnitManufacturer_Apple;
        AudioComponent component = AudioComponentFindNext(nullptr, &description);
        if (component == nullptr) {
            error = "The iOS RemoteIO AudioUnit is unavailable on this system";
            disposeUnit();
            return LazerAudioErrorDevice;
        }
        OSStatus status = AudioComponentInstanceNew(component, &unit_);
        if (status != noErr || unit_ == nullptr) {
            unit_ = nullptr;
            error = statusText("AudioComponentInstanceNew", status);
            disposeUnit();
            return LazerAudioErrorDevice;
        }

        // The output element is enabled by default; the input element is not
        // wanted at all, and enabling it would put a microphone indicator on
        // the status bar and demand a usage description for a music player.
        UInt32 disabled = 0;
        status = AudioUnitSetProperty(unit_, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, kInputBus, &disabled, sizeof(disabled));
        if (status != noErr) {
            error = statusText("RemoteIO input disable", status);
            disposeUnit();
            return LazerAudioErrorDevice;
        }

        AudioStreamBasicDescription format{};
        format.mSampleRate = static_cast<Float64>(target_.sampleRate);
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        format.mFramesPerPacket = 1;
        format.mChannelsPerFrame = static_cast<UInt32>(channels);
        format.mBitsPerChannel = 32;
        format.mBytesPerFrame = static_cast<UInt32>(sizeof(float) * channels);
        format.mBytesPerPacket = format.mBytesPerFrame;
        status = AudioUnitSetProperty(unit_, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, kOutputBus, &format, sizeof(format));
        if (status != noErr) {
            error = statusText("RemoteIO stream format", status);
            disposeUnit();
            return LazerAudioErrorDevice;
        }

        const int32_t ioFrames = info.ioBufferFrames > 0 ? info.ioBufferFrames : 512;
        // A slice smaller than what the device asks for would make the unit
        // split callbacks; leaving headroom above it keeps one callback per IO
        // period on every route we have seen (44.1 kHz through 192 kHz).
        UInt32 sliceFrames = static_cast<UInt32>(
            std::clamp<int64_t>(static_cast<int64_t>(ioFrames) * 2, 1024, 8192));
        status = AudioUnitSetProperty(unit_, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, kOutputBus, &sliceFrames, sizeof(sliceFrames));
        if (status != noErr) {
            error = statusText("RemoteIO maximum frames", status);
            disposeUnit();
            return LazerAudioErrorDevice;
        }

        AURenderCallbackStruct callback{};
        callback.inputProc = &RemoteIOOutput::renderThunk;
        callback.inputProcRefCon = this;
        status = AudioUnitSetProperty(unit_, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, kOutputBus, &callback, sizeof(callback));
        if (status != noErr) {
            error = statusText("RemoteIO render callback", status);
            disposeUnit();
            return LazerAudioErrorDevice;
        }

        status = AudioUnitInitialize(unit_);
        if (status != noErr) {
            error = statusText("AudioUnitInitialize", status);
            disposeUnit();
            return LazerAudioErrorDevice;
        }
        initialized_ = true;
        // Read back what the unit accepted instead of trusting the request.
        AudioStreamBasicDescription granted{};
        UInt32 grantedSize = sizeof(granted);
        if (AudioUnitGetProperty(unit_, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input, kOutputBus, &granted, &grantedSize) == noErr &&
            granted.mSampleRate > 0 && granted.mChannelsPerFrame > 0) {
            // The queue was allocated for interleaved Float32 at the requested
            // channel count. A unit that changes that layout would make the
            // callback read frames with the wrong stride.
            if (std::abs(granted.mSampleRate - static_cast<double>(target_.sampleRate)) > 0.5 ||
                granted.mChannelsPerFrame != static_cast<UInt32>(channels) ||
                granted.mFormatID != kAudioFormatLinearPCM ||
                (granted.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)) !=
                    (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked) ||
                granted.mBitsPerChannel != 32 ||
                granted.mBytesPerFrame != static_cast<UInt32>(sizeof(float) * channels)) {
                error = "RemoteIO changed the requested interleaved Float32 layout";
                disposeUnit();
                return LazerAudioErrorDevice;
            }
        } else {
            error = "RemoteIO did not report its accepted client format";
            disposeUnit();
            return LazerAudioErrorDevice;
        }

        return LazerAudioOk;
    }

    bool synchronizeSession(bool resume = true) {
        auto state = iosSessionState();
        if (state.revision != sessionRevision_) {
            sessionRevision_ = state.revision;
            rebuildRequired_ = true;
            nextRecoveryAttempt_ = {};
            // Removed headphones and ShouldResume=false must never turn into
            // an unsolicited speaker restart. Only start() grants permission.
            if (!state.mayResume) requestedRunning_ = false;
        }
        if (state.interrupted || !state.mediaServicesAvailable || !state.mayResume) {
            disposeUnit();
            rebuildRequired_ = true;
            return false;
        }
        if (rebuildRequired_) {
            const auto now = std::chrono::steady_clock::now();
            if (now < nextRecoveryAttempt_) return false;
            disposeUnit();
            IosSessionInfo info;
            std::string recoveryError;
            // Keep the engine / queue clock fixed for this open session. The
            // AudioUnit resamples its client format to a new 44.1/48 kHz route;
            // retiming already queued PCM would otherwise change its pitch.
            const int32_t activated = iosSessionActivate(0, bufferMillis_, info, recoveryError);
            // setActive / preferred-buffer requests may notify synchronously.
            state = iosSessionState();
            sessionRevision_ = state.revision;
            if (!state.mayResume) requestedRunning_ = false;
            if (activated != LazerAudioOk || state.interrupted ||
                !state.mediaServicesAvailable || !state.mayResume ||
                createUnit(info, recoveryError) != LazerAudioOk) {
                disposeUnit();
                nextRecoveryAttempt_ = now + std::chrono::milliseconds(50);
                return false;
            }
            rebuildRequired_ = false;
        }
        if (unit_ == nullptr || !initialized_) return false;
        if (resume && requestedRunning_ && !running_) {
            if (AudioOutputUnitStart(unit_) != noErr) {
                disposeUnit();
                rebuildRequired_ = true;
                nextRecoveryAttempt_ = std::chrono::steady_clock::now() +
                    std::chrono::milliseconds(50);
                return false;
            }
            running_ = true;
        }
        return true;
    }

    /* The OS audio thread. No locks, no allocation, no logging: it only moves
     * bytes out of the SPSC queue and reports underruns it had to pad. */
    static OSStatus renderThunk(void *reference, AudioUnitRenderActionFlags *flags,
        const AudioTimeStamp *timeStamp, UInt32 bus, UInt32 frames, AudioBufferList *data) {
        return static_cast<RemoteIOOutput *>(reference)->render(flags, timeStamp, bus, frames, data);
    }

    OSStatus render(AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32 frames,
        AudioBufferList *data) {
        if (data == nullptr || data->mNumberBuffers == 0) return noErr;
        AudioBuffer &buffer = data->mBuffers[0];
        const int32_t frameBytes = frameBytes_.load(std::memory_order_acquire);
        if (frameBytes <= 0 || buffer.mData == nullptr) return noErr;
        const size_t capacityFrames = buffer.mDataByteSize / static_cast<size_t>(frameBytes);
        const int32_t wanted = static_cast<int32_t>(
            std::min<size_t>(frames, capacityFrames));
        if (wanted <= 0) return noErr;
        const int32_t dequeued = queue_.readInterleavedBytes(
            static_cast<uint8_t *>(buffer.mData), buffer.mDataByteSize,
            static_cast<size_t>(wanted));
        const int32_t received = dequeued > 0 ? std::min(dequeued, wanted) : 0;
        if (received < wanted) {
            const size_t offset = static_cast<size_t>(received) * static_cast<size_t>(frameBytes);
            const size_t missing = buffer.mDataByteSize > offset
                ? static_cast<size_t>(wanted - received) * static_cast<size_t>(frameBytes) : 0;
            if (missing > 0) {
                std::memset(static_cast<uint8_t *>(buffer.mData) + offset, 0, missing);
            }
            underrunFrames_.fetch_add(static_cast<uint64_t>(wanted - received),
                std::memory_order_relaxed);
        }
        return noErr;
    }

    mutable std::recursive_mutex mutex_;
    CoreAudioPcmQueue queue_;
    AudioUnit unit_ = nullptr;
    bool initialized_ = false;
    bool running_ = false;
    bool sessionActive_ = false;
    bool opened_ = false;
    bool requestedRunning_ = false;
    bool rebuildRequired_ = false;
    int32_t bufferMillis_ = 120;
    uint64_t sessionRevision_ = 0;
    std::chrono::steady_clock::time_point nextRecoveryAttempt_{};
    TargetFormat target_{};
    std::atomic<int32_t> frameBytes_{0};
    std::atomic<uint64_t> underrunFrames_{0};
};

}  // namespace

std::unique_ptr<AudioOutput> createPlatformAudioOutput() {
    return std::make_unique<RemoteIOOutput>();
}

}  // namespace lazer::audio
