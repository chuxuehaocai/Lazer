#include "beat_grid.h"
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
/* How long the producer may stay parked at the high watermark before it tries again regardless. */
constexpr int32_t kProducerPauseLimitMillis = 50;

/* AutoMix transition contract, ported from the reference player's planner and mixer.
 *
 * The incoming song's silent intro is skipped: mixing it against the outgoing tail is dead air in
 * the middle of a transition. A frame counts as silence only when both its level and its peak are
 * below the thresholds, and only a run of at least `kSilenceIntroFrames` frames (160 ms) is treated
 * as an intro — a short dip is not. */
constexpr double kSilenceFrameDb = -65.0;
constexpr double kSilenceFramePeak = 0.00018;
constexpr int64_t kSilenceIntroFrames = 8;
constexpr double kSilenceScanSeconds = 3.0;
/* The low end trades between the decks instead of doubling: each deck's one-pole low band is
 * subtracted while the other one owns the bass. `kBassSwapMax` is the most of it that is taken. */
constexpr double kBassSwapCutoffHz = 180.0;
constexpr double kBassSwapMax = 0.85;
constexpr double kBassSwapScale = 0.75;
constexpr double kBassSwapClashScale = 3.0;
/* How much of a source is analysed for its beat grid. Several seconds carry enough beats for a
 * tempo, and the pump sees them on their way to the ring anyway. */
constexpr double kBeatGridCaptureSeconds = 6.0;
/* The musical range the reference player's natural mode keeps its overlap in; a beat-snapped
 * overlap is allowed half a beat of slack around it. */
constexpr double kOverlapMinSeconds = 4.0;
constexpr double kOverlapMaxSeconds = 8.0;
/* The reference player's exit echo: three taps one beat apart, each 0.28 of the previous, added
 * from the outgoing lane. Its planner falls back to the echo when neither its key test nor its
 * level test picks one of the other two exits, which is where the engine's planner ends up too. */
constexpr int32_t kEchoTaps = 3;
constexpr double kEchoGain = 0.28;
/* How long an exit may ring after the overlap ended, in beats. */
constexpr int32_t kEchoTailBeats = 3;
/* The reverb: three combs at incommensurate delays, so their repeats never line up into a rhythm,
 * with damped feedback so the tail darkens as it decays and rings on after the song is gone. */
constexpr int32_t kReverbCombs = 3;
constexpr double kReverbCombSeconds[kReverbCombs] = {0.0237, 0.0311, 0.0413};
constexpr double kReverbCombWeight = 0.7;
/* Feedback of 0.94 against the damping below is a couple of seconds of tail, which is what the
 * exit is for: the song is gone and the wash is still there. */
constexpr double kReverbFeedback = 0.94;
constexpr double kReverbDampCutoffHz = 3500.0;
/* The planner's two thresholds: a low-band clash under a third means the two songs are bright
 * enough that a reverb tail will not smear them into each other, and five decibels is the level
 * difference the reference filters on. */
constexpr double kReverbClashMax = 0.35;
constexpr double kFilterLevelDeltaDb = 5.0;
/* The exit filter sweeps from a passthrough to this cutoff across the overlap. */
constexpr double kFilterClosedHz = 220.0;
/* How long the outgoing deck's peak is held for the planner. The other side of the comparison is a
 * second of the incoming song's head, and a song's own beats are half a second apart at 120 BPM: a
 * shorter hold would read the gap between two of them as a quiet song. */
