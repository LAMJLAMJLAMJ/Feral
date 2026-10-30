// The render core's C API. Swift (and the Core Audio IOProc) use only this header, so Swift never
// needs C++ interop and nothing on the audio thread goes through Swift.
//
// Threads:
//   control thread   feral_core_publish_gains, feral_core_collect, feral_core_audio_detached
//   audio thread     feral_core_render (never allocates, locks or logs)
//   any thread       feral_core_get_stats, feral_core_live_states
#ifndef FERAL_CORE_H
#define FERAL_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The largest matrix the core is built for. v1 runs 128 by 128; the headroom is for later versions.
#define FERAL_MAX_CHANNELS 256

typedef struct feral_core feral_core;

/// Creates a core. sample_rate is used only to measure how much of each buffer's time the render takes.
feral_core *feral_core_create(double sample_rate);
void feral_core_destroy(feral_core *core);

/// Publishes a new fixed gain matrix as the next render state. gains holds outputs rows of inputs
/// linear gains each (row-major: gains[out * inputs + in]). The audio thread ramps every gain from
/// its old value over its next buffer, so the change does not click. Returns 0, or -1 when the
/// sizes are out of range. Control thread only; allocates.
int feral_core_publish_gains(feral_core *core, const float *gains, int inputs, int outputs);

/// Frees render states the audio thread has moved past. Returns how many were freed.
/// Control or housekeeping thread.
size_t feral_core_collect(feral_core *core);

/// Render states still allocated, the current one included.
size_t feral_core_live_states(const feral_core *core);

/// Tells the core the audio thread has stopped and will not call feral_core_render until it is
/// started again (for example after AudioDeviceStop returns). The next render fades in from silence
/// over one buffer, and every state but the newest can be freed.
void feral_core_audio_detached(feral_core *core);

/// Renders one buffer. inputs holds num_inputs channel pointers (a null pointer is a silent input),
/// outputs num_outputs channel pointers that are overwritten. Inputs the matrix does not have are
/// ignored and outputs it does not have are silent. Audio thread only: no allocation, no locks.
void feral_core_render(feral_core *core, const float *const *inputs, int num_inputs,
                       float *const *outputs, int num_outputs, int frames);

typedef struct feral_core_stats {
    /// Buffers rendered.
    uint64_t buffers;
    /// Buffers whose render took more than 80 % of the buffer's duration.
    uint64_t late_buffers;
    /// Times the audio thread picked up a new render state.
    uint64_t state_swaps;
    /// Sequence number of the render state the audio thread is using (0 before the first).
    uint64_t current_state;
    /// Highest share of a buffer's duration taken by one render since the last reset (1 = 100 %).
    float max_load;
} feral_core_stats;

/// Reads the counters. When reset_max_load is non-zero, max_load starts again from 0.
void feral_core_get_stats(feral_core *core, feral_core_stats *stats, int reset_max_load);

#ifdef __cplusplus
}
#endif

#endif
