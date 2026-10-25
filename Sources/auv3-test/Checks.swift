import AVFoundation
import AudioToolbox

/// The test run: each phase renders on a dedicated high-priority thread in real time
/// (unless --fast), as a host's audio thread would, and turns what it saw into checks.
final class TestRun: @unchecked Sendable {
    let host: PluginHost
    let options: Options
    private(set) var checks: [CheckResult] = []
    private let log: (String) -> Void

    /// A plain render error, a non-finite sample, a silent instrument: anything the
    /// phases notice, kept so later checks can compare (did sound come back?).
    private var playedSoundAtStart = false

    init(host: PluginHost, options: Options, log: @escaping (String) -> Void) {
        self.host = host
        self.options = options
        self.log = log
    }

    private var parameters: [AUParameter] {
        host.audioUnit.parameterTree?.allParameters ?? []
    }

    private var writableParameters: [AUParameter] {
        parameters.filter { $0.flags.contains(.flag_IsWritable) && $0.maxValue > $0.minValue }
    }

    func runAll() {
        checkParameters()
        if options.showUI { checkWindow() }
        checkPlaysSound()
        checkRenderThreadAutomation()
        checkSoundAfterAutomation()
        checkHostThreadAutomation()
        checkClicks()
        checkParameterReadBack()
        checkStateRestore()
    }

    // MARK: Rendering phases

    struct PhaseStats {
        var blocks = 0
        var renderErrors = 0
        var firstError: OSStatus = noErr
        var nonFiniteBlocks = 0
        var peak: Float = 0
        var late = 0              // render calls longer than the block they made
        var stalls = 0            // render calls over 100 ms: an audible dropout anywhere
        var worstSeconds: Double = 0
        var silentWindows = 0     // half-second windows with nothing audible
        var windows = 0
        var edges: [Float] = []   // each block's sharpest edge (see BlockResult.edge)
    }

    /// Renders `seconds` of audio, in real time unless --fast. `perBlock` runs on the
    /// render thread before each block, with the block's index.
    /// With a `name`, the phase's audio is saved when the run is saving audio.
    private func render(seconds: Double, name: String? = nil, perBlock: @escaping (Int) -> Void = { _ in }) -> PhaseStats {
        var stats = PhaseStats()
        if let name { host.capture?.begin(name, seconds: seconds) }
        defer { if name != nil { host.capture?.finish() } }
        let host = self.host
        let realTime = options.realTime
        let blockCount = Int((seconds / host.blockDuration).rounded(.up))
        let windowBlocks = max(1, Int(0.5 / host.blockDuration))
        stats.edges.reserveCapacity(blockCount)
        let done = DispatchSemaphore(value: 0)

        let thread = Thread {
            var windowPeak: Float = 0
            let start = DispatchTime.now().uptimeNanoseconds
            for index in 0..<blockCount {
                let result = host.renderBlock { _ in perBlock(index) }
                stats.blocks += 1
                if result.status != noErr {
                    stats.renderErrors += 1
                    if stats.firstError == noErr { stats.firstError = result.status }
                }
                if result.nonFinite { stats.nonFiniteBlocks += 1 }
                stats.peak = max(stats.peak, result.peak)
                stats.edges.append(result.edge)
                windowPeak = max(windowPeak, result.peak)
                // The first few calls of a phase may warm caches; hosts tolerate that too.
                if index >= 8 {
                    stats.worstSeconds = max(stats.worstSeconds, result.duration)
                    if result.duration > host.blockDuration { stats.late += 1 }
                    if result.duration > 0.1 { stats.stalls += 1 }
                }
                if (index + 1) % windowBlocks == 0 {
                    stats.windows += 1
                    if windowPeak < 1e-4 { stats.silentWindows += 1 }
                    windowPeak = 0
                }
                if realTime {
                    let deadline = start + UInt64(Double(index + 1) * host.blockDuration * 1e9)
                    let now = DispatchTime.now().uptimeNanoseconds
                    if deadline > now { usleep(useconds_t((deadline - now) / 1_000)) }
                }
            }
            done.signal()
        }
        thread.qualityOfService = .userInteractive
        thread.name = "auv3-test render"
        thread.start()
        done.wait()
        return stats
    }

