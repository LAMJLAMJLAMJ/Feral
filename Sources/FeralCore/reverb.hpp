#pragma once

// A room's late tail, as the audio thread runs it: a feedback delay network (FDN) of
// FERAL_ROOM_LINES lines mixed by a Hadamard matrix, each line with a three-band decay filter and a
// slowly wandering length, fed from the room's summed sends through a pre-delay and a chain of
// all-pass diffusers. Every line's output is one of the room's buses, which output taps play.
//
// References for the design (ideas, not code): Jot and Chaigne 1991 (FDN with per-line absorption
// filters), zita-rev1 and the IEM FdnReverb (Hadamard FDNs with modulation).

#include "feral_core.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>

namespace feral {

class RoomRuntime {
public:
    static constexpr int N = FERAL_ROOM_LINES;
    static constexpr int kDiffusers = 4;

    explicit RoomRuntime(double sampleRate) : fs(sampleRate) {
        lineSize = powerOfTwo(static_cast<uint32_t>(FERAL_ROOM_MAX_LINE * 1.6 * fs + depthFor(1) + 8));
        preSize = powerOfTwo(static_cast<uint32_t>(FERAL_ROOM_MAX_PREDELAY * fs + FERAL_MAX_FRAMES + 8));
        // Diffuser lengths at 48 kHz: 1.5 to 5.1 ms, mutually prime.
        const int base[kDiffusers] = {73, 109, 179, 241};
        apSize = 0;
        for (int i = 0; i < kDiffusers; ++i) {
            apLen[i] = std::max(1, static_cast<int>(std::lround(base[i] * fs / 48000.0)));
            apSize = std::max(apSize, apLen[i]);
        }
        memory = static_cast<float *>(std::calloc(static_cast<size_t>(N) * lineSize + preSize + kDiffusers * apSize, sizeof(float)));
    }

    ~RoomRuntime() { std::free(memory); }

    RoomRuntime(const RoomRuntime &) = delete;
    RoomRuntime &operator=(const RoomRuntime &) = delete;

    /// Whether the room ran last buffer.
    bool running = false;

    /// Stops the room and empties it; the next process starts it from silence.
    void stop() { running = false; }

