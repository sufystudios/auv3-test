import AppKit
import AVFoundation

// auv3-test: a command-line Audio Unit host for testing AUv3 plugins. The main thread
// runs AppKit (plugins' windows and their main-thread work need it, as in a real host);
// the test itself runs on a background thread and ends the process when it's done.

let parsed = Options.parse(Array(CommandLine.arguments.dropFirst()))

switch parsed {
case .help:
    print(Options.usage)
    exit(0)
case .error(let message):
    FileHandle.standardError.write(Data("auv3-test: \(message)\n\nRun `auv3-test --help` for usage.\n".utf8))
    exit(2)
case .list(let json):
    let components = installedComponents()
    if json {
        struct Entry: Codable { var codes: String; var name: String; var manufacturer: String; var version: String; var type: String }
        let entries = components.map { Entry(codes: describe($0.audioComponentDescription), name: $0.name,
                                             manufacturer: $0.manufacturerName, version: $0.versionString, type: $0.typeName) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(data: try! encoder.encode(entries), encoding: .utf8)!)
    } else {
        for component in components {
            print("\(describe(component.audioComponentDescription))  \(component.manufacturerName): \(component.name)  (\(component.typeName), \(component.versionString))")
        }
    }
    exit(0)
case .run(let options):
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let runner = Thread {
        var report = Report()
        report.settings = [
            "sampleRate": "\(Int(options.sampleRate)) Hz",
            "blockSize": "\(options.blockSize) frames",
            "secondsPerPhase": "\(options.seconds)",
            "realTime": options.realTime ? "yes" : "no (--fast)",
            "window": options.showUI ? "opened" : "not opened (--no-ui)",
            "audio": options.saveAudio.map { "saved to \($0.path)" } ?? "not saved",
        ]
        let log: (String) -> Void = { message in
            if options.verbose { FileHandle.standardError.write(Data("… \(message)\n".utf8)) }
        }
        do {
            log("Loading \(describe(options.component))")
            let host = try PluginHost(options: options)
            let flags = host.component.audioComponentDescription.componentFlags
            report.plugin = PluginInfo(
                name: host.component.name, manufacturer: host.component.manufacturerName,
                codes: describe(host.component.audioComponentDescription), version: host.component.versionString,
                isAUv3: flags & AudioComponentFlags.isV3AudioUnit.rawValue != 0,
                hasCustomView: host.component.hasCustomView,
                parameterCount: host.audioUnit.parameterTree?.allParameters.count ?? 0)
            try host.prepare()
            if let directory = options.saveAudio {
                host.capture = try AudioCapture(directory: directory, format: host.format)
            }
            let run = TestRun(host: host, options: options, log: log)
            run.capturePrepared()
            run.runAll()
            report.checks = run.checks
            if let capture = host.capture {
                report.audioFiles = capture.written.map(\.path)
                if !capture.errors.isEmpty { report.settings["audioErrors"] = capture.errors.joined(separator: "; ") }
            }
            if let snapshot = options.snapshot {
                if let problem = options.showUI ? host.snapshot(to: snapshot) : "--snapshot needs the window (not --no-ui)" {
                    report.settings["snapshot"] = "not saved: \(problem)"
                } else {
                    report.settings["snapshot"] = "saved to \(snapshot.path)"
                }
            }
            if options.showUI { host.closeWindow() }
            host.stop()
        } catch {
            report.setupError = String(describing: error)
        }
        DispatchQueue.main.async {
            if options.json { report.printJSON() } else { report.printText() }
            fflush(stdout)
            exit(report.exitCode)
        }
    }
    runner.start()
    app.run()
}
