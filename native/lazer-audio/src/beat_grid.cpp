#include "beat_grid.h"

#include <algorithm>
#include <cmath>
#include <vector>

namespace lazer_audio {
namespace {

/* Analysis frame and hop. 1024 samples is about 23 ms at 44.1 kHz, which resolves a kick drum's
 * attack; the hop is half of it, so a beat position is known to about 12 ms. */
constexpr int32_t kFrameSize = 1024;
constexpr int32_t kHop = 512;
/* The tempo range the estimator considers, and the tempo it prefers when the autocorrelation cannot
 * tell an octave apart — the reference player folds its candidates into 55..300 BPM too. */
constexpr double kMinBpm = 60.0;
constexpr double kMaxBpm = 200.0;
constexpr double kPreferredBpm = 120.0;
/* Wide on purpose: the preference only breaks ties between tempos that are equally plausible, it
 * must not decide an octave. */
constexpr double kOctaveWidth = 2.0;
/* Of the equally plausible periods, take the shortest one: a click track correlates just as well at
 * twice its beat as at its beat, and the shorter grid is the one that lines up with every click. */
constexpr double kCombTolerance = 0.9;
/* How far around a plausible lag the comb may move the period, and in what steps. */
constexpr double kPeriodRefineHops = 1.5;
constexpr double kPeriodRefineStep = 0.02;
/* How many plausible periods are refined as combs. */
constexpr size_t kMaxCandidates = 8;
/* The grid has to explain a clear majority of the onset energy, not merely beat an average phase
 * class by luck: a four-on-the-floor track scores near 1, broadband material without a pulse scores
 * around 0.2, and anything below this is reported invalid. */
constexpr double kMinConfidence = 0.6;
/* A beat needs at least this much of the analysed audio behind it to be measurable at all. */
constexpr int64_t kMinAnalysedFrames = 2000;
/* Anything quieter than this is silence. The onset envelope differences dB levels, so the floor has
 * to be finite: with negative infinity every attack out of silence would look equally loud and the
 * envelope would lose the very dynamics that tell a downbeat from a ghost note. */
constexpr double kSilenceDb = -60.0;

double beatSeconds(double bpm) { return 60.0 / bpm; }

}  // namespace

int64_t BeatGrid::beatFrames() const {
    if (!valid || sampleRate <= 0 || bpm <= 0.0) return 0;
    return std::max<int64_t>(1, static_cast<int64_t>(std::llround(beatSeconds(bpm) * sampleRate)));
}

int64_t BeatGrid::nextBeatAtOrAfter(int64_t frame) const {
    const int64_t beat = beatFrames();
    if (beat <= 0) return frame;
    /* The anchor is periodic, not a starting point: a position before it maps to the beat the grid
     * would have placed there, which is what lets a caller align audio that begins earlier than the
     * analysed window. */
    const int64_t delta = frame - firstBeatFrame;
    const int64_t beats = delta >= 0 ? (delta + beat - 1) / beat : -((-delta) / beat);
    return firstBeatFrame + beats * beat;
}

int64_t BeatGrid::beatsBetween(int64_t from, int64_t to) const {
    const int64_t beat = beatFrames();
    if (beat <= 0 || to <= from) return 0;
    return (to - from) / beat;
}

BeatGrid estimateBeatGrid(
    const float *samples, int64_t frames, int32_t sampleRate, int32_t channels) {
    BeatGrid grid;
    grid.sampleRate = sampleRate;
    if (samples == nullptr || sampleRate <= 0 || channels <= 0 || frames < kMinAnalysedFrames) {
        return grid;
    }

    /* Onset envelope: the frame energy in dB, half-wave rectified against the previous frame. A dB
     * domain difference is what keeps a quiet passage's attacks as visible as a loud one's. */
    const int64_t frameCount = (frames - kFrameSize) / kHop + 1;
    if (frameCount < 8) return grid;
    std::vector<double> onset(static_cast<size_t>(frameCount), 0.0);
    double previousDb = kSilenceDb;
    for (int64_t index = 0; index < frameCount; ++index) {
        const int64_t start = index * kHop;
        double energy = 0.0;
        for (int64_t frame = 0; frame < kFrameSize; ++frame) {
            const float *source = samples + (start + frame) * channels;
            double mono = 0.0;
            for (int32_t channel = 0; channel < channels; ++channel) mono += source[channel];
            mono /= channels;
            energy += mono * mono;
        }
        energy /= kFrameSize;
        const double db = energy > 0.0 ? std::max(kSilenceDb, 10.0 * std::log10(energy)) : kSilenceDb;
        onset[static_cast<size_t>(index)] =
            index == 0 ? 0.0 : std::max(0.0, db - previousDb);
        previousDb = db;
    }

    /* Remove the envelope's own average so a steady loud section does not dominate the
     * autocorrelation. */
    double mean = 0.0;
    for (double value : onset) mean += value;
    mean /= static_cast<double>(onset.size());
    for (double &value : onset) value = std::max(0.0, value - mean);
    double energySum = 0.0;
    for (double value : onset) energySum += value * value;
    if (energySum <= 0.0) return grid;

    const double hopSeconds = static_cast<double>(kHop) / sampleRate;
    const int64_t minLag = std::max<int64_t>(1, static_cast<int64_t>(beatSeconds(kMaxBpm) / hopSeconds));
    const int64_t maxLag = std::min<int64_t>(
        frameCount - 1, static_cast<int64_t>(beatSeconds(kMinBpm) / hopSeconds));
    if (maxLag <= minLag) return grid;

    /* Correlated up to twice the longest candidate period: a tempo's score also counts how well its
     * own double correlates, which is what tells a beat apart from half of one. */
    const int64_t correlationLimit = std::min<int64_t>(frameCount - 1, maxLag * 2 + 1);
    std::vector<double> correlation(static_cast<size_t>(correlationLimit + 1), 0.0);
    for (int64_t lag = minLag; lag <= correlationLimit; ++lag) {
        double sum = 0.0;
        for (int64_t index = 0; index + lag < frameCount; ++index) {
            sum += onset[static_cast<size_t>(index)] * onset[static_cast<size_t>(index + lag)];
        }
        correlation[static_cast<size_t>(lag)] = sum / static_cast<double>(frameCount - lag);
    }

    std::vector<double> score(static_cast<size_t>(maxLag + 2), 0.0);
    double bestScore = 0.0;
    for (int64_t lag = minLag; lag <= maxLag; ++lag) {
        const double bpm = beatSeconds(1.0) / (static_cast<double>(lag) * hopSeconds);
        const double weight =
            std::exp(-0.5 * std::pow(std::log2(bpm / kPreferredBpm) / kOctaveWidth, 2.0));
        /* The period and its double: a real beat correlates at both, a coincidental half-beat
         * pattern only at the shorter one. */
        const double doubled = 2 * lag <= correlationLimit
            ? 0.5 * correlation[static_cast<size_t>(2 * lag)] : 0.0;
        score[static_cast<size_t>(lag)] = (correlation[static_cast<size_t>(lag)] + doubled) * weight;
        bestScore = std::max(bestScore, score[static_cast<size_t>(lag)]);
    }
    if (bestScore <= 0.0) return grid;

    /* Correlation only says which periods are plausible. Which one *is* the beat is decided by the
     * same thing the transition needs: how much onset energy lands exactly on the grid's lines. An
     * off-beat pattern correlates just as well one and a half beats out, and a lag quantised to the
     * analysis hop can align by luck, so the plausible periods are each refined as a comb and the
     * winner is the shortest period that places a line on every beat rather than on every second or
     * third one. */
    std::vector<int64_t> candidates;
    for (int64_t lag = minLag; lag <= maxLag; ++lag) {
        if (score[static_cast<size_t>(lag)] >= bestScore * 0.5) candidates.push_back(lag);
    }
    if (candidates.size() > kMaxCandidates) {
        std::partial_sort(candidates.begin(), candidates.begin() + kMaxCandidates, candidates.end(),
            [&](int64_t left, int64_t right) {
                return score[static_cast<size_t>(left)] > score[static_cast<size_t>(right)];
            });
        candidates.resize(kMaxCandidates);
    }

    const double offsetStep = std::max<int64_t>(kHop / 4, 1);
    struct Comb {
        double periodFrames = 0.0;
        int64_t offset = 0;
        double score = -1.0;
    };
    std::vector<Comb> combs;
    for (int64_t lag : candidates) {
        Comb best;
        for (double candidate = static_cast<double>(lag) - kPeriodRefineHops;
             candidate <= static_cast<double>(lag) + kPeriodRefineHops;
             candidate += kPeriodRefineStep) {
            if (candidate < 1.0) continue;
            const double periodFrames = candidate * kHop;
            for (double offset = 0.0; offset < periodFrames; offset += offsetStep) {
                double sum = 0.0;
                for (double at = offset; at < static_cast<double>(frames); at += periodFrames) {
                    const int64_t index = static_cast<int64_t>(std::floor(at / kHop));
                    if (index >= 0 && index < frameCount) sum += onset[static_cast<size_t>(index)];
                }
                if (sum > best.score) {
                    best.score = sum;
                    best.periodFrames = periodFrames;
                    best.offset = static_cast<int64_t>(offset);
                }
            }
        }
        if (best.score > 0.0) combs.push_back(best);
    }
    if (combs.empty()) return grid;

    double bestCombScore = 0.0;
    for (const Comb &comb : combs) bestCombScore = std::max(bestCombScore, comb.score);
    const Comb *winner = nullptr;
    for (const Comb &comb : combs) {
        if (comb.score < bestCombScore * kCombTolerance) continue;
        if (winner == nullptr || comb.periodFrames < winner->periodFrames) winner = &comb;
    }
    if (winner == nullptr) return grid;
    const double bestPeriodFrames = winner->periodFrames;
    const int64_t bestOffset = winner->offset;
    const double refinedBpm = beatSeconds(1.0) / (bestPeriodFrames / sampleRate);
    if (refinedBpm < kMinBpm || refinedBpm > kMaxBpm) return grid;

    grid.valid = true;
    grid.bpm = refinedBpm;
    /* Confidence is the winning phase's contrast against a typical one. The typical score is a
     * median rather than a mean: one loud attack is an outlier that would otherwise make noise look
     * like a pulse. */
    std::vector<double> phaseScores;
    for (double offset = 0.0; offset < bestPeriodFrames; offset += offsetStep) {
        double sum = 0.0;
        for (double at = offset; at < static_cast<double>(frames); at += bestPeriodFrames) {
            const int64_t index = static_cast<int64_t>(std::floor(at / kHop));
            if (index >= 0 && index < frameCount) sum += onset[static_cast<size_t>(index)];
        }
        phaseScores.push_back(sum);
    }
    double typicalPhase = 0.0;
    if (!phaseScores.empty()) {
        std::sort(phaseScores.begin(), phaseScores.end());
        /* The upper quartile, not the middle: with dozens of phase classes the best one beats the
         * middle by chance alone, and that luck must not read as a pulse. */
        typicalPhase = phaseScores[phaseScores.size() * 3 / 4];
    }
    grid.confidence = bestCombScore + typicalPhase > 0.0
        ? std::clamp((bestCombScore - typicalPhase) / (bestCombScore + typicalPhase), 0.0, 1.0) : 0.0;
    grid.firstBeatFrame = bestOffset;
    if (grid.confidence < kMinConfidence) {
        grid.valid = false;
    }
    return grid;
}

}  // namespace lazer_audio
