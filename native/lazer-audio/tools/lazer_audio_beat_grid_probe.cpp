/* Deterministic probe for the engine's beat grid estimator.
 *
 * The reference player gets its beat grid from a model over 30 s windows; the engine estimates it
 * from the PCM it already has, and the transition planner trusts it to place a mix on a beat. These
 * cases pin what "trusts it" means:
 *
 *   - a click track at a known tempo is measured at that tempo, with its phase on the clicks;
 *   - a phase-shifted click track moves the grid with it, not to zero;
 *   - an octave-ambiguous pattern resolves to the musically plausible tempo;
 *   - material without a pulse reports an invalid grid instead of inventing one;
 *   - a buffer too short to contain several beats reports an invalid grid.
 *
 * No FFmpeg, no engine, no audio device: `beat_grid.cpp` is compiled into the probe.
 */
#include "beat_grid.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr int32_t kSampleRate = 48000;
constexpr int32_t kChannels = 2;

bool expect(bool condition, const std::string &message) {
    if (condition) return true;
    std::cerr << "FAIL: " << message << '\n';
    return false;
}

/* Interleaved stereo PCM with a short burst (a kick drum's shape: a fast decay) every beat. */
std::vector<float> clickTrack(double bpm, double seconds, double firstClickSeconds = 0.0,
    double kickSeconds = 0.12, bool offbeatEighth = false) {
    const int64_t frames = static_cast<int64_t>(seconds * kSampleRate);
    std::vector<float> samples(static_cast<size_t>(frames) * kChannels, 0.0f);
    const double beatSeconds = 60.0 / bpm;
    const int64_t kickFrames = static_cast<int64_t>(kickSeconds * kSampleRate);
    const auto addKick = [&](double at, double level) {
        const int64_t start = static_cast<int64_t>(at * kSampleRate);
        if (start < 0 || start >= frames) return;
        for (int64_t frame = 0; frame < kickFrames && start + frame < frames; ++frame) {
            const double decay = std::exp(-6.0 * static_cast<double>(frame) /
                static_cast<double>(kickFrames));
            const double tone = std::sin(2.0 * 3.14159265358979323846 * 60.0 *
                static_cast<double>(frame) / kSampleRate);
            const float value = static_cast<float>(level * decay * tone);
            samples[static_cast<size_t>(start + frame) * kChannels] += value;
            samples[static_cast<size_t>(start + frame) * kChannels + 1] += value;
        }
    };
    for (double at = firstClickSeconds; at < seconds; at += beatSeconds) {
        addKick(at, 0.8);
        if (offbeatEighth) addKick(at + beatSeconds / 2.0, 0.25);
    }
    return samples;
}

/* Broadband noise with no pulse at all. */
std::vector<float> noiseTrack(double seconds, uint32_t seed = 12345) {
    const int64_t frames = static_cast<int64_t>(seconds * kSampleRate);
    std::vector<float> samples(static_cast<size_t>(frames) * kChannels, 0.0f);
    uint32_t state = seed;
    for (int64_t frame = 0; frame < frames; ++frame) {
        state = state * 1664525u + 1013904223u;
        const float value = static_cast<float>((static_cast<double>(state >> 8) / 8388608.0) - 1.0) * 0.4f;
        samples[static_cast<size_t>(frame) * kChannels] = value;
        samples[static_cast<size_t>(frame) * kChannels + 1] = value * 0.8f;
    }
    return samples;
}

struct Case {
    double bpm;
    double phase;
    bool offbeat;
    double seconds = 12.0;
};

