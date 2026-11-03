import Foundation

/// A level spectrum for display: dB per point on a log frequency scale, from `lowHz` to `highHz`.
/// 0 dB is a full-scale sine.
public enum Spectrum {
    public static let lowHz: Double = 20
    public static let highHz: Double = 20_000
    public static let points = 160
    public static let fftSize = 4096
    /// Below anything worth drawing.
    public static let floorDB: Float = -120

    /// The frequency of point i.
    public static func frequency(_ i: Int) -> Double {
        lowHz * pow(highHz / lowHz, Double(i) / Double(points - 1))
    }

    /// The spectrum of the last `fftSize` samples (fewer are padded with zeros at the start), Hann
    /// windowed. Each point takes the loudest bin within a twelfth of an octave of it (so a tone reads its
    /// level), and
    /// reads between the two nearest bins where none is that close (the low end).
    public static func analyse(_ samples: [Float], sampleRate: Double) -> [Float] {
        let n = fftSize
        var re = [Double](repeating: 0, count: n), im = [Double](repeating: 0, count: n)
        let x = samples.suffix(n)
        let offset = n - x.count
        var windowSum = 0.0
        for k in 0..<n {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(k) / Double(n))
            windowSum += w
            if k >= offset { re[k] = w * Double(x[x.startIndex + k - offset]) }
        }
        fft(&re, &im)
        // Power per bin, scaled so a full-scale sine reads 0 dB.
        let half = n / 2
        let scale = 2 / windowSum
        var power = [Double](repeating: 0, count: half + 1)
        for k in 0...half {
            let m = (re[k] * re[k] + im[k] * im[k]).squareRoot() * scale
            power[k] = m * m
        }
        let binHz = sampleRate / Double(n)
        let spread = pow(2, 1.0 / 24)
        return (0..<points).map { i -> Float in
            let f = frequency(i)
            guard f < sampleRate / 2 else { return floorDB }
            let lo = Int((f / spread / binHz).rounded(.up)), hi = Int((f * spread / binHz).rounded(.down))
            var p: Double
            if lo <= hi, hi <= half {
                p = power[max(lo, 0)...hi].max() ?? 0
            } else {
                let at = f / binHz, k = min(Int(at), half - 1), t = at - Double(k)
                p = power[k] * (1 - t) + power[k + 1] * t
            }
            return max(floorDB, Float(10 * log10(max(p, 1e-30))))
        }
    }

    /// In-place radix-2 FFT; the count must be a power of two.
    static func fft(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j |= bit
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let angle = -2 * Double.pi / Double(len)
            let wr = cos(angle), wi = sin(angle)
            var start = 0
            while start < n {
                var cr = 1.0, ci = 0.0
                for k in 0..<(len / 2) {
                    let a = start + k, b = a + len / 2
                    let tr = re[b] * cr - im[b] * ci, ti = re[b] * ci + im[b] * cr
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                    let next = cr * wr - ci * wi
                    ci = cr * wi + ci * wr
                    cr = next
                }
                start += len
            }
            len <<= 1
        }
    }
}
