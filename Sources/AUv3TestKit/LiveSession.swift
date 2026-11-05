import AVFoundation
import AudioToolbox
import CoreMIDI

/// A person plays the plugin: through the speakers, with its own keys and knobs or a
/// MIDI keyboard, for as long as they like (up to --seconds). Everything is recorded,
/// and afterwards each problem is put on a timeline with what was being played or
/// moved at the time: "0:12.31 click, while Cutoff moved".
///
/// The plugin renders on the output's own audio thread, as in a host: an
/// AVAudioSourceNode pulls blocks from it through a small FIFO, so what's heard is
/// exactly what's measured.
final class LiveSession: @unchecked Sendable {
    let host: PluginHost
    let options: Options
    private let log: (String) -> Void

    init(host: PluginHost, options: Options, log: @escaping (String) -> Void) {
        self.host = host
        self.options = options
        self.log = log
    }

    /// Something that happened, at a time in seconds from the start.
    struct Event { var time: Double; var text: String }

    // Written on the MIDI and parameter-observer threads, read afterwards.
    private let lock = NSLock()
    private var notes: [Event] = []
    private var moves: [(time: Double, address: AUParameterAddress, value: AUValue)] = []
    private var framesRendered = 0  // audio thread; read loosely for timestamps

    private var now: Double { Double(framesRendered) / options.sampleRate }

    /// Plays until Return (Mac, from a terminal), the window closing (Mac), or
    /// --seconds; then measures. Returns the checks and notes for the report's settings.
    func run(spectrogram: URL?) -> (checks: [CheckResult], settings: [String: String]) {
        var settings: [String: String] = [:]
        let rate = options.sampleRate
        let maxFrames = Int(options.seconds * rate) + 8_192
        let recorder = SampleRecorder(frames: maxFrames)
        let blockSize = Int(options.blockSize)
        let maxBlocks = maxFrames / blockSize + 1
        var durations = [Double](repeating: 0, count: maxBlocks)
        var statuses = [OSStatus](repeating: noErr, count: maxBlocks)
        var blocks = 0
        let stopped = StopSignal()

        host.recorder = recorder
        host.capture?.begin("live", seconds: options.seconds)

        // The FIFO between the plugin's fixed blocks and whatever the output asks for.
        let capacity = blockSize * 8
        var fifoL = [Float](repeating: 0, count: capacity), fifoR = fifoL
        var fifoCount = 0
        let host = self.host
        let source = AVAudioSourceNode(format: host.format) { [unowned self] _, _, frameCount, bufferList in
            let out = UnsafeMutableAudioBufferListPointer(bufferList)
            let frames = Int(frameCount)
            while fifoCount < frames, blocks < maxBlocks, !stopped.isSet {
                let result = host.renderBlock()
                durations[blocks] = result.duration
                statuses[blocks] = result.status
                blocks += 1
                self.framesRendered += blockSize
                let rendered = host.renderedOutput
                guard let data = rendered.floatChannelData, fifoCount + blockSize <= capacity else { break }
                let right = rendered.format.channelCount > 1 ? 1 : 0
                for i in 0..<blockSize {
                    fifoL[fifoCount + i] = result.status == noErr ? data[0][i] : 0
                    fifoR[fifoCount + i] = result.status == noErr ? data[right][i] : 0
                }
                fifoCount += blockSize
            }
            let available = min(frames, fifoCount)
            for (channel, buffer) in out.enumerated() {
                guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let fifo = channel == 0 ? fifoL : fifoR
                for i in 0..<frames { samples[i] = i < available ? fifo[i] : 0 }
            }
            // Shift what's left to the front (a few blocks at most).
            let rest = fifoCount - available
            if rest > 0 {
                for i in 0..<rest { fifoL[i] = fifoL[available + i]; fifoR[i] = fifoR[available + i] }
            }
            fifoCount = rest
            return noErr
        }

        let engine = AVAudioEngine()
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: host.format)
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        // Parameter moves from the plugin's own controls (it reports them to the host).
        let token = host.audioUnit.parameterTree?.token(byAddingParameterObserver: { [weak self] address, value in
            guard let self else { return }
            self.lock.withLock { self.moves.append((self.now, address, value)) }
        })
        let midi = MIDIInput { [weak self] bytes in
            guard let self else { return }
            host.sendMIDI(bytes)
            if bytes.count >= 3, bytes[0] & 0xF0 == 0x90, bytes[2] > 0 {
                self.lock.withLock { self.notes.append(Event(time: self.now, text: Scenario.noteName(Int(bytes[1])))) }
            }
        }
        settings["midiInputs"] = midi.sourceNames.isEmpty ? "none connected (play the plugin's own keys)" : midi.sourceNames.joined(separator: ", ")

