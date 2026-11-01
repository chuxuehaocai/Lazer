/* AVAudioSession side of the iOS output backend. iOS builds only. */
#include "ios_audio_session.h"

#import <AVFoundation/AVFoundation.h>

#include <algorithm>
#include <cmath>
#include <atomic>
#include <mutex>

namespace lazer::audio {
namespace {

/* All notification flags and their revision are published together. The
 * observers live for the process, as does AVAudioSession.sharedInstance. They
 * never capture an AudioOutput, so teardown cannot race a dangling callback. */
constexpr uint64_t kInterrupted = 1;
constexpr uint64_t kServicesAvailable = 2;
constexpr uint64_t kMayResume = 4;
// Headphone removal needs an explicit play acknowledgement even if a later
// interruption-end notification grants ShouldResume before a producer polls.
constexpr uint64_t kRemovedHeadphones = 8;
constexpr uint64_t kRevisionStep = 16;
std::atomic<uint64_t> lifecycle{kServicesAvailable | kMayResume};

void changed(uint64_t set, uint64_t clear) {
    uint64_t previous = lifecycle.load(std::memory_order_relaxed);
    while (!lifecycle.compare_exchange_weak(previous,
        ((previous + kRevisionStep) | set) & ~clear,
        std::memory_order_release, std::memory_order_relaxed)) {}
}

void observeSession() {
    static std::once_flag once;
    std::call_once(once, [] {
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:nil
            usingBlock:^(NSNotification *notification) {
                const auto reason = static_cast<AVAudioSessionRouteChangeReason>(
                    [notification.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue]);
                // Never unexpectedly switch from headphones to the loudspeaker.
                const bool removed = reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable;
                changed(removed ? kRemovedHeadphones : 0, removed ? kMayResume : 0);
            }];
        [center addObserverForName:AVAudioEngineConfigurationChangeNotification object:nil queue:nil
            usingBlock:^(NSNotification *) { changed(0, 0); }];
        [center addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil
            usingBlock:^(NSNotification *notification) {
                const auto type = static_cast<AVAudioSessionInterruptionType>(
                    [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue]);
                if (type == AVAudioSessionInterruptionTypeBegan) {
                    changed(kInterrupted, 0);
                } else {
                    const auto options = [notification.userInfo[
                        AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
                    const bool resume = (options & AVAudioSessionInterruptionOptionShouldResume) != 0;
                    changed(resume ? kMayResume : 0,
                        kInterrupted | (resume ? 0 : kMayResume));
                }
            }];
        [center addObserverForName:AVAudioSessionMediaServicesWereLostNotification object:nil queue:nil
            usingBlock:^(NSNotification *) { changed(0, kServicesAvailable); }];
        [center addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil queue:nil
            usingBlock:^(NSNotification *) { changed(kServicesAvailable, 0); }];
    });
}

NSString *describe(NSError *failure) {
    if (failure == nil) return @"unknown error";
    return [NSString stringWithFormat:@"%@ (%@ %ld)", failure.localizedDescription,
            failure.domain, static_cast<long>(failure.code)];
}

/* The app configures the session from Dart. Only a category that cannot play
 * music at all is replaced, so the options the app chose (Bluetooth A2DP, and
 * whatever else `AudioSessionConfiguration.music()` selects) survive. */
bool categoryCanPlay(NSString *category) {
    return [category isEqualToString:AVAudioSessionCategoryPlayback] ||
        [category isEqualToString:AVAudioSessionCategoryPlayAndRecord] ||
        [category isEqualToString:AVAudioSessionCategoryMultiRoute];
}

}  // namespace

IosSessionState iosSessionState() noexcept {
    const auto value = lifecycle.load(std::memory_order_acquire);
    return {value / kRevisionStep, (value & kInterrupted) != 0,
        (value & kServicesAvailable) != 0,
        (value & kMayResume) != 0 && (value & kRemovedHeadphones) == 0};
}

void iosSessionRequestResume() noexcept {
    uint64_t previous = lifecycle.load(std::memory_order_relaxed);
    while (!lifecycle.compare_exchange_weak(previous,
        (previous | kMayResume) & ~kRemovedHeadphones,
        std::memory_order_release, std::memory_order_relaxed)) {}
}

int32_t iosSessionActivate(int32_t preferredSampleRate, int32_t bufferMillis,
    IosSessionInfo &info, std::string &error) {
    @autoreleasepool {
        info = IosSessionInfo{};
        error.clear();
        observeSession();
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if (session == nil) {
            error = "iOS audio session is unavailable";
            return LazerAudioErrorDevice;
        }

        NSError *failure = nil;
        if (!categoryCanPlay(session.category)) {
            if (![session setCategory:AVAudioSessionCategoryPlayback
                                 mode:AVAudioSessionModeDefault
                              options:0
                                error:&failure]) {
                error = std::string("iOS audio session category: ") +
                    describe(failure).UTF8String;
                return LazerAudioErrorDevice;
            }
        }

        // Both of these are requests: the route decides. Reading them back below is
        // what the engine is allowed to call a fact.
        if (preferredSampleRate > 0 &&
            std::fabs(session.sampleRate - static_cast<double>(preferredSampleRate)) > 0.5) {
            [session setPreferredSampleRate:static_cast<double>(preferredSampleRate) error:nil];
        }
        if (bufferMillis > 0 && std::fabs(session.preferredIOBufferDuration -
                static_cast<double>(bufferMillis) / 1000.0) > 0.000001) {
            [session setPreferredIOBufferDuration:static_cast<double>(bufferMillis) / 1000.0
                                            error:nil];
        }

        if (![session setActive:YES error:&failure]) {
            error = std::string("iOS audio session activation: ") +
                describe(failure).UTF8String;
            return LazerAudioErrorDevice;
        }

        const double rate = session.sampleRate;
        if (!(rate > 0.0)) {
            error = "iOS reported no output sample clock";
            [session setActive:NO withOptions:0 error:nil];
            return LazerAudioErrorDevice;
        }
        info.sampleRate = static_cast<int32_t>(std::llround(rate));
        const double ioSeconds = session.IOBufferDuration;
        if (ioSeconds > 0.0) {
            info.ioBufferFrames = static_cast<int32_t>(
                std::max<int64_t>(1, std::llround(ioSeconds * rate)));
        }
        const double latencySeconds = session.outputLatency;
        if (latencySeconds > 0.0) {
            info.outputLatencyFrames = static_cast<int32_t>(
                std::max<int64_t>(0, std::llround(latencySeconds * rate)));
        }
        AVAudioSessionPortDescription *output = session.currentRoute.outputs.firstObject;
        if (output != nil && output.portType != nil) {
            info.route = output.portType.UTF8String;
        } else {
            info.route = "unknown";
        }
        return LazerAudioOk;
    }
}

void iosSessionDeactivate() {
    @autoreleasepool {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if (session == nil) return;
        // NotifyOthersOnDeactivation hands the route back to whatever was playing
        // before, instead of leaving the app holding a silent session.
        [session setActive:NO
               withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                     error:nil];
    }
}

}  // namespace lazer::audio