    /// Notes for an instrument: a held C minor chord.
    private static let chord: [UInt8] = [48, 51, 55]

    private func startNotes() {
        guard host.isInstrument else { return }
        _ = render(seconds: 0.05) { [host] index in
            if index == 0 { for note in Self.chord { host.noteOn(note) } }
        }
    }

    private func stopNotes() {
        guard host.isInstrument else { return }
        _ = render(seconds: 0.05) { [host] index in
            if index == 0 { for note in Self.chord { host.noteOff(note) } }
        }
    }

    private func timingCheck(id: String, title: String, stats: PhaseStats, extraDetail: String = "") -> CheckResult {
        let worstMs = stats.worstSeconds * 1000
        let blockMs = host.blockDuration * 1000
        let lateShare = stats.blocks > 0 ? Double(stats.late) / Double(stats.blocks) : 0
        var status: CheckResult.Status = .passed
        var problems: [String] = []
        if stats.renderErrors > 0 { status = .failed; problems.append("\(stats.renderErrors) render calls returned \(Self.errorName(stats.firstError))") }
        if stats.nonFiniteBlocks > 0 { status = .failed; problems.append("\(stats.nonFiniteBlocks) blocks contained NaN or infinite samples") }
        // A stall, regular lateness, or a call taking twice its block fails: each is
        // an audible dropout in a host. The odd call a little over its block is a
        // warning - a host's own buffering usually absorbs it.
        if stats.stalls > 0 { status = .failed; problems.append("\(stats.stalls) render calls took over 100 ms (worst \(String(format: "%.0f", worstMs)) ms): audible dropouts") }
        else if lateShare > 0.02 || worstMs > 2 * blockMs {
            status = .failed
            problems.append("\(stats.late) of \(stats.blocks) render calls took longer than the \(String(format: "%.1f", blockMs)) ms of audio they made (worst \(String(format: "%.1f", worstMs)) ms)")
        } else if stats.late > 0 {
            if status == .passed { status = .warning }
            problems.append("\(stats.late) of \(stats.blocks) render calls ran a little late (worst \(String(format: "%.1f", worstMs)) ms of a \(String(format: "%.1f", blockMs)) ms block)")
        }
        let detail = (problems.isEmpty
            ? "\(stats.blocks) blocks rendered on time; worst render call \(String(format: "%.1f", worstMs)) ms of a \(String(format: "%.1f", blockMs)) ms block."
            : problems.joined(separator: "; ") + ".") + extraDetail
        return CheckResult(
            id: id, title: title, status: status, detail: detail,
            hint: stats.renderErrors > 0
                ? "The render block returned an error (\(Self.errorName(stats.firstError))). A host treats that as no audio for the block; return noErr and output silence instead if there's nothing to play."
                : stats.nonFiniteBlocks > 0
                ? "A filter or feedback path is blowing up, often from a parameter jumping to an extreme; clamp values and reset filter state when they go non-finite."
                : "The render thread must never wait: don't touch UI, @Published/ObservableObject properties, locks the main thread holds, or allocate there. Hand host values to the main thread instead, and apply them to DSP with atomics or a lock-free queue.",
            measurements: ["blocks": Double(stats.blocks), "lateBlocks": Double(stats.late), "stalls": Double(stats.stalls),
                           "worstRenderMs": worstMs, "blockMs": blockMs, "peak": Double(stats.peak),
                           "renderErrors": Double(stats.renderErrors), "nonFiniteBlocks": Double(stats.nonFiniteBlocks)])
    }

    // MARK: Checks

