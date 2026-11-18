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
 * Ordinary playback reports SharedMix. Strict USB PCM and DoP keep integer
 * samples in the queue and convert only at the final callback to Float32, which
 * represents every signed 16/24-bit sample exactly. Their verified route, clock,
 * channel count, unity volume and non-mixing session are invalidated immediately
 * by notifications. This is not hardware exclusive ownership or DAC readback.
 */
#include "audio_output.h"
#include "coreaudio_pcm_queue.h"
#include "coreaudio_dop_carrier.h"
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
#include <vector>

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

bool validStrictSource(const AudioOutputRequest &request, const StreamDescription &source,
    std::string &error) {
    if (request.requireDoP) {
        const bool multiplier = source.dsdRateMultiplier == 64 || source.dsdRateMultiplier == 128 ||
            source.dsdRateMultiplier == 256 || source.dsdRateMultiplier == 512 ||
            source.dsdRateMultiplier == 1024;
        if (request.bitPerfect || !request.desired.doP || !source.dsd || !source.rawDsd ||
            !multiplier || source.sampleRate <= 0 || (source.sampleRate & 1) != 0 ||
            static_cast<int64_t>(source.sampleRate) * 8 !=
                static_cast<int64_t>(44100) * source.dsdRateMultiplier ||
            request.desired.sampleRate != source.sampleRate / 2 ||
            request.desired.channels != source.channels ||
            (source.channels != 1 && source.channels != 2) ||
            request.desired.bitsPerSample != 24 || request.desired.containerBitsPerSample != 24) {
            error = "iOS DoP requires raw mono/stereo DSD and an exact packed 24-bit carrier clock";
            return false;
        }
    } else if (source.dsd || !source.lossless || !source.integerPcm ||
        !source.canonicalChannelLayout || !source.decoderFormatMatchesStream ||
        (source.bitsPerSample != 16 && source.bitsPerSample != 24) || source.sampleRate <= 0 ||
        (source.channels != 1 && source.channels != 2) || request.desired.doP ||
        (request.desired.sampleRate > 0 && request.desired.sampleRate != source.sampleRate)) {
        error = "iOS USB Bit-perfect requires exact 16/24-bit lossless integer PCM; "
            "32-bit integer and floating-point sources cannot use the exact Float32 bridge";
        return false;
    }
    return true;
}

bool validUsbRoute(const IosSessionInfo &info, const TargetFormat &target,
    const std::string &previousUid, std::string &error) {
    if (!info.usbOnly || info.routeUid.empty()) {
        error = "iOS direct output requires a connected USB DAC; speaker, Bluetooth and AirPlay are unsupported";
    } else if (!previousUid.empty() && previousUid != info.routeUid) {
        error = "iOS direct output USB device changed; reopen playback for the new DAC";
    } else if (!info.nonMixablePlayback) {
        error = "iOS direct output requires a non-mixing Playback session in default mode";
    } else if (!info.unityVolume) {
        error = "iOS direct output requires system output volume at 100%; volume was not changed automatically";
    } else if (info.sampleRate != target.sampleRate || info.outputChannels != target.channels) {
        error = "iOS USB DAC did not grant the exact source sample rate and channel count";
    } else {
        return true;
    }
    return false;
}

