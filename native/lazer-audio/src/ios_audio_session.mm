/* AVAudioSession side of the iOS output backend. iOS builds only. */
#include "ios_audio_session.h"

#import <AVFoundation/AVFoundation.h>

#include <cmath>

namespace lazer::audio {
namespace {

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

int32_t iosSessionActivate(int32_t preferredSampleRate, int32_t bufferMillis,
    IosSessionInfo &info, std::string &error) {
    info = IosSessionInfo{};
    error.clear();
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
    if (bufferMillis > 0) {
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

void iosSessionDeactivate() {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (session == nil) return;
    // NotifyOthersOnDeactivation hands the route back to whatever was playing
    // before, instead of leaving the app holding a silent session.
    [session setActive:NO
           withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                 error:nil];
}

}  // namespace lazer::audio
