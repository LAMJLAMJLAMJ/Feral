import FeralCore
import XCTest

/// 2D (flat) Delay, DBAP and VBAP, where only the azimuth and the distance in plan count, and the
/// KNN and SPCAP panners.
final class PannerTests: XCTestCase {
    let speakers = [feral_point(x: -4, y: 0, z: 1), feral_point(x: 4, y: 0, z: 1), feral_point(x: 0, y: 0, z: 9)]
    let low = feral_point(x: -1, y: 2, z: 1)
    let high = feral_point(x: -1, y: 2, z: 8)

    func testFlatDelayIgnoresHeight() {
        func render(_ p: feral_point, planar: Int32) -> ([Float], [Double]) {
            var params = feral_delay_params(speed_of_sound: 343, precedence: 0.01, rolloff: 1, reference_distance: 0,
                                            distance_offset: -1, planar: planar)
            var g = [Float](repeating: 0, count: 3), d = [Double](repeating: 0, count: 3)
            feral_delay_render(speakers, nil, 3, p, &params, &g, &d)
            return (g, d)
        }
        XCTAssertEqual(render(low, planar: 1).0, render(high, planar: 1).0)
        XCTAssertEqual(render(low, planar: 1).1, render(high, planar: 1).1)
        // In 3D, raising the source makes the high speaker the nearest by far.
        XCTAssertGreaterThan(render(high, planar: 0).1[0], render(high, planar: 1).1[0])
    }

    func testFlatDBAPIgnoresHeight() {
        func render(_ p: feral_point, planar: Int32) -> [Float] {
            var g = [Float](repeating: 0, count: 3)
            feral_dbap_render(speakers, nil, 3, p, 0.5, 6, planar, &g)
            return g
        }
        XCTAssertEqual(render(low, planar: 1), render(high, planar: 1))
        XCTAssertNotEqual(render(low, planar: 0), render(high, planar: 0))
    }

    func testFlatVBAPIgnoresHeightInDistanceToo() throws {
        let ring = [feral_point(x: 0, y: 5, z: 0), feral_point(x: 5, y: 0, z: 3), feral_point(x: 0, y: -5, z: 6),
                    feral_point(x: -5, y: 0, z: 0)]
        let v = try XCTUnwrap(feral_vbap_create(ring, 4, feral_point(x: 0, y: 0, z: 0), 2))
        defer { feral_vbap_destroy(v) }
        var a = [Float](repeating: 0, count: 4), b = [Float](repeating: 0, count: 4)
        // Far enough out that the roll-off applies.
        feral_vbap_render(v, feral_point(x: 8, y: 8, z: 0), 0, 1, 0, &a)
        feral_vbap_render(v, feral_point(x: 8, y: 8, z: 20), 0, 1, 0, &b)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a[0], a[1])
        XCTAssertLessThan(a[0], 0.7, "rolled off by the distance in plan")
    }

    // MARK: KNN and SPCAP

    /// Eight speakers in a ring of 5 m around the origin, speaker 0 straight along x.
    let ring = (0..<8).map { k -> feral_point in
        let a = Double(k) * .pi / 4
        return feral_point(x: 5 * cos(a), y: 5 * sin(a), z: 0)
    }

    func params(k: Int32 = 1, spread: Double = 0, tightness: Double = 1, planar: Int32 = 0) -> feral_pan_params {
        feral_pan_params(reference: feral_point(x: 0, y: 0, z: 0), planar: planar, rolloff: 0, reference_distance: 0,
                         neighbours: k, spread: spread, tightness: tightness)
    }

    func knn(_ degrees: Double, _ p: feral_pan_params, z: Double = 0) -> [Float] {
        var params = p
        var g = [Float](repeating: 0, count: 8)
        let a = degrees * .pi / 180
        feral_knn_render(ring, nil, 8, feral_point(x: 5 * cos(a), y: 5 * sin(a), z: z), &params, &g)
        return g
    }

    func testKNNPlaysOnAsFewSpeakersAsItCan() {
        XCTAssertEqual(knn(0, params()), [1, 0, 0, 0, 0, 0, 0, 0], "on a speaker with spread 0, only it plays")
        XCTAssertEqual(knn(10, params(k: 3)), [1, 0, 0, 0, 0, 0, 0, 0], "more neighbours without spread change nothing")
        let half = knn(22.5, params())
        XCTAssertEqual(half[0], half[1], accuracy: 1e-6, "halfway, both equally")
        XCTAssertEqual(half[0], Float(0.5.squareRoot()), accuracy: 1e-6)
        // Moving across the halfway point changes the gains smoothly.
        var last = knn(15, params())
        for tenth in 151...300 {
            let g = knn(Double(tenth) / 10, params())
            for k in 0..<8 { XCTAssertEqual(g[k], last[k], accuracy: 0.12) }
            last = g
        }
        let wide = knn(0, params(k: 3, spread: 60))
        XCTAssertGreaterThan(wide[1], 0)
        XCTAssertEqual(wide[1], wide[7], accuracy: 1e-6)
        XCTAssertEqual(wide.filter { $0 > 0 }.count, 3, "no more than K")
        XCTAssertEqual(knn(0, params(k: 3, spread: 60, planar: 1), z: 9), wide, "2D ignores height")
        XCTAssertNotEqual(knn(0, params(k: 3, spread: 60), z: 9), wide)
    }

    func testSPCAPCorrectsForCrowdedSpeakers() {
        func spcap(_ speakers: [feral_point], tightness: Double = 1) -> [Float] {
            var p = params(tightness: tightness)
            var g = [Float](repeating: 0, count: speakers.count)
            feral_spcap_render(speakers, nil, Int32(speakers.count), feral_point(x: 5, y: 0, z: 0), &p, &g)
            return g
        }
        let even = spcap(ring)
        XCTAssertEqual(even.map { $0 * $0 }.reduce(0, +), 1, accuracy: 1e-5, "power-normalised")
        XCTAssertGreaterThan(even[0], even[1])
        XCTAssertEqual(even[4], 0, accuracy: 1e-6, "nothing from straight behind")
        XCTAssertGreaterThan(spcap(ring, tightness: 8)[0], even[0], "tighter is narrower")
        // A ninth speaker crowding in next to speaker 1 turns both down, not the image towards them.
        let crowded = spcap(ring + [feral_point(x: 5 * cos(0.85), y: 5 * sin(0.85), z: 0)])
        XCTAssertLessThan(crowded[1], even[1])
    }
}