bool validHardwareFormat(const AudioStreamBasicDescription &format, const TargetFormat &target) {
    const auto flags = format.mFormatFlags;
    const bool floating = (flags & kAudioFormatFlagIsFloat) != 0;
    const bool planar = (flags & kAudioFormatFlagIsNonInterleaved) != 0;
    const UInt32 channelsPerBuffer = planar ? 1U : static_cast<UInt32>(target.channels);
    const UInt32 allowed = kAudioFormatFlagIsFloat | kAudioFormatFlagIsSignedInteger |
        kAudioFormatFlagIsPacked | kAudioFormatFlagIsAlignedHigh | kAudioFormatFlagIsNonInterleaved;
    if (format.mFormatID != kAudioFormatLinearPCM || !std::isfinite(format.mSampleRate) ||
        std::abs(format.mSampleRate - static_cast<double>(target.sampleRate)) > 0.001 ||
        format.mChannelsPerFrame != static_cast<UInt32>(target.channels) ||
        format.mFramesPerPacket != 1 || format.mBytesPerPacket != format.mBytesPerFrame ||
        (flags & ~allowed) != 0 || channelsPerBuffer == 0 ||
        format.mBytesPerFrame % channelsPerBuffer != 0) return false;
    const UInt32 sampleBytes = format.mBytesPerFrame / channelsPerBuffer;
    if (floating) {
        return (flags & (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh)) == 0 &&
            (flags & kAudioFormatFlagIsPacked) != 0 &&
            ((format.mBitsPerChannel == 32 && sampleBytes == 4) ||
                (format.mBitsPerChannel == 64 && sampleBytes == 8));
    }
    return (flags & kAudioFormatFlagIsSignedInteger) != 0 &&
        format.mBitsPerChannel >= static_cast<UInt32>(target.bitsPerSample) &&
        format.mBitsPerChannel <= 32 && sampleBytes >= 2 && sampleBytes <= 4 &&
        format.mBitsPerChannel <= sampleBytes * 8 &&
        ((flags & kAudioFormatFlagIsPacked) == 0 || format.mBitsPerChannel == sampleBytes * 8);
}

class RemoteIOOutput final : public AudioOutput {
public:
    ~RemoteIOOutput() override { close(); }
    bool strictDirectOutputRequests() const noexcept override { return true; }

    int32_t open(const AudioOutputRequest &request, const StreamDescription &source,
        AudioOutputSession &session, std::string &error, LogProxy *) override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        error.clear();
        closeForReplacement();
        session = AudioOutputSession{};

        if (request.requireNativeDsd) {
            error = "iOS RemoteIO has no raw Native DSD transport; use explicit DoP with a compatible USB DAC";
            close();
            return LazerAudioErrorUnsupported;
        }
        strictUsb_ = request.bitPerfect || request.requireDoP;
        if (strictUsb_ && !validStrictSource(request, source, error)) {
            // A previous track may have retained its active background session
            // for this replacement. An unsuccessful replacement must release it.
            close();
            return LazerAudioErrorUnsupported;
        }

        const int32_t channels = std::clamp(
            source.channels > 0 ? source.channels : 2, 1, kMaximumChannels);
        const int32_t wantedRate = request.desired.sampleRate > 0
            ? request.desired.sampleRate : source.sampleRate;

        IosSessionInfo info;
        int32_t failure = iosSessionActivate(wantedRate,
            std::clamp(request.bufferMillis, 20, 1000), info, error, strictUsb_);
        if (failure != LazerAudioOk) {
            close();
            return failure;
        }
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
        target_.sampleRate = strictUsb_ ? wantedRate : info.sampleRate;
        target_.channels = channels;
        target_.bitsPerSample = strictUsb_ ? (request.requireDoP ? 24 : source.bitsPerSample) : 0;
        target_.containerBitsPerSample = strictUsb_ ? target_.bitsPerSample : 32;
        target_.doP = request.requireDoP;
        if (strictUsb_ && !validUsbRoute(info, target_, {}, error)) {
            close();
            return LazerAudioErrorUnsupported;
        }
        strictRouteUid_ = strictUsb_ ? info.routeUid : std::string{};
        validatedSessionRevision_.store(info.revision, std::memory_order_release);
        if (!queue_.configure(static_cast<size_t>(queueFrames),
                static_cast<size_t>(target_.frameBytes()))) {
            error = "Could not allocate the iOS output queue";
            close();
            return LazerAudioErrorDevice;
        }

