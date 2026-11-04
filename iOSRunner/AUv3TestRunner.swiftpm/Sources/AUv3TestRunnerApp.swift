import SwiftUI
import AVFoundation
import AUv3TestKit

/// auv3-test on an iPhone or iPad: tests an AUv3 installed on the device, the way
/// GarageBand or AUM loads it, and shows the report. `auv3-test-ios` installs this and
/// launches it with the plugin's codes and options as arguments (the same ones the Mac
/// command line takes); the report is printed too, for the script, and the app quits
/// when it's done. Opened by hand, with no arguments, it lists the plugins installed.
@main
struct AUv3TestRunnerApp: App {
    @State private var output = "Starting…"

    var body: some Scene {
        WindowGroup {
            ScrollView {
                Text(output)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .task {
                await waitForPluginsToRegister()
                start()
            }
        }
    }

    /// iOS finds the Audio Units in installed apps in the background, after the first
    /// ask, and says when it has (as GarageBand and AUM wait for). Asked straight away,
    /// only Apple's own are there. Waits for that, or a few seconds at most.
    private func waitForPluginsToRegister() async {
        _ = AVAudioUnitComponentManager.shared().components(matching: AudioComponentDescription())
        let changes = NotificationCenter.default.notifications(named: AVAudioUnitComponentManager.registrationsChangedNotification)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in changes { break } }
            group.addTask { try? await Task.sleep(for: .seconds(5)) }
            await group.next()
            group.cancelAll()
        }
        // A moment more, in case several apps' plugins arrive one after another.
        try? await Task.sleep(for: .seconds(1))
    }

    static let reportStart = "=== auv3-test report ==="
    static let reportEnd = "=== end of report ==="

    private func start() {
        // Only what auv3-test-ios passed: leave out anything Xcode adds when it runs the app.
        let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst()).filter { !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
        let scripted = !arguments.isEmpty
        // Plugins render here as in a music app, so the session plays (silently: the
        // audio goes to the checks, not the speaker).
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)

        switch AUv3Test.request(for: scripted ? arguments : ["--list"]) {
        case .finished(let text, let code):
            finish(scripted ? text : "Installed Audio Units:\n\n" + text, code: code, quit: scripted)
        case .run(let run):
            output = "Testing… (this takes a minute or so)"
            // Off the main thread: the plugin's view and main-thread work need it free.
            Thread {
                let report = run.perform()
                DispatchQueue.main.async {
                    finish(run.wantsJSON ? report.json : report.text, code: report.exitCode, quit: true)
                }
            }.start()
        }
    }

    private func finish(_ text: String, code: Int32, quit: Bool) {
        output = text
        print(Self.reportStart)
        print(text)
        print(Self.reportEnd)
        print("auv3-test exit code: \(code)")
        fflush(stdout)
        // Left open when opened by hand, to read; quits for the script, which waits for it.
        if quit {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(code) }
        }
    }
}
