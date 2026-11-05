import AVFoundation
import AudioToolbox

/// A scenario: what to play and change, step by step, as a person or an agent would
/// while trying a plugin. auv3-test plays it the way a DAW plays a track (notes and
/// automation from the render thread), records it, and measures each step.
///
///     { "name": "Filter and delay",
///       "steps": [
///         { "play": [48, 55, 60], "for": 2, "expect": "sound" },
///         { "sweep": "cutoff", "from": 200, "to": 8000, "over": 4 },
///         { "set": "delayMix", "to": "50%", "for": 2 },
///         { "release": "all", "for": 4 },
///         { "play": 57, "for": 2, "expect": "in-tune" } ] }
///
/// Parameters are named by identifier, key path or display name (any case), or by
/// address. Values are in the parameter's own units, or "N%" of its range.
struct Scenario: Decodable {
    var name: String?
    var steps: [Step]

    enum Value: Decodable {
        case units(Float)
        case percent(Float)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Float.self) {
                self = .units(number)
                return
            }
            let text = try container.decode(String.self).trimmingCharacters(in: .whitespaces)
            guard text.hasSuffix("%"), let percent = Float(text.dropLast()) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "a value is a number, or a percentage like \"50%\"")
            }
            self = .percent(percent)
        }

        func resolve(for parameter: AUParameter) -> AUValue {
            switch self {
            case .units(let value): return min(max(value, parameter.minValue), parameter.maxValue)
            case .percent(let percent): return parameter.minValue + (parameter.maxValue - parameter.minValue) * min(max(percent, 0), 100) / 100
            }
        }

        var text: String {
            switch self {
            case .units(let value): return TestRun.format(value)
            case .percent(let percent): return "\(TestRun.format(percent))%"
            }
        }
    }

    enum Action {
        case play(notes: [UInt8], velocity: UInt8)
        case release(notes: [UInt8]?)  // nil: every held note
        case set(parameter: String, to: Value)
        case sweep(parameter: String, from: Value, to: Value)
        case wait
    }

    enum Expectation: String, Decodable {
        case sound, silence, inTune = "in-tune"
    }

    struct Step: Decodable {
        var action: Action
        var seconds: Double
        var expect: [Expectation]

        private enum Key: String, CodingKey {
            case play, velocity, release, set, sweep, from, to, over, wait, `for`, expect
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            func notes(_ key: Key) throws -> [UInt8] {
                if let one = try? c.decode(Int.self, forKey: key) { return [UInt8(clamping: one)] }
                return try c.decode([Int].self, forKey: key).map { UInt8(clamping: $0) }
            }
            let duration = try c.decodeIfPresent(Double.self, forKey: .for)
            if c.contains(.play) {
                action = .play(notes: try notes(.play), velocity: UInt8(clamping: try c.decodeIfPresent(Int.self, forKey: .velocity) ?? 100))
                seconds = duration ?? 2
            } else if c.contains(.release) {
                let all = (try? c.decode(String.self, forKey: .release)) == "all"
                action = .release(notes: all ? nil : try notes(.release))
                seconds = duration ?? 2
            } else if let name = try c.decodeIfPresent(String.self, forKey: .set) {
                action = .set(parameter: name, to: try c.decode(Value.self, forKey: .to))
                seconds = duration ?? 1
            } else if let name = try c.decodeIfPresent(String.self, forKey: .sweep) {
                action = .sweep(parameter: name, from: try c.decode(Value.self, forKey: .from), to: try c.decode(Value.self, forKey: .to))
                seconds = try c.decodeIfPresent(Double.self, forKey: .over) ?? duration ?? 4
            } else if let wait = try c.decodeIfPresent(Double.self, forKey: .wait) {
                action = .wait
                seconds = wait
            } else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "each step is one of play, release, set, sweep or wait"))
            }
            if let one = try? c.decode(Expectation.self, forKey: .expect) {
                expect = [one]
            } else {
                expect = try c.decodeIfPresent([Expectation].self, forKey: .expect) ?? []
            }
            guard seconds > 0, seconds <= 600 else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "a step lasts more than 0 and at most 600 seconds"))
            }
        }

        var title: String {
            let length = "\(TestRun.format(Float(seconds))) s"
            switch action {
            case .play(let notes, let velocity):
                return "Play \(notes.map { Scenario.noteName(Int($0)) }.joined(separator: " "))" + (velocity == 100 ? "" : " at velocity \(velocity)") + ", \(length)"
            case .release(let notes):
                return "Release \(notes.map { $0.map { Scenario.noteName(Int($0)) }.joined(separator: " ") } ?? "all notes"), \(length)"
            case .set(let parameter, let value): return "Set \(parameter) to \(value.text), \(length)"
            case .sweep(let parameter, let from, let to): return "Sweep \(parameter) from \(from.text) to \(to.text) over \(length)"
            case .wait: return "Wait \(length)"
            }
        }
    }

    static func load(_ json: Data) throws -> Scenario {
        do {
            let scenario = try JSONDecoder().decode(Scenario.self, from: json)
            guard !scenario.steps.isEmpty else { throw ScenarioError("the scenario has no steps") }
            return scenario
        } catch let error as DecodingError {
            throw ScenarioError("the scenario isn't valid: \(Self.describe(error))")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context), .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map { $0.intValue.map { "step \($0 + 1)" } ?? $0.stringValue }.joined(separator: ", ")
            return (path.isEmpty ? "" : "\(path): ") + context.debugDescription
        case .keyNotFound(let key, let context):
            let path = context.codingPath.map { $0.intValue.map { "step \($0 + 1)" } ?? $0.stringValue }.joined(separator: ", ")
            return (path.isEmpty ? "" : "\(path): ") + "\"\(key.stringValue)\" is missing"
        @unknown default:
            return String(describing: error)
        }
    }

    static func noteName(_ note: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[((note % 12) + 12) % 12])\(note / 12 - 1)"
    }
}

