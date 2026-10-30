#pragma once

#include "feral_core.h"

#include <cstdint>
#include <vector>

namespace feral {

/// One tap of a render state: an input to an output, straight (FERAL_TAP_GAIN) or through the
/// input's delay line (FERAL_TAP_DELAY). Within an output, taps are sorted by (input, kind), which
/// is also how the audio thread matches them to the ones already playing.
struct Tap {
    int32_t input;
    int32_t kind;
    float gain;
    float delay; // samples; FERAL_TAP_DELAY only

    bool operator<(const Tap &o) const { return input != o.input ? input < o.input : kind < o.kind; }
    bool sameKey(const Tap &o) const { return input == o.input && kind == o.kind; }
};

}

/// Everything the audio thread needs for one buffer, built on the control thread and never changed
/// after it is published. The audio thread only reads it.
struct feral_state {
    /// Increases by one with each publish, so states are ordered and the audio thread's progress
    /// tells the control thread which ones it can free.
    uint64_t sequence = 0;
    int inputs = 0;
    int outputs = 0;
    /// Per output, its taps sorted by (input, kind). Silent taps are left out, so a sparse matrix
    /// (the usual case) costs only what it routes.
    std::vector<std::vector<feral::Tap>> taps;
    std::vector<feral_output_params> outputParams;
    /// Per output, the limiter's per-sample release factor, worked out when the state is published.
    std::vector<float> limiterRelease;
    feral_motion_params motion;
    /// Samples every gain change in this state takes (0: one buffer).
    int fadeFrames = 0;

    feral_state(int inputs, int outputs);
    /// Sorts the taps, sums duplicate gain taps and drops silent ones. False when an output has two
    /// delay taps from the same input.
    bool finish(double maxDelay);
};

namespace feral {
using RenderState = ::feral_state;
}