    private func checkParameters() {
        let all = parameters
        var problems: [String] = []
        let addresses = Dictionary(grouping: all, by: \.address).filter { $0.value.count > 1 }
        if !addresses.isEmpty { problems.append("\(addresses.count) addresses are used by more than one parameter") }
        let identifiers = Dictionary(grouping: all, by: \.identifier).filter { $0.value.count > 1 }
        if !identifiers.isEmpty { problems.append("duplicate identifiers: \(identifiers.keys.sorted().prefix(5).joined(separator: ", "))") }
        let badRanges = all.filter { !$0.minValue.isFinite || !$0.maxValue.isFinite || $0.minValue > $0.maxValue }
        if !badRanges.isEmpty { problems.append("bad ranges on \(badRanges.prefix(5).map(\.identifier).joined(separator: ", "))") }
        let outOfRange = all.filter { $0.value < $0.minValue - 1e-4 || $0.value > $0.maxValue + 1e-4 }
        if !outOfRange.isEmpty { problems.append("starts outside its range: \(outOfRange.prefix(5).map { "\($0.identifier) = \($0.value)" }.joined(separator: ", "))") }

        let status: CheckResult.Status = problems.isEmpty ? (all.isEmpty ? .warning : .passed) : .failed
        checks.append(CheckResult(
            id: "parameters", title: "Parameters are well formed", status: status,
            detail: problems.isEmpty
                ? (all.isEmpty ? "The plugin has no parameters, so hosts can't automate it." : "\(all.count) parameters (\(writableParameters.count) writable), unique addresses and identifiers, sane ranges.")
                : problems.joined(separator: "; ") + ".",
            hint: all.isEmpty ? "Expose an AUParameterTree so hosts can show and automate your controls."
                              : "Addresses are what hosts save automation against: give every parameter its own, permanent one.",
            measurements: ["parameters": Double(all.count), "writable": Double(writableParameters.count)]))
    }

    private func checkWindow() {
        log("Opening the plugin's window")
        let note = host.openWindow()
        checks.append(CheckResult(
            id: "window", title: "Opens its window", status: note == nil ? .passed : .warning,
            detail: note.map { "It didn't: \($0)." } ?? "The plugin's view opened in a window, and stayed open through the tests that follow.",
            hint: "Hosts call requestViewController; an AUv3 with a UI should return its view controller promptly."))
    }

    private func checkPlaysSound() {
        log("Playing \(host.isInstrument ? "a chord" : "a test tone through it") for \(options.seconds) s")
        startNotes()
        let stats = render(seconds: options.seconds, name: "plays")
        playedSoundAtStart = stats.peak >= 1e-4
        var check = timingCheck(id: "plays", title: host.isInstrument ? "Plays a held chord" : "Processes a test tone", stats: stats)
        if !playedSoundAtStart && check.status != .failed {
            check.status = host.isInstrument ? .failed : .warning
            check.detail = "Silent for \(options.seconds) s: the output never rose above -80 dBFS. " + check.detail
            check.hint = host.isInstrument
                ? "It didn't respond to MIDI note-ons (C3, D#3, G3 at velocity 100) sent through scheduleMIDIEventBlock, or its default sound is silent."
                : "It output silence for a 220 Hz tone at -12 dBFS. Fine for a gate or a silent default; otherwise check it pulls its input."
        } else if stats.peak > 4 {
            check.status = check.status == .failed ? .failed : .warning
            check.detail += " Very loud: peaks reached \(String(format: "%.1f", 20 * log10(Double(stats.peak)))) dBFS."
            check.hint = "Peaks this far over 0 dBFS will clip in most hosts; check gain staging."
        }
        checks.append(check)
    }

    /// Sweeps every writable parameter through its range, from the render thread, as a
    /// host plays automation back - the path where a plugin touching its UI from the
    /// audio thread stalls it.
    private func checkRenderThreadAutomation() {
        let targets = writableParameters
        guard !targets.isEmpty else { return }
        log("Automating \(targets.count) parameters from the render thread for \(options.seconds) s")
        let blocksPerSecond = 1 / host.blockDuration
        let host = self.host
        let stats = render(seconds: options.seconds, name: "render-thread-automation") { index in
            let t = Double(index) / blocksPerSecond
            for (i, parameter) in targets.enumerated() {
                host.automate(parameter.address, to: Self.sweep(parameter, t: t, lane: i))
            }
        }
        checks.append(timingCheck(
            id: "render-thread-automation", title: "Keeps time while the host automates every parameter (render thread)",
            stats: stats, extraDetail: " Swept \(targets.count) parameters every block."))
    }