        do {
            try engine.start()
        } catch {
            host.recorder = nil
            host.capture?.finish()
            return ([CheckResult(id: "live", title: "Plays live", status: .failed,
                                 detail: "The audio output wouldn't start: \(error.localizedDescription).",
                                 hint: "Check the Mac's or device's sound output is available.")], settings)
        }

        print("▶︎ Playing \(host.component.name) live, for up to \(Int(options.seconds)) s. Play its keys or a MIDI keyboard, and move its controls.")
        #if os(macOS)
        print("  Press Return here, or close its window, when you're done.")
        if isatty(0) != 0 {
            Thread { _ = readLine(); stopped.set() }.start()
        }
        #endif
        fflush(stdout)
        let started = Date()
        while !stopped.isSet && Date().timeIntervalSince(started) < options.seconds {
            Thread.sleep(forTimeInterval: 0.1)
            #if os(macOS)
            let open = DispatchQueue.main.sync { host.window?.isVisible ?? true }
            if !open { stopped.set() }
            #endif
        }
        stopped.set()
        engine.stop()
        if let token { host.audioUnit.parameterTree?.removeParameterObserver(token) }
        midi.close()
        host.recorder = nil
        host.capture?.finish()

        let (checks, markers) = analyse(recorder: recorder, durations: Array(durations.prefix(blocks)),
                                        statuses: Array(statuses.prefix(blocks)))
        settings["livePlayed"] = String(format: "%.1f s", Double(blocks * blockSize) / rate)
        if let spectrogram {
            let (mono, _) = recorder.mono()
            if let problem = Spectrogram.write(mono, sampleRate: rate, steps: markers, to: spectrogram) {
                settings["spectrogram"] = "not saved: \(problem)"
            } else {
                settings["spectrogram"] = "saved to \(spectrogram.path) (numbered lines mark the timeline's problems)"
            }
        }
        return (checks, settings)
    }

    // MARK: Afterwards

    private func analyse(recorder: SampleRecorder, durations: [Double], statuses: [OSStatus]) -> ([CheckResult], [Int]) {
        let rate = options.sampleRate
        let (mono, nonFinite) = recorder.mono()
        let (notes, moves) = lock.withLock { (self.notes, self.moves) }
        let parameters = host.audioUnit.parameterTree?.allParameters ?? []
        func name(_ address: AUParameterAddress) -> String {
            parameters.first { $0.address == address }?.displayName ?? "parameter \(address)"
        }
        /// What was going on around `time`: controls moved, notes played within 150 ms.
        func context(_ time: Double) -> String {
            let moved = Set(moves.filter { abs($0.time - time) < 0.15 }.map { name($0.address) }).sorted()
            let played = notes.filter { abs($0.time - time) < 0.15 }.map(\.text)
            var parts: [String] = []
            if !moved.isEmpty { parts.append("while \(moved.joined(separator: ", ")) moved") }
            if !played.isEmpty { parts.append("as \(played.joined(separator: " ")) played") }
            return parts.isEmpty ? "" : ", " + parts.joined(separator: " and ")
        }
        func stamp(_ time: Double) -> String {
            String(format: "%d:%05.2f", Int(time) / 60, time.truncatingRemainder(dividingBy: 60))
        }

        var timeline: [Event] = []
        // Clicks: windows standing out from the sound on both sides (see SoundAnalysis).
        let window = SoundAnalysis.clickWindow
        for (index, ratio) in SoundAnalysis.clickRatios(SoundAnalysis.windowMaxima(mono)).enumerated() where ratio > 4 {
            let time = Double(index * window) / rate
            // A note's own attack isn't a click.
            guard !notes.contains(where: { $0.time <= time && time - $0.time < 0.05 }) else { continue }
            timeline.append(Event(time: time, text: "click (\(Int(ratio))× sharper than around it)\(context(time))"))
        }
        // Cut-outs: 40 dB gone within 10 ms, while clearly audible.
        let envelope = SoundAnalysis.envelope(mono[...], sampleRate: rate)
        var i = 1
        while i < envelope.count {
            if envelope[i - 1] > -40 && envelope[i] < envelope[i - 1] - 40 {
                let time = Double(i) / 100
                timeline.append(Event(time: time, text: "cut out (down \(Int(envelope[i - 1] - envelope[i])) dB in 10 ms)\(context(time))"))
                i += 20
            }
            i += 1
        }
        // Late and failed renders.
        let blockSeconds = host.blockDuration
        for (index, duration) in durations.enumerated() where index >= 8 && duration > 0.1 {
            let time = Double(index) * blockSeconds
            timeline.append(Event(time: time, text: "dropout: a render call took \(Int(duration * 1000)) ms\(context(time))"))
        }
        if let first = statuses.firstIndex(where: { $0 != noErr }) {
            timeline.append(Event(time: Double(first) * blockSeconds, text: "render failed (\(TestRun.errorName(statuses[first])))"))
        }
        if let first = nonFinite.first {
            timeline.append(Event(time: Double(first) / rate, text: "NaN or infinite samples\(context(Double(first) / rate))"))
        }
        let clipped = mono.enumerated().filter { abs($0.element) >= 1 }.map(\.offset)
        if let first = clipped.first {
            timeline.append(Event(time: Double(first) / rate, text: "clipping (\(clipped.count) samples at or over 0 dBFS in all)\(context(Double(first) / rate))"))
        }
        timeline.sort { $0.time < $1.time }

        let late = durations.dropFirst(8).filter { $0 > blockSeconds }.count
        let length = Double(mono.count) / rate
        let movedNames = Set(moves.map { name($0.address) }).sorted()
        var checks: [CheckResult] = []
        let shown = timeline.prefix(30).enumerated().map { "\($0.offset + 1). \(stamp($0.element.time)) \($0.element.text)" }
        let summary = "\(String(format: "%.1f", length)) s played, \(notes.count) notes, \(moves.count) control moves" +
            (movedNames.isEmpty ? "." : " (\(movedNames.prefix(12).joined(separator: ", "))\(movedNames.count > 12 ? "…" : "")).")
        checks.append(CheckResult(
            id: "live", title: "Plays live without a problem",
            status: timeline.isEmpty ? .passed : (timeline.contains { $0.text.hasPrefix("NaN") || $0.text.hasPrefix("render failed") || $0.text.hasPrefix("dropout") } ? .failed : .warning),
            detail: summary + (timeline.isEmpty ? " Nothing went wrong." : "\n    " + shown.joined(separator: "\n    ") + (timeline.count > 30 ? "\n    … and \(timeline.count - 30) more." : "")),
            hint: timeline.isEmpty ? nil : "Each line is when it happened and what was being moved or played then. Replay that moment with --save-audio, or turn it into a scenario (README) to test it every time. Clicks while a control moves: glide its value over 5-30 ms. Dropouts: the render thread waited on something.",
            measurements: ["seconds": length, "notes": Double(notes.count), "moves": Double(moves.count),
                           "problems": Double(timeline.count), "lateBlocks": Double(late),
                           "worstRenderMs": ((durations.dropFirst(8).max() ?? 0) * 10_000).rounded() / 10]))
        let markers = timeline.prefix(30).map { Int($0.time * rate) }
        return (checks, markers)
    }
}

