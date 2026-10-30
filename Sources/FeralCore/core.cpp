#include "feral_core.h"
#include "render_state.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <mutex>

using feral::RenderState;
using feral::Tap;

feral_state::feral_state(int inputs, int outputs)
    : inputs(inputs), outputs(outputs), taps(outputs), outputParams(outputs, feral_output_defaults()),
      limiterRelease(outputs, 1.0f), motion(feral_motion_defaults(48000)) {}

bool feral_state::finish(double maxDelay) {
    for (int out = 0; out < outputs; ++out) {
        auto &list = taps[out];
        std::stable_sort(list.begin(), list.end());
        size_t kept = 0;
        for (size_t i = 0; i < list.size(); ++i) {
            if (kept > 0 && list[kept - 1].sameKey(list[i])) {
                if (list[i].kind == FERAL_TAP_DELAY) return false;
                list[kept - 1].gain += list[i].gain;
            } else {
                list[kept++] = list[i];
            }
        }
        list.resize(kept);
        list.erase(std::remove_if(list.begin(), list.end(), [](const Tap &t) { return t.gain == 0.0f; }), list.end());
        for (Tap &t : list) t.delay = static_cast<float>(std::clamp<double>(t.delay, 0, maxDelay));

        feral_output_params &p = outputParams[out];
        p.delay = static_cast<float>(std::clamp<double>(p.delay, 0, maxDelay));
        // The limiter lets go by 20 dB over limiter_release samples.
        limiterRelease[out] = p.limiter_release > 1 ? std::pow(0.1f, 1.0f / p.limiter_release) : 0.0f;
    }
    return true;
}

namespace feral {
namespace {

static_assert(std::atomic<RenderState *>::is_always_lock_free);
static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(std::atomic<float>::is_always_lock_free);

/// Distinct (input, kind) keys one output can have, so the most taps it can ever play at once.
constexpr int kVoicesPerOutput = 2 * FERAL_MAX_CHANNELS;

/// A delay that moves: it glides towards its target, or crossfades from an old value to the target.
struct DelayMotion {
    double current = 0;
    double target = 0;
    double from = 0; // the delay being faded out during a crossfade
    int position = 0;
    int length = 0;  // the crossfade's length; 0 when none is running

    void reset(double delay) { current = target = from = delay; position = length = 0; }
};

/// What a delay does over one buffer: the main read moves from d0 to d1, and during a crossfade the
/// old delay's read fades out while the main one fades in (weights w0 to w1 for the main read).
struct DelayPlan {
    double d0, d1;
    bool crossfading;
    double from;
    float w0, w1;
};

/// Raised-cosine crossfade weight for the new read: 0 to 1, and the old read's weight is 1 minus it,
/// so two copies of the same signal sum back to it.
inline float crossfadeShape(double t) {
    if (t >= 1) return 1;
    const double s = std::sin(0.5 * M_PI * t);
    return static_cast<float>(s * s);
}

/// Moves a delay by one buffer. Audio thread.
DelayPlan advance(DelayMotion &m, const feral_motion_params &p, int frames) {
    const double diff = m.target - m.current;
    if (m.length == 0 && diff != 0 && (std::fabs(diff) > p.jump || p.glide_rate <= 0)) {
        // Too far to glide: crossfade to the target.
        m.from = m.current;
        m.current = m.target;
        m.position = 0;
        m.length = std::max(1, static_cast<int>(p.crossfade));
    }
    DelayPlan plan{};
    plan.d0 = m.current;
    // Glide (also during a crossfade, if the target moves on: it then glides from where the new read is).
    const double step = std::max(0.0, static_cast<double>(p.glide_rate)) * frames;
    m.current += std::clamp(m.target - m.current, -step, step);
    plan.d1 = m.current;
    if (m.length > 0) {
        plan.crossfading = true;
        plan.from = m.from;
        plan.w0 = crossfadeShape(static_cast<double>(m.position) / m.length);
        m.position += frames;
        plan.w1 = crossfadeShape(static_cast<double>(m.position) / m.length);
        if (m.position >= m.length) m.length = m.position = 0;
    }
    return plan;
}

/// A delay line: a power-of-two ring the input is written into, one block at a time.
struct DelayLine {
    float *data;
    uint32_t mask;

