import Foundation

/// The outcome of one check.
struct CheckResult: Codable {
    enum Status: String, Codable {
        case passed, warning, failed
    }

    /// Stable, short identifier, e.g. "render-thread-automation".
    var id: String
    /// What was checked, in plain words.
    var title: String
    var status: Status
    /// What happened, with the numbers that matter.
    var detail: String
    /// For a failure or warning: the usual cause and fix.
    var hint: String?
    /// Measurements, for scripts: e.g. ["worstRenderMs": 2104.5].
    var measurements: [String: Double] = [:]
}

struct PluginInfo: Codable {
    var name: String
    var manufacturer: String
    var codes: String
    var version: String
    var isAUv3: Bool
    var hasCustomView: Bool
    var parameterCount: Int
}

struct Report: Codable {
    var tool = "auv3-test"
    var toolVersion = auv3TestVersion
    var plugin: PluginInfo?
    var settings: [String: String] = [:]
    var checks: [CheckResult] = []
    /// Set when the plugin couldn't be found or loaded at all.
    var setupError: String?

    var exitCode: Int32 {
        if setupError != nil { return 2 }
        return checks.contains { $0.status == .failed } ? 1 : 0
    }

    func printText() {
        print("auv3-test \(toolVersion)")
        if let plugin {
            print("Plugin:  \(plugin.name) by \(plugin.manufacturer)  [\(plugin.codes)]  version \(plugin.version)")
            print("         \(plugin.isAUv3 ? "AUv3" : "AUv2"), \(plugin.parameterCount) parameters, \(plugin.hasCustomView ? "has its own window" : "no custom window")")
        }
        if !settings.isEmpty {
            print("Settings: " + settings.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        print("")
        if let setupError {
            print("✗ Couldn't test the plugin: \(setupError)")
            return
        }
        for check in checks {
            let mark = switch check.status { case .passed: "✓"; case .warning: "!"; case .failed: "✗" }
            print("\(mark) \(check.title)")
            print("    \(check.detail)")
            if let hint = check.hint, check.status != .passed { print("    → \(hint)") }
        }
        let failed = checks.filter { $0.status == .failed }.count
        let warnings = checks.filter { $0.status == .warning }.count
        print("")
        print(failed == 0 ? "PASSED  (\(checks.count) checks, \(warnings) warnings)"
                          : "FAILED  (\(failed) of \(checks.count) checks failed, \(warnings) warnings)")
    }

    func printJSON() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }
}

let auv3TestVersion = "0.1.0"