struct ScenarioError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Keeps every sample a scenario renders, in arrays reserved up front so the render
/// thread doesn't allocate.
final class SampleRecorder: @unchecked Sendable {
    private(set) var left: [Float] = []
    private(set) var right: [Float] = []

    init(frames: Int) {
        left.reserveCapacity(frames)
        right.reserveCapacity(frames)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
        let second = buffer.format.channelCount > 1 ? 1 : 0
        right.append(contentsOf: UnsafeBufferPointer(start: data[second], count: frames))
    }

    /// Left and right mixed, with anything not finite as silence (and counted).
    func mono() -> (samples: [Float], nonFinite: [Int]) {
        var nonFinite: [Int] = []
        let samples = zip(left, right).enumerated().map { index, pair -> Float in
            let value = (pair.0 + pair.1) / 2
            if !value.isFinite { nonFinite.append(index); return 0 }
            return value
        }
        return (samples, nonFinite)
    }
}

extension TestRun {
    /// Plays the scenario, then measures each step into a check.
    func runScenario(_ scenario: Scenario, spectrogram: URL?) -> [String: String] {
        var notes: [String: String] = [:]
        let parameters = host.audioUnit.parameterTree?.allParameters ?? []
        func find(_ name: String) -> AUParameter? {
            if let address = UInt64(name) { return parameters.first { $0.address == address } }
            let wanted = name.lowercased()
            return parameters.first { $0.identifier.lowercased() == wanted }
                ?? parameters.first { $0.keyPath.lowercased() == wanted }
                ?? parameters.first { $0.displayName.lowercased() == wanted }
        }
        // Every parameter named must exist, before anything plays.
        for (index, step) in scenario.steps.enumerated() {
            switch step.action {
            case .set(let name, _), .sweep(let name, _, _):
                if find(name) == nil {
                    let known = parameters.prefix(40).map(\.identifier).joined(separator: ", ")
                    checks.append(CheckResult(id: "scenario", title: "Plays the scenario", status: .failed,
                        detail: "Step \(index + 1) names a parameter the plugin doesn't have: \(name).",
                        hint: "Name parameters by identifier, key path, display name or address. This plugin's identifiers: \(known)\(parameters.count > 40 ? "…" : "")."))
                    return notes
                }
            default: break
            }
        }
        if !host.isInstrument, scenario.steps.contains(where: { if case .play = $0.action { return true } else { return false } }) {
            notes["scenarioNotes"] = "the plugin is an effect: its input is a test tone, and notes go to it as MIDI"
        }

        let blockSize = Int(options.blockSize)
        let blocksPerStep = scenario.steps.map { Int(($0.seconds / host.blockDuration).rounded(.up)) }
        let totalFrames = blocksPerStep.reduce(0, +) * blockSize
        let recorder = SampleRecorder(frames: totalFrames + blockSize)
        var durations = [Double](repeating: 0, count: blocksPerStep.reduce(0, +))
        var statuses = [OSStatus](repeating: noErr, count: durations.count)
        // A second of silence first, not measured: a host has been running a while
        // before anyone plays, and some plugins take a moment to make their first sound.
        _ = render(seconds: 1)
        host.recorder = recorder
        host.capture?.begin("scenario", seconds: Double(totalFrames) / options.sampleRate)

        // Each step's events, resolved before the render thread runs.
        enum Event { case on([UInt8], UInt8), off([UInt8]?), set(AUParameter, AUValue), sweep(AUParameter, AUValue, AUValue) , none }
        let events: [Event] = scenario.steps.map { step in
            switch step.action {
            case .play(let notes, let velocity): return .on(notes, velocity)
            case .release(let notes): return .off(notes)
            case .set(let name, let value):
                let p = find(name)!
                return .set(p, value.resolve(for: p))
            case .sweep(let name, let from, let to):
                let p = find(name)!
                return .sweep(p, from.resolve(for: p), to.resolve(for: p))
            case .wait: return .none
            }
        }

        let host = self.host
        let realTime = options.realTime
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            var held = Set<UInt8>()
            var block = 0
            let start = DispatchTime.now().uptimeNanoseconds
            for (stepIndex, event) in events.enumerated() {
                let count = blocksPerStep[stepIndex]
                for index in 0..<count {
                    let result = host.renderBlock { _ in
                        switch event {
                        case .on(let notes, let velocity) where index == 0:
                            for note in notes { host.noteOn(note, velocity: velocity); held.insert(note) }
                        case .off(let notes) where index == 0:
                            for note in notes ?? Array(held) { host.noteOff(note); held.remove(note) }
                        case .set(let p, let value) where index == 0:
                            host.automate(p.address, to: value)
                        case .sweep(let p, let from, let to):
                            host.automate(p.address, to: Scenario.sweepValue(p, from: from, to: to, t: Double(index) / Double(max(1, count - 1))))
                        default: break
                        }
                    }
                    durations[block] = result.duration
                    statuses[block] = result.status
                    block += 1
                    if realTime {
                        let deadline = start + UInt64(Double(block) * host.blockDuration * 1e9)
                        let now = DispatchTime.now().uptimeNanoseconds
                        if deadline > now { usleep(useconds_t((deadline - now) / 1_000)) }
                    }
                }
            }
            // Leave nothing sounding for whatever runs next.
            _ = host.renderBlock { _ in for note in held { host.noteOff(note) } }
            done.signal()
        }
        thread.qualityOfService = .userInteractive
        thread.name = "auv3-test render"
        thread.start()
        done.wait()
        host.recorder = nil
        host.capture?.finish()