    /// Runs one block: x is the room's summed sends (frames samples), out[j] receives line j's
    /// output. Audio thread; no allocation.
    void process(const feral_room_params &p, const float *x, float *const *out, int frames) {
        if (!running) start(p);
        updateTargets(p);
        const float inv = 1.0f / static_cast<float>(frames);

        // The decay gains and the input gain move a little towards their targets each block (about
        // 50 ms to settle), so a new decay never clicks.
        const float a = 1.0f - std::exp(-static_cast<float>(frames) / static_cast<float>(0.05 * fs));
        for (int j = 0; j < N; ++j)
            for (int b = 0; b < 3; ++b) gain[j][b] += a * (targetGain[j][b] - gain[j][b]);
        inputGain += a * (targetInputGain - inputGain);
        diffusion += a * (targetDiffusion - diffusion);

        // Line lengths: each glides towards its target (0.5 % at most), and wanders by the modulation.
        double d0[N], d1[N];
        const double glide = 0.005 * frames;
        const double depth = depthFor(p.modulation);
        for (int j = 0; j < N; ++j) {
            const double m0 = depthNow * std::sin(phase[j]);
            length[j] += std::clamp(targetLength[j] - length[j], -glide, glide);
            phase[j] += 2 * M_PI * rate[j] * frames / fs;
            if (phase[j] > 2 * M_PI) phase[j] -= 2 * M_PI;
            const double m1 = depth * std::sin(phase[j]);
            d0[j] = length[j] + depthNow + m0;
            d1[j] = length[j] + depth + m1;
        }
        depthNow = depth;

        // Pre-delay: write the block, then read it back at the pre-delay (crossfading to a new one).
        const uint32_t preMask = preSize - 1;
        float *pre = memory + static_cast<size_t>(N) * lineSize;
        for (int n = 0; n < frames; ++n) pre[(preWrite + static_cast<uint32_t>(n)) & preMask] = x ? x[n] : 0.0f;
        const double target = std::clamp<double>(p.predelay, 0, FERAL_ROOM_MAX_PREDELAY * fs);
        if (fadeLeft == 0 && std::fabs(target - predelay) >= 1) {
            fromPredelay = predelay;
            predelay = target;
            fadeLeft = fadeLength = std::max(1, static_cast<int>(0.03 * fs));
        }

        float *ap[kDiffusers];
        for (int i = 0; i < kDiffusers; ++i) ap[i] = memory + static_cast<size_t>(N) * lineSize + preSize + static_cast<size_t>(i) * apSize;
        const float g = 0.7f * diffusion;
        const uint32_t mask = lineSize - 1;

        for (int n = 0; n < frames; ++n) {
            // The input, pre-delayed.
            const uint32_t at = preWrite + static_cast<uint32_t>(n);
            float in = pre[(at - static_cast<uint32_t>(predelay)) & preMask];
            if (fadeLeft > 0) {
                const float w = static_cast<float>(fadeLeft) / static_cast<float>(fadeLength);
                const float old = pre[(at - static_cast<uint32_t>(fromPredelay)) & preMask];
                in = in * (1 - w) + old * w;
                --fadeLeft;
            }
            // Diffused by the all-passes.
            for (int i = 0; i < kDiffusers; ++i) {
                float &slot = ap[i][apPos[i]];
                const float d = slot;
                const float y = d - g * in;
                slot = in + g * y;
                in = y;
                if (++apPos[i] == apLen[i]) apPos[i] = 0;
            }
            in *= inputGain;

            // Read every line, filter it (three-band decay), and send it out.
            const float t = static_cast<float>(n + 1) * inv;
            float v[N];
            for (int j = 0; j < N; ++j) {
                const double d = d0[j] + (d1[j] - d0[j]) * t;
                // First-order all-pass interpolation (as in Dattorro's plate): lossless, where linear or
                // cubic interpolation would dull the tail a little on every pass. The fraction is kept
                // from 0.5 to 1.5, where the all-pass is well behaved.
                const double whole = std::floor(d - 0.5);
                const auto k = static_cast<uint32_t>(whole);
                const float f = static_cast<float>(d - whole);
                const float c = (1 - f) / (1 + f);
                const float *line = memory + static_cast<size_t>(j) * lineSize;
                const uint32_t i = lineWrite - k;
                const float y = c * (line[i & mask] - interp[j]) + line[(i - 1) & mask];
                interp[j] = y;
                // The three bands from two low-passes (each two one-poles in a row, 12 dB per octave):
                // below the first, between, above the second. With every gain the same this is that
                // gain exactly, whatever the filters do.
                lp1a[j] += c1 * (y - lp1a[j]);
                lp1[j] += c1 * (lp1a[j] - lp1[j]);
                lp2a[j] += c2 * (y - lp2a[j]);
                lp2[j] += c2 * (lp2a[j] - lp2[j]);
                const float s = gain[j][0] * lp1[j] + gain[j][1] * (lp2[j] - lp1[j]) + gain[j][2] * (y - lp2[j]);
                v[j] = s;
                out[j][n] = s;
            }
            // Mix them (a fast Walsh-Hadamard transform, scaled to be lossless) and write them back
            // with the input, which goes into every line with its own sign.
            for (int h = 1; h < N; h <<= 1) {
                for (int i = 0; i < N; i += h << 1) {
                    for (int j = i; j < i + h; ++j) {
                        const float u = v[j], w = v[j + h];
                        v[j] = u + w;
                        v[j + h] = u - w;
                    }
                }
            }
            for (int j = 0; j < N; ++j) {
                float *line = memory + static_cast<size_t>(j) * lineSize;
                line[lineWrite & mask] = v[j] * kScale + (inputSign(j) ? -in : in);
            }
            ++lineWrite;
        }
        preWrite += static_cast<uint32_t>(frames);
        for (int j = 0; j < N; ++j) {
            lp1[j] = flush(lp1[j]);
            lp2[j] = flush(lp2[j]);
            lp1a[j] = flush(lp1a[j]);
            lp2a[j] = flush(lp2a[j]);
            interp[j] = flush(interp[j]);
        }
    }

private:
    static constexpr float kScale = 0.25f; // 1 / sqrt(N): makes the Hadamard matrix orthonormal

    double fs;
    uint32_t lineSize = 0, preSize = 0;
    int apSize = 0;
    int apLen[kDiffusers] = {};
    int apPos[kDiffusers] = {};
    float *memory = nullptr;
    uint32_t lineWrite = 0, preWrite = 0;

    double length[N] = {}, targetLength[N] = {};
    double rate[N] = {}, phase[N] = {};
    double depthNow = 0;
    float gain[N][3] = {}, targetGain[N][3] = {};
    float inputGain = 0, targetInputGain = 0;
    float diffusion = 0, targetDiffusion = 0;
    float lp1[N] = {}, lp2[N] = {}, lp1a[N] = {}, lp2a[N] = {};
    float interp[N] = {}; // each line's all-pass interpolator's last output
    float c1 = 0, c2 = 0;
    double predelay = 0, fromPredelay = 0;
    int fadeLeft = 0, fadeLength = 1;
    // The parameters the targets were last worked out from.
    float lastLine = -1, lastDecay[3] = {-1, -1, -1}, lastCross[2] = {-1, -1};

    static uint32_t powerOfTwo(uint32_t n) {
        uint32_t p = 1;
        while (p < n) p <<= 1;
        return p;
    }