        failure = createUnit(error);
        if (failure != LazerAudioOk) {
            close();
            return failure;
        }
        opened_ = true;
        bufferMillis_ = std::clamp(request.bufferMillis, 20, 1000);
        ioPeriodFrames_.store(ioFrames, std::memory_order_release);
        // Activation and preference changes may emit their own notifications.
        // Consume that epoch once, after setup, rather than rebuilding forever.
        sessionRevision_ = iosSessionState().revision;
        frameBytes_.store(target_.frameBytes(), std::memory_order_release);
        session = AudioOutputSession{};
        session.target = target_;
        session.engineFormat = PcmFormat{target_.sampleRate, target_.channels};
        session.formatSelection = strictUsb_ ? (target_.doP ? LazerAudioFormatSelectionIosUsbDoP
            : LazerAudioFormatSelectionIosUsbPcm) : LazerAudioFormatSelectionSharedMix;
        session.exclusive = false;
        session.transparentUsb = strictUsb_;
        session.doP = target_.doP;
        session.periodFrames = ioFrames;
        // The device holds one IO buffer; everything above that in `queue_` is this
        // backend's own cushion for a source that stalls mid-track. The engine sizes
        // its ring and its render block from `bufferFrames`, so publishing the
        // cushion there would triple seconds of software queue into that ring and
        // hide the latency the listener actually hears. The cushion stays a detail
        // of this backend; the published depth is what the AudioUnit asked for.
        session.bufferFrames = ioFrames;
        session.writeMode = OutputWriteMode::Variable;
        session.queueDepthAvailable = true;
        // The render loop primes one period itself; pre-filling here would
        // double-count that ledger, exactly as on the other callback backends.
        session.primeBeforeStart = false;
        session.description = std::string(strictUsb_ ? (target_.doP ? "iOS USB DoP, exact Float32 bridge ("
            : "iOS USB PCM, exact Float32 bridge (") : "iOS RemoteIO shared PCM (") + info.route + ", " +
            std::to_string(target_.sampleRate) + " Hz)";
        return LazerAudioOk;
    }

    void close() override { closeOutput(true); }

    void closeForReplacement() override { closeOutput(false); }

    void closeOutput(bool releaseSession) {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        requestedRunning_ = false;
        strictReady_.store(false, std::memory_order_release);
        opened_ = false;
        rebuildRequired_ = false;
        clearRecoveryFailure();
        disposeUnit();
        queue_.reset();
        frameBytes_.store(0, std::memory_order_release);
        ioPeriodFrames_.store(0, std::memory_order_release);
        // Deactivating between tracks relinquishes the background playback
        // session; iOS can then refuse the next activation while locked. Keep
        // it through replacements and release it only on stop or teardown.
        if (sessionActive_ && releaseSession) {
            iosSessionDeactivate();
            sessionActive_ = false;
        }
        target_ = TargetFormat{};
        strictUsb_ = false;
        strictRouteUid_.clear();
        directScratch_.clear();
        strictFailure_.clear();
        callbackFault_.store(false, std::memory_order_release);
        nextDoPMarker_ = 0x05;
    }

    int32_t start(std::string &error) override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        error.clear();
        if (!opened_) return LazerAudioErrorInvalidArgument;
        iosSessionRequestResume();
        requestedRunning_ = true;
        strictFailure_.clear();
        nextRecoveryAttempt_ = {};
        clearRecoveryFailure();
        // An interrupted/unavailable device is temporary back-pressure, not a
        // bad music file. A later producer poll performs the eventual restart.
        if (!synchronizeSession(false)) {
            // A real activation/initialization error is different from an
            // interruption. Returning Ok here used to leave the first play
            // permanently parked with no error the app could report.
            if (!strictFailure_.empty() || !recoveryFailure_.empty()) {
                error = strictFailure_.empty() ? recoveryFailure_ : strictFailure_;
                return LazerAudioErrorDevice;
            }
            return LazerAudioOk;
        }
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
        if (strictUsb_) strictReady_.store(false, std::memory_order_release);
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
        nextDoPMarker_ = 0x05;
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
        // Frames only become writable when the AudioUnit renders its next period,
        // so nothing can free before one IO period has elapsed. Sleeping once for a
        // slice derived from that period keeps the producer off both the device lock
        // and the session snapshot, instead of re-entering writableFrames() up to
        // twenty times per call and finding the same queue every time.
        const int32_t slice = std::clamp(timeoutMillis, 0, ioPeriodMillis());
        if (slice > 0) std::this_thread::sleep_for(std::chrono::milliseconds(slice));
        if (writableFrames(error) > 0) return OutputWaitResult::Ready;
        return error.empty() ? OutputWaitResult::Timeout : OutputWaitResult::Error;
    }

    int32_t writableFrames(std::string &error) override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        error.clear();
        if (!opened_) {
            error = "iOS audio output disconnected";
            return -1;
        }
        if (!synchronizeSession()) return recoveryExpired(error) ? -1 : 0;
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
        if (recoveryExpired(error)) return -1;
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
        if (recoveryExpired(error)) return LazerAudioErrorDevice;
        if (frameCount == 0) return 0;
        // A notification can arrive after writableFrames() granted capacity.
        // Retain that in-flight producer block even while the unit is stopped;
        // subsequent writable queries apply back-pressure until recovery.
        return queue_.write(bytes, frameCount);
    }

    bool isOpen() const noexcept override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        return opened_ && (!strictUsb_ || strictCallbackAuthorized());
    }