    void write(uint32_t at, const float *x, int frames) {
        const uint32_t start = at & mask;
        const uint32_t first = std::min<uint32_t>(static_cast<uint32_t>(frames), mask + 1 - start);
        if (x) {
            std::memcpy(data + start, x, first * sizeof(float));
            std::memcpy(data, x + first, (frames - first) * sizeof(float));
        } else {
            std::memset(data + start, 0, first * sizeof(float));
            std::memset(data, 0, (frames - first) * sizeof(float));
        }
    }

    float at(uint32_t i) const { return data[i & mask]; }

    /// x[m - d] for block sample m (the block starts at index `block`), d >= 0. Four-point (cubic)
    /// Lagrange interpolation, exact for whole-sample delays; under one sample, linear, since the
    /// next sample has not arrived yet.
    float read(uint32_t block, int m, double d) const {
        const double whole = std::floor(d);
        const auto k = static_cast<uint32_t>(whole);
        const float f = static_cast<float>(d - whole);
        const uint32_t i = block + static_cast<uint32_t>(m) - k; // x[m - k]
        if (k == 0) return (1 - f) * at(i) + f * at(i - 1);
        const float cm = -f * (f - 1) * (f - 2) / 6, c0 = (f + 1) * (f - 1) * (f - 2) / 2;
        const float c1 = -(f + 1) * f * (f - 2) / 2, c2 = (f + 1) * f * (f - 1) / 6;
        return cm * at(i + 1) + c0 * at(i) + c1 * at(i - 1) + c2 * at(i - 2);
    }

    /// y[m] += g(m) * x[m - d(m)], with the gain going linearly from g0 to g1 and the delay from d0
    /// to d1 over the block (each reaching its end value on the last sample).
    void accumulate(uint32_t block, int frames, double d0, double d1, float g0, float g1, float *y) const {
        const float gstep = (g1 - g0) / static_cast<float>(frames);
        if (d0 != d1) {
            const double dstep = (d1 - d0) / frames;
            for (int m = 0; m < frames; ++m)
                y[m] += (g0 + gstep * static_cast<float>(m + 1)) * read(block, m, d0 + dstep * (m + 1));
            return;
        }
        // A fixed delay: the interpolation weights are the same for the whole block.
        const double whole = std::floor(d0);
        const auto k = static_cast<uint32_t>(whole);
        const float f = static_cast<float>(d0 - whole);
        const uint32_t oldest = (block - k - 2) & mask; // the earliest sample any output needs
        if (k == 0 || oldest + static_cast<uint32_t>(frames) + 3 > mask + 1) {
            for (int m = 0; m < frames; ++m) y[m] += (g0 + gstep * static_cast<float>(m + 1)) * read(block, m, d0);
            return;
        }
        const float *x = data + oldest + 2; // x[m] here is the input k samples before block sample m
        if (f == 0) {
            if (g0 == g1) for (int m = 0; m < frames; ++m) y[m] += g1 * x[m];
            else for (int m = 0; m < frames; ++m) y[m] += (g0 + gstep * static_cast<float>(m + 1)) * x[m];
            return;
        }
        const float cm = -f * (f - 1) * (f - 2) / 6, c0 = (f + 1) * (f - 1) * (f - 2) / 2;
        const float c1 = -(f + 1) * f * (f - 2) / 2, c2 = (f + 1) * f * (f - 1) / 6;
        if (g0 == g1) {
            const float a = g1 * cm, b = g1 * c0, c = g1 * c1, d = g1 * c2;
            for (int m = 0; m < frames; ++m) y[m] += a * x[m + 1] + b * x[m] + c * x[m - 1] + d * x[m - 2];
            return;
        }
        for (int m = 0; m < frames; ++m) {
            const float v = cm * x[m + 1] + c0 * x[m] + c1 * x[m - 1] + c2 * x[m - 2];
            y[m] += (g0 + gstep * static_cast<float>(m + 1)) * v;
        }
    }

