#pragma once
#include "audio_output.h"
namespace lazer::audio {
std::unique_ptr<AudioOutput> createAndroidUsbAudioOutput();
std::unique_ptr<AudioOutput> routeAndroidAudioOutput(std::unique_ptr<AudioOutput> system);
}