        let (mono, nonFinite) = recorder.mono()
        // Clicks are judged against the sound on both sides, across step boundaries.
        let clickRatios = SoundAnalysis.clickRatios(SoundAnalysis.windowMaxima(mono))
        var frame = 0, block = 0
        var boundaries: [Int] = []
        for (index, step) in scenario.steps.enumerated() {
            let frames = blocksPerStep[index] * blockSize
            let range = frame..<min(frame + frames, mono.count)
            boundaries.append(frame)
            let window = SoundAnalysis.clickWindow
            let windows = ((range.lowerBound + window - 1) / window)..<(range.upperBound / window)
            checks.append(measure(step, number: index + 1, samples: mono[range],
                                  clicks: windows.map { (ratio: clickRatios[$0], at: $0 * window - range.lowerBound) },
                                  nonFinite: nonFinite.filter { range.contains($0) }.count,
                                  durations: Array(durations[block..<(block + blocksPerStep[index])]),
                                  statuses: Array(statuses[block..<(block + blocksPerStep[index])])))
            frame += frames
            block += blocksPerStep[index]
        }
        if let spectrogram {
            if let problem = Spectrogram.write(mono, sampleRate: options.sampleRate, steps: boundaries, to: spectrogram) {
                notes["spectrogram"] = "not saved: \(problem)"
            } else {
                notes["spectrogram"] = "saved to \(spectrogram.path)"
            }
        }
        return notes
    }

    /// One step's audio, measured into a check: what was heard, and anything wrong.
    private func measure(_ step: Scenario.Step, number: Int, samples: ArraySlice<Float>,
                         clicks: [(ratio: Double, at: Int)], nonFinite: Int,
                         durations: [Double], statuses: [OSStatus]) -> CheckResult {
        let rate = options.sampleRate
        var problems: [(failed: Bool, text: String, hint: String)] = []
        var m: [String: Double] = [:]

        let peak = SoundAnalysis.peak(samples), rms = SoundAnalysis.rms(samples)
        m["peakDb"] = (SoundAnalysis.decibels(peak) * 10).rounded() / 10
        m["rmsDb"] = (SoundAnalysis.decibels(rms) * 10).rounded() / 10
        let clipped = samples.filter { abs($0) >= 1 }.count
        m["clippedSamples"] = Double(clipped)
        let dc = SoundAnalysis.mean(samples)
        m["dcOffset"] = (Double(dc) * 10_000).rounded() / 10_000

        // Timing, as in the other checks (the first few calls may warm caches).
        let measured = durations.dropFirst(min(8, max(0, durations.count - 1)))
        let late = measured.filter { $0 > host.blockDuration }.count
        let stalls = measured.filter { $0 > 0.1 }.count
        m["worstRenderMs"] = ((measured.max() ?? 0) * 10_000).rounded() / 10
        m["lateBlocks"] = Double(late)
        let errors = statuses.filter { $0 != noErr }
        if let error = errors.first {
            problems.append((true, "\(errors.count) render calls failed (\(TestRun.errorName(error))).", "A render error drops audio in a host. See the plays check's hint in the README."))
        }
        if nonFinite > 0 {
            problems.append((true, "\(nonFinite) samples were NaN or infinite.", "Usually a filter or feedback path blowing up at this setting, or a divide by zero. Clamp coefficients and guard denominators."))
        }
        if stalls > 0 {
            problems.append((true, "\(stalls) render calls took over 100 ms: an audible dropout.", "Something on the render thread waited: a lock, the main thread, allocation or I/O. Whatever this step changes is the place to look."))
        } else if late > max(1, measured.count / 50) {
            problems.append((false, "\(late) of \(measured.count) render calls ran late.", "This step costs more CPU than the block allows, or the render thread waits briefly. Profile it with this scenario running."))
        }
        if clipped > 0 {
            problems.append((false, "\(clipped) samples clipped (at or over 0 dBFS).", "A host's output would distort here. Leave headroom, or soft-clip the output stage."))
        }
        if abs(dc) > 0.02 {
            problems.append((false, "A DC offset of \(TestRun.format(dc)).", "DC wastes headroom and thumps when it starts or stops. A DC-blocking high-pass (around 10 Hz) on the output removes it."))
        }

        // Clicks, leaving out a played note's own onset (that's the patch's attack).
        var judged = clicks
        if case .play = step.action { judged = Array(judged.dropFirst()) }
        if let worst = judged.max(by: { $0.ratio < $1.ratio }), SoundAnalysis.rms(samples) > 1e-4 {
            m["clickRatio"] = (worst.ratio * 10).rounded() / 10
            if worst.ratio > 4 {
                let seconds = Double(max(0, worst.at)) / rate
                problems.append((false, "A click about \(String(format: "%.2f", seconds)) s into the step: an edge \(String(format: "%.0f", worst.ratio))× sharper than the sound either side of it.",
                                 "A sudden step in the waveform. If this step changes a parameter, glide to the new value over 5-30 ms; a delay time needs a crossfade."))
            }
        }

        // Zipper noise, on sweeps: steps at the start of each render block.
        if case .sweep = step.action, SoundAnalysis.rms(samples) > 1e-4 {
            let ratio = SoundAnalysis.zipper(samples, blockSize: Int(options.blockSize))
            m["zipperRatio"] = (ratio * 100).rounded() / 100
            if ratio > 1.5 {
                problems.append((false, "Zipper noise: the waveform is \(String(format: "%.1f", ratio))× sharper at the start of each render block than elsewhere, so the parameter moves in steps.",
                                 "The new value is applied all at once at each block. Smooth it per sample (a one-pole smoother over about 10 ms), or ramp across the block from the previous value."))
            }
        }

        // Sudden cuts, and how long a release takes to fade.
        let envelope = SoundAnalysis.envelope(samples, sampleRate: rate)
        if let cut = SoundAnalysis.abruptStop(envelope) {
            let seconds = Double(cut) / 100
            problems.append((false, "The sound cuts out \(String(format: "%.2f", seconds)) s into the step: down 40 dB or more within 10 ms.",
                             "A fade would take longer. A voice ending without its release, a gate, a buffer reset or a dropout. If it's a release, check the envelope reaches zero smoothly."))
        }
        if case .release = step.action {
            if let decay = SoundAnalysis.decayTime(envelope) {
                m["decaySeconds"] = decay
            }
        }
        if case .play = step.action, let onset = SoundAnalysis.onset(envelope) {
            m["onsetSeconds"] = onset
        }

        // Pitch, for a single note.
        var heard = ""
        if case .play(let notes, _) = step.action, notes.count == 1, samples.count > Int(0.4 * rate) {
            if let frequency = SoundAnalysis.steadyPitch(samples, sampleRate: rate) {
                let (cents, octaves) = SoundAnalysis.tuning(of: frequency, note: Int(notes[0]))
                m["pitchHz"] = (frequency * 10).rounded() / 10
                m["centsOff"] = (cents * 10).rounded() / 10
                m["octavesOff"] = Double(octaves)
                heard = " Pitch \(String(format: "%.1f", frequency)) Hz: \(String(format: "%+.0f", cents)) cents from \(Scenario.noteName(Int(notes[0])))\(octaves == 0 ? "" : ", \(octaves > 0 ? "+" : "")\(octaves) octave\(abs(octaves) == 1 ? "" : "s")")."
                if step.expect.contains(.inTune), abs(cents) > 10 {
                    problems.append((false, "Out of tune: \(String(format: "%+.0f", cents)) cents from \(Scenario.noteName(Int(notes[0]))).",
                                     "Check the note-to-frequency conversion (A4 = 440 Hz, MIDI note 69) and any detune or fine-tune default."))
                }
            } else if step.expect.contains(.inTune) {
                problems.append((false, "No steady pitch to check the tuning of.", "The sound is too noisy, detuned, modulated or complex for a single pitch, or the note started too late in the step; try a plain patch or a longer step."))
            }
        }

        for expectation in step.expect {
            switch expectation {
            case .sound where peak < 0.00316:
                // By peak: an echo or a sparse arpeggio is sound too, though its average is low.
                problems.append((true, "Expected sound, but it never rose above -50 dBFS.", "Whatever this step plays or turns up isn't reaching the output. For an effect, check its wet mix and that its input is connected."))
            case .silence:
                // By the end of the step: a release's tail is allowed to fade first.
                let end = SoundAnalysis.peak(samples.suffix(Int(0.5 * rate)))
                if end > 1e-4 {
                    problems.append((true, "Expected silence by the end of the step, but its last half second peaked at \(String(format: "%.0f", SoundAnalysis.decibels(end))) dBFS.",
                                     "Something keeps sounding: a note that didn't release, a tail longer than the step, or noise from the plugin itself."))
                }
            default: break
            }
        }

        let level = peak < 1e-5 ? "Silent." : "Level \(String(format: "%.0f", SoundAnalysis.decibels(rms))) dBFS RMS, peak \(String(format: "%.0f", SoundAnalysis.decibels(peak))) dBFS."
        let decay = m["decaySeconds"].map { " Faded 60 dB in \(String(format: "%.2f", $0)) s." } ?? ""
        let onset = m["onsetSeconds"].flatMap { $0 >= 0.05 ? " Sound began \(String(format: "%.2f", $0)) s after the note-on." : nil } ?? ""
        let status: CheckResult.Status = problems.contains { $0.failed } ? .failed : problems.isEmpty ? .passed : .warning
        let detail = ([level + onset + heard + decay] + problems.map(\.text)).joined(separator: " ")
        return CheckResult(id: "step-\(number)", title: "Step \(number): \(step.title)", status: status, detail: detail,
                           hint: problems.isEmpty ? nil : problems.map(\.hint).joined(separator: " "), measurements: m)
    }
}

extension Scenario {
    /// A sweep's value part way through, `t` from 0 to 1: even steps of the parameter's
    /// units, but even steps of pitch for frequencies, as a filter knob turns.
    static func sweepValue(_ p: AUParameter, from: AUValue, to: AUValue, t: Double) -> AUValue {
        if p.unit == .hertz, from > 0, to > 0 {
            return AUValue(Double(from) * pow(Double(to) / Double(from), t))
        }
        return from + (to - from) * AUValue(t)
    }
}
