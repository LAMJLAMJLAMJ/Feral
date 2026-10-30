#include "feral_core.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <utility>
#include <vector>

namespace {

struct V3 {
    double x = 0, y = 0, z = 0;
    V3 operator+(const V3 &o) const { return {x + o.x, y + o.y, z + o.z}; }
    V3 operator-(const V3 &o) const { return {x - o.x, y - o.y, z - o.z}; }
    V3 operator*(double s) const { return {x * s, y * s, z * s}; }
};

inline V3 v3(feral_point p) { return {p.x, p.y, p.z}; }
inline double dot(const V3 &a, const V3 &b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline V3 cross(const V3 &a, const V3 &b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
inline double length(const V3 &a) { return std::sqrt(dot(a, a)); }
inline V3 normalized(const V3 &a) {
    const double l = length(a);
    return l > 0 ? a * (1 / l) : V3{};
}

/// Scales gains so their squares sum to 1 (leaves all-zero gains alone).
void normalisePower(double *g, int n) {
    double sum = 0;
    for (int k = 0; k < n; ++k) sum += g[k] * g[k];
    if (sum <= 0) return;
    const double s = 1 / std::sqrt(sum);
    for (int k = 0; k < n; ++k) g[k] *= s;
}

// ----- Convex hull of directions (3D VBAP) --------------------------------------------------------

struct Face {
    int a, b, c;
    V3 normal;
    double offset; // dot(normal, a)
};

Face makeFace(const std::vector<V3> &p, int a, int b, int c, const V3 &inside) {
    Face f{a, b, c, normalized(cross(p[b] - p[a], p[c] - p[a])), 0};
    f.offset = dot(f.normal, p[a]);
    if (dot(f.normal, inside) - f.offset > 0) { // make it face away from the inside
        std::swap(f.b, f.c);
        f.normal = f.normal * -1;
        f.offset = -f.offset;
    }
    return f;
}

/// Incremental convex hull. Returns false when the points are all (nearly) on one plane.
bool convexHull(const std::vector<V3> &p, std::vector<Face> &faces) {
    const int n = static_cast<int>(p.size());
    if (n < 4) return false;
    constexpr double eps = 1e-9;
    // A starting tetrahedron from four well-spread points.
    int i0 = 0, i1 = -1, i2 = -1, i3 = -1;
    double best = 0;
    for (int i = 1; i < n; ++i) if (double d = length(p[i] - p[i0]); d > best) { best = d; i1 = i; }
    if (i1 < 0 || best < 1e-6) return false;
    best = 0;
    for (int i = 0; i < n; ++i) {
        const double d = length(cross(p[i1] - p[i0], p[i] - p[i0]));
        if (d > best) { best = d; i2 = i; }
    }
    if (i2 < 0 || best < 1e-6) return false;
    best = 0;
    const V3 planeNormal = normalized(cross(p[i1] - p[i0], p[i2] - p[i0]));
    for (int i = 0; i < n; ++i) {
        const double d = std::fabs(dot(planeNormal, p[i] - p[i0]));
        if (d > best) { best = d; i3 = i; }
    }
    if (i3 < 0 || best < 1e-6) return false;
    const V3 inside = (p[i0] + p[i1] + p[i2] + p[i3]) * 0.25;
    faces = {makeFace(p, i0, i1, i2, inside), makeFace(p, i0, i1, i3, inside),
             makeFace(p, i0, i2, i3, inside), makeFace(p, i1, i2, i3, inside)};

    std::vector<char> visible;
    std::vector<std::pair<int, int>> edges, horizon;
    for (int i = 0; i < n; ++i) {
        if (i == i0 || i == i1 || i == i2 || i == i3) continue;
        visible.assign(faces.size(), 0);
        bool any = false;
        for (size_t f = 0; f < faces.size(); ++f)
            if (dot(faces[f].normal, p[i]) - faces[f].offset > eps) visible[f] = any = true;
        if (!any) continue; // inside (or a duplicate direction)
        // The horizon: edges of visible faces whose other face is not visible.
        edges.clear();
        for (size_t f = 0; f < faces.size(); ++f) {
            if (!visible[f]) continue;
            edges.push_back({faces[f].a, faces[f].b});
            edges.push_back({faces[f].b, faces[f].c});
            edges.push_back({faces[f].c, faces[f].a});
        }
        horizon.clear();
        for (const auto &e : edges) {
            const bool shared = std::any_of(edges.begin(), edges.end(),
                                            [&](const auto &o) { return o.first == e.second && o.second == e.first; });
            if (!shared) horizon.push_back(e);
        }
        std::vector<Face> kept;
        for (size_t f = 0; f < faces.size(); ++f) if (!visible[f]) kept.push_back(faces[f]);
        for (const auto &e : horizon) kept.push_back(makeFace(p, e.first, e.second, i, inside));
        faces = std::move(kept);
    }
    return true;
}

inline double det3(const V3 &a, const V3 &b, const V3 &c) { return dot(a, cross(b, c)); }

}

struct feral_vbap {
    int dimensions = 3;
    int count = 0;          // real speakers
    int virtualCount = 0;   // speakers added to close the hull, after the real ones
    std::vector<V3> directions;
    V3 reference;
    double meanDistance = 1;

    // 3D: triangles and the inverse of each one's direction matrix (rows), so g = inverse * u.
    std::vector<std::array<int, 3>> triangles;
    std::vector<std::array<V3, 3>> inverses;
    // The real speakers next to each virtual one, which share its gain.
    std::vector<std::vector<int>> neighbours;

    // 2D: speaker azimuths, and pairs of adjacent speakers with each pair's inverse matrix.
    std::vector<double> azimuth;
    std::vector<std::array<int, 2>> pairs;
    std::vector<std::array<double, 4>> pairInverses;

    /// Gains for one direction (unit vector), power-normalised. Adds into g (count entries).
    void panDirection(const V3 &u, double *g) const;
};

void feral_vbap::panDirection(const V3 &u, double *g) const {
    std::vector<double> local(count, 0.0);
    if (dimensions == 2) {
        const double theta = std::atan2(u.y, u.x);
        const double c = std::cos(theta), s = std::sin(theta);
        for (size_t i = 0; i < pairs.size(); ++i) {
            const auto &m = pairInverses[i];
            const double ga = m[0] * c + m[1] * s, gb = m[2] * c + m[3] * s;
            if (ga >= -1e-9 && gb >= -1e-9) {
                local[pairs[i][0]] = std::max(0.0, ga);
                local[pairs[i][1]] = std::max(0.0, gb);
                normalisePower(local.data(), count);
                for (int k = 0; k < count; ++k) g[k] += local[k];
                return;
            }
        }
        // Outside the arc the speakers cover: the nearest one by angle plays it.
        int nearest = 0;
        double closest = 1e9;
        for (int k = 0; k < count; ++k) {
            const double d = std::fabs(std::remainder(theta - azimuth[k], 2 * M_PI));
            if (d < closest) { closest = d; nearest = k; }
        }
        g[nearest] += 1;
        return;
    }

    // 3D: the triangle whose speakers enclose the direction (all three gains non-negative).
    int chosen = -1;
    double bestMin = -1e9;
    std::array<double, 3> gains{};
    for (size_t t = 0; t < triangles.size(); ++t) {
        const auto &inv = inverses[t];
        const std::array<double, 3> h = {dot(inv[0], u), dot(inv[1], u), dot(inv[2], u)};
        const double lowest = std::min({h[0], h[1], h[2]});
        if (lowest > bestMin) { bestMin = lowest; chosen = static_cast<int>(t); gains = h; }
        if (lowest >= -1e-9) break;
    }
    if (chosen < 0) return;
    std::vector<double> power(count, 0.0);
    double total = 0;
    for (int j = 0; j < 3; ++j) {
        const double gj = std::max(0.0, gains[j]);
        total += gj * gj;
        const int s = triangles[chosen][j];
        if (s < count) {
            power[s] += gj * gj;
        } else {
            // A virtual speaker's share is spread evenly (in power) over its real neighbours.
            const auto &near = neighbours[s - count];
            for (int k : near) power[k] += gj * gj / static_cast<double>(near.size());
        }
    }
    if (total <= 0) return;
    for (int k = 0; k < count; ++k) g[k] += std::sqrt(power[k] / total);
}

extern "C" {

double feral_speed_of_sound(double celsius) { return 331.3 * std::sqrt(1 + celsius / 273.15); }

void feral_delay_render(const feral_point *speakers, const double *weights, int count, feral_point source,
                        const feral_delay_params *params, float *gains, double *delays) {
    if (count <= 0) return;
    std::vector<double> distance(count);
    double nearest = 1e300;
    for (int k = 0; k < count; ++k) {
        distance[k] = length(v3(speakers[k]) - v3(source));
        nearest = std::min(nearest, distance[k]);
    }
    const double c = params->speed_of_sound > 0 ? params->speed_of_sound : feral_speed_of_sound(20);
    const double d0 = params->distance_offset < 0 ? nearest : params->distance_offset;
    // The automatic reference is at least 1 m, so a source standing on a speaker does not mute the rest.
    const double dr = params->reference_distance > 0 ? params->reference_distance : std::max(nearest, 1.0);
    for (int k = 0; k < count; ++k) {
        const double w = weights ? weights[k] : 1;
        delays[k] = std::max(0.0, distance[k] - d0) / c + params->precedence;
        double level = 1;
        if (params->rolloff > 0 && distance[k] > dr) level = std::pow(dr / distance[k], params->rolloff);
        gains[k] = static_cast<float>(w * level);
    }
}

void feral_dbap_render(const feral_point *speakers, const double *weights, int count, feral_point source,
                       double blur, double rolloff_db, float *gains) {
    if (count <= 0) return;
    const double a = rolloff_db / (20 * std::log10(2.0));
    std::vector<double> g(count);
    for (int k = 0; k < count; ++k) {
        const V3 d = v3(speakers[k]) - v3(source);
        const double w = weights ? weights[k] : 1;
        const double r2 = dot(d, d) + blur * blur;
        g[k] = r2 > 0 ? w / std::pow(r2, a / 2) : (w != 0 ? 1e12 : 0); // a source on a speaker with no blur
    }
    normalisePower(g.data(), count);
    for (int k = 0; k < count; ++k) gains[k] = static_cast<float>(g[k]);
}

feral_vbap *feral_vbap_create(const feral_point *speakers, int count, feral_point reference, int dimensions) {
    if (count < 2) return nullptr;
    auto *v = new feral_vbap;
    v->count = count;
    v->reference = v3(reference);
    double elevMin = 1e9, elevMax = -1e9, distanceSum = 0;
    for (int k = 0; k < count; ++k) {
        const V3 d = v3(speakers[k]) - v->reference;
        const double r = length(d);
        distanceSum += r;
        v->directions.push_back(r > 0 ? d * (1 / r) : V3{0, 1, 0});
        const double elevation = std::atan2(d.z, std::hypot(d.x, d.y)) * 180 / M_PI;
        elevMin = std::min(elevMin, elevation);
        elevMax = std::max(elevMax, elevation);
    }
    v->meanDistance = distanceSum / count > 0 ? distanceSum / count : 1;
    v->dimensions = dimensions == 2 || dimensions == 3 ? dimensions : (elevMax - elevMin <= 5 ? 2 : 3);
    for (int k = 0; k < count; ++k) v->azimuth.push_back(std::atan2(v->directions[k].y, v->directions[k].x));

    if (v->dimensions == 2) {
        std::vector<int> order(count);
        for (int k = 0; k < count; ++k) order[k] = k;
        std::sort(order.begin(), order.end(), [&](int a, int b) { return v->azimuth[a] < v->azimuth[b]; });
        for (int i = 0; i < count; ++i) {
            const int a = order[i], b = order[(i + 1) % count];
            double gap = v->azimuth[b] - v->azimuth[a];
            if (gap <= 0) gap += 2 * M_PI;
            if (gap < 1e-6 || gap >= M_PI - 1e-6) continue; // the same direction, or wider than a half turn
            const double ca = std::cos(v->azimuth[a]), sa = std::sin(v->azimuth[a]);
            const double cb = std::cos(v->azimuth[b]), sb = std::sin(v->azimuth[b]);
            const double det = ca * sb - cb * sa;
            v->pairs.push_back({a, b});
            v->pairInverses.push_back({sb / det, -cb / det, -sa / det, ca / det});
            if (count == 2) break; // two speakers make one pair, not two
        }
        return v;
    }

    // 3D. A tiny fixed jitter breaks ties between speakers on one circle (a ring), so its flat cap
    // is triangulated cleanly; it moves no direction by more than a few millionths of a degree.
    auto jittered = [](const std::vector<V3> &dirs) {
        std::vector<V3> p = dirs;
        uint32_t r = 12345;
        for (V3 &d : p) {
            auto next = [&r] { r ^= r << 13; r ^= r >> 17; r ^= r << 5; return (r * (1.0 / 4294967296.0) - 0.5) * 1e-7; };
            d = normalized(d + V3{next(), next(), next()});
        }
        return p;
    };
    auto enclosesReference = [](const std::vector<Face> &faces) {
        return std::all_of(faces.begin(), faces.end(), [](const Face &f) { return f.offset > 1e-6; });
    };
    std::vector<Face> faces;
    bool ok = convexHull(jittered(v->directions), faces) && enclosesReference(faces);
    // Close an open dome with a speaker below, then if needed one above.
    for (const V3 extra : {V3{0, 0, -1}, V3{0, 0, 1}}) {
        if (ok) break;
        v->directions.push_back(extra);
        ++v->virtualCount;
        ok = convexHull(jittered(v->directions), faces) && enclosesReference(faces);
    }
    if (!ok) {
        delete v;
        return nullptr;
    }
    v->neighbours.assign(v->virtualCount, {});
    for (const Face &f : faces) {
        const std::array<int, 3> t = {f.a, f.b, f.c};
        const V3 &a = v->directions[t[0]], &b = v->directions[t[1]], &c = v->directions[t[2]];
        const double det = det3(a, b, c);
        if (std::fabs(det) < 1e-9) continue; // a sliver: its speakers lie on one great circle
        // Rows of the inverse of the matrix whose columns are a, b, c.
        v->inverses.push_back({cross(b, c) * (1 / det), cross(c, a) * (1 / det), cross(a, b) * (1 / det)});
        v->triangles.push_back(t);
        for (int j = 0; j < 3; ++j) {
            if (t[j] < count) continue;
            auto &near = v->neighbours[t[j] - count];
            for (int o = 0; o < 3; ++o)
                if (t[o] < count && std::find(near.begin(), near.end(), t[o]) == near.end()) near.push_back(t[o]);
        }
    }
    return v;
}

void feral_vbap_destroy(feral_vbap *vbap) { delete vbap; }

int feral_vbap_dimensions(const feral_vbap *vbap) { return vbap->dimensions; }

int feral_vbap_regions(const feral_vbap *vbap) {
    if (vbap->dimensions == 2) return static_cast<int>(vbap->pairs.size());
    int n = 0;
    for (const auto &t : vbap->triangles)
        if (t[0] < vbap->count || t[1] < vbap->count || t[2] < vbap->count) ++n;
    return n;
}

int feral_vbap_virtual_speakers(const feral_vbap *vbap) { return vbap->virtualCount; }

void feral_vbap_render(const feral_vbap *vbap, feral_point source, double width, double rolloff,
                       double reference_distance, float *gains) {
    const int n = vbap->count;
    std::vector<double> g(n, 0.0);
    const V3 offset = v3(source) - vbap->reference;
    const double distance = length(offset);
    if (distance < 1e-6) {
        // At the reference there is no direction: every speaker equally.
        for (int k = 0; k < n; ++k) gains[k] = static_cast<float>(1 / std::sqrt(static_cast<double>(n)));
        return;
    }
    V3 u = offset * (1 / distance);
    if (vbap->dimensions == 2) {
        // Only the azimuth counts; straight up or down falls back to straight ahead.
        u = (u.x == 0 && u.y == 0) ? V3{0, 1, 0} : normalized(V3{u.x, u.y, 0});
    }

    width = std::clamp(width, 0.0, 360.0) * M_PI / 180;
    if (width <= 0) {
        vbap->panDirection(u, g.data());
    } else if (vbap->dimensions == 2) {
        // Nine directions spread evenly across the width.
        const double theta = std::atan2(u.y, u.x);
        for (int i = 0; i <= 8; ++i) {
            const double t = theta + width * (i / 8.0 - 0.5);
            vbap->panDirection({std::cos(t), std::sin(t), 0}, g.data());
        }
    } else {
        // The direction itself and two rings of eight around it, at a quarter and half the width.
        const V3 helper = std::fabs(u.z) < 0.9 ? V3{0, 0, 1} : V3{1, 0, 0};
        const V3 e1 = normalized(cross(u, helper)), e2 = cross(u, e1);
        vbap->panDirection(u, g.data());
        for (double radius : {width / 4, width / 2}) {
            for (int i = 0; i < 8; ++i) {
                const double phi = 2 * M_PI * i / 8;
                const V3 d = u * std::cos(radius) + (e1 * std::cos(phi) + e2 * std::sin(phi)) * std::sin(radius);
                vbap->panDirection(normalized(d), g.data());
            }
        }
    }
    normalisePower(g.data(), n);
    const double dr = reference_distance > 0 ? reference_distance : vbap->meanDistance;
    const double level = rolloff > 0 && distance > dr ? std::pow(dr / distance, rolloff) : 1;
    for (int k = 0; k < n; ++k) gains[k] = static_cast<float>(g[k] * level);
}

void feral_biquad_design(int type, double frequency, double q, double gain_db, double sample_rate,
                         feral_biquad *band) {
    *band = {1, 0, 0, 0, 0};
    if (type == FERAL_EQ_OFF || !(frequency > 0) || !(sample_rate > 0) || frequency >= sample_rate / 2) return;
    if (!(q > 0)) q = M_SQRT1_2;
    const double A = std::pow(10.0, gain_db / 40), w0 = 2 * M_PI * frequency / sample_rate;
    const double cw = std::cos(w0), alpha = std::sin(w0) / (2 * q), sA = 2 * std::sqrt(A) * alpha;
    double b0, b1, b2, a0, a1, a2;
    switch (type) {
    case FERAL_EQ_PEAK:
        b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A;
        a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A;
        break;
    case FERAL_EQ_LOW_SHELF:
        b0 = A * ((A + 1) - (A - 1) * cw + sA); b1 = 2 * A * ((A - 1) - (A + 1) * cw); b2 = A * ((A + 1) - (A - 1) * cw - sA);
        a0 = (A + 1) + (A - 1) * cw + sA; a1 = -2 * ((A - 1) + (A + 1) * cw); a2 = (A + 1) + (A - 1) * cw - sA;
        break;
    case FERAL_EQ_HIGH_SHELF:
        b0 = A * ((A + 1) + (A - 1) * cw + sA); b1 = -2 * A * ((A - 1) + (A + 1) * cw); b2 = A * ((A + 1) + (A - 1) * cw - sA);
        a0 = (A + 1) - (A - 1) * cw + sA; a1 = 2 * ((A - 1) - (A + 1) * cw); a2 = (A + 1) - (A - 1) * cw - sA;
        break;
    case FERAL_EQ_LOW_PASS:
        b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
        break;
    case FERAL_EQ_HIGH_PASS:
        b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
        break;
    case FERAL_EQ_NOTCH:
        b0 = 1; b1 = -2 * cw; b2 = 1; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
        break;
    case FERAL_EQ_ALL_PASS:
        b0 = 1 - alpha; b1 = -2 * cw; b2 = 1 + alpha; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
        break;
    default:
        return;
    }
    *band = {static_cast<float>(b0 / a0), static_cast<float>(b1 / a0), static_cast<float>(b2 / a0),
             static_cast<float>(a1 / a0), static_cast<float>(a2 / a0)};
}

}