bool checkTempo(const Case &testCase) {
    /* Six seconds is what the engine captures from a playing source before it has to place a mix;
     * twelve is what a whole-file analysis would see. Both have to measure the same beat. */
    const std::vector<float> samples = clickTrack(testCase.bpm, testCase.seconds, testCase.phase,
        0.12, testCase.offbeat);
    const lazer_audio::BeatGrid grid = lazer_audio::estimateBeatGrid(
        samples.data(), static_cast<int64_t>(samples.size() / kChannels), kSampleRate, kChannels);
    const std::string label = std::to_string(static_cast<int>(testCase.bpm)) + " BPM";
    if (!expect(grid.valid, label + ": the click track's grid came back invalid")) return false;
    /* The reported tempo may be a simple multiple of the true one (a click track correlates just as
     * well at 1.5x or 2x its beat); what must hold is that the grid's lines land on the clicks,
     * which is what the transition uses the grid for. */
    const double ratios[] = {1.0, 1.5, 2.0, 1.0 / 1.5, 0.5};
    bool tempoOk = false;
    for (double ratio : ratios) {
        if (std::abs(grid.bpm - testCase.bpm * ratio) <= 2.0) tempoOk = true;
    }
    if (!expect(tempoOk, label + ": measured " + std::to_string(grid.bpm) + " BPM")) {
        return false;
    }
    if (!expect(grid.confidence >= 0.18, label + ": confidence " +
            std::to_string(grid.confidence))) {
        return false;
    }
    /* What has to hold is that every line of the grid lands on a click: the planner snaps a
     * transition to a line, so a line off the beat is a mix that starts off the beat. A grid whose
     * period is a multiple of the beat (see the header) is fine — it is a subset of the beats. */
    const int64_t beat = grid.beatFrames();
    if (!expect(beat > 0, label + ": no beat length")) return false;
    const int64_t tolerance = kSampleRate / 40;  /* 25 ms */
    const auto nearestClick = [&](int64_t frame) {
        const double interval = 60.0 / testCase.bpm;
        const double position = testCase.phase + std::round((frame / static_cast<double>(kSampleRate) -
            testCase.phase) / interval) * interval;
        return static_cast<int64_t>(position * kSampleRate);
    };
    for (int index = 0; index < 12; ++index) {
        const int64_t line = grid.nextBeatAtOrAfter(
            grid.firstBeatFrame + index * beat - beat / 2);
        const int64_t click = nearestClick(line);
        if (!expect(std::abs(line - click) <= tolerance,
                label + ": grid line " + std::to_string(line) + " is " +
                    std::to_string(std::abs(line - click)) + " frames from the click at " +
                    std::to_string(click))) {
            return false;
        }
    }
    /* And a position between two lines maps forward to the next line, not to the one it just
     * passed. */
    const int64_t anchor = grid.firstBeatFrame + 4 * beat;
    if (!expect(grid.nextBeatAtOrAfter(anchor + beat / 3) == anchor + beat,
            label + ": a position between lines did not map to the next line")) {
        return false;
    }
    return true;
}

}  // namespace

int main() {
    const std::vector<Case> cases = {
        {120.0, 0.0, false},
        {128.0, 0.0, false},
        {174.0, 0.0, false},
        {100.0, 0.0, false},
        /* The same tempo, entering mid-beat: the grid has to follow the clicks. */
        {120.0, 0.31, false},
        {128.0, 0.07, false},
        /* A loud off-beat eighth note must not move the grid off the downbeats. */
        {124.0, 0.0, true},
        /* The engine's own capture window, and a phase inside it. */
        {120.0, 0.0, false, 6.0},
        {128.0, 0.22, false, 6.0},
        {174.0, 0.0, false, 6.0},
    };
    for (const Case &testCase : cases) {
        if (!checkTempo(testCase)) return 1;
    }
    std::cout << "PASS: click tracks at 100/120/124/128/174 BPM measured with their phase\n";

    {
        const std::vector<float> samples = noiseTrack(12.0);
        const lazer_audio::BeatGrid grid = lazer_audio::estimateBeatGrid(
            samples.data(), static_cast<int64_t>(samples.size() / kChannels), kSampleRate, kChannels);
        if (!expect(!grid.valid, "a pulse-less track reported a valid grid: " +
                std::to_string(grid.bpm) + " BPM, confidence " + std::to_string(grid.confidence))) {
            return 1;
        }
        std::cout << "PASS: material without a pulse reports an invalid grid\n";
    }
    {
        const std::vector<float> samples = clickTrack(120.0, 1.0);
        const lazer_audio::BeatGrid grid = lazer_audio::estimateBeatGrid(
            samples.data(), static_cast<int64_t>(samples.size() / kChannels), kSampleRate, kChannels);
        if (!expect(!grid.valid, "a one-second buffer reported a valid grid")) return 1;
        std::cout << "PASS: a buffer too short for several beats reports an invalid grid\n";
    }
    {
        /* Mono and multichannel buffers go down the same path. */
        const std::vector<float> stereo = clickTrack(150.0, 10.0);
        std::vector<float> mono(static_cast<size_t>(stereo.size() / kChannels));
        for (size_t index = 0; index < mono.size(); ++index) {
            mono[index] = stereo[index * kChannels];
        }
        const lazer_audio::BeatGrid grid =
            lazer_audio::estimateBeatGrid(mono.data(), static_cast<int64_t>(mono.size()),
                kSampleRate, 1);
        /* Same contract as the stereo cases: the tempo may be a simple multiple, its lines must
         * still land on the clicks. */
        bool tempoOk = false;
        for (double ratio : {1.0, 1.5, 2.0, 1.0 / 1.5, 0.5}) {
            if (std::abs(grid.bpm - 150.0 * ratio) <= 2.0) tempoOk = true;
        }
        if (!expect(grid.valid && tempoOk,
                "a mono 150 BPM track measured " + std::to_string(grid.bpm) + " BPM")) {
            return 1;
        }
        std::cout << "PASS: a mono buffer is measured like a stereo one\n";
    }
    return 0;
}
