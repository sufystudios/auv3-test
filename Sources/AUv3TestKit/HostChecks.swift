import AVFoundation
import AudioToolbox

/// Checks of what hosts do around the audio, rather than to it: change the sample rate,
/// run several instances, bypass an effect, load factory presets. Each is a common way
/// for a plugin that plays fine on its own to go wrong in a real session.
extension TestRun {
    /// Renders `seconds`, keeping every sample, with `perBlock` before each block.
    func capture(seconds: Double, perBlock: @escaping (Int) -> Void = { _ in }) -> (samples: [Float], stats: PhaseStats) {
        let recorder = SampleRecorder(frames: Int(seconds * host.sampleRate) + 8_192)
        host.recorder = recorder
        let stats = render(seconds: seconds, perBlock: perBlock)
        host.recorder = nil
        return (recorder.mono().samples, stats)
    }

    // MARK: Sample rates

    static let testRates: [Double] = [44_100, 48_000, 96_000]
    static func kHz(_ rate: Double) -> String { "\(TestRun.format(Float(rate / 1000))) kHz" }
    /// A3: low enough to measure cleanly, in every instrument's range.
    static let pitchNote: UInt8 = 57

    /// Hosts run at 44.1, 48 or 96 kHz (iOS devices at 48), and change it under a loaded
    /// plugin. A plugin that assumes one rate somewhere plays out of tune, or not at
    /// all, at the others - or at every rate, if it assumes one the device never uses.
    func checkSampleRates() {
        log("Playing at \(Self.testRates.map { Self.kHz($0) }.joined(separator: ", "))")
        struct Reading { var rate: Double; var peak: Float; var pitch: Double? }
        var readings: [Reading] = []
        var refused: [String] = []
        let host = self.host
        for rate in Self.testRates {
            do {
                try host.reconfigure(sampleRate: rate)
            } catch {
                refused.append("\(Int(rate)) Hz (\(error))")
                continue
            }
            let (samples, _) = capture(seconds: 1.5) { index in
                if index == 0, host.isInstrument { host.noteOn(Self.pitchNote) }
            }
            if host.isInstrument { _ = render(seconds: 0.3) { index in if index == 0 { host.noteOff(Self.pitchNote) } } }
            let peak = SoundAnalysis.peak(samples[...])
            readings.append(Reading(rate: rate, peak: peak, pitch: peak > 1e-3 ? SoundAnalysis.steadyPitch(samples[...], sampleRate: rate) : nil))
        }
        do {
            try host.reconfigure(sampleRate: options.sampleRate)
        } catch {
            refused.append("going back to \(Int(options.sampleRate)) Hz (\(error))")
        }

        var problems: [(failed: Bool, text: String)] = []
        var hints: [String] = []
        if !refused.isEmpty {
            problems.append((false, "It refused \(refused.joined(separator: ", "))."))
            hints.append("Accept any rate in your bus's format, and set your DSP up for it in allocateRenderResources: hosts choose it, and change it under a loaded plugin.")
        }
        let sounding = readings.filter { $0.peak > 1e-3 }
        let silent = readings.filter { $0.peak <= 1e-3 }
        if !sounding.isEmpty && !silent.isEmpty {
            problems.append((true, "Silent at \(silent.map { Self.kHz($0.rate) }.joined(separator: ", ")), though it sounds at \(sounding.map { Self.kHz($0.rate) }.joined(separator: ", "))."))
            hints.append("Something is set up for one rate only: check what allocateRenderResources does with the new format, and buffers sized at init.")
        }
        let pitched = readings.compactMap { reading in reading.pitch.map { (reading.rate, $0) } }
        let list = pitched.map { "\(Self.kHz($0.0)): \(String(format: "%.1f", $0.1)) Hz" }.joined(separator: ", ")
        if pitched.count >= 2 {
            let spread = 1200 * log2(pitched.map(\.1).max()! / pitched.map(\.1).min()!)
            if spread > 10 {
                problems.append((true, "Its pitch depends on the sample rate (\(list)): \(Int(spread)) cents apart."))
                hints.append("Somewhere a sample rate is assumed instead of read from the format: an oscillator's phase increment, a filter's coefficients, a delay's length in samples.")
            }
        }
        // For an instrument, the note itself: A3 is 220 Hz, octaves aside.
        if host.isInstrument, let typical = pitched.map(\.1).sorted().dropFirst(pitched.count / 2).first {
            let (cents, _) = SoundAnalysis.tuning(of: typical, note: Int(Self.pitchNote))
            if abs(cents) > 25 {
                problems.append((false, "A3 (MIDI note 57) plays at \(String(format: "%.1f", typical)) Hz: \(String(format: "%+.0f", cents)) cents off, octaves aside."))
                hints.append("If the default patch isn't meant to be detuned, look for a rate assumed inside the plugin's own graph - nodes made before the rate is set, or a library default (AudioKit's is 48 kHz on iOS 18 and later, 44.1 kHz on the Mac). A ratio of (44.1/48)² is -293 cents.")
            }
        }

        let status: CheckResult.Status = problems.contains { $0.failed } ? .failed : problems.isEmpty ? .passed : .warning
        let heard = sounding.isEmpty ? "Silent at every rate." : (pitched.isEmpty ? "Sounded at \(sounding.map { Self.kHz($0.rate) }.joined(separator: ", ")) (no single pitch to compare)." : "Pitch \(list).")
        var measurements: [String: Double] = [:]
        for (rate, pitch) in pitched { measurements["pitchHzAt\(Int(rate))"] = (pitch * 10).rounded() / 10 }
        checks.append(CheckResult(
            id: "sample-rates", title: "Plays the same at 44.1, 48 and 96 kHz",
            status: sounding.isEmpty && host.isInstrument ? .warning : status,
            detail: ([heard] + problems.map(\.text)).joined(separator: " "),
            hint: hints.isEmpty ? "Read the rate from the bus format in allocateRenderResources, and never assume one." : hints.joined(separator: " "),
            measurements: measurements))
    }
}
