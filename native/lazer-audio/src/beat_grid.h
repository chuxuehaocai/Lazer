#ifndef LAZER_AUDIO_BEAT_GRID_H
#define LAZER_AUDIO_BEAT_GRID_H

#include <cstdint>

namespace lazer_audio {

/* Tempo and beat phase estimated from PCM.
 *
 * The reference player analyses 30 s windows with a model (Beat This) and gets a beat list per
 * track. The engine cannot carry a model, so this estimates the two facts its transition planner
 * actually consumes — how long a beat is and where the next one sits — with classic DSP: a
 * half-wave rectified onset envelope in the dB domain, its autocorrelation for the period, and a
 * phase search for the offset.
 *
 * A grid that is not confident enough is reported invalid, and the transition falls back to an
 * unaligned overlap: a wrong grid would move the mix onto a wrong beat, which is worse than no
 * alignment at all.
 *
 * Two honest limits, both of which the caller has to live with. The reported tempo can be a simple
 * multiple of the true one — most often 1.5x or 2x, since a pulse train correlates at those lags
 * too — so it is a grid spacing, not a BPM readout; every line still falls on a real beat, which is
 * what a transition needs. And it is estimated from a handful of seconds, where the reference
 * player analyses thirty with a model: it will not find a phrase, only the beat. */
struct BeatGrid {
    bool valid = false;
    int32_t sampleRate = 0;
    /* Beats per minute. 0 when the grid is invalid. */
    double bpm = 0.0;
    /* How pronounced the period was in the onset envelope, 0..1. */
    double confidence = 0.0;
    /* Phase anchor: the first beat at or after the analysed buffer's start. */
    int64_t firstBeatFrame = 0;

    /* Length of one beat in frames. */
    int64_t beatFrames() const;
    /* The next beat at or after `frame`, in the same timeline as the analysis. */
    int64_t nextBeatAtOrAfter(int64_t frame) const;
    /* How many beats fit between two frames, at least zero. */
    int64_t beatsBetween(int64_t from, int64_t to) const;
};

/* Estimates the grid from interleaved float PCM. `frames` should cover several seconds: the onset
 * autocorrelation needs a handful of beats to see a period at all. `channels` may be 1 or more; the
 * channels are averaged. */
BeatGrid estimateBeatGrid(
    const float *samples, int64_t frames, int32_t sampleRate, int32_t channels);

}  // namespace lazer_audio

#endif