    /// Plays a moving delay for one block: one read, or two during a crossfade. The gain and the
    /// crossfade weight both ramp over the block; their product is ramped between its end values.
    void accumulate(uint32_t block, int frames, const DelayPlan &plan, float g0, float g1, float *y) const {
        if (!plan.crossfading) {
            accumulate(block, frames, plan.d0, plan.d1, g0, g1, y);
            return;
        }
        accumulate(block, frames, plan.from, plan.from, g0 * (1 - plan.w0), g1 * (1 - plan.w1), y);
        accumulate(block, frames, plan.d0, plan.d1, g0 * plan.w0, g1 * plan.w1, y);
    }
};

/// A tap as the audio thread plays it: where its gain and delay are now, and where they are going.
struct Voice {
    int32_t input;
    int32_t kind;
    float gain;      // now
    float target;    // where it is going
    int32_t fadeLeft; // samples left of a long fade; 0 means it reaches the target this buffer
    bool live;       // in the current state (otherwise it is fading out)
    DelayMotion delay;

    bool before(const Tap &t) const { return input != t.input ? input < t.input : kind < t.kind; }
    bool sameKey(const Tap &t) const { return input == t.input && kind == t.kind; }

    /// This buffer's gain ramp.
    void advanceGain(int frames, float &g0, float &g1) {
        g0 = gain;
        if (fadeLeft > frames) {
            gain += (target - gain) * static_cast<float>(frames) / static_cast<float>(fadeLeft);
            fadeLeft -= frames;
        } else {
            gain = target;
            fadeLeft = 0;
        }
        g1 = gain;
    }
};

/// One output's processing, as the audio thread runs it.
struct OutputRuntime {
    bool started = false; // false until the first buffer, which takes the targets as they are
    DelayMotion delay;
    feral_biquad eq[FERAL_EQ_BANDS];
    float z1[FERAL_EQ_BANDS], z2[FERAL_EQ_BANDS];
    float gain = 1;
    float mute = 1;       // 1 playing, 0 muted
    float envelope = 0;   // the limiter's peak follower
};

constexpr feral_biquad kFlat = {1, 0, 0, 0, 0};

inline bool isFlat(const feral_biquad &b) {
    return b.b0 == 1 && b.b1 == 0 && b.b2 == 0 && b.a1 == 0 && b.a2 == 0;
}

inline bool operator!=(const feral_biquad &a, const feral_biquad &b) {
    return a.b0 != b.b0 || a.b1 != b.b1 || a.b2 != b.b2 || a.a1 != b.a1 || a.a2 != b.a2;
}

inline float flushTiny(float v) { return std::fabs(v) < 1e-20f ? 0.0f : v; }

}
}

using namespace feral;

struct feral_core {
    double sampleRate;
    double maxDelay;

    // Shared between the threads. The control thread stores a new state into latest; the audio
    // thread loads it at the start of each buffer and, once it has switched, stores the state's
    // sequence into acknowledged. States are published in sequence order and the audio thread only
    // moves forward, so any state older than the acknowledged one will never be read again.
    std::atomic<RenderState *> latest{nullptr};
    std::atomic<uint64_t> acknowledged{0};

    // Audio thread only (and the control thread while the audio thread is detached).
    RenderState *current = nullptr;
    std::vector<Voice> voices = std::vector<Voice>(static_cast<size_t>(FERAL_MAX_CHANNELS) * kVoicesPerOutput);
    std::vector<int> voiceCount = std::vector<int>(FERAL_MAX_CHANNELS, 0);
    std::vector<Voice> mergeScratch = std::vector<Voice>(kVoicesPerOutput);
    int voiceOutputs = 0; // outputs below this may have voices
    std::vector<OutputRuntime> outputRuntime = std::vector<OutputRuntime>(FERAL_MAX_CHANNELS);
    float *lineMemory = nullptr;
    uint32_t lineMask = 0;
    uint32_t writeIndex = 0;   // where the next block goes in every delay line
    int inputLinesUsed = 0;    // input delay lines written since the last clear
    int outputLinesUsed = 0;
    const float *inputPointers[FERAL_MAX_CHANNELS] = {};
    float *outputPointers[FERAL_MAX_CHANNELS] = {};

    // Control side only. The mutex orders publish and collect if they run on different threads;
    // the audio thread never takes it.
    std::mutex controlMutex;
    uint64_t nextSequence = 1;
    std::vector<RenderState *> published; // oldest first, the newest last
    std::atomic<size_t> liveStates{0};

