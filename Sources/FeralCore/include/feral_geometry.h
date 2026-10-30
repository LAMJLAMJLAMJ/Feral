// The renderers' geometry: from a source's position to a gain (and for the Delay renderer a delay)
// per speaker. Control thread only; nothing here touches audio. Positions are in metres in the
// venue frame: x to stage right, y towards the audience, z up.
#ifndef FERAL_GEOMETRY_H
#define FERAL_GEOMETRY_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct feral_point {
    double x, y, z;
} feral_point;

// ----- Delay renderer -----------------------------------------------------------------------------
//
// Every speaker plays the source with the delay and level it would have if the sound came from the
// source's position, plus the precedence offset, so the first arrival at every seat is from the
// stage (TiMax and Soundscape style):
//
//   delay_k = max(0, |p_s - p_k| - d_0) / c + tau_0
//   gain_k  = w_k * min(1, (d_r / |p_s - p_k|) ^ alpha)

typedef struct feral_delay_params {
    /// c, in m/s. feral_speed_of_sound gives it for an air temperature.
    double speed_of_sound;
    /// tau_0, in seconds: how long after the natural sound the speakers arrive (typically 5 to 15 ms).
    double precedence;
    /// alpha: 1 gives 6 dB per doubling of distance, 0 no distance roll-off.
    double rolloff;
    /// d_r in metres; 0 or less means the nearest speaker's distance, so the nearest plays at its weight.
    double reference_distance;
    /// d_0 in metres; below 0 means the nearest speaker's distance, so the nearest gets only tau_0.
    double distance_offset;
} feral_delay_params;

/// The speed of sound in dry air at a temperature in degrees Celsius.
double feral_speed_of_sound(double celsius);

/// Writes count gains and delays (in seconds). weights may be null (all 1).
void feral_delay_render(const feral_point *speakers, const double *weights, int count, feral_point source,
                        const feral_delay_params *params, float *gains, double *delays);

// ----- DBAP ---------------------------------------------------------------------------------------
//
//   g_k = w_k / (|p_s - p_k|^2 + r_s^2) ^ (a / 2),  sum of g_k^2 = 1,  a = R / (20 log10 2)

/// Writes count gains. blur is r_s in metres, rolloff_db is R in dB per doubling of distance.
void feral_dbap_render(const feral_point *speakers, const double *weights, int count, feral_point source,
                       double blur, double rolloff_db, float *gains);

// ----- VBAP ---------------------------------------------------------------------------------------
//
// Direction is taken from the group's reference point. In 3D the speakers' directions are
// triangulated by their convex hull; an open dome is closed with a virtual speaker below (and
// above, if needed) whose gain is spread to the speakers next to it. In 2D the speakers pair up by
// azimuth around the reference, and a source outside the arc they cover plays from the end speaker.
// Width spreads the source over several directions around it (MDAP), summed and power-normalised.

typedef struct feral_vbap feral_vbap;

/// Builds the triangulation (3D) or the pairs (2D). dimensions is 2, 3, or 0 to choose: 2D when every
/// speaker is within 5 degrees of the same elevation, 3D otherwise. Returns null when the speakers
/// cannot be panned between (fewer than 2, or in 3D all on one side of the reference).
feral_vbap *feral_vbap_create(const feral_point *speakers, int count, feral_point reference, int dimensions);
void feral_vbap_destroy(feral_vbap *vbap);

/// 2 or 3.
int feral_vbap_dimensions(const feral_vbap *vbap);

/// Triangles (3D) or pairs (2D) that include at least one real speaker.
int feral_vbap_regions(const feral_vbap *vbap);

/// Virtual speakers added to close the hull (0, 1 or 2).
int feral_vbap_virtual_speakers(const feral_vbap *vbap);

/// Writes the speakers' gains, power-normalised (sum of squares 1) and then scaled by the distance
/// roll-off min(1, (d_r / d) ^ rolloff), where d is the source's distance from the reference and d_r
/// is reference_distance, or the speakers' mean distance when that is 0 or less. width is in degrees.
/// A source at the reference plays equally from every speaker.
void feral_vbap_render(const feral_vbap *vbap, feral_point source, double width, double rolloff,
                       double reference_distance, float *gains);

// ----- EQ -----------------------------------------------------------------------------------------

enum {
    FERAL_EQ_OFF = 0,
    FERAL_EQ_PEAK = 1,
    FERAL_EQ_LOW_SHELF = 2,
    FERAL_EQ_HIGH_SHELF = 3,
    FERAL_EQ_LOW_PASS = 4,
    FERAL_EQ_HIGH_PASS = 5,
    FERAL_EQ_NOTCH = 6,
    FERAL_EQ_ALL_PASS = 7,
};

struct feral_biquad;

/// Designs one band (RBJ Audio EQ Cookbook). q is the bandwidth (peak, notch, all-pass), the slope
/// (shelves, where 0.7071 is the steepest without overshoot) or the resonance (low and high pass).
/// FERAL_EQ_OFF, or a frequency outside 0 to Nyquist, gives a band that passes through.
void feral_biquad_design(int type, double frequency, double q, double gain_db, double sample_rate,
                         struct feral_biquad *band);

#ifdef __cplusplus
}
#endif

#endif