private:
    /// How long the device needs to render one period, bounded so a pathological
    /// route cannot park the producer for longer than a frame budget.
    [[nodiscard]] int32_t ioPeriodMillis() const noexcept {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        const int32_t frames = ioPeriodFrames_.load(std::memory_order_acquire);
        const int32_t rate = target_.sampleRate;
        if (frames <= 0 || rate <= 0) return 20;
        const int64_t millis = static_cast<int64_t>(frames) * 1000 / rate;
        return static_cast<int32_t>(std::clamp<int64_t>(millis, 1, 20));
    }

    // Only control / render-producer callers enter these helpers. Stopping
    // and disposing the unit synchronizes its callback before queue reset or
    // destruction. A route rebuild deliberately leaves the SPSC PCM untouched.
    void disposeUnit() {
        if (unit_ == nullptr) return;
        strictReady_.store(false, std::memory_order_release);
        if (running_) AudioOutputUnitStop(unit_);
        running_ = false;
        if (formatListener_) {
            AudioUnitRemovePropertyListenerWithUserData(unit_, kAudioUnitProperty_StreamFormat,
                &RemoteIOOutput::formatChanged, this);
            formatListener_ = false;
        }
        if (initialized_) AudioUnitUninitialize(unit_);
        initialized_ = false;
        AudioComponentInstanceDispose(unit_);
        unit_ = nullptr;
    }

    int32_t createUnit(std::string &error) {
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

        // I/O units already size their slices for the hardware, including screen
        // sleep and route sample-rate conversion. Do not replace that negotiated
        // value with a smaller software cap (formerly 1024..8192 frames).
        // https://developer.apple.com/documentation/audiotoolbox/kaudiounitproperty_maximumframesperslice

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

        // A hardware format change can precede the route notification. The
        // property listener only invalidates strict output; it never allocates.
        if (strictUsb_) {
            status = AudioUnitAddPropertyListener(unit_, kAudioUnitProperty_StreamFormat,
                &RemoteIOOutput::formatChanged, this);
            if (status != noErr) {
                error = statusText("RemoteIO format-change observer", status);
                disposeUnit();
                return LazerAudioErrorDevice;
            }
            formatListener_ = true;
        }
        const uint64_t formatRevision = formatRevision_.load(std::memory_order_acquire);

        // The hardware may ask for much larger blocks while the display sleeps,
        // or when RemoteIO converts a high-rate client stream to a new route.
        // A queue sized only from the normal IO period can never supply a whole
        // such callback, causing repeated underruns even with a fast decoder.
        UInt32 maximumSliceFrames = 0;
        UInt32 maximumSliceSize = sizeof(maximumSliceFrames);
        status = AudioUnitGetProperty(unit_, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, kOutputBus, &maximumSliceFrames, &maximumSliceSize);
        if (status != noErr || maximumSliceSize != sizeof(maximumSliceFrames) ||
            maximumSliceFrames == 0) {
            error = status != noErr ? statusText("RemoteIO maximum render slice", status)
                : "RemoteIO did not report a valid maximum render slice";
            disposeUnit();
            return LazerAudioErrorDevice;
        }
        const int64_t maximumQueueFrames = std::max<int64_t>(kMinimumQueueFrames,
            static_cast<int64_t>(target_.sampleRate) * kMaximumQueueSeconds);
        if (maximumSliceFrames > maximumQueueFrames) {
            error = "RemoteIO requires a render slice larger than the bounded output queue";
            disposeUnit();
            return LazerAudioErrorDevice;
        }
        // Room for a second maximum slice lets the producer refill while the
        // device consumes the first. Allocation happens before the unit starts;
        // recovery preserves all queued PCM rather than resetting the source.
        const size_t sliceCapacity = static_cast<size_t>(std::min<int64_t>(
            static_cast<int64_t>(maximumSliceFrames) * 2, maximumQueueFrames));
        if (!queue_.reservePreservingFrames(sliceCapacity)) {
            error = "Could not grow the iOS output queue for the negotiated render slice";
            disposeUnit();
            return LazerAudioErrorDevice;
        }
        if (strictUsb_) {
            try {
                directScratch_.resize(static_cast<size_t>(maximumSliceFrames) *
                    static_cast<size_t>(target_.frameBytes()));
            } catch (...) {
                error = "Could not allocate the iOS exact-integer bridge buffer";
                disposeUnit();
                return LazerAudioErrorDevice;
            }
        }
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
                grantedSize != sizeof(granted) || granted.mFormatID != kAudioFormatLinearPCM ||
                granted.mFormatFlags !=
                    (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked) ||
                granted.mBitsPerChannel != 32 ||
                granted.mFramesPerPacket != 1 || granted.mBytesPerPacket != granted.mBytesPerFrame ||
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

        if (strictUsb_) {
            AudioStreamBasicDescription hardware{};
            UInt32 hardwareSize = sizeof(hardware);
            if (AudioUnitGetProperty(unit_, kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Output, kOutputBus, &hardware, &hardwareSize) != noErr ||
                hardwareSize != sizeof(hardware) || !validHardwareFormat(hardware, target_)) {
                error = "iOS USB hardware-side format cannot preserve the requested clock, channels and precision";
                disposeUnit();
                return LazerAudioErrorUnsupported;
            }
            if (formatRevision_.load(std::memory_order_acquire) != formatRevision ||
                iosSessionRealtimeRevision() != validatedSessionRevision_.load(std::memory_order_acquire)) {
                error = "iOS USB format or route changed while validating output";
                disposeUnit();
                return LazerAudioErrorDevice;
            }
            strictReady_.store(true, std::memory_order_release);
            if (formatRevision_.load(std::memory_order_acquire) != formatRevision) {
                strictReady_.store(false, std::memory_order_release);
                error = "iOS USB hardware format changed while enabling output";
                disposeUnit();
                return LazerAudioErrorDevice;
            }
        }

        return LazerAudioOk;
    }

    static void formatChanged(void *reference, AudioUnit, AudioUnitPropertyID,
        AudioUnitScope, AudioUnitElement) {
        auto *output = static_cast<RemoteIOOutput *>(reference);
        output->formatRevision_.fetch_add(1, std::memory_order_release);
        output->strictReady_.store(false, std::memory_order_release);
    }

    void clearRecoveryFailure() {
        recoveryFailure_.clear();
        recoveryFailedAt_ = {};
    }

    void recordRecoveryFailure(const std::string &error) {
        const auto now = std::chrono::steady_clock::now();
        if (recoveryFailure_.empty()) recoveryFailedAt_ = now;
        recoveryFailure_ = error.empty() ? "iOS audio output recovery failed" : error;
        nextRecoveryAttempt_ = now + std::chrono::milliseconds(50);
    }

    bool recoveryExpired(std::string &error) const {
        if (!strictFailure_.empty()) {
            error = strictFailure_;
            return true;
        }
        // Keep short route-reconfiguration failures recoverable, but do not
        // claim endless back-pressure after a persistent NSError/OSStatus.
        // Real system interruptions and missing media services do not spend
        // this budget: only failed attempts while the session is available do.
        if (recoveryFailure_.empty() || std::chrono::steady_clock::now() -
                recoveryFailedAt_ < std::chrono::seconds(3)) return false;
        error = recoveryFailure_;
        return true;
    }

    bool synchronizeSession(bool resume = true) {
        if (strictUsb_ && callbackFault_.load(std::memory_order_acquire)) {
            strictFailure_ = "iOS direct output stopped after an unexpected AudioUnit callback layout";
            disposeUnit();
            return false;
        }
        if (!strictFailure_.empty()) return false;
        auto state = iosSessionState();
        if (strictUsb_ && (!strictReady_.load(std::memory_order_acquire) ||
                iosSessionRealtimeRevision() != validatedSessionRevision_.load(std::memory_order_acquire))) {
            rebuildRequired_ = true;
            nextRecoveryAttempt_ = {};
        }
        if (state.revision != sessionRevision_) {
            sessionRevision_ = state.revision;
            rebuildRequired_ = true;
            nextRecoveryAttempt_ = {};
            // Removed headphones and ShouldResume=false must never turn into
            // an unsolicited speaker restart. Only start() grants permission.
            if (!state.mayResume) requestedRunning_ = false;
        }
        if (state.interrupted || !state.mediaServicesAvailable || !state.mayResume) {
            clearRecoveryFailure();
            disposeUnit();
            rebuildRequired_ = true;
            if (strictUsb_ && !state.mayResume && !state.interrupted && state.mediaServicesAvailable) {
                strictFailure_ = "iOS direct USB output stopped after the route was removed; reopen playback";
            }
            return false;
        }
        if (rebuildRequired_) {
            const auto now = std::chrono::steady_clock::now();
            if (now < nextRecoveryAttempt_) return false;
            disposeUnit();
            IosSessionInfo info;
            std::string recoveryError;
            // Keep the engine / queue clock fixed for this open session. The
            // Ordinary playback may resample to the new route; strict USB must
            // revalidate the same device and exact clock before any resumption.
            const int32_t activated = iosSessionActivate(strictUsb_ ? target_.sampleRate : 0,
                bufferMillis_, info, recoveryError, strictUsb_);
            // setActive / preferred-buffer requests may notify synchronously.
            state = iosSessionState();
            sessionRevision_ = state.revision;
            if (!state.mayResume) requestedRunning_ = false;
            if (state.interrupted || !state.mediaServicesAvailable || !state.mayResume) {
                clearRecoveryFailure();
                disposeUnit();
                nextRecoveryAttempt_ = now + std::chrono::milliseconds(50);
                return false;
            }
            if (activated == LazerAudioOk && strictUsb_) {
                if (!validUsbRoute(info, target_, strictRouteUid_, recoveryError)) {
                    strictFailure_ = recoveryError;
                    requestedRunning_ = false;
                    return false;
                }
                validatedSessionRevision_.store(info.revision, std::memory_order_release);
            }
            if (activated != LazerAudioOk || createUnit(recoveryError) != LazerAudioOk) {
                disposeUnit();
                if (strictUsb_) {
                    strictFailure_ = recoveryError;
                    requestedRunning_ = false;
                    return false;
                }
                recordRecoveryFailure(recoveryError);
                return false;
            }
            if (info.sampleRate > 0 && info.ioBufferFrames > 0) {
                const int64_t clientFrames = static_cast<int64_t>(info.ioBufferFrames) *
                    target_.sampleRate / info.sampleRate;
                ioPeriodFrames_.store(static_cast<int32_t>(std::clamp<int64_t>(
                    clientFrames, 1, std::numeric_limits<int32_t>::max())),
                    std::memory_order_release);
            }
            rebuildRequired_ = false;
        }
        if (unit_ == nullptr || !initialized_) return false;
        if (resume && requestedRunning_ && !running_) {
            const OSStatus status = AudioOutputUnitStart(unit_);
            if (status != noErr) {
                disposeUnit();
                rebuildRequired_ = true;
                recordRecoveryFailure(statusText("AudioOutputUnitStart during recovery", status));
                return false;
            }
            running_ = true;
        }
        clearRecoveryFailure();
        return true;
    }

    /* The OS audio thread. No locks, no allocation, no logging: it only moves
     * bytes out of the SPSC queue and reports underruns it had to pad. */
    static OSStatus renderThunk(void *reference, AudioUnitRenderActionFlags *flags,
        const AudioTimeStamp *timeStamp, UInt32 bus, UInt32 frames, AudioBufferList *data) {
        return static_cast<RemoteIOOutput *>(reference)->render(flags, timeStamp, bus, frames, data);
    }

    static void silence(AudioBufferList *data) noexcept {
        for (UInt32 index = 0; index < data->mNumberBuffers; ++index) {
            if (data->mBuffers[index].mData != nullptr) {
                std::memset(data->mBuffers[index].mData, 0, data->mBuffers[index].mDataByteSize);
            }
        }
    }

    bool strictCallbackAuthorized() const noexcept {
        return strictReady_.load(std::memory_order_acquire) &&
            iosSessionRealtimeRevision() == validatedSessionRevision_.load(std::memory_order_acquire);
    }

    OSStatus renderStrict(UInt32 frames, AudioBufferList *data) noexcept {
        silence(data);
        if (!strictCallbackAuthorized()) return noErr;
        AudioBuffer &buffer = data->mBuffers[0];
        const size_t sourceFrameBytes = static_cast<size_t>(target_.frameBytes());
        const size_t floatFrameBytes = static_cast<size_t>(target_.channels) * sizeof(float);
        if (data->mNumberBuffers != 1 || buffer.mData == nullptr ||
            buffer.mNumberChannels != static_cast<UInt32>(target_.channels) ||
            static_cast<size_t>(frames) > directScratch_.size() / sourceFrameBytes ||
            static_cast<size_t>(frames) > buffer.mDataByteSize / floatFrameBytes ||
            buffer.mDataByteSize % floatFrameBytes != 0) {
            callbackFault_.store(true, std::memory_order_release);
            strictReady_.store(false, std::memory_order_release);
            return noErr;
        }
        const int32_t copied = queue_.readInterleavedBytes(directScratch_.data(), directScratch_.size(), frames);
        if (copied < 0) {
            callbackFault_.store(true, std::memory_order_release);
            strictReady_.store(false, std::memory_order_release);
            return noErr;
        }
        const size_t audioFrames = static_cast<size_t>(copied);
        if (target_.doP && !prepareCoreAudioDoPCarrier(directScratch_.data(), frames, audioFrames,
                target_.channels, nextDoPMarker_)) {
            callbackFault_.store(true, std::memory_order_release);
            strictReady_.store(false, std::memory_order_release);
            return noErr;
        }
        const size_t samples = (target_.doP ? frames : audioFrames) * static_cast<size_t>(target_.channels);
        const size_t width = static_cast<size_t>(target_.bitsPerSample / 8);
        const float scale = target_.bitsPerSample == 16 ? 1.0f / 32768.0f : 1.0f / 8388608.0f;
        auto *destination = static_cast<float *>(buffer.mData);
        for (size_t index = 0; index < samples; ++index) {
            const uint8_t *word = directScratch_.data() + index * width;
            int32_t value = static_cast<int32_t>(word[0]) | (static_cast<int32_t>(word[1]) << 8);
            if (width == 3) {
                value |= static_cast<int32_t>(word[2]) << 16;
                if (value >= 0x800000) value -= 0x1000000;
            } else if (value >= 0x8000) {
                value -= 0x10000;
            }
            destination[index] = static_cast<float>(value) * scale;
        }
        if (audioFrames < frames) {
            underrunFrames_.fetch_add(frames - audioFrames, std::memory_order_relaxed);
        }
        // Notification may arrive during the copy: never return this block to
        // the new route after it invalidates our exact-output contract.
        if (!strictCallbackAuthorized()) silence(data);
        return noErr;
    }

    OSStatus render(AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32 frames,
        AudioBufferList *data) {
        if (data == nullptr || data->mNumberBuffers == 0) return noErr;
        if (strictUsb_) return renderStrict(frames, data);
        const int32_t frameBytes = frameBytes_.load(std::memory_order_acquire);
        if (frameBytes <= 0) return noErr;

        // The client format is interleaved, so a well-behaved unit hands exactly one
        // buffer. Anything else is still answered rather than left alone: whatever a
        // buffer keeps from the previous callback is device memory the listener would
        // hear as noise, and this callback must never be the reason a route plays
        // garbage back.
        AudioBuffer &buffer = data->mBuffers[0];
        int32_t received = 0;
        int32_t wanted = 0;
        if (buffer.mData != nullptr) {
            const size_t capacityFrames = buffer.mDataByteSize / static_cast<size_t>(frameBytes);
            wanted = static_cast<int32_t>(std::min<size_t>(frames, capacityFrames));
            if (wanted > 0) {
                const int32_t dequeued = queue_.readInterleavedBytes(
                    static_cast<uint8_t *>(buffer.mData), buffer.mDataByteSize,
                    static_cast<size_t>(wanted));
                received = dequeued > 0 ? std::min(dequeued, wanted) : 0;
            }
            const size_t filled = static_cast<size_t>(received) * static_cast<size_t>(frameBytes);
            if (buffer.mDataByteSize > filled) {
                std::memset(static_cast<uint8_t *>(buffer.mData) + filled, 0,
                    buffer.mDataByteSize - filled);
            }
        }
        if (received < wanted) {
            underrunFrames_.fetch_add(static_cast<uint64_t>(wanted - received),
                std::memory_order_relaxed);
        }
        for (UInt32 index = 1; index < data->mNumberBuffers; ++index) {
            AudioBuffer &extra = data->mBuffers[index];
            if (extra.mData != nullptr && extra.mDataByteSize > 0) {
                std::memset(extra.mData, 0, extra.mDataByteSize);
            }
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
    bool strictUsb_ = false;
    bool formatListener_ = false;
    std::string strictRouteUid_;
    std::string strictFailure_;
    std::vector<uint8_t> directScratch_;
    uint8_t nextDoPMarker_ = 0x05;
    std::atomic<bool> strictReady_{false};
    std::atomic<bool> callbackFault_{false};
    std::atomic<uint64_t> formatRevision_{0};
    std::atomic<uint64_t> validatedSessionRevision_{0};
    int32_t bufferMillis_ = 120;
    uint64_t sessionRevision_ = 0;
    std::chrono::steady_clock::time_point nextRecoveryAttempt_{};
    std::chrono::steady_clock::time_point recoveryFailedAt_{};
    std::string recoveryFailure_;
    TargetFormat target_{};
    std::atomic<int32_t> frameBytes_{0};
    /// The IO period the route granted, in frames; 0 before the first open.
    std::atomic<int32_t> ioPeriodFrames_{0};
    std::atomic<uint64_t> underrunFrames_{0};
};

}  // namespace

std::unique_ptr<AudioOutput> createPlatformAudioOutput() {
    return std::make_unique<RemoteIOOutput>();
}

}  // namespace lazer::audio
