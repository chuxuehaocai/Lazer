#include "output_alsa.h"

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstring>
#include <iterator>
#include <poll.h>
#include <sstream>
#include <utility>

#include <alsa/asoundlib.h>

#include "alsa_pcm_packing.h"
#include "output_alsa_recovery.h"

namespace lazer::audio {

namespace {

struct FormatChoice {
    snd_pcm_format_t alsaFormat;
    int32_t validBits;
    int32_t containerBits;
    int32_t formatSelection = LazerAudioFormatSelectionUnknown;
};

std::string alsaErrorText(const char *operation, int result) {
    std::string text(operation);
    text += ": ";
    text += snd_strerror(result);
    return text;
}

bool isHwDeviceName(const std::string &name) {
    /* ALSA's `hw:` PCM is the raw hardware path. Reject aliases and all plugin wrappers rather
     * than accidentally accepting `default`, `plughw:` or a user configured conversion chain. */
    return name.size() > 3 && name.compare(0, 3, "hw:") == 0 &&
        name.find_first_of("\r\n\0", 0, 3) == std::string::npos;
}

bool isAllowedOutputDeviceName(const std::string &name) {
    if (isHwDeviceName(name)) return true;
#if defined(LAZER_AUDIO_TEST_ALLOW_ALSA_NULL)
    /* The ALSA null PCM is enabled only in probe builds to exercise negotiation and queue control
     * on CI hosts without sound cards. It is never enumerated and release builds reject it. */
    return name == "null";
#else
    (void) name;
    return false;
#endif
}

std::vector<unsigned int> candidateRates(const StreamDescription &source,
    const AudioOutputRequest &request) {
    unsigned int preferred = request.desired.sampleRate > 0
        ? static_cast<unsigned int>(request.desired.sampleRate) : 0;
    if (source.dsd) {
        /* The source clock in DSD metadata is a byte clock, not a PCM rate. Convert DSD64 to
         * 176.4 kHz, DSD128 to 352.8 kHz and higher rates to the closest supported 44.1-family
         * PCM clock at or below 705.6 kHz. */
        const int32_t multiplier = std::max(source.dsdRateMultiplier, 64);
        const int32_t decimation = std::max(1, std::min(multiplier / 16, 16));
        preferred = static_cast<unsigned int>(44'100 * decimation);
    } else if (source.sampleRate > 0) {
        preferred = static_cast<unsigned int>(source.sampleRate);
    }
    if (preferred == 0) preferred = 44'100;

    std::vector<unsigned int> rates;
    const auto append = [&rates](unsigned int rate) {
        if (rate == 0 || std::find(rates.begin(), rates.end(), rate) != rates.end()) return;
        rates.push_back(rate);
    };
    append(preferred);
    if (request.bitPerfect) return rates;

    constexpr unsigned int commonRates[] = {
        8000, 11025, 16000, 22050, 32000, 44100, 48000, 64000, 88200, 96000,
        176400, 192000, 352800, 384000, 705600, 768000,
    };
    std::vector<unsigned int> ordered(commonRates, commonRates + std::size(commonRates));
    const bool sourceUses441Family = preferred != 0 && preferred % 44100 == 0;
    std::stable_sort(ordered.begin(), ordered.end(), [preferred, sourceUses441Family](
        unsigned int left, unsigned int right) {
        const bool leftSameFamily = left % 44100 == 0;
        const bool rightSameFamily = right % 44100 == 0;
        if (leftSameFamily != rightSameFamily) {
            if (leftSameFamily == sourceUses441Family) return true;
            if (rightSameFamily == sourceUses441Family) return false;
        }
        const uint64_t leftDistance = left > preferred ? left - preferred : preferred - left;
        const uint64_t rightDistance = right > preferred ? right - preferred : preferred - right;
        return leftDistance < rightDistance;
    });
    for (const unsigned int rate : ordered) append(rate);
    return rates;
}

std::vector<FormatChoice> candidateFormats(const StreamDescription &source, bool bitPerfect) {
    if (bitPerfect) {
        switch (source.bitsPerSample) {
            case 16:
                return {{SND_PCM_FORMAT_S16_LE, 16, 16}};
            case 24:
                /* ALSA exposes packed 24-bit and S24_LE (24-bit samples in the low three bytes
                 * of a 32-bit word). The write boundary repacks the shared left-aligned word. */
                return {{SND_PCM_FORMAT_S24_3LE, 24, 24}, {SND_PCM_FORMAT_S24_LE, 24, 32}};
            case 32:
                return {{SND_PCM_FORMAT_S32_LE, 32, 32}};
            default:
                return {};
        }
    }

    std::vector<FormatChoice> formats{{SND_PCM_FORMAT_FLOAT_LE, 0, 32}};
    const auto append = [&formats](snd_pcm_format_t format, int32_t bits, int32_t container) {
        const auto found = std::find_if(formats.begin(), formats.end(),
            [format](const FormatChoice &choice) { return choice.alsaFormat == format; });
        if (found == formats.end()) formats.push_back({format, bits, container});
    };

    if (source.bitsPerSample == 16) {
        append(SND_PCM_FORMAT_S16_LE, 16, 16);
        append(SND_PCM_FORMAT_S24_3LE, 24, 24);
        append(SND_PCM_FORMAT_S24_LE, 24, 32);
        append(SND_PCM_FORMAT_S32_LE, 32, 32);
    } else if (source.bitsPerSample == 24) {
        append(SND_PCM_FORMAT_S24_3LE, 24, 24);
        append(SND_PCM_FORMAT_S24_LE, 24, 32);
        append(SND_PCM_FORMAT_S32_LE, 32, 32);
        append(SND_PCM_FORMAT_S16_LE, 16, 16);
    } else {
        append(SND_PCM_FORMAT_S32_LE, 32, 32);
        append(SND_PCM_FORMAT_S24_3LE, 24, 24);
        append(SND_PCM_FORMAT_S24_LE, 24, 32);
        append(SND_PCM_FORMAT_S16_LE, 16, 16);
    }
    return formats;
}

FormatChoice dopCarrierFormat() {
    return {SND_PCM_FORMAT_S24_3LE, 24, 24};
}

std::vector<FormatChoice> nativeDsdFormats() {
    return {
        {SND_PCM_FORMAT_DSD_U32_BE, 32, 32, LazerAudioFormatSelectionNativeDsdU32Be},
        {SND_PCM_FORMAT_DSD_U32_LE, 32, 32, LazerAudioFormatSelectionNativeDsdU32Le},
        {SND_PCM_FORMAT_DSD_U16_BE, 16, 16, LazerAudioFormatSelectionNativeDsdU16Be},
        {SND_PCM_FORMAT_DSD_U16_LE, 16, 16, LazerAudioFormatSelectionNativeDsdU16Le},
        {SND_PCM_FORMAT_DSD_U8, 8, 8, LazerAudioFormatSelectionNativeDsdU8},
    };
}

bool validDopRequest(const AudioOutputRequest &request, const StreamDescription &source,
    std::string &failure) {
    if (!source.dsd || !source.rawDsd) {
        failure = "ALSA DoP output requires a raw DSD source; DST-decoded PCM cannot be wrapped";
        return false;
    }
    if (source.sampleRate <= 0 || (source.sampleRate & 1) != 0 ||
        request.desired.sampleRate != source.sampleRate / 2) {
        failure = "ALSA DoP carrier rate must be exactly half the raw DSD byte clock";
        return false;
    }
    const int32_t supportedMultipliers[] = {64, 128, 256, 512, 1024};
    if (std::find(std::begin(supportedMultipliers), std::end(supportedMultipliers),
            source.dsdRateMultiplier) == std::end(supportedMultipliers) ||
        static_cast<int64_t>(source.sampleRate) * 8 !=
            static_cast<int64_t>(44'100) * source.dsdRateMultiplier) {
        failure = "ALSA DoP output requires a supported, internally consistent DSD rate";
        return false;
    }
    if (source.channels != 1 && source.channels != 2) {
        failure = "ALSA DoP output supports only mono or stereo raw DSD";
        return false;
    }
    if (request.desired.channels != source.channels) {
        failure = "ALSA DoP output requires the exact source channel count";
        return false;
    }
    if (request.desired.bitsPerSample != 24 ||
        request.desired.containerBitsPerSample != 24) {
        failure = "ALSA DoP output requires packed 24-bit carrier frames";
        return false;
    }
    failure.clear();
    return true;
}

bool validNativeDsdRequest(const AudioOutputRequest &request,
    const StreamDescription &source, std::string &failure) {
    if (!request.exclusive || request.bitPerfect || !request.desired.nativeDsd ||
        request.desired.doP) {
        failure = "ALSA Native DSD requires a direct DSD-only output request";
        return false;
    }
    if (!source.dsd || !source.rawDsd) {
        failure = "ALSA Native DSD requires a raw DSD source; DST-decoded PCM cannot use Native DSD";
        return false;
    }
    constexpr int32_t supportedMultipliers[] = {64, 128, 256, 512, 1024};
    if (source.sampleRate <= 0 ||
        std::find(std::begin(supportedMultipliers), std::end(supportedMultipliers),
            source.dsdRateMultiplier) == std::end(supportedMultipliers) ||
        static_cast<int64_t>(source.sampleRate) * 8 !=
            static_cast<int64_t>(44'100) * source.dsdRateMultiplier) {
        failure = "ALSA Native DSD requires a supported, internally consistent DSD rate";
        return false;
    }
    if ((source.channels != 1 && source.channels != 2) ||
        request.desired.channels != source.channels) {
        failure = "ALSA Native DSD requires the exact mono or stereo source channel count";
        return false;
    }
    failure.clear();
    return true;
}

bool validBitPerfectSource(const StreamDescription &source) {
    return !source.dsd && source.lossless && source.integerPcm &&
        source.canonicalChannelLayout && source.decoderFormatMatchesStream &&
        (source.channels == 1 || source.channels == 2) && source.sampleRate > 0 &&
        (source.bitsPerSample == 16 || source.bitsPerSample == 24 ||
            source.bitsPerSample == 32);
}

struct ConfiguredPcm {
    snd_pcm_t *pcm = nullptr;
    snd_pcm_format_t format = SND_PCM_FORMAT_UNKNOWN;
    unsigned int rate = 0;
    unsigned int channels = 0;
    int32_t formatSelection = LazerAudioFormatSelectionUnknown;
    snd_pcm_uframes_t periodFrames = 0;
    snd_pcm_uframes_t bufferFrames = 0;
    bool canPause = false;
};

bool tryOpenConfigured(const std::string &device, unsigned int rate, unsigned int channels,
    const FormatChoice &format, int32_t bufferMillis, ConfiguredPcm &configured,
    std::string &failure) {
    snd_pcm_t *pcm = nullptr;
    int result = snd_pcm_open(&pcm, device.c_str(), SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK);
    if (result < 0) {
        failure = alsaErrorText("could not open ALSA hardware PCM", result);
        return false;
    }

    snd_pcm_hw_params_t *parameters = nullptr;
    snd_pcm_hw_params_malloc(&parameters);
    if (parameters == nullptr) {
        snd_pcm_close(pcm);
        failure = "could not allocate ALSA hardware parameters";
        return false;
    }

    const auto reject = [&](const char *operation, int code) {
        failure = alsaErrorText(operation, code);
        snd_pcm_hw_params_free(parameters);
        snd_pcm_close(pcm);
        return false;
    };

    result = snd_pcm_hw_params_any(pcm, parameters);
    if (result < 0) return reject("could not query ALSA hardware capabilities", result);
    result = snd_pcm_hw_params_set_access(pcm, parameters, SND_PCM_ACCESS_RW_INTERLEAVED);
    if (result < 0) return reject("ALSA device does not support interleaved PCM", result);
    result = snd_pcm_hw_params_set_format(pcm, parameters, format.alsaFormat);
    if (result < 0) return reject("ALSA device rejected the requested sample format", result);
    result = snd_pcm_hw_params_set_channels(pcm, parameters, channels);
    if (result < 0) return reject("ALSA device rejected the requested channel count", result);
    result = snd_pcm_hw_params_set_rate(pcm, parameters, rate, 0);
    if (result < 0) return reject("ALSA device rejected the requested sample rate", result);

    const unsigned int periodTimeUs = 10'000;
    unsigned int desiredPeriodTime = periodTimeUs;
    int direction = 0;
    result = snd_pcm_hw_params_set_period_time_near(
        pcm, parameters, &desiredPeriodTime, &direction);
    if (result < 0) return reject("ALSA device rejected a 10 ms period", result);

    const int32_t boundedBufferMillis = std::clamp(bufferMillis, 60, 2000);
    unsigned int desiredBufferTime = static_cast<unsigned int>(boundedBufferMillis) * 1000U;
    direction = 0;
    result = snd_pcm_hw_params_set_buffer_time_near(
        pcm, parameters, &desiredBufferTime, &direction);
    if (result < 0) return reject("ALSA device rejected the requested buffer duration", result);

    result = snd_pcm_hw_params(pcm, parameters);
    if (result < 0) return reject("could not apply ALSA hardware parameters", result);

    /* Read back the committed parameters. Never publish the requested numbers as though ALSA had
     * accepted them: the render converter and bit-perfect decision use only these readback values. */
    result = snd_pcm_hw_params_current(pcm, parameters);
    if (result < 0) return reject("could not read back ALSA hardware parameters", result);
    snd_pcm_format_t actualFormat = SND_PCM_FORMAT_UNKNOWN;
    unsigned int actualRate = 0;
    unsigned int actualChannels = 0;
    direction = 0;
    result = snd_pcm_hw_params_get_format(parameters, &actualFormat);
    if (result < 0) return reject("could not read back ALSA PCM format", result);
    result = snd_pcm_hw_params_get_rate(parameters, &actualRate, &direction);
    if (result < 0) return reject("could not read back ALSA sample rate", result);
    result = snd_pcm_hw_params_get_channels(parameters, &actualChannels);
    if (result < 0) return reject("could not read back ALSA channel count", result);
    if (actualFormat != format.alsaFormat || actualRate != rate || actualChannels != channels) {
        std::ostringstream message;
        const char *actualFormatName = snd_pcm_format_name(actualFormat);
        message << "ALSA negotiated a different format than requested (rate " << actualRate
                << ", channels " << actualChannels << ", format "
                << (actualFormatName != nullptr ? actualFormatName : "unknown") << ")";
        failure = message.str();
        snd_pcm_hw_params_free(parameters);
        snd_pcm_close(pcm);
        return false;
    }

    snd_pcm_uframes_t periodFrames = 0;
    snd_pcm_uframes_t bufferFrames = 0;
    direction = 0;
    result = snd_pcm_hw_params_get_period_size(parameters, &periodFrames, &direction);
    if (result < 0) return reject("could not read back ALSA period size", result);
    result = snd_pcm_hw_params_get_buffer_size(parameters, &bufferFrames);
    if (result < 0) return reject("could not read back ALSA buffer size", result);
    if (periodFrames == 0 || bufferFrames == 0 || periodFrames > bufferFrames ||
        bufferFrames > static_cast<snd_pcm_uframes_t>(INT_MAX)) {
        failure = "ALSA returned an invalid period or buffer size";
        snd_pcm_hw_params_free(parameters);
        snd_pcm_close(pcm);
        return false;
    }

    const bool canPause = snd_pcm_hw_params_can_pause(parameters) != 0;
    snd_pcm_hw_params_free(parameters);

    snd_pcm_sw_params_t *softwareParameters = nullptr;
    snd_pcm_sw_params_malloc(&softwareParameters);
    if (softwareParameters == nullptr) {
        snd_pcm_close(pcm);
        failure = "could not allocate ALSA software parameters";
        return false;
    }
    result = snd_pcm_sw_params_current(pcm, softwareParameters);
    if (result < 0) {
        failure = alsaErrorText("could not query ALSA software parameters", result);
        snd_pcm_sw_params_free(softwareParameters);
        snd_pcm_close(pcm);
        return false;
    }
    const snd_pcm_uframes_t availableMin = std::max<snd_pcm_uframes_t>(periodFrames, 1);
    result = snd_pcm_sw_params_set_avail_min(pcm, softwareParameters, availableMin);
    if (result >= 0) {
        /* Let writei start playback after the first queued frame. start() prepares the PCM before
         * the render thread submits, and a larger threshold could deadlock on a short final track. */
        result = snd_pcm_sw_params_set_start_threshold(pcm, softwareParameters, 1);
    }
    if (result >= 0) result = snd_pcm_sw_params(pcm, softwareParameters);
    snd_pcm_sw_params_free(softwareParameters);
    if (result < 0) {
        failure = alsaErrorText("could not apply ALSA software parameters", result);
        snd_pcm_close(pcm);
        return false;
    }

    configured.pcm = pcm;
    configured.format = actualFormat;
    configured.rate = actualRate;
    configured.channels = actualChannels;
    configured.formatSelection = format.formatSelection;
    configured.periodFrames = periodFrames;
    configured.bufferFrames = bufferFrames;
    configured.canPause = canPause;
    return true;
}

bool tryOpenNativeDsdConfigured(const std::string &device,
    const AudioOutputRequest &request, const StreamDescription &source,
    ConfiguredPcm &configured, std::string &failure, int32_t forcedFormatIndex = -1) {
    const auto formats = nativeDsdFormats();
    if (forcedFormatIndex < -1 ||
        forcedFormatIndex >= static_cast<int32_t>(formats.size())) return false;
    for (size_t index = 0; index < formats.size(); ++index) {
        if (forcedFormatIndex >= 0 && index != static_cast<size_t>(forcedFormatIndex)) continue;
        const FormatChoice &format = formats[index];
        const unsigned int wordBytes = static_cast<unsigned int>(format.containerBits / 8);
        if (wordBytes == 0 || source.sampleRate <= 0 ||
            source.sampleRate % static_cast<int32_t>(wordBytes) != 0) continue;
        const unsigned int rate = static_cast<unsigned int>(source.sampleRate) / wordBytes;
        if (tryOpenConfigured(device, rate, static_cast<unsigned int>(source.channels), format,
                request.bufferMillis, configured, failure)) {
            return true;
        }
    }
    return false;
}

size_t queuedBufferFrames(const std::vector<uint8_t> &bytes, size_t offsetFrames, int32_t frameBytes) {
    if (frameBytes <= 0) return 0;
    const size_t totalFrames = bytes.size() / static_cast<size_t>(frameBytes);
    return totalFrames > offsetFrames ? totalFrames - offsetFrames : 0;
}

}  // namespace

#if defined(LAZER_AUDIO_TEST_ALLOW_ALSA_NULL)
/* Probe hooks deliberately bypass only the public hw:-name gate so the test-only ALSA null plugin
 * can check one exact carrier tuple. Production AlsaOutput::open never uses these hooks. */
extern "C" int32_t lazer_audio_test_alsa_dop_null_negotiation(int32_t carrierRate,
    int32_t channels, int32_t *actualRate, int32_t *actualChannels,
    int32_t *validBits, int32_t *containerBits) {
    if (carrierRate <= 0 || carrierRate > INT_MAX / 2 ||
        (channels != 1 && channels != 2) || actualRate == nullptr ||
        actualChannels == nullptr || validBits == nullptr || containerBits == nullptr) {
        return LazerAudioErrorInvalidArgument;
    }

    AudioOutputRequest request;
    request.requireDoP = true;
    request.desired.sampleRate = carrierRate;
    request.desired.channels = channels;
    request.desired.bitsPerSample = 24;
    request.desired.containerBitsPerSample = 24;
    StreamDescription source;
    source.dsd = true;
    source.rawDsd = true;
    source.sampleRate = carrierRate * 2;
    source.channels = channels;
    source.dsdRateMultiplier = static_cast<int32_t>(
        static_cast<int64_t>(source.sampleRate) * 8 / 44'100);
    std::string failure;
    if (!validDopRequest(request, source, failure)) return LazerAudioErrorUnsupported;

    ConfiguredPcm configured;
    if (!tryOpenConfigured("null", static_cast<unsigned int>(carrierRate),
            static_cast<unsigned int>(channels), dopCarrierFormat(), 120, configured, failure)) {
        return LazerAudioErrorUnsupported;
    }
    *actualRate = static_cast<int32_t>(configured.rate);
    *actualChannels = static_cast<int32_t>(configured.channels);
    *validBits = 24;
    *containerBits = 24;
    snd_pcm_close(configured.pcm);
    return LazerAudioOk;
}

extern "C" int32_t lazer_audio_test_alsa_native_dsd_null_negotiation(
    int32_t dsdByteClock, int32_t dsdRateMultiplier, int32_t channels, int32_t formatIndex,
    int32_t *actualRate, int32_t *actualChannels, int32_t *validBits,
    int32_t *containerBits, int32_t *formatSelection) {
    if (dsdByteClock <= 0 || dsdByteClock > 5'644'800 ||
        (channels != 1 && channels != 2) || formatIndex < -1 || formatIndex >= 5 ||
        actualRate == nullptr ||
        actualChannels == nullptr || validBits == nullptr || containerBits == nullptr ||
        formatSelection == nullptr) {
        return LazerAudioErrorInvalidArgument;
    }

    AudioOutputRequest request;
    request.exclusive = true;
    request.requireNativeDsd = true;
    request.desired.nativeDsd = true;
    request.desired.sampleRate = dsdByteClock;
    request.desired.channels = channels;
    request.bufferMillis = 120;
    StreamDescription source;
    source.dsd = true;
    source.rawDsd = true;
    source.sampleRate = dsdByteClock;
    source.channels = channels;
    source.dsdRateMultiplier = dsdRateMultiplier;
    std::string failure;
    if (!validNativeDsdRequest(request, source, failure)) return LazerAudioErrorUnsupported;

    ConfiguredPcm configured;
    if (!tryOpenNativeDsdConfigured("null", request, source, configured, failure,
            formatIndex)) {
        return LazerAudioErrorUnsupported;
    }
    const auto formats = nativeDsdFormats();
    const auto selected = std::find_if(formats.begin(), formats.end(),
        [&configured](const FormatChoice &choice) {
            return choice.alsaFormat == configured.format;
        });
    if (selected == formats.end()) {
        snd_pcm_close(configured.pcm);
        return LazerAudioErrorUnsupported;
    }
    *actualRate = static_cast<int32_t>(configured.rate);
    *actualChannels = static_cast<int32_t>(configured.channels);
    *validBits = selected->validBits;
    *containerBits = selected->containerBits;
    *formatSelection = configured.formatSelection;
    snd_pcm_close(configured.pcm);
    return LazerAudioOk;
}

extern "C" int32_t lazer_audio_test_alsa_dop_stage_bytes(const uint8_t *bytes,
    int32_t frameCount, int32_t channels, uint8_t *destination, int32_t destinationBytes) {
    if (frameCount < 0 || (channels != 1 && channels != 2) || destinationBytes < 0 ||
        (frameCount > 0 && (bytes == nullptr || destination == nullptr))) {
        return LazerAudioErrorInvalidArgument;
    }
    if (frameCount == 0) return 0;
    if (frameCount > destinationBytes / (channels * 3)) {
        return LazerAudioErrorBufferTooSmall;
    }
    const size_t byteCount = static_cast<size_t>(frameCount) *
        static_cast<size_t>(channels) * 3;
    std::vector<uint8_t> staged;
    appendAlsaOutputFrames(staged, bytes, static_cast<size_t>(frameCount),
        static_cast<size_t>(channels), channels * 3, true, false);
    std::copy(staged.begin(), staged.end(), destination);
    return frameCount;
}

extern "C" int32_t lazer_audio_test_alsa_dop_suspend_resume(int32_t alsaError,
    int32_t retryCount, int32_t finalResumeResult, int32_t *resumeCalls, int32_t *waitCalls) {
    if (retryCount < 0 || resumeCalls == nullptr || waitCalls == nullptr) {
        return LazerAudioErrorInvalidArgument;
    }
    int calls = 0;
    int waits = 0;
    const AlsaRecoveryResult result = resumeAlsaDirectDsdSuspend(alsaError, -ESTRPIPE, -EAGAIN,
        [&]() {
            ++calls;
            return calls <= retryCount ? -EAGAIN : finalResumeResult;
        },
        [&]() { ++waits; });
    *resumeCalls = calls;
    *waitCalls = waits;
    return result.outcome == AlsaRecoveryOutcome::SuspendResumed ? 1 : 0;
}
#endif

AlsaOutput::~AlsaOutput() {
    close();
}

int32_t AlsaOutput::open(const AudioOutputRequest &request, const StreamDescription &source,
    AudioOutputSession &session, std::string &error, LogProxy *log) {
    close();

    if (request.requireDoP && request.requireNativeDsd) {
        error = "DoP and Native DSD are separate output modes";
        return LazerAudioErrorInvalidArgument;
    }
    if (request.bitPerfect && !request.requireDoP && !request.requireNativeDsd &&
        !validBitPerfectSource(source)) {
        error = source.dsd
            ? "ALSA bit-perfect output accepts exact PCM only; convert DSD to PCM first"
            : "ALSA bit-perfect output needs mono/stereo lossless integer PCM at 16/24/32 bit";
        return LazerAudioErrorUnsupported;
    }
    if (!request.requireDoP && !request.requireNativeDsd &&
        request.desired.channels <= 0 && source.channels <= 0) {
        error = "the source has no usable channel count";
        return LazerAudioErrorUnsupported;
    }

#if defined(LAZER_AUDIO_TEST_ALLOW_ALSA_NULL)
    std::string device = request.deviceId.empty() ? "hw:0,0" : request.deviceId;
    const bool testNativeDsdNull = request.requireNativeDsd &&
        device == "lazer-test:alsa-null";
    if (testNativeDsdNull) device = "null";
#else
    const std::string device = request.deviceId.empty() ? "hw:0,0" : request.deviceId;
#endif
    if ((request.requireDoP || request.requireNativeDsd) && !isHwDeviceName(device)
#if defined(LAZER_AUDIO_TEST_ALLOW_ALSA_NULL)
        && !testNativeDsdNull
#endif
        ) {
        error = request.requireDoP
            ? "ALSA DoP output requires a direct hw: device; ALSA plugins and the test null PCM are not accepted"
            : "ALSA Native DSD requires a direct hw: device; ALSA plugins are not accepted";
        return LazerAudioErrorInvalidArgument;
    }
    if (!isAllowedOutputDeviceName(device)) {
#if defined(LAZER_AUDIO_TEST_ALLOW_ALSA_NULL)
        error = "ALSA output requires a direct hw: device ID (for example hw:1,0); only the test probe accepts null";
#else
        error = "ALSA output requires a direct hw: device ID (for example hw:1,0); ALSA plugins are disabled";
#endif
        return LazerAudioErrorInvalidArgument;
    }

    if (request.requireDoP && !validDopRequest(request, source, error)) {
        return LazerAudioErrorUnsupported;
    }
    if (request.requireNativeDsd && !validNativeDsdRequest(request, source, error)) {
        return LazerAudioErrorUnsupported;
    }

    const std::vector<unsigned int> rates = request.requireDoP
        ? std::vector<unsigned int>{static_cast<unsigned int>(request.desired.sampleRate)}
        : request.requireNativeDsd ? std::vector<unsigned int>{} : candidateRates(source, request);
    const std::vector<FormatChoice> formats = request.requireDoP
        ? std::vector<FormatChoice>{dopCarrierFormat()}
        : request.requireNativeDsd ? nativeDsdFormats()
        : candidateFormats(source, request.bitPerfect);
    std::vector<unsigned int> channels;
    const unsigned int sourceChannels = static_cast<unsigned int>(
        request.desired.channels > 0 ? request.desired.channels : source.channels);
    if (sourceChannels > 0) channels.push_back(sourceChannels);
    if (!request.requireDoP && !request.requireNativeDsd && !request.bitPerfect &&
        sourceChannels == 1) channels.push_back(2);

    if ((!request.requireNativeDsd && rates.empty()) || formats.empty() || channels.empty()) {
        error = "no ALSA PCM formats are available for this stream";
        return LazerAudioErrorUnsupported;
    }

    ConfiguredPcm configured;
    std::string lastFailure;
    bool found = false;
    if (request.requireNativeDsd) {
        found = tryOpenNativeDsdConfigured(device, request, source, configured, lastFailure);
    } else {
        for (const unsigned int rate : rates) {
            for (const unsigned int channelCount : channels) {
                for (const FormatChoice &format : formats) {
                    if (tryOpenConfigured(device, rate, channelCount, format,
                        request.bufferMillis, configured, lastFailure)) {
                        found = true;
                        break;
                    }
                }
                if (found) break;
            }
            if (found) break;
        }
    }
    if (!found) {
        error = request.requireDoP
            ? "the ALSA hw device does not accept the exact DoP carrier rate, channels and packed S24_3LE format"
            : request.requireNativeDsd
            ? "the ALSA hw device does not accept a supported exact Native DSD rate, channel count and DSD_U8/U16/U32 format"
            : request.bitPerfect
            ? "the ALSA hw device does not accept the exact source PCM rate, channels and precision"
            : "the ALSA hw device accepts none of the tried direct PCM formats";
        if (!lastFailure.empty()) error += ": " + lastFailure;
        return LazerAudioErrorUnsupported;
    }

    const int32_t validBits = formats.front().alsaFormat == configured.format
        ? formats.front().validBits
        : [&formats, &configured]() {
            const auto it = std::find_if(formats.begin(), formats.end(),
                [&configured](const FormatChoice &choice) {
                    return choice.alsaFormat == configured.format;
                });
            return it == formats.end() ? 0 : it->validBits;
        }();
    const int32_t containerBits = [&formats, &configured]() {
        const auto it = std::find_if(formats.begin(), formats.end(),
            [&configured](const FormatChoice &choice) {
                return choice.alsaFormat == configured.format;
            });
        return it == formats.end() ? 0 : it->containerBits;
    }();

    std::lock_guard guard(mutex_);
    pcm_ = configured.pcm;
    log_ = log;
    deviceName_ = device;
    bufferFrames_ = static_cast<int32_t>(configured.bufferFrames);
    periodFrames_ = static_cast<int32_t>(configured.periodFrames);
    frameBytes_ = static_cast<int32_t>(configured.channels) * (containerBits / 8);
    pollDescriptorCount_ = snd_pcm_poll_descriptors_count(configured.pcm);
    pauseSupported_ = configured.canPause;
    shift24ToLow_ = !request.requireDoP && !request.requireNativeDsd &&
        configured.format == SND_PCM_FORMAT_S24_LE;
    running_ = false;
    hardwarePaused_ = false;
    stagedBytes_.clear();
    stagedOffsetFrames_ = 0;
    submittedBytes_.clear();
    submittedOffsetFrames_ = 0;

    TargetFormat target;
    target.sampleRate = static_cast<int32_t>(configured.rate);
    target.channels = static_cast<int32_t>(configured.channels);
    target.bitsPerSample = validBits;
    target.containerBitsPerSample = containerBits;
    target.doP = request.requireDoP;
    target.nativeDsd = request.requireNativeDsd;
    target.nativeDsdBigEndian = configured.format == SND_PCM_FORMAT_DSD_U8 ||
        configured.format == SND_PCM_FORMAT_DSD_U16_BE ||
        configured.format == SND_PCM_FORMAT_DSD_U32_BE;
    session.target = target;
    session.engineFormat = PcmFormat{target.sampleRate, target.channels};
    session.formatSelection = request.requireDoP
        ? LazerAudioFormatSelectionDoPCarrier : configured.formatSelection;
    session.periodFrames = periodFrames_;
    session.bufferFrames = bufferFrames_;
    session.description = "ALSA " + deviceName_ + " / " +
        std::to_string(target.sampleRate) + " Hz / " +
        std::to_string(target.bitsPerSample == 0 ? 32 : target.bitsPerSample) + " bit / " +
        std::to_string(target.channels) + " 声道";
    if (request.requireDoP) session.description += " / DoP carrier";
    if (request.requireNativeDsd) {
        const char *formatName = snd_pcm_format_name(configured.format);
        session.description += " / Native ";
        session.description += formatName != nullptr ? formatName : "DSD";
    }
    /* hw: bypasses ALSA conversion/mix plugins. This reports direct PCM ownership to the engine;
     * it does not certify the DAC's internal clock or downstream DSP. */
    session.exclusive = isHwDeviceName(deviceName_);
    session.writeMode = OutputWriteMode::Variable;
    session.primeBeforeStart = false;
    session.queueDepthAvailable = true;
    session.doP = request.requireDoP;
    session.nativeDsd = request.requireNativeDsd;
    session_ = session;
    error.clear();
    if (log_ != nullptr) log_->write(LazerAudioLogInfo, session.description);
    return LazerAudioOk;
}

void AlsaOutput::close() {
    std::lock_guard guard(mutex_);
    if (pcm_ != nullptr) {
        snd_pcm_t *pcm = static_cast<snd_pcm_t *>(pcm_);
        if (running_) snd_pcm_drop(pcm);
        snd_pcm_close(pcm);
        pcm_ = nullptr;
    }
    running_ = false;
    hardwarePaused_ = false;
    pauseSupported_ = false;
    shift24ToLow_ = false;
    bufferFrames_ = 0;
    periodFrames_ = 0;
    frameBytes_ = 0;
    pollDescriptorCount_ = 0;
    log_ = nullptr;
    deviceName_.clear();
    session_ = AudioOutputSession{};
    stagedBytes_.clear();
    stagedOffsetFrames_ = 0;
    submittedBytes_.clear();
    submittedOffsetFrames_ = 0;
}

bool AlsaOutput::isOpen() const noexcept {
    std::lock_guard guard(mutex_);
    return pcm_ != nullptr;
}

int32_t AlsaOutput::start(std::string &error) {
    std::lock_guard guard(mutex_);
    if (pcm_ == nullptr) {
        error = "the ALSA output is not open";
        return LazerAudioErrorState;
    }
    if (running_) return LazerAudioOk;

    auto *pcm = static_cast<snd_pcm_t *>(pcm_);
    if (hardwarePaused_) {
        const int result = snd_pcm_pause(pcm, 0);
        if (result >= 0) {
            hardwarePaused_ = false;
            running_ = true;
            return flushStaged(error);
        }
        if (session_.doP || session_.nativeDsd) {
            error = alsaErrorText(
                "direct DSD output stopped after pause resume failure because stream continuity is unknown",
                result);
            return LazerAudioErrorDevice;
        }
        /* Some drivers advertise pause capability but fail to resume. Preserve the queued frames
         * in software and fall back to drop/prepare rather than losing the audio already accepted. */
        const int dropped = snd_pcm_drop(pcm);
        if (dropped < 0) {
            error = alsaErrorText("could not resume or reset the ALSA PCM", dropped);
            return LazerAudioErrorDevice;
        }
        requeueSubmittedAtFront();
        hardwarePaused_ = false;
    }

    const int32_t normalized = normalizeAlsaState(error);
    if (normalized != LazerAudioOk) return normalized;
    const snd_pcm_state_t state = snd_pcm_state(pcm);
    if (state != SND_PCM_STATE_PREPARED) {
        const int result = snd_pcm_prepare(pcm);
        if (result < 0) {
            error = alsaErrorText("could not prepare the ALSA PCM", result);
            return LazerAudioErrorDevice;
        }
    }
    running_ = true;
    return flushStaged(error);
}

int32_t AlsaOutput::stop(std::string &error) {
    std::lock_guard guard(mutex_);
    if (pcm_ == nullptr || !running_) return LazerAudioOk;
    auto *pcm = static_cast<snd_pcm_t *>(pcm_);
    if (pauseSupported_) {
        /* Refresh the mirror just before freezing playback so the paused queue does not include
         * frames that the device consumed since the last render-loop query. */
        error.clear();
        (void)currentQueuedFrames(error);
        const int result = snd_pcm_pause(pcm, 1);
        if (result >= 0) {
            hardwarePaused_ = true;
            running_ = false;
            return LazerAudioOk;
        }
    }

    /* USB DACs often cannot pause. Snapshot the not-yet-played frames before dropping the device
     * queue, then replay them after prepare on resume so pause does not skip queued audio. */
    error.clear();
    if (currentQueuedFrames(error) < 0) return LazerAudioErrorDevice;
    const int dropped = snd_pcm_drop(pcm);
    if (dropped < 0 && dropped != -EBADFD) {
        error = alsaErrorText("could not stop the ALSA PCM", dropped);
        return LazerAudioErrorDevice;
    }
    requeueSubmittedAtFront();
    running_ = false;
    hardwarePaused_ = false;
    return LazerAudioOk;
}

int32_t AlsaOutput::reset(std::string &error) {
    std::lock_guard guard(mutex_);
    if (pcm_ == nullptr) {
        error = "the ALSA output is not open";
        return LazerAudioErrorState;
    }
    auto *pcm = static_cast<snd_pcm_t *>(pcm_);
    int result = snd_pcm_drop(pcm);
    if (result < 0 && result != -EBADFD) {
        error = alsaErrorText("could not clear the ALSA PCM queue", result);
        return LazerAudioErrorDevice;
    }
    result = snd_pcm_prepare(pcm);
    if (result < 0) {
        error = alsaErrorText("could not prepare the ALSA PCM after reset", result);
        return LazerAudioErrorDevice;
    }
    running_ = false;
    hardwarePaused_ = false;
    stagedBytes_.clear();
    stagedOffsetFrames_ = 0;
    submittedBytes_.clear();
    submittedOffsetFrames_ = 0;
    return LazerAudioOk;
}

OutputWaitResult AlsaOutput::waitForReady(int32_t timeoutMillis, std::string &error) {
    std::lock_guard guard(mutex_);
    if (pcm_ == nullptr) {
        error = "the ALSA output is not open";
        return OutputWaitResult::Error;
    }
    const int timeout = std::max(timeoutMillis, 0);
    if (!running_) {
        if (timeout > 0) poll(nullptr, 0, timeout);
        return OutputWaitResult::Timeout;
    }

    auto *pcm = static_cast<snd_pcm_t *>(pcm_);
    if (normalizeAlsaState(error) != LazerAudioOk) return OutputWaitResult::Error;
    if (flushStaged(error) != LazerAudioOk) return OutputWaitResult::Error;
    if (pollDescriptorCount_ <= 0) {
        if (timeout > 0) poll(nullptr, 0, timeout);
        if (flushStaged(error) != LazerAudioOk) return OutputWaitResult::Error;
        return OutputWaitResult::Ready;
    }

    std::vector<pollfd> descriptors(static_cast<size_t>(pollDescriptorCount_));
    int result = snd_pcm_poll_descriptors(pcm, descriptors.data(),
        static_cast<unsigned int>(descriptors.size()));
    if (result < 0) {
        error = alsaErrorText("could not obtain ALSA poll descriptors", result);
        return OutputWaitResult::Error;
    }
    do {
        result = poll(descriptors.data(), static_cast<nfds_t>(descriptors.size()), timeout);
    } while (result < 0 && errno == EINTR);
    if (result == 0) return OutputWaitResult::Timeout;
    if (result < 0) {
        error = "polling the ALSA output failed";
        return OutputWaitResult::Error;
    }

    unsigned short revents = 0;
    result = snd_pcm_poll_descriptors_revents(pcm, descriptors.data(),
        static_cast<unsigned int>(descriptors.size()), &revents);
    if (result < 0) {
        error = alsaErrorText("could not read ALSA readiness state", result);
        return OutputWaitResult::Error;
    }
    if ((revents & POLLERR) != 0) {
        if (normalizeAlsaState(error) != LazerAudioOk) return OutputWaitResult::Error;
    }
    if ((revents & (POLLOUT | POLLERR)) == 0) return OutputWaitResult::Timeout;
    if (flushStaged(error) != LazerAudioOk) return OutputWaitResult::Error;
    return OutputWaitResult::Ready;
}

int32_t AlsaOutput::writableFrames(std::string &error) {
    std::lock_guard guard(mutex_);
    if (pcm_ == nullptr) {
        error = "the ALSA output is not open";
        return LazerAudioErrorState;
    }
    const int32_t queued = currentQueuedFrames(error);
    if (queued < 0) return queued;
    return std::max(bufferFrames_ - queued, 0);
}

int32_t AlsaOutput::queuedFrames(std::string &error) {
    std::lock_guard guard(mutex_);
    if (pcm_ == nullptr) {
        error = "the ALSA output is not open";
        return LazerAudioErrorState;
    }
    return currentQueuedFrames(error);
}

OutputDrainResult AlsaOutput::drain(std::string &error) {
    const int32_t queued = queuedFrames(error);
    if (queued < 0) return OutputDrainResult::Error;
    return queued == 0 ? OutputDrainResult::Drained : OutputDrainResult::Pending;
}

int32_t AlsaOutput::write(const uint8_t *bytes, int32_t frameCount, std::string &error) {
    std::lock_guard guard(mutex_);
    if (pcm_ == nullptr) {
        error = "the ALSA output is not open";
        return LazerAudioErrorState;
    }
    if (frameCount < 0 || (frameCount > 0 && bytes == nullptr)) {
        error = "invalid PCM buffer passed to ALSA output";
        return LazerAudioErrorInvalidArgument;
    }
    if (frameCount == 0) return 0;

    const int32_t queued = currentQueuedFrames(error);
    if (queued < 0) return queued;
    if (frameCount > bufferFrames_ - queued) {
        /* The render loop asks writableFrames immediately before write. Refusing an over-capacity
         * packet is safer than silently accepting only a prefix, which would discard source frames. */
        error = "ALSA staging queue has less room than the submitted PCM block";
        return LazerAudioErrorDevice;
    }

    compactQueue(stagedBytes_, stagedOffsetFrames_);
    appendAlsaOutputFrames(stagedBytes_, bytes, static_cast<size_t>(frameCount),
        static_cast<size_t>(session_.target.channels), frameBytes_, session_.doP, shift24ToLow_);
    if (running_ && flushStaged(error) != LazerAudioOk) return LazerAudioErrorDevice;
    return frameCount;
}

int32_t AlsaOutput::flushStaged(std::string &error) {
    if (pcm_ == nullptr) return LazerAudioErrorState;
    if (!running_) return LazerAudioOk;
    auto *pcm = static_cast<snd_pcm_t *>(pcm_);

    int32_t normalized = normalizeAlsaState(error);
    if (normalized != LazerAudioOk) return normalized;

    while (queuedBufferFrames(stagedBytes_, stagedOffsetFrames_, frameBytes_) > 0) {
        const size_t pendingFrames = queuedBufferFrames(
            stagedBytes_, stagedOffsetFrames_, frameBytes_);
        const size_t offsetBytes = stagedOffsetFrames_ * static_cast<size_t>(frameBytes_);
        const uint8_t *source = stagedBytes_.data() + offsetBytes;
        const snd_pcm_sframes_t written = snd_pcm_writei(
            pcm, source, static_cast<snd_pcm_uframes_t>(pendingFrames));
        if (written > 0) {
            const size_t writtenFrames = static_cast<size_t>(written);
            compactQueue(submittedBytes_, submittedOffsetFrames_);
            submittedBytes_.insert(submittedBytes_.end(), source,
                source + writtenFrames * static_cast<size_t>(frameBytes_));
            stagedOffsetFrames_ += writtenFrames;
            compactQueue(stagedBytes_, stagedOffsetFrames_);
            continue;
        }
        if (written == 0 || written == -EAGAIN) break;
        if (written == -EINTR) continue;
        if (written == -EPIPE || written == -ESTRPIPE) {
            normalized = recover(error, static_cast<int>(written));
            if (normalized != LazerAudioOk) return normalized;
            continue;
        }
        error = alsaErrorText("ALSA could not accept PCM frames", static_cast<int>(written));
        return LazerAudioErrorDevice;
    }
    return LazerAudioOk;
}

int32_t AlsaOutput::normalizeAlsaState(std::string &error) {
    if (pcm_ == nullptr) return LazerAudioErrorState;
    const snd_pcm_state_t state = snd_pcm_state(static_cast<snd_pcm_t *>(pcm_));
    if (state == SND_PCM_STATE_XRUN) return recover(error, -EPIPE);
    if (state == SND_PCM_STATE_SUSPENDED) return recover(error, -ESTRPIPE);
    return LazerAudioOk;
}

int32_t AlsaOutput::recover(std::string &error, int alsaError) {
    if (pcm_ == nullptr) return LazerAudioErrorState;
    auto *pcm = static_cast<snd_pcm_t *>(pcm_);
    if (session_.doP || session_.nativeDsd) {
        const AlsaRecoveryResult result = recoverAlsaDirectDsd(alsaError, -EPIPE, -ESTRPIPE,
            -EAGAIN,
            [pcm]() { return snd_pcm_resume(pcm); },
            []() { (void) poll(nullptr, 0, 1000); });
        const int resumeError = result.error;
        const bool resumed = result.outcome == AlsaRecoveryOutcome::SuspendResumed;
        if (!resumed) {
            if (alsaError == -EPIPE) {
                error = session_.doP
                    ? "DoP output stopped after ALSA XRUN because carrier frame loss makes marker phase unknown"
                    : "Native DSD output stopped after ALSA XRUN because DSD word loss breaks stream continuity";
            } else if (alsaError == -ESTRPIPE) {
                error = alsaErrorText(session_.doP
                    ? "DoP output stopped because ALSA suspend could not resume without resetting the carrier queue"
                    : "Native DSD output stopped because ALSA suspend could not resume without resetting the DSD queue",
                    resumeError);
                if (resumeError == -EAGAIN) {
                    error += "; ALSA suspend resume retry limit was exhausted";
                }
                error += session_.doP ? "; marker phase is unknown" : "; DSD stream continuity is unknown";
            } else {
                error = alsaErrorText(session_.doP
                    ? "DoP output stopped because ALSA recovery cannot guarantee carrier marker phase"
                    : "Native DSD output stopped because ALSA recovery cannot guarantee word continuity",
                    alsaError);
            }
            return LazerAudioErrorDevice;
        }
        if (log_ != nullptr) {
            log_->write(LazerAudioLogInfo, session_.doP
                ? "DoP ALSA suspend resumed with the existing carrier queue preserved"
                : "Native DSD ALSA suspend resumed with the existing DSD queue preserved");
        }
        error.clear();
        return LazerAudioOk;
    }

    const AlsaRecoveryResult result = recoverAlsaPlayback(
        alsaError,
        -EPIPE,
        -ESTRPIPE,
        -EAGAIN,
        [pcm]() { return snd_pcm_resume(pcm); },
        [pcm]() { return snd_pcm_prepare(pcm); },
        []() { (void) poll(nullptr, 0, 1000); });
    if (result.outcome == AlsaRecoveryOutcome::Failed) {
        error = alsaErrorText("could not recover the ALSA PCM after XRUN/suspend", result.error);
        if (alsaError == -ESTRPIPE && result.error == -EAGAIN) {
            error += "; ALSA suspend resume retry limit was exhausted";
        }
        return LazerAudioErrorDevice;
    }
    reconcileAlsaRecoveryQueues(
        result.outcome,
        stagedBytes_, stagedOffsetFrames_,
        submittedBytes_, submittedOffsetFrames_,
        static_cast<size_t>(frameBytes_));
    if (log_ != nullptr) {
        const char *message = "ALSA PCM recovered from XRUN; submitted frames were discarded";
        if (result.outcome == AlsaRecoveryOutcome::SuspendResumed) {
            message = "ALSA PCM resumed from suspend; the ALSA queue was preserved";
        } else if (result.outcome == AlsaRecoveryOutcome::SuspendPrepared) {
            message = "ALSA PCM prepared after suspend; pending frames were requeued";
        }
        log_->write(LazerAudioLogWarning, message);
    }
    error.clear();
    return LazerAudioOk;
}

int32_t AlsaOutput::currentQueuedFrames(std::string &error) {
    if (pcm_ == nullptr) return LazerAudioErrorState;
    if (!running_) {
        const size_t stoppedFrames = queuedBufferFrames(stagedBytes_, stagedOffsetFrames_, frameBytes_) +
            queuedBufferFrames(submittedBytes_, submittedOffsetFrames_, frameBytes_);
        return static_cast<int32_t>(std::min<size_t>(
            static_cast<size_t>(bufferFrames_), stoppedFrames));
    }
    const int32_t normalized = normalizeAlsaState(error);
    if (normalized != LazerAudioOk) return normalized;

    /* ALSA documents avail_update as the buffer-fill query. snd_pcm_delay includes downstream
     * transport latency and is appropriate for audible-position estimates, not ring occupancy. */
    auto *pcm = static_cast<snd_pcm_t *>(pcm_);
    bool attemptedRecovery = false;
    int32_t recoveryError = LazerAudioErrorDevice;
    const auto availableResult = queryAlsaAvailabilityWithRecovery(
        static_cast<snd_pcm_sframes_t>(-EPIPE),
        static_cast<snd_pcm_sframes_t>(-ESTRPIPE),
        [this, &error, &recoveryError, &attemptedRecovery](int alsaError) {
            attemptedRecovery = true;
            recoveryError = recover(error, alsaError);
            return recoveryError == LazerAudioOk;
        },
        [pcm]() { return snd_pcm_avail_update(pcm); });
    if (!availableResult) return recoveryError;
    const snd_pcm_sframes_t available = *availableResult;
    if (available < 0) {
        error = alsaErrorText(attemptedRecovery
                ? "could not query ALSA writable frames after recovery"
                : "could not query ALSA writable frames",
            static_cast<int>(available));
        return LazerAudioErrorDevice;
    }
    const size_t hardwareFrames = static_cast<size_t>(bufferFrames_ -
        std::clamp<snd_pcm_sframes_t>(available, 0,
            static_cast<snd_pcm_sframes_t>(bufferFrames_)));
    const size_t submittedFrames = queuedBufferFrames(
        submittedBytes_, submittedOffsetFrames_, frameBytes_);
    if (submittedFrames > hardwareFrames) pruneSubmitted(submittedFrames - hardwareFrames);

    const size_t stagedFrames = queuedBufferFrames(stagedBytes_, stagedOffsetFrames_, frameBytes_);
    const size_t total = std::min<size_t>(
        static_cast<size_t>(bufferFrames_), hardwareFrames + stagedFrames);
    return static_cast<int32_t>(total);
}

void AlsaOutput::pruneSubmitted(size_t framesPlayed) {
    const size_t pending = queuedBufferFrames(submittedBytes_, submittedOffsetFrames_, frameBytes_);
    submittedOffsetFrames_ += std::min(framesPlayed, pending);
    compactQueue(submittedBytes_, submittedOffsetFrames_);
}

void AlsaOutput::compactQueue(std::vector<uint8_t> &queue, size_t &offsetFrames) {
    if (frameBytes_ <= 0 || offsetFrames == 0) return;
    const size_t offsetBytes = offsetFrames * static_cast<size_t>(frameBytes_);
    if (offsetBytes >= queue.size()) {
        queue.clear();
        offsetFrames = 0;
    } else if (offsetBytes >= queue.size() / 2) {
        queue.erase(queue.begin(), queue.begin() + static_cast<std::ptrdiff_t>(offsetBytes));
        offsetFrames = 0;
    }
}

void AlsaOutput::requeueSubmittedAtFront() {
    reconcileAlsaRecoveryQueues(
        AlsaRecoveryOutcome::SuspendPrepared,
        stagedBytes_, stagedOffsetFrames_,
        submittedBytes_, submittedOffsetFrames_,
        static_cast<size_t>(frameBytes_));
}

std::unique_ptr<AudioOutput> createPlatformAudioOutput() {
    return std::make_unique<AlsaOutput>();
}

}  // namespace lazer::audio