constexpr double kOutgoingPeakHoldSeconds = 4.0;

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
    explicit SourceSlot(Engine *engine, LazerAudioLogHandler)
        : owner(engine), source(&log) {
        log.install({
            [](void *context, int32_t level, const char *message) {
                static_cast<Engine *>(context)->log_.write(
                    static_cast<LazerAudioLogLevel>(level), message);
            },
            engine,
        }, false);
    }

    ~SourceSlot() {
        cancel();
        joinPrefetch();
        source.close();
    }

    void configurePrefetch(int32_t sampleRate, int32_t periodFrames, int32_t frameBytes,
        int32_t bufferedOverlapFrames = 0) {
        const size_t rate = static_cast<size_t>(std::max(sampleRate, 1));
        const size_t period = static_cast<size_t>(std::max(periodFrames, 1));
        const size_t overlap = static_cast<size_t>(std::max(bufferedOverlapFrames, 0));
        const size_t cushion = std::max(rate / 4, period * 2);
        const size_t capacity = std::max({rate, period * 4, overlap + cushion});
        const size_t watermark = std::min(capacity, overlap + cushion);
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

    void requestSeek(int64_t positionMillis, bool flushSession = false) {
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
            if (flushSession) {
                sessionSeekPending.store(true, std::memory_order_release);
            }
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
            bool flushSession = false;
            {
                std::lock_guard guard(consumerMutex);
                pcm->discardAll();
                flushSession = sessionSeekPending.exchange(false, std::memory_order_acq_rel);
            }
            if (flushSession && owner != nullptr) owner->onSeekApplied();
            return;
        }
        if (owner != nullptr) {
            owner->onSeekApplied();
        }
    }

    LogProxy log;
    LazerAudioReader reader{};
    Engine *owner = nullptr;
    AudioSource source;
    uint64_t queueGeneration = 0;
    double replayGainLinear = 1.0;
    /* Pump-owned source-clock accounting, including an incoming prefix already used in a mix. */
    int64_t producedOutputFrames = 0;
    std::atomic<int64_t> overlapFrames{0};
    std::atomic<bool> overlapStarted{false};
    std::atomic<bool> sessionSeekPending{false};
    int64_t overlapLengthFrames = 0;
    /* Tempo and beat phase of this source's own audio, estimated from the first seconds the pump
     * decodes it: the transition places the mix on this source's beats. */
    lazer_audio::BeatGrid grid;
    std::vector<float> gridCapture;
    int64_t gridCaptureFrames = 0;
    /* How far into the source the analysed head started: a grid measured from a peeked head is
     * anchored at the read position, not at the file's first sample. */
    int64_t gridOriginFrames = 0;
    bool gridAnalysed = false;
    /* The incoming song's silent intro, skipped at the start of the overlap. It is not mix progress
     * (which `overlapFrames` counts), but it is part of this source's own position. */
    int64_t skippedIntroFrames = 0;
    int64_t presentationOffsetFrames = 0;
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
        /* Clear the render thread's mirror too: it must not keep describing a retired source. */
        activePresentation_.publish(StreamDescription{}, 0);
        pendingPresentation_.publish(StreamDescription{}, 0);
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
    if (output_ != nullptr) output_->closeForReplacement();
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
    volumeRefreshPending_.store(false, std::memory_order_release);
    volumeRefreshSeekApplied_.store(false, std::memory_order_release);
    seekFlushReady_.store(false, std::memory_order_release);
    volumeRefreshGeneration_.store(0, std::memory_order_release);
    volumeRefreshAppliedGeneration_.store(0, std::memory_order_release);
    volumeImmediate_.store(false, std::memory_order_release);
    requestedSeekTargetMillis_.store(-1, std::memory_order_release);
    exclusiveInFlightAudioFrames_.store(0, std::memory_order_release);
    outputPeakMilliDbfs_.store(-120'000, std::memory_order_release);
    limiterGainReductionMilliDb_.store(0, std::memory_order_release);
    outputClippedSampleCount_.store(0, std::memory_order_release);
    outputTelemetryValid_.store(false, std::memory_order_release);
    underrunActive_.store(0, std::memory_order_release);
    underrunFrames_.store(0, std::memory_order_release);
    streamStarted_ = false;
    cancelledOverlapGain_.store(-1.0, std::memory_order_release);
    overlapRecoveryGain_ = 1.0;
    overlapRecoveryFrames_ = 0;
    autoMixOutgoingEnergy_ = 0.0;
    autoMixIncomingEnergy_ = 0.0;
    autoMixLevelFrames_ = 0;
    autoMixIncomingGain_ = 1.0;
    autoMixIncomingGainTarget_ = 1.0;
    autoMixLimiterGain_ = 1.0;
    autoMixBassAmount_ = 0.0;
    autoMixEchoActive_ = false;
    autoMixExit_ = AutoMixExit::Echo;
    autoMixEchoTailFrames_ = 0;
    autoMixEchoElapsedFrames_ = 0;
    autoMixEchoIndex_ = 0;
    autoMixEchoDelayFrames_ = 0;
    autoMixEchoCapacity_ = 0;
    autoMixEcho_.clear();
    autoMixReverbDelayFrames_.clear();
    autoMixReverbDamp_.clear();
    autoMixFilterState_.clear();
    autoMixOutgoingPeak_ = 0.0;
    autoMixOutgoingLow_.clear();
    autoMixIncomingLow_.clear();
    autoMixSilenceScratch_.clear();
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
        /* The opening source is audible immediately: publish it as the active presentation too. */
        activePresentation_.publish(presentationDescription_, presentationSeekTargetMillis_);
        pendingPresentation_.publish(presentationDescription_, presentationSeekTargetMillis_);
    }
    if (result != LazerAudioOk) {
        setErrorLocked(currentSource().lastError(), result);
        publishTerminal(LazerAudioEventFailed, result, 0);
        return result;
    }

    const bool autoMix = autoMixMillis_.load(std::memory_order_acquire) > 0;
    const bool requireDoP = !autoMix && doPOutputApplies(
        device_.dsd_output_mode, currentSource().description());
    const bool requireNativeDsd = !autoMix && nativeDsdOutputApplies(
        device_.dsd_output_mode, currentSource().description());
    if (safeParams.replay_gain_db != 0.0 &&
        ((!autoMix && device_.bit_perfect != 0) || requireDoP || requireNativeDsd)) {
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
    if (((!autoMix && device_.bit_perfect != 0) || requireDoP || requireNativeDsd) &&
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
    request.bitPerfect = !autoMix && device_.bit_perfect != 0;
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
    /* Every early return below leaves the previous session's answer behind otherwise. */
    formatMatchesSource_ = false;
    const bool autoMix = autoMixMillis_.load(std::memory_order_acquire) > 0;
    const bool requireDoP = !autoMix && doPOutputApplies(device_.dsd_output_mode, description);
    const bool requireNativeDsd = !autoMix && nativeDsdOutputApplies(device_.dsd_output_mode, description);
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
        autoMixMillis_.load(std::memory_order_acquire) == 0 &&
        device_.bit_perfect != 0 && !exactPcmFormat) {
        lastError_ = "bit-perfect output requires exact mono or stereo lossless integer PCM format";
        return LazerAudioErrorUnsupported;
    }
    if (!outputSession_.doP && !outputSession_.nativeDsd) {
        dspBypassed_ = autoMixMillis_.load(std::memory_order_acquire) == 0 &&
            device_.bit_perfect != 0 && outputSession_.exclusive && exactPcmFormat;
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
        const double initialVolume = volume_.load(std::memory_order_acquire);
        dsp_.configureFormat(outputSession_.engineFormat, initialVolume);
        dsp_.setVolume(initialVolume,
            static_cast<int32_t>(volumeRampMillis_.load(std::memory_order_acquire)));
    }

    const int32_t frameBytes = outputSession_.target.frameBytes();
    const int32_t wantedFrames = std::max(
        outputSession_.bufferFrames * 3,
        outputSession_.target.sampleRate * std::max(device_.buffer_millis, 60) / 1000);
    ring_.reset(wantedFrames, frameBytes);
    /* Hysteresis marks for the producer: it stops at the high mark and resumes at the low one. A
     * quarter/three-quarters split, widened to at least two render blocks when the ring is short so
     * a tiny buffer still has a band to work in instead of toggling every block. */
    {
        const int32_t capacity = ring_.capacityFrames();
        const int32_t minimumBand = static_cast<int32_t>(kRenderBlockFrames) * 2;
        /* Stop at the capacity — the same reach the pipeline always had, so a consumer that parks
         * still lets the decoder finish the outgoing track — and resume only once a quarter of the
         * ring has drained. Resuming the moment a single frame frees up is what keeps the producer
         * awake through a whole period; waiting for the low mark gives the render thread a real
         * cushion after a starvation instead of one block. */
        int32_t highMark = capacity;
        int32_t lowMark = capacity / 4;
        if (capacity <= 0) {
            lowMark = 0;
            highMark = 0;
        } else if (highMark - lowMark < minimumBand) {
            highMark = std::min(capacity, minimumBand);
            lowMark = std::max(0, highMark - minimumBand);
        }
        ringLowWatermarkFrames_.store(lowMark, std::memory_order_relaxed);
        ringHighWatermarkFrames_.store(highMark, std::memory_order_relaxed);
        producerPausedForRing_ = false;
    }
    convertScratch_.assign(static_cast<size_t>(wantedFrames) * frameBytes, 0);
    autoMixScratch_.assign(static_cast<size_t>(wantedFrames) *
        static_cast<size_t>(std::max(target.channels, 1)), 0.0f);
    /* Enough of the incoming source's head for one peek: its silent intro, and a beat grid when the
     * pump has not analysed that source itself (the prefetch buffer holds at least the overlap). */
    autoMixSilenceScratch_.assign(
        static_cast<size_t>(kBeatGridCaptureSeconds * std::max(target.sampleRate, 1)) *
        static_cast<size_t>(std::max(target.channels, 1)), 0.0f);
    const size_t queuedScratchFrames = std::max(kRenderBlockFrames,
        static_cast<size_t>(std::max(outputSession_.bufferFrames, 1)));
    if (outputSession_.nativeDsd) {
        const size_t rawFrameBytes = static_cast<size_t>(std::max(target.channels, 1));
        const size_t wordBytes = static_cast<size_t>(target.containerBitsPerSample / 8);
        queuedPcmScratch_.assign(queuedScratchFrames * wordBytes * rawFrameBytes, 0);
        nativeDsdScratch_.assign(queuedScratchFrames * frameBytes, 0);
    } else {
        const int32_t stagedFrameBytes = dspBypassed_ || outputSession_.doP
            ? frameBytes : floatTarget_.frameBytes();
        queuedPcmScratch_.assign(queuedScratchFrames *
            static_cast<size_t>(std::max(stagedFrameBytes, 1)), 0);
        nativeDsdScratch_.clear();
    }
    replayGainCurrentLinear_ = source_->replayGainLinear;
    replayGainTargetLinear_ = source_->replayGainLinear;
    replayGainRampRemainingFrames_ = 0;
    /* Bit-perfect has a second definition for DSD. A DoP session carries the decoded DSD bitstream
     * unchanged inside a 24-bit carrier, and a Native DSD session inside the endpoint's own DSD word
     * format; either way `configurePipeline` above already refused to open any session whose carrier
     * does not match the source exactly (rate, channels, depth, exclusivity). So reaching this point
     * with a DoP/Native DSD session *is* the carrier contract holding — `output_format_matches_source`
     * means "the DSD stream is carried exactly", not "the PCM triple is identical". The DSP is out of
     * the path on both (`dspInPath()` returns false), and `setDsp` refuses processing requests while
     * they are active, so the three conditions on the PCM rule hold by construction. */
    const bool dsdCarrierExact = outputSession_.doP || outputSession_.nativeDsd;
    formatMatchesSource_ = dsdCarrierExact ? true : exactPcmFormat;
    bitPerfectActive_.store(dsdCarrierExact ? outputSession_.exclusive : dspBypassed_,
        std::memory_order_release);
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
        dsdOutputMode = autoMixMillis_.load(std::memory_order_acquire) > 0
            ? LazerAudioDsdOutputConvertToPcm : device_.dsd_output_mode;
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
        if (autoMixMillis_.load(std::memory_order_acquire) == 0 &&
            preparedDescription.sampleRate != activeDescription.sampleRate) {
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
        const int32_t overlapFrames = static_cast<int32_t>(
            static_cast<int64_t>(autoMixMillis_.load(std::memory_order_acquire)) * target.sampleRate / 1000);
        prepared->configurePrefetch(target.sampleRate, outputSession_.bufferFrames,
            target.frameBytes(), overlapFrames);
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
            if (nextSource_->overlapStarted.load(std::memory_order_acquire)) {
                const double progress = std::clamp(
                    static_cast<double>(nextSource_->overlapFrames.load(std::memory_order_acquire)) /
                    static_cast<double>(std::max<int64_t>(nextSource_->overlapLengthFrames - 1, 1)),
                    0.0, 1.0);
                cancelledOverlapGain_.store(std::cos(progress * 1.57079632679489661923),
                    std::memory_order_release);
            }
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
        /* A pump may still retain the slot while abandoning a boundary wait. Close installed
         * readers synchronously before returning: their caller is now free to release context. */
        if (retired->prefetchStarted) retired->source.close();
    }
    retired.reset();
    if (result == LazerAudioQueueAlreadyActive) {
        /* Publication of the new slot precedes destruction of the old one so reader callbacks
         * never run under sourceMutex_. Its caller may free that old context after AlreadyActive. */
        std::unique_lock retirementGuard(sourceRetirementMutex_);
        sourceRetirementChanged_.wait(retirementGuard, [this] {
            return !sourceRetirementPending_.load(std::memory_order_acquire);
        });
    }
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
    bool ready = false;
    if (candidate->pcm != nullptr) {
        if (candidate->overlapStarted.load(std::memory_order_acquire)) {
            /* The initial watermark includes the entire overlap. Those frames have already been
             * rendered with A; requiring that watermark again would pause at EOF to refill it. */
            candidate->pcm->waitForDataOrFinish();
            ready = !candidate->pcm->isCancelled() && candidate->pcm->queuedFrames() > 0;
        } else {
            ready = candidate->pcm->waitUntilReady();
        }
    }
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
        presentationSeekTargetMillis_ = source_->source.seekTargetMillis() +
            source_->presentationOffsetFrames * 1000 / outputSession_.target.sampleRate;
        presentationBufferedPercent_ = static_cast<int32_t>(
            source_->source.bufferedFraction() * 100.0);
        retired = std::move(source_);
        sourceRetirementPending_.store(true, std::memory_order_release);
        source_ = std::move(nextSource_);
        source_->presentationOffsetFrames = source_->overlapFrames.load(std::memory_order_acquire) +
            source_->skippedIntroFrames;
        source_->producedOutputFrames = source_->presentationOffsetFrames;
        replayGainTargetLinear_ = source_->replayGainLinear;
        if (source_->presentationOffsetFrames > 0 ||
            std::abs(replayGainTargetLinear_ - replayGainCurrentLinear_) < 1.0e-12) {
            replayGainCurrentLinear_ = replayGainTargetLinear_;
            replayGainRampRemainingFrames_ = 0;
        } else {
            replayGainRampRemainingFrames_ = std::max<int64_t>(
                1, static_cast<int64_t>(outputSession_.target.sampleRate) * 5 / 1000);
        }
        pendingPresentationDescription_ = source_->source.description();
        pendingPresentationSeekTargetMillis_ = source_->source.seekTargetMillis() +
            source_->presentationOffsetFrames * 1000 / outputSession_.target.sampleRate;
        /* Mirror for the render thread, which commits it at the audible seam without a lock. */
        pendingPresentation_.publish(source_->source.description(),
            pendingPresentationSeekTargetMillis_);
        pendingPresentationSeek_.store(false, std::memory_order_release);
        boundaryFrame = acceptedFrames_.load(std::memory_order_acquire);
        if (nativeDsdActive_.load(std::memory_order_acquire) &&
            nativeDsdPacker_.hasPendingInput()) {
            ++boundaryFrame;
        }
        pendingTrackChangedFrame_.store(boundaryFrame, std::memory_order_release);
    }
    /* pumpLoop still owns an outgoing-slot reference until this call returns. Close it explicitly;
     * waiting for the final shared_ptr destructor would let TrackChanged outlive its reader. */
    retired->cancel();
    retired->joinPrefetch();
    retired->source.close();
    retired.reset();
    {
        std::lock_guard retirementGuard(sourceRetirementMutex_);
        sourceRetirementPending_.store(false, std::memory_order_release);
    }
    sourceRetirementChanged_.notify_all();
    /* An event permits the caller to release the outgoing reader too, so the render-side seam
     * must remain unpublished until its close callback has completed. */
    pendingPresentationReady_.store(true, std::memory_order_release);
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
    /* A gain change while Ready asks the producer to discard its old-gain prebuffer and decode
     * again from the current position. Wait without holding lifecycleMutex_; the fixed ceiling also
     * bounds calls arriving through the serialized worker while a source seek is slow. */
    constexpr auto kSeekFlushTimeout = std::chrono::seconds(5);
    const auto seekFlushDeadline = std::chrono::steady_clock::now() + kSeekFlushTimeout;
    std::unique_lock lifecycleGuard(lifecycleMutex_, std::defer_lock);
    for (;;) {
        while (volumeRefreshPending_.load(std::memory_order_acquire) &&
            !cancelled_.load(std::memory_order_acquire)) {
            const int32_t waitingState = state_.load(std::memory_order_acquire);
            if (waitingState == LazerAudioStateFailed || waitingState == LazerAudioStateStopped ||
                waitingState == LazerAudioStateIdle) {
                const int32_t error = lastErrorCode_.load(std::memory_order_acquire);
                return error == LazerAudioOk ? LazerAudioErrorState : error;
            }
            if (std::chrono::steady_clock::now() >= seekFlushDeadline) {
                lifecycleGuard.lock();
                if (cancelled_.load(std::memory_order_acquire)) {
                    lifecycleGuard.unlock();
                    return LazerAudioErrorCancelled;
                }
                if (!volumeRefreshPending_.load(std::memory_order_acquire)) {
                    lifecycleGuard.unlock();
                    continue;
                }
                const int32_t timeoutState = state_.load(std::memory_order_acquire);
                if (timeoutState == LazerAudioStateFailed || timeoutState == LazerAudioStateStopped ||
                    timeoutState == LazerAudioStateIdle) {
                    const int32_t error = lastErrorCode_.load(std::memory_order_acquire);
                    lifecycleGuard.unlock();
                    return error == LazerAudioOk ? LazerAudioErrorState : error;
                }
                setError("the initial audio buffer did not refresh before playback",
                    LazerAudioErrorSource);
                publishTerminal(LazerAudioEventFailed, LazerAudioErrorSource,
                    currentPositionMillis());
                return LazerAudioErrorSource;
            }
            if (pumpFinished_.load(std::memory_order_acquire)) {
                /* Short sources may finish decoding before the caller changes volume. A completed
                 * producer can still honor the refresh by seeking and pumping the source again. */
                lifecycleGuard.lock();
                const int32_t restartState = state_.load(std::memory_order_acquire);
                if (restartState == LazerAudioStateFailed || restartState == LazerAudioStateStopped ||
                    restartState == LazerAudioStateIdle) {
                    const int32_t error = lastErrorCode_.load(std::memory_order_acquire);
                    lifecycleGuard.unlock();
                    return error == LazerAudioOk ? LazerAudioErrorState : error;
                }
                if (volumeRefreshPending_.load(std::memory_order_acquire) &&
                    pumpFinished_.load(std::memory_order_acquire)) {
                    if (pumpThread_.joinable()) pumpThread_.join();
                    if (cancelled_.load(std::memory_order_acquire)) {
                        lifecycleGuard.unlock();
                        return LazerAudioErrorCancelled;
                    }
                    pumpFinished_.store(false, std::memory_order_release);
                    try {
                        pumpThread_ = std::thread([this] { pumpLoop(); });
                    } catch (...) {
                        pumpFinished_.store(true, std::memory_order_release);
                        lifecycleGuard.unlock();
                        setError("could not restart the audio producer for the gain refresh",
                            LazerAudioErrorNoMemory);
                        publishTerminal(LazerAudioEventFailed, LazerAudioErrorNoMemory,
                            currentPositionMillis());
                        return LazerAudioErrorNoMemory;
                    }
                }
                lifecycleGuard.unlock();
            }
            sleepIdle();
        }
        if (cancelled_.load(std::memory_order_acquire)) return LazerAudioErrorCancelled;
        lifecycleGuard.lock();
        if (!volumeRefreshPending_.load(std::memory_order_acquire)) break;
        lifecycleGuard.unlock();
    }

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
    formatMatchesSource_ = false;
    dopActive_.store(false, std::memory_order_release);
    nativeDsdActive_.store(false, std::memory_order_release);
    state_.store(LazerAudioStateStopped, std::memory_order_release);
    return LazerAudioOk;
}

