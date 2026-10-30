#pragma once

#include <cstdint>
#include <vector>

namespace feral {

/// One non-zero entry of the gain matrix.
struct Tap {
    int input;
    float gain;
};

/// Everything the audio thread needs for one buffer, built on the control thread and never changed
/// after it is published. The audio thread only reads it.
struct RenderState {
    /// Increases by one with each publish, so states are ordered and the audio thread's progress
    /// tells the control thread which ones it can free.
    uint64_t sequence = 0;
    int inputs = 0;
    int outputs = 0;
    /// Per output, its non-zero gains sorted by input. Silent pairs are left out, so a sparse
    /// matrix (the usual case) costs only what it routes.
    std::vector<std::vector<Tap>> taps;

    RenderState(uint64_t sequence, const float *gains, int inputs, int outputs);
};

}
