#include "engine.h"
#include "pcm_output.h"
#include "queued_pcm_buffer.h"
#include "dop_packer.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <deque>

extern "C" {
#include <libavutil/avutil.h>
#include <libavcodec/version.h>
#include <libavformat/version.h>
#include <libswresample/version.h>
}

namespace lazer::audio {

namespace {

constexpr int32_t kRenderWaitMillis = 50;
constexpr int32_t kIdleSleepMillis = 3;
constexpr size_t kRenderBlockFrames = 960;

bool doPOutputApplies(int32_t dsdOutputMode, const StreamDescription &source) noexcept {
    return dsdOutputMode == LazerAudioDsdOutputRequireDoP && source.dsd && source.rawDsd &&
        (source.channels == 1 || source.channels == 2);
}

bool nativeDsdOutputApplies(int32_t dsdOutputMode, const StreamDescription &source) noexcept {
    return dsdOutputMode == LazerAudioDsdOutputRequireNative && source.dsd;
}

double replayGainLinear(double gainDb) noexcept {
    return std::pow(10.0, gainDb / 20.0);
}

void sleepIdle() {
    std::this_thread::sleep_for(std::chrono::milliseconds(kIdleSleepMillis));
}

}  // namespace

struct Engine::SourceSlot final : SourceConsumer {
    explicit SourceSlot(Engine *engine, LazerAudioLogHandler handler)
        : owner(engine), source(&log) {
        log.install(handler);
    }

    ~SourceSlot() {
        cancel();
        joinPrefetch();
        source.close();
    }

    void configurePrefetch(int32_t sampleRate, int32_t periodFrames, int32_t frameBytes) {
        const size_t rate = static_cast<size_t>(std::max(sampleRate, 1));
        const size_t period = static_cast<size_t>(std::max(periodFrames, 1));
        const size_t capacity = std::max(rate, period * 4);
        const size_t watermark = std::min(capacity, std::max(rate / 4, period * 2));
        pcm = std::make_unique<QueuedPcmBuffer>(capacity, watermark,
            static_cast<size_t>(std::max(frameBytes, 1)));
    }

    bool startPrefetch() {
        std::lock_guard guard(prefetchThreadMutex);
        if (pcm == nullptr || prefetchStarted) return false;
        return launchPrefetchLocked();
    }

    bool launchPrefetchLocked() {
        if (pcm == nullptr || cancelled.load(std::memory_order_acquire) ||
            prefetchRunning.load(std::memory_order_acquire)) return false;
        prefetchRunning.store(true, std::memory_order_release);
        try {
            prefetchThread = std::thread([this] {
                for (;;) {
                    const int32_t result = source.pump(*this);
                    std::unique_lock consumerGuard(consumerMutex);
                    if (!cancelled.load(std::memory_order_acquire) && source.hasPendingSeek()) {
                        consumerGuard.unlock();
                        continue;
                    }
                    pcm->finish(result, source.lastError(), source.reachedEndOfStream());
                    prefetchRunning.store(false, std::memory_order_release);
                    return;
                }
            });
            prefetchStarted = true;
            return true;
        } catch (...) {
            prefetchRunning.store(false, std::memory_order_release);
            return false;
        }
    }

    void cancel() {
        cancelled.store(true, std::memory_order_release);
        if (pcm != nullptr) pcm->cancel();
        source.interruptReader();
    }

    void joinPrefetch() {
        std::lock_guard guard(prefetchThreadMutex);
        if (prefetchThread.joinable() && prefetchThread.get_id() != std::this_thread::get_id()) {
            prefetchThread.join();
        }
    }

    void requestSeek(int64_t positionMillis) {
        bool restartFinishedPrefetch = false;
        {
            std::lock_guard guard(consumerMutex);
            if (cancelled.load(std::memory_order_acquire)) return;
            source.requestSeek(positionMillis);
            if (pcm != nullptr) pcm->discardAll();
            if (pcm != nullptr && !prefetchRunning.load(std::memory_order_acquire)) {
                /* The successor can be fully decoded before its audible boundary. Reopen the
                 * staging buffer while holding the consumer lock so the engine pump cannot mistake
                 * the just-discarded, finished queue for the end of the whole session. */
                restartFinishedPrefetch = pcm->resetForRestart();
            }
            if (owner != nullptr) owner->seekFlushRequested_.store(true, std::memory_order_release);
        }
        if (restartFinishedPrefetch) {
            std::lock_guard guard(prefetchThreadMutex);
            if (prefetchThread.joinable()) prefetchThread.join();
            if (!launchPrefetchLocked() && pcm != nullptr) {
                pcm->finish(LazerAudioErrorNoMemory,
                    "could not restart queued decoder after seek", false);
            }
        }
    }

    int32_t accept(const uint8_t *bytes, int32_t frameCount) override {
        std::lock_guard guard(consumerMutex);
        if (cancelled.load(std::memory_order_acquire) || pcm == nullptr || source.hasPendingSeek()) {
            return 0;
        }
        return pcm->accept(bytes, frameCount);
    }

    bool shouldPump() const override {
        return !cancelled.load(std::memory_order_acquire) && pcm != nullptr && pcm->shouldPump();
    }

    bool isCancelled() const override {
        return cancelled.load(std::memory_order_acquire) || pcm == nullptr || pcm->isCancelled();
    }

    void onSeekApplied() override {
        if (pcm != nullptr) {
            /* A queued source's initial CUE seek positions its private decoder before the track
             * boundary. It must not flush the active source's output ring. User seeks on an
             * activated queued source already request the session flush in requestSeek(). */
            std::lock_guard guard(consumerMutex);
            pcm->discardAll();
            return;
        }
        if (owner != nullptr) owner->onSeekApplied();
    }