int32_t Engine::seek(int64_t positionMillis) {
    std::lock_guard lifecycleGuard(lifecycleMutex_);
    std::lock_guard refreshGuard(volumeRefreshMutex_);
    if (volumeRefreshPending_.load(std::memory_order_acquire)) {
        volumeRefreshSeekApplied_.store(false, std::memory_order_release);
        volumeRefreshAppliedGeneration_.store(0, std::memory_order_release);
    }
    return seekLocked(positionMillis);
}

int32_t Engine::seekLocked(int64_t positionMillis) {
    if (state_.load(std::memory_order_acquire) == LazerAudioStateIdle) {
        return LazerAudioErrorState;
    }
    std::shared_ptr<SourceSlot> active;
    std::shared_ptr<SourceSlot> incoming;
    {
        std::lock_guard sourceGuard(sourceMutex_);
        active = source_;
        if (active == nullptr) return LazerAudioErrorState;
        if (nextSource_ != nullptr && nextSource_->overlapStarted.load(std::memory_order_acquire)) {
            incoming = nextSource_;
        }
        if (pendingPresentationReady_.load(std::memory_order_acquire) &&
            pendingTrackChangedFrame_.load(std::memory_order_acquire) >= 0) {
            /* source_ is the decoder-active source. If it is B but the audible seam has not been
             * crossed, keep B's presentation event pending and rebase it after the seek flush. */
            pendingPresentationSeek_.store(true, std::memory_order_release);
        }
    }
    /* Seeking invalidates the current starvation episode. Keep the session total cumulative. */
    underrunActive_.store(0, std::memory_order_release);
    const int64_t position = std::max<int64_t>(0, positionMillis);
    requestedSeekTargetMillis_.store(position, std::memory_order_release);
    seekFlushReady_.store(false, std::memory_order_release);
    seekFlushRequested_.store(true, std::memory_order_release);
    /* Never hold sourceMutex_ while waiting for a consumer: the queued pump owns its consumer
     * mutex while accept() publishes source metadata. Keep the slot alive with shared ownership. */
    if (incoming != nullptr) {
        incoming->requestSeek(incoming->source.seekTargetMillis());
        std::lock_guard consumerGuard(incoming->consumerMutex);
        incoming->overlapFrames.store(0, std::memory_order_release);
        incoming->skippedIntroFrames = 0;
        incoming->overlapStarted.store(false, std::memory_order_release);
        incoming->overlapLengthFrames = 0;
    }
    if (active->prefetchStarted) active->requestSeek(position, true);
    else active->source.requestSeek(position);
    return LazerAudioOk;
}

int32_t Engine::setVolume(double volume) {
    std::lock_guard lifecycleGuard(lifecycleMutex_);
    const double clamped = std::clamp(volume, 0.0, 1.0);
    if ((bitPerfectActive_.load(std::memory_order_acquire) ||
        dopActive_.load(std::memory_order_acquire) ||
        nativeDsdActive_.load(std::memory_order_acquire)) && clamped < 0.999999) {
        setError("software volume is unavailable while direct output is active; use the DAC volume",
            LazerAudioErrorUnsupported);
        return LazerAudioErrorUnsupported;
    }
    const int32_t currentState = state_.load(std::memory_order_acquire);
    const bool beforeFirstOutput = currentState == LazerAudioStateReady &&
        renderedFrames_.load(std::memory_order_acquire) == 0;
    std::unique_lock refreshGuard(volumeRefreshMutex_, std::defer_lock);
    if (beforeFirstOutput) refreshGuard.lock();
    const double previous = volume_.exchange(clamped, std::memory_order_acq_rel);
    if (beforeFirstOutput && clamped != previous) {
        volumeRefreshGeneration_.fetch_add(1, std::memory_order_acq_rel);
        volumeRefreshAppliedGeneration_.store(0, std::memory_order_release);
        volumeRefreshSeekApplied_.store(false, std::memory_order_release);
        volumeRefreshPending_.store(true, std::memory_order_release);
        volumeImmediate_.store(true, std::memory_order_release);
    }
    volumeDirty_.store(true, std::memory_order_release);
    if (beforeFirstOutput && clamped != previous) {
        int64_t refreshPosition = requestedSeekTargetMillis_.load(std::memory_order_acquire);
        if (refreshPosition < 0) {
            std::lock_guard sourceGuard(sourceMutex_);
            refreshPosition = source_ == nullptr ? 0 : source_->source.seekTargetMillis();
        }
        const int32_t result = seekLocked(refreshPosition);
        if (result != LazerAudioOk) {
            volume_.store(previous, std::memory_order_release);
            volumeRefreshPending_.store(false, std::memory_order_release);
            volumeRefreshSeekApplied_.store(false, std::memory_order_release);
            volumeRefreshAppliedGeneration_.store(0, std::memory_order_release);
            volumeImmediate_.store(false, std::memory_order_release);
            seekFlushRequested_.store(false, std::memory_order_release);
            seekFlushReady_.store(false, std::memory_order_release);
            volumeDirty_.store(true, std::memory_order_release);
            return result;
        }
    }
    return LazerAudioOk;
}

