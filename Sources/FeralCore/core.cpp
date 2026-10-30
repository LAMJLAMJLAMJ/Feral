#include "feral_core.h"
#include "render_state.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <mutex>

namespace feral {

RenderState::RenderState(uint64_t sequence, const float *gains, int inputs, int outputs)
    : sequence(sequence), inputs(inputs), outputs(outputs), taps(outputs) {
    for (int out = 0; out < outputs; ++out) {
        for (int in = 0; in < inputs; ++in) {
            float g = gains[out * inputs + in];
            if (g != 0.0f) taps[out].push_back({in, g});
        }
    }
}

static_assert(std::atomic<RenderState *>::is_always_lock_free);
static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(std::atomic<float>::is_always_lock_free);

namespace {

// y += g * x
inline void accumulate(float *y, const float *x, float g, int frames) {
    for (int n = 0; n < frames; ++n) y[n] += g * x[n];
}

// y += (g0 + (g1 - g0) * (n + 1) / frames) * x: reaches g1 exactly on the buffer's last sample.
inline void accumulateRamp(float *y, const float *x, float g0, float g1, int frames) {
    const float step = (g1 - g0) / static_cast<float>(frames);
    for (int n = 0; n < frames; ++n) y[n] += (g0 + step * static_cast<float>(n + 1)) * x[n];
}

}

}

using feral::RenderState;
using feral::Tap;

struct feral_core {
    double sampleRate;

    // Shared between the threads. The control thread stores a new state into latest; the audio
    // thread loads it at the start of each buffer and, once it has switched, stores the state's
    // sequence into acknowledged. States are published in sequence order and the audio thread only
    // moves forward, so any state older than the acknowledged one will never be read again.
    std::atomic<RenderState *> latest{nullptr};
    std::atomic<uint64_t> acknowledged{0};

    // Audio thread only (and the control thread while the audio thread is detached).
    RenderState *current = nullptr;

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
};

extern "C" {

feral_core *feral_core_create(double sample_rate) {
    auto *core = new feral_core;
    core->sampleRate = sample_rate > 0 ? sample_rate : 48000;
    return core;
}

void feral_core_destroy(feral_core *core) {
    if (!core) return;
    for (RenderState *s : core->published) delete s;
    delete core;
}

int feral_core_publish_gains(feral_core *core, const float *gains, int inputs, int outputs) {
    if (inputs < 0 || outputs < 0 || inputs > FERAL_MAX_CHANNELS || outputs > FERAL_MAX_CHANNELS) return -1;
    if (inputs * outputs > 0 && !gains) return -1;
    std::lock_guard<std::mutex> lock(core->controlMutex);
    auto *state = new RenderState(core->nextSequence++, gains, inputs, outputs);
    core->published.push_back(state);
    core->liveStates.fetch_add(1, std::memory_order_relaxed);
    core->latest.store(state, std::memory_order_release);
    return 0;
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
    RenderState *newest = core->latest.load(std::memory_order_acquire);
    // Nothing reads the older states now; the newest stays for the next start.
    core->acknowledged.store(newest ? newest->sequence : 0, std::memory_order_release);
}

void feral_core_set_test_signal(feral_core *core, int kind, float level_db, float sine_hz) {
    core->testGain.store(std::pow(10.0f, level_db / 20.0f), std::memory_order_relaxed);
    core->testHz.store(sine_hz > 0 ? sine_hz : 1000, std::memory_order_relaxed);
    core->testKind.store(kind, std::memory_order_relaxed);
}

namespace {

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

}

void feral_core_render(feral_core *core, const float *const *inputs, int num_inputs,
                       float *const *outputs, int num_outputs, int frames) {
    using clock = std::chrono::steady_clock;
    const auto started = clock::now();
    if (frames <= 0) return;

    RenderState *previous = core->current;
    RenderState *next = core->latest.load(std::memory_order_acquire);
    const bool swapping = next != previous;

    const float *test = generateTestSignal(core, frames);
    auto input = [&](int in) -> const float * {
        if (in == 0 && test) return test;
        return in < num_inputs ? inputs[in] : nullptr;
    };

    for (int out = 0; out < num_outputs; ++out) {
        float *y = outputs[out];
        if (!y) continue;
        std::fill(y, y + frames, 0.0f);
        const std::vector<Tap> *newTaps = next && out < next->outputs ? &next->taps[out] : nullptr;
        const std::vector<Tap> *oldTaps = previous && out < previous->outputs ? &previous->taps[out] : nullptr;

        if (!swapping) {
            if (!newTaps) continue;
            for (const Tap &t : *newTaps)
                if (const float *x = input(t.input)) feral::accumulate(y, x, t.gain, frames);
            continue;
        }

        // Ramp every gain from the old state to the new one: walk both sorted tap lists together.
        static const std::vector<Tap> none;
        const std::vector<Tap> &a = oldTaps ? *oldTaps : none;
        const std::vector<Tap> &b = newTaps ? *newTaps : none;
        size_t i = 0, j = 0;
        while (i < a.size() || j < b.size()) {
            int in;
            float g0 = 0, g1 = 0;
            if (j == b.size() || (i < a.size() && a[i].input < b[j].input)) {
                in = a[i].input; g0 = a[i++].gain;
            } else if (i == a.size() || b[j].input < a[i].input) {
                in = b[j].input; g1 = b[j++].gain;
            } else {
                in = a[i].input; g0 = a[i++].gain; g1 = b[j++].gain;
            }
            if (const float *x = input(in)) feral::accumulateRamp(y, x, g0, g1, frames);
        }
    }

    if (swapping) {
        core->current = next;
        if (next) core->acknowledged.store(next->sequence, std::memory_order_release);
        core->stateSwaps.fetch_add(1, std::memory_order_relaxed);
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
}

}