    // The test signal. The control side sets the targets; the generator's state is the audio thread's.
    std::atomic<int> testKind{FERAL_TEST_OFF};
    std::atomic<float> testGain{0};
    std::atomic<float> testHz{1000};
    std::vector<float> testBuffer = std::vector<float>(FERAL_TEST_MAX_FRAMES);
    float testLastGain = 0;
    uint32_t testRandom = 0x9E3779B9u;
    float pink[7] = {};
    double testPhase = 0;

    // Counters written by the audio thread.
    std::atomic<uint64_t> buffers{0};
    std::atomic<uint64_t> lateBuffers{0};
    std::atomic<uint64_t> stateSwaps{0};
    std::atomic<float> maxLoad{0};
    std::atomic<uint32_t> activeTaps{0};

    DelayLine inputLine(int in) { return {lineMemory + static_cast<size_t>(in) * (lineMask + 1), lineMask}; }
    DelayLine outputLine(int out) {
        return {lineMemory + static_cast<size_t>(FERAL_MAX_CHANNELS + out) * (lineMask + 1), lineMask};
    }
    Voice *outputVoices(int out) { return voices.data() + static_cast<size_t>(out) * kVoicesPerOutput; }
};

extern "C" {

feral_motion_params feral_motion_defaults(double sample_rate) {
    return {0.005f, static_cast<float>(0.005 * sample_rate), static_cast<float>(0.030 * sample_rate)};
}

feral_output_params feral_output_defaults(void) {
    feral_output_params p{};
    p.delay = 0;
    for (auto &b : p.eq) b = kFlat;
    p.gain = 1;
    p.limiter_threshold = 0;
    p.limiter_release = 9600; // 200 ms at 48 kHz
    p.mute = 0;
    return p;
}

feral_core *feral_core_create(double sample_rate) {
    auto *core = new feral_core;
    core->sampleRate = sample_rate > 0 ? sample_rate : 48000;
    core->maxDelay = std::floor(FERAL_MAX_DELAY_SECONDS * core->sampleRate);
    uint32_t length = 1;
    while (length < core->maxDelay + FERAL_MAX_FRAMES + 8) length <<= 1;
    core->lineMask = length - 1;
    // Untouched pages of calloc'd memory cost nothing, so lines for unused channels are free.
    core->lineMemory = static_cast<float *>(std::calloc(static_cast<size_t>(2 * FERAL_MAX_CHANNELS) * length, sizeof(float)));
    return core;
}

void feral_core_destroy(feral_core *core) {
    if (!core) return;
    for (RenderState *s : core->published) delete s;
    std::free(core->lineMemory);
    delete core;
}

double feral_core_max_delay(const feral_core *core) { return core->maxDelay; }

feral_state *feral_state_create(int inputs, int outputs) {
    if (inputs < 0 || outputs < 0 || inputs > FERAL_MAX_CHANNELS || outputs > FERAL_MAX_CHANNELS) return nullptr;
    return new feral_state(inputs, outputs);
}

void feral_state_destroy(feral_state *state) { delete state; }

int feral_state_add_gain(feral_state *state, int input, int output, float gain) {
    if (input < 0 || input >= state->inputs || output < 0 || output >= state->outputs) return -1;
    state->taps[output].push_back({input, FERAL_TAP_GAIN, gain, 0});
    return 0;
}

int feral_state_add_delay(feral_state *state, int input, int output, float gain, float delay) {
    if (input < 0 || input >= state->inputs || output < 0 || output >= state->outputs) return -1;
    state->taps[output].push_back({input, FERAL_TAP_DELAY, gain, std::isfinite(delay) ? delay : 0});
    return 0;
}

int feral_state_set_output(feral_state *state, int output, const feral_output_params *params) {
    if (output < 0 || output >= state->outputs) return -1;
    state->outputParams[output] = *params;
    return 0;
}

void feral_state_set_motion(feral_state *state, const feral_motion_params *motion) { state->motion = *motion; }

size_t feral_state_tap_count(const feral_state *state) {
    size_t n = 0;
    for (const auto &list : state->taps) n += list.size();
    return n;
}

int feral_core_publish(feral_core *core, feral_state *state, int fade_frames) {
    if (!state->finish(core->maxDelay)) {
        delete state;
        return -1;
    }
    state->fadeFrames = std::max(0, fade_frames);
    std::lock_guard<std::mutex> lock(core->controlMutex);
    state->sequence = core->nextSequence++;
    core->published.push_back(state);
    core->liveStates.fetch_add(1, std::memory_order_relaxed);
    core->latest.store(state, std::memory_order_release);
    return 0;
}

int feral_core_publish_gains(feral_core *core, const float *gains, int inputs, int outputs) {
    if (inputs < 0 || outputs < 0 || inputs > FERAL_MAX_CHANNELS || outputs > FERAL_MAX_CHANNELS) return -1;
    if (inputs * outputs > 0 && !gains) return -1;
    feral_state *state = feral_state_create(inputs, outputs);
    for (int out = 0; out < outputs; ++out)
        for (int in = 0; in < inputs; ++in)
            if (float g = gains[out * inputs + in]; g != 0.0f) state->taps[out].push_back({in, FERAL_TAP_GAIN, g, 0});
    return feral_core_publish(core, state, 0);
}

size_t feral_core_collect(feral_core *core) {
    std::lock_guard<std::mutex> lock(core->controlMutex);
    const uint64_t inUse = core->acknowledged.load(std::memory_order_acquire);
    auto &list = core->published;
    // Never free the newest: the audio thread may load it at any moment.
    size_t freeable = 0;
    while (freeable + 1 < list.size() && list[freeable]->sequence < inUse) ++freeable;
    for (size_t i = 0; i < freeable; ++i) delete list[i];
    list.erase(list.begin(), list.begin() + static_cast<std::ptrdiff_t>(freeable));
    core->liveStates.fetch_sub(freeable, std::memory_order_relaxed);
    return freeable;
}

size_t feral_core_live_states(const feral_core *core) {
    return core->liveStates.load(std::memory_order_relaxed);
}

void feral_core_audio_detached(feral_core *core) {
    std::lock_guard<std::mutex> lock(core->controlMutex);
    core->current = nullptr;
    // Start again from silence: no taps playing, empty delay lines, filters at rest.
    std::fill(core->voiceCount.begin(), core->voiceCount.end(), 0);
    core->voiceOutputs = 0;
    core->activeTaps.store(0, std::memory_order_relaxed);
    for (auto &r : core->outputRuntime) r = OutputRuntime{};
    const size_t length = core->lineMask + 1;
    for (int in = 0; in < core->inputLinesUsed; ++in) std::memset(core->inputLine(in).data, 0, length * sizeof(float));
    for (int out = 0; out < core->outputLinesUsed; ++out) std::memset(core->outputLine(out).data, 0, length * sizeof(float));
    core->inputLinesUsed = core->outputLinesUsed = 0;
    RenderState *newest = core->latest.load(std::memory_order_acquire);
    // Nothing reads the older states now; the newest stays for the next start.
    core->acknowledged.store(newest ? newest->sequence : 0, std::memory_order_release);
}

void feral_core_set_test_signal(feral_core *core, int kind, float level_db, float sine_hz) {
    core->testGain.store(std::pow(10.0f, level_db / 20.0f), std::memory_order_relaxed);
    core->testHz.store(sine_hz > 0 ? sine_hz : 1000, std::memory_order_relaxed);
    core->testKind.store(kind, std::memory_order_relaxed);
}

}

