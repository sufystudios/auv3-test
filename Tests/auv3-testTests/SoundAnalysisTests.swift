import Foundation
import Testing
@testable import AUv3TestKit

/// The scenario measurements, on made-up signals where the right answer is known.
@Suite struct SoundAnalysisTests {
    let rate = 48_000.0

    func sine(_ hz: Double, seconds: Double, level: Float = 0.5) -> [Float] {
        (0..<Int(seconds * rate)).map { level * Float(sin(2 * .pi * hz * Double($0) / rate)) }
    }

    func saw(_ hz: Double, seconds: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { i in
            let phase = (hz * Double(i) / rate).truncatingRemainder(dividingBy: 1)
            return Float(0.5 * (2 * phase - 1))
        }
    }

    @Test("Finds the pitch of a sine and of a sawtooth")
    func pitch() throws {
        let a3 = try #require(SoundAnalysis.pitch(sine(220, seconds: 0.5)[...], sampleRate: rate))
        #expect(abs(a3 - 220) < 0.5)
        let c3 = try #require(SoundAnalysis.pitch(saw(130.81, seconds: 0.5)[...], sampleRate: rate))
        #expect(abs(SoundAnalysis.tuning(of: c3, note: 48).cents) < 3)
    }

    @Test("Tuning folds octaves away: a note an octave up is in tune")
    func octaves() {
        let (cents, octaves) = SoundAnalysis.tuning(of: 440, note: 57)
        #expect(abs(cents) < 0.01)
        #expect(octaves == 1)
    }

    @Test("Noise has no pitch")
    func noise() {
        var seed: UInt64 = 1
        let noise = (0..<24_000).map { _ -> Float in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed) >> 40) / Float(1 << 23)
        }
        #expect(SoundAnalysis.pitch(noise[...], sampleRate: rate) == nil)
    }

    @Test("A gain stepped once per block is zipper noise; a per-sample glide isn't")
    func zipper() {
        let tone = sine(220, seconds: 2)
        let block = 512
        let stepped = tone.enumerated().map { i, x in x * (0.2 + 0.8 * Float(i / block * block) / Float(tone.count)) }
        let smooth = tone.enumerated().map { i, x in x * (0.2 + 0.8 * Float(i) / Float(tone.count)) }
        #expect(SoundAnalysis.zipper(stepped[...], blockSize: block) > 1.5)
        #expect(SoundAnalysis.zipper(smooth[...], blockSize: block) < 1.2)
    }

    @Test("A one-sample spike is a click; a filter opening isn't")
    func clicks() {
        // (On a sine: a raw, aliasing sawtooth's resets are as sharp as a small click.)
        var tone = sine(110, seconds: 2)
        tone[48_000] += 0.1
        #expect(SoundAnalysis.clickRatios(SoundAnalysis.windowMaxima(tone)).max()! > 4)

        // Brighter and brighter: a sine fading into a sawtooth, as a low-pass opens.
        let dull = sine(110, seconds: 2), bright = saw(110, seconds: 2)
        let opening = (0..<dull.count).map { i -> Float in
            let t = Float(i) / Float(dull.count)
            return dull[i] * (1 - t) + bright[i] * t
        }
        #expect(SoundAnalysis.clickRatios(SoundAnalysis.windowMaxima(opening)).max()! < 4)
    }

    @Test("A sound cut off at once is abrupt; a fade isn't, and its decay is measured")
    func cutsAndFades() {
        let tone = sine(220, seconds: 1)
        let cut = tone.enumerated().map { i, x in i < 24_000 ? x : 0 }
        #expect(SoundAnalysis.abruptStop(SoundAnalysis.envelope(cut[...], sampleRate: rate)) != nil)

        // An exponential fade of 60 dB over 0.5 s.
        let fade = tone.enumerated().map { i, x in x * Float(pow(10, -3 * Double(i) / (0.5 * rate))) }
        let envelope = SoundAnalysis.envelope(fade[...], sampleRate: rate)
        #expect(SoundAnalysis.abruptStop(envelope) == nil)
        let decay = SoundAnalysis.decayTime(envelope)
        #expect(decay != nil && abs(decay! - 0.5) < 0.05)
    }

    @Test("Scenario steps parse, with defaults, percentages and expectations")
    func parsing() throws {
        let scenario = try Scenario.load(Data("""
        { "steps": [
            { "play": [48, 55], "expect": "sound" },
            { "sweep": "cutoff", "from": "10%", "to": 8000, "over": 3 },
            { "release": "all", "for": 1, "expect": ["silence"] },
            { "wait": 0.5 } ] }
        """.utf8))
        #expect(scenario.steps.count == 4)
        #expect(scenario.steps[0].seconds == 2)
        #expect(scenario.steps[0].expect == [.sound])
        #expect(scenario.steps[1].seconds == 3)
        #expect(scenario.steps[1].title == "Sweep cutoff from 10% to 8000 over 3 s")
        #expect(scenario.steps[2].expect == [.silence])
        #expect(throws: ScenarioError.self) { try Scenario.load(Data(#"{ "steps": [ { "jump": 1 } ] }"#.utf8)) }
    }
}
