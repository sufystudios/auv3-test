import Foundation
import Testing
@testable import auv3_test

/// The click check, on made-up signals where the right answer is known: three holds
/// of 12 blocks, jumping something at the start of the second and third, as the
/// `clicks` check does to a plugin.
struct ClickDetectionTests {
    static let sampleRate: Float = 48_000
    static let blockSize = 512
    static let holdBlocks = 12
    static let transitionBlocks = 4

    /// Runs `sample(n, hold)` through the edge meter, returning each block's sharpest edge.
    static func edges(_ sample: (Int, Int) -> Float) -> [Float] {
        var meter = EdgeMeter()
        var edges: [Float] = []
        for block in 0..<(3 * holdBlocks) {
            var sharpest: Float = 0
            for i in 0..<blockSize {
                let n = block * blockSize + i
                sharpest = max(sharpest, meter.measure(sample(n, block / holdBlocks)))
            }
            edges.append(sharpest)
        }
        return edges
    }

    static func ratio(_ sample: (Int, Int) -> Float) -> Float? {
        ClickDetection.clickRatio(edges: edges(sample), holdBlocks: holdBlocks, transitionBlocks: transitionBlocks)
    }

    static func sine(_ n: Int, _ hz: Float = 220) -> Float { sin(2 * .pi * hz * Float(n) / sampleRate) }

    /// Where a hold starts, in samples.
    static func start(_ hold: Int) -> Int { hold * holdBlocks * blockSize }

    @Test("A gain applied in one sample clicks")
    func instantGainStep() {
        let ratio = Self.ratio { n, hold in Self.sine(n) * (hold == 1 ? 0.6 : 0.2) }
        #expect(ratio != nil)
    }

    @Test("The same change, glided over 10 ms, doesn't")
    func glidedGainStep() {
        let glide = Int(0.01 * Self.sampleRate)
        let ratio = Self.ratio { n, hold in
            func gain(_ hold: Int) -> Float { hold == 1 ? 0.6 : 0.2 }
            guard hold > 0 else { return Self.sine(n) * gain(0) }
            let progress = min(1, Float(n - Self.start(hold)) / Float(glide))
            return Self.sine(n) * (gain(hold - 1) + (gain(hold) - gain(hold - 1)) * progress)
        }
        #expect(ratio == nil)
    }

    @Test("A steady tone doesn't")
    func steadyTone() {
        #expect(Self.ratio { n, _ in Self.sine(n) * 0.3 } == nil)
    }

    @Test("A sawtooth's own jumps don't, even when its level changes")
    func sawtooth() {
        // A naive sawtooth jumps every cycle; a gain change on it is masked by those.
        let ratio = Self.ratio { n, hold in
            let phase = (Float(n) * 130 / Self.sampleRate).truncatingRemainder(dividingBy: 1)
            return (2 * phase - 1) * (hold == 1 ? 0.3 : 0.15)
        }
        #expect(ratio == nil)
    }

    @Test("A brighter sound after the jump - a filter opening - doesn't")
    func brightnessChange() {
        // A one-pole lowpass on a sawtooth, its cutoff jumping from 300 Hz to 5 kHz and
        // back in a single sample: no step in the waveform, just a brighter sound.
        var state: Float = 0
        let ratio = Self.ratio { n, hold in
            let phase = (Float(n) * 130 / Self.sampleRate).truncatingRemainder(dividingBy: 1)
            let cutoff: Float = hold == 1 ? 5_000 : 300
            let coefficient = 1 - exp(-2 * .pi * cutoff / Self.sampleRate)
            state += coefficient * ((2 * phase - 1) * 0.3 - state)
            return state
        }
        #expect(ratio == nil)
    }

    @Test("Silence that jumps to a quiet level isn't counted as an audible click")
    func inaudible() {
        #expect(Self.ratio { n, hold in Self.sine(n) * (hold == 1 ? 0.004 : 0.001) } == nil)
    }
}