    /// After the sweeps, back at its starting values: does it still play?
    private func checkSoundAfterAutomation() {
        guard host.isInstrument, playedSoundAtStart else { return }
        log("Checking it still plays after automation")
        restoreStartingValues()
        stopNotes()
        startNotes()
        let stats = render(seconds: min(options.seconds, 2), name: "sound-after-automation")
        let sounded = stats.peak >= 1e-4
        checks.append(CheckResult(
            id: "sound-after-automation", title: "Still plays after automation",
            status: sounded ? .passed : .failed,
            detail: sounded ? "With its parameters back where they started, a new chord sounds again."
                            : "Silent: it played before the automation sweeps, but not after, even with every parameter back at its starting value.",
            hint: "Automation left it stuck: a render thread blocked or a voice/filter left in a bad state. Look for work done on the render thread when a parameter changes.",
            measurements: ["peak": Double(stats.peak)]))
        stopNotes()
    }

    /// Hosts also set parameters from their own threads (their UI, MIDI learn).
    private func checkHostThreadAutomation() {
        let targets = writableParameters
        guard !targets.isEmpty else { return }
        log("Setting parameters from a host thread for \(min(options.seconds, 2)) s")
        startNotes()
        let keepGoing = Flag()
        // An AUv3 takes sets from any thread, as hosts make them. An AUv2 lives in our
        // process, and AUv2 hosts set from the main thread: Apple's own AUv2 views crash
        // if parameters change under them from another one.
        let fromMainThread = !host.isAUv3
        let worker = Thread {
            var t = 0.0
            while keepGoing.isSet {
                let time = t
                let setAll = { for (i, parameter) in targets.enumerated() { parameter.setValue(Self.sweep(parameter, t: time, lane: i), originator: nil) } }
                if fromMainThread { DispatchQueue.main.sync(execute: setAll) } else { setAll() }
                t += 0.02
                usleep(20_000)
            }
        }
        worker.start()
        let stats = render(seconds: min(options.seconds, 2), name: "host-thread-automation")
        keepGoing.clear()
        checks.append(timingCheck(
            id: "host-thread-automation", title: "Keeps time while the host sets parameters from another thread",
            stats: stats, extraDetail: " Set \(targets.count) parameters 50 times a second from \(fromMainThread ? "the main thread (AUv2)" : "a background thread")."))
        restoreStartingValues()
        stopNotes()
    }

    /// Stepped automation - a host jumping a parameter from one value to another, as
    /// Logic does between automation points or when you click a control - shouldn't
    /// click. Each smoothly variable parameter in turn jumps between a quarter and three
    /// quarters of its range while a chord holds; the blocks just after each jump are
    /// compared with the steady sound at both values. A plugin that glides to a new
    /// value shows no spike; one that applies it in a single sample pops.
    private func checkClicks() {
        guard host.isInstrument || host.isEffect, playedSoundAtStart || host.isEffect else { return }
        let targets = writableParameters.filter { $0.unit != .indexed && $0.unit != .boolean }
        guard !targets.isEmpty else { return }
        let hold = 0.12
        let holdBlocks = max(8, Int((hold / host.blockDuration).rounded()))
        // A jump may land a block or two late (plugins applying sets on their main
        // thread), and a glide or ring-out takes a few more: the transition is the
        // first third of a hold, the steady part the rest.
        let transitionBlocks = max(3, holdBlocks / 3)
        log("Jumping \(targets.count) parameters, one at a time, to listen for clicks (\(String(format: "%.0f", Double(targets.count) * 3 * hold)) s)")
        startNotes()
        let host = self.host
        var findings: [(name: String, ratio: Float)] = []
        if let capture = host.capture { capture.begin("clicks", seconds: Double(targets.count) * 3 * hold + 1) }
        for parameter in targets {
            let span = parameter.maxValue - parameter.minValue
            let low = parameter.minValue + span * 0.25
            let high = parameter.minValue + span * 0.75
            // Settle at the low value, jump up, then back down.
            let stats = render(seconds: Double(holdBlocks * 3) * host.blockDuration) { index in
                if index == 0 { host.automate(parameter.address, to: low) }
                if index == holdBlocks { host.automate(parameter.address, to: high) }
                if index == 2 * holdBlocks { host.automate(parameter.address, to: low) }
            }
            if let ratio = ClickDetection.clickRatio(edges: stats.edges, holdBlocks: holdBlocks, transitionBlocks: transitionBlocks) {
                findings.append((parameter.identifier, ratio))
            }
        }
        host.capture?.finish()
        restoreStartingValues()
        stopNotes()
        findings.sort { $0.ratio > $1.ratio }
        let list = findings.prefix(6).map { "\($0.name) (\(String(format: "%.0f", $0.ratio))× sharper)" }.joined(separator: ", ")
        checks.append(CheckResult(
            id: "clicks", title: "Changes parameters without clicks",
            status: findings.isEmpty ? .passed : .warning,
            detail: findings.isEmpty
                ? "Jumped \(targets.count) parameters between a quarter and three quarters of their range; none clicked."
                : "\(findings.count) of \(targets.count) clicked when jumped: \(list)\(findings.count > 6 ? "…" : ".")",
            hint: "Glide to a new value over a few milliseconds (a one-pole smoother or a short ramp, 5-30 ms) instead of applying it in one sample. Gains and mix levels are the usual culprits; a delay's time often needs a crossfade instead.",
            measurements: ["parametersTested": Double(targets.count), "clicking": Double(findings.count)]))
    }

