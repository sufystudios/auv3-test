import Foundation

/// Measurements of rendered audio for scenarios: pure functions on mono samples, so
/// they can be tested on signals where the right answer is known.
enum SoundAnalysis {
    static func decibels(_ x: Float) -> Double { x > 0 ? 20 * log10(Double(x)) : -200 }

    static func peak(_ x: ArraySlice<Float>) -> Float { x.reduce(0) { max($0, abs($1)) } }

    static func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        return sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(x.count))
    }

    static func mean(_ x: ArraySlice<Float>) -> Float {
        x.isEmpty ? 0 : x.reduce(0, +) / Float(x.count)
    }

    /// |second difference| at each sample: the waveform's sharpness. Steady for a
    /// steady sound; a click or a stepped change spikes it.
    static func edges(_ x: ArraySlice<Float>) -> [Float] {
        let x = Array(x)
        guard x.count > 2 else { return [] }
        var e = [Float](repeating: 0, count: x.count)
        for i in 2..<x.count { e[i] = abs(x[i] - 2 * x[i - 1] + x[i - 2]) }
        return e
    }

    /// Each window's sharpest edge. Windows are long enough (43 ms at 48 kHz) to hold
    /// whole cycles of notes from about 24 Hz up, so a sawtooth's own resets are part
    /// of every window's steady sound rather than standing out.
    static let clickWindow = 2048

    static func windowMaxima(_ x: [Float], window: Int = clickWindow) -> [Float] {
        let e = edges(x[...])
        return stride(from: 0, to: e.count - window + 1, by: window).map { e[$0..<($0 + window)].max() ?? 0 }
    }

    /// How much each window's sharpest edge stands above the sound on both sides of it:
    /// the larger of the median of up to 4 windows before and 4 after. A click stands
    /// out from both; a sound getting brighter (a filter opening) doesn't, as the
    /// windows on one side are as sharp.
    static func clickRatios(_ maxima: [Float]) -> [Double] {
        maxima.indices.map { i in
            func median(_ range: Range<Int>) -> Float? {
                let values = maxima[range.clamped(to: maxima.indices)].sorted()
                return values.isEmpty ? nil : values[values.count / 2]
            }
            let before = median((i - 4)..<i), after = median((i + 1)..<(i + 5))
            let reference = max(before ?? 0, after ?? 0)
            return reference > 1e-6 ? Double(maxima[i] / reference) : 1
        }
    }

    /// Zipper noise: a parameter changing in steps, once per render block, as a host's
    /// automation arrives, instead of gliding. Each step sharpens the waveform right at
    /// a block's start. Returns how much sharper the waveform is in the first two
    /// samples of blocks than everywhere else: about 1 when the change is smooth.
    static func zipper(_ x: ArraySlice<Float>, blockSize: Int) -> Double {
        let e = edges(x)
        guard e.count > blockSize * 8 else { return 1 }
        var atBoundaries: Float = 0, boundaryCount: Float = 0
        var elsewhere: Float = 0, elsewhereCount: Float = 0
        for i in 2..<e.count {
            if i % blockSize < 2 {
                atBoundaries += e[i]; boundaryCount += 1
            } else {
                elsewhere += e[i]; elsewhereCount += 1
            }
        }
        guard boundaryCount > 0, elsewhereCount > 0, elsewhere > 1e-9 else { return 1 }
        return Double((atBoundaries / boundaryCount) / (elsewhere / elsewhereCount))
    }

    /// The fundamental frequency, by YIN (de Cheveigné and Kawahara), from 30 Hz to
    /// 2 kHz, or nil when there's no clear pitch.
    static func pitch(_ x: ArraySlice<Float>, sampleRate: Double) -> Double? {
        let x = Array(x)
        let maxTau = Int(sampleRate / 30), minTau = Int(sampleRate / 2000)
        let window = min(x.count - maxTau, 4096)
        guard window > 512 else { return nil }
        var d = [Float](repeating: 0, count: maxTau + 1)
        for tau in 1...maxTau {
            var sum: Float = 0
            for i in 0..<window {
                let delta = x[i] - x[i + tau]
                sum += delta * delta
            }
            d[tau] = sum
        }
        // Cumulative mean normalised difference: dips near 0 at the period.
        var normalised = [Float](repeating: 1, count: maxTau + 1)
        var running: Float = 0
        for tau in 1...maxTau {
            running += d[tau]
            normalised[tau] = running > 0 ? d[tau] * Float(tau) / running : 1
        }
        var tau = minTau
        while tau < maxTau {
            if normalised[tau] < 0.15 {
                while tau + 1 < maxTau && normalised[tau + 1] < normalised[tau] { tau += 1 }
                break
            }
            tau += 1
        }
        guard tau < maxTau, normalised[tau] < 0.15 else { return nil }
        // Between samples, from the parabola through the dip.
        let a = normalised[tau - 1], b = normalised[tau], c = normalised[tau + 1]
        let shift = (a - c) / (2 * (a - 2 * b + c))
        let period = Double(tau) + (shift.isFinite ? Double(shift) : 0)
        return sampleRate / period
    }

    /// A held note's pitch: three readings across the second half, clear of the onset,
    /// that agree within 30 cents; their median. Nil when there isn't a steady one.
    static func steadyPitch(_ x: ArraySlice<Float>, sampleRate: Double) -> Double? {
        let readings = [0.5, 0.65, 0.8].compactMap { fraction -> Double? in
            let start = x.index(x.startIndex, offsetBy: Int(Double(x.count) * fraction))
            return pitch(x[start..<min(start + 6_000, x.endIndex)], sampleRate: sampleRate)
        }.sorted()
        guard readings.count == 3, 1200 * log2(readings[2] / readings[0]) < 30 else { return nil }
        return readings[1]
    }

    static func noteFrequency(_ note: Int) -> Double { 440 * pow(2, Double(note - 69) / 12) }

    /// How far `frequency` is from `note`, in cents, folded to the nearest octave (a
    /// patch an octave up is in tune), with the octaves it's off by.
    static func tuning(of frequency: Double, note: Int) -> (cents: Double, octaves: Int) {
        let cents = 1200 * log2(frequency / noteFrequency(note))
        let octaves = Int((cents / 1200).rounded())
        return (cents - Double(octaves) * 1200, octaves)
    }

    /// Level in 10 ms frames, in dBFS: for fades, tails and sudden cuts.
    static func envelope(_ x: ArraySlice<Float>, sampleRate: Double) -> [Double] {
        let frame = max(1, Int(sampleRate / 100))
        return stride(from: x.startIndex, to: x.endIndex, by: frame).map { start in
            decibels(rms(x[start..<min(start + frame, x.endIndex)]))
        }
    }

    /// The first 10 ms frame where the sound drops by 40 dB or more from one frame to
    /// the next while it was clearly audible (a cut or dropout, not a fade), if any.
    static func abruptStop(_ envelope: [Double]) -> Int? {
        guard envelope.count > 1 else { return nil }
        for i in 1..<envelope.count where envelope[i - 1] > -40 && envelope[i] < envelope[i - 1] - 40 {
            return i
        }
        return nil
    }

    /// When the sound first rises above -60 dBFS, in seconds, or nil if it never does.
    static func onset(_ envelope: [Double]) -> Double? {
        envelope.firstIndex { $0 > -60 }.map { Double($0) / 100 }
    }

    /// How long the sound takes to fall 60 dB below its level at the start, in seconds,
    /// or nil if it hasn't by the end.
    static func decayTime(_ envelope: [Double]) -> Double? {
        guard let start = envelope.first, start > -100 else { return nil }
        guard let index = envelope.firstIndex(where: { $0 < start - 60 }) else { return nil }
        return Double(index) / 100
    }
}
