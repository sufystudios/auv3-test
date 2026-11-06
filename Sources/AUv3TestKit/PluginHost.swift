import AVFoundation
import AudioToolbox
import CoreAudioKit  // requestViewController
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum HostError: Error, CustomStringConvertible {
    case notFound(String)
    case loadFailed(String)
    case timedOut(String)
    case renderSetup(String)

    var description: String {
        switch self {
        case .notFound(let s), .loadFailed(let s), .timedOut(let s), .renderSetup(let s): s
        }
    }
}

/// Every Audio Unit this device can see, as a host's plugin list would show them.
func installedComponents() -> [AVAudioUnitComponent] {
    AVAudioUnitComponentManager.shared().components(matching: AudioComponentDescription())
        .sorted { ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name) }
}

/// Loads and drives one Audio Unit the way a host does: out of process (as Logic and
/// GarageBand load AUv3s), rendering on a dedicated high-priority thread, with a host
/// tempo and transport, MIDI and parameter events scheduled from that thread.
final class PluginHost: @unchecked Sendable {
    let options: Options
    let component: AVAudioUnitComponent
    let audioUnit: AUAudioUnit
    private(set) var format: AVAudioFormat
    /// The rate the plugin renders at now: the options' rate, unless reconfigure(sampleRate:) changed it.
    private(set) var sampleRate: Double
    let isInstrument: Bool
    let isEffect: Bool
    /// An app-extension AUv3, loaded in its own process; otherwise an AUv2 in ours.
    let isAUv3: Bool

    /// In --play, the host's own keyboard under the plugin; its keys go to `onKeyboardNote`.
    private(set) var keyboard: KeyboardView?
    var onKeyboardNote: ((_ note: UInt8, _ down: Bool) -> Void)?
    static let keyboardHeight: CGFloat = 130

    #if os(macOS)
    private(set) var window: NSWindow?
    /// The plugin's view controller, kept while it's shown inside a container.
    private var hostedController: NSViewController?
    #else
    /// The plugin's view controller, kept while the tests run, as a host showing it would.
    private var viewController: UIViewController?
    #endif
    private var output: AVAudioPCMBuffer
    private var input: AVAudioPCMBuffer
    private var sampleTime: Double = 0
    private var inputPhase: Double = 0

    // The host's musical context: a steady 120 BPM, playing.
    let tempo: Double = 120

