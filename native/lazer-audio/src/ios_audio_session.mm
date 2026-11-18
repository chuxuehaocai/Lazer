/* AVAudioSession side of the iOS output backend. iOS builds only. */
#include "ios_audio_session.h"

#import <AVFoundation/AVFoundation.h>

#include <algorithm>
#include <cmath>
#include <atomic>
#include <mutex>

namespace lazer::audio { void iosSessionObservedVolumeChanged() noexcept; }

/* outputVolume is KVO-observable. Keep the observer for the lifetime of the
 * shared session; it never captures an AudioOutput or touches its queue. */
@interface LazerIosAudioVolumeObserver : NSObject
@end
@implementation LazerIosAudioVolumeObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
    change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context {
    (void)object;
    (void)change;
    (void)context;
    if ([keyPath isEqualToString:@"outputVolume"]) {
        lazer::audio::iosSessionObservedVolumeChanged();
    }
}
@end

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
std::atomic<uint64_t> realtimeEpoch{0};

void changed(uint64_t set, uint64_t clear) {
    uint64_t previous = lifecycle.load(std::memory_order_relaxed);
    while (!lifecycle.compare_exchange_weak(previous,
        ((previous + kRevisionStep) | set) & ~clear,
        std::memory_order_release, std::memory_order_relaxed)) {}
    realtimeEpoch.fetch_add(1, std::memory_order_release);
}

void observeSession() {
    static std::once_flag once;
    std::call_once(once, [] {
        static LazerIosAudioVolumeObserver *volumeObserver =
            [[LazerIosAudioVolumeObserver alloc] init];
        [[AVAudioSession sharedInstance] addObserver:volumeObserver
            forKeyPath:@"outputVolume" options:0 context:nil];
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

void iosSessionObservedVolumeChanged() noexcept {
    realtimeEpoch.fetch_add(1, std::memory_order_release);
}

uint64_t iosSessionRealtimeRevision() noexcept {
    return realtimeEpoch.load(std::memory_order_acquire);
}

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
    IosSessionInfo &info, std::string &error, bool strictUsb) {
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
        const bool exactCategory = [session.category isEqualToString:AVAudioSessionCategoryPlayback] &&
            [session.mode isEqualToString:AVAudioSessionModeDefault] && session.categoryOptions == 0;
        if ((strictUsb && !exactCategory) || !categoryCanPlay(session.category)) {
            if (![session setCategory:AVAudioSessionCategoryPlayback
                                 mode:AVAudioSessionModeDefault
                              options:0
                                error:&failure]) {
                error = std::string("iOS audio session category: ") +
                    describe(failure).UTF8String;
                return LazerAudioErrorDevice;
            }
        }

        // Compare preferences to preferences: the current route can already run
        // at the requested rate while a stale preference still names the previous
        // track's clock. That stale value could take effect on the next USB route.
        // Both requests are hints; only the activated route values below are facts.
        if (preferredSampleRate > 0 &&
            std::fabs(session.preferredSampleRate - static_cast<double>(preferredSampleRate)) > 0.5) {
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

        info.revision = iosSessionRealtimeRevision();
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
        info.outputChannels = static_cast<int32_t>(session.outputNumberOfChannels);
        info.usbOnly = session.currentRoute.outputs.count == 1 &&
            [output.portType isEqualToString:AVAudioSessionPortUSBAudio];
        if (output.UID != nil) info.routeUid = output.UID.UTF8String;
        info.nonMixablePlayback =
            [session.category isEqualToString:AVAudioSessionCategoryPlayback] &&
            [session.mode isEqualToString:AVAudioSessionModeDefault] && session.categoryOptions == 0;
        // Never raise system volume. A user may change it, in which case the
        // KVO epoch immediately silences strict output until revalidation.
        info.unityVolume = session.outputVolume == 1.0f;
        if (strictUsb && info.revision != iosSessionRealtimeRevision()) {
            error = "iOS USB output changed during session validation; retry playback";
            [session setActive:NO
                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                         error:nil];
            return LazerAudioErrorDevice;
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
