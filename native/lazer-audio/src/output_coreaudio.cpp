#include "output_coreaudio.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <sys/types.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <bit>
#include <chrono>
#include <cstddef>
#include <cmath>
#include <cstring>
#include <iomanip>
#include <limits>
#include <sstream>
#include <thread>
#include <utility>

#include "coreaudio_format_policy.h"
#include "coreaudio_dop_carrier.h"
#include "coreaudio_drain_policy.h"

namespace lazer::audio {
namespace {

constexpr AudioObjectPropertyElement kMainElement = kAudioObjectPropertyElementMain;
constexpr int32_t kMaximumChannels = 2;

AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    return AudioObjectPropertyAddress{selector, scope, kMainElement};
}

std::string statusText(const char *operation, OSStatus status) {
    std::ostringstream text;
    text << operation << " failed (OSStatus 0x" << std::hex << std::uppercase
         << static_cast<uint32_t>(status) << ')';
    return text.str();
}

template <typename T>
bool getProperty(AudioObjectID object, AudioObjectPropertySelector selector,
    T &value, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    auto property = address(selector, scope);
    UInt32 size = static_cast<UInt32>(sizeof(T));
    return AudioObjectGetPropertyData(object, &property, 0, nullptr, &size, &value) == noErr &&
        size == sizeof(T);
}

template <typename T>
bool getPropertyArray(AudioObjectID object, AudioObjectPropertySelector selector,
    std::vector<T> &values, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    values.clear();
    auto property = address(selector, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(object, &property, 0, nullptr, &size) != noErr ||
        size == 0 || size % sizeof(T) != 0) return false;
    try {
        values.resize(size / sizeof(T));
    } catch (...) {
        return false;
    }
    return AudioObjectGetPropertyData(object, &property, 0, nullptr, &size,
        values.data()) == noErr && size % sizeof(T) == 0;
}

bool propertySettable(AudioObjectID object, AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    auto property = address(selector, scope);
    Boolean settable = false;
    return AudioObjectIsPropertySettable(object, &property, &settable) == noErr && settable;
}

bool setProperty(AudioObjectID object, AudioObjectPropertySelector selector,
    const void *value, UInt32 size,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    auto property = address(selector, scope);
    return AudioObjectSetPropertyData(object, &property, 0, nullptr, size, value) == noErr;
}

std::string cfStringUtf8(CFStringRef value) {
    if (value == nullptr) return {};
    const CFIndex maxSize = CFStringGetMaximumSizeForEncoding(CFStringGetLength(value),
        kCFStringEncodingUTF8) + 1;
    if (maxSize <= 0 || maxSize > std::numeric_limits<CFIndex>::max() - 1) return {};
    std::string result(static_cast<size_t>(maxSize), '\0');
    if (!CFStringGetCString(value, result.data(), maxSize, kCFStringEncodingUTF8)) return {};
    result.resize(std::strlen(result.c_str()));
    return result;
}

bool readCFStringProperty(AudioObjectID object, AudioObjectPropertySelector selector,
    std::string &result) {
    CFStringRef value = nullptr;
    if (!getProperty(object, selector, value)) return false;
    if (value == nullptr) return false;
    result = cfStringUtf8(value);
    CFRelease(value);
    return !result.empty();
}

bool readDeviceUID(AudioDeviceID device, std::string &uid) {
    return readCFStringProperty(device, kAudioDevicePropertyDeviceUID, uid);
}

bool readCurrentVirtualFormat(AudioStreamID stream, AudioStreamBasicDescription &format) {
    return getProperty(stream, kAudioStreamPropertyVirtualFormat, format);
}

bool readPhysicalFormat(AudioStreamID stream, AudioStreamBasicDescription &format) {
    return getProperty(stream, kAudioStreamPropertyPhysicalFormat, format);
}

bool isFloat(const AudioStreamBasicDescription &format) {
    return (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
}

bool isSignedInteger(const AudioStreamBasicDescription &format) {
    return (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
}

bool isInterleaved(const AudioStreamBasicDescription &format) {
    return (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0;
}

bool isLittleEndian(const AudioStreamBasicDescription &format) {
    const bool bigEndian = (format.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0;
    return !bigEndian;
}

int32_t sampleContainerBits(const AudioStreamBasicDescription &format) {
    const uint32_t channels = format.mChannelsPerFrame;
    if (channels == 0 || format.mBytesPerFrame == 0) return 0;
    const uint32_t bytesPerSample = isInterleaved(format)
        ? format.mBytesPerFrame / channels : format.mBytesPerFrame;
    if (isInterleaved(format) && format.mBytesPerFrame % channels != 0) return 0;
    if (bytesPerSample > static_cast<uint32_t>(std::numeric_limits<int32_t>::max() / 8)) return 0;
    return static_cast<int32_t>(bytesPerSample * 8);
}

bool normalizedTuple(const AudioStreamBasicDescription &format,
    const CoreAudioSampleRateRange &range, CoreAudioPcmStreamTuple &tuple) {
    if (format.mFormatID != kAudioFormatLinearPCM || format.mChannelsPerFrame == 0 ||
        format.mChannelsPerFrame > static_cast<UInt32>(kMaximumChannels) ||
        format.mBitsPerChannel > static_cast<UInt32>(std::numeric_limits<int32_t>::max())) return false;
    tuple = {};
    tuple.sampleRateRange = range;
    tuple.channels = static_cast<int32_t>(format.mChannelsPerFrame);
    tuple.interleaved = isInterleaved(format);
    tuple.littleEndian = isLittleEndian(format);
    tuple.packed = (format.mFormatFlags & kAudioFormatFlagIsPacked) != 0;
    tuple.alignedHigh = (format.mFormatFlags & kAudioFormatFlagIsAlignedHigh) != 0;
    tuple.nonMixable = (format.mFormatFlags & kAudioFormatFlagIsNonMixable) != 0;
    tuple.containerBitsPerSample = sampleContainerBits(format);
    tuple.bitsPerChannel = static_cast<int32_t>(format.mBitsPerChannel);
    tuple.encoding = coreAudioPcmEncodingFromFlags(isFloat(format), isSignedInteger(format));
    if (tuple.encoding == CoreAudioPcmEncoding::Unsupported) return false;
    return tuple.containerBitsPerSample > 0 && tuple.bitsPerChannel > 0;
}

bool rateRangeFor(const AudioStreamRangedDescription &description,
    CoreAudioSampleRateRange &range) {
    const AudioValueRange &reported = description.mSampleRateRange;
    if (description.mFormat.mSampleRate == kAudioStreamAnyRate) {
        range.minimumHz = reported.mMinimum;
        range.maximumHz = reported.mMaximum;
    } else if (std::isfinite(description.mFormat.mSampleRate) &&
        description.mFormat.mSampleRate > 0.0) {
        range.minimumHz = description.mFormat.mSampleRate;
        range.maximumHz = description.mFormat.mSampleRate;
    } else {
        return false;
    }
    return std::isfinite(range.minimumHz) && std::isfinite(range.maximumHz) &&
        range.minimumHz > 0.0 && range.maximumHz >= range.minimumHz;
}

struct StreamCandidate {
    AudioStreamID stream = kAudioObjectUnknown;
    AudioStreamBasicDescription format{};
    CoreAudioPcmStreamTuple tuple{};
};

bool readDeviceStreams(AudioDeviceID device, std::vector<AudioStreamID> &streams) {
    return getPropertyArray(device, kAudioDevicePropertyStreams, streams,
        kAudioDevicePropertyScopeOutput) && !streams.empty();
}

bool appendStreamCandidates(AudioStreamID stream, std::vector<StreamCandidate> &candidates,
    CoreAudioHalPcmCapabilities &capabilities) {
    std::vector<AudioStreamRangedDescription> ranges;
    if (getPropertyArray(stream, kAudioStreamPropertyAvailableVirtualFormats, ranges)) {
        for (const auto &description : ranges) {
            CoreAudioSampleRateRange rateRange{};
            if (!rateRangeFor(description, rateRange)) continue;
            CoreAudioPcmStreamTuple tuple{};
            if (!normalizedTuple(description.mFormat, rateRange, tuple)) continue;
            candidates.push_back(StreamCandidate{stream, description.mFormat, tuple});
            capabilities.streamTuples.push_back(tuple);
        }
        return !ranges.empty();
    }

    AudioStreamBasicDescription current{};
    if (!readCurrentVirtualFormat(stream, current) || current.mSampleRate <= 0.0) return false;
    CoreAudioSampleRateRange rateRange{current.mSampleRate, current.mSampleRate};
    CoreAudioPcmStreamTuple tuple{};
    if (!normalizedTuple(current, rateRange, tuple)) return false;
    candidates.push_back(StreamCandidate{stream, current, tuple});
    capabilities.streamTuples.push_back(tuple);
    return true;
}

bool equalRate(double left, int32_t right) {
    return std::isfinite(left) && std::abs(left - static_cast<double>(right)) < 0.5;
}

bool sameStreamFormat(const AudioStreamBasicDescription &left,
    const AudioStreamBasicDescription &right) {
    return left.mSampleRate == right.mSampleRate && left.mFormatID == right.mFormatID &&
        left.mFormatFlags == right.mFormatFlags && left.mBytesPerPacket == right.mBytesPerPacket &&
        left.mFramesPerPacket == right.mFramesPerPacket &&
        left.mBytesPerFrame == right.mBytesPerFrame &&
        left.mChannelsPerFrame == right.mChannelsPerFrame &&
        left.mBitsPerChannel == right.mBitsPerChannel;
}

bool candidateMatches(const StreamCandidate &candidate,
    const CoreAudioPcmEndpointTuple &endpoint) {
    int32_t bits = candidate.tuple.encoding == CoreAudioPcmEncoding::Float32
        ? 0 : candidate.tuple.bitsPerChannel;
    const double minimumRate = candidate.tuple.sampleRateRange.minimumHz;
    const double maximumRate = candidate.tuple.sampleRateRange.maximumHz;
    return endpoint.sampleRateHz >= minimumRate && endpoint.sampleRateHz <= maximumRate &&
        candidate.tuple.channels == endpoint.channels && bits == endpoint.bitsPerSample &&
        candidate.tuple.containerBitsPerSample == endpoint.containerBitsPerSample &&
        candidate.tuple.interleaved == endpoint.interleaved &&
        candidate.tuple.littleEndian == endpoint.littleEndian &&
        candidate.tuple.packed == endpoint.packed &&
        candidate.tuple.alignedHigh == endpoint.alignedHigh &&
        candidate.tuple.nonMixable == endpoint.nonMixable;
}

bool setAndReadNominalRate(AudioDeviceID device, int32_t requestedRate,
    double originalRate, double &actualRate, bool &writeApplied,
    double &selectedRate, bool &changedRate, std::string &error) {
    writeApplied = false;
    if (requestedRate <= 0) {
        error = "CoreAudio selected an invalid sample rate";
        return false;
    }
    double currentRate = 0.0;
    if (!getProperty(device, kAudioDevicePropertyNominalSampleRate, currentRate) ||
        !std::isfinite(currentRate) || currentRate <= 0.0) {
        error = "CoreAudio could not read the device nominal sample rate";
        return false;
    }
    if (std::abs(currentRate - requestedRate) < 0.5) {
        actualRate = currentRate;
        selectedRate = currentRate;
        changedRate = std::abs(originalRate - currentRate) >= 0.5;
        return true;
    }
    if (!propertySettable(device, kAudioDevicePropertyNominalSampleRate)) {
        error = "the selected CoreAudio device does not allow changing its nominal sample rate";
        return false;
    }
    const Float64 rate = static_cast<Float64>(requestedRate);
    if (!setProperty(device, kAudioDevicePropertyNominalSampleRate, &rate, sizeof(rate))) {
        error = "CoreAudio rejected the requested nominal sample rate";
        return false;
    }
    writeApplied = true;
    selectedRate = requestedRate;
    changedRate = std::abs(originalRate - requestedRate) >= 0.5;
    for (int attempt = 0; attempt < 50; ++attempt) {
        double observedRate = 0.0;
        if (getProperty(device, kAudioDevicePropertyNominalSampleRate, observedRate) &&
            std::isfinite(observedRate) && observedRate > 0.0) {
            actualRate = observedRate;
            selectedRate = observedRate;
            changedRate = std::abs(originalRate - observedRate) >= 0.5;
            if (std::abs(observedRate - requestedRate) < 0.5) return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    error = "CoreAudio did not read back the requested nominal sample rate";
    return false;
}

bool makeVirtualFormat(AudioStreamID stream, AudioStreamBasicDescription &format,
    std::string &error) {
    if (!propertySettable(stream, kAudioStreamPropertyVirtualFormat)) {
        error = "the selected CoreAudio output stream does not allow changing its virtual format";
        return false;
    }
    if (!setProperty(stream, kAudioStreamPropertyVirtualFormat, &format, sizeof(format))) {
        error = "CoreAudio rejected the selected output stream virtual format";
        return false;
    }
    AudioStreamBasicDescription readback{};
    if (!readCurrentVirtualFormat(stream, readback)) {
        error = "CoreAudio could not read back the selected output stream virtual format";
        return false;
    }
    format = readback;
    return true;
}

bool configureIoProcStreamUsage(AudioDeviceID device, AudioDeviceIOProcID ioProc,
    const std::vector<AudioStreamID> &streams, AudioStreamID selectedStream,
    std::string &error) {
    if (streams.size() <= 1) return true;
    if (streams.size() > std::numeric_limits<UInt32>::max() ||
        streams.size() > (std::numeric_limits<size_t>::max() -
            offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn)) / sizeof(UInt32)) {
        error = "CoreAudio returned an invalid output stream count";
        return false;
    }
    const size_t byteCount = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) +
        streams.size() * sizeof(UInt32);
    std::vector<uint64_t> storage((byteCount + sizeof(uint64_t) - 1) / sizeof(uint64_t), 0);
    auto *usage = reinterpret_cast<AudioHardwareIOProcStreamUsage *>(storage.data());
    // CoreAudio's variable-length property payload identifies its IOProc through
    // mIOProc, which is exposed as a raw pointer even though AudioDeviceIOProcID
    // is a function pointer. The HAL treats this value as an opaque IOProc token;
    // preserve its pointer representation without dereferencing it as data.
    static_assert(sizeof(usage->mIOProc) == sizeof(ioProc));
    usage->mIOProc = std::bit_cast<decltype(usage->mIOProc)>(ioProc);
    usage->mNumberStreams = static_cast<UInt32>(streams.size());
    bool foundStream = false;
    for (size_t index = 0; index < streams.size(); ++index) {
        usage->mStreamIsOn[index] = streams[index] == selectedStream ? 1U : 0U;
        foundStream = foundStream || streams[index] == selectedStream;
    }
    if (!foundStream) {
        error = "CoreAudio selected a stream that is no longer attached to the device";
        return false;
    }
    auto property = address(kAudioDevicePropertyIOProcStreamUsage,
        kAudioDevicePropertyScopeOutput);
    const OSStatus result = AudioObjectSetPropertyData(device, &property, 0, nullptr,
        static_cast<UInt32>(byteCount), usage);
    if (result != noErr) {
        error = statusText("setting AudioDeviceIOProc stream usage", result);
        return false;
    }
    return true;
}

bool formatMatchesEndpoint(const AudioStreamBasicDescription &format,
    const CoreAudioPcmEndpointTuple &endpoint) {
    CoreAudioSampleRateRange rate{format.mSampleRate, format.mSampleRate};
    CoreAudioPcmStreamTuple tuple{};
    if (!normalizedTuple(format, rate, tuple) || !equalRate(format.mSampleRate,
            endpoint.sampleRateHz)) return false;
    const int32_t bits = tuple.encoding == CoreAudioPcmEncoding::Float32
        ? 0 : tuple.bitsPerChannel;
    return tuple.channels == endpoint.channels && bits == endpoint.bitsPerSample &&
        tuple.containerBitsPerSample == endpoint.containerBitsPerSample &&
        tuple.interleaved == endpoint.interleaved && tuple.littleEndian == endpoint.littleEndian &&
        tuple.packed == endpoint.packed && tuple.alignedHigh == endpoint.alignedHigh &&
        tuple.nonMixable == endpoint.nonMixable;
}

bool exactDoPCarrierFormat(const AudioStreamBasicDescription &format,
    const CoreAudioPcmEndpointTuple &endpoint) {
    const UInt32 frameBytes = static_cast<UInt32>(endpoint.channels) * 3U;
    return formatMatchesEndpoint(format, endpoint) &&
        format.mFormatID == kAudioFormatLinearPCM &&
        std::abs(format.mSampleRate - static_cast<double>(endpoint.sampleRateHz)) < 0.001 &&
        format.mFramesPerPacket == 1 && format.mBytesPerFrame == frameBytes &&
        format.mBytesPerPacket == frameBytes;
}

bool isValidBitPerfectSource(const StreamDescription &source) {
    return !source.dsd && source.lossless && source.integerPcm &&
        source.canonicalChannelLayout && source.decoderFormatMatchesStream &&
        (source.channels == 1 || source.channels == 2) && source.sampleRate > 0 &&
        (source.bitsPerSample == 16 || source.bitsPerSample == 24 ||
            source.bitsPerSample == 32);
}

bool validCoreAudioDoPRequest(const AudioOutputRequest &request,
    const StreamDescription &source, std::string &error) {
    if (!request.exclusive || request.bitPerfect || !request.desired.doP) {
        error = "CoreAudio DoP requires Hog Mode and a DoP-only output request";
        return false;
    }
    if (!source.dsd || !source.rawDsd) {
        error = "CoreAudio DoP requires a raw DSD source; DST-decoded PCM cannot be wrapped";
        return false;
    }
    constexpr int32_t supportedMultipliers[] = {64, 128, 256, 512, 1024};
    const bool supportedMultiplier = std::find(std::begin(supportedMultipliers),
        std::end(supportedMultipliers), source.dsdRateMultiplier) !=
        std::end(supportedMultipliers);
    if (!supportedMultiplier || source.sampleRate <= 0 || (source.sampleRate & 1) != 0 ||
        static_cast<int64_t>(source.sampleRate) * 8 !=
            static_cast<int64_t>(44'100) * source.dsdRateMultiplier ||
        request.desired.sampleRate != source.sampleRate / 2) {
        error = "CoreAudio DoP carrier rate must be exactly half a supported raw DSD byte clock";
        return false;
    }
    if ((source.channels != 1 && source.channels != 2) ||
        request.desired.channels != source.channels) {
        error = "CoreAudio DoP supports only the exact mono or stereo source channel count";
        return false;
    }
    if (request.desired.bitsPerSample != 24 ||
        request.desired.containerBitsPerSample != 24) {
        error = "CoreAudio DoP requires packed 24-bit carrier frames";
        return false;
    }
    error.clear();
    return true;
}

}  // namespace

CoreAudioOutput::~CoreAudioOutput() {
    close();
}

int32_t CoreAudioOutput::open(const AudioOutputRequest &request,
    const StreamDescription &source, AudioOutputSession &session, std::string &error,
    LogProxy *log) {
    close();
    error.clear();

    if (request.requireNativeDsd || request.desired.nativeDsd) {
        error = "CoreAudio Native DSD is not implemented; use DoP or convert DSD to PCM";
        return LazerAudioErrorUnsupported;
    }
    if (request.requireDoP && !validCoreAudioDoPRequest(request, source, error)) {
        return LazerAudioErrorUnsupported;
    }
    if (!request.requireDoP && request.bitPerfect &&
        (!request.exclusive || !isValidBitPerfectSource(source))) {
        error = "CoreAudio bit-perfect output requires Hog Mode and mono/stereo lossless integer PCM at 16/24/32 bit";
        return LazerAudioErrorUnsupported;
    }
    if ((!request.requireDoP && request.desired.doP) ||
        request.desired.sampleRate <= 0 ||
        (request.desired.channels != 1 && request.desired.channels != 2)) {
        error = "CoreAudio HAL PCM output supports mono or stereo with a valid sample rate";
        return LazerAudioErrorUnsupported;
    }

    try {
        if (request.deviceId.empty()) {
            if (!getProperty(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice,
                    device_) || device_ == kAudioObjectUnknown) {
                error = "CoreAudio has no default output device";
                return LazerAudioErrorDevice;
            }
        } else {
            std::vector<AudioDeviceID> devices;
            if (!getPropertyArray(kAudioObjectSystemObject, kAudioHardwarePropertyDevices, devices)) {
                error = "CoreAudio could not enumerate output devices";
                return LazerAudioErrorDevice;
            }
            for (AudioDeviceID candidate : devices) {
                std::string uid;
                if (readDeviceUID(candidate, uid) && uid == request.deviceId) {
                    device_ = candidate;
                    break;
                }
            }
            if (device_ == kAudioObjectUnknown) {
                error = "the selected CoreAudio device UID is not present";
                return LazerAudioErrorDevice;
            }
        }

        std::vector<AudioStreamID> streams;
        if (!readDeviceStreams(device_, streams)) {
            error = "the selected CoreAudio device has no output streams";
            close();
            return LazerAudioErrorUnsupported;
        }

        double initialRate = 0.0;
        if (!getProperty(device_, kAudioDevicePropertyNominalSampleRate, initialRate) ||
            !std::isfinite(initialRate) || initialRate <= 0.0) {
            error = "CoreAudio could not read the output device sample rate";
            close();
            return LazerAudioErrorDevice;
        }
        originalNominalRate_ = initialRate;
        selectedNominalRate_ = initialRate;
        hostClockFrequency_ = AudioGetHostClockFrequency();

        CoreAudioHogOwnership hogOwnership = CoreAudioHogOwnership::Unknown;
        if (request.exclusive) {
            pid_t hogPid = -1;
            if (!getProperty(device_, kAudioDevicePropertyHogMode, hogPid)) {
                error = "CoreAudio Hog Mode is unavailable for the selected output device";
                close();
                return LazerAudioErrorUnsupported;
            }
            const pid_t processId = getpid();
            if (hogPid == processId) {
                error = "this process already owns CoreAudio Hog Mode for the selected device";
                close();
                return LazerAudioErrorDevice;
            }
            if (hogPid >= 0) {
                error = "another process currently owns CoreAudio Hog Mode for the selected device";
                close();
                return LazerAudioErrorDevice;
            }
            if (!propertySettable(device_, kAudioDevicePropertyHogMode) ||
                !setProperty(device_, kAudioDevicePropertyHogMode, &processId, sizeof(processId))) {
                error = "CoreAudio could not acquire Hog Mode for the selected output device";
                close();
                return LazerAudioErrorUnsupported;
            }
            /* The setter succeeded. Keep release responsibility even if the following readback
             * fails, but release only after checking that this process still owns Hog Mode. */
            ownsHog_ = true;
            pid_t confirmedPid = -1;
            if (!getProperty(device_, kAudioDevicePropertyHogMode, confirmedPid) ||
                confirmedPid != processId) {
                error = "CoreAudio did not confirm Hog Mode ownership";
                close();
                return LazerAudioErrorDevice;
            }
            hogOwnership = CoreAudioHogOwnership::OwnedByCurrentProcess;
        } else {
            pid_t hogPid = -1;
            if (getProperty(device_, kAudioDevicePropertyHogMode, hogPid)) {
                hogOwnership = hogPid < 0 ? CoreAudioHogOwnership::Unsupported
                    : CoreAudioHogOwnership::OwnedByAnotherProcess;
            }
        }

        CoreAudioHalPcmCapabilities capabilities{};
        capabilities.hogOwnership = hogOwnership;
        std::vector<AudioValueRange> nominalRanges;
        if (getPropertyArray(device_, kAudioDevicePropertyAvailableNominalSampleRates,
                nominalRanges)) {
            capabilities.nominalSampleRateRangesKnown = true;
            for (const auto &range : nominalRanges) {
                capabilities.nominalSampleRateRanges.push_back(
                    CoreAudioSampleRateRange{range.mMinimum, range.mMaximum});
            }
        }
        if (capabilities.nominalSampleRateRanges.empty()) {
            capabilities.nominalSampleRateRangesKnown = true;
            capabilities.nominalSampleRateRanges.push_back({initialRate, initialRate});
        }
        std::vector<StreamCandidate> candidates;
        capabilities.streamTuplesKnown = true;
        for (AudioStreamID stream : streams) {
            if (request.exclusive) {
                (void)appendStreamCandidates(stream, candidates, capabilities);
                continue;
            }
            /* Shared IOProcs must use the stream's existing virtual ASBD. Enumerating a device's
             * other available formats is not permission to change the format used by all clients. */
            AudioStreamBasicDescription current{};
            if (!readCurrentVirtualFormat(stream, current) || current.mSampleRate <= 0.0) continue;
            CoreAudioSampleRateRange rateRange{current.mSampleRate, current.mSampleRate};
            CoreAudioPcmStreamTuple tuple{};
            if (!normalizedTuple(current, rateRange, tuple)) continue;
            candidates.push_back(StreamCandidate{stream, current, tuple});
            capabilities.streamTuples.push_back(tuple);
        }
        if (!request.exclusive) {
            capabilities.nominalSampleRateRanges.clear();
            for (const auto &candidate : candidates) {
                capabilities.nominalSampleRateRanges.push_back(candidate.tuple.sampleRateRange);
            }
            capabilities.nominalSampleRateRangesKnown = true;
        }
        if (candidates.empty()) {
            error = "CoreAudio found no supported mono/stereo linear PCM output stream format";
            close();
            return LazerAudioErrorUnsupported;
        }

        TargetFormat desired = request.desired;
        if (request.bitPerfect) {
            desired.bitsPerSample = source.bitsPerSample;
            desired.containerBitsPerSample = source.bitsPerSample;
        } else if (desired.bitsPerSample != 0 && desired.bitsPerSample != 16 &&
            desired.bitsPerSample != 24 && desired.bitsPerSample != 32) {
            desired.bitsPerSample = 0;
            desired.containerBitsPerSample = 32;
        }
        CoreAudioPcmEndpointTuple selectedEndpoint{};
        bool exactPcmTuple = false;
        if (request.requireDoP) {
            const CoreAudioDoPDecision decision = negotiateCoreAudioDoPFormat(
                desired, capabilities, request.exclusive);
            if (!decision.accepted) {
                std::ostringstream message;
                message << "CoreAudio has no exact Hog Mode DoP carrier format for this stream (policy reason "
                        << static_cast<int32_t>(decision.reason) << ')';
                error = message.str();
                close();
                return LazerAudioErrorUnsupported;
            }
            selectedEndpoint = decision.endpoint;
        } else {
            const CoreAudioPcmDecision decision = negotiateCoreAudioPcmFormat(desired,
                capabilities, request.exclusive, request.bitPerfect);
            if (!decision.accepted()) {
                std::ostringstream message;
                message << "CoreAudio has no acceptable PCM format for the requested stream (policy reason "
                        << static_cast<int32_t>(decision.reason) << ')';
                error = message.str();
                close();
                return LazerAudioErrorUnsupported;
            }
            selectedEndpoint = decision.endpoint;
            exactPcmTuple = decision.kind == CoreAudioPcmDecisionKind::ExactPcmTuple;
        }

        auto selectedCandidate = std::find_if(candidates.begin(), candidates.end(),
            [&selectedEndpoint, &request](const StreamCandidate &candidate) {
                return candidateMatches(candidate, selectedEndpoint) &&
                    (!request.requireDoP || exactDoPCarrierFormat(candidate.format,
                        selectedEndpoint));
            });
        if (selectedCandidate == candidates.end()) {
            error = request.requireDoP
                ? "CoreAudio has no complete packed DoP ASBD for the selected carrier rate"
                : "CoreAudio format policy selected a stream tuple that is no longer available";
            close();
            return LazerAudioErrorDevice;
        }
        stream_ = selectedCandidate->stream;
        if (request.exclusive) {
            if (!readCurrentVirtualFormat(stream_, originalStreamFormat_)) {
                error = "CoreAudio could not read the original output stream virtual format";
                close();
                return LazerAudioErrorDevice;
            }
            hasOriginalStreamFormat_ = true;
        }

        double actualRate = 0.0;
        std::string rateError;
        bool rateWriteApplied = false;
        const bool nominalRateReady = request.exclusive
            ? setAndReadNominalRate(device_, selectedEndpoint.sampleRateHz,
                originalNominalRate_, actualRate, rateWriteApplied, selectedNominalRate_,
                changedNominalRate_, rateError)
            : (actualRate = selectedCandidate->format.mSampleRate, true);
        if (!nominalRateReady) {
            if (!rateWriteApplied && !request.bitPerfect && !request.requireDoP) {
                /* A rejected rate change is safe to fall back from only if the clock still reads
                 * its pre-open value. Re-negotiate against that single rate and convert in Engine. */
                double observedRate = 0.0;
                if (getProperty(device_, kAudioDevicePropertyNominalSampleRate, observedRate) &&
                    std::isfinite(observedRate) && std::abs(observedRate - initialRate) < 0.5) {
                    capabilities.nominalSampleRateRanges.assign(1,
                        CoreAudioSampleRateRange{initialRate, initialRate});
                    const CoreAudioPcmDecision fallback = negotiateCoreAudioPcmFormat(
                        desired, capabilities, true, false);
                    auto fallbackCandidate = std::find_if(candidates.begin(), candidates.end(),
                        [&fallback](const StreamCandidate &candidate) {
                            return fallback.accepted() && candidateMatches(candidate,
                                fallback.endpoint);
                    });
                    if (fallback.accepted() && fallbackCandidate != candidates.end()) {
                        selectedEndpoint = fallback.endpoint;
                        exactPcmTuple = fallback.kind ==
                            CoreAudioPcmDecisionKind::ExactPcmTuple;
                        selectedCandidate = fallbackCandidate;
                        stream_ = selectedCandidate->stream;
                        if (!readCurrentVirtualFormat(stream_, originalStreamFormat_)) {
                            error = "CoreAudio could not read the fallback output stream format";
                            close();
                            return LazerAudioErrorDevice;
                        }
                        hasOriginalStreamFormat_ = true;
                        hasSelectedStreamFormat_ = false;
                        changedStreamFormat_ = false;
                        actualRate = initialRate;
                        rateError.clear();
                    }
                }
            }
            if (!rateError.empty()) {
                if (request.exclusive) {
                    AudioStreamBasicDescription current{};
                    if (readCurrentVirtualFormat(stream_, current)) {
                        selectedStreamFormat_ = current;
                        hasSelectedStreamFormat_ = true;
                        changedStreamFormat_ = !sameStreamFormat(originalStreamFormat_, current);
                    }
                }
                error = rateError;
                close();
                return rateWriteApplied ? LazerAudioErrorDevice : LazerAudioErrorUnsupported;
            }
        }
        if (request.exclusive) {
            AudioStreamBasicDescription current{};
            if (!readCurrentVirtualFormat(stream_, current)) {
                error = "CoreAudio could not read the virtual format after changing the device rate";
                close();
                return LazerAudioErrorDevice;
            }
            selectedStreamFormat_ = current;
            hasSelectedStreamFormat_ = true;
            changedStreamFormat_ = !sameStreamFormat(originalStreamFormat_, current);
        } else {
            selectedNominalRate_ = initialRate;
            changedNominalRate_ = false;
        }
        AudioStreamBasicDescription requestedFormat = selectedCandidate->format;
        std::string virtualFormatError;
        bool setVirtualSucceeded = true;
        if (request.exclusive) {
            requestedFormat.mSampleRate = static_cast<Float64>(selectedEndpoint.sampleRateHz);
            setVirtualSucceeded = makeVirtualFormat(stream_, requestedFormat, virtualFormatError);
        }
        if (request.exclusive && !setVirtualSucceeded) {
            AudioStreamBasicDescription current{};
            if (readCurrentVirtualFormat(stream_, current)) {
                selectedStreamFormat_ = current;
                hasSelectedStreamFormat_ = true;
                changedStreamFormat_ = !sameStreamFormat(originalStreamFormat_, current);
            }
            if (request.bitPerfect || request.requireDoP) {
                error = virtualFormatError;
                close();
                return LazerAudioErrorUnsupported;
            }
        }

        AudioStreamBasicDescription readback{};
        if (!readCurrentVirtualFormat(stream_, readback) || readback.mSampleRate <= 0.0 ||
            readback.mChannelsPerFrame == 0 || readback.mChannelsPerFrame > kMaximumChannels) {
            error = "CoreAudio could not read back a usable virtual output format";
            close();
            return LazerAudioErrorDevice;
        }
        if (request.exclusive) {
            selectedStreamFormat_ = readback;
            hasSelectedStreamFormat_ = true;
            changedStreamFormat_ = !sameStreamFormat(originalStreamFormat_, readback);
        } else if (!sameStreamFormat(readback, selectedCandidate->format)) {
            error = "the shared CoreAudio stream format changed during negotiation";
            close();
            return LazerAudioErrorDevice;
        }
        streamFormat_ = readback;
        if (!request.exclusive) actualRate = readback.mSampleRate;
        CoreAudioSampleRateRange actualRange{readback.mSampleRate, readback.mSampleRate};
        CoreAudioPcmStreamTuple actualTuple{};
        if (!normalizedTuple(readback, actualRange, actualTuple)) {
            error = "CoreAudio selected an output format that is not supported PCM";
            close();
            return LazerAudioErrorUnsupported;
        }
        if ((request.bitPerfect || request.requireDoP) &&
            !formatMatchesEndpoint(readback, selectedEndpoint)) {
            error = request.requireDoP
                ? "CoreAudio virtual format readback did not exactly match the DoP carrier request"
                : "CoreAudio virtual format readback did not exactly match the bit-perfect request";
            close();
            return LazerAudioErrorUnsupported;
        }
        if (request.requireDoP && !exactDoPCarrierFormat(readback, selectedEndpoint)) {
            error = "CoreAudio virtual ASBD does not preserve complete packed DoP frames";
            close();
            return LazerAudioErrorUnsupported;
        }

        AudioStreamBasicDescription physical{};
        const bool physicalRead = readPhysicalFormat(stream_, physical);
        if (request.bitPerfect || request.requireDoP) {
            const bool physicalFormatMatches = request.requireDoP
                ? exactDoPCarrierFormat(physical, selectedEndpoint)
                : physicalRead && formatMatchesEndpoint(physical, selectedEndpoint);
            const bool rateMatches = request.requireDoP
                ? std::abs(actualRate - request.desired.sampleRate) < 0.001
                : equalRate(actualRate, request.desired.sampleRate);
            if (!physicalRead || !physicalFormatMatches || !rateMatches) {
                error = request.requireDoP
                    ? "CoreAudio DoP output refused: the physical carrier format and requested rate could not be verified exactly"
                    : "CoreAudio bit-perfect output refused: the physical stream format and requested rate could not be verified exactly";
                close();
                return LazerAudioErrorUnsupported;
            }
        }

        sampleBytes_ = sampleContainerBits(readback) / 8;
        interleaved_ = isInterleaved(readback);
        littleEndian_ = isLittleEndian(readback);
        if (sampleBytes_ <= 0 || sampleBytes_ > 4 ||
            readback.mChannelsPerFrame < 1 || readback.mChannelsPerFrame > kMaximumChannels) {
            error = "CoreAudio virtual PCM frame layout cannot be represented by the Engine";
            close();
            return LazerAudioErrorUnsupported;
        }
        if (request.requireDoP && (sampleBytes_ != 3 || !interleaved_ || !littleEndian_ ||
                !formatMatchesEndpoint(readback, selectedEndpoint))) {
            error = "CoreAudio DoP requires an exact interleaved little-endian packed PCM24 virtual format";
            close();
            return LazerAudioErrorUnsupported;
        }

        UInt32 periodFrames = 0;
        if (!getProperty(device_, kAudioDevicePropertyBufferFrameSize, periodFrames) ||
            periodFrames == 0) {
            error = "CoreAudio could not read the device buffer frame size";
            close();
            return LazerAudioErrorDevice;
        }
        bufferFrames_ = periodFrames;
        const bool deviceLatencyKnown = getProperty(device_, kAudioDevicePropertyLatency,
            outputLatencyFrames_, kAudioDevicePropertyScopeOutput);
        const bool streamLatencyKnown = getProperty(stream_, kAudioStreamPropertyLatency,
            streamLatencyFrames_);
        latencyMetadataKnown_ = deviceLatencyKnown && streamLatencyKnown;

        const int32_t boundedBufferMillis = std::clamp(request.bufferMillis, 60, 2000);
        const size_t desiredQueueFrames = static_cast<size_t>(std::max<int64_t>(
            static_cast<int64_t>(readback.mSampleRate * boundedBufferMillis / 1000.0),
            static_cast<int64_t>(periodFrames) * 3));
        const int32_t frameBytes = static_cast<int32_t>(sampleBytes_ * readback.mChannelsPerFrame);
        if (!queue_.configure(desiredQueueFrames, static_cast<size_t>(frameBytes))) {
            error = "could not allocate the CoreAudio PCM render queue";
            close();
            return LazerAudioErrorNoMemory;
        }

        const OSStatus createStatus = AudioDeviceCreateIOProcID(device_, &CoreAudioOutput::ioProc,
            this, &ioProcId_);
        if (createStatus != noErr || ioProcId_ == nullptr) {
            error = statusText("AudioDeviceCreateIOProcID", createStatus);
            close();
            return LazerAudioErrorDevice;
        }
        if (!configureIoProcStreamUsage(device_, ioProcId_, streams, stream_, error)) {
            close();
            return LazerAudioErrorDevice;
        }

        TargetFormat target{};
        target.sampleRate = static_cast<int32_t>(std::llround(readback.mSampleRate));
        target.channels = static_cast<int32_t>(readback.mChannelsPerFrame);
        target.bitsPerSample = actualTuple.encoding == CoreAudioPcmEncoding::Float32
            ? 0 : actualTuple.bitsPerChannel;
        target.containerBitsPerSample = actualTuple.containerBitsPerSample;
        target.doP = request.requireDoP;
        session.target = target;
        session.engineFormat = PcmFormat{target.sampleRate, target.channels};
        session.periodFrames = static_cast<int32_t>(periodFrames);
        session.bufferFrames = static_cast<int32_t>(periodFrames);
        session.writeMode = OutputWriteMode::Variable;
        session.queueDepthAvailable = true;
        session.primeBeforeStart = false;
        session.exclusive = ownsHog_;
        session.doP = request.requireDoP;
        session.coreAudioMixabilityKnown = true;
        session.coreAudioStreamNonMixable = actualTuple.nonMixable;
        const bool exactVirtualTuple = exactPcmTuple &&
            formatMatchesEndpoint(readback, selectedEndpoint);
        session.formatSelection = request.requireDoP
            ? LazerAudioFormatSelectionDoPCarrier
            : ownsHog_
                ? (exactVirtualTuple
                    ? LazerAudioFormatSelectionExclusiveSource
                    : LazerAudioFormatSelectionExclusiveMixFallback)
                : LazerAudioFormatSelectionSharedMix;

        std::ostringstream description;
        description << "CoreAudio HAL " << (ownsHog_ ? "Hog Mode" : "shared") << " / "
            << target.sampleRate << " Hz / "
            << (target.bitsPerSample == 0 ? 32 : target.bitsPerSample) << " bit / "
            << target.channels << " ch / "
            << (interleaved_ ? "interleaved" : "non-interleaved")
            << (request.requireDoP ? " virtual DoP carrier" : " virtual PCM");
        description << (actualTuple.nonMixable ? " / HAL non-mixable" : " / HAL mixable");
        if (physicalRead) {
            description << " / physical " << static_cast<int32_t>(std::llround(physical.mSampleRate))
                << " Hz / " << physical.mBitsPerChannel << " bit";
        }
        if (!littleEndian_) description << " / byte-swap";
        if (!ownsHog_) description << " / HAL and device DSP are not bypassed";
        if (!latencyMetadataKnown_) description << " / drain estimate adds one period (latency metadata unavailable)";
        session.description = description.str();
        session_ = session;
        log_ = log;
        callbackFailed_.store(false, std::memory_order_release);
        nextDoPMarker_ = 0x05;
        hasOutputSampleDeadline_.store(false, std::memory_order_release);
        hasOutputHostDeadline_.store(false, std::memory_order_release);
        if (log_ != nullptr) log_->write(LazerAudioLogInfo, session.description);
        error.clear();
        return LazerAudioOk;
    } catch (const std::bad_alloc &) {
        error = "not enough memory while preparing the CoreAudio output";
        close();
        return LazerAudioErrorNoMemory;
    } catch (...) {
        error = "unexpected failure while preparing the CoreAudio output";
        close();
        return LazerAudioErrorDevice;
    }
}

void CoreAudioOutput::close() {
    if (running_) {
        std::string ignored;
        (void)stop(ignored);
    }
    if (device_ != kAudioObjectUnknown && ioProcId_ != nullptr) {
        (void)AudioDeviceDestroyIOProcID(device_, ioProcId_);
        ioProcId_ = nullptr;
    }
    bool nominalRateRestored = false;
    if (changedNominalRate_ && device_ != kAudioObjectUnknown) {
        double currentRate = 0.0;
        if (getProperty(device_, kAudioDevicePropertyNominalSampleRate, currentRate) &&
            std::abs(currentRate - selectedNominalRate_) < 0.5) {
            const Float64 restoreRate = originalNominalRate_;
            nominalRateRestored = setProperty(device_, kAudioDevicePropertyNominalSampleRate,
                &restoreRate, sizeof(restoreRate));
        }
    }
    if (changedStreamFormat_ && stream_ != kAudioObjectUnknown &&
        hasOriginalStreamFormat_ && hasSelectedStreamFormat_) {
        AudioStreamBasicDescription current{};
        const auto snapshot = [](const AudioStreamBasicDescription &format) {
            return CoreAudioStreamFormatSnapshot{
                format.mSampleRate,
                format.mFormatID,
                format.mFormatFlags,
                format.mBytesPerPacket,
                format.mFramesPerPacket,
                format.mBytesPerFrame,
                format.mChannelsPerFrame,
                format.mBitsPerChannel,
                format.mReserved,
            };
        };
        if (readCurrentVirtualFormat(stream_, current) &&
            coreAudioStreamFormatMayRestore(snapshot(current), snapshot(selectedStreamFormat_),
                nominalRateRestored, originalNominalRate_) &&
            propertySettable(stream_, kAudioStreamPropertyVirtualFormat)) {
            (void)setProperty(stream_, kAudioStreamPropertyVirtualFormat,
                &originalStreamFormat_, sizeof(originalStreamFormat_));
        }
    }
    if (ownsHog_ && device_ != kAudioObjectUnknown) {
        pid_t currentPid = -1;
        if (getProperty(device_, kAudioDevicePropertyHogMode, currentPid) &&
            currentPid == getpid()) {
            const pid_t release = -1;
            (void)setProperty(device_, kAudioDevicePropertyHogMode, &release, sizeof(release));
        }
    }
    device_ = kAudioObjectUnknown;
    stream_ = kAudioObjectUnknown;
    streamFormat_ = {};
    originalStreamFormat_ = {};
    selectedStreamFormat_ = {};
    session_ = {};
    queue_.reset();
    log_ = nullptr;
    bufferFrames_ = 0;
    outputLatencyFrames_ = 0;
    streamLatencyFrames_ = 0;
    sampleBytes_ = 0;
    interleaved_ = true;
    littleEndian_ = true;
    ownsHog_ = false;
    changedNominalRate_ = false;
    hasOriginalStreamFormat_ = false;
    hasSelectedStreamFormat_ = false;
    changedStreamFormat_ = false;
    latencyMetadataKnown_ = false;
    running_.store(false, std::memory_order_release);
    nextDoPMarker_ = 0x05;
    originalNominalRate_ = 0.0;
    selectedNominalRate_ = 0.0;
    callbackFailed_.store(false, std::memory_order_release);
    ioProcCallbackSequence_.store(0, std::memory_order_release);
    callbackHealthState_.store(0, std::memory_order_release);
    lastObservedCallbackSequence_.store(0, std::memory_order_release);
    lastCallbackObservedMillis_.store(0, std::memory_order_release);
    lastIoProcHostTime_.store(0, std::memory_order_release);
    hasIoProcHostTime_.store(false, std::memory_order_release);
    callbackStallTimeoutMillis_.store(1000, std::memory_order_release);
    outputCallbacksInFlight_.store(0, std::memory_order_release);
    outputTimingUnknown_.store(false, std::memory_order_release);
    hasOutputSampleDeadline_.store(false, std::memory_order_release);
    hasOutputHostDeadline_.store(false, std::memory_order_release);
}

bool CoreAudioOutput::isOpen() const noexcept {
    return device_ != kAudioObjectUnknown && ioProcId_ != nullptr;
}

int32_t CoreAudioOutput::start(std::string &error) {
    if (!isOpen()) {
        error = "the CoreAudio output is not open";
        return LazerAudioErrorState;
    }
    if (running_) return LazerAudioOk;
    callbackHealthState_.store(0, std::memory_order_release);
    hasIoProcHostTime_.store(false, std::memory_order_release);
    callbackStallTimeoutMillis_.store(coreAudioCallbackStallTimeoutMillis(bufferFrames_,
        static_cast<uint64_t>(std::max(session_.target.sampleRate, 0))), std::memory_order_release);
    const OSStatus result = AudioDeviceStart(device_, ioProcId_);
    if (result != noErr) {
        error = statusText("AudioDeviceStart", result);
        return LazerAudioErrorDevice;
    }
    const auto startMillis = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    lastObservedCallbackSequence_.store(
        ioProcCallbackSequence_.load(std::memory_order_acquire), std::memory_order_release);
    lastCallbackObservedMillis_.store(startMillis < 0 ? 0 : static_cast<uint64_t>(startMillis),
        std::memory_order_release);
    running_.store(true, std::memory_order_release);
    callbackHealthState_.store(kCallbackHealthMonitoring, std::memory_order_release);
    error.clear();
    return LazerAudioOk;
}

int32_t CoreAudioOutput::stop(std::string &error) {
    if (!running_) {
        error.clear();
        return LazerAudioOk;
    }
    const uint8_t priorHealthState = callbackHealthState_.fetch_and(
        kCallbackHealthLost, std::memory_order_acq_rel);
    const OSStatus result = AudioDeviceStop(device_, ioProcId_);
    if (result != noErr) {
        if ((priorHealthState & kCallbackHealthMonitoring) != 0 &&
            (priorHealthState & kCallbackHealthLost) == 0) {
            callbackHealthState_.fetch_or(kCallbackHealthMonitoring, std::memory_order_release);
        }
        error = statusText("AudioDeviceStop", result);
        return LazerAudioErrorDevice;
    }
    running_.store(false, std::memory_order_release);
    error.clear();
    return LazerAudioOk;
}

int32_t CoreAudioOutput::reset(std::string &error) {
    if (!isOpen()) {
        error = "the CoreAudio output is not open";
        return LazerAudioErrorState;
    }
    if (running_) {
        const int32_t stopped = stop(error);
        if (stopped != LazerAudioOk) return stopped;
    }
    queue_.reset();
    hasOutputSampleDeadline_.store(false, std::memory_order_release);
    hasOutputHostDeadline_.store(false, std::memory_order_release);
    callbackFailed_.store(false, std::memory_order_release);
    callbackHealthState_.store(0, std::memory_order_release);
    lastObservedCallbackSequence_.store(0, std::memory_order_release);
    lastCallbackObservedMillis_.store(0, std::memory_order_release);
    lastIoProcHostTime_.store(0, std::memory_order_release);
    hasIoProcHostTime_.store(false, std::memory_order_release);
    outputTimingUnknown_.store(false, std::memory_order_release);
    error.clear();
    return LazerAudioOk;
}

OutputWaitResult CoreAudioOutput::waitForReady(int32_t timeoutMillis, std::string &error) {
    if (!isOpen()) {
        error = "the CoreAudio output is not open";
        return OutputWaitResult::Error;
    }
    const auto deadline = std::chrono::steady_clock::now() +
        std::chrono::milliseconds(std::max(timeoutMillis, 0));
    do {
        if (callbackFailed_.load(std::memory_order_acquire)) {
            error = "the CoreAudio IOProc received an unsupported output buffer layout";
            return OutputWaitResult::Error;
        }
        const uint8_t healthState = callbackHealthState_.load(std::memory_order_acquire);
        if ((healthState & kCallbackHealthLost) != 0) {
            error = "CoreAudio stopped delivering IOProc callbacks";
            return OutputWaitResult::Error;
        }
        const auto now = std::chrono::steady_clock::now();
        if ((healthState & kCallbackHealthMonitoring) != 0) {
            const uint64_t callbackSequence = ioProcCallbackSequence_.load(
                std::memory_order_acquire);
            const bool usedHostTime = hasIoProcHostTime_.load(std::memory_order_acquire) &&
                hostClockFrequency_ > 0.0;
            bool stale = false;
            if (usedHostTime) {
                stale = coreAudioCallbackHostTimeIsStale(true, false,
                    AudioGetCurrentHostTime(), lastIoProcHostTime_.load(std::memory_order_acquire),
                    hostClockFrequency_,
                    callbackStallTimeoutMillis_.load(std::memory_order_acquire));
            } else {
                const uint64_t lastObservedSequence = lastObservedCallbackSequence_.exchange(
                    callbackSequence, std::memory_order_acq_rel);
                const auto nowMillisSigned = std::chrono::duration_cast<std::chrono::milliseconds>(
                    now.time_since_epoch()).count();
                const uint64_t nowMillis = nowMillisSigned < 0 ? 0
                    : static_cast<uint64_t>(nowMillisSigned);
                if (callbackSequence != lastObservedSequence) {
                    lastCallbackObservedMillis_.store(nowMillis, std::memory_order_release);
                }
                stale = coreAudioCallbackIsStale(true, false, nowMillis,
                    lastCallbackObservedMillis_.load(std::memory_order_acquire),
                    callbackStallTimeoutMillis_.load(std::memory_order_acquire));
            }
            if (stale) {
                uint8_t expected = kCallbackHealthMonitoring;
                if (callbackHealthState_.compare_exchange_strong(expected,
                        kCallbackHealthMonitoring | kCallbackHealthLost,
                        std::memory_order_acq_rel, std::memory_order_acquire)) {
                    bool callbackProgress = ioProcCallbackSequence_.load(
                        std::memory_order_acquire) != callbackSequence;
                    if (!callbackProgress && usedHostTime &&
                        hasIoProcHostTime_.load(std::memory_order_acquire) &&
                        hostClockFrequency_ > 0.0) {
                        callbackProgress = !coreAudioCallbackHostTimeIsStale(true, false,
                            AudioGetCurrentHostTime(),
                            lastIoProcHostTime_.load(std::memory_order_acquire),
                            hostClockFrequency_,
                            callbackStallTimeoutMillis_.load(std::memory_order_acquire));
                    } else if (!callbackProgress) {
                        const auto recheckNow = std::chrono::steady_clock::now();
                        const auto recheckMillisSigned =
                            std::chrono::duration_cast<std::chrono::milliseconds>(
                                recheckNow.time_since_epoch()).count();
                        const uint64_t recheckMillis = recheckMillisSigned < 0 ? 0
                            : static_cast<uint64_t>(recheckMillisSigned);
                        const uint64_t sequenceNow = ioProcCallbackSequence_.load(
                            std::memory_order_acquire);
                        const uint64_t previouslyObservedSequence =
                            lastObservedCallbackSequence_.exchange(sequenceNow,
                                std::memory_order_acq_rel);
                        if (sequenceNow != previouslyObservedSequence) {
                            lastCallbackObservedMillis_.store(recheckMillis,
                                std::memory_order_release);
                            callbackProgress = true;
                        } else {
                            callbackProgress = !coreAudioCallbackIsStale(true, false,
                                recheckMillis,
                                lastCallbackObservedMillis_.load(std::memory_order_acquire),
                                callbackStallTimeoutMillis_.load(std::memory_order_acquire));
                        }
                    }
                    if (!callbackProgress &&
                        ioProcCallbackSequence_.load(std::memory_order_acquire) !=
                            callbackSequence) {
                        callbackProgress = true;
                    }
                    if (callbackProgress) {
                        uint8_t lostState = kCallbackHealthMonitoring | kCallbackHealthLost;
                        (void)callbackHealthState_.compare_exchange_strong(lostState,
                            kCallbackHealthMonitoring, std::memory_order_acq_rel,
                            std::memory_order_acquire);
                    }
                }
                if ((callbackHealthState_.load(std::memory_order_acquire) &
                        kCallbackHealthLost) != 0) {
                    error = "CoreAudio stopped delivering IOProc callbacks";
                    return OutputWaitResult::Error;
                }
            }
        }
        if (queue_.writableFrames() > 0) {
            error.clear();
            return OutputWaitResult::Ready;
        }
        if (std::chrono::steady_clock::now() >= deadline) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    } while (true);
    error.clear();
    return OutputWaitResult::Timeout;
}

int32_t CoreAudioOutput::writableFrames(std::string &error) {
    if (!isOpen()) {
        error = "the CoreAudio output is not open";
        return LazerAudioErrorState;
    }
    if (callbackFailed_.load(std::memory_order_acquire)) {
        error = "the CoreAudio IOProc received an unsupported output buffer layout";
        return LazerAudioErrorDevice;
    }
    error.clear();
    return static_cast<int32_t>(std::min<size_t>(queue_.writableFrames(),
        static_cast<size_t>(std::numeric_limits<int32_t>::max())));
}

int32_t CoreAudioOutput::queuedFrames(std::string &error) {
    if (!isOpen()) {
        error = "the CoreAudio output is not open";
        return LazerAudioErrorState;
    }
    if (callbackFailed_.load(std::memory_order_acquire)) {
        error = "the CoreAudio IOProc received an unsupported output buffer layout";
        return LazerAudioErrorDevice;
    }
    const uint64_t queued = queue_.queuedFrames();
    const bool callbackInFlight = outputCallbacksInFlight_.load(std::memory_order_acquire) != 0;
    const bool hasSampleDeadline = hasOutputSampleDeadline_.load(std::memory_order_acquire);
    const bool hasHostDeadline = hasOutputHostDeadline_.load(std::memory_order_acquire);
    const bool hasSubmittedTail = hasSampleDeadline || hasHostDeadline;
    bool clockEvidenceAvailable = false;
    uint64_t framesUntilDeadline = 0;
    if (running_ && stream_ != kAudioObjectUnknown &&
        (callbackInFlight || hasSubmittedTail)) {
        AudioTimeStamp current{};
        if (AudioDeviceGetCurrentTime(device_, &current) == noErr) {
            if ((current.mFlags & kAudioTimeStampSampleTimeValid) != 0 && hasSampleDeadline) {
                const double sampleNow = std::max(0.0, current.mSampleTime);
                const uint64_t deadline = lastOutputSampleDeadline_.load(
                    std::memory_order_acquire);
                clockEvidenceAvailable = true;
                if (static_cast<double>(deadline) > sampleNow) {
                    framesUntilDeadline = static_cast<uint64_t>(std::ceil(deadline - sampleNow));
                }
            } else if ((current.mFlags & kAudioTimeStampHostTimeValid) != 0 && hasHostDeadline &&
                hostClockFrequency_ > 0.0) {
                const uint64_t deadline = lastOutputHostDeadline_.load(
                    std::memory_order_acquire);
                clockEvidenceAvailable = true;
                if (deadline > current.mHostTime && hostClockFrequency_ > 0.0) {
                    const double frames = static_cast<double>(deadline - current.mHostTime) *
                        session_.target.sampleRate / hostClockFrequency_;
                    framesUntilDeadline = static_cast<uint64_t>(
                        std::ceil(std::max(0.0, frames)));
                }
            }
        }
    }
    const uint64_t pending = coreAudioPendingFrames(queued, callbackInFlight,
        hasSubmittedTail || outputTimingUnknown_.load(std::memory_order_acquire),
        clockEvidenceAvailable, framesUntilDeadline, bufferFrames_);
    error.clear();
    return static_cast<int32_t>(std::min<uint64_t>(pending,
        static_cast<uint64_t>(std::numeric_limits<int32_t>::max())));
}

OutputDrainResult CoreAudioOutput::drain(std::string &error) {
    const int32_t queued = queuedFrames(error);
    if (queued < 0) return OutputDrainResult::Error;
    return queued == 0 ? OutputDrainResult::Drained : OutputDrainResult::Pending;
}

int32_t CoreAudioOutput::write(const uint8_t *bytes, int32_t frameCount,
    std::string &error) {
    if (!isOpen()) {
        error = "the CoreAudio output is not open";
        return LazerAudioErrorState;
    }
    if (bytes == nullptr || frameCount < 0) {
        error = "CoreAudio received an invalid PCM write";
        return LazerAudioErrorInvalidArgument;
    }
    if (callbackFailed_.load(std::memory_order_acquire)) {
        error = "the CoreAudio IOProc received an unsupported output buffer layout";
        return LazerAudioErrorDevice;
    }
    const int32_t written = queue_.write(bytes, frameCount);
    if (written < 0) {
        error = "CoreAudio could not enqueue the PCM frames";
        return LazerAudioErrorDevice;
    }
    error.clear();
    return written;
}

OSStatus CoreAudioOutput::ioProc(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime, AudioBufferList *output,
    const AudioTimeStamp *outputTime, void *clientData) {
    (void)device;
    (void)input;
    (void)inputTime;
    auto *self = static_cast<CoreAudioOutput *>(clientData);
    if (self == nullptr) return noErr;
    self->outputCallbacksInFlight_.fetch_add(1, std::memory_order_acq_rel);
    struct InFlightReset {
        std::atomic<uint32_t> &count;
        ~InFlightReset() { count.fetch_sub(1, std::memory_order_release); }
    } inFlightReset{self->outputCallbacksInFlight_};
    if (now != nullptr && (now->mFlags & kAudioTimeStampHostTimeValid) != 0 &&
        now->mHostTime != 0) {
        self->lastIoProcHostTime_.store(now->mHostTime, std::memory_order_relaxed);
        self->hasIoProcHostTime_.store(true, std::memory_order_release);
    } else {
        self->hasIoProcHostTime_.store(false, std::memory_order_release);
    }
    self->ioProcCallbackSequence_.fetch_add(1, std::memory_order_release);
    return self->render(outputTime, output);
}

OSStatus CoreAudioOutput::render(const AudioTimeStamp *outputTime,
    AudioBufferList *output) noexcept {
    if (output == nullptr) {
        callbackFailed_.store(true, std::memory_order_release);
        return noErr;
    }
    /* HAL documents that these buffers are zeroed on entry, but clear them explicitly as a
     * fail-closed underrun path: any bytes not overwritten below remain silence. */
    for (UInt32 index = 0; index < output->mNumberBuffers; ++index) {
        AudioBuffer &buffer = output->mBuffers[index];
        if (buffer.mData != nullptr && buffer.mDataByteSize > 0) {
            std::memset(buffer.mData, 0, buffer.mDataByteSize);
        }
    }
    if (output->mNumberBuffers == 0 || output->mNumberBuffers > 128) {
        callbackFailed_.store(true, std::memory_order_release);
        return noErr;
    }
    std::array<uint8_t *, 2> destinations{};
    std::array<size_t, 2> capacities{};
    size_t destinationCount = 0;
    for (UInt32 index = 0; index < output->mNumberBuffers; ++index) {
        AudioBuffer &buffer = output->mBuffers[index];
        /* HAL leaves disabled streams in the buffer list with a null mData pointer. */
        if (buffer.mData == nullptr) continue;
        if (destinationCount >= destinations.size()) {
            callbackFailed_.store(true, std::memory_order_release);
            return noErr;
        }
        destinations[destinationCount] = static_cast<uint8_t *>(buffer.mData);
        capacities[destinationCount] = buffer.mDataByteSize;
        if (interleaved_) {
            if (buffer.mNumberChannels != static_cast<UInt32>(session_.target.channels)) {
                callbackFailed_.store(true, std::memory_order_release);
                return noErr;
            }
        } else if (buffer.mNumberChannels != 1) {
            callbackFailed_.store(true, std::memory_order_release);
            return noErr;
        }
        ++destinationCount;
    }
    if (destinationCount != (interleaved_ ? 1U :
            static_cast<size_t>(session_.target.channels))) {
        callbackFailed_.store(true, std::memory_order_release);
        return noErr;
    }

    const size_t frameBytes = static_cast<size_t>(sampleBytes_) *
        static_cast<size_t>(session_.target.channels);
    size_t maximumFrames = capacities[0] / (interleaved_ ? frameBytes
        : static_cast<size_t>(sampleBytes_));
    if (!interleaved_) {
        for (size_t index = 1; index < destinationCount; ++index) {
            maximumFrames = std::min(maximumFrames,
                capacities[index] / static_cast<size_t>(sampleBytes_));
        }
    }
    const int32_t frameLimit = static_cast<int32_t>(std::min<size_t>(maximumFrames,
        static_cast<size_t>(std::numeric_limits<int32_t>::max())));
    int32_t copied = 0;
    if (session_.doP) {
        if (!interleaved_ || !littleEndian_ || sampleBytes_ != 3 || destinationCount != 1 ||
            session_.target.frameBytes() <= 0 ||
            capacities[0] % static_cast<size_t>(session_.target.frameBytes()) != 0) {
            callbackFailed_.store(true, std::memory_order_release);
            return noErr;
        }
        copied = queue_.readInterleavedBytes(destinations[0], capacities[0],
            static_cast<size_t>(frameLimit));
        if (copied >= 0 && !prepareCoreAudioDoPCarrier(destinations[0],
                static_cast<size_t>(frameLimit), static_cast<size_t>(copied),
                session_.target.channels, nextDoPMarker_)) {
            callbackFailed_.store(true, std::memory_order_release);
            return noErr;
        }
    } else {
        copied = queue_.readToBuffers(destinations.data(), capacities.data(),
            destinationCount, interleaved_, session_.target.channels, sampleBytes_,
            littleEndian_, frameLimit);
    }
    if (copied < 0) {
        callbackFailed_.store(true, std::memory_order_release);
        return noErr;
    }

    if (copied > 0 && outputTime != nullptr) {
        const uint64_t tailFrames = static_cast<uint64_t>(outputLatencyFrames_) +
            streamLatencyFrames_ + (latencyMetadataKnown_ ? 0U : bufferFrames_);
        bool deadlinePublished = false;
        if ((outputTime->mFlags & kAudioTimeStampSampleTimeValid) != 0 &&
            std::isfinite(outputTime->mSampleTime) && outputTime->mSampleTime >= 0.0) {
            const double endSample = outputTime->mSampleTime + copied + tailFrames;
            if (endSample >= 0.0 && endSample <=
                static_cast<double>(std::numeric_limits<uint64_t>::max())) {
                lastOutputSampleDeadline_.store(static_cast<uint64_t>(std::ceil(endSample)),
                    std::memory_order_release);
                hasOutputSampleDeadline_.store(true, std::memory_order_release);
                deadlinePublished = true;
            }
        }
        if ((outputTime->mFlags & kAudioTimeStampHostTimeValid) != 0 &&
            hostClockFrequency_ > 0.0 && session_.target.sampleRate > 0) {
            const double frameCount = static_cast<double>(copied + tailFrames);
            const double ticks = frameCount * hostClockFrequency_ / session_.target.sampleRate;
            if (std::isfinite(ticks) && ticks >= 0.0 &&
                ticks < static_cast<double>(std::numeric_limits<uint64_t>::max() -
                    outputTime->mHostTime)) {
                lastOutputHostDeadline_.store(outputTime->mHostTime +
                    static_cast<uint64_t>(std::ceil(ticks)), std::memory_order_release);
                hasOutputHostDeadline_.store(true, std::memory_order_release);
                deadlinePublished = true;
            }
        }
        outputTimingUnknown_.store(!deadlinePublished, std::memory_order_release);
        if (!deadlinePublished) callbackFailed_.store(true, std::memory_order_release);
    } else if (copied > 0) {
        outputTimingUnknown_.store(true, std::memory_order_release);
        callbackFailed_.store(true, std::memory_order_release);
    }
    return noErr;
}

std::unique_ptr<AudioOutput> createPlatformAudioOutput() {
    return std::make_unique<CoreAudioOutput>();
}

}  // namespace lazer::audio
