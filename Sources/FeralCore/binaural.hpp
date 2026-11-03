// The monitor's binaural render: each speaker's feed, delayed and scaled for its distance from the
// listening point, convolved with the head-related impulse responses for its direction, summed into
// two ears. Uniformly partitioned overlap-save convolution in 64-sample blocks (FFT size 128), so the
// monitor runs 64 samples behind the speakers.
#pragma once

#include "feral_core.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace feral {

using cf = std::complex<float>;

/// Radix-2 complex FFT of size 128, unscaled both ways.
struct Fft128 {
    static constexpr int N = 128;
    std::array<cf, N / 2> twiddle{};
    std::array<int, N> reversed{};

    Fft128() {
        for (int k = 0; k < N / 2; ++k) twiddle[k] = std::polar(1.0f, static_cast<float>(-2 * M_PI * k / N));
        for (int i = 0; i < N; ++i) {
            int r = 0;
            for (int b = 0, x = i; b < 7; ++b, x >>= 1) r = (r << 1) | (x & 1);
            reversed[i] = r;
        }
    }

    void run(cf *x, bool inverse) const {
        for (int i = 0; i < N; ++i)
            if (i < reversed[i]) std::swap(x[i], x[reversed[i]]);
        for (int len = 2; len <= N; len <<= 1) {
            const int half = len / 2, step = N / len;
            for (int i = 0; i < N; i += len) {
                for (int j = 0; j < half; ++j) {
                    cf w = twiddle[j * step];
                    if (inverse) w = std::conj(w);
                    const cf a = x[i + j], b = x[i + j + half] * w;
                    x[i + j] = a + b;
                    x[i + j + half] = a - b;
                }
            }
        }
    }
};

constexpr int kMonitorBlock = 64;
constexpr int kMonitorBins = kMonitorBlock + 1;
/// HRIRs up to 8 blocks (512 samples).
constexpr int kMonitorMaxPartitions = 8;
/// The longest distance delay, in samples, and each speaker's history ring.
constexpr int kMonitorMaxDelay = 8192;
constexpr uint32_t kMonitorRing = 16384;

}

/// What the monitor plays, built on the control side and handed to the core whole.
struct feral_monitor {
    struct Speaker {
        int output = 0;
        float gain = 1;
        int delay = 0;
        /// [ear][partition][bin], kMonitorMaxPartitions partitions per ear (zero past the HRIR's end)
        std::vector<feral::cf> spectra;
    };
    int left = -1, right = -1;
    float gain = 1;
    int partitions = 1;
    std::vector<Speaker> speakers;
    uint64_t sequence = 0;
};

namespace feral {

/// The convolver's state: the audio thread's, sized for every channel up front.
struct BinauralRuntime {
    Fft128 fft;
    int maxSpeakers;
    float *rings;               // [speaker][kMonitorRing], calloc'd: pages never used cost nothing
    float *scratch;             // [speaker][FERAL_MAX_FRAMES]: solo feeds, built by the core
    std::vector<cf> history;    // [speaker][partition][bin]: input spectra, newest at `slot`
    std::vector<cf> work;       // two FFT frames
    std::vector<float> outQueue = std::vector<float>(2 * kMonitorRing);
    uint64_t written = 0, processed = 0, queued = kMonitorBlock, consumed = 0;
    int slot = 0;
    std::vector<int> layout;    // the outputs the history belongs to

    explicit BinauralRuntime(int speakers)
        : maxSpeakers(speakers),
          rings(static_cast<float *>(std::calloc(static_cast<size_t>(speakers) * kMonitorRing, sizeof(float)))),
          scratch(static_cast<float *>(std::calloc(static_cast<size_t>(speakers) * FERAL_MAX_FRAMES, sizeof(float)))),
          history(static_cast<size_t>(speakers) * kMonitorMaxPartitions * kMonitorBins), work(2 * Fft128::N) {
        layout.reserve(static_cast<size_t>(speakers));
    }
    ~BinauralRuntime() {
        std::free(rings);
        std::free(scratch);
    }
    BinauralRuntime(const BinauralRuntime &) = delete;
    BinauralRuntime &operator=(const BinauralRuntime &) = delete;

    float *feed(int speaker) { return scratch + static_cast<size_t>(speaker) * FERAL_MAX_FRAMES; }

    /// Starts again from silence (when the monitor comes back after being off or on PFL), clearing
    /// only what the first `speakers` use.
    void reset(int speakers) {
        speakers = std::min(speakers, maxSpeakers);
        std::memset(rings, 0, static_cast<size_t>(speakers) * kMonitorRing * sizeof(float));
        std::fill(history.begin(), history.end(), cf{});
        std::fill(outQueue.begin(), outQueue.end(), 0.0f);
        written = processed = consumed = 0;
        queued = kMonitorBlock;
    }

    cf *spectrum(int speaker, int s) { return history.data() + (static_cast<size_t>(speaker) * kMonitorMaxPartitions + s) * kMonitorBins; }

    /// Drops the history when the speakers change (a new plan with the same speakers keeps it).
    void follow(const feral_monitor &m) {
        bool same = static_cast<int>(layout.size()) == static_cast<int>(m.speakers.size());
        for (size_t k = 0; same && k < layout.size(); ++k) same = layout[k] == m.speakers[k].output;
        if (same) return;
        layout.clear();
        for (const auto &s : m.speakers) layout.push_back(s.output);
        std::fill(history.begin(), history.end(), cf{});
    }

