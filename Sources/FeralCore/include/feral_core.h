// The render core's C API. Swift (and the Core Audio IOProc) use only this header, so Swift never
// needs C++ interop and nothing on the audio thread goes through Swift.
//
// Threads:
//   control thread   feral_state_*, feral_core_publish, feral_core_publish_gains, feral_core_collect,
//                    feral_core_audio_detached, and the geometry functions in feral_geometry.h
//   audio thread     feral_core_render (never allocates, locks or logs)
//   any thread       feral_core_get_stats, feral_core_live_states, feral_core_set_test_signal,
//                    feral_core_read_meters (one reader at a time)
#ifndef FERAL_CORE_H
#define FERAL_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The most inputs (sources) and outputs (speakers) the core is built for. v1 runs 128 by 128;
/// the headroom is for later versions.
#define FERAL_MAX_CHANNELS 256

/// The longest buffer rendered in one go, in frames. Longer buffers are rendered in pieces.
#define FERAL_MAX_FRAMES 4096

/// Each source's delay line holds this many seconds (at 48 kHz, a little more). Delays are clamped to it.
#define FERAL_MAX_DELAY_SECONDS 1.0

typedef struct feral_core feral_core;

/// Creates a core for a sample rate, with a delay line for every possible input and output.
feral_core *feral_core_create(double sample_rate);
void feral_core_destroy(feral_core *core);

/// The longest delay the core plays, in samples (FERAL_MAX_DELAY_SECONDS at the core's rate).
double feral_core_max_delay(const feral_core *core);

// ----- Render states ------------------------------------------------------------------------------
//
// A render state is everything the audio thread plays: for every output, its taps (an input at a
// gain, either straight or through the input's delay line), and the output's processing. The
// control thread builds one with feral_state_*, then hands it to feral_core_publish.
//
// A tap is identified by (input, output, kind). When a new state arrives the audio thread matches
// its taps to the ones playing, so nothing restarts:
//   - every gain moves to its new value over one buffer, or over the publish's fade time;
//   - a tap that is gone fades out the same way, and a new one fades in;
//   - a delay glides to its new value at a limited rate (a small pitch shift), or, if it jumps by
//     more than the jump threshold, crossfades from the old delay to the new one;
//   - output processing changes ramp or crossfade the same way (see feral_output_params).

typedef struct feral_state feral_state;

enum {
    FERAL_TAP_GAIN = 0,  ///< the input as it arrives, times a gain (VBAP, DBAP, routing)
    FERAL_TAP_DELAY = 1, ///< the input through its delay line, times a gain (Delay renderer)
};

/// How delays move when they change. Every field is in samples.
typedef struct feral_motion_params {
    /// The most a delay changes per sample while gliding: 0.005 moves it at most 5 samples every
    /// 1000, a pitch shift of 0.5 %.
    float glide_rate;
    /// A change larger than this crossfades from the old delay to the new one instead of gliding.
    float jump;
    /// The length of that crossfade.
    float crossfade;
} feral_motion_params;

/// The design's defaults at a sample rate: glide 0.5 %, jump 5 ms, crossfade 30 ms.
feral_motion_params feral_motion_defaults(double sample_rate);

/// One biquad section, normalised so a0 is 1:
/// y[n] = b0 x[n] + b1 x[n-1] + b2 x[n-2] - a1 y[n-1] - a2 y[n-2]. Design one with feral_biquad_design.
typedef struct feral_biquad {
    float b0, b1, b2, a1, a2;
} feral_biquad;

#define FERAL_EQ_BANDS 8

/// One output's processing, in order: alignment delay, EQ, gain (trim and polarity), limiter, mute.
typedef struct feral_output_params {
    /// The system layer's alignment delay in samples. Changes glide or crossfade like tap delays.
    float delay;
    /// The EQ bands; a band of {1, 0, 0, 0, 0} passes through. Coefficient changes interpolate over one buffer.
    feral_biquad eq[FERAL_EQ_BANDS];
    /// Trim times polarity, linear (a negative gain flips polarity). Ramps over one buffer.
    float gain;
    /// The limiter's threshold as a linear peak level; 0 turns it off. It has no look-ahead (so no
    /// latency): it reacts on the sample that goes over, and then lets go at the release rate.
    float limiter_threshold;
    /// How long the limiter takes to let go by 20 dB, in samples.
    float limiter_release;
    /// Non-zero mutes the output. Ramps over one buffer.
    int mute;
} feral_output_params;