/// Set once, from any thread: the session is over.
final class StopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Every MIDI source, connected; each MIDI 1.0 channel message is handed over as bytes.
final class MIDIInput: @unchecked Sendable {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private(set) var sourceNames: [String] = []

    init(_ receive: @escaping @Sendable ([UInt8]) -> Void) {
        guard MIDIClientCreateWithBlock("auv3-test" as CFString, &client, nil) == noErr else { return }
        let status = MIDIInputPortCreateWithProtocol(client, "auv3-test in" as CFString, ._1_0, &port) { list, _ in
            for packet in list.unsafeSequence() {
                let words = MIDIEventPacket.WordCollection(packet)
                for word in words {
                    // A MIDI 1.0 channel voice message in a universal packet: type 2.
                    guard word >> 28 == 0x2 else { continue }
                    receive([UInt8((word >> 16) & 0xFF), UInt8((word >> 8) & 0x7F), UInt8(word & 0x7F)])
                }
            }
        }
        guard status == noErr else { return }
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            guard MIDIPortConnectSource(port, source, nil) == noErr else { continue }
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name) == noErr, let name {
                sourceNames.append(name.takeRetainedValue() as String)
            }
        }
    }

    func close() {
        if port != 0 { MIDIPortDispose(port) }
        if client != 0 { MIDIClientDispose(client) }
    }
}