    /// Takes `frames` of every speaker's feed (signals[k] null is silence) and writes `frames` of
    /// the two ears, 64 samples late.
    void process(const feral_monitor &m, const float *const *signals, int frames, float *left, float *right) {
        const int n = std::min(static_cast<int>(m.speakers.size()), maxSpeakers);
        for (int k = 0; k < n; ++k) {
            float *ring = rings + static_cast<size_t>(k) * kMonitorRing;
            for (int i = 0; i < frames; ++i) ring[(written + static_cast<uint64_t>(i)) & (kMonitorRing - 1)] = signals[k] ? signals[k][i] : 0.0f;
        }
        written += static_cast<uint64_t>(frames);
        while (written - processed >= static_cast<uint64_t>(kMonitorBlock)) {
            block(m, n);
            processed += kMonitorBlock;
        }
        for (int i = 0; i < frames; ++i) {
            const size_t at = static_cast<size_t>((consumed + static_cast<uint64_t>(i)) & (kMonitorRing - 1));
            if (left) left[i] = outQueue[2 * at] * m.gain;
            if (right) right[i] = outQueue[2 * at + 1] * m.gain;
        }
        consumed += static_cast<uint64_t>(frames);
    }

private:
    /// One 64-sample block: every speaker's spectrum into the history, then the ears.
    void block(const feral_monitor &m, int n) {
        constexpr int N = Fft128::N;
        cf *z = work.data();
        slot = (slot + 1) % kMonitorMaxPartitions;
        // Two speakers per FFT: one as the real part, one as the imaginary.
        for (int k = 0; k < n; k += 2) {
            for (int i = 0; i < N; ++i) {
                // The last 128 samples: the previous block and this one.
                const uint64_t t = processed + static_cast<uint64_t>(i) - kMonitorBlock;
                auto sample = [&](int s) -> float {
                    const auto &sp = m.speakers[static_cast<size_t>(s)];
                    const float *ring = rings + static_cast<size_t>(s) * kMonitorRing;
                    return ring[(t - static_cast<uint64_t>(sp.delay)) & (kMonitorRing - 1)] * sp.gain;
                };
                z[i] = cf(sample(k), k + 1 < n ? sample(k + 1) : 0.0f);
            }
            fft.run(z, false);
            cf *a = spectrum(k, slot);
            cf *b = k + 1 < n ? spectrum(k + 1, slot) : nullptr;
            for (int j = 0; j < kMonitorBins; ++j) {
                const cf zj = z[j], zn = std::conj(z[(N - j) % N]);
                a[j] = 0.5f * (zj + zn);
                if (b) b[j] = cf(0, -0.5f) * (zj - zn);
            }
        }
        // The ears: sum over speakers and partitions, left as the real part and right as the imaginary.
        std::array<cf, kMonitorBins> yl{}, yr{};
        const int P = std::clamp(m.partitions, 1, kMonitorMaxPartitions);
        for (int k = 0; k < n; ++k) {
            const auto &sp = m.speakers[static_cast<size_t>(k)];
            for (int p = 0; p < P; ++p) {
                const cf *x = spectrum(k, (slot - p + kMonitorMaxPartitions) % kMonitorMaxPartitions);
                const cf *hl = sp.spectra.data() + static_cast<size_t>(p) * kMonitorBins;
                const cf *hr = sp.spectra.data() + static_cast<size_t>(kMonitorMaxPartitions + p) * kMonitorBins;
                for (int j = 0; j < kMonitorBins; ++j) {
                    yl[j] += x[j] * hl[j];
                    yr[j] += x[j] * hr[j];
                }
            }
        }
        for (int j = 0; j < N; ++j) {
            const cf l = j <= kMonitorBlock ? yl[j] : std::conj(yl[N - j]);
            const cf r = j <= kMonitorBlock ? yr[j] : std::conj(yr[N - j]);
            z[j] = l + cf(0, 1) * r;
        }
        fft.run(z, true);
        for (int i = 0; i < kMonitorBlock; ++i) {
            const size_t at = static_cast<size_t>((queued + static_cast<uint64_t>(i)) & (kMonitorRing - 1));
            outQueue[2 * at] = z[kMonitorBlock + i].real() / N;
            outQueue[2 * at + 1] = z[kMonitorBlock + i].imag() / N;
        }
        queued += kMonitorBlock;
    }
};

/// A speaker's HRIR pair as the convolver wants it: each 64-sample partition, zero-padded to 128,
/// in the frequency domain, kMonitorMaxPartitions per ear. `length` is cut to that many blocks.
/// Returns the partitions the HRIR fills.
inline int monitorSpectra(const float *left, const float *right, int length, std::vector<cf> &out) {
    static const Fft128 fft;
    length = std::clamp(length, 1, kMonitorBlock * kMonitorMaxPartitions);
    const int P = (length + kMonitorBlock - 1) / kMonitorBlock;
    out.assign(static_cast<size_t>(2 * kMonitorMaxPartitions) * kMonitorBins, cf{});
    std::array<cf, Fft128::N> z{};
    for (int ear = 0; ear < 2; ++ear) {
        const float *h = ear == 0 ? left : right;
        for (int p = 0; p < P; ++p) {
            z.fill(cf{});
            for (int i = 0; i < kMonitorBlock && p * kMonitorBlock + i < length; ++i) z[i] = h[p * kMonitorBlock + i];
            fft.run(z.data(), false);
            std::copy(z.begin(), z.begin() + kMonitorBins, out.begin() + static_cast<long>((ear * kMonitorMaxPartitions + p) * kMonitorBins));
        }
    }
    return P;
}

}