namespace {

// Built before main, so the audio thread never runs a static initialiser (which may take a lock).
const std::vector<Tap> kNoTaps;
const feral_output_params kPlain = feral_output_defaults();
const feral_motion_params kStill = {0, 0, 1};

/// Fills the core's test buffer with the generated signal. Audio thread only.
const float *generateTestSignal(feral_core *core, int frames) {
    const int kind = core->testKind.load(std::memory_order_relaxed);
    if (kind == FERAL_TEST_OFF || frames > FERAL_TEST_MAX_FRAMES) {
        core->testLastGain = 0;
        return nullptr;
    }
    float *y = core->testBuffer.data();
    if (kind == FERAL_TEST_SINE) {
        // RMS of a sine is its peak over sqrt 2.
        const double step = 2 * M_PI * core->testHz.load(std::memory_order_relaxed) / core->sampleRate;
        for (int n = 0; n < frames; ++n) {
            y[n] = static_cast<float>(std::sqrt(2.0) * std::sin(core->testPhase));
            core->testPhase += step;
        }
        core->testPhase = std::fmod(core->testPhase, 2 * M_PI);
    } else {
        // White noise (xorshift32) through Paul Kellet's pink filter, scaled to an RMS of 1.
        float *b = core->pink;
        uint32_t r = core->testRandom;
        for (int n = 0; n < frames; ++n) {
            r ^= r << 13; r ^= r >> 17; r ^= r << 5;
            const float w = static_cast<float>(r) * (2.0f / 4294967296.0f) - 1.0f;
            b[0] = 0.99886f * b[0] + w * 0.0555179f;
            b[1] = 0.99332f * b[1] + w * 0.0750759f;
            b[2] = 0.96900f * b[2] + w * 0.1538520f;
            b[3] = 0.86650f * b[3] + w * 0.3104856f;
            b[4] = 0.55000f * b[4] + w * 0.5329522f;
            b[5] = -0.7616f * b[5] - w * 0.0168980f;
            y[n] = (b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362f) * 0.5667f;
            b[6] = w * 0.115926f;
        }
        core->testRandom = r;
    }
    // Ramp from the last buffer's level, so switching on or changing level does not click.
    const float g0 = core->testLastGain, g1 = core->testGain.load(std::memory_order_relaxed);
    const float step = (g1 - g0) / static_cast<float>(frames);
    for (int n = 0; n < frames; ++n) y[n] *= g0 + step * static_cast<float>(n + 1);
    core->testLastGain = g1;
    return y;
}

// y += g * x
inline void accumulate(float *y, const float *x, float g, int frames) {
    for (int n = 0; n < frames; ++n) y[n] += g * x[n];
}

// y += (g0 + (g1 - g0) * (n + 1) / frames) * x: reaches g1 exactly on the buffer's last sample.
inline void accumulateRamp(float *y, const float *x, float g0, float g1, int frames) {
    const float step = (g1 - g0) / static_cast<float>(frames);
    for (int n = 0; n < frames; ++n) y[n] += (g0 + step * static_cast<float>(n + 1)) * x[n];
}

/// Matches the playing voices to a new state's taps, output by output (both lists are sorted by
/// key). Matched voices take the new targets, new taps start silent at their delay, and voices
/// whose tap is gone fade out. Audio thread; no allocation.
void mergeState(feral_core *core, const RenderState *next) {
    const int fade = next->fadeFrames;
    const int outputs = std::max(core->voiceOutputs, next->outputs);
    for (int out = 0; out < outputs; ++out) {
        Voice *old = core->outputVoices(out);
        const int oldCount = core->voiceCount[out];
        const std::vector<Tap> &taps = out < next->outputs ? next->taps[out] : kNoTaps;
        Voice *merged = core->mergeScratch.data();
        int count = 0, i = 0;
        size_t j = 0;
        while (i < oldCount || j < taps.size()) {
            Voice v;
            if (j == taps.size() || (i < oldCount && old[i].before(taps[j]))) {
                v = old[i++];
                v.target = 0;
                v.live = false;
            } else if (i == oldCount || !old[i].sameKey(taps[j])) {
                const Tap &t = taps[j++];
                v = Voice{t.input, t.kind, 0, t.gain, 0, true, {}};
                v.delay.reset(t.delay);
            } else {
                v = old[i++];
                const Tap &t = taps[j++];
                v.target = t.gain;
                v.live = true;
                v.delay.target = t.delay;
            }
            v.fadeLeft = std::max(v.fadeLeft, fade);
            merged[count++] = v; // keys are distinct per output, so count stays within kVoicesPerOutput
        }
        std::copy(merged, merged + count, old);
        core->voiceCount[out] = count;
    }
    core->voiceOutputs = outputs;
}

/// Runs one output's processing in place on y. Audio thread.
void processOutput(feral_core *core, int out, const feral_output_params &p, float release,
                   const feral_motion_params &motion, uint32_t block, float *y, int frames) {
    OutputRuntime &r = core->outputRuntime[out];
    const float targetMute = p.mute ? 0.0f : 1.0f;
    if (!r.started) {
        r.started = true;
        r.delay.reset(p.delay);
        std::copy(p.eq, p.eq + FERAL_EQ_BANDS, r.eq);
        std::fill(r.z1, r.z1 + FERAL_EQ_BANDS, 0.0f);
        std::fill(r.z2, r.z2 + FERAL_EQ_BANDS, 0.0f);
        r.gain = p.gain;
        r.mute = targetMute;
        r.envelope = 0;
    }
    const float inv = 1.0f / static_cast<float>(frames);

    // Alignment delay. The line is always written, so a delay set later has the history it needs.
    DelayLine line = core->outputLine(out);
    line.write(block, y, frames);
    r.delay.target = p.delay;
    if (r.delay.current != 0 || r.delay.target != 0 || r.delay.length != 0) {
        const DelayPlan plan = advance(r.delay, motion, frames);
        std::fill(y, y + frames, 0.0f);
        line.accumulate(block, frames, plan, 1, 1, y);
    }

    // EQ: transposed direct form II, coefficients interpolated over the buffer when they change.
    for (int b = 0; b < FERAL_EQ_BANDS; ++b) {
        feral_biquad c = r.eq[b];
        const feral_biquad &t = p.eq[b];
        const bool changing = c != t;
        if (!changing && isFlat(c)) continue;
        float z1 = r.z1[b], z2 = r.z2[b];
        if (!changing) {
            for (int n = 0; n < frames; ++n) {
                const float x = y[n];
                const float v = c.b0 * x + z1;
                z1 = c.b1 * x - c.a1 * v + z2;
                z2 = c.b2 * x - c.a2 * v;
                y[n] = v;
            }
        } else {
            const feral_biquad d = {(t.b0 - c.b0) * inv, (t.b1 - c.b1) * inv, (t.b2 - c.b2) * inv,
                                    (t.a1 - c.a1) * inv, (t.a2 - c.a2) * inv};
            for (int n = 0; n < frames; ++n) {
                c.b0 += d.b0; c.b1 += d.b1; c.b2 += d.b2; c.a1 += d.a1; c.a2 += d.a2;
                const float x = y[n];
                const float v = c.b0 * x + z1;
                z1 = c.b1 * x - c.a1 * v + z2;
                z2 = c.b2 * x - c.a2 * v;
                y[n] = v;
            }
            r.eq[b] = t;
        }
        r.z1[b] = flushTiny(z1);
        r.z2[b] = flushTiny(z2);
    }

    // Trim and polarity.
    if (r.gain != p.gain) {
        const float g0 = r.gain, step = (p.gain - g0) * inv;
        for (int n = 0; n < frames; ++n) y[n] *= g0 + step * static_cast<float>(n + 1);
        r.gain = p.gain;
    } else if (r.gain != 1) {
        for (int n = 0; n < frames; ++n) y[n] *= r.gain;
    }

    // Limiter: the follower jumps to any higher peak at once and decays at the release rate, and the
    // gain brings the follower down to the threshold, so no sample leaves above it.
    if (p.limiter_threshold > 0) {
        const float threshold = p.limiter_threshold;
        float env = r.envelope;
        for (int n = 0; n < frames; ++n) {
            env = std::max(std::fabs(y[n]), env * release);
            if (env > threshold) y[n] *= threshold / env;
        }
        r.envelope = flushTiny(env);
    } else {
        r.envelope = 0;
    }

    // Mute.
    if (r.mute != targetMute) {
        const float m0 = r.mute, step = (targetMute - m0) * inv;
        for (int n = 0; n < frames; ++n) y[n] *= m0 + step * static_cast<float>(n + 1);
        r.mute = targetMute;
    } else if (r.mute == 0) {
        std::fill(y, y + frames, 0.0f);
    }
}

void renderBlock(feral_core *core, const float *const *inputs, int num_inputs, float *const *outputs,
                 int num_outputs, int frames) {
    RenderState *previous = core->current;
    RenderState *next = core->latest.load(std::memory_order_acquire);
    if (next != previous) {
        if (next) mergeState(core, next);
        core->current = next;
        if (next) core->acknowledged.store(next->sequence, std::memory_order_release);
        core->stateSwaps.fetch_add(1, std::memory_order_relaxed);
    }

    const float *test = generateTestSignal(core, frames);
    auto input = [&](int in) -> const float * {
        if (in == 0 && test) return test;
        return in < num_inputs ? inputs[in] : nullptr;
    };

    // Every input goes into its delay line first, so a tap can read the sample that just arrived.
    const uint32_t block = core->writeIndex;
    const int lines = std::min(FERAL_MAX_CHANNELS, std::max(num_inputs, test ? 1 : 0));
    for (int in = 0; in < lines; ++in) core->inputLine(in).write(block, input(in), frames);
    core->inputLinesUsed = std::max(core->inputLinesUsed, lines);

    const feral_motion_params &motion = next ? next->motion : kStill;
    uint32_t active = 0;

    const int rendered = std::min(num_outputs, FERAL_MAX_CHANNELS);
    for (int out = 0; out < rendered; ++out) {
        float *y = outputs[out];
        if (!y) continue;
        std::fill(y, y + frames, 0.0f);
        if (out >= core->voiceOutputs && !(next && out < next->outputs)) continue;

        Voice *vs = core->outputVoices(out);
        int count = out < core->voiceOutputs ? core->voiceCount[out] : 0;
        int kept = 0;
        for (int i = 0; i < count; ++i) {
            Voice &v = vs[i];
            float g0, g1;
            v.advanceGain(frames, g0, g1);
            if (v.kind == FERAL_TAP_GAIN) {
                if (const float *x = input(v.input)) {
                    if (g0 == g1) accumulate(y, x, g1, frames);
                    else accumulateRamp(y, x, g0, g1, frames);
                }
            } else {
                const DelayPlan plan = advance(v.delay, motion, frames);
                if (v.input < lines) core->inputLine(v.input).accumulate(block, frames, plan, g0, g1, y);
            }
            // A voice whose tap is gone stays until it has faded out.
            if (v.live || v.gain != 0.0f) vs[kept++] = v;
        }
        if (out < core->voiceOutputs) core->voiceCount[out] = kept;
        active += static_cast<uint32_t>(kept);

        const bool inState = next && out < next->outputs;
        processOutput(core, out, inState ? next->outputParams[out] : kPlain, inState ? next->limiterRelease[out] : 0,
                      motion, block, y, frames);
        core->outputLinesUsed = std::max(core->outputLinesUsed, out + 1);
    }
    core->writeIndex = block + static_cast<uint32_t>(frames);
    core->activeTaps.store(active, std::memory_order_relaxed);
}

}