    init(options: Options) throws {
        self.options = options
        guard let component = AVAudioUnitComponentManager.shared().components(matching: options.component).first else {
            throw HostError.notFound("This device has no Audio Unit with the codes \(describe(options.component)). Run `auv3-test --list` to see what's installed. For an AUv3, open its app once so the system registers it.")
        }
        self.component = component
        let type = options.component.componentType
        isInstrument = type == kAudioUnitType_MusicDevice || type == kAudioUnitType_Generator
        isEffect = type == kAudioUnitType_Effect || type == kAudioUnitType_MusicEffect
        isAUv3 = component.audioComponentDescription.componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue != 0

        // Out of process, as hosts load AUv3s; an AUv2 loads in process regardless.
        var loaded: AUAudioUnit?
        var loadError: Error?
        let done = DispatchSemaphore(value: 0)
        AUAudioUnit.instantiate(with: component.audioComponentDescription, options: [.loadOutOfProcess]) { unit, error in
            loaded = unit
            loadError = error
            done.signal()
        }
        guard done.wait(timeout: .now() + 20) == .success else {
            throw HostError.timedOut("the plugin didn't finish loading within 20 seconds")
        }
        guard let loaded else {
            throw HostError.loadFailed("the plugin failed to load: \(loadError.map { String(describing: $0) } ?? "no error given")")
        }
        audioUnit = loaded

        guard let format = AVAudioFormat(standardFormatWithSampleRate: options.sampleRate, channels: 2),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: options.blockSize),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: options.blockSize) else {
            throw HostError.renderSetup("couldn't make a \(options.sampleRate) Hz stereo format")
        }
        self.format = format
        self.sampleRate = options.sampleRate
        self.output = output
        self.input = input
    }

    // MARK: Setting up, as a host does before playback

    /// Changes the rate the plugin renders at, as a host does when its project's rate
    /// changes: render resources released, every bus given the new format, resources
    /// allocated again.
    func reconfigure(sampleRate rate: Double) throws {
        audioUnit.deallocateRenderResources()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: options.blockSize),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: options.blockSize) else {
            throw HostError.renderSetup("couldn't make a \(rate) Hz stereo format")
        }
        self.format = format
        self.output = output
        self.input = input
        sampleRate = rate
        edgeMeters = []
        try prepare()
    }

    func prepare() throws {
        let unit = audioUnit
        do {
            if unit.outputBusses.count > 0 {
                try unit.outputBusses[0].setFormat(format)
                unit.outputBusses[0].isEnabled = true
            }
            if isEffect, unit.inputBusses.count > 0 {
                try unit.inputBusses[0].setFormat(format)
                // Connected, as a host's channel strip connects it; bridged AUv2
                // effects otherwise render nothing (kAudioUnitErr_NoConnection).
                unit.inputBusses[0].isEnabled = true
            }
        } catch {
            throw HostError.renderSetup("the plugin refused a \(Int(sampleRate)) Hz stereo format: \(error)")
        }
        unit.maximumFramesToRender = max(options.blockSize, 1024)

        // Tempo and transport, which plugins read from their render thread. Hosts set
        // these before allocating render resources; some plugins only look them up then.
        let tempo = self.tempo
        let sampleRate = self.sampleRate
        unit.musicalContextBlock = { [weak self] currentTempo, numerator, denominator, beatPosition, sampleOffsetToNextBeat, downbeat in
            let beat = (self?.sampleTime ?? 0) / sampleRate * tempo / 60
            currentTempo?.pointee = tempo
            numerator?.pointee = 4
            denominator?.pointee = 4
            beatPosition?.pointee = beat
            sampleOffsetToNextBeat?.pointee = Int((beat.rounded(.up) - beat) * 60 / tempo * sampleRate)
            downbeat?.pointee = (beat / 4).rounded(.down) * 4
            return true
        }
        unit.transportStateBlock = { [weak self] flags, samplePosition, cycleStart, cycleEnd in
            flags?.pointee = [.changed, .moving]
            samplePosition?.pointee = self?.sampleTime ?? 0
            cycleStart?.pointee = 0
            cycleEnd?.pointee = 0
            return true
        }

        do {
            try unit.allocateRenderResources()
        } catch {
            throw HostError.renderSetup("allocateRenderResources failed: \(error)")
        }
    }

    // MARK: The plugin's window

    #if os(macOS)
    /// Opens the plugin's own view in a window, as a host does when you open it.
    /// Returns a note if it has none or it couldn't be shown.
    func openWindow() -> String? {
        var note: String?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            self.audioUnit.requestViewController { controller in
                DispatchQueue.main.async {
                    defer { done.signal() }
                    guard let controller else {
                        note = "the plugin offered no view"
                        return
                    }
                    var size = self.options.windowSize ?? controller.preferredContentSize
                    if size.width < 50 || size.height < 50 { size = NSSize(width: 800, height: 500) }
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                    // Swift owns the window; AppKit's old default would release it again on close.
                    window.isReleasedWhenClosed = false
                    window.title = "\(self.component.name) - auv3-test"
                    if self.options.live {
                        // The plugin above, the host's keyboard below.
                        let keys = Self.keyboardHeight
                        let container = NSView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height + keys))
                        controller.view.frame = NSRect(x: 0, y: keys, width: size.width, height: size.height)
                        controller.view.autoresizingMask = [.width, .height]
                        container.addSubview(controller.view)
                        let keyboard = self.makeKeyboard(frame: NSRect(x: 0, y: 0, width: size.width, height: keys))
                        keyboard.autoresizingMask = [.width, .maxYMargin]
                        container.addSubview(keyboard)
                        self.hostedController = controller
                        window.contentView = container
                        window.setContentSize(container.frame.size)
                    } else {
                        window.contentViewController = controller
                        window.setContentSize(size)
                    }
                    window.center()
                    window.orderFrontRegardless()
                    self.window = window
                }
            }
        }
        if done.wait(timeout: .now() + 15) == .timedOut { return "the plugin's view didn't arrive within 15 seconds" }
        return note
    }

    /// Saves the plugin's window as a PNG at the screen's resolution. An AUv3's view is
    /// drawn by the plugin's own process, in a layer of its own over our window, so the
    /// image is of that part of the screen, taken from the window server: our window
    /// alone comes out empty. (Capturing other processes' drawing may need the Screen
    /// Recording permission for the terminal running auv3-test.) Returns a note if it
    /// couldn't be saved.
    func snapshot(to url: URL) -> String? {
        var note: String?
        // What's on screen is what's captured, so lift the window above every other
        // app's first, and give the window server a moment to composite it.
        DispatchQueue.main.sync {
            self.window?.level = .floating
            self.window?.orderFrontRegardless()
        }
        Thread.sleep(forTimeInterval: 1)
        DispatchQueue.main.sync {
            guard let window = self.window, let screen = window.screen ?? NSScreen.screens.first else {
                note = "no window was open to snapshot"
                return
            }
            window.displayIfNeeded()
            // The window's frame in the window server's coordinates, which run down
            // from the top of the main screen rather than up from the bottom.
            let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            let frame = window.frame
            let area = CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
            guard let image = CGWindowListCreateImage(area, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else {
                note = "the window server returned no image of the window"
                return
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                note = "couldn't encode the snapshot as PNG"
                return
            }
            do {
                try png.write(to: url)
            } catch {
                note = "couldn't write the snapshot: \(error.localizedDescription)"
            }
        }
        return note
    }

    func closeWindow() {
        DispatchQueue.main.sync {
            self.keyboard?.releaseAll()
            self.window?.close()
            self.window = nil
            self.hostedController = nil
        }
    }
    #else
    /// Asks for the plugin's view, as GarageBand does when you open a plugin, and shows it
    /// full screen over the runner for the rest of the run, as a host would. Returns a
    /// note if it has none or it couldn't be shown.
    func openWindow() -> String? {
        var note: String?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            self.audioUnit.requestViewController { controller in
                DispatchQueue.main.async {
                    defer { done.signal() }
                    guard let controller else {
                        note = "the plugin offered no view"
                        return
                    }
                    controller.loadViewIfNeeded()
                    self.viewController = controller
                    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    guard let root = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
                        ?? scenes.first?.windows.first?.rootViewController else {
                        return  // No app window (unit tests): the loaded view is what counts.
                    }
                    let container = UIViewController()
                    container.view.backgroundColor = .black
                    container.modalPresentationStyle = .fullScreen
                    container.addChild(controller)
                    let bounds = container.view.bounds
                    let keys = self.options.live ? Self.keyboardHeight : 0
                    controller.view.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - keys)
                    controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    container.view.addSubview(controller.view)
                    if self.options.live {
                        // The host's keyboard below the plugin, clear of the home indicator.
                        let keyboard = self.makeKeyboard(frame: CGRect(x: 0, y: bounds.height - keys, width: bounds.width, height: keys - 20))
                        keyboard.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
                        container.view.addSubview(keyboard)
                    }
                    controller.didMove(toParent: container)
                    root.present(container, animated: false)
                }
            }
        }
        if done.wait(timeout: .now() + 15) == .timedOut { return "the plugin's view didn't arrive within 15 seconds" }
        return note
    }

    /// Marks the moment for `auv3-test-ios` to take the screenshot: the plugin's view is
    /// drawn by its own process, so only a capture of the screen shows it. The script
    /// watches for this line, captures the device's screen from the Mac and saves it;
    /// the view stays up meanwhile. `url` is the Mac's path, so it isn't used here.
    static let snapshotReadyMarker = "=== auv3-test snapshot ready ==="

    func snapshot(to url: URL) -> String? {
        guard viewController != nil else { return "no view was open to snapshot" }
        Thread.sleep(forTimeInterval: 1)  // Let the plugin finish drawing.
        print(Self.snapshotReadyMarker)
        fflush(stdout)
        Thread.sleep(forTimeInterval: 6)  // Time for the Mac to capture the screen.
        return nil
    }

    func closeWindow() {
        DispatchQueue.main.sync {
            self.keyboard?.releaseAll()
            self.viewController?.parent?.dismiss(animated: false)
            self.viewController = nil
        }
    }
    #endif

    /// The host's keyboard, playing the plugin by MIDI (main thread, as a host's UI does).
    private func makeKeyboard(frame: CGRect) -> KeyboardView {
        let keyboard = KeyboardView(frame: frame)
        keyboard.onNote = { [weak self] note, down in
            guard let self else { return }
            self.sendMIDI(down ? [0x90, note, 100] : [0x80, note, 0])
            self.onKeyboardNote?(note, down)
        }
        self.keyboard = keyboard
        return keyboard
    }

    // MARK: Rendering

    struct BlockResult {
        var status: OSStatus
        /// How long the render call took, in seconds.
        var duration: Double
        /// Peak absolute sample, and whether any sample was NaN or infinite.
        var peak: Float
        var nonFinite: Bool
        /// The block's sharpest edge: the largest second difference between samples,
        /// carried across blocks. Steady for a steady sound; a click spikes it.
        var edge: Float
    }

    /// One per channel, so edges are measured across block boundaries.
    private var edgeMeters: [EdgeMeter] = []

    /// Where rendered audio goes as well, when the run is saving it.
    var capture: AudioCapture?
    /// Where a scenario keeps every sample, to measure afterwards.
    var recorder: SampleRecorder?

    var blockDuration: Double { Double(options.blockSize) / sampleRate }

    /// The block `renderBlock` just made, until the next call: a live session plays it.
    var renderedOutput: AVAudioPCMBuffer { output }

    /// Renders one block, as the host's audio thread does each cycle. `beforeRender`
    /// runs first on the same thread: where a host schedules MIDI and automation.
    func renderBlock(_ beforeRender: (_ sampleTime: Double) -> Void = { _ in }) -> BlockResult {
        let frames = options.blockSize
        beforeRender(sampleTime)

        output.frameLength = frames
        let outputList = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        for buffer in outputList {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = sampleTime
        timestamp.mHostTime = mach_absolute_time()
        timestamp.mFlags = [.sampleTimeValid, .hostTimeValid]

        let pull: AURenderPullInputBlock? = isEffect ? { [unowned self] _, _, frameCount, _, inputData in
            self.fillInput(inputData, frames: frameCount)
            return noErr
        } : nil

        let started = DispatchTime.now().uptimeNanoseconds
        let status = audioUnit.renderBlock(&flags, &timestamp, frames, 0, output.mutableAudioBufferList, pull)
        let duration = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9

        var peak: Float = 0
        var nonFinite = false
        var edge: Float = 0
        let rendered = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        if edgeMeters.count != rendered.count { edgeMeters = Array(repeating: EdgeMeter(), count: rendered.count) }
        for (channel, buffer) in rendered.enumerated() {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<count {
                let x = data[i]
                if !x.isFinite {
                    nonFinite = true
                    continue
                }
                peak = max(peak, abs(x))
                edge = max(edge, edgeMeters[channel].measure(x))
            }
        }
        if status == noErr {
            capture?.append(output)
            recorder?.append(output)
        } else if let recorder {
            // Keep the timeline whole: a failed block is silence.
            for buffer in rendered { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            output.frameLength = frames
            recorder.append(output)
        }
        sampleTime += Double(frames)
        return BlockResult(status: status, duration: duration, peak: peak, nonFinite: nonFinite, edge: edge)
    }

    /// What an effect is fed.
    enum InputSignal {
        /// A quiet 220 Hz tone with a little noise (the default).
        case tone
        /// Silence, but for a single sample at 0.5 at the start of the next block that
        /// pulls input (see `impulsePending`): for latency and tails.
        case impulse
    }
    var inputSignal: InputSignal = .tone
    /// With `.impulse`: the next block's input starts with the impulse.
    var impulsePending = false
    /// Where an effect's input goes as well, when a check compares output with it.
    var inputRecorder: SampleRecorder?

    /// An effect's input, as `inputSignal` says.
    private func fillInput(_ list: UnsafeMutablePointer<AudioBufferList>, frames: AUAudioFrameCount) {
        input.frameLength = frames
        let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let increment = 2 * Double.pi * 220 / sampleRate
        if let left = source[0].mData?.assumingMemoryBound(to: Float.self) {
            switch inputSignal {
            case .tone:
                for i in 0..<Int(frames) {
                    left[i] = Float(0.25 * sin(inputPhase + Double(i) * increment)) + Float.random(in: -0.01...0.01)
                }
            case .impulse:
                for i in 0..<Int(frames) { left[i] = 0 }
                if impulsePending {
                    left[0] = 0.5
                    impulsePending = false
                }
            }
        }
        inputPhase += Double(frames) * increment
        if source.count > 1, let left = source[0].mData, let right = source[1].mData {
            memcpy(right, left, Int(frames) * MemoryLayout<Float>.size)
        }
        inputRecorder?.append(input)
        // Point the plugin's input buffers at ours where it left them empty.
        let destination = UnsafeMutableAudioBufferListPointer(list)
        for (i, buffer) in destination.enumerated() where i < source.count {
            if buffer.mData == nil {
                destination[i].mData = source[i].mData
            } else {
                memcpy(buffer.mData, source[i].mData, Int(frames) * MemoryLayout<Float>.size)
            }
            destination[i].mDataByteSize = frames * UInt32(MemoryLayout<Float>.size)
        }
    }

    // MARK: Events, from the render thread

    func sendMIDI(_ bytes: [UInt8], atFrame offset: Int = 0) {
        guard let schedule = audioUnit.scheduleMIDIEventBlock else { return }
        bytes.withUnsafeBufferPointer { pointer in
            schedule(AUEventSampleTimeImmediate + AUEventSampleTime(offset), 0, bytes.count, pointer.baseAddress!)
        }
    }

    func noteOn(_ note: UInt8, velocity: UInt8 = 100) { sendMIDI([0x90, note, velocity]) }
    func noteOff(_ note: UInt8) { sendMIDI([0x80, note, 0]) }

    /// Automation as a host plays it back: a parameter event scheduled from the render thread.
    func automate(_ address: AUParameterAddress, to value: AUValue, atFrame offset: Int = 0) {
        audioUnit.scheduleParameterBlock(AUEventSampleTimeImmediate + AUEventSampleTime(offset), 0, address, value)
    }

    func stop() {
        audioUnit.deallocateRenderResources()
    }
}
