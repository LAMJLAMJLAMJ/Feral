#include "feral_core.h"
#include "render_state.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <os/workgroup.h>
#endif

using feral::RenderState;
using feral::Tap;

feral_state::feral_state(int inputs, int outputs)
    : inputs(inputs), outputs(outputs), taps(outputs), outputParams(outputs, feral_output_defaults()),
      inputParams(inputs, feral_input_defaults()), limiterRelease(outputs, 1.0f), motion(feral_motion_defaults(48000)) {}

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
    for (int in = 0; in < inputs; ++in) {
        feral_input_params &p = inputParams[in];
        auto unit = [](float v) { return std::isfinite(v) ? std::clamp(v, 0.0f, 0.999999f) : 0.0f; };
        if (!std::isfinite(p.comp_threshold) || p.comp_threshold < 0) p.comp_threshold = 0;
        if (!std::isfinite(p.comp_ratio) || p.comp_ratio < 1) p.comp_ratio = 1;
        p.comp_attack = unit(p.comp_attack);
        p.comp_release = unit(p.comp_release);
        if (!std::isfinite(p.comp_makeup) || p.comp_makeup < 0) p.comp_makeup = 1;
        if (p.link < 0 || p.link >= inputs || p.link == in) p.link = -1;
        p.delay = std::isfinite(p.delay) ? static_cast<float>(std::clamp<double>(p.delay, 0, maxDelay)) : 0.0f;
        p.trim = std::isfinite(p.trim) ? std::clamp(p.trim, -16.0f, 16.0f) : 1.0f;
        for (auto &b : p.bands) {
            if (!std::isfinite(b.threshold) || b.threshold < 0) b.threshold = 0;
            if (!std::isfinite(b.ratio) || b.ratio < 1) b.ratio = 1;
            b.attack = unit(b.attack);
            b.release = unit(b.release);
            if (!std::isfinite(b.gain) || b.gain < 0) b.gain = 1;
        }
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
    void accumulate(uint32_t block, int frames, double d0, double d1, float g0, float g1, float *__restrict y) const {
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
        const float *__restrict x = data + oldest + 2; // x[m] here is the input k samples before block sample m
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

/// One input's EQ and compressor, as the audio thread runs them. Everything starts at rest: a flat
/// EQ (so a new EQ ramps in over a buffer), the follower at silence, unity makeup.
struct InputRuntime {
    feral_biquad eq[FERAL_INPUT_EQ_BANDS];
    float z1[FERAL_INPUT_EQ_BANDS], z2[FERAL_INPUT_EQ_BANDS];
    float envelope = 0;
    float makeup = 1;
    DelayMotion delay;
    float trim = 1;
    // Multiband: the crossover's sections now and their state, each band's follower and gain.
    bool split = false;
    feral_biquad crossover[FERAL_CROSSOVER_SECTIONS];
    float xz1[FERAL_CROSSOVER_SECTIONS], xz2[FERAL_CROSSOVER_SECTIONS];
    float bandEnvelope[FERAL_COMP_BANDS] = {};
    float bandGain[FERAL_COMP_BANDS] = {1, 1, 1};

    InputRuntime() {
        for (auto &b : crossover) b = {1, 0, 0, 0, 0};
        std::fill(xz1, xz1 + FERAL_CROSSOVER_SECTIONS, 0.0f);
        std::fill(xz2, xz2 + FERAL_CROSSOVER_SECTIONS, 0.0f);
        for (auto &b : eq) b = {1, 0, 0, 0, 0};
        std::fill(z1, z1 + FERAL_INPUT_EQ_BANDS, 0.0f);
        std::fill(z2, z2 + FERAL_INPUT_EQ_BANDS, 0.0f);
    }
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

/// The per-output work of one block, as the audio thread hands it to the workers.
struct RenderJob {
    float *const *outputs = nullptr;
    int frames = 0;
    uint32_t block = 0;
    int lines = 0;
    const RenderState *next = nullptr;
    const feral_motion_params *motion = nullptr;
    int rendered = 0;
};

/// Render workers. Each block the audio thread writes the job, then publishes a ticket holding the
/// number of chunks (of kChunkOutputs outputs each) and wakes the workers; everyone, the audio
/// thread too, takes chunk numbers from the ticket until none are left, and the audio thread waits
/// for the chunks already taken. A ticket taken from an earlier block holds a number past its own
/// chunk count, so a late worker does nothing.
struct WorkerPool {
    static constexpr int kChunkOutputs = 4;
    std::vector<std::thread> threads;
    std::atomic<uint32_t> generation{0};
    std::atomic<bool> quit{false};
    std::atomic<uint64_t> ticket{0}; // chunk count << 32 | next chunk
    std::atomic<int> chunksDone{0};
    std::atomic<uint32_t> active{0};
    RenderJob job;
#ifdef __APPLE__
    std::mutex workgroupMutex;
    std::vector<os_workgroup_t> retained; // every workgroup ever set, released on destroy
    std::atomic<os_workgroup_t> workgroup{nullptr};
    std::atomic<uint32_t> workgroupSeq{0};
#endif
};

struct feral_core {
    double sampleRate;
    double maxDelay;
    WorkerPool *pool = nullptr;

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
    std::vector<InputRuntime> inputRuntime = std::vector<InputRuntime>(FERAL_MAX_CHANNELS);
    // Processed inputs, one block each. Untouched pages cost nothing, so unprocessed inputs are free.
    float *inputScratch = nullptr;
    const float *inputSources[FERAL_MAX_CHANNELS] = {};
    const float *rawInputs[FERAL_MAX_CHANNELS] = {};
    // A linked pair's bands while its multiband compressor runs: [side][band], one block each.
    std::vector<float> bandScratch = std::vector<float>(static_cast<size_t>(2 * FERAL_COMP_BANDS) * FERAL_MAX_FRAMES);
    float *lineMemory = nullptr;
    uint32_t lineMask = 0;
    uint32_t writeIndex = 0;   // where the next block goes in every delay line
    int inputLinesUsed = 0;    // input delay lines written since the last clear
    int preLinesUsed = 0;      // the same for inputs' own delay lines
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

    // Level meters. The audio thread writes them; one other thread reads them (feral_core_read_meters).
    // Peaks are linear and start again from 0 when read; powers are mean squares averaged over about
    // 300 ms. The *State arrays are the audio thread's own copies of the averages.
    std::array<std::atomic<float>, FERAL_MAX_CHANNELS> inputPeak{}, inputPower{}, outputPeak{}, outputPower{};
    std::array<float, FERAL_MAX_CHANNELS> inputPowerState{}, outputPowerState{};
    // Each input compressor's deepest reduction in dB since the last read.
    std::array<std::atomic<float>, FERAL_MAX_CHANNELS> inputReduction{};
    std::array<std::atomic<float>, static_cast<size_t>(FERAL_MAX_CHANNELS) * FERAL_COMP_BANDS> bandReduction{};

    // The analysis tap: one input's samples before and after its processing, in rings the audio
    // thread writes and one other thread reads (feral_core_read_analysis).
    std::atomic<int> analysisInput{-1};
    int analysisLast = -1; // audio thread: the input the rings hold
    std::atomic<uint64_t> analysisWritten{0};
    std::array<std::atomic<float>, FERAL_ANALYSIS_FRAMES> analysisPre{}, analysisPost{};
    int meteredInputs = 0, meteredOutputs = 0;

    DelayLine inputLine(int in) { return {lineMemory + static_cast<size_t>(in) * (lineMask + 1), lineMask}; }
    DelayLine preLine(int in) {
        return {lineMemory + static_cast<size_t>(2 * FERAL_MAX_CHANNELS + in) * (lineMask + 1), lineMask};
    }
    DelayLine outputLine(int out) {
        return {lineMemory + static_cast<size_t>(FERAL_MAX_CHANNELS + out) * (lineMask + 1), lineMask};
    }
    Voice *outputVoices(int out) { return voices.data() + static_cast<size_t>(out) * kVoicesPerOutput; }
};

namespace {
void workerMain(feral_core *core);
}

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

feral_input_params feral_input_defaults(void) {
    feral_input_params p{};
    for (auto &b : p.eq) b = kFlat;
    p.comp_threshold = 0;
    p.comp_ratio = 1;
    p.comp_attack = 0;
    p.comp_release = 0;
    p.comp_makeup = 1;
    p.delay = 0;
    p.trim = 1;
    p.multiband = 0;
    for (auto &b : p.crossover) b = kFlat;
    for (auto &b : p.bands) b = {0, 1, 0, 0, 1};
    p.link = -1;
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
    // Input delay lines (taps read them), output alignment lines, and the lines for inputs' own delay.
    core->lineMemory = static_cast<float *>(std::calloc(static_cast<size_t>(3 * FERAL_MAX_CHANNELS) * length, sizeof(float)));
    core->inputScratch = static_cast<float *>(std::calloc(static_cast<size_t>(FERAL_MAX_CHANNELS) * FERAL_MAX_FRAMES, sizeof(float)));
    return core;
}

int feral_core_start_workers(feral_core *core, int count) {
    if (core->pool || count <= 0) return feral_core_workers(core);
    core->pool = new WorkerPool;
    const int n = std::min(count, FERAL_MAX_WORKERS);
    for (int i = 0; i < n; ++i) core->pool->threads.emplace_back(workerMain, core);
    return n;
}

int feral_core_workers(const feral_core *core) { return core->pool ? static_cast<int>(core->pool->threads.size()) : 0; }

void feral_core_set_workgroup(feral_core *core, void *workgroup) {
#ifdef __APPLE__
    if (!core->pool) return;
    WorkerPool &p = *core->pool;
    std::lock_guard<std::mutex> lock(p.workgroupMutex);
    auto wg = static_cast<os_workgroup_t>(workgroup);
    if (wg) {
        os_retain(wg);
        p.retained.push_back(wg);
    }
    p.workgroup.store(wg, std::memory_order_release);
    p.workgroupSeq.fetch_add(1, std::memory_order_acq_rel);
    // Wake the workers so they join it before the next block.
    p.generation.fetch_add(1, std::memory_order_release);
    p.generation.notify_all();
#else
    (void)core;
    (void)workgroup;
#endif
}

void feral_core_destroy(feral_core *core) {
    if (!core) return;
    if (WorkerPool *p = core->pool) {
        p->quit.store(true, std::memory_order_release);
        p->generation.fetch_add(1, std::memory_order_release);
        p->generation.notify_all();
        for (std::thread &t : p->threads) t.join();
#ifdef __APPLE__
        for (os_workgroup_t wg : p->retained) os_release(wg);
#endif
        delete p;
    }
    for (RenderState *s : core->published) delete s;
    std::free(core->lineMemory);
    std::free(core->inputScratch);
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

int feral_state_set_input(feral_state *state, int input, const feral_input_params *params) {
    if (input < 0 || input >= state->inputs) return -1;
    state->inputParams[input] = *params;
    return 0;
}

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
    for (auto &r : core->inputRuntime) r = InputRuntime{};
    const size_t length = core->lineMask + 1;
    for (int in = 0; in < core->inputLinesUsed; ++in) std::memset(core->inputLine(in).data, 0, length * sizeof(float));
    for (int in = 0; in < core->preLinesUsed; ++in) std::memset(core->preLine(in).data, 0, length * sizeof(float));
    core->preLinesUsed = 0;
    for (int out = 0; out < core->outputLinesUsed; ++out) std::memset(core->outputLine(out).data, 0, length * sizeof(float));
    core->inputLinesUsed = core->outputLinesUsed = 0;
    // The meters fall to silence; nothing is playing.
    core->inputPowerState.fill(0);
    core->outputPowerState.fill(0);
    for (int i = 0; i < FERAL_MAX_CHANNELS; ++i) {
        core->inputPower[i].store(0, std::memory_order_relaxed);
        core->outputPower[i].store(0, std::memory_order_relaxed);
        core->inputReduction[i].store(0, std::memory_order_relaxed);
        for (int b = 0; b < FERAL_COMP_BANDS; ++b) core->bandReduction[i * FERAL_COMP_BANDS + b].store(0, std::memory_order_relaxed);
    }
    core->meteredInputs = core->meteredOutputs = 0;
    RenderState *newest = core->latest.load(std::memory_order_acquire);
    // Nothing reads the older states now; the newest stays for the next start.
    core->acknowledged.store(newest ? newest->sequence : 0, std::memory_order_release);
}

void feral_core_set_test_signal(feral_core *core, int kind, float level_db, float sine_hz) {
    core->testGain.store(std::pow(10.0f, level_db / 20.0f), std::memory_order_relaxed);
    core->testHz.store(sine_hz > 0 ? sine_hz : 1000, std::memory_order_relaxed);
    core->testKind.store(kind, std::memory_order_relaxed);
}

void feral_core_read_meters(feral_core *core, float *input_peak, float *input_rms, int inputs,
                            float *output_peak, float *output_rms, int outputs) {
    inputs = std::clamp(inputs, 0, FERAL_MAX_CHANNELS);
    outputs = std::clamp(outputs, 0, FERAL_MAX_CHANNELS);
    for (int i = 0; i < inputs; ++i) {
        if (input_peak) input_peak[i] = core->inputPeak[i].exchange(0, std::memory_order_relaxed);
        if (input_rms) input_rms[i] = std::sqrt(core->inputPower[i].load(std::memory_order_relaxed));
    }
    for (int o = 0; o < outputs; ++o) {
        if (output_peak) output_peak[o] = core->outputPeak[o].exchange(0, std::memory_order_relaxed);
        if (output_rms) output_rms[o] = std::sqrt(core->outputPower[o].load(std::memory_order_relaxed));
    }
}

void feral_core_set_analysis_input(feral_core *core, int input) {
    core->analysisInput.store(input >= 0 && input < FERAL_MAX_CHANNELS ? input : -1, std::memory_order_relaxed);
}

uint64_t feral_core_read_analysis(feral_core *core, float *pre, float *post, int frames) {
    frames = std::clamp(frames, 0, FERAL_ANALYSIS_FRAMES);
    const uint64_t written = core->analysisWritten.load(std::memory_order_acquire);
    const uint64_t have = std::min<uint64_t>(written, static_cast<uint64_t>(frames));
    const int zeros = frames - static_cast<int>(have);
    for (int n = 0; n < zeros; ++n) pre[n] = post[n] = 0;
    for (uint64_t k = 0; k < have; ++k) {
        const size_t i = static_cast<size_t>((written - have + k) & (FERAL_ANALYSIS_FRAMES - 1));
        pre[zeros + k] = core->analysisPre[i].load(std::memory_order_relaxed);
        post[zeros + k] = core->analysisPost[i].load(std::memory_order_relaxed);
    }
    return written;
}

void feral_core_read_band_reduction(feral_core *core, float *reduction_db, int inputs) {
    inputs = std::clamp(inputs, 0, FERAL_MAX_CHANNELS);
    for (int i = 0; i < inputs * FERAL_COMP_BANDS; ++i) reduction_db[i] = core->bandReduction[i].exchange(0, std::memory_order_relaxed);
}

void feral_core_read_reduction(feral_core *core, float *reduction_db, int inputs) {
    inputs = std::clamp(inputs, 0, FERAL_MAX_CHANNELS);
    for (int i = 0; i < inputs; ++i) reduction_db[i] = core->inputReduction[i].exchange(0, std::memory_order_relaxed);
}

}

namespace {

// Built before main, so the audio thread never runs a static initialiser (which may take a lock).
const std::vector<Tap> kNoTaps;
const feral_output_params kPlain = feral_output_defaults();
const feral_input_params kNone = feral_input_defaults();
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

/// Runs EQ bands in place on y: each band moves from cur to target over the buffer (transposed
/// direct form II). A band whose coefficients change runs on its own, interpolated; the steady bands
/// then run together sample by sample, which lets the processor overlap them (each band alone is one
/// long chain of dependent multiplies). Bands in series commute, so the order does not change the result.
void runEQ(feral_biquad *cur, float *z1s, float *z2s, const feral_biquad *target, int bands, float *y, int frames) {
    const float inv = 1.0f / static_cast<float>(frames);
    feral_biquad steady[FERAL_EQ_BANDS];
    float s1[FERAL_EQ_BANDS], s2[FERAL_EQ_BANDS];
    int steadyBand[FERAL_EQ_BANDS];
    int steadyCount = 0;
    for (int b = 0; b < bands; ++b) {
        feral_biquad c = cur[b];
        const feral_biquad &t = target[b];
        if (c != t) {
            float z1 = z1s[b], z2 = z2s[b];
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
            cur[b] = t;
            z1s[b] = flushTiny(z1);
            z2s[b] = flushTiny(z2);
        } else if (!isFlat(c)) {
            steady[steadyCount] = c;
            s1[steadyCount] = z1s[b];
            s2[steadyCount] = z2s[b];
            steadyBand[steadyCount++] = b;
        }
    }
    if (steadyCount > 0) {
        for (int n = 0; n < frames; ++n) {
            float x = y[n];
            for (int k = 0; k < steadyCount; ++k) {
                const feral_biquad &c = steady[k];
                const float v = c.b0 * x + s1[k];
                s1[k] = c.b1 * x - c.a1 * v + s2[k];
                s2[k] = c.b2 * x - c.a2 * v;
                x = v;
            }
            y[n] = x;
        }
        for (int k = 0; k < steadyCount; ++k) {
            z1s[steadyBand[k]] = flushTiny(s1[k]);
            z2s[steadyBand[k]] = flushTiny(s2[k]);
        }
    }
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

    // EQ.
    runEQ(r.eq, r.z1, r.z2, p.eq, FERAL_EQ_BANDS, y, frames);

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

/// Meters one block of a channel (x null is silence): its peak joins the peak not yet read, and its
/// mean square moves the running average by `a`. Audio thread only.
void meterBlock(const float *x, int frames, float a, float &state, std::atomic<float> &peak, std::atomic<float> &power) {
    float p = 0, sum = 0;
    if (x) {
        for (int n = 0; n < frames; ++n) {
            const float v = x[n];
            p = std::max(p, std::fabs(v));
            sum += v * v;
        }
    }
    state = flushTiny(state + a * (sum / static_cast<float>(frames) - state));
    power.store(state, std::memory_order_relaxed);
    // The reader may zero the peak between this load and store; then this block's peak is kept, as it should be.
    if (p > peak.load(std::memory_order_relaxed)) peak.store(p, std::memory_order_relaxed);
}

/// Compresses y in place: the follower moves towards each sample's level (the detector's, when
/// given) at the attack rate going up and the release rate coming down, and above the threshold the
/// gain brings the level to threshold * (level / threshold)^(1 / ratio). Returns the lowest gain.
float compress(float *y, const float *detector, float &envelope, float threshold, float ratio, float attack,
               float release, int frames) {
    const float slope = 1.0f / ratio - 1.0f;
    float env = envelope, deepest = 1;
    for (int n = 0; n < frames; ++n) {
        const float level = detector ? detector[n] : std::fabs(y[n]);
        env = level > env ? attack * env + (1 - attack) * level : release * env + (1 - release) * level;
        if (env > threshold) {
            const float g = std::pow(env / threshold, slope);
            deepest = std::min(deepest, g);
            y[n] *= g;
        }
    }
    envelope = flushTiny(env);
    return deepest;
}

/// y *= gain, ramping from `now` to `target` over the block when they differ; now becomes target.
void rampGain(float *y, float &now, float target, int frames) {
    if (now != target) {
        const float g0 = now, step = (target - g0) / static_cast<float>(frames);
        for (int n = 0; n < frames; ++n) y[n] *= g0 + step * static_cast<float>(n + 1);
        now = target;
    } else if (now != 1) {
        for (int n = 0; n < frames; ++n) y[n] *= now;
    }
}

/// Runs one processing block of the first `lines` inputs' EQ and compressor, and points
/// core->inputSources at what each input plays: the input itself when it has no processing (and
/// none is still settling), otherwise its processed copy. Audio thread; no allocation.
void processInputs(feral_core *core, const RenderState *next, const float *const *raw, int lines, int frames,
                   uint32_t block, const feral_motion_params &motion) {
    bool busy[FERAL_MAX_CHANNELS];
    for (int in = 0; in < lines; ++in) {
        const feral_input_params &p = next && in < next->inputs ? next->inputParams[in] : kNone;
        InputRuntime &r = core->inputRuntime[in];
        // Every input's own delay line is written, so a delay set later has the history it needs.
        DelayLine line = core->preLine(in);
        line.write(block, raw[in], frames);
        bool eq = false;
        for (int b = 0; b < FERAL_INPUT_EQ_BANDS; ++b) eq = eq || !isFlat(p.eq[b]) || !isFlat(r.eq[b]);
        const bool delayed = p.delay != 0 || r.delay.current != 0 || r.delay.target != 0 || r.delay.length != 0;
        busy[in] = raw[in] && (eq || delayed || p.trim != 1 || r.trim != 1 || p.comp_threshold > 0 || p.multiband ||
                               r.split || p.comp_makeup != 1 || r.makeup != 1);
        if (!busy[in]) {
            core->inputSources[in] = raw[in];
            r = InputRuntime{};
            continue;
        }
        float *y = core->inputScratch + static_cast<size_t>(in) * FERAL_MAX_FRAMES;
        if (delayed) {
            r.delay.target = p.delay;
            const DelayPlan plan = advance(r.delay, motion, frames);
            std::fill(y, y + frames, 0.0f);
            line.accumulate(block, frames, plan, 1, 1, y);
        } else {
            std::copy(raw[in], raw[in] + frames, y);
        }
        rampGain(y, r.trim, p.trim, frames);
        if (eq) runEQ(r.eq, r.z1, r.z2, p.eq, FERAL_INPUT_EQ_BANDS, y, frames);
        core->inputSources[in] = y;
    }

    // Compressors, after every EQ. A linked pair runs together, when its first input comes up: both
    // followers hear the louder side, so both sides duck alike and the image stays put (band by band
    // when multiband).
    bool done[FERAL_MAX_CHANNELS] = {};
    float *ys[2];
    int ins[2];
    for (int in = 0; in < lines; ++in) {
        if (!busy[in] || done[in]) continue;
        const feral_input_params &p = next && in < next->inputs ? next->inputParams[in] : kNone;
        int count = 1;
        ins[0] = in;
        ys[0] = core->inputScratch + static_cast<size_t>(in) * FERAL_MAX_FRAMES;
        if (p.link > in && p.link < lines && busy[p.link]) {
            ins[1] = p.link;
            ys[1] = core->inputScratch + static_cast<size_t>(p.link) * FERAL_MAX_FRAMES;
            count = 2;
        }
        const feral_input_params *qs[2];
        for (int k = 0; k < count; ++k) {
            done[ins[k]] = true;
            qs[k] = next && ins[k] < next->inputs ? &next->inputParams[ins[k]] : &kNone;
        }
        float detector[FERAL_MAX_FRAMES];
        auto detect = [&](float *const *xs) -> const float * {
            if (count == 1) return nullptr;
            for (int n = 0; n < frames; ++n) detector[n] = std::max(std::fabs(xs[0][n]), std::fabs(xs[1][n]));
            return detector;
        };
        auto note = [&](std::atomic<float> &meter, float deepest) {
            if (deepest >= 1) return;
            const float db = -20.0f * std::log10(deepest);
            if (db > meter.load(std::memory_order_relaxed)) meter.store(db, std::memory_order_relaxed);
        };

        // Multiband: split each side into bands, compress each band (a pair's bands hear the louder
        // side's same band), apply the band gains and add the bands back up.
        float deepestAll[2] = {1, 1};
        bool multiband[2];
        for (int k = 0; k < count; ++k) {
            InputRuntime &r = core->inputRuntime[ins[k]];
            multiband[k] = qs[k]->multiband != 0;
            if (multiband[k] && !r.split) {
                r.split = true;
                std::copy(qs[k]->crossover, qs[k]->crossover + FERAL_CROSSOVER_SECTIONS, r.crossover);
                std::fill(r.xz1, r.xz1 + FERAL_CROSSOVER_SECTIONS, 0.0f);
                std::fill(r.xz2, r.xz2 + FERAL_CROSSOVER_SECTIONS, 0.0f);
                std::fill(r.bandEnvelope, r.bandEnvelope + FERAL_COMP_BANDS, 0.0f);
                for (int b = 0; b < FERAL_COMP_BANDS; ++b) r.bandGain[b] = qs[k]->bands[b].gain;
            } else if (!multiband[k]) {
                r.split = false;
            }
            if (!multiband[k]) continue;
            float *y = ys[k];
            float *band[FERAL_COMP_BANDS];
            for (int b = 0; b < FERAL_COMP_BANDS; ++b)
                band[b] = core->bandScratch.data() + static_cast<size_t>(k * FERAL_COMP_BANDS + b) * FERAL_MAX_FRAMES;
            const feral_biquad *t = qs[k]->crossover;
            // Low: low-pass twice and the upper crossover's all-pass.
            std::copy(y, y + frames, band[0]);
            runEQ(r.crossover, r.xz1, r.xz2, t, 3, band[0], frames);
            // The rest: high-pass twice, then split again into mid and high.
            std::copy(y, y + frames, band[1]);
            runEQ(r.crossover + 3, r.xz1 + 3, r.xz2 + 3, t + 3, 2, band[1], frames);
            std::copy(band[1], band[1] + frames, band[2]);
            runEQ(r.crossover + 5, r.xz1 + 5, r.xz2 + 5, t + 5, 2, band[1], frames);
            runEQ(r.crossover + 7, r.xz1 + 7, r.xz2 + 7, t + 7, 2, band[2], frames);
        }
        for (int b = 0; b < FERAL_COMP_BANDS; ++b) {
            float *bs[2];
            for (int k = 0; k < count; ++k)
                bs[k] = core->bandScratch.data() + static_cast<size_t>(k * FERAL_COMP_BANDS + b) * FERAL_MAX_FRAMES;
            const float *d = count == 2 && multiband[0] && multiband[1] ? detect(bs) : nullptr;
            for (int k = 0; k < count; ++k) {
                if (!multiband[k]) continue;
                InputRuntime &r = core->inputRuntime[ins[k]];
                const feral_comp_band &cb = qs[k]->bands[b];
                float deepest = 1;
                if (cb.threshold > 0 && cb.ratio > 1) {
                    deepest = compress(bs[k], d, r.bandEnvelope[b], cb.threshold, cb.ratio, cb.attack, cb.release, frames);
                } else {
                    r.bandEnvelope[b] = 0;
                }
                rampGain(bs[k], r.bandGain[b], cb.gain, frames);
                note(core->bandReduction[ins[k] * FERAL_COMP_BANDS + b], deepest);
                deepestAll[k] = std::min(deepestAll[k], deepest);
            }
        }
        for (int k = 0; k < count; ++k) {
            if (!multiband[k]) continue;
            float *y = ys[k];
            const float *b0 = core->bandScratch.data() + static_cast<size_t>(k * FERAL_COMP_BANDS) * FERAL_MAX_FRAMES;
            for (int n = 0; n < frames; ++n) y[n] = b0[n] + b0[n + FERAL_MAX_FRAMES] + b0[n + 2 * FERAL_MAX_FRAMES];
        }

        // Single band.
        const float *d = count == 2 && !multiband[0] && !multiband[1] ? detect(ys) : nullptr;
        for (int k = 0; k < count; ++k) {
            const int i = ins[k];
            const feral_input_params &q = *qs[k];
            InputRuntime &r = core->inputRuntime[i];
            float *y = ys[k];
            if (!multiband[k]) {
                if (q.comp_threshold > 0 && q.comp_ratio > 1) {
                    deepestAll[k] = compress(y, d, r.envelope, q.comp_threshold, q.comp_ratio, q.comp_attack,
                                             q.comp_release, frames);
                } else {
                    r.envelope = 0;
                }
            }
            rampGain(y, r.makeup, q.comp_makeup, frames);
            note(core->inputReduction[i], deepestAll[k]);
        }
    }
}

inline void cpuRelax() {
#if defined(__aarch64__) || defined(__arm64__)
    __asm__ __volatile__("yield");
#elif defined(__x86_64__) || defined(__i386__)
    __builtin_ia32_pause();
#endif
}

/// Plays outputs [first, last): their taps, then each output's processing. Each output touches only
/// its own voices, runtime and alignment line, so different outputs can run on different threads.
/// Returns the voices still playing.
uint32_t renderOutputs(feral_core *core, const RenderJob &job, int first, int last) {
    const int frames = job.frames, lines = job.lines;
    const uint32_t block = job.block;
    const RenderState *next = job.next;
    const feral_motion_params &motion = *job.motion;
    uint32_t active = 0;
    for (int out = first; out < last; ++out) {
        float *y = job.outputs[out];
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
                if (const float *x = v.input < lines ? core->inputSources[v.input] : nullptr) {
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
    }
    return active;
}

/// Takes chunks from the current ticket and plays them, until none are left.
void runChunks(feral_core *core) {
    WorkerPool &p = *core->pool;
    for (;;) {
        const uint64_t t = p.ticket.fetch_add(1, std::memory_order_acq_rel);
        const auto chunk = static_cast<uint32_t>(t), chunks = static_cast<uint32_t>(t >> 32);
        if (chunk >= chunks) return;
        const RenderJob &job = p.job;
        const int first = static_cast<int>(chunk) * WorkerPool::kChunkOutputs;
        const int last = std::min(job.rendered, first + WorkerPool::kChunkOutputs);
        const uint32_t active = renderOutputs(core, job, first, last);
        p.active.fetch_add(active, std::memory_order_relaxed);
        p.chunksDone.fetch_add(1, std::memory_order_release);
    }
}

#ifdef __APPLE__
/// Makes the calling thread a real-time thread, as Core Audio's own is, so it can join the device's
/// workgroup.
void makeRealtime(double sampleRate) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    const double ticksPerSecond = 1e9 * tb.denom / tb.numer;
    const double period = 256.0 / sampleRate; // a typical live buffer
    thread_time_constraint_policy_data_t policy;
    policy.period = static_cast<uint32_t>(period * ticksPerSecond);
    policy.computation = static_cast<uint32_t>(period * 0.5 * ticksPerSecond);
    policy.constraint = static_cast<uint32_t>(period * ticksPerSecond);
    policy.preemptible = 1;
    thread_policy_set(mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY, reinterpret_cast<thread_policy_t>(&policy),
                      THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}
#endif

/// A worker: waits for a block, then takes chunks like the audio thread does.
void workerMain(feral_core *core) {
    WorkerPool &p = *core->pool;
#ifdef __APPLE__
    makeRealtime(core->sampleRate);
    os_workgroup_t joined = nullptr;
    os_workgroup_join_token_s token{};
    uint32_t joinedSeq = 0;
#endif
    uint32_t seen = p.generation.load(std::memory_order_acquire);
    while (!p.quit.load(std::memory_order_acquire)) {
#ifdef __APPLE__
        // Follow the device's workgroup (it changes when the device is reopened).
        if (const uint32_t seq = p.workgroupSeq.load(std::memory_order_acquire); seq != joinedSeq) {
            if (joined) os_workgroup_leave(joined, &token);
            joined = p.workgroup.load(std::memory_order_acquire);
            if (joined && os_workgroup_join(joined, &token) != 0) joined = nullptr;
            joinedSeq = seq;
        }
#endif
        p.generation.wait(seen, std::memory_order_acquire);
        seen = p.generation.load(std::memory_order_acquire);
        if (p.quit.load(std::memory_order_acquire)) break;
        runChunks(core);
    }
#ifdef __APPLE__
    if (joined) os_workgroup_leave(joined, &token);
#endif
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

    // Every input runs its EQ and compressor, then goes into its delay line, so a tap can read the
    // sample that just arrived.
    const uint32_t block = core->writeIndex;
    const int lines = std::min(FERAL_MAX_CHANNELS, std::max(num_inputs, test ? 1 : 0));
    for (int in = 0; in < lines; ++in) core->rawInputs[in] = input(in);
    const feral_motion_params &motion = next ? next->motion : kStill;
    processInputs(core, next, core->rawInputs, lines, frames, block, motion);
    core->preLinesUsed = std::max(core->preLinesUsed, lines);
    auto source = [&](int in) -> const float * { return in < lines ? core->inputSources[in] : nullptr; };

    // The analysis tap.
    if (const int a = core->analysisInput.load(std::memory_order_relaxed); a >= 0) {
        if (a != core->analysisLast) {
            core->analysisLast = a;
            core->analysisWritten.store(0, std::memory_order_release);
        }
        const float *pre = a < lines ? core->rawInputs[a] : nullptr, *post = source(a);
        const uint64_t w = core->analysisWritten.load(std::memory_order_relaxed);
        for (int n = 0; n < frames; ++n) {
            const size_t i = static_cast<size_t>((w + static_cast<uint64_t>(n)) & (FERAL_ANALYSIS_FRAMES - 1));
            core->analysisPre[i].store(pre ? pre[n] : 0.0f, std::memory_order_relaxed);
            core->analysisPost[i].store(post ? post[n] : 0.0f, std::memory_order_relaxed);
        }
        core->analysisWritten.store(w + static_cast<uint64_t>(frames), std::memory_order_release);
    } else {
        core->analysisLast = -1;
    }
    for (int in = 0; in < lines; ++in) core->inputLine(in).write(block, source(in), frames);
    core->inputLinesUsed = std::max(core->inputLinesUsed, lines);

    const int rendered = std::min(num_outputs, FERAL_MAX_CHANNELS);
    const RenderJob job{outputs, frames, block, lines, next, &motion, rendered};
    uint32_t active = 0;
    WorkerPool *pool = core->pool;
    const int chunks = (rendered + WorkerPool::kChunkOutputs - 1) / WorkerPool::kChunkOutputs;
    if (pool && chunks > 1) {
        // Hand the outputs out in chunks; the audio thread takes chunks too and then waits only for
        // the ones a worker has already started.
        pool->job = job;
        pool->chunksDone.store(0, std::memory_order_relaxed);
        pool->active.store(0, std::memory_order_relaxed);
        pool->ticket.store(static_cast<uint64_t>(chunks) << 32, std::memory_order_release);
        pool->generation.fetch_add(1, std::memory_order_release);
        pool->generation.notify_all();
        runChunks(core);
        while (pool->chunksDone.load(std::memory_order_acquire) < chunks) cpuRelax();
        active = pool->active.load(std::memory_order_relaxed);
    } else {
        active = renderOutputs(core, job, 0, rendered);
    }
    // The highest output whose alignment line was written.
    for (int out = rendered - 1; out >= 0; --out) {
        if (outputs[out] && (out < core->voiceOutputs || (next && out < next->outputs))) {
            core->outputLinesUsed = std::max(core->outputLinesUsed, out + 1);
            break;
        }
    }
    core->writeIndex = block + static_cast<uint32_t>(frames);
    core->activeTaps.store(active, std::memory_order_relaxed);

    // Meters: the inputs as they arrived (the test signal in place of input 1), the outputs as the
    // device gets them. Channels no longer there fall to silence (every channel metered since the
    // audio started keeps being metered).
    const float a = 1.0f - static_cast<float>(std::exp(-frames / (0.3 * core->sampleRate)));
    const int inputsMetered = std::max(num_inputs, test ? 1 : 0);
    for (int in = 0; in < std::max(inputsMetered, core->meteredInputs); ++in) {
        meterBlock(in < inputsMetered ? input(in) : nullptr, frames, a, core->inputPowerState[in], core->inputPeak[in],
                   core->inputPower[in]);
    }
    core->meteredInputs = std::max(core->meteredInputs, inputsMetered);
    for (int out = 0; out < std::max(rendered, core->meteredOutputs); ++out) {
        meterBlock(out < rendered ? outputs[out] : nullptr, frames, a, core->outputPowerState[out], core->outputPeak[out],
                   core->outputPower[out]);
    }
    core->meteredOutputs = std::max(core->meteredOutputs, rendered);
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