    LogProxy log;
    LazerAudioReader reader{};
    Engine *owner = nullptr;
    AudioSource source;
    uint64_t queueGeneration = 0;
    double replayGainLinear = 1.0;
    std::unique_ptr<QueuedPcmBuffer> pcm;
    std::thread prefetchThread;
    std::mutex prefetchThreadMutex;
    std::mutex consumerMutex;
    std::atomic<bool> cancelled{false};
    std::atomic<bool> prefetchRunning{false};
    bool prefetchStarted = false;
};

Engine::Engine(LazerAudioEngineConfig config)
    : Engine(config, createPlatformAudioOutput()) {}

Engine::Engine(LazerAudioEngineConfig config, std::unique_ptr<AudioOutput> output)
    : config_(config), output_(std::move(output)) {
    log_.install(config_.log);
    source_ = std::make_shared<SourceSlot>(this, config_.log);
    device_ = config_.device;
    if (config_.device.device_id != nullptr && config_.device.device_id[0] != L'\0') {
        deviceId_ = config_.device.device_id;
        device_.device_id = deviceId_.c_str();
    } else {
        device_.device_id = nullptr;
    }
    if (device_.buffer_millis <= 0) device_.buffer_millis = 120;
}

Engine::~Engine() {
    teardown();
}

Engine *Engine::create(const LazerAudioEngineConfig &config) {
    return create(config, createPlatformAudioOutput());
}

Engine *Engine::create(
    const LazerAudioEngineConfig &config, std::unique_ptr<AudioOutput> output) {
    if (config.abi_version != LAZER_AUDIO_ABI_VERSION) return nullptr;
    if (config.struct_size < sizeof(LazerAudioEngineConfig)) return nullptr;
    if (config.device.dsd_output_mode != LazerAudioDsdOutputConvertToPcm &&
        config.device.dsd_output_mode != LazerAudioDsdOutputRequireDoP &&
        config.device.dsd_output_mode != LazerAudioDsdOutputRequireNative) return nullptr;
    auto *engine = new (std::nothrow) Engine(config, std::move(output));
    return engine;
}

void Engine::destroy() {
    stop();
    delete this;
}

void Engine::joinThreads() {
    if (renderThread_.joinable()) renderThread_.join();
    if (pumpThread_.joinable()) pumpThread_.join();
}

void Engine::cancelCurrentSources() {
    std::shared_ptr<SourceSlot> active;
    std::shared_ptr<SourceSlot> queued;
    std::shared_ptr<SourceSlot> preparing;
    {
        std::lock_guard sourceGuard(sourceMutex_);
        active = source_;
        queued = nextSource_;
        preparing = preparingSource_;
    }
    if (active != nullptr) {
        if (active->prefetchStarted) active->cancel();
        else active->source.interruptReader();
    }
    if (queued != nullptr) {
        queued->cancel();
        queued->joinPrefetch();
    }
    if (preparing != nullptr) preparing->cancel();
}

void Engine::retireCurrentSources() {
    std::shared_ptr<SourceSlot> active;
    std::shared_ptr<SourceSlot> queued;
    std::shared_ptr<SourceSlot> preparing;
    {
        std::lock_guard sourceGuard(sourceMutex_);
        active = std::move(source_);
        queued = std::move(nextSource_);
        preparing = std::move(preparingSource_);
        presentationDescription_ = {};
        pendingPresentationDescription_ = {};
        presentationSeekTargetMillis_ = 0;
        pendingPresentationSeekTargetMillis_ = 0;
        presentationBufferedPercent_ = 0;
        pendingPresentationReady_.store(false, std::memory_order_release);
        pendingPresentationSeek_.store(false, std::memory_order_release);
        pendingTrackChangedFrame_.store(-1, std::memory_order_release);
    }
    for (const auto &slot : {active, queued, preparing}) {
        if (slot != nullptr) {
            slot->cancel();
            slot->joinPrefetch();
        }
    }
    active.reset();
    queued.reset();
    preparing.reset();
}

void Engine::teardown() {
    std::lock_guard lifecycleGuard(lifecycleMutex_);
    cancelled_.store(true, std::memory_order_release);
    paused_.store(true, std::memory_order_release);
    dopActive_.store(false, std::memory_order_release);
    nativeDsdActive_.store(false, std::memory_order_release);
    cancelCurrentSources();
    joinThreads();
    if (output_ != nullptr) output_->close();
    outputSession_ = AudioOutputSession{};
    retireCurrentSources();
    state_.store(LazerAudioStateIdle, std::memory_order_release);
}

int32_t Engine::open(
    const wchar_t *path, const LazerAudioReader *reader, const LazerAudioOpenParams &params) {
    /* One open at a time, and a fresh open always retires the previous stream first so a stale pump
     * or render thread can never write into the new pipeline. */
    if (path == nullptr && reader == nullptr) return LazerAudioErrorInvalidArgument;
    std::unique_lock lifecycleGuard(lifecycleMutex_);
    const uint64_t generation = sessionGeneration_.fetch_add(1, std::memory_order_acq_rel) + 1;
    cancelled_.store(true, std::memory_order_release);
    paused_.store(true, std::memory_order_release);
    cancelCurrentSources();
    joinThreads();
    if (output_ != nullptr) output_->close();
    outputSession_ = AudioOutputSession{};
    retireCurrentSources();
    state_.store(LazerAudioStatePreparing, std::memory_order_release);
    terminalClaimed_.store(false, std::memory_order_release);
    terminalDetail_.store(0, std::memory_order_relaxed);
    terminalPositionMillis_.store(0, std::memory_order_relaxed);
    terminalEvent_.store(-1, std::memory_order_release);
    {
        std::lock_guard sourceGuard(sourceMutex_);
        source_ = std::make_shared<SourceSlot>(this, config_.log);
    }
    std::unique_lock apiGuard(apiMutex_);
    cancelled_.store(false, std::memory_order_release);
    endedRaised_.store(false, std::memory_order_release);
    pumpFinished_.store(false, std::memory_order_release);
    writtenFrames_.store(0, std::memory_order_release);
    renderedFrames_.store(0, std::memory_order_release);
    acceptedFrames_.store(0, std::memory_order_release);
    trackStartOutputFrame_.store(0, std::memory_order_release);
    pendingTrackChangedFrame_.store(-1, std::memory_order_release);
    pendingPresentationReady_.store(false, std::memory_order_release);
    pendingPresentationSeek_.store(false, std::memory_order_release);
    seekFlushRequested_.store(false, std::memory_order_release);
    exclusiveInFlightAudioFrames_.store(0, std::memory_order_release);
    outputPeakMilliDbfs_.store(-120'000, std::memory_order_release);
    limiterGainReductionMilliDb_.store(0, std::memory_order_release);
    outputClippedSampleCount_.store(0, std::memory_order_release);
    outputTelemetryValid_.store(false, std::memory_order_release);
    underrunActive_.store(0, std::memory_order_release);
    underrunFrames_.store(0, std::memory_order_release);
    streamStarted_ = false;
    lastError_.clear();
    lastErrorCode_.store(LazerAudioOk, std::memory_order_release);
    bitPerfectActive_ = false;
    dopActive_.store(false, std::memory_order_release);
    nativeDsdActive_.store(false, std::memory_order_release);
    resetDopMarker();
    const LazerAudioOpenParams safeParams = params;
    if (!std::isfinite(safeParams.replay_gain_db) || safeParams.replay_gain_db < -60.0 ||
        safeParams.replay_gain_db > 24.0) {
        setErrorLocked("ReplayGain must be finite and within -60..24 dB",
            LazerAudioErrorInvalidArgument);
        publishTerminal(LazerAudioEventFailed, LazerAudioErrorInvalidArgument, 0);
        return LazerAudioErrorInvalidArgument;
    }
    int32_t result = LazerAudioOk;
    std::shared_ptr<SourceSlot> openingSource;
    {
        std::lock_guard sourceGuard(sourceMutex_);
        openingSource = source_;
        openingSource->replayGainLinear = replayGainLinear(safeParams.replay_gain_db);
        if (reader != nullptr) {
            openingSource->reader = *reader;
        }
    }
    if (reader != nullptr) {
        /* Bind the callbacks before publishing the slot. A concurrent stop can then cancel even if
         * it lands before FFmpeg begins probing the reader. */
        result = openingSource->source.prepareReader(openingSource->reader);
        if (result == LazerAudioOk) {
            std::lock_guard sourceGuard(sourceMutex_);
            preparingSource_ = openingSource;
        }
    }
    if (reader != nullptr && result == LazerAudioOk) {
        /* A caller reader can block while opening a growing HTTP cache. Publish its slot so stop or
         * replacement can interrupt it, then release engine locks while FFmpeg probes the stream. */
        apiGuard.unlock();
        lifecycleGuard.unlock();
        result = openingSource->source.openReader(openingSource->reader, safeParams);
        lifecycleGuard.lock();

        bool stillCurrent = false;
        {
            std::lock_guard sourceGuard(sourceMutex_);
            stillCurrent = source_ == openingSource;
            if (preparingSource_ == openingSource) preparingSource_.reset();
        }
        if (sessionGeneration_.load(std::memory_order_acquire) != generation ||
            cancelled_.load(std::memory_order_acquire) || !stillCurrent) {
            lifecycleGuard.unlock();
            openingSource->source.close();
            return LazerAudioErrorState;
        }
        apiGuard.lock();
    } else if (reader == nullptr) {
        std::lock_guard sourceGuard(sourceMutex_);
        result = openingSource->source.openFile(path, safeParams);
    }
    if (result == LazerAudioOk) {
        std::lock_guard sourceGuard(sourceMutex_);
        presentationDescription_ = openingSource->source.description();
        presentationSeekTargetMillis_ = openingSource->source.seekTargetMillis();
        presentationBufferedPercent_ = static_cast<int32_t>(
            openingSource->source.bufferedFraction() * 100.0);
    }
    if (result != LazerAudioOk) {
        setErrorLocked(currentSource().lastError(), result);
        publishTerminal(LazerAudioEventFailed, result, 0);
        return result;
    }

    const bool requireDoP = doPOutputApplies(
        device_.dsd_output_mode, currentSource().description());
    const bool requireNativeDsd = nativeDsdOutputApplies(
        device_.dsd_output_mode, currentSource().description());
    if (safeParams.replay_gain_db != 0.0 &&
        (device_.bit_perfect != 0 || requireDoP || requireNativeDsd)) {
        setErrorLocked("ReplayGain changes samples and is unavailable in bit-perfect or direct DSD mode",
            LazerAudioErrorUnsupported);
        currentSource().close();
        publishTerminal(LazerAudioEventFailed, LazerAudioErrorUnsupported, 0);
        return LazerAudioErrorUnsupported;
    }
    if ((requireDoP || requireNativeDsd) && device_.bit_perfect != 0) {
        setErrorLocked("direct DSD output and bit-perfect PCM output are separate modes",
            LazerAudioErrorInvalidArgument);
        currentSource().close();
        publishTerminal(LazerAudioEventFailed, LazerAudioErrorInvalidArgument, 0);
        return LazerAudioErrorInvalidArgument;
    }
    if ((device_.bit_perfect != 0 || requireDoP || requireNativeDsd) &&
        volume_.load(std::memory_order_acquire) < 0.999999) {
        setErrorLocked("set software volume to 100% and use the DAC volume for direct output",
            LazerAudioErrorUnsupported);
        currentSource().close();
        publishTerminal(LazerAudioEventFailed, LazerAudioErrorUnsupported, 0);
        return LazerAudioErrorUnsupported;
    }

    if (output_ == nullptr) {
        setErrorLocked("no local audio output backend is available", LazerAudioErrorUnsupported);
        currentSource().close();
        publishTerminal(LazerAudioEventFailed, LazerAudioErrorUnsupported, 0);
        return LazerAudioErrorUnsupported;
    }

    AudioOutputRequest request;
    if (!wideStringToUtf8(device_.device_id, request.deviceId)) {
        setErrorLocked("the selected output device ID is not valid Unicode", LazerAudioErrorInvalidArgument);
        currentSource().close();
        publishTerminal(LazerAudioEventFailed, LazerAudioErrorInvalidArgument, 0);
        return LazerAudioErrorInvalidArgument;
    }
    request.exclusive = device_.exclusive != 0 || requireDoP || requireNativeDsd;
    request.bufferMillis = device_.buffer_millis > 0 ? device_.buffer_millis : 120;
    request.bitPerfect = device_.bit_perfect != 0;
    request.requireDoP = requireDoP;
    request.requireNativeDsd = requireNativeDsd;
    request.desired.sampleRate = currentSource().description().sampleRate;
    request.desired.channels = currentSource().description().channels;
    if (requireDoP) {
        request.desired.sampleRate = currentSource().description().sampleRate / 2;
        request.desired.bitsPerSample = 24;
        request.desired.containerBitsPerSample = 24;
        request.desired.doP = true;
    } else if (requireNativeDsd) {
        request.desired.nativeDsd = true;
    }

    std::string deviceError;
    result = output_->open(request, currentSource().description(), outputSession_, deviceError, &log_);
    if (result != LazerAudioOk) {
        setErrorLocked(deviceError, result);
        currentSource().close();
        publishTerminal(LazerAudioEventFailed, result, 0);
        return result;
    }

    result = configurePipeline();
    if (result != LazerAudioOk) {
        setErrorLocked(lastError_, result);
        output_->close();
        currentSource().close();
        publishTerminal(LazerAudioEventFailed, result, 0);
        return result;
    }

    pumpThread_ = std::thread([this] { pumpLoop(); });
    renderThread_ = std::thread([this] { renderLoop(); });
    int32_t expectedState = LazerAudioStatePreparing;
    if (state_.compare_exchange_strong(expectedState, LazerAudioStateReady,
        std::memory_order_acq_rel, std::memory_order_acquire)) {
        raise(LazerAudioEventReady, 0, currentPositionMillis());
    }
    return LazerAudioOk;
}

int32_t Engine::configurePipeline() {
    const StreamDescription &description = currentSource().description();
    const TargetFormat &target = outputSession_.target;
    const bool requireDoP = doPOutputApplies(device_.dsd_output_mode, description);
    const bool requireNativeDsd = nativeDsdOutputApplies(device_.dsd_output_mode, description);
    if (requireDoP != outputSession_.doP || requireNativeDsd != outputSession_.nativeDsd) {
        lastError_ = requireDoP
            ? "the selected output did not initialize the required DoP carrier format"
            : requireNativeDsd
                ? "the selected output did not initialize the required Native DSD format"
                : "the output initialized a DSD mode even though PCM output was requested";
        return LazerAudioErrorUnsupported;
    }
    nativeDsdActive_.store(false, std::memory_order_release);
    if (outputSession_.doP) {
        if (!description.dsd || !description.rawDsd || !outputSession_.exclusive ||
            target.sampleRate <= 0 || target.sampleRate * 2 != description.sampleRate ||
            target.channels != description.channels || target.bitsPerSample != 24 ||
            target.frameBytes() != target.channels * 3) {
            lastError_ = "the initialized output does not match the raw DSD DoP carrier contract";
            return LazerAudioErrorUnsupported;
        }
        TargetFormat dopTarget = target;
        dopTarget.doP = true;
        const int32_t result = currentSource().setTargetFormat(dopTarget);
        if (result != LazerAudioOk) {
            lastError_ = currentSource().lastError();
            return result;
        }
        dspBypassed_ = false;
        dopActive_.store(true, std::memory_order_release);
    } else {
        dopActive_.store(false, std::memory_order_release);
    }
    if (outputSession_.nativeDsd) {
        const int32_t wordBytes = target.containerBitsPerSample / 8;
        if (!description.dsd || !description.rawDsd || !outputSession_.exclusive ||
            !target.nativeDsd || target.sampleRate <= 0 ||
            (target.containerBitsPerSample != 8 && target.containerBitsPerSample != 16 &&
                target.containerBitsPerSample != 32) ||
            target.bitsPerSample != target.containerBitsPerSample ||
            static_cast<int64_t>(target.sampleRate) * wordBytes != description.sampleRate ||
            target.channels != description.channels ||
            (target.channels != 1 && target.channels != 2)) {
            lastError_ = "the initialized output does not match the raw Native DSD format contract";
            return LazerAudioErrorUnsupported;
        }
        TargetFormat rawDsdTarget = target;
        rawDsdTarget.sampleRate = description.sampleRate;
        rawDsdTarget.bitsPerSample = 8;
        rawDsdTarget.containerBitsPerSample = 8;
        rawDsdTarget.nativeDsd = false;
        rawDsdTarget.nativeDsdRawBytes = true;
        rawDsdTarget.nativeDsdBigEndian = true;
        rawDsdTarget.nativeDsdWordBytes = wordBytes;
        const int32_t result = currentSource().setTargetFormat(rawDsdTarget);
        if (result != LazerAudioOk) {
            lastError_ = currentSource().lastError();
            return result;
        }
        nativeDsdPacker_ = NativeDsdPacker(static_cast<size_t>(target.channels),
            static_cast<size_t>(wordBytes), target.nativeDsdBigEndian);
        dspBypassed_ = false;
        nativeDsdActive_.store(true, std::memory_order_release);
    } else {
        nativeDsdPacker_ = NativeDsdPacker{};
    }
    const bool exactContainer = target.containerBitsPerSample == target.bitsPerSample ||
        (target.bitsPerSample == 24 && target.containerBitsPerSample == 32);
    const bool exactPcmFormat = description.lossless && description.integerPcm &&
        description.canonicalChannelLayout && description.decoderFormatMatchesStream &&
        (description.channels == 1 || description.channels == 2) &&
        description.sampleRate == target.sampleRate &&
        description.channels == target.channels && description.bitsPerSample == target.bitsPerSample &&
        exactContainer &&
        (target.bitsPerSample == 16 || target.bitsPerSample == 24 || target.bitsPerSample == 32);
    if (!outputSession_.doP && !outputSession_.nativeDsd &&
        device_.bit_perfect != 0 && !exactPcmFormat) {
        lastError_ = "bit-perfect output requires exact mono or stereo lossless integer PCM format";
        return LazerAudioErrorUnsupported;
    }
    if (!outputSession_.doP && !outputSession_.nativeDsd) {
        dspBypassed_ = device_.bit_perfect != 0 && outputSession_.exclusive && exactPcmFormat;
    }
    if (outputSession_.doP) {
        /* DoP words are an encoded DSD bitstream. They must reach the carrier untouched, with
         * software processing and quantization completely out of the chain. */
    } else if (outputSession_.nativeDsd) {
        /* Native DSD is a raw bitstream, so keep it out of the PCM DSP and float conversion path. */
    } else if (dspBypassed_) {
        /* Bit-perfect stream out: the decoded integer samples go straight to the device, which is why
         * the volume control must then belong to the amplifier or the DAC. */
        const int32_t result = currentSource().setTargetFormat(outputSession_.target);
        if (result != LazerAudioOk) {
            lastError_ = currentSource().lastError();
            return result;
        }
    } else {
        TargetFormat floatTarget;
        floatTarget.sampleRate = outputSession_.target.sampleRate;
        floatTarget.channels = outputSession_.target.channels;
        floatTarget.bitsPerSample = 0;
        floatTarget_ = floatTarget;
        const int32_t result = currentSource().setTargetFormat(floatTarget);
        if (result != LazerAudioOk) {
            lastError_ = currentSource().lastError();
            return result;
        }
        dsp_.configureFormat(outputSession_.engineFormat);
        dsp_.setVolume(volume_.load(std::memory_order_acquire),
            static_cast<int32_t>(volumeRampMillis_.load(std::memory_order_acquire)));
    }

    const int32_t frameBytes = outputSession_.target.frameBytes();
    const int32_t wantedFrames = std::max(
        outputSession_.bufferFrames * 3,
        outputSession_.target.sampleRate * std::max(device_.buffer_millis, 60) / 1000);
    ring_.reset(wantedFrames, frameBytes);
    convertScratch_.assign(static_cast<size_t>(wantedFrames) * frameBytes, 0);
    const size_t queuedScratchFrames = std::max(kRenderBlockFrames,
        static_cast<size_t>(std::max(outputSession_.bufferFrames, 1)));
    if (outputSession_.nativeDsd) {
        const size_t rawFrameBytes = static_cast<size_t>(std::max(target.channels, 1));
        const size_t wordBytes = static_cast<size_t>(target.containerBitsPerSample / 8);
        queuedPcmScratch_.assign(queuedScratchFrames * wordBytes * rawFrameBytes, 0);
        nativeDsdScratch_.assign(queuedScratchFrames * frameBytes, 0);
    } else {
        queuedPcmScratch_.assign(static_cast<size_t>(queuedScratchFrames) * frameBytes, 0);
        nativeDsdScratch_.clear();
    }
    replayGainCurrentLinear_ = source_->replayGainLinear;
    replayGainTargetLinear_ = source_->replayGainLinear;
    replayGainRampRemainingFrames_ = 0;
    bitPerfectActive_.store(dspBypassed_, std::memory_order_release);
    return LazerAudioOk;
}

int32_t Engine::queueReader(
    uint64_t queueGeneration, const LazerAudioReader &reader,
    const LazerAudioOpenParams &params) {
    if (reader.read == nullptr) return LazerAudioErrorInvalidArgument;
    if (!std::isfinite(params.replay_gain_db) || params.replay_gain_db < -60.0 ||
        params.replay_gain_db > 24.0) return LazerAudioErrorInvalidArgument;

    auto prepared = std::make_shared<SourceSlot>(this, config_.log);
    prepared->queueGeneration = queueGeneration;
    prepared->replayGainLinear = replayGainLinear(params.replay_gain_db);
    prepared->reader = reader;
    uint64_t generation = 0;
    TargetFormat target{};
    StreamDescription activeDescription;
    bool requireBitPerfect = false;
    bool requireDoP = false;
    bool requireNativeDsd = false;
    int32_t dsdOutputMode = LazerAudioDsdOutputConvertToPcm;
    {
        std::lock_guard lifecycleGuard(lifecycleMutex_);
        const int32_t currentState = state_.load(std::memory_order_acquire);
        if (currentState != LazerAudioStateReady && currentState != LazerAudioStatePlaying &&
            currentState != LazerAudioStatePaused) return LazerAudioErrorState;
        if (pumpFinished_.load(std::memory_order_acquire)) {
            return LazerAudioErrorState;
        }
        const uint64_t currentQueueGeneration = queueGeneration_.load(std::memory_order_acquire);
        if (queueGeneration <= currentQueueGeneration) return LazerAudioErrorState;
        generation = sessionGeneration_.load(std::memory_order_acquire);
        dsdOutputMode = device_.dsd_output_mode;
        requireDoP = dopActive_.load(std::memory_order_acquire);
        requireNativeDsd = nativeDsdActive_.load(std::memory_order_acquire);
        target = requireDoP || dspBypassed_ ? outputSession_.target : floatTarget_;
        if (requireDoP) target.doP = true;
        requireBitPerfect = !requireDoP && dspBypassed_;
        if (params.replay_gain_db != 0.0 && (requireDoP || requireNativeDsd || requireBitPerfect)) {
            return LazerAudioErrorUnsupported;
        }
        {
            std::lock_guard sourceGuard(sourceMutex_);
            if (nextSource_ != nullptr || preparingSource_ != nullptr || source_ == nullptr) {
                return LazerAudioErrorState;
            }
            activeDescription = source_->source.description();
        }
        const int32_t preparedReader = prepared->source.prepareReader(prepared->reader);
        if (preparedReader != LazerAudioOk) return preparedReader;
        queueGeneration_.store(queueGeneration, std::memory_order_release);
        std::lock_guard sourceGuard(sourceMutex_);
        preparingSource_ = prepared;
    }

    const auto abandonPreparation = [&] {
        std::lock_guard sourceGuard(sourceMutex_);
        if (preparingSource_ == prepared) preparingSource_.reset();
    };

    /* Opening a growing cache reader may block while FFmpeg probes its headers. Do this away from
     * the render thread and without holding either engine mutex. The pending slot is published first
     * so clear/stop can invoke its reader interruption callback if the probe blocks. */
    const int32_t opened = prepared->source.openReader(prepared->reader, params);
    if (opened != LazerAudioOk) {
        abandonPreparation();
        return opened;
    }

    const StreamDescription &preparedDescription = prepared->source.description();
    if ((doPOutputApplies(dsdOutputMode, preparedDescription) && !requireDoP) ||
        (nativeDsdOutputApplies(dsdOutputMode, preparedDescription) &&
            !requireNativeDsd)) {
        /* A queued PCM session may not cross into a direct-DSD policy without reopening the
         * endpoint; doing so would silently convert the successor through the old pipeline. */
        abandonPreparation();
        return LazerAudioErrorUnsupported;
    }
    if (requireDoP) {
        /* The existing endpoint carries DoP as exact packed 24-bit PCM. Keep one carrier clock,
         * channel layout, and raw DSD rate for the whole session; PCM/DST or a different DSD rate
         * must fall back to the regular stop/open path so the endpoint can be renegotiated. */
        const TargetFormat &sessionTarget = outputSession_.target;
        const bool compatibleRawDsd = activeDescription.dsd && activeDescription.rawDsd &&
            preparedDescription.dsd && preparedDescription.rawDsd &&
            activeDescription.dsdRateMultiplier > 0 &&
            preparedDescription.dsdRateMultiplier == activeDescription.dsdRateMultiplier &&
            preparedDescription.sampleRate == activeDescription.sampleRate &&
            preparedDescription.channels == activeDescription.channels &&
            (preparedDescription.channels == 1 || preparedDescription.channels == 2);
        const bool compatibleCarrier = outputSession_.doP && outputSession_.exclusive &&
            sessionTarget.sampleRate > 0 &&
            sessionTarget.sampleRate == target.sampleRate &&
            static_cast<int64_t>(sessionTarget.sampleRate) * 2 == preparedDescription.sampleRate &&
            sessionTarget.channels == target.channels &&
            sessionTarget.channels == preparedDescription.channels &&
            sessionTarget.bitsPerSample == 24 && sessionTarget.containerBitsPerSample == 24 &&
            target.bitsPerSample == 24 && target.containerBitsPerSample == 24 &&
            target.frameBytes() == target.channels * 3;
        if (!compatibleRawDsd || !compatibleCarrier) {
            abandonPreparation();
            return LazerAudioErrorUnsupported;
        }
    } else if (requireNativeDsd) {
        /* Native DSD successors are staged as raw byte frames. The session-level packer remains
         * owned by Engine so a partial U16/U32 word crosses the seam without 0x69 padding. */
        const TargetFormat &sessionTarget = outputSession_.target;
        const bool compatibleRawDsd = outputSession_.nativeDsd && outputSession_.exclusive &&
            activeDescription.dsd && activeDescription.rawDsd &&
            preparedDescription.dsd && preparedDescription.rawDsd &&
            activeDescription.dsdRateMultiplier > 0 &&
            preparedDescription.dsdRateMultiplier == activeDescription.dsdRateMultiplier &&
            preparedDescription.sampleRate == activeDescription.sampleRate &&
            preparedDescription.channels == activeDescription.channels &&
            (preparedDescription.channels == 1 || preparedDescription.channels == 2);
        const int32_t wordBytes = sessionTarget.containerBitsPerSample / 8;
        const bool compatibleWordFormat = sessionTarget.nativeDsd &&
            (wordBytes == 1 || wordBytes == 2 || wordBytes == 4) &&
            sessionTarget.bitsPerSample == sessionTarget.containerBitsPerSample &&
            sessionTarget.channels == preparedDescription.channels &&
            static_cast<int64_t>(sessionTarget.sampleRate) * wordBytes ==
                preparedDescription.sampleRate;
        if (!compatibleRawDsd || !compatibleWordFormat) {
            abandonPreparation();
            return LazerAudioErrorUnsupported;
        }
        target = sessionTarget;
        target.sampleRate = preparedDescription.sampleRate;
        target.bitsPerSample = 8;
        target.containerBitsPerSample = 8;
        target.nativeDsd = false;
        target.nativeDsdRawBytes = true;
        target.nativeDsdBigEndian = true;
        target.nativeDsdWordBytes = wordBytes;
    } else {
        /* Keep the active device clock for the whole session. A different-rate successor must go
         * through the normal stop/open path so exclusive output can renegotiate before that track. */
        if (preparedDescription.sampleRate != activeDescription.sampleRate) {
            abandonPreparation();
            return LazerAudioErrorUnsupported;
        }
    }

    if (requireBitPerfect) {
        const StreamDescription &description = prepared->source.description();
        const bool exactContainer = target.containerBitsPerSample == target.bitsPerSample ||
            (target.bitsPerSample == 24 && target.containerBitsPerSample == 32);
        const bool exactPcmFormat = description.lossless && description.integerPcm &&
            description.canonicalChannelLayout && description.decoderFormatMatchesStream &&
            (description.channels == 1 || description.channels == 2) &&
            description.sampleRate == target.sampleRate &&
            description.channels == target.channels && description.bitsPerSample == target.bitsPerSample &&
            exactContainer &&
            (target.bitsPerSample == 16 || target.bitsPerSample == 24 || target.bitsPerSample == 32);
        if (!exactPcmFormat) {
            abandonPreparation();
            return LazerAudioErrorUnsupported;
        }
    }
    const int32_t formatted = prepared->source.setTargetFormat(target);
    if (formatted != LazerAudioOk) {
        abandonPreparation();
        return formatted;
    }

    {
        std::lock_guard lifecycleGuard(lifecycleMutex_);
        const int32_t currentState = state_.load(std::memory_order_acquire);
        if (sessionGeneration_.load(std::memory_order_acquire) != generation ||
            queueGeneration_.load(std::memory_order_acquire) != queueGeneration ||
            pumpFinished_.load(std::memory_order_acquire) ||
            (currentState != LazerAudioStateReady && currentState != LazerAudioStatePlaying &&
                currentState != LazerAudioStatePaused)) {
            abandonPreparation();
            return LazerAudioErrorState;
        }
        std::lock_guard sourceGuard(sourceMutex_);
        if (preparingSource_ != prepared || nextSource_ != nullptr) {
            return LazerAudioErrorState;
        }
        prepared->configurePrefetch(target.sampleRate, outputSession_.bufferFrames,
            target.frameBytes());
        if (!prepared->startPrefetch()) {
            preparingSource_.reset();
            return LazerAudioErrorNoMemory;
        }
        nextSource_ = prepared;
        preparingSource_.reset();
    }
    log_.write(LazerAudioLogDebug, requireNativeDsd
        ? "started bounded raw Native DSD byte prefetch for one compatible successor source"
        : "started bounded PCM prefetch for one compatible successor source");
    return LazerAudioOk;
}

int32_t Engine::clearQueuedReader(uint64_t queueGeneration) {
    std::shared_ptr<SourceSlot> retired;
    int32_t result = LazerAudioErrorState;
    {
        std::lock_guard lifecycleGuard(lifecycleMutex_);
        const uint64_t currentQueueGeneration = queueGeneration_.load(std::memory_order_acquire);
        if (queueGeneration <= currentQueueGeneration) return LazerAudioErrorState;
        queueGeneration_.store(queueGeneration, std::memory_order_release);
        std::lock_guard sourceGuard(sourceMutex_);
        if (nextSource_ != nullptr) {
            retired = std::move(nextSource_);
            result = LazerAudioQueueCleared;
        } else if (preparingSource_ != nullptr && preparingSource_->queueGeneration != 0 &&
            preparingSource_->queueGeneration == currentQueueGeneration) {
            retired = std::move(preparingSource_);
            result = LazerAudioQueueCleared;
        } else if (source_ != nullptr && source_->queueGeneration != 0 &&
            source_->queueGeneration == currentQueueGeneration) {
            result = LazerAudioQueueAlreadyActive;
        }
        if (retired != nullptr && !pendingPresentationReady_.load(std::memory_order_acquire)) {
            pendingTrackChangedFrame_.store(-1, std::memory_order_release);
        }
    }
    /* Interruption, worker join and close callbacks can reenter the owner; do them lock-free. */
    if (retired != nullptr) {
        retired->cancel();
        retired->joinPrefetch();
    }
    retired.reset();
    return result;
}

int32_t Engine::tryStartQueuedSource(bool &started, std::string &error) {
    started = false;
    error.clear();
    std::shared_ptr<SourceSlot> candidate;
    int64_t boundaryFrame = 0;
    {
        std::lock_guard sourceGuard(sourceMutex_);
        if (nextSource_ == nullptr || cancelled_.load(std::memory_order_acquire)) {
            return LazerAudioOk;
        }
        candidate = nextSource_;
        boundaryFrame = acceptedFrames_.load(std::memory_order_acquire);
        if (nativeDsdActive_.load(std::memory_order_acquire) &&
            nativeDsdPacker_.hasPendingInput()) {
            /* The first packed successor word also contains the old track's final DSD bytes. */
            ++boundaryFrame;
        }
        pendingPresentationReady_.store(false, std::memory_order_release);
        pendingTrackChangedFrame_.store(boundaryFrame, std::memory_order_release);
    }

    /* The render thread knows the old stream has reached its boundary and must not pad a partial
     * fixed period while the queued decoder reaches its PCM watermark. No engine mutex is held. */
    const bool ready = candidate->pcm != nullptr && candidate->pcm->waitUntilReady();
    if (!ready) {
        std::lock_guard sourceGuard(sourceMutex_);
        if (nextSource_ != candidate || cancelled_.load(std::memory_order_acquire)) {
            if (pendingTrackChangedFrame_.load(std::memory_order_acquire) == boundaryFrame) {
                pendingTrackChangedFrame_.store(-1, std::memory_order_release);
            }
            return LazerAudioOk;
        }
        if (candidate->pcm != nullptr && candidate->pcm->finished() &&
            candidate->pcm->queuedFrames() == 0) {
            const int32_t result = candidate->pcm->result();
            error = candidate->pcm->error();
            if (result != LazerAudioOk) return result;
            if (!candidate->pcm->reachedEof()) {
                error = error.empty() ? "queued audio source stopped before clean EOF" : error;
                return LazerAudioErrorSource;
            }
            error = "queued audio source produced no PCM frames";
            return LazerAudioErrorSource;
        }
        return LazerAudioOk;
    }

    std::shared_ptr<SourceSlot> retired;
    {
        std::lock_guard sourceGuard(sourceMutex_);
        if (nextSource_ != candidate || cancelled_.load(std::memory_order_acquire)) {
            if (pendingTrackChangedFrame_.load(std::memory_order_acquire) == boundaryFrame) {
                pendingTrackChangedFrame_.store(-1, std::memory_order_release);
            }
            return LazerAudioOk;
        }
        presentationDescription_ = source_->source.description();
        presentationSeekTargetMillis_ = source_->source.seekTargetMillis();
        presentationBufferedPercent_ = static_cast<int32_t>(
            source_->source.bufferedFraction() * 100.0);
        retired = std::move(source_);
        source_ = std::move(nextSource_);
        replayGainTargetLinear_ = source_->replayGainLinear;
        if (std::abs(replayGainTargetLinear_ - replayGainCurrentLinear_) < 1.0e-12) {
            replayGainCurrentLinear_ = replayGainTargetLinear_;
            replayGainRampRemainingFrames_ = 0;
        } else {
            replayGainRampRemainingFrames_ = std::max<int64_t>(
                1, static_cast<int64_t>(outputSession_.target.sampleRate) * 5 / 1000);
        }
        pendingPresentationDescription_ = source_->source.description();
        pendingPresentationSeekTargetMillis_ = source_->source.seekTargetMillis();
        pendingPresentationSeek_.store(false, std::memory_order_release);
        boundaryFrame = acceptedFrames_.load(std::memory_order_acquire);
        if (nativeDsdActive_.load(std::memory_order_acquire) &&
            nativeDsdPacker_.hasPendingInput()) {
            ++boundaryFrame;
        }
        pendingTrackChangedFrame_.store(boundaryFrame, std::memory_order_release);
        pendingPresentationReady_.store(true, std::memory_order_release);
    }
    retired.reset();
    log_.write(LazerAudioLogDebug,
        "successor source activated at output frame=" + std::to_string(boundaryFrame));
    started = true;
    return LazerAudioOk;
}

AudioSource &Engine::currentSource() noexcept {
    return source_->source;
}

const AudioSource &Engine::currentSource() const noexcept {
    return source_->source;
}

bool Engine::currentSourceEnded() const {
    std::lock_guard sourceGuard(sourceMutex_);
    return source_ == nullptr || source_->source.reachedEndOfStream();
}

int32_t Engine::play() {
    std::lock_guard lifecycleGuard(lifecycleMutex_);
    const int32_t currentState = state_.load(std::memory_order_acquire);
    if (currentState == LazerAudioStateIdle || currentState == LazerAudioStatePreparing ||
        currentState == LazerAudioStateFailed || currentState == LazerAudioStateStopped) {
        return LazerAudioErrorState;
    }

    if (outputSession_.primeBeforeStart && !streamStarted_) {
        const int32_t frameBytes = std::max(outputSession_.target.frameBytes(), 1);
        const int32_t bufferFrames = outputSession_.bufferFrames;
        std::vector<uint8_t> firstBuffer(static_cast<size_t>(bufferFrames) * frameBytes, 0);
        const int32_t audioFrames = ring_.read(firstBuffer.data(), bufferFrames);
        if (outputSession_.doP) {
            const int32_t formattedFrames = prepareDopCarrierFrames(firstBuffer.data(),
                bufferFrames, audioFrames, outputSession_.target.channels, true, dopNextMarker_);
            if (formattedFrames != bufferFrames) {
                const std::string message = "the DoP carrier formatter rejected the priming buffer";
                setError(message, LazerAudioErrorDevice);
                bitPerfectActive_.store(false, std::memory_order_release);
                publishTerminal(LazerAudioEventFailed, LazerAudioErrorDevice, currentPositionMillis());
                return LazerAudioErrorDevice;
            }
        } else if (audioFrames < bufferFrames) {
            std::memset(firstBuffer.data() + static_cast<size_t>(audioFrames) * frameBytes,
                outputSession_.nativeDsd ? 0x69 : 0,
                static_cast<size_t>(bufferFrames - audioFrames) * frameBytes);
        }
        std::string primeError;
        const int32_t primed = output_->write(firstBuffer.data(), bufferFrames, primeError);
        if (primed != bufferFrames) {
            const std::string message = primeError.empty()
                ? "could not prefill the first exclusive audio buffer" : primeError;
            setError(message, primed < 0 ? primed : LazerAudioErrorDevice);
            bitPerfectActive_.store(false, std::memory_order_release);
            publishTerminal(LazerAudioEventFailed, LazerAudioErrorDevice, currentPositionMillis());
            return LazerAudioErrorDevice;
        }
        writtenFrames_.fetch_add(audioFrames, std::memory_order_release);
        exclusiveInFlightAudioFrames_.store(audioFrames, std::memory_order_release);
    }

    std::string error;
    const int32_t result = output_->start(error);
    if (result != LazerAudioOk) {
        setError(error, result);
        bitPerfectActive_.store(false, std::memory_order_release);
        publishTerminal(LazerAudioEventFailed, result, currentPositionMillis());
        return result;
    }
    streamStarted_ = true;
    paused_.store(false, std::memory_order_release);
    state_.store(LazerAudioStatePlaying, std::memory_order_release);
    return LazerAudioOk;
}

int32_t Engine::pause() {
    std::lock_guard lifecycleGuard(lifecycleMutex_);
    const int32_t previous = state_.load(std::memory_order_acquire);
    if (previous != LazerAudioStatePlaying) return LazerAudioOk;
    paused_.store(true, std::memory_order_release);
    underrunActive_.store(0, std::memory_order_release);
    std::string error;
    output_->stop(error);
    state_.store(LazerAudioStatePaused, std::memory_order_release);
    return LazerAudioOk;
}

int32_t Engine::stop() {
    std::lock_guard lifecycleGuard(lifecycleMutex_);
    if (state_.load(std::memory_order_acquire) == LazerAudioStateIdle) return LazerAudioOk;
    sessionGeneration_.fetch_add(1, std::memory_order_acq_rel);
    cancelled_.store(true, std::memory_order_release);
    paused_.store(true, std::memory_order_release);
    underrunActive_.store(0, std::memory_order_release);
    cancelCurrentSources();
    joinThreads();
    if (output_ != nullptr) output_->close();
    retireCurrentSources();
    {
        std::lock_guard sourceGuard(sourceMutex_);
        source_ = std::make_shared<SourceSlot>(this, config_.log);
    }
    bitPerfectActive_.store(false, std::memory_order_release);
    dopActive_.store(false, std::memory_order_release);
    nativeDsdActive_.store(false, std::memory_order_release);
    state_.store(LazerAudioStateStopped, std::memory_order_release);
    return LazerAudioOk;
}

int32_t Engine::seek(int64_t positionMillis) {
    if (state_.load(std::memory_order_acquire) == LazerAudioStateIdle) {
        return LazerAudioErrorState;
    }
    std::lock_guard sourceGuard(sourceMutex_);
    if (source_ == nullptr) return LazerAudioErrorState;
    if (pendingPresentationReady_.load(std::memory_order_acquire) &&
        pendingTrackChangedFrame_.load(std::memory_order_acquire) >= 0) {
        /* source_ is the decoder-active source. If it is B but the audible seam has not been
         * crossed, keep B's presentation event pending and rebase it after the seek flush. */
        pendingPresentationSeek_.store(true, std::memory_order_release);
    }
    /* Seeking invalidates the current starvation episode. Keep the session total cumulative. */
    underrunActive_.store(0, std::memory_order_release);
    const int64_t position = std::max<int64_t>(0, positionMillis);
    if (source_->prefetchStarted) source_->requestSeek(position);
    else {
        currentSource().requestSeek(position);
        seekFlushRequested_.store(true, std::memory_order_release);
    }
    return LazerAudioOk;
}

int32_t Engine::setVolume(double volume) {
    const double clamped = std::clamp(volume, 0.0, 1.0);
    if ((bitPerfectActive_.load(std::memory_order_acquire) ||
        dopActive_.load(std::memory_order_acquire) ||
        nativeDsdActive_.load(std::memory_order_acquire)) && clamped < 0.999999) {
        setError("software volume is unavailable while direct output is active; use the DAC volume",
            LazerAudioErrorUnsupported);
        return LazerAudioErrorUnsupported;
    }
    volume_.store(clamped, std::memory_order_release);
    volumeDirty_.store(true, std::memory_order_release);
    return LazerAudioOk;
}

int32_t Engine::setDsp(const LazerAudioDspConfig &dsp) {
    if (dsp.band_count > LAZER_AUDIO_MAX_EQ_BANDS) return LazerAudioErrorInvalidArgument;
    if ((dopActive_.load(std::memory_order_acquire) ||
        nativeDsdActive_.load(std::memory_order_acquire)) &&
        (dsp.preamp_db != 0.0 || dsp.band_count > 0 || dsp.limiter_enabled != 0)) {
        setError("EQ and limiter are unavailable while direct DSD output is active",
            LazerAudioErrorUnsupported);
        return LazerAudioErrorUnsupported;
    }
    dsp_.requestConfig(dsp);
    return LazerAudioOk;
}

int32_t Engine::setDevice(const LazerAudioDeviceConfig &device) {
    std::lock_guard guard(apiMutex_);
    if (device.dsd_output_mode != LazerAudioDsdOutputConvertToPcm &&
        device.dsd_output_mode != LazerAudioDsdOutputRequireDoP &&
        device.dsd_output_mode != LazerAudioDsdOutputRequireNative) {
        return LazerAudioErrorInvalidArgument;
    }
    const int32_t currentState = state_.load(std::memory_order_acquire);
    if (currentState != LazerAudioStateIdle && currentState != LazerAudioStateStopped &&
        currentState != LazerAudioStateFailed) return LazerAudioErrorState;
    device_ = device;
    deviceId_.clear();
    if (device.device_id != nullptr && device.device_id[0] != L'\0') {
        deviceId_ = device.device_id;
        device_.device_id = deviceId_.c_str();
    } else {
        device_.device_id = nullptr;
    }
    bitPerfectActive_.store(false, std::memory_order_release);
    dopActive_.store(false, std::memory_order_release);
    nativeDsdActive_.store(false, std::memory_order_release);
    if (device_.buffer_millis <= 0) device_.buffer_millis = 120;
    return LazerAudioOk;
}

void Engine::snapshot(LazerAudioSnapshot &out) {
    out.state = state_.load(std::memory_order_acquire);
    out.paused = paused_.load(std::memory_order_acquire) ? 1 : 0;
    std::lock_guard sourceGuard(sourceMutex_);
    if (source_ != nullptr) {
        const bool transitionPending = pendingTrackChangedFrame_.load(std::memory_order_acquire) >= 0;
        const StreamDescription &description = transitionPending
            ? presentationDescription_ : currentSource().description();
        out.position_millis = currentPositionMillisLocked();
        out.duration_millis = description.durationMillis;
        out.buffered_percent = transitionPending
            ? presentationBufferedPercent_
            : static_cast<int32_t>(currentSource().bufferedFraction() * 100.0);
    } else {
        out.position_millis = 0;
        out.duration_millis = 0;
        out.buffered_percent = 0;
    }
    out.error = lastErrorCode_.load(std::memory_order_acquire);
    out.underrun_active = underrunActive_.load(std::memory_order_acquire);
    out.underrun_frames = underrunFrames_.load(std::memory_order_acquire);
    const int32_t terminalEvent = terminalEvent_.load(std::memory_order_acquire);
    out.terminal_event = terminalEvent;
    out.terminal_detail = terminalEvent == -1
        ? 0 : terminalDetail_.load(std::memory_order_relaxed);
    out.terminal_position_millis = terminalEvent == -1
        ? 0 : terminalPositionMillis_.load(std::memory_order_relaxed);
}

void Engine::streamInfo(LazerAudioStreamInfo &out) {
    /* A callback can reenter this API while open/stop holds lifecycleMutex_. Never deadlock it;
     * return an unknown snapshot if the output lifecycle is changing. */
    std::unique_lock lifecycleGuard(lifecycleMutex_, std::try_to_lock);
    std::memset(&out, 0, sizeof(out));
    if (!lifecycleGuard.owns_lock()) return;

    std::lock_guard sourceGuard(sourceMutex_);
    if (source_ == nullptr) return;
    const bool transitionPending = pendingTrackChangedFrame_.load(std::memory_order_acquire) >= 0;
    const StreamDescription &description = transitionPending
        ? presentationDescription_ : currentSource().description();
    const size_t length = std::min(description.codec.size(), sizeof(out.codec) - 1);
    std::memcpy(out.codec, description.codec.data(), length);
    out.source_sample_rate = description.dsd ? 0 : description.sampleRate;
    out.source_channels = description.channels;
    out.source_bits_per_sample = description.dsd ? 0 : description.bitsPerSample;
    out.source_bitrate_kbps = description.bitrateKbps;
    out.lossless = description.lossless;
    out.source_format_kind = description.dsd
        ? LazerAudioSourceFormatDsd : LazerAudioSourceFormatPcm;
    out.source_dsd_rate_multiplier = description.dsdRateMultiplier;
    out.output_format_kind = LazerAudioOutputFormatPcm;
    out.output_peak_millidbfs = outputPeakMilliDbfs_.load(std::memory_order_acquire);
    out.limiter_gain_reduction_millidb = limiterGainReductionMilliDb_.load(std::memory_order_acquire);
    out.output_clipped_sample_count = outputClippedSampleCount_.load(std::memory_order_acquire);
    const int32_t currentState = state_.load(std::memory_order_acquire);
    if (output_ != nullptr && output_->isOpen() && currentState != LazerAudioStateFailed &&
        currentState != LazerAudioStateIdle && currentState != LazerAudioStatePreparing) {
        out.output_sample_rate = outputSession_.target.sampleRate;
        out.output_channels = outputSession_.target.channels;
        out.output_bits_per_sample = outputSession_.target.bitsPerSample == 0
            ? 32 : outputSession_.target.bitsPerSample;
        out.output_exclusive = outputSession_.exclusive ? 1 : 0;
        out.output_container_bits_per_sample = outputSession_.target.containerBitsPerSample > 0
            ? outputSession_.target.containerBitsPerSample : 32;
        out.output_is_float = outputSession_.target.bitsPerSample == 0 ? 1 : 0;
        out.output_format_initialized = 1;
        out.output_coreaudio_mixability_known = outputSession_.coreAudioMixabilityKnown ? 1 : 0;
        out.output_coreaudio_non_mixable = outputSession_.coreAudioStreamNonMixable ? 1 : 0;
        out.output_format_selection = outputSession_.formatSelection;
        out.output_telemetry_valid = outputTelemetryValid_.load(std::memory_order_acquire) &&
            !bitPerfectActive_.load(std::memory_order_acquire) &&
            !dopActive_.load(std::memory_order_acquire) &&
            !nativeDsdActive_.load(std::memory_order_acquire) ? 1 : 0;
        out.output_format_kind = outputSession_.nativeDsd
            ? LazerAudioOutputFormatNativeDsd
            : outputSession_.doP ? LazerAudioOutputFormatDoP : LazerAudioOutputFormatPcm;
        out.output_dsd_rate_multiplier = (outputSession_.doP || outputSession_.nativeDsd)
            ? description.dsdRateMultiplier : 0;
    }
    out.bit_perfect_active = bitPerfectActive_.load(std::memory_order_acquire) ? 1 : 0;
}

int64_t Engine::currentPositionMillis() const {
    std::lock_guard sourceGuard(sourceMutex_);
    return currentPositionMillisLocked();
}

int64_t Engine::currentPositionMillisLocked() const {
    const int32_t rate = outputSession_.target.sampleRate;
    if (source_ == nullptr) return 0;
    const bool transitionPending = pendingTrackChangedFrame_.load(std::memory_order_acquire) >= 0;
    const int64_t seekTarget = transitionPending
        ? presentationSeekTargetMillis_ : currentSource().seekTargetMillis();
    if (rate <= 0) return seekTarget;
    const int64_t rendered = renderedFrames_.load(std::memory_order_acquire);
    const int64_t trackStart = trackStartOutputFrame_.load(std::memory_order_acquire);
    return seekTarget + std::max<int64_t>(rendered - trackStart, 0) * 1000 / rate;
}

void Engine::raise(int32_t event, int32_t detail, int64_t positionMillis) {
    if (config_.events.on_event == nullptr) return;
    config_.events.on_event(config_.events.context, event, detail, positionMillis);
}

void Engine::publishTerminal(int32_t event, int32_t detail, int64_t positionMillis) {
    bool expected = false;
    if (!terminalClaimed_.compare_exchange_strong(expected, true,
        std::memory_order_acq_rel, std::memory_order_acquire)) return;

    /* Keep the event, detail, and frozen event position from the same winning failure. Publish
     * the terminal state only after the whole record is visible to snapshot readers. */
    terminalDetail_.store(detail, std::memory_order_relaxed);
    terminalPositionMillis_.store(positionMillis, std::memory_order_relaxed);
    terminalEvent_.store(event, std::memory_order_release);
    state_.store(event == LazerAudioEventEnded ? LazerAudioStateStopped : LazerAudioStateFailed,
        std::memory_order_release);
    raise(event, detail, positionMillis);
}

void Engine::setError(const std::string &text, int32_t code) {
    std::lock_guard guard(apiMutex_);
    setErrorLocked(text, code);
}

void Engine::setErrorLocked(const std::string &text, int32_t code) {
    lastError_ = text;
    lastErrorCode_.store(code, std::memory_order_release);
    log_.write(LazerAudioLogError, text);
}

bool Engine::shouldPump() const {
    /* The pump keeps feeding while the ring has room even when paused, which is what makes resume
     * instant; it parks only on a real pause with a full ring, handled by accept() returning 0. */
    return !cancelled_.load(std::memory_order_acquire);
}

bool Engine::isCancelled() const {
    return cancelled_.load(std::memory_order_acquire);
}

void Engine::onSeekApplied() {
    ring_.clearForProducer();
    if (nativeDsdActive_.load(std::memory_order_acquire)) nativeDsdPacker_.reset();
    resetTimelineForSeek();
    seekFlushRequested_.store(false, std::memory_order_release);
    underrunActive_.store(0, std::memory_order_release);
}

void Engine::resetTimelineForSeek() {
    writtenFrames_.store(0, std::memory_order_release);
    renderedFrames_.store(0, std::memory_order_release);
    acceptedFrames_.store(0, std::memory_order_release);
    trackStartOutputFrame_.store(0, std::memory_order_release);
    exclusiveInFlightAudioFrames_.store(0, std::memory_order_release);
    std::lock_guard sourceGuard(sourceMutex_);
    if (pendingPresentationSeek_.load(std::memory_order_acquire) &&
        pendingPresentationReady_.load(std::memory_order_acquire)) {
        /* Frame zero is before the first post-seek sample. Wait for one rendered B frame so the
         * callback remains tied to the first output packet that actually contains the successor. */
        pendingTrackChangedFrame_.store(1, std::memory_order_release);
    } else {
        pendingTrackChangedFrame_.store(-1, std::memory_order_release);
        pendingPresentationReady_.store(false, std::memory_order_release);
        pendingPresentationSeek_.store(false, std::memory_order_release);
    }
}

int32_t Engine::accept(const uint8_t *bytes, int32_t frameCount) {
    if (frameCount <= 0) return 0;
    if (nativeDsdActive_.load(std::memory_order_acquire)) {
        const size_t wordBytes = static_cast<size_t>(outputSession_.target.containerBitsPerSample / 8);
        const size_t outputFrameBytes = static_cast<size_t>(outputSession_.target.frameBytes());
        if (wordBytes == 0 || outputFrameBytes == 0 || bytes == nullptr) return 0;
        const size_t possibleFrames = (static_cast<size_t>(frameCount) + wordBytes) / wordBytes;
        const size_t scratchFrames = possibleFrames;
        if (nativeDsdScratch_.size() < scratchFrames * outputFrameBytes) {
            nativeDsdScratch_.resize(scratchFrames * outputFrameBytes);
        }
        const size_t outputCapacityFrames = std::min(scratchFrames,
            static_cast<size_t>(std::max(ring_.writableFrames(), 0)));
        const NativeDsdPackResult packed = nativeDsdPacker_.pack(bytes,
            static_cast<size_t>(frameCount), nativeDsdScratch_.data(), outputCapacityFrames);
        if (packed.producedOutputFrames > 0) {
            const int32_t written = ring_.write(nativeDsdScratch_.data(),
                static_cast<int32_t>(packed.producedOutputFrames));
            if (written > 0) acceptedFrames_.fetch_add(written, std::memory_order_release);
        }
        if (packed.status == NativeDsdPackStatus::InvalidChannelCount ||
            packed.status == NativeDsdPackStatus::InvalidWordBytes ||
            packed.status == NativeDsdPackStatus::InvalidArgument ||
            packed.status == NativeDsdPackStatus::SizeOverflow) {
            return 0;
        }
        return static_cast<int32_t>(packed.consumedInputFrames);
    }
    if (volumeDirty_.exchange(false, std::memory_order_acq_rel)) {
        dsp_.setVolume(volume_.load(std::memory_order_acquire),
            static_cast<int32_t>(volumeRampMillis_.load(std::memory_order_acquire)));
    }
    int32_t frames = std::min(frameCount, ring_.writableFrames());
    if (frames <= 0) return 0;
    if (dspBypassed_ || dopActive_.load(std::memory_order_acquire) ||
        nativeDsdActive_.load(std::memory_order_acquire)) {
        const int32_t written = ring_.write(bytes, frames);
        if (written > 0) acceptedFrames_.fetch_add(written, std::memory_order_release);
        return written;
    }

    const int32_t frameBytes = std::max(outputSession_.target.frameBytes(), 1);
    const size_t scratchFrames = convertScratch_.size() / static_cast<size_t>(frameBytes);
    frames = std::min(frames, static_cast<int32_t>(std::min(
        scratchFrames, static_cast<size_t>(frames))));
    if (frames <= 0) return 0;

    /* The block arrives as float32 at the device clock, so the DSP runs at the rate its filters were
     * designed for and the quantisation to the device depth happens on the way into the ring. */
    float *samples = const_cast<float *>(reinterpret_cast<const float *>(bytes));
    if (replayGainCurrentLinear_ != 1.0 || replayGainTargetLinear_ != 1.0) {
        const size_t channels = static_cast<size_t>(std::max(outputSession_.target.channels, 1));
        for (int32_t frame = 0; frame < frames; ++frame) {
            if (replayGainRampRemainingFrames_ > 0) {
                replayGainCurrentLinear_ += (replayGainTargetLinear_ - replayGainCurrentLinear_) /
                    static_cast<double>(replayGainRampRemainingFrames_);
                --replayGainRampRemainingFrames_;
                if (replayGainRampRemainingFrames_ == 0) {
                    replayGainCurrentLinear_ = replayGainTargetLinear_;
                }
            }
            float *frameSamples = samples + static_cast<size_t>(frame) * channels;
            for (size_t channel = 0; channel < channels; ++channel) {
                frameSamples[channel] = static_cast<float>(frameSamples[channel] * replayGainCurrentLinear_);
            }
        }
    }
    const double limiterReductionDb = dsp_.process(samples, static_cast<size_t>(frames));
    const size_t sampleCount = static_cast<size_t>(frames) *
        static_cast<size_t>(std::max(outputSession_.target.channels, 1));
    const int32_t peakMilliDbfs = samplePeakMilliDbfs(samples, sampleCount);
    const uint64_t clippedSamples = convertToOutput(samples, frames, convertScratch_.data());
    const int32_t written = ring_.write(convertScratch_.data(), frames);
    if (written > 0) {
        acceptedFrames_.fetch_add(written, std::memory_order_release);
        int32_t peakHold = outputPeakMilliDbfs_.load(std::memory_order_relaxed);
        while (peakHold < peakMilliDbfs && !outputPeakMilliDbfs_.compare_exchange_weak(
            peakHold, peakMilliDbfs, std::memory_order_release, std::memory_order_relaxed)) {}
        const double boundedReduction = std::clamp(limiterReductionDb, -180.0, 0.0);
        const int32_t reductionMilliDb = static_cast<int32_t>(std::llround(boundedReduction * 1000.0));
        int32_t reductionHold = limiterGainReductionMilliDb_.load(std::memory_order_relaxed);
        while (reductionHold > reductionMilliDb && !limiterGainReductionMilliDb_.compare_exchange_weak(
            reductionHold, reductionMilliDb, std::memory_order_release, std::memory_order_relaxed)) {}
        if (outputSession_.target.bitsPerSample != 0) {
            outputClippedSampleCount_.fetch_add(clippedSamples, std::memory_order_acq_rel);
        }
        outputTelemetryValid_.store(true, std::memory_order_release);
    }
    return written;
}

uint64_t Engine::convertToOutput(const float *source, int32_t frames, uint8_t *destination) {
    const size_t samples = static_cast<size_t>(frames) *
        static_cast<size_t>(std::max(outputSession_.target.channels, 1));
    if (outputSession_.target.bitsPerSample == 0) {
        std::memcpy(destination, source, samples * sizeof(float));
        return 0;
    }
    return convertIntegerPcm(source, samples, outputSession_.target.bitsPerSample,
        outputSession_.target.containerBitsPerSample, destination, ditherState_);
}

void Engine::pumpLoop() {
    const auto flushForSeek = [this] {
        if (!seekFlushRequested_.load(std::memory_order_acquire)) return;
        ring_.clearForProducer();
        if (nativeDsdActive_.load(std::memory_order_acquire)) nativeDsdPacker_.reset();
        resetTimelineForSeek();
        underrunActive_.store(0, std::memory_order_release);
        seekFlushRequested_.store(false, std::memory_order_release);
    };
    for (;;) {
        flushForSeek();
        std::shared_ptr<SourceSlot> active;
        {
            std::lock_guard sourceGuard(sourceMutex_);
            active = source_;
        }
        if (active == nullptr || cancelled_.load(std::memory_order_acquire)) break;

        int32_t result = LazerAudioOk;
        bool reachedEof = false;
        std::string sourceError;
        if (!active->prefetchStarted) {
            result = active->source.pump(*this);
            reachedEof = active->source.reachedEndOfStream();
            sourceError = active->source.lastError();
        } else {
            const int32_t frameBytes = nativeDsdActive_.load(std::memory_order_acquire)
                ? std::max(outputSession_.target.channels, 1)
                : std::max(outputSession_.target.frameBytes(), 1);
            const int32_t scratchFrames = static_cast<int32_t>(queuedPcmScratch_.size() /
                static_cast<size_t>(frameBytes));
            while (!cancelled_.load(std::memory_order_acquire)) {
                flushForSeek();
                int32_t queued = 0;
                int32_t accepted = 0;
                {
                    std::lock_guard consumerGuard(active->consumerMutex);
                    queued = active->pcm->peekFrames(queuedPcmScratch_.data(), scratchFrames);
                    if (queued > 0) {
                        accepted = accept(queuedPcmScratch_.data(), queued);
                        if (accepted > 0) active->pcm->consumeFrames(accepted);
                    }
                }
                if (accepted > 0) continue;
                if (cancelled_.load(std::memory_order_acquire)) break;
                if (queued == 0 && active->pcm->finished() &&
                    active->pcm->queuedFrames() == 0) {
                    result = active->pcm->result();
                    sourceError = active->pcm->error();
                    reachedEof = active->pcm->reachedEof();
                    break;
                }
                if (queued == 0) active->pcm->waitForDataOrFinish();
                else sleepIdle();
            }
        }
        log_.write(LazerAudioLogDebug,
            "source pump returned code=" + std::to_string(result) +
            " eof=" + std::to_string(reachedEof ? 1 : 0));
        if (cancelled_.load(std::memory_order_acquire)) break;
        if (result != LazerAudioOk || !reachedEof) {
            pumpFinished_.store(true, std::memory_order_release);
            const int32_t errorCode = result == LazerAudioOk ? LazerAudioErrorSource : result;
            if (sourceError.empty()) sourceError = "audio source stopped before clean EOF";
            setError(sourceError, errorCode);
            endedRaised_.store(true, std::memory_order_release);
            publishTerminal(LazerAudioEventFailed, errorCode, currentPositionMillis());
            return;
        }
        bool started = false;
        std::string queueError;
        const int32_t queuedResult = tryStartQueuedSource(started, queueError);
        if (queuedResult != LazerAudioOk) {
            pumpFinished_.store(true, std::memory_order_release);
            if (queueError.empty()) queueError = "queued audio source failed before clean EOF";
            setError(queueError, queuedResult);
            endedRaised_.store(true, std::memory_order_release);
            publishTerminal(LazerAudioEventFailed, queuedResult, currentPositionMillis());
            return;
        }
        if (!started) {
            if (nativeDsdActive_.load(std::memory_order_acquire)) {
                while (nativeDsdPacker_.hasPendingInput() &&
                    !cancelled_.load(std::memory_order_acquire)) {
                    if (ring_.writableFrames() == 0) {
                        sleepIdle();
                        continue;
                    }
                    const NativeDsdPackResult flushed = nativeDsdPacker_.flush(
                        nativeDsdScratch_.data(), 1);
                    if (flushed.status != NativeDsdPackStatus::Ok ||
                        flushed.producedOutputFrames != 1) {
                        pumpFinished_.store(true, std::memory_order_release);
                        const std::string error =
                            "the final Native DSD word could not be padded at session EOF";
                        setError(error, LazerAudioErrorDecode);
                        endedRaised_.store(true, std::memory_order_release);
                        publishTerminal(LazerAudioEventFailed, LazerAudioErrorDecode,
                            currentPositionMillis());
                        return;
                    }
                    const int32_t written = ring_.write(nativeDsdScratch_.data(), 1);
                    if (written != 1) {
                        pumpFinished_.store(true, std::memory_order_release);
                        const std::string error =
                            "the output ring rejected the final Native DSD word";
                        setError(error, LazerAudioErrorDevice);
                        endedRaised_.store(true, std::memory_order_release);
                        publishTerminal(LazerAudioEventFailed, LazerAudioErrorDevice,
                            currentPositionMillis());
                        return;
                    }
                    acceptedFrames_.fetch_add(1, std::memory_order_release);
                }
                if (cancelled_.load(std::memory_order_acquire)) break;
            }
            if (active->queueGeneration != 0 &&
                pendingPresentationReady_.load(std::memory_order_acquire)) {
                /* Keep the engine pump alive until the activated successor has crossed its
                 * presentation boundary. A seek can restart a fully prefetched short successor;
                 * returning EOF here would otherwise strand its newly decoded PCM. */
                while (!cancelled_.load(std::memory_order_acquire) &&
                    pendingPresentationReady_.load(std::memory_order_acquire)) {
                    flushForSeek();
                    if (active->pcm->queuedFrames() > 0 || !active->pcm->finished()) break;
                    if (pendingPresentationSeek_.load(std::memory_order_acquire) &&
                        active->pcm->reachedEof() &&
                        acceptedFrames_.load(std::memory_order_acquire) == 0 &&
                        ring_.readableFrames() == 0) {
                        /* A seek exactly to EOF has no first successor frame to publish. Let the
                         * session drain cleanly instead of waiting forever for an inaudible seam. */
                        std::lock_guard sourceGuard(sourceMutex_);
                        pendingTrackChangedFrame_.store(-1, std::memory_order_release);
                        pendingPresentationReady_.store(false, std::memory_order_release);
                        pendingPresentationSeek_.store(false, std::memory_order_release);
                        break;
                    }
                    sleepIdle();
                }
                if (cancelled_.load(std::memory_order_acquire)) break;
                if (pendingPresentationReady_.load(std::memory_order_acquire)) continue;
            }
            /* The stream ran out of packets. The render thread drains only once the whole session
             * reaches EOF, so a prepared successor can append frames to the same output ring. */
            pumpFinished_.store(true, std::memory_order_release);
            log_.write(LazerAudioLogDebug, "pump reached final end of stream");
            break;
        }
    }
}

void Engine::renderLoop() {
    std::string error;
    const int32_t threadSetup = output_->enterRenderThread(error);
    if (threadSetup != LazerAudioOk) {
        setError(error.empty() ? "the output backend could not initialise its render thread" : error,
            threadSetup);
        bitPerfectActive_.store(false, std::memory_order_release);
        publishTerminal(LazerAudioEventDeviceLost, threadSetup, currentPositionMillis());
        output_->leaveRenderThread();
        return;
    }

    const size_t blockFrames = std::max(kRenderBlockFrames,
        static_cast<size_t>(std::max(outputSession_.bufferFrames, 1)));
    std::vector<uint8_t> block(blockFrames *
        static_cast<size_t>(std::max(outputSession_.target.frameBytes(), 1)));
    uint64_t seenFlush = ring_.flushSequence();
    const auto waitForOutput = [this, &error]() {
        error.clear();
        const OutputWaitResult result = output_->waitForReady(kRenderWaitMillis, error);
        if (result == OutputWaitResult::Ready) return 1;
        if (result == OutputWaitResult::Timeout) return 0;
        setError(error.empty() ? "the output backend failed while waiting for a period" : error,
            LazerAudioErrorDevice);
        bitPerfectActive_.store(false, std::memory_order_release);
        publishTerminal(LazerAudioEventDeviceLost, 0, currentPositionMillis());
        return -1;
    };
    const auto publishTrackChanged = [this, &seenFlush]() {
        if (seekFlushRequested_.load(std::memory_order_acquire) ||
            ring_.flushSequence() != seenFlush) return;
        int64_t boundary = pendingTrackChangedFrame_.load(std::memory_order_acquire);
        if (boundary < 0 || !pendingPresentationReady_.load(std::memory_order_acquire) ||
            renderedFrames_.load(std::memory_order_acquire) < boundary) return;
        bool committed = false;
        {
            std::lock_guard sourceGuard(sourceMutex_);
            int64_t expected = boundary;
            if (!seekFlushRequested_.load(std::memory_order_acquire) &&
                ring_.flushSequence() == seenFlush &&
                pendingTrackChangedFrame_.compare_exchange_strong(
                    expected, -1, std::memory_order_acq_rel)) {
                presentationDescription_ = std::move(pendingPresentationDescription_);
                presentationSeekTargetMillis_ = pendingPresentationSeek_.load(
                    std::memory_order_acquire)
                    ? source_->source.seekTargetMillis()
                    : pendingPresentationSeekTargetMillis_;
                trackStartOutputFrame_.store(boundary, std::memory_order_release);
                pendingPresentationReady_.store(false, std::memory_order_release);
                pendingPresentationSeek_.store(false, std::memory_order_release);
                committed = true;
            }
        }
        if (committed) {
            /* Event callbacks may synchronously query the snapshot or stream info. */
            raise(LazerAudioEventTrackChanged, 0, currentPositionMillis());
        }
    };
    const auto activeDurationMillis = [this]() {
        std::lock_guard sourceGuard(sourceMutex_);
        return source_ == nullptr ? int64_t{0} : source_->source.description().durationMillis;
    };

    struct VariableOutputSpan {
        int64_t outputFrames;
        int64_t sourceFrames;
    };
    std::deque<VariableOutputSpan> variableOutputQueue;
    int64_t queueDepthAtLastObservation = 0;
    int64_t submissionsSinceQueueObservation = 0;
    int64_t renderedVariableSourceFrames = 0;
    bool variableQueueNeedsResync = true;
    const auto retireVariableOutputFrames = [&](int64_t retiredFrames) {
        while (retiredFrames > 0 && !variableOutputQueue.empty()) {
            VariableOutputSpan &span = variableOutputQueue.front();
            const int64_t retired = std::min(retiredFrames, span.outputFrames);
            const int64_t sourceRetired = std::min(retired, span.sourceFrames);
            renderedVariableSourceFrames += sourceRetired;
            span.outputFrames -= retired;
            span.sourceFrames -= sourceRetired;
            retiredFrames -= retired;
            if (span.outputFrames == 0) variableOutputQueue.pop_front();
        }
    };

    while (!cancelled_.load(std::memory_order_acquire)) {
        const uint64_t flush = ring_.flushSequence();
        if (flush != seenFlush) {
            /* A seek cleared the ring: the frames written before it no longer describe the position. */
            seenFlush = flush;
            /* The producer already reset session counters when it consumed seekFlushRequested_.
             * Reset only the render-side counters here; resetting acceptedFrames_ a second time
             * could hide a short post-seek tail from the producer's clean-EOF handling. */
            writtenFrames_.store(0, std::memory_order_release);
            renderedFrames_.store(0, std::memory_order_release);
            exclusiveInFlightAudioFrames_.store(0, std::memory_order_release);
            variableOutputQueue.clear();
            queueDepthAtLastObservation = 0;
            submissionsSinceQueueObservation = 0;
            renderedVariableSourceFrames = 0;
            variableQueueNeedsResync = true;
            /* A seek flush discards any underrun state associated with stale queued frames. */
            underrunActive_.store(0, std::memory_order_release);
        }

        if (paused_.load(std::memory_order_acquire)) {
            if (waitForOutput() < 0) break;
            sleepIdle();
            continue;
        }

        const bool fixedPeriod = outputSession_.writeMode == OutputWriteMode::FixedPeriod;
        if (fixedPeriod) {
            const int32_t waitResult = waitForOutput();
            if (waitResult <= 0) {
                if (waitResult < 0) break;
                continue;
            }
            const int32_t justPlayed = exclusiveInFlightAudioFrames_.exchange(
                0, std::memory_order_acq_rel);
            if (flush != seenFlush) {
                /* A seek invalidates queued source frames; discard their old position accounting. */
                seenFlush = flush;
                writtenFrames_.store(0, std::memory_order_release);
                renderedFrames_.store(0, std::memory_order_release);
            } else if (justPlayed > 0) {
                renderedFrames_.fetch_add(justPlayed, std::memory_order_release);
            }
            publishTrackChanged();
        }

        if (pumpFinished_.load(std::memory_order_acquire) && ring_.readableFrames() == 0) {
            /* A completed source's drain wait is not an underrun. */
            underrunActive_.store(0, std::memory_order_release);
            const OutputDrainResult drain = output_->drain(error);
            if (drain == OutputDrainResult::Error) {
                setError(error.empty() ? "the output backend failed while draining" : error,
                    LazerAudioErrorDevice);
                bitPerfectActive_.store(false, std::memory_order_release);
                publishTerminal(LazerAudioEventDeviceLost, 0, currentPositionMillis());
                break;
            }
            if (drain == OutputDrainResult::Drained) {
                if (!endedRaised_.exchange(true)) {
                    publishTerminal(LazerAudioEventEnded, 0, activeDurationMillis());
                }
                break;
            }
            if (waitForOutput() < 0) break;
            continue;
        }

        error.clear();
        const int32_t queuedBeforeWrite = outputSession_.queueDepthAvailable
            ? output_->queuedFrames(error) : 0;
        if (queuedBeforeWrite < 0) {
            setError(error.empty() ? "the output backend could not report its queued frames" : error,
                LazerAudioErrorDevice);
            publishTerminal(LazerAudioEventDeviceLost, 0, currentPositionMillis());
            break;
        }
        if (!fixedPeriod && outputSession_.queueDepthAvailable) {
            if (variableQueueNeedsResync) {
                /* A seek flush clears software accounting while an endpoint may still have old
                 * carrier frames queued. Retire those as non-source audio after the queue drains. */
                variableOutputQueue.clear();
                if (queuedBeforeWrite > 0) {
                    variableOutputQueue.push_back({queuedBeforeWrite, 0});
                }
                queueDepthAtLastObservation = queuedBeforeWrite;
                submissionsSinceQueueObservation = 0;
                variableQueueNeedsResync = false;
            } else {
                const int64_t submittedBeforeObservation = queueDepthAtLastObservation +
                    submissionsSinceQueueObservation;
                const int64_t retiredFrames = std::max<int64_t>(
                    submittedBeforeObservation - queuedBeforeWrite, 0);
                retireVariableOutputFrames(retiredFrames);
                queueDepthAtLastObservation = queuedBeforeWrite;
                submissionsSinceQueueObservation = 0;
                renderedFrames_.store(renderedVariableSourceFrames, std::memory_order_release);
                publishTrackChanged();
            }
        }
        error.clear();
        int32_t room = output_->writableFrames(error);
        if (room < 0) {
            setError(error.empty() ? "the output backend could not report writable frames" : error,
                LazerAudioErrorDevice);
            bitPerfectActive_.store(false, std::memory_order_release);
            publishTerminal(LazerAudioEventDeviceLost, 0, currentPositionMillis());
            break;
        }
        if (!fixedPeriod) room = std::min(room, static_cast<int32_t>(kRenderBlockFrames));
        if (room <= 0) {
            if (waitForOutput() < 0) break;
            continue;
        }

        /* At a queued boundary, never manufacture a short fixed-period packet or silence while the
         * successor decoder is still filling PCM. A sustained network underrun may stall the device
         * clock, but it cannot advance or corrupt the sample stream. */
        const int64_t boundary = pendingTrackChangedFrame_.load(std::memory_order_acquire);
        bool waitedForQueuedBoundary = false;
        if (boundary >= 0 && !pumpFinished_.load(std::memory_order_acquire)) {
            waitedForQueuedBoundary = true;
            underrunActive_.store(0, std::memory_order_release);
            const auto hasEnough = [&]() {
                const int32_t readable = ring_.readableFrames();
                return fixedPeriod
                    ? readable >= room || (readable > 0 && currentSourceEnded())
                    : readable > 0;
            };
            while (!cancelled_.load(std::memory_order_acquire) &&
                !pumpFinished_.load(std::memory_order_acquire) && !hasEnough()) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
            if (cancelled_.load(std::memory_order_acquire)) break;
            if (!pumpFinished_.load(std::memory_order_acquire) && !hasEnough()) continue;
        }

        const int32_t frameBytes = std::max(outputSession_.target.frameBytes(), 1);
        const int32_t frames = ring_.read(block.data(), room);
        if (frames == 0 && !pumpFinished_.load(std::memory_order_acquire) &&
            !waitedForQueuedBoundary && currentSourceEnded()) {
            /* A clean decoder EOF can race the pump's final session notification. Wait for that
             * notification rather than submitting a silent fixed period between queued tracks. */
            sleepIdle();
            continue;
        }
        int32_t framesToWrite = fixedPeriod || frames == 0 ? room : frames;
        if (outputSession_.doP) {
            /* The shared formatter applies endpoint period semantics and advances the marker clock
             * only across frames included in this write submission. */
            framesToWrite = lazer::audio::prepareDopCarrierFrames(block.data(), room, frames,
                outputSession_.target.channels, fixedPeriod, dopNextMarker_);
            if (framesToWrite < 0) {
                setError("the DoP carrier formatter rejected the output frame layout",
                    LazerAudioErrorDevice);
                publishTerminal(LazerAudioEventDeviceLost, 0, currentPositionMillis());
                break;
            }
        } else if (fixedPeriod && frames < room) {
            std::memset(block.data() + static_cast<size_t>(frames) * frameBytes,
                outputSession_.nativeDsd ? 0x69 : 0,
                static_cast<size_t>(room - frames) * frameBytes);
        }

        const bool sendingSilence = frames == 0;
        if (sendingSilence) {
            if (pumpFinished_.load(std::memory_order_acquire)) {
                const OutputDrainResult drain = output_->drain(error);
                if (drain == OutputDrainResult::Error) {
                    setError(error.empty() ? "the output backend failed while draining" : error,
                        LazerAudioErrorDevice);
                    bitPerfectActive_.store(false, std::memory_order_release);
                    publishTerminal(LazerAudioEventDeviceLost, 0, currentPositionMillis());
                    break;
                }
                if (drain == OutputDrainResult::Drained) {
                    if (!endedRaised_.exchange(true)) {
                        publishTerminal(LazerAudioEventEnded, 0, activeDurationMillis());
                    }
                    break;
                }
                if (waitForOutput() < 0) break;
                continue;
            }
            if (!outputSession_.doP) {
                std::memset(block.data(), outputSession_.nativeDsd ? 0x69 : 0,
                    static_cast<size_t>(room) * frameBytes);
            }
        }

        if (!outputSession_.doP) {
            framesToWrite = fixedPeriod || sendingSilence ? room : frames;
        }
        error.clear();
        const int32_t written = output_->write(block.data(), framesToWrite, error);
        if (written < 0 || (fixedPeriod && written != room) ||
            ((outputSession_.doP || outputSession_.nativeDsd) && written != framesToWrite)) {
            setError(error.empty() ? "the output backend rejected the submitted PCM frames" : error,
                written < 0 ? written : LazerAudioErrorDevice);
            publishTerminal(LazerAudioEventDeviceLost, 0, currentPositionMillis());
            break;
        }
        const int32_t submittedFrames = std::min(written, framesToWrite);
        const int32_t submittedSourceFrames = std::min(frames, submittedFrames);
        const int32_t paddedFrames = std::max(submittedFrames - submittedSourceFrames, 0);
        const bool currentSourceUnfinished = !pumpFinished_.load(std::memory_order_acquire) &&
            !currentSourceEnded();
        const bool countsAsUnderrun = paddedFrames > 0 && !waitedForQueuedBoundary &&
            !seekFlushRequested_.load(std::memory_order_acquire) &&
            ring_.flushSequence() == flush && currentSourceUnfinished;
        if (countsAsUnderrun) {
            underrunActive_.store(1, std::memory_order_release);
            underrunFrames_.fetch_add(static_cast<uint64_t>(paddedFrames),
                std::memory_order_acq_rel);
        } else {
            /* Full source data marks recovery; clean EOF padding and seek-flush output are ignored. */
            underrunActive_.store(0, std::memory_order_release);
        }
        if (fixedPeriod) {
            writtenFrames_.fetch_add(frames, std::memory_order_release);
            exclusiveInFlightAudioFrames_.store(frames, std::memory_order_release);
        } else if (written > 0) {
            writtenFrames_.fetch_add(written, std::memory_order_release);
            const int32_t sourceFrames = std::min(frames, written);
            if (outputSession_.queueDepthAvailable) {
                /* Keep an ordered audio/DoP-idle ledger. Total device queue depth includes idle
                 * carriers, but only source carriers should advance media position. */
                variableOutputQueue.push_back({written, sendingSilence ? 0 : sourceFrames});
                submissionsSinceQueueObservation += written;
            } else {
                /* Without a queue-depth API, preserve the old immediate-render assumption while
                 * excluding inserted idle carriers from source progress. */
                renderedVariableSourceFrames += sendingSilence ? 0 : sourceFrames;
                renderedFrames_.store(renderedVariableSourceFrames, std::memory_order_release);
            }
            publishTrackChanged();
        }
        if (sendingSilence && !fixedPeriod && waitForOutput() < 0) break;
    }

    output_->leaveRenderThread();
}

std::string Engine::buildInformation() {
    std::string text = "FFmpeg avformat ";
    text += AV_STRINGIFY(LIBAVFORMAT_VERSION);
    text += ", avcodec ";
    text += AV_STRINGIFY(LIBAVCODEC_VERSION);
    text += ", swresample ";
    text += AV_STRINGIFY(LIBSWRESAMPLE_VERSION);
    return text;
}

void Engine::resetDopMarker() noexcept {
    dopNextMarker_ = 0x05;
}

}  // namespace lazer::audio