extern "C" {

void feral_core_render(feral_core *core, const float *const *inputs, int num_inputs,
                       float *const *outputs, int num_outputs, int frames) {
    using clock = std::chrono::steady_clock;
    const auto started = clock::now();
    if (frames <= 0) return;
    num_inputs = std::clamp(num_inputs, 0, FERAL_MAX_CHANNELS);
    num_outputs = std::clamp(num_outputs, 0, FERAL_MAX_CHANNELS);

    // Longer buffers than the core's blocks are rendered in pieces.
    for (int done = 0; done < frames;) {
        const int n = std::min(FERAL_MAX_FRAMES, frames - done);
        if (done == 0 && n == frames) {
            renderBlock(core, inputs, num_inputs, outputs, num_outputs, n);
        } else {
            for (int i = 0; i < num_inputs; ++i) core->inputPointers[i] = inputs[i] ? inputs[i] + done : nullptr;
            for (int o = 0; o < num_outputs; ++o) core->outputPointers[o] = outputs[o] ? outputs[o] + done : nullptr;
            renderBlock(core, core->inputPointers, num_inputs, core->outputPointers, num_outputs, n);
        }
        done += n;
    }

    const double elapsed = std::chrono::duration<double>(clock::now() - started).count();
    const float load = static_cast<float>(elapsed * core->sampleRate / frames);
    core->buffers.fetch_add(1, std::memory_order_relaxed);
    if (load > 0.8f) core->lateBuffers.fetch_add(1, std::memory_order_relaxed);
    if (load > core->maxLoad.load(std::memory_order_relaxed)) core->maxLoad.store(load, std::memory_order_relaxed);
}

void feral_core_get_stats(feral_core *core, feral_core_stats *stats, int reset_max_load) {
    stats->buffers = core->buffers.load(std::memory_order_relaxed);
    stats->late_buffers = core->lateBuffers.load(std::memory_order_relaxed);
    stats->state_swaps = core->stateSwaps.load(std::memory_order_relaxed);
    stats->current_state = core->acknowledged.load(std::memory_order_relaxed);
    stats->max_load = reset_max_load ? core->maxLoad.exchange(0, std::memory_order_relaxed)
                                     : core->maxLoad.load(std::memory_order_relaxed);
    stats->active_taps = core->activeTaps.load(std::memory_order_relaxed);
}

}