/// The parameters of an output with no processing: no delay, flat, unity gain, no limiter, not muted.
feral_output_params feral_output_defaults(void);

#define FERAL_INPUT_EQ_BANDS 6

/// Bands of the multiband compressor, and the filter sections that split them: in order, the low
/// band's low-pass twice (a Linkwitz-Riley crossover) and an all-pass at the upper crossover (so the
/// bands add back up flat), the high-pass at the lower crossover twice, then the upper crossover's
/// low-pass twice (mid band) and high-pass twice (high band).
#define FERAL_COMP_BANDS 3
#define FERAL_CROSSOVER_SECTIONS 9

/// One band of the multiband compressor.
typedef struct feral_comp_band {
    float threshold; // linear; 0 leaves the band uncompressed
    float ratio;     // >= 1
    float attack;    // per-sample follower factors 0..1
    float release;
    float gain;      // linear, after the band's compressor
} feral_comp_band;

/// One input's processing before it reaches any tap or its delay line: delay, trim and polarity,
/// EQ, then a compressor.
typedef struct feral_input_params {
    /// Delay in samples (to line a source up with its acoustic sound); changes glide or crossfade
    /// like every other delay (feral_motion_params).
    float delay;
    /// Trim times polarity, linear (-1 inverts); changes ramp over one buffer.
    float trim;
    /// The EQ bands; {1, 0, 0, 0, 0} passes through. Coefficient changes interpolate over one buffer.
    feral_biquad eq[FERAL_INPUT_EQ_BANDS];
    /// The compressor's threshold as a linear level; 0 turns it off.
    float comp_threshold;
    /// 1 or more: 4 brings 4 dB over the threshold down to 1 dB over.
    float comp_ratio;
    /// The level follower's per-sample attack and release factors (0 to 1; nearer 1 is slower).
    float comp_attack;
    float comp_release;
    /// Gain after the compressor, linear (single or multiband).
    float comp_makeup;
    /// Non-zero splits the input into FERAL_COMP_BANDS bands with `crossover` and compresses each
    /// with its own `bands` entry; comp_threshold and comp_ratio are then not used.
    int multiband;
    feral_biquad crossover[FERAL_CROSSOVER_SECTIONS];
    feral_comp_band bands[FERAL_COMP_BANDS];
    /// Another input (from 0) whose level also drives this compressor, so a stereo pair is compressed
    /// alike; -1 for none. Give the two inputs the same parameters and link them to each other.
    int link;
} feral_input_params;

/// An input with no processing: flat EQ, no compressor, no link.
feral_input_params feral_input_defaults(void);

/// Starts an empty state for inputs by outputs (each up to FERAL_MAX_CHANNELS). Every output starts
/// with no taps and feral_output_defaults(), and the motion is feral_motion_defaults(48000).
/// Returns null when the sizes are out of range.
feral_state *feral_state_create(int inputs, int outputs);

/// Frees a state that was never published (a published one belongs to the core).
void feral_state_destroy(feral_state *state);

/// Adds a gain tap (an input to an output, from 0). Adding the same pair twice sums the gains.
/// Returns 0, or -1 when a channel is out of range.
int feral_state_add_gain(feral_state *state, int input, int output, float gain);

/// Adds a delay tap: the input, delay samples ago, times gain. Delays are clamped to 0 to the core's
/// maximum. Returns 0, or -1 when a channel is out of range. A second delay tap for the same pair
/// makes feral_core_publish refuse the state.
int feral_state_add_delay(feral_state *state, int input, int output, float gain, float delay);

/// Sets one output's processing. Returns 0, or -1 when the output is out of range.
int feral_state_set_output(feral_state *state, int output, const feral_output_params *params);

void feral_state_set_motion(feral_state *state, const feral_motion_params *motion);

/// Sets one input's processing. Returns 0, or -1 when the input is out of range.
int feral_state_set_input(feral_state *state, int input, const feral_input_params *params);

/// Taps in the state so far.
size_t feral_state_tap_count(const feral_state *state);

