// auv3-test: a command-line Audio Unit host for testing AUv3 plugins. The main thread
// runs AppKit (plugins' windows and their main-thread work need it, as in a real host);
// the test itself runs on a background thread and ends the process when it's done.
// The checks live in AUv3TestKit, which also runs on iPhone and iPad (see auv3-test-ios).
#if os(macOS)
import AppKit
import AUv3TestKit

switch AUv3Test.request(for: Array(CommandLine.arguments.dropFirst())) {
case .finished(let output, let code):
    if code == 0 {
        print(output)
    } else {
        FileHandle.standardError.write(Data((output + "\n").utf8))
    }
    exit(code)
case .run(let run):
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let runner = Thread {
        let report = run.perform()
        DispatchQueue.main.async {
            print(run.wantsJSON ? report.json : report.text)
            fflush(stdout)
            exit(report.exitCode)
        }
    }
    runner.start()
    app.run()
}
#endif