int32_t Engine::setAutoMix(int32_t durationMillis) {
    if (durationMillis < 0 || durationMillis > 30'000) return LazerAudioErrorInvalidArgument;
    autoMixMillis_.store(durationMillis, std::memory_order_release);
    return LazerAudioOk;
}

int32_t Engine::setDsp(const LazerAudioDspConfig &dsp) {
    if (dsp.band_count > LAZER_AUDIO_MAX_EQ_BANDS) return LazerAudioErrorInvalidArgument;
    /* A module that would alter the samples. Bypassed stages (a disabled band, a limiter that is
     * off) do not count: sending them is how the settings layer keeps its state in one piece. */
    const bool wantsProcessing = dsp.preamp_db != 0.0 || dsp.band_count > 0 ||
        dsp.limiter_enabled != 0 || dsp.crossfeed_enabled != 0;
    if (wantsProcessing && (dopActive_.load(std::memory_order_acquire) ||
            nativeDsdActive_.load(std::memory_order_acquire))) {
        setError("EQ and limiter are unavailable while direct DSD output is active",
            LazerAudioErrorUnsupported);
        return LazerAudioErrorUnsupported;
    }
    /* A bit-perfect session routes the decoded samples straight to the device, so a processing
     * request cannot be honoured. Saying so beats accepting the request and silently dropping it:
     * the caller would otherwise believe the EQ is applied while the state reports no DSP. */
    if (wantsProcessing && bitPerfectActive_.load(std::memory_order_acquire)) {
        setError("EQ, limiter and crossfeed are unavailable while bit-perfect output is active; "
            "turn bit-perfect off first", LazerAudioErrorUnsupported);
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
    formatMatchesSource_ = false;
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
        out.position_millis = currentPositionMillisLocked();
        /* During a transition the audible track is the one the render thread committed at the seam,
         * so its duration comes from the same atomics the render thread published — not from
         * `presentationDescription_`, whose codec-string commit the producer may not have applied
         * yet. A synchronous `snapshot()` from the TrackChanged callback must report the successor. */
        out.duration_millis = transitionPending
            ? activePresentation_.durationMillis.load(std::memory_order_acquire)
            : currentSource().description().durationMillis;
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
    /* Both cursors are atomics, so this is a lock-free read from the polling thread and the one
     * number that separates "the decoder cannot keep up" from "the device is being starved". */
    out.ring_fill_frames = ring_.readableFrames();
    out.ring_capacity_frames = ring_.capacityFrames();
    out.ring_low_watermark_frames = ringLowWatermarkFrames_.load(std::memory_order_relaxed);
    out.ring_high_watermark_frames = ringHighWatermarkFrames_.load(std::memory_order_relaxed);
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
    /* The scalars the render thread may query synchronously (from a TrackChanged callback) come from
     * the commit it made at the seam; only the codec string is left for the producer to publish,
     * because it is the one field that is not a plain atomic. */
    const bool dsd = transitionPending
        ? activePresentation_.dsd.load(std::memory_order_acquire) != 0
        : description.dsd;
    out.source_sample_rate = dsd
        ? 0
        : (transitionPending
            ? activePresentation_.sampleRate.load(std::memory_order_acquire)
            : description.sampleRate);
    out.source_channels = transitionPending
        ? activePresentation_.channels.load(std::memory_order_acquire) : description.channels;
    out.source_bits_per_sample = dsd
        ? 0
        : (transitionPending
            ? activePresentation_.bitsPerSample.load(std::memory_order_acquire)
            : description.bitsPerSample);
    out.source_bitrate_kbps = transitionPending
        ? activePresentation_.bitrateKbps.load(std::memory_order_acquire) : description.bitrateKbps;
    out.lossless = transitionPending
        ? activePresentation_.lossless.load(std::memory_order_acquire) : (description.lossless ? 1 : 0);
    out.source_format_kind = dsd
        ? LazerAudioSourceFormatDsd : LazerAudioSourceFormatPcm;
    out.source_dsd_rate_multiplier = transitionPending
        ? activePresentation_.dsdRateMultiplier.load(std::memory_order_acquire)
        : description.dsdRateMultiplier;
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
        /* The three facts behind `bit_perfect_active`, published so a caller can check the claim
         * rather than trust it. They live inside this block on purpose: once the session is gone
         * (failed, idle, preparing) there is no exclusive output, no format and no DSP path left to
         * describe, and a reader deriving bit-perfect from the three must come out false. Keeping
         * them here is what makes the derived answer agree with `bit_perfect_active`. */
        out.output_dsp_active = dspInPath() ? 1 : 0;
        out.output_format_matches_source = formatMatchesSource_ ? 1 : 0;
    }
    out.bit_perfect_active = bitPerfectActive_.load(std::memory_order_acquire) ? 1 : 0;
}

bool Engine::dspInPath() const {
    /* The float DSP/volume chain only processes the samples when the pipeline chose the processed
     * branch: the direct-integer path, DoP and Native DSD all route around it. */
    if (dspBypassed_) return false;
    if (dopActive_.load(std::memory_order_acquire)) return false;
    if (nativeDsdActive_.load(std::memory_order_acquire)) return false;
    return true;
}

int64_t Engine::currentPositionMillis() const {
    std::lock_guard sourceGuard(sourceMutex_);
    return currentPositionMillisLocked();
}

int64_t Engine::renderPositionMillis() const noexcept {
    /* The render thread's own position: same arithmetic as `currentPositionMillisLocked`, but every
     * input is an atomic it can read without sourceMutex_. The seek target comes from the published
     * presentation because the render thread must never reach into `source_`. */
    const int32_t rate = outputSession_.target.sampleRate;
    const int64_t seekTarget = activePresentation_.seekTargetMillis.load(std::memory_order_acquire);
    if (rate <= 0) return seekTarget;
    const int64_t rendered = renderedFrames_.load(std::memory_order_acquire);
    const int64_t trackStart = trackStartOutputFrame_.load(std::memory_order_acquire);
    return seekTarget + std::max<int64_t>(rendered - trackStart, 0) * 1000 / rate;
}

void Engine::applyPendingPresentationCommit() {
    const uint64_t requested = presentationCommitRequested_.load(std::memory_order_acquire);
    if (requested == presentationCommitApplied_.load(std::memory_order_acquire)) return;
    /* The render thread already published the audible scalars; this moves the full description
     * (codec string included) for the UI-facing readers. Producer thread, so taking the lock is
     * fine — it is never held by the render thread. */
    std::lock_guard sourceGuard(sourceMutex_);
    presentationDescription_ = pendingPresentationDescription_;
    presentationCommitApplied_.store(requested, std::memory_order_release);
}

int64_t Engine::currentPositionMillisLocked() const {
    const int32_t rate = outputSession_.target.sampleRate;
    if (source_ == nullptr) return 0;
    const bool transitionPending = pendingTrackChangedFrame_.load(std::memory_order_acquire) >= 0;
    const int64_t seekTarget = transitionPending
        ? presentationSeekTargetMillis_ : currentSource().seekTargetMillis() +
            (rate > 0 ? source_->presentationOffsetFrames * 1000 / rate : 0);
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
    std::lock_guard refreshGuard(volumeRefreshMutex_);
    if (seekFlushRequested_.load(std::memory_order_acquire)) {
        seekFlushReady_.store(true, std::memory_order_release);
    }
}

void Engine::flushSeekOnPumpThread() {
    if (!seekFlushRequested_.load(std::memory_order_acquire) ||
        !seekFlushReady_.load(std::memory_order_acquire)) return;
    std::unique_lock refreshGuard(volumeRefreshMutex_);
    if (!seekFlushRequested_.load(std::memory_order_acquire) ||
        !seekFlushReady_.load(std::memory_order_acquire)) return;
    bool anotherSeekPending = false;
    {
        std::lock_guard sourceGuard(sourceMutex_);
        anotherSeekPending = source_ != nullptr && source_->source.hasPendingSeek();
    }
    if (anotherSeekPending) {
        seekFlushReady_.store(false, std::memory_order_release);
        return;
    }
    /* Whether this flush answers a seek the caller asked for. The initial CUE positioning seek of a
     * queued source applies the same way but nobody is waiting for it, so it is not announced. */
    const bool volumeRefresh = volumeRefreshPending_.load(std::memory_order_acquire);
    const bool requested = !volumeRefresh &&
        requestedSeekTargetMillis_.load(std::memory_order_acquire) >= 0;
    seekFlushReady_.store(false, std::memory_order_release);
    seekFlushRequested_.store(false, std::memory_order_release);
    ring_.clearForProducer();
    if (nativeDsdActive_.load(std::memory_order_acquire)) nativeDsdPacker_.reset();
    resetTimelineForSeek();
    underrunActive_.store(0, std::memory_order_release);
    if (volumeRefresh) {
        if (anotherSeekPending) {
            volumeRefreshAppliedGeneration_.store(0, std::memory_order_release);
            volumeRefreshSeekApplied_.store(false, std::memory_order_release);
        } else {
            volumeRefreshAppliedGeneration_.store(
                volumeRefreshGeneration_.load(std::memory_order_acquire), std::memory_order_release);
            volumeRefreshSeekApplied_.store(true, std::memory_order_release);
        }
    }
    if (!requested) return;
    /* Everything the decoder produced before the target is gone, so the clock now reads the target.
     * This is the confirmation the caller holds its published position for: `LazerAudioEventSeekCompleted`
     * is in the ABI for exactly this, and without it the app can only wait out its own hold ceiling,
     * which is what left the progress bar standing still after a seek. */
    refreshGuard.unlock();
    raise(LazerAudioEventSeekCompleted, 0, currentPositionMillis());
}

void Engine::resetTimelineForSeek() {
    writtenFrames_.store(0, std::memory_order_release);
    renderedFrames_.store(0, std::memory_order_release);
    acceptedFrames_.store(0, std::memory_order_release);
    trackStartOutputFrame_.store(0, std::memory_order_release);
    exclusiveInFlightAudioFrames_.store(0, std::memory_order_release);
    std::lock_guard sourceGuard(sourceMutex_);
    if (source_ != nullptr) {
        source_->producedOutputFrames = 0;
        source_->presentationOffsetFrames = 0;
    }
    const int64_t requestedSeek = requestedSeekTargetMillis_.exchange(-1, std::memory_order_acq_rel);
    if (requestedSeek >= 0) {
        if (pendingPresentationReady_.load(std::memory_order_acquire)) {
            pendingPresentationSeekTargetMillis_ = requestedSeek;
            pendingPresentation_.seekTargetMillis.store(requestedSeek, std::memory_order_release);
        } else {
            activePresentation_.seekTargetMillis.store(requestedSeek, std::memory_order_release);
        }
    }
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

double Engine::measureBassClash(
    const float *outgoing, int32_t outgoingFrames, SourceSlot &candidate, int32_t sampleRate,
    size_t channels, double *incomingPeak) {
    if (outgoing == nullptr || outgoingFrames <= 0 || sampleRate <= 0 || channels == 0) return 0.0;
    const double lowAlpha = 1.0 - std::exp(
        -2.0 * 3.14159265358979323846 * kBassSwapCutoffHz / static_cast<double>(sampleRate));
    double outgoingTotal = 0.0;
    double outgoingLow = 0.0;
    for (int32_t frame = 0; frame < outgoingFrames; ++frame) {
        for (size_t channel = 0; channel < channels; ++channel) {
            const double value = outgoing[static_cast<size_t>(frame) * channels + channel];
            outgoingTotal += value * value;
            double &state = autoMixOutgoingLow_[channel];
            state += lowAlpha * (value - state);
            outgoingLow += state * state;
        }
    }
    double incomingTotal = 0.0;
    double incomingLow = 0.0;
    double incomingHeadPeak = 0.0;
    /* A second of head, not a quarter: the planner's level reading has to hold a beat, or a gap
     * between two of them reads as a silent song. */
    const int64_t headFrames = std::min<int64_t>(
        std::max<int64_t>(static_cast<int64_t>(sampleRate), 1),
        std::max<int64_t>(candidate.pcm != nullptr ? candidate.pcm->queuedFrames() : 0, 0));
    const int64_t capacityFrames = static_cast<int64_t>(autoMixSilenceScratch_.size() / channels);
    const int32_t peekFrames = static_cast<int32_t>(std::min<int64_t>(headFrames, capacityFrames));
    if (candidate.pcm != nullptr && peekFrames > 0) {
        const int32_t peeked = candidate.pcm->peekFrames(
            reinterpret_cast<uint8_t *>(autoMixSilenceScratch_.data()), peekFrames);
        for (int32_t frame = 0; frame < peeked; ++frame) {
            for (size_t channel = 0; channel < channels; ++channel) {
                const double value = autoMixSilenceScratch_[
                    static_cast<size_t>(frame) * channels + channel];
                incomingTotal += value * value;
                incomingHeadPeak = std::max(incomingHeadPeak, std::abs(value));
                double &state = autoMixIncomingLow_[channel];
                state += lowAlpha * (value - state);
                incomingLow += state * state;
            }
        }
    }
    const double outgoingFraction =
        outgoingTotal > 0.0 ? outgoingLow / outgoingTotal : 0.0;
    const double incomingFraction =
        incomingTotal > 0.0 ? incomingLow / incomingTotal : 0.0;
    const double clash = std::min(1.0, std::sqrt(std::max(outgoingFraction, 0.0) *
        std::max(incomingFraction, 0.0)) * kBassSwapClashScale);
    if (incomingPeak != nullptr) *incomingPeak = incomingHeadPeak;
    return std::clamp(kBassSwapScale * clash, 0.0, kBassSwapMax);
}

AutoMixExit Engine::planExitEffect(double levelDeltaDb, double bassClash) {
    /* The reference's DJ planner picks a beat repeat for the fastest, most confident grids, a
     * reverb for two songs in the same key, a filter for two songs whose levels differ, and an
     * echo otherwise. The engine has no key analysis, so the key test runs on the closest fact it
     * does measure: a low-band clash means the two songs already fight where a reverb tail would
     * smear them into each other, which is when the tail is the wrong exit. Its repeat is not
     * ported: there is nothing to repeat with.
     *
     * The order is the reference's: the reverb is decided first, then the filter, then the echo. */
    if (bassClash <= kReverbClashMax) return AutoMixExit::Reverb;
    if (levelDeltaDb > kFilterLevelDeltaDb) return AutoMixExit::Filter;
    return AutoMixExit::Echo;
}

double Engine::mixExitEffect(double input, size_t channel) {
    if (autoMixEchoCapacity_ <= 0) return 0.0;
    const size_t offset = channel * static_cast<size_t>(autoMixEchoCapacity_);
    const size_t write = static_cast<size_t>(autoMixEchoIndex_);
    if (autoMixExit_ == AutoMixExit::Reverb &&
        autoMixReverbDelayFrames_.size() == static_cast<size_t>(kReverbCombs) &&
        channel < autoMixReverbDamp_.size()) {
        /* Three combs read out of the one line at incommensurate delays, their sum damped and fed
         * back in: the line's own content is what makes the tail a wash rather than a pattern. */
        double sum = 0.0;
        double weight = 1.0;
        double total = 0.0;
        for (int32_t comb = 0; comb < kReverbCombs; ++comb) {
            const int64_t delay = autoMixReverbDelayFrames_[static_cast<size_t>(comb)];
            if (delay <= 0 || delay >= autoMixEchoCapacity_) continue;
            int64_t read = autoMixEchoIndex_ - delay;
            if (read < 0) read += autoMixEchoCapacity_;
            sum += weight * autoMixEcho_[offset + static_cast<size_t>(read)];
            total += weight;
            weight *= kReverbCombWeight;
        }
        const double wet = total > 0.0 ? sum / total : 0.0;
        double &damp = autoMixReverbDamp_[channel];
        damp += autoMixReverbDampCoef_ * (wet - damp);
        autoMixEcho_[offset + write] = input + kReverbFeedback * damp;
        return wet;
    }
    /* The echo: the outgoing lane written into the line unchanged, and the reference's taps read
     * back out of it. The reference adds them from the unmodified lane, so they do not fade with
     * the crossfade and the song can ring out over the incoming one. */
    autoMixEcho_[offset + write] = input;
    double wet = 0.0;
    double tapGain = kEchoGain;
    for (int32_t tap = 1; tap <= kEchoTaps; ++tap) {
        const int64_t delay = autoMixEchoDelayFrames_ * tap;
        if (delay > 0 && delay < autoMixEchoCapacity_) {
            int64_t read = autoMixEchoIndex_ - delay;
            if (read < 0) read += autoMixEchoCapacity_;
            wet += tapGain * autoMixEcho_[offset + static_cast<size_t>(read)];
        }
        tapGain *= kEchoGain;
    }
    if (autoMixEchoDelayFrames_ > 0) {
        /* Wet over the first beat, so the first readable tap arrives as a tail, not as a step. */
        wet *= std::min(1.0, static_cast<double>(autoMixEchoElapsedFrames_) /
            static_cast<double>(autoMixEchoDelayFrames_));
    }
    return wet;
}

void Engine::captureBeatGridLocked(const float *samples, int32_t frames, size_t channels) {
    if (source_ == nullptr || samples == nullptr || frames <= 0 || channels == 0) return;
    const int32_t rate = outputSession_.target.sampleRate;
    if (rate <= 0) return;
    SourceSlot &slot = *source_;
    if (slot.gridAnalysed) return;
    const int64_t windowFrames = static_cast<int64_t>(kBeatGridCaptureSeconds * rate);
    const int64_t remaining = windowFrames - slot.gridCaptureFrames;
    if (remaining <= 0) return;
    const int32_t take = static_cast<int32_t>(std::min<int64_t>(remaining, frames));
    const size_t sampleCount = static_cast<size_t>(take) * channels;
    if (slot.gridCapture.empty()) {
        slot.gridCapture.reserve(static_cast<size_t>(windowFrames) * channels);
    }
    slot.gridCapture.insert(slot.gridCapture.end(), samples, samples + sampleCount);
    slot.gridCaptureFrames += take;
    if (slot.gridCaptureFrames >= windowFrames) {
        slot.grid = lazer_audio::estimateBeatGrid(slot.gridCapture.data(), slot.gridCaptureFrames, rate,
            static_cast<int32_t>(channels));
        slot.gridAnalysed = true;
        /* The buffer has done its job: the grid is a handful of numbers from here on. */
        slot.gridCapture.clear();
        slot.gridCapture.shrink_to_fit();
    }
}

int64_t Engine::snapOverlapToBeat(
    const SourceSlot &slot, int64_t desiredFrames, int64_t mixStartOutputFrames) {
    const lazer_audio::BeatGrid &grid = slot.grid;
    const int64_t beat = grid.beatFrames();
    if (!grid.valid || beat <= 0 || desiredFrames <= 1) return desiredFrames;
    /* The mix ends where the source ends, so its start is what moves: onto the nearest line of the
     * source's own beat grid, which is the frame count the pump produced from the start. */
    const int64_t snapped = grid.nextBeatAtOrAfter(mixStartOutputFrames - beat / 2);
    /* `snapped` is the beat line the start moves onto, so the overlap's *length* changes by that
     * same amount: the mix still ends where the source ends, only its start moved. Returning the
     * distance instead of the length is what made this a no-op — a value bounded by half a beat can
     * never fall inside the 4-8 s window the guard below checks it against. */
    const int64_t snappedFrames = desiredFrames + (mixStartOutputFrames - snapped);
    if (snappedFrames <= 1) return desiredFrames;
    const int32_t rate = outputSession_.target.sampleRate > 0 ? outputSession_.target.sampleRate : 1;
    const double seconds = static_cast<double>(snappedFrames) / rate;
    const double slack = static_cast<double>(beat) / rate;
    if (seconds < kOverlapMinSeconds - slack || seconds > kOverlapMaxSeconds + slack) {
        return desiredFrames;
    }
    return snappedFrames;
}

int64_t Engine::beatPhaseSkipFrames(const SourceSlot &incoming, int64_t consumedFrames,
    const SourceSlot &outgoing, int64_t mixStartOutputFrames) {
    const int64_t beatIn = incoming.grid.beatFrames();
    if (!incoming.grid.valid || beatIn <= 0) return 0;
    const int64_t beatOut = outgoing.grid.beatFrames();
    /* The outgoing song is the reference: its period is what the incoming song's beats are lined up
     * with, and the shift never has to be longer than one of them. */
    const int64_t period =
        outgoing.grid.valid && beatOut > 0 ? beatOut : beatIn;
    int64_t phaseOut = 0;
    if (outgoing.grid.valid && beatOut > 0) {
        /* How far the mix starts past the outgoing song's last beat line. Both anchors are measured
         * against their own grid: a grid's zero is wherever its analysis found the first beat. */
        phaseOut =
            ((mixStartOutputFrames - outgoing.grid.firstBeatFrame) % beatOut + beatOut) % beatOut;
    }
    /* Consuming `shift` more frames makes the incoming song's next beat line land exactly where the
     * outgoing song's next one is. The incoming grid's own frame zero sits at its origin, so the
     * frames already consumed since then come off the shift. */
    const int64_t anchor = incoming.grid.firstBeatFrame + incoming.gridOriginFrames;
    const int64_t shift =
        ((anchor - consumedFrames + phaseOut) % period + period) % period;
    return shift;
}

int64_t Engine::consumeIncomingSilence(SourceSlot &candidate, int32_t sampleRate, size_t channels) {
    if (candidate.pcm == nullptr || sampleRate <= 0 || channels == 0) return 0;
    const int64_t frameFrames = std::max<int64_t>(sampleRate / 50, 1);
    const int64_t wantedFrames = std::min<int64_t>(
        static_cast<int64_t>(kSilenceScanSeconds * sampleRate),
        std::max<int64_t>(candidate.pcm->queuedFrames(), 0));
    if (wantedFrames < frameFrames * kSilenceIntroFrames) return 0;
    const int64_t capacityFrames = static_cast<int64_t>(
        autoMixSilenceScratch_.size() / channels);
    const int32_t peekFrames = static_cast<int32_t>(
        std::min<int64_t>(wantedFrames, capacityFrames));
    if (peekFrames <= 0) return 0;
    const int32_t peeked = candidate.pcm->peekFrames(
        reinterpret_cast<uint8_t *>(autoMixSilenceScratch_.data()), peekFrames);
    if (peeked < frameFrames * kSilenceIntroFrames) return 0;
    int64_t silentFrames = 0;
    for (int64_t offset = 0; offset + frameFrames <= peeked; offset += frameFrames) {
        double energy = 0.0;
        double peak = 0.0;
        for (int64_t frame = 0; frame < frameFrames; ++frame) {
            for (size_t channel = 0; channel < channels; ++channel) {
                const double value = autoMixSilenceScratch_[
                    static_cast<size_t>(offset + frame) * channels + channel];
                energy += value * value;
                peak = std::max(peak, std::abs(value));
            }
        }
        const double rms = std::sqrt(energy / static_cast<double>(frameFrames * channels));
        const double db = rms > 0.0 ? 20.0 * std::log10(rms) : -200.0;
        if (db > kSilenceFrameDb || peak > kSilenceFramePeak) break;
        silentFrames += frameFrames;
    }
    if (silentFrames < frameFrames * kSilenceIntroFrames) return 0;
    candidate.pcm->consumeFrames(silentFrames);
    return silentFrames;
}

int32_t Engine::accept(const uint8_t *bytes, int32_t frameCount) {
    if (frameCount <= 0) return 0;
    /* Seek callbacks can arrive on the queued decoder thread. The active pump owns all writes and
     * clears of the output ring, so it applies the flush at this block boundary. */
    flushSeekOnPumpThread();
    /* Producer-side upkeep, done once per accepted block: apply a codec-string commit the render
     * thread asked for at a frame seam, and republish the end-of-stream flag the render thread reads
     * instead of locking. Both are cheap atomic operations on data the pump thread already owns. */
    applyPendingPresentationCommit();
    sourceEndedMirror_.store(currentSourceEnded(), std::memory_order_release);
    /* Ring hysteresis. The render thread works out of a cushion: feeding past the high watermark
     * only pins the ring full (every late decode block then becomes audible immediately), while
     * dropping below the low one is what actually risks a gap. So the producer stops at the high
     * mark and resumes at the low mark rather than tracking the fill frame by frame.
     *
     * A pending track boundary suspends the pause: the render thread is then holding the last
     * period of the outgoing track until the ring reaches it, and throttling the producer in that
     * window is how a seam turns into a stall. */
    const int32_t fill = ring_.readableFrames();
    const int32_t highMark = ringHighWatermarkFrames_.load(std::memory_order_relaxed);
    const int32_t lowMark = ringLowWatermarkFrames_.load(std::memory_order_relaxed);
    /* A seam in flight keeps the producer running: the pump parks in its own wait loop until the
     * render thread crosses that boundary, and the render thread needs ring frames to get there, so
     * throttling the producer in that window is a deadlock rather than a cushion. */
    const bool seamInFlight =
        pendingTrackChangedFrame_.load(std::memory_order_acquire) >= 0 ||
        pendingPresentationReady_.load(std::memory_order_acquire);
    if (producerPausedForRing_) {
        /* Resume when the ring drains to the low mark — that is the hysteresis — but never stay
         * latched: a consumer that has parked (a stalled endpoint, a paused device) must not be able
         * to stop the decoder from finishing the outgoing track, which is exactly what the gapless
         * path needs it to do. */
        const bool drained = !seamInFlight && fill > lowMark;
        const bool latchedTooLong = std::chrono::steady_clock::now() - producerPausedSince_ >
            std::chrono::milliseconds(kProducerPauseLimitMillis);
        if (drained && !latchedTooLong) return 0;
        producerPausedForRing_ = false;
    } else if (highMark > 0 && !seamInFlight && fill >= highMark) {
        producerPausedForRing_ = true;
        producerPausedSince_ = std::chrono::steady_clock::now();
        return 0;
    }
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
        const double volume = volume_.load(std::memory_order_acquire);
        if (volumeImmediate_.exchange(false, std::memory_order_acq_rel)) {
            dsp_.setVolumeImmediately(volume);
        } else {
            dsp_.setVolume(volume,
                static_cast<int32_t>(volumeRampMillis_.load(std::memory_order_acquire)));
        }
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
    bool mixing = false;
    double incomingReplayGain = 1.0;
    int64_t mixedStartFrame = 0;
    int64_t mixedLengthFrames = 0;
    {
        std::lock_guard sourceGuard(sourceMutex_);
        const int32_t rate = outputSession_.target.sampleRate;
        const int32_t channels = outputSession_.target.channels;
        const int32_t duration = autoMixMillis_.load(std::memory_order_acquire);
        auto candidate = nextSource_;
        if (source_ != nullptr && candidate != nullptr && candidate->pcm != nullptr &&
            rate > 0 && channels > 0 &&
            (duration > 0 || candidate->overlapStarted.load(std::memory_order_acquire))) {
            const int64_t exactTotal = source_->source.totalOutputFrames();
            const int64_t totalFrames = exactTotal > 0 ? exactTotal :
                source_->source.description().durationMillis * rate / 1000;
            const int64_t positionFrames = source_->source.seekTargetMillis() * rate / 1000 +
                source_->producedOutputFrames;
            const int64_t remainingFrames = totalFrames - positionFrames;
            const int64_t exactIncoming = candidate->source.totalOutputFrames();
            const int64_t incomingFrames = exactIncoming > 0 ? exactIncoming :
                candidate->source.description().durationMillis * rate / 1000;
            int64_t desiredFrames = std::min({
                static_cast<int64_t>(duration) * rate / 1000, totalFrames / 2, incomingFrames / 2});
            /* Put the mix's start on a beat of the outgoing song: that is where a listener hears
             * the transition happen, and it is what lines the incoming song's beats up with it. */
            if (source_->grid.valid) {
                const int64_t mixStart = source_->producedOutputFrames + remainingFrames - desiredFrames;
                desiredFrames = snapOverlapToBeat(*source_, desiredFrames, mixStart);
            }
            const bool started = candidate->overlapStarted.load(std::memory_order_acquire);
            if (!started && desiredFrames > 1 && remainingFrames > desiredFrames &&
                remainingFrames - desiredFrames < frames) {
                /* Split exactly at the overlap's first frame instead of stepping the gain once
                 * per decoder block. The next accept starts with outgoing=1, incoming=0. */
                frames = static_cast<int32_t>(remainingFrames - desiredFrames);
            } else if (started || (desiredFrames > 1 && remainingFrames > 1 &&
                    remainingFrames <= desiredFrames)) {
                std::lock_guard consumerGuard(candidate->consumerMutex);
                const bool ready = started || candidate->pcm->queuedFrames() >=
                    candidate->pcm->readyWatermarkFrames() || candidate->pcm->finished();
                if (ready && !candidate->cancelled.load(std::memory_order_acquire)) {
                    const int32_t available = candidate->pcm->peekFrames(
                        reinterpret_cast<uint8_t *>(autoMixScratch_.data()), frames);
                    if (available == 0 && started && !candidate->pcm->finished()) return 0;
                    if (available > 0) {
                        frames = available;
                        if (!started) {
                            /* A slow successor can join late. Shorten the overlap to the actual
                             * remaining tail, preserving full outgoing gain until B is ready. */
                            candidate->overlapLengthFrames = std::min(desiredFrames, remainingFrames);
                            candidate->overlapStarted.store(true, std::memory_order_release);
                            /* A new overlap measures its own levels and starts unlimited. */
                            autoMixOutgoingEnergy_ = 0.0;
                            autoMixIncomingEnergy_ = 0.0;
                            autoMixLevelFrames_ = 0;
                            autoMixIncomingGain_ = 1.0;
                            autoMixIncomingGainTarget_ = 1.0;
                            autoMixLimiterGain_ = 1.0;
                            autoMixBassAmount_ = 0.0;
                            autoMixOutgoingLow_.assign(static_cast<size_t>(channels), 0.0);
                            autoMixIncomingLow_.assign(static_cast<size_t>(channels), 0.0);
                            /* Start on music: the incoming song's silent intro is dead air in the
                             * middle of the transition, so it is consumed before the first mixed
                             * frame and counted in the successor's own position. */
                            int64_t skipped = consumeIncomingSilence(
                                *candidate, rate, static_cast<size_t>(channels));
                            /* The incoming song's tempo and beat phase, if the pump has not already
                             * measured this source (a successor is prepared, never played, so it has
                             * no grid of its own yet). */
                            if (!candidate->gridAnalysed && !candidate->grid.valid) {
                                const int64_t headFrames = std::min<int64_t>(
                                    std::max<int64_t>(candidate->pcm->queuedFrames(), 0),
                                    static_cast<int64_t>(kBeatGridCaptureSeconds * rate));
                                const int32_t peekFrames = static_cast<int32_t>(std::min<int64_t>(
                                    headFrames,
                                    static_cast<int64_t>(autoMixSilenceScratch_.size() / channels)));
                                if (peekFrames > 0) {
                                    const int32_t peeked = candidate->pcm->peekFrames(
                                        reinterpret_cast<uint8_t *>(autoMixSilenceScratch_.data()),
                                        peekFrames);
                                    if (peeked > 0) {
                                        candidate->grid = lazer_audio::estimateBeatGrid(
                                            autoMixSilenceScratch_.data(), peeked, rate,
                                            static_cast<int32_t>(channels));
                                        candidate->gridOriginFrames = skipped;
                                    }
                                }
                                candidate->gridAnalysed = true;
                            }
                            /* Line the incoming song's beat phase up with the beat the outgoing song
                             * is on, by starting it later within its own bar. Without this the two
                             * grids can sit half a beat apart for the whole overlap. */
                            if (source_->grid.valid && candidate->grid.valid && skipped >= 0) {
                                const int64_t mixStartOutput = source_->producedOutputFrames +
                                    (remainingFrames - candidate->overlapLengthFrames);
                                const int64_t phaseSkip = beatPhaseSkipFrames(
                                    *candidate, skipped, *source_, mixStartOutput);
                                if (phaseSkip > 0) {
                                    const int64_t available = std::max<int64_t>(
                                        candidate->pcm->queuedFrames(), 0);
                                    const int32_t consume = static_cast<int32_t>(
                                        std::min<int64_t>(phaseSkip, available));
                                    if (consume > 0) {
                                        candidate->pcm->consumeFrames(consume);
                                        skipped += consume;
                                    }
                                }
                            }
                            if (skipped > 0) {
                                candidate->skippedIntroFrames = skipped;
                                const int32_t refilled = candidate->pcm->peekFrames(
                                    reinterpret_cast<uint8_t *>(autoMixScratch_.data()), frames);
                                if (refilled <= 0) return 0;
                                frames = refilled;
                            }
                            /* Whether the two songs clash in the bass is decided before the first
                             * mixed frame: the outgoing side from this block, the incoming side from
                             * the head of its prefetch buffer. Measuring it later would hand the low
                             * end over in one direction only whenever the overlap is short. */
                            double incomingPeak = 0.0;
                            autoMixBassAmount_ = measureBassClash(
                                autoMixScratch_.data(), frames, *candidate, rate,
                                static_cast<size_t>(channels), &incomingPeak);
                            /* The exit the outgoing song takes, chosen from the two facts the
                             * engine measures: how much the two low bands clash and how far
                             * apart the two songs sit in level. The taps are one beat of the
                             * outgoing song apart, so the effect needs a beat: the reference
                             * player only chooses one in its DJ mode, which needs boundary
                             * beats too. */
                            const int64_t exitBeat = source_->grid.beatFrames();
                            autoMixEchoActive_ = source_->grid.valid && exitBeat > 0;
                            autoMixEchoTailFrames_ = 0;
                            autoMixEchoElapsedFrames_ = 0;
                            autoMixEchoIndex_ = 0;
                            if (autoMixEchoActive_) {
                                /* A peak with a floor, so silence on one side is a level difference
                                 * rather than a ratio of zero. */
                                const double outgoingDb = 20.0 *
                                    std::log10(std::max(autoMixOutgoingPeak_, 1.0e-6));
                                const double incomingDb =
                                    20.0 * std::log10(std::max(incomingPeak, 1.0e-6));
                                autoMixExit_ = planExitEffect(
                                    std::abs(outgoingDb - incomingDb), autoMixBassAmount_);
                                autoMixEchoDelayFrames_ = exitBeat;
                                autoMixEchoCapacity_ =
                                    exitBeat * kEchoTaps + std::max<int32_t>(rate, 1);
                                autoMixEcho_.assign(
                                    static_cast<size_t>(autoMixEchoCapacity_) *
                                        static_cast<size_t>(channels), 0.0);
                                autoMixReverbDelayFrames_.assign(kReverbCombs, 0);
                                for (int32_t comb = 0; comb < kReverbCombs; ++comb) {
                                    autoMixReverbDelayFrames_[static_cast<size_t>(comb)] =
                                        std::max<int64_t>(1, static_cast<int64_t>(
                                            kReverbCombSeconds[comb] * rate));
                                }
                                autoMixReverbDamp_.assign(static_cast<size_t>(channels), 0.0);
                                autoMixReverbDampCoef_ = 1.0 - std::exp(
                                    -2.0 * 3.14159265358979323846 * kReverbDampCutoffHz /
                                    std::max<int32_t>(rate, 1));
                                autoMixFilterState_.assign(static_cast<size_t>(channels), 0.0);
                            } else {
                                autoMixExit_ = AutoMixExit::Echo;
                                autoMixEchoDelayFrames_ = 0;
                                autoMixEchoCapacity_ = 0;
                                autoMixEcho_.clear();
                                autoMixReverbDelayFrames_.clear();
                                autoMixReverbDamp_.clear();
                                autoMixFilterState_.clear();
                            }
                            raise(LazerAudioEventTrackMixStarted, 0, renderPositionMillis());
                        }
                        mixing = true;
                        incomingReplayGain = candidate->replayGainLinear;
                        mixedStartFrame = candidate->overlapFrames.load(std::memory_order_acquire);
                        mixedLengthFrames = candidate->overlapLengthFrames;
                        if (autoMixEchoActive_ && autoMixEchoCapacity_ > 0 &&
                            autoMixExit_ != AutoMixExit::Filter) {
                            /* The ring-out is the point of the two delay-line exits: the outgoing
                             * song has ended, its line has not, so a few beats of it play over the
                             * incoming song. A filter has no line and nothing to ring out with. */
                            autoMixEchoTailFrames_ = autoMixEchoDelayFrames_ * kEchoTailBeats;
                        }
                        candidate->pcm->consumeFrames(frames);
                        candidate->overlapFrames.fetch_add(frames, std::memory_order_release);
                    }
                }
            }
        }
    }
    if (!mixing) {
        /* The exit planner needs the outgoing deck's level at the moment the overlap starts and
         * cannot look backwards through audio it has already rendered, so the deck's peak is held
         * for a few seconds of its own blocks. Measured before the mix overwrites the block, and
         * only while the deck plays alone: the mix would otherwise feed the planner the incoming
         * song as if it were the outgoing one. */
        const size_t levelSamples = static_cast<size_t>(frames) *
            static_cast<size_t>(std::max(outputSession_.target.channels, 1));
        double blockPeak = 0.0;
        for (size_t sample = 0; sample < levelSamples; ++sample) {
            blockPeak = std::max(blockPeak, std::abs(static_cast<double>(samples[sample])));
        }
        const double holdSeconds = std::max<double>(
            static_cast<double>(outputSession_.target.sampleRate), 1.0) * kOutgoingPeakHoldSeconds;
        autoMixOutgoingPeak_ = std::max(blockPeak,
            autoMixOutgoingPeak_ * std::exp(-static_cast<double>(frames) / holdSeconds));
    }
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
    const double recoveryStart = cancelledOverlapGain_.exchange(-1.0, std::memory_order_acq_rel);
    if (recoveryStart >= 0.0) {
        overlapRecoveryGain_ = recoveryStart;
        overlapRecoveryFrames_ = std::max<int64_t>(1, outputSession_.target.sampleRate * 5 / 1000);
    }
    if (overlapRecoveryFrames_ > 0) {
        const size_t channels = static_cast<size_t>(std::max(outputSession_.target.channels, 1));
        for (int32_t frame = 0; frame < frames && overlapRecoveryFrames_ > 0; ++frame) {
            overlapRecoveryGain_ += (1.0 - overlapRecoveryGain_) /
                static_cast<double>(overlapRecoveryFrames_--);
            for (size_t channel = 0; channel < channels; ++channel) {
                samples[static_cast<size_t>(frame) * channels + channel] *=
                    static_cast<float>(overlapRecoveryGain_);
            }
        }
    }
    if (mixing) {
        constexpr double halfPi = 1.57079632679489661923;
        const size_t channels = static_cast<size_t>(std::max(outputSession_.target.channels, 1));
        /* Level match: the incoming song joins at its measured level relative to the outgoing one,
         * easing back to unity by the end of the overlap so the hand-off does not step the level.
         * The two sides are measured over the overlap's first quarter second; that is short enough
         * to be current and long enough not to follow a single transient. */
        const int64_t levelWindowFrames = std::max<int64_t>(
            static_cast<int64_t>(outputSession_.target.sampleRate) / 4, 1);
        if (autoMixLevelFrames_ < levelWindowFrames) {
            double outgoingEnergy = 0.0;
            double incomingEnergy = 0.0;
            for (int32_t frame = 0; frame < frames; ++frame) {
                for (size_t channel = 0; channel < channels; ++channel) {
                    const size_t sample = static_cast<size_t>(frame) * channels + channel;
                    const double outgoing = samples[sample];
                    const double incoming = autoMixScratch_[sample];
                    outgoingEnergy += outgoing * outgoing;
                    incomingEnergy += incoming * incoming;
                }
            }
            autoMixOutgoingEnergy_ += outgoingEnergy;
            autoMixIncomingEnergy_ += incomingEnergy;
            autoMixLevelFrames_ += frames;
            if (autoMixLevelFrames_ >= levelWindowFrames) {
                const double measured = static_cast<double>(autoMixLevelFrames_) *
                    static_cast<double>(channels);
                const double outgoingRms = std::sqrt(autoMixOutgoingEnergy_ / measured);
                const double incomingRms = std::sqrt(autoMixIncomingEnergy_ / measured);
                if (outgoingRms > 1.0e-6 && incomingRms > 1.0e-6) {
                    autoMixIncomingGainTarget_ = std::clamp(outgoingRms / incomingRms, 0.5, 2.0);
                }
            }
        }
        const double gainStep = 1.0 / std::max(
            static_cast<double>(outputSession_.target.sampleRate) * 0.05, 1.0);
        const double filterClosedAlpha = 1.0 - std::exp(
            -2.0 * 3.14159265358979323846 * kFilterClosedHz /
            std::max<double>(outputSession_.target.sampleRate, 1.0));
        const double lowAlpha = 1.0 - std::exp(-2.0 * 3.14159265358979323846 *
            kBassSwapCutoffHz / std::max<double>(outputSession_.target.sampleRate, 1.0));
        for (int32_t frame = 0; frame < frames; ++frame) {
            if (autoMixIncomingGain_ < autoMixIncomingGainTarget_) {
                autoMixIncomingGain_ = std::min(
                    autoMixIncomingGainTarget_, autoMixIncomingGain_ + gainStep);
            } else if (autoMixIncomingGain_ > autoMixIncomingGainTarget_) {
                autoMixIncomingGain_ = std::max(
                    autoMixIncomingGainTarget_, autoMixIncomingGain_ - gainStep);
            }
            const double progress = std::clamp(static_cast<double>(mixedStartFrame + frame) /
                static_cast<double>(std::max<int64_t>(mixedLengthFrames - 1, 1)), 0.0, 1.0);
            const double outgoingGain = std::cos(progress * halfPi);
            const double correction = autoMixIncomingGain_ +
                (1.0 - autoMixIncomingGain_) * progress;
            const double incomingGain =
                std::sin(progress * halfPi) * incomingReplayGain * correction;
            /* The bass changes hands around the middle of the overlap: the outgoing deck owns the
             * low end until then, the incoming one from there. */
            const double outgoingSwap = progress >= 0.5
                ? 0.5 - 0.5 * std::cos(2.0 * 3.14159265358979323846 * (progress - 0.5)) : 0.0;
            const double incomingSwap = progress < 0.5
                ? std::sin(2.0 * 3.14159265358979323846 * progress) : 0.0;
            for (size_t channel = 0; channel < channels; ++channel) {
                const size_t sample = static_cast<size_t>(frame) * channels + channel;
                const double outgoing = samples[sample];
                const double incoming = autoMixScratch_[sample];
                double &outgoingLow = autoMixOutgoingLow_[channel];
                double &incomingLow = autoMixIncomingLow_[channel];
                outgoingLow += lowAlpha * (outgoing - outgoingLow);
                incomingLow += lowAlpha * (incoming - incomingLow);
                const double outgoingLane =
                    outgoing - outgoingLow * autoMixBassAmount_ * outgoingSwap;
                const double incomingLane =
                    incoming - incomingLow * autoMixBassAmount_ * incomingSwap;
                double lane = outgoingLane;
                if (autoMixEchoActive_ && autoMixExit_ == AutoMixExit::Filter &&
                    channel < autoMixFilterState_.size()) {
                    /* The exit filter: the outgoing lane's low-pass closes across the overlap, so
                     * the song leaves muffled instead of being cut. The coefficient runs from a
                     * passthrough to the closed cutoff, which sweeps the cutoff exponentially. */
                    double &state = autoMixFilterState_[channel];
                    state += std::pow(filterClosedAlpha, progress) * (outgoingLane - state);
                    lane = state;
                }
                double echo = 0.0;
                if (autoMixEchoActive_ && autoMixEchoCapacity_ > 0 &&
                    autoMixExit_ != AutoMixExit::Filter) {
                    echo = mixExitEffect(outgoingLane, channel);
                }
                samples[sample] = static_cast<float>(
                    lane * outgoingGain + incomingLane * incomingGain + echo);
            }
            if (autoMixEchoActive_ && autoMixEchoCapacity_ > 0) {
                /* The line is a frame clock, not a block clock: the taps read it a beat back, so
                 * the position has to move with the frame. Advancing it once per block leaves every
                 * frame of that block writing one slot, and every tap but the last reading zero. */
                autoMixEchoIndex_ = (autoMixEchoIndex_ + 1) % autoMixEchoCapacity_;
                autoMixEchoElapsedFrames_ += 1;
            }
        }
        /* Peak guard: two songs at full level can sum past full scale, and a clipped overlap is
         * the one artefact a listener notices immediately. The envelope takes the block peak down
         * to the ceiling at once and recovers slowly, relaxing to unity over the first and last
         * 10 ms of the overlap so neither seam steps. */
        constexpr double kCeiling = 0.98;
        const size_t mixedSamples = static_cast<size_t>(frames) * channels;
        double peak = 0.0;
        for (size_t sample = 0; sample < mixedSamples; ++sample) {
            peak = std::max(peak, std::abs(static_cast<double>(samples[sample])));
        }
        const double desired = peak > kCeiling ? kCeiling / peak : 1.0;
        const double rate = std::max<double>(outputSession_.target.sampleRate, 1.0);
        const double attackStep = 1.0 / std::max(rate * 0.06, 1.0);
        const double releaseStep = 1.0 / std::max(rate * 0.3, 1.0);
        const double edgeStep = 1.0 / std::max(rate * 0.01, 1.0);
        for (int32_t frame = 0; frame < frames; ++frame) {
            if (desired < autoMixLimiterGain_) {
                autoMixLimiterGain_ = std::max(desired, autoMixLimiterGain_ - attackStep);
            } else {
                autoMixLimiterGain_ = std::min(desired, autoMixLimiterGain_ + releaseStep);
            }
            const int64_t index = mixedStartFrame + frame;
            double gain = std::max(autoMixLimiterGain_, std::max(0.0, 1.0 - index * edgeStep));
            gain = std::max(gain, std::max(0.0,
                1.0 - static_cast<double>(mixedLengthFrames - 1 - index) * edgeStep));
            for (size_t channel = 0; channel < channels; ++channel) {
                samples[static_cast<size_t>(frame) * channels + channel] *= static_cast<float>(gain);
            }
        }
    }
    /* An exit's tail outlives the overlap: the source it came from has been promoted away, so it is
     * mixed into whatever is playing now. */
    if (!mixing && autoMixEchoActive_ && autoMixEchoTailFrames_ > 0 && autoMixEchoCapacity_ > 0) {
        const size_t tailChannels =
            static_cast<size_t>(std::max(outputSession_.target.channels, 1));
        const int64_t tailLength = std::max<int64_t>(
            autoMixEchoDelayFrames_ * kEchoTailBeats, 1);
        /* Frames on the outside, channels within: the line's position is a frame clock, so every
         * channel of one frame reads and retires the same slot. */
        for (int32_t frame = 0; frame < frames; ++frame) {
            const double fade = static_cast<double>(autoMixEchoTailFrames_) /
                static_cast<double>(tailLength);
            for (size_t channel = 0; channel < tailChannels; ++channel) {
                const size_t sample = static_cast<size_t>(frame) * tailChannels + channel;
                samples[sample] = static_cast<float>(
                    samples[sample] + mixExitEffect(0.0, channel) * fade);
            }
            autoMixEchoIndex_ = (autoMixEchoIndex_ + 1) % autoMixEchoCapacity_;
            autoMixEchoTailFrames_ -= 1;
            if (autoMixEchoTailFrames_ <= 0) {
                autoMixEchoTailFrames_ = 0;
                autoMixEchoActive_ = false;
                break;
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
        if (volumeRefreshPending_.load(std::memory_order_acquire) &&
            volumeRefreshSeekApplied_.load(std::memory_order_acquire)) {
            const uint64_t refreshGeneration =
                volumeRefreshGeneration_.load(std::memory_order_acquire);
            if (refreshGeneration != 0 && volumeRefreshAppliedGeneration_.load(
                    std::memory_order_acquire) == refreshGeneration) {
                volumeRefreshPending_.store(false, std::memory_order_release);
                if (volumeRefreshGeneration_.load(std::memory_order_acquire) != refreshGeneration) {
                    /* A newer slider value arrived while this block was being published. Keep
                     * playback gated until its seek and first block have also been applied. */
                    volumeRefreshPending_.store(true, std::memory_order_release);
                } else {
                    volumeRefreshSeekApplied_.store(false, std::memory_order_release);
                }
            }
        }
        {
            std::lock_guard sourceGuard(sourceMutex_);
            if (source_ != nullptr) source_->producedOutputFrames += written;
            captureBeatGridLocked(samples, frames,
                static_cast<size_t>(std::max(outputSession_.target.channels, 1)));
        }
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
    for (;;) {
        flushSeekOnPumpThread();
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
            flushSeekOnPumpThread();
            reachedEof = active->source.reachedEndOfStream();
            sourceError = active->source.lastError();
        } else {
            const int32_t frameBytes = nativeDsdActive_.load(std::memory_order_acquire)
                ? std::max(outputSession_.target.channels, 1)
                : std::max(dspBypassed_ || dopActive_.load(std::memory_order_acquire)
                    ? outputSession_.target.frameBytes() : floatTarget_.frameBytes(), 1);
            const int32_t scratchFrames = static_cast<int32_t>(queuedPcmScratch_.size() /
                static_cast<size_t>(frameBytes));
            while (!cancelled_.load(std::memory_order_acquire)) {
                flushSeekOnPumpThread();
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
                    flushSeekOnPumpThread();
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
        publishTerminal(LazerAudioEventDeviceLost, threadSetup, renderPositionMillis());
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
        publishTerminal(LazerAudioEventDeviceLost, 0, renderPositionMillis());
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
            /* No lock: the whole commit is atomic stores the producer cannot observe half-applied
             * (it only ever reads these after `pendingPresentationReady_` is cleared, and the new
             * track's scalars are published by the producer before the boundary can be reached).
             * This is the render thread's only way to make the seam visible to `snapshot()` and
             * `streamInfo()`, so it has to happen here rather than on the producer. */
            int64_t expected = boundary;
            if (!seekFlushRequested_.load(std::memory_order_acquire) &&
                ring_.flushSequence() == seenFlush &&
                pendingTrackChangedFrame_.compare_exchange_strong(
                    expected, -1, std::memory_order_acq_rel)) {
                const bool seekedIntoSuccessor =
                    pendingPresentationSeek_.load(std::memory_order_acquire);
                int64_t seekTarget = pendingPresentation_.seekTargetMillis.load(
                    std::memory_order_acquire);
                if (seekedIntoSuccessor) {
                    /* A seek was applied to the successor after it was prepared; the producer
                     * republishes its target, so take the freshly published value. */
                    seekTarget = pendingPresentation_.seekTargetMillis.load(
                        std::memory_order_acquire);
                }
                activePresentation_.durationMillis.store(
                    pendingPresentation_.durationMillis.load(std::memory_order_acquire),
                    std::memory_order_release);
                activePresentation_.seekTargetMillis.store(seekTarget, std::memory_order_release);
                activePresentation_.sampleRate.store(
                    pendingPresentation_.sampleRate.load(std::memory_order_acquire),
                    std::memory_order_release);
                activePresentation_.channels.store(
                    pendingPresentation_.channels.load(std::memory_order_acquire),
                    std::memory_order_release);
                activePresentation_.bitsPerSample.store(
                    pendingPresentation_.bitsPerSample.load(std::memory_order_acquire),
                    std::memory_order_release);
                activePresentation_.bitrateKbps.store(
                    pendingPresentation_.bitrateKbps.load(std::memory_order_acquire),
                    std::memory_order_release);
                activePresentation_.dsd.store(
                    pendingPresentation_.dsd.load(std::memory_order_acquire),
                    std::memory_order_release);
                activePresentation_.dsdRateMultiplier.store(
                    pendingPresentation_.dsdRateMultiplier.load(std::memory_order_acquire),
                    std::memory_order_release);
                activePresentation_.lossless.store(
                    pendingPresentation_.lossless.load(std::memory_order_acquire),
                    std::memory_order_release);
                trackStartOutputFrame_.store(boundary, std::memory_order_release);
                pendingPresentationReady_.store(false, std::memory_order_release);
                pendingPresentationSeek_.store(false, std::memory_order_release);
                committed = true;
            }
        }
        if (committed) {
            /* Ask the producer to move the full description (codec string); it owns that string and
             * the UI readers take sourceMutex_ to read it. */
            presentationCommitRequested_.fetch_add(1, std::memory_order_acq_rel);
            /* Event callbacks may synchronously query the snapshot or stream info. */
            raise(LazerAudioEventTrackChanged, 0, renderPositionMillis());
        }
    };
    /* Source end-of-stream as the producer last published it: the render thread must not take
     * sourceMutex_ to ask the source directly. */
    const auto sourceEndedNow = [this]() {
        return sourceEndedMirror_.load(std::memory_order_acquire);
    };
    const auto activeDurationMillis = [this]() {
        return activePresentation_.durationMillis.load(std::memory_order_acquire);
    };

    struct VariableOutputSpan {
        int64_t outputFrames;
        int64_t sourceFrames;
    };
    /* Fixed-capacity ledger instead of a deque: the render thread must not allocate. Dropping the
     * oldest entry on overflow only loses accounting for the frames that were submitted longest ago,
     * which is exactly the case the resync path already handles. */
    constexpr size_t kVariableLedgerCapacity = 1024;
    std::vector<VariableOutputSpan> variableOutputLedger(kVariableLedgerCapacity);
    size_t variableLedgerHead = 0;
    size_t variableLedgerCount = 0;
    const auto variableLedgerPush = [&](VariableOutputSpan span) {
        if (variableLedgerCount == kVariableLedgerCapacity) {
            variableLedgerHead = (variableLedgerHead + 1) % kVariableLedgerCapacity;
            --variableLedgerCount;
        }
        variableOutputLedger[(variableLedgerHead + variableLedgerCount) % kVariableLedgerCapacity] =
            span;
        ++variableLedgerCount;
    };
    const auto variableLedgerClear = [&]() {
        variableLedgerHead = 0;
        variableLedgerCount = 0;
    };
    int64_t queueDepthAtLastObservation = 0;
    int64_t submissionsSinceQueueObservation = 0;
    int64_t renderedVariableSourceFrames = 0;
    bool variableQueueNeedsResync = true;
    /* Session start: do not submit the first period before the producer has filled one. Counting the
     * opening silence as a source-starvation underrun would make every session look like it starved
     * once, and the number would stop meaning "the decoder fell behind". Bounded, so a source that
     * is slow to open still starts instead of waiting forever. */
    bool primedForSession = false;
    int32_t primingWaits = 0;
    constexpr int32_t kPrimingWaitLimit = 8;
    const auto retireVariableOutputFrames = [&](int64_t retiredFrames) {
        while (retiredFrames > 0 && variableLedgerCount > 0) {
            VariableOutputSpan &span = variableOutputLedger[variableLedgerHead];
            const int64_t retired = std::min(retiredFrames, span.outputFrames);
            const int64_t sourceRetired = std::min(retired, span.sourceFrames);
            renderedVariableSourceFrames += sourceRetired;
            span.outputFrames -= retired;
            span.sourceFrames -= sourceRetired;
            retiredFrames -= retired;
            if (span.outputFrames == 0) {
                variableLedgerHead = (variableLedgerHead + 1) % kVariableLedgerCapacity;
                --variableLedgerCount;
            }
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
            variableLedgerClear();
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
        if (!primedForSession && !fixedPeriod) {
            /* Wait for the producer to fill one period before the session's first submission. */
            const int32_t ready = std::max<int32_t>(
                static_cast<int32_t>(kRenderBlockFrames), 0);
            if (ring_.readableFrames() >= ready ||
                pumpFinished_.load(std::memory_order_acquire) || sourceEndedNow() ||
                primingWaits >= kPrimingWaitLimit) {
                primedForSession = true;
            } else {
                ++primingWaits;
                if (waitForOutput() < 0) break;
                continue;
            }
        }
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
                publishTerminal(LazerAudioEventDeviceLost, 0, renderPositionMillis());
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
            publishTerminal(LazerAudioEventDeviceLost, 0, renderPositionMillis());
            break;
        }
        if (!fixedPeriod && outputSession_.queueDepthAvailable) {
            if (variableQueueNeedsResync) {
                /* A seek flush clears software accounting while an endpoint may still have old
                 * carrier frames queued. Retire those as non-source audio after the queue drains. */
                variableLedgerClear();
                if (queuedBeforeWrite > 0) {
                    variableLedgerPush({queuedBeforeWrite, 0});
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
            publishTerminal(LazerAudioEventDeviceLost, 0, renderPositionMillis());
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
                    ? readable >= room || (readable > 0 && sourceEndedNow())
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
            !waitedForQueuedBoundary && sourceEndedNow()) {
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
                publishTerminal(LazerAudioEventDeviceLost, 0, renderPositionMillis());
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
                    publishTerminal(LazerAudioEventDeviceLost, 0, renderPositionMillis());
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
            publishTerminal(LazerAudioEventDeviceLost, 0, renderPositionMillis());
            break;
        }
        const int32_t submittedFrames = std::min(written, framesToWrite);
        const int32_t submittedSourceFrames = std::min(frames, submittedFrames);
        const int32_t paddedFrames = std::max(submittedFrames - submittedSourceFrames, 0);
        const bool currentSourceUnfinished = !pumpFinished_.load(std::memory_order_acquire) &&
            !sourceEndedNow();
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
                variableLedgerPush({written, sendingSilence ? 0 : sourceFrames});
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
