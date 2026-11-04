import Foundation
import AVFoundation

/// The whole tool, for any front end: the Mac command line (Sources/auv3-test), or the
/// iOS runner app that runs it in the Simulator or on an iPhone or iPad
/// (iOSRunner/AUv3TestRunner.swiftpm, driven by `auv3-test-ios`).
public enum AUv3Test {
    /// What a command line asks for.
    public enum Request {
        /// Help, an argument error or the list of plugins: print this and exit with `code`.
        case finished(String, code: Int32)
        /// Test a plugin.
        case run(Run)
    }

    public static func request(for arguments: [String]) -> Request {
        switch Options.parse(arguments) {
        case .help:
            return .finished(Options.usage, code: 0)
        case .error(let message):
            return .finished("auv3-test: \(message)\n\nRun `auv3-test --help` for usage.", code: 2)
        case .list(let json):
            return .finished(listing(json: json), code: 0)
        case .run(let options):
            return .run(Run(options: options))
        }
    }

    /// The installed Audio Units, one per line or as JSON.
    static func listing(json: Bool) -> String {
        let components = installedComponents()
        if json {
            struct Entry: Codable { var codes: String; var name: String; var manufacturer: String; var version: String; var type: String }
            let entries = components.map { Entry(codes: describe($0.audioComponentDescription), name: $0.name,
                                                 manufacturer: $0.manufacturerName, version: $0.versionString, type: $0.typeName) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(entries)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        return components.map {
            "\(describe($0.audioComponentDescription))  \($0.manufacturerName): \($0.name)  (\($0.typeName), \($0.versionString))"
        }.joined(separator: "\n")
    }

    /// A test run, ready to go.
    public struct Run {
        let options: Options

        /// Whether the plugin has a view of its own: the component says so on the Mac,
        /// the loaded plugin on iOS.
        static func hasOwnView(_ host: PluginHost) -> Bool {
            #if os(macOS)
            host.component.hasCustomView
            #else
            host.audioUnit.providesUserInterface
            #endif
        }

        /// Whether the report should be printed as JSON.
        public var wantsJSON: Bool { options.json }

        /// Loads the plugin and runs every check. Call it off the main thread, and keep
        /// the main thread's run loop going meanwhile: plugins' views and their
        /// main-thread work need it, as in a real host.
        public func perform() -> Report {
            var report = Report()
            report.settings = [
                "sampleRate": "\(Int(options.sampleRate)) Hz",
                "blockSize": "\(options.blockSize) frames",
                "secondsPerPhase": "\(options.seconds)",
                "realTime": options.realTime ? "yes" : "no (--fast)",
                "window": options.showUI ? "opened" : "not opened (--no-ui)",
                "audio": options.saveAudio.map { "saved to \($0.path)" } ?? "not saved",
            ]
            let options = self.options
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
                    hasCustomView: Self.hasOwnView(host),
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
            return report
        }
    }
}