    static float flush(float v) { return std::fabs(v) < 1e-20f ? 0.0f : v; }

    /// The lines' wander in samples, at most 0.25 ms.
    double depthFor(float modulation) const { return std::clamp(modulation, 0.0f, 1.0f) * 0.00025 * fs; }

    /// Whether line j takes the input inverted: half the lines, in a pattern no Hadamard row has.
    static bool inputSign(int j) { return (0x6A95u >> j) & 1u; }

    static bool isPrime(uint32_t n) {
        if (n < 2) return false;
        for (uint32_t d = 2; d * d <= n; ++d)
            if (n % d == 0) return false;
        return true;
    }

    /// Empties the room and sets everything to the parameters at once.
    void start(const feral_room_params &p) {
        const size_t total = static_cast<size_t>(N) * lineSize + preSize + kDiffusers * static_cast<size_t>(apSize);
        std::memset(memory, 0, total * sizeof(float));
        std::fill(apPos, apPos + kDiffusers, 0);
        std::fill(lp1, lp1 + N, 0.0f);
        std::fill(lp2, lp2 + N, 0.0f);
        std::fill(lp1a, lp1a + N, 0.0f);
        std::fill(lp2a, lp2a + N, 0.0f);
        std::fill(interp, interp + N, 0.0f);
        lastLine = -1;
        updateTargets(p);
        for (int j = 0; j < N; ++j) {
            length[j] = targetLength[j];
            for (int b = 0; b < 3; ++b) gain[j][b] = targetGain[j][b];
            rate[j] = 0.09 + 0.071 * j;
            phase[j] = 0.7 * j;
        }
        inputGain = targetInputGain;
        diffusion = targetDiffusion;
        depthNow = depthFor(p.modulation);
        predelay = std::clamp<double>(p.predelay, 0, FERAL_ROOM_MAX_PREDELAY * fs);
        fadeLeft = 0;
        running = true;
    }

    /// Works out the lines' lengths, decay gains and the input gain from the parameters (only when
    /// they changed: finding the lengths' primes is the costly part).
    void updateTargets(const feral_room_params &p) {
        targetDiffusion = std::isfinite(p.diffusion) ? std::clamp(p.diffusion, 0.0f, 1.0f) : 0.7f;
        bool changed = p.line_length != lastLine;
        for (int b = 0; b < 3; ++b) changed = changed || p.decay[b] != lastDecay[b];
        for (int b = 0; b < 2; ++b) changed = changed || p.crossover[b] != lastCross[b];
        if (!changed) return;
        lastLine = p.line_length;
        std::copy(p.decay, p.decay + 3, lastDecay);
        std::copy(p.crossover, p.crossover + 2, lastCross);

        const double mean = std::clamp<double>(std::isfinite(p.line_length) ? p.line_length : 0.02 * fs,
                                               FERAL_ROOM_MIN_LINE * fs, FERAL_ROOM_MAX_LINE * fs);
        // Lengths from 0.5 to 1.5 times the mean, unevenly spaced, each the nearest prime (so no two
        // lines share a period).
        for (int j = 0; j < N; ++j) {
            const double r = 0.5 + (j + 0.45 * std::sin(1.7 * j + 0.3)) / (N - 1);
            auto n = static_cast<uint32_t>(std::max(2.0, std::round(mean * r)));
            while (!isPrime(n)) ++n;
            targetLength[j] = n;
        }
        double meanSquare = 0;
        for (int j = 0; j < N; ++j) {
            for (int b = 0; b < 3; ++b) {
                const double rt = std::clamp<double>(std::isfinite(p.decay[b]) ? p.decay[b] : 2, 0.1, 30);
                // RT60: 60 dB down after rt seconds, so each pass of length L loses 60 L / (rt fs) dB.
                targetGain[j][b] = static_cast<float>(std::pow(10.0, -3.0 * targetLength[j] / (rt * fs)));
            }
            meanSquare += targetGain[j][1] * targetGain[j][1];
        }
        meanSquare /= N;
        // The tail's total energy is about the input's: each pass keeps g² of it, so the whole tail
        // holds g² / (1 - g²) of what goes in; the input is scaled by the square root of the inverse.
        targetInputGain = static_cast<float>(std::sqrt(std::max(1e-6, (1 - meanSquare) / meanSquare)) * kScale);
        auto coefficient = [&](float hz, float fallback) {
            const double f = std::clamp<double>(std::isfinite(hz) && hz > 0 ? hz : fallback, 10, 0.45 * fs);
            return static_cast<float>(1 - std::exp(-2 * M_PI * f / fs));
        };
        c1 = coefficient(p.crossover[0], 177);
        c2 = coefficient(p.crossover[1], 5657);
    }
};

}