    /// A host reads a parameter back straight after setting it (auval does too).
    private func checkParameterReadBack() {
        let targets = writableParameters
        guard !targets.isEmpty else { return }
        // An out-of-process plugin answers our earlier sets asynchronously; let those
        // answers arrive so they can't be mistaken for this check's.
        if host.isAUv3 {
            _ = render(seconds: 0.2)
            usleep(200_000)
        }
        let stepped = { (parameter: AUParameter) in parameter.unit == .indexed || parameter.unit == .boolean }
        func tolerance(_ parameter: AUParameter) -> AUValue {
            stepped(parameter) ? 0.5 : max(1e-3, (parameter.maxValue - parameter.minValue) * 1e-3)
        }
        var sets: [(AUParameter, AUValue)] = []
        var mismatches: [String] = []
        for (i, parameter) in targets.enumerated() {
            let value = Self.sweep(parameter, t: 0.37, lane: i)
            parameter.setValue(value, originator: nil)
            sets.append((parameter, value))
            if !host.isAUv3 {
                let readBack = parameter.value
                if abs(readBack - value) > tolerance(parameter) {
                    mismatches.append("\(parameter.identifier): set \(Self.format(value)), read \(Self.format(readBack))")
                }
            }
        }
        // An out-of-process AUv3's values reach the host's copy of its parameter tree
        // asynchronously, so give them a moment, as a host's UI would.
        if host.isAUv3 {
            usleep(300_000)
            for (parameter, value) in sets where abs(parameter.value - value) > tolerance(parameter) {
                mismatches.append("\(parameter.identifier): set \(Self.format(value)), read \(Self.format(parameter.value))")
            }
        }
        restoreStartingValues()
        checks.append(CheckResult(
            id: "parameter-readback", title: "Reads back what the host set",
            status: mismatches.isEmpty ? .passed : .warning,
            detail: mismatches.isEmpty ? "All \(targets.count) writable parameters read back the value just set."
                                       : "\(mismatches.count) didn't: " + mismatches.prefix(5).joined(separator: "; ") + (mismatches.count > 5 ? "…" : "."),
            hint: host.isAUv3
                ? "Even 300 ms after the host set these, its copy of the parameter tree hadn't caught up, so a host's own controls would show the old value. It's common for out-of-process AUv3s straight after render-thread automation, and the plugin itself may well have the value; check its fullState. If you apply sets later, return the pending value from implementorValueProvider until then."
                : "Hosts (and auval) read a parameter straight back after setting it. If you apply sets later, return the pending value until then.",
            measurements: ["mismatches": Double(mismatches.count)]))
    }

