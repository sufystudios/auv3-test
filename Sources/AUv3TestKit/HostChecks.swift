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

    // MARK: Two instances

    /// Hosts load a plugin on several tracks at once. One that keeps its state in
    /// statics or singletons - a shared parameter tree, engine or voice - plays one
    /// track's notes on another, or moves both when one knob turns.
    func checkTwoInstances() {
        log("Loading a second instance alongside the first")
        let a = host
        let b: PluginHost
        do {
            b = try PluginHost(options: options)
            try b.prepare()
        } catch {
            checks.append(CheckResult(id: "two-instances", title: "Runs as two independent instances", status: .warning,
                detail: "A second instance wouldn't load or start: \(error).",
                hint: "Hosts load a plugin once per track. Make sure nothing in your AU or extension is meant to exist only once."))
            return
        }
        defer { b.stop() }

        /// Renders both, A then B each cycle as a host's graph does, keeping A's audio.
        func renderBoth(_ seconds: Double, _ perBlock: @escaping (Int) -> Void = { _ in }) -> [Float] {
            let recorder = SampleRecorder(frames: Int(seconds * a.sampleRate) + 8_192)
            a.recorder = recorder
            let blocks = Int((seconds / a.blockDuration).rounded(.up))
            let realTime = options.realTime
            let done = DispatchSemaphore(value: 0)
            let thread = Thread {
                let start = DispatchTime.now().uptimeNanoseconds
                for index in 0..<blocks {
                    perBlock(index)
                    _ = a.renderBlock()
                    _ = b.renderBlock()
                    if realTime {
                        let deadline = start + UInt64(Double(index + 1) * a.blockDuration * 1e9)
                        let now = DispatchTime.now().uptimeNanoseconds
                        if deadline > now { usleep(useconds_t((deadline - now) / 1_000)) }
                    }
                }
                done.signal()
            }
            thread.qualityOfService = .userInteractive
            thread.start()
            done.wait()
            a.recorder = nil
            return recorder.mono().samples
        }

        var problems: [(failed: Bool, text: String)] = []
        var hints: [String] = []
        var m: [String: Double] = [:]
        _ = renderBoth(0.5)  // Let anything still sounding in A fade.

        // 1. B's note mustn't sound in A.
        if a.isInstrument {
            let leaked = renderBoth(1) { index in if index == 0 { b.noteOn(48) } }
            _ = renderBoth(0.3) { index in if index == 0 { b.noteOff(48) } }
            let peak = SoundAnalysis.peak(leaked[...])
            m["peakInFirstFromSecondsNote"] = Double(peak)
            if peak > 1e-3 {
                problems.append((true, "A note played on the second instance sounded in the first (peak \(Int(SoundAnalysis.decibels(peak))) dBFS)."))
                hints.append("The instances share a voice, engine or audio graph - a static, a singleton, or one created once per process. Make each AUAudioUnit build its own.")
            }
        }

        // 2. B's controls mustn't move A's: first how much A varies by itself, then
        // with B's parameters all changed.
        let note = Self.pitchNote
        if a.isInstrument { _ = renderBoth(0.3) { index in if index == 0 { a.noteOn(note) } } }
        let before = renderBoth(1), steady = renderBoth(1)
        let aTree = a.audioUnit.parameterTree?.allParameters ?? []
        let aValues = aTree.map(\.value)
        let bTargets = (b.audioUnit.parameterTree?.allParameters ?? []).filter { $0.flags.contains(.flag_IsWritable) && $0.maxValue > $0.minValue }
        for (i, parameter) in bTargets.enumerated() {
            parameter.setValue(Self.sweep(parameter, t: 7.3, lane: i), originator: nil)
        }
        let after = renderBoth(1)
        if a.isInstrument { _ = renderBoth(0.3) { index in if index == 0 { a.noteOff(note) } } }

        let movedInA = zip(aTree, aValues).filter { abs($0.0.value - $0.1) > max(1e-4, ($0.0.maxValue - $0.0.minValue) * 1e-3) }
        if !bTargets.isEmpty && !movedInA.isEmpty {
            problems.append((true, "Setting the second instance's parameters changed \(movedInA.count) of the first's (\(movedInA.prefix(4).map { $0.0.identifier }.joined(separator: ", ")))."))
            hints.append("The instances share a parameter tree or the values behind it. Build the AUParameterTree, and whatever stores its values, per instance.")
        }
        func level(_ x: [Float]) -> Double { SoundAnalysis.decibels(SoundAnalysis.rms(x[...])) }
        let drift = abs(level(steady) - level(before)), change = abs(level(after) - level(steady))
        m["levelDriftDb"] = (drift * 10).rounded() / 10
        m["levelChangeDb"] = (change * 10).rounded() / 10
        if !bTargets.isEmpty, level(before) > -60, change > max(3, 3 * drift) {
            problems.append((true, "The first instance's sound changed by \(String(format: "%.1f", change)) dB when the second's parameters changed (it drifts by \(String(format: "%.1f", drift)) dB on its own)."))
            hints.append("The DSP state is shared between instances: look for static or global filter, oscillator or buffer state in the kernel.")
        }
        if a.isInstrument, let p1 = SoundAnalysis.steadyPitch(steady[...], sampleRate: a.sampleRate),
           let p2 = SoundAnalysis.steadyPitch(after[...], sampleRate: a.sampleRate), abs(1200 * log2(p2 / p1)) > 10 {
            problems.append((true, "The first instance's pitch moved from \(String(format: "%.1f", p1)) to \(String(format: "%.1f", p2)) Hz when the second's parameters changed."))
            hints.append("Tuning or oscillator state is shared between instances.")
        }

        restoreStartingValues()
        checks.append(CheckResult(
            id: "two-instances", title: "Runs as two independent instances",
            status: problems.contains { $0.failed } ? .failed : .passed,
            detail: problems.isEmpty
                ? "A second instance loaded alongside the first; its notes and its \(bTargets.count) parameters left the first alone."
                : problems.map(\.text).joined(separator: " "),
            hint: hints.isEmpty ? "Everything an instance uses should belong to that instance." : hints.joined(separator: " "),
            measurements: m))
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
