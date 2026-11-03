#pragma once

#include "feral_core.h"

#include <array>
#include <cstdint>
#include <vector>

namespace feral {

/// Taps of this kind play a bus (a room line or a reflection) instead of an input; their `input`
/// is the bus (see roomBus and reflectionBus).
constexpr int32_t kTapBus = 2;

/// The buses: every room's lines, then every input's reflections.
constexpr int kRoomBuses = FERAL_MAX_ROOMS * FERAL_ROOM_LINES;
constexpr int kBuses = kRoomBuses + FERAL_MAX_CHANNELS * FERAL_MAX_REFLECTIONS;
constexpr int roomBus(int room, int line) { return room * FERAL_ROOM_LINES + line; }
constexpr int reflectionBus(int input, int k) { return kRoomBuses + input * FERAL_MAX_REFLECTIONS + k; }

/// One input's early reflections.
struct Reflections {
    int count = 0;
    float delay[FERAL_MAX_REFLECTIONS] = {};
    float gain[FERAL_MAX_REFLECTIONS] = {};
    feral_biquad filter[FERAL_REFLECTION_FILTER] = {{1, 0, 0, 0, 0}, {1, 0, 0, 0, 0}};
};

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
    /// Per input, its EQ and compressor.
    std::vector<feral_input_params> inputParams;
    /// Per output, the limiter's per-sample release factor, worked out when the state is published.
    std::vector<float> limiterRelease;
    feral_motion_params motion;
    /// Samples every gain change in this state takes (0: one buffer).
    int fadeFrames = 0;
    /// The rooms, and every input's send to each (roomSend[room * inputs + input], linear).
    std::array<feral_room_params, FERAL_MAX_ROOMS> rooms;
    std::vector<float> roomSend;
    /// Per input its reflections; empty when no input has any.
    std::vector<feral::Reflections> reflections;
    /// True when any room is on or any input has reflections (worked out by finish).
    bool reverb = false;

    feral_state(int inputs, int outputs);
    /// Sorts the taps, sums duplicate gain taps and drops silent ones. False when an output has two
    /// delay taps from the same input.
    bool finish(double maxDelay);
};

namespace feral {
using RenderState = ::feral_state;
}