    /// Saves the plugin's state, scrambles its parameters, restores the state: as a
    /// host saves and reopens a project.
    private func checkStateRestore() {
        let targets = writableParameters
        let unit = host.audioUnit
        guard let saved = unit.fullState else {
            checks.append(CheckResult(id: "state", title: "Saves and restores its state", status: .warning,
                                      detail: "fullState is empty, so a host project can't save the plugin's settings.",
                                      hint: "Return your settings from fullState (and accept them back) so projects reopen as they were saved."))
            return
        }
        let before = Dictionary(uniqueKeysWithValues: targets.map { ($0.address, $0.value) })
        for (i, parameter) in targets.enumerated() {
            parameter.setValue(Self.sweep(parameter, t: 0.71, lane: i + 3), originator: nil)
        }
        unit.fullState = saved
        _ = render(seconds: 0.2)
        usleep(200_000)
        var mismatches: [String] = []
        for parameter in targets {
            guard let expected = before[parameter.address] else { continue }
            let tolerance = max(1e-3, (parameter.maxValue - parameter.minValue) * 1e-3)
            if abs(parameter.value - expected) > tolerance {
                mismatches.append("\(parameter.identifier): saved \(Self.format(expected)), restored \(Self.format(parameter.value))")
            }
        }
        checks.append(CheckResult(
            id: "state", title: "Saves and restores its state",
            status: mismatches.isEmpty ? .passed : .failed,
            detail: mismatches.isEmpty ? "After scrambling \(targets.count) parameters, restoring the saved state put every one back."
                                       : "\(mismatches.count) parameters didn't come back: " + mismatches.prefix(5).joined(separator: "; ") + (mismatches.count > 5 ? "…" : "."),
            hint: "Setting fullState must restore every parameter. Make sure all of them are saved in it, and the tree's values are updated when it's applied.",
            measurements: ["mismatches": Double(mismatches.count), "parametersChecked": Double(targets.count)]))
    }

    // MARK: Helpers

    private lazy var startingValues: [(AUParameter, AUValue)] = writableParameters.map { ($0, $0.value) }

    private func restoreStartingValues() {
        for (parameter, value) in startingValues { parameter.setValue(value, originator: nil) }
    }

    /// Where lane `lane` of the sweep is at time `t`: a slow sine through the whole
    /// range, offset per parameter so they don't all move together; steps for
    /// indexed and on/off parameters.
    static func sweep(_ parameter: AUParameter, t: Double, lane: Int) -> AUValue {
        let phase = sin(2 * Double.pi * (t * 0.5 + Double(lane) * 0.137))
        let value = parameter.minValue + (parameter.maxValue - parameter.minValue) * AUValue(0.5 + 0.5 * phase)
        return parameter.unit == .indexed || parameter.unit == .boolean ? value.rounded() : value
    }

    /// Audio Unit errors' names, for the ones a render block returns.
    static func errorName(_ status: OSStatus) -> String {
        let names: [OSStatus: String] = [
            kAudioUnitErr_NoConnection: "kAudioUnitErr_NoConnection: no input connected",
            kAudioUnitErr_TooManyFramesToProcess: "kAudioUnitErr_TooManyFramesToProcess: more frames than maximumFramesToRender",
            kAudioUnitErr_Uninitialized: "kAudioUnitErr_Uninitialized: render resources not allocated",
            kAudioUnitErr_FormatNotSupported: "kAudioUnitErr_FormatNotSupported",
            kAudioUnitErr_CannotDoInCurrentContext: "kAudioUnitErr_CannotDoInCurrentContext",
            kAudioUnitErr_RenderTimeout: "kAudioUnitErr_RenderTimeout: the out-of-process plugin didn't answer in time",
            kAudio_ParamError: "kAudio_ParamError",
        ]
        return names[status] ?? "OSStatus \(status)"
    }

    static func format(_ value: AUValue) -> String {
        abs(value) >= 100 ? String(format: "%.0f", value) : String(format: "%.3g", value)
    }

    func capturePrepared() { _ = startingValues }
}

/// A flag shared between threads.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var isSet: Bool { lock.withLock { value } }
    func clear() { lock.withLock { value = false } }
}