/// Publishes a state as the next one the audio thread plays, and takes ownership of it.
/// fade_frames is the time every gain change in it takes: 0 means one buffer (a parameter change),
/// more means a crossfade (a renderer or group change; 50 ms in the design). A gain still fading
/// from an earlier publish keeps at least the rest of that fade. Returns 0, or -1 when the state
/// has two delay taps for the same input and output (it is freed and nothing changes).
int feral_core_publish(feral_core *core, feral_state *state, int fade_frames);

/// Publishes a plain gain matrix as the next state: outputs rows of inputs linear gains each
/// (row-major: gains[out * inputs + in]), every output unprocessed. Returns 0, or -1 when the
/// sizes are out of range.
int feral_core_publish_gains(feral_core *core, const float *gains, int inputs, int outputs);

/// Frees render states the audio thread has moved past. Returns how many were freed.
/// Control or housekeeping thread.
size_t feral_core_collect(feral_core *core);

/// Render states still allocated, the current one included.
size_t feral_core_live_states(const feral_core *core);

/// Tells the core the audio thread has stopped and will not call feral_core_render until it is
/// started again (for example after AudioDeviceStop returns). Delay lines and filters are cleared,
/// the next render fades in from silence over one buffer, and every state but the newest can be freed.
void feral_core_audio_detached(feral_core *core);

/// Renders one buffer. inputs holds num_inputs channel pointers (a null pointer is a silent input),
/// outputs num_outputs channel pointers that are overwritten. Inputs the state does not have are
/// ignored and outputs it does not have are silent. Audio thread only: no allocation, no locks.
void feral_core_render(feral_core *core, const float *const *inputs, int num_inputs,
                       float *const *outputs, int num_outputs, int frames);

/// Generated signals for testing outputs with nothing plugged in.
enum {
    FERAL_TEST_OFF = 0,
    FERAL_TEST_PINK = 1, ///< pink noise
    FERAL_TEST_SINE = 2, ///< a sine at sine_hz
};

/// The longest buffer the test signal is generated for, in frames.
#define FERAL_TEST_MAX_FRAMES 4096

/// Replaces engine input 1 with a generated signal at level_db RMS re full scale (a sine's peak is
/// 3 dB higher), or puts input 1 back with FERAL_TEST_OFF. Level changes ramp over one buffer.
/// Any thread.
void feral_core_set_test_signal(feral_core *core, int kind, float level_db, float sine_hz);

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
    /// Taps playing now, including ones still fading out.
    uint32_t active_taps;
} feral_core_stats;

/// Reads the level meters: the first `inputs` engine inputs as they arrive (with the test signal in
/// place of input 1) and the first `outputs` outputs after their processing, as the device gets them.
/// *_peak: the highest absolute sample since the last read, linear (reading starts it again from 0).
/// *_rms: the RMS level averaged over about 300 ms, linear. Any of the arrays may be null.
/// Any thread, but one reader at a time (the peaks are reset by whoever reads them).
void feral_core_read_meters(feral_core *core, float *input_peak, float *input_rms, int inputs,
                            float *output_peak, float *output_rms, int outputs);

/// Reads each input compressor's deepest gain reduction since the last read, in dB (0 or more;
/// reading starts it again from 0). Any thread, one reader at a time.
void feral_core_read_reduction(feral_core *core, float *reduction_db, int inputs);

/// Samples the analysis tap keeps (a power of two).
#define FERAL_ANALYSIS_FRAMES 8192

/// Picks the input (from 0) whose samples the analysis tap keeps, before and after its EQ and
/// compressor, for a spectrum display; -1 turns it off. Any thread.
void feral_core_set_analysis_input(feral_core *core, int input);

/// Copies the analysed input's newest `frames` samples (up to FERAL_ANALYSIS_FRAMES) before (pre)
/// and after (post) its processing, oldest first. Returns how many samples the tap has taken since
/// the input was picked; when that is fewer than `frames`, the start of each buffer is zeros. One
/// reader at a time.
uint64_t feral_core_read_analysis(feral_core *core, float *pre, float *post, int frames);

/// The same per multiband band: reduction_db holds FERAL_COMP_BANDS values per input, input by
/// input (0 for an input that is not multiband).
void feral_core_read_band_reduction(feral_core *core, float *reduction_db, int inputs);

/// Reads the counters. When reset_max_load is non-zero, max_load starts again from 0.
void feral_core_get_stats(feral_core *core, feral_core_stats *stats, int reset_max_load);

#ifdef __cplusplus
}
#endif

#include "feral_geometry.h"

#endif
