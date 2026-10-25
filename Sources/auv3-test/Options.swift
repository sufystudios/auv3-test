import Foundation
import AudioToolbox

/// What to test and how, from the command line.
struct Options {
    var component = AudioComponentDescription()
    var sampleRate: Double = 48_000
    var blockSize: AUAudioFrameCount = 512
    /// Seconds of audio for each phase that renders.
    var seconds: Double = 4
    /// Open the plugin's own window while testing, as a host does. Many render-thread
    /// bugs only show with the UI alive (it's what the render thread ends up waiting on).
    var showUI = true
    /// Render in real time, as a host does, rather than as fast as possible.
    var realTime = true
    var json = false
    var verbose = false

    static let usage = """
    auv3-test: tests an Audio Unit v3 plugin the way a host does.

    USAGE
      auv3-test <type> <subtype> <manufacturer> [options]
      auv3-test --list

      The three codes are the plugin's four-character component codes, e.g.
      auv3-test aumu Dron Sufy        (an instrument)
      auv3-test aufx dely appl        (an effect)

    OPTIONS
      --list               List the Audio Units macOS can see, with their codes.
      --json               Print the report as JSON (for scripts and coding agents).
      --seconds <n>        Audio per phase, in seconds (default 4).
      --sample-rate <hz>   Default 48000.
      --block-size <n>     Frames per render call (default 512).
      --no-ui              Don't open the plugin's window (for headless machines).
      --fast               Render as fast as possible instead of in real time.
      --verbose            Print progress while testing.
      --help

    EXIT CODES
      0  every check passed (there may be warnings)
      1  at least one check failed
      2  the plugin couldn't be found or loaded, or the options were wrong
    """

    enum ParseResult {
        case run(Options)
        case list(json: Bool)
        case help
        case error(String)
    }

    static func parse(_ arguments: [String]) -> ParseResult {
        var options = Options()
        var codes: [String] = []
        var list = false
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            func value() -> String? { iterator.next() }
            switch argument {
            case "--help", "-h": return .help
            case "--list": list = true
            case "--json": options.json = true
            case "--no-ui": options.showUI = false
            case "--fast": options.realTime = false
            case "--verbose", "-v": options.verbose = true
            case "--seconds":
                guard let v = value().flatMap(Double.init), v > 0 else { return .error("--seconds needs a positive number") }
                options.seconds = v
            case "--sample-rate":
                guard let v = value().flatMap(Double.init), v >= 8_000 else { return .error("--sample-rate needs a rate in Hz") }
                options.sampleRate = v
            case "--block-size":
                guard let v = value().flatMap(UInt32.init), (16...8_192).contains(v) else { return .error("--block-size needs 16...8192") }
                options.blockSize = v
            default:
                if argument.hasPrefix("--") { return .error("unknown option \(argument)") }
                codes.append(argument)
            }
        }
        if list { return .list(json: options.json) }
        guard codes.count == 3 else { return .error("give the plugin's type, subtype and manufacturer codes, e.g. aumu Dron Sufy") }
        guard let type = fourCC(codes[0]), let subtype = fourCC(codes[1]), let manufacturer = fourCC(codes[2]) else {
            return .error("each code must be exactly four characters, e.g. aumu Dron Sufy")
        }
        options.component = AudioComponentDescription(componentType: type, componentSubType: subtype,
                                                      componentManufacturer: manufacturer,
                                                      componentFlags: 0, componentFlagsMask: 0)
        return .run(options)
    }
}

/// "aumu" -> its OSType. Exactly four ASCII characters; spaces count ("dls ").
func fourCC(_ string: String) -> OSType? {
    let bytes = Array(string.utf8)
    guard bytes.count == 4, bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return nil }
    return bytes.reduce(0) { ($0 << 8) | OSType($1) }
}

/// An OSType back to its four characters.
func fourCCString(_ code: OSType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    return String(decoding: bytes, as: UTF8.self)
}

func describe(_ description: AudioComponentDescription) -> String {
    "\(fourCCString(description.componentType)) \(fourCCString(description.componentSubType)) \(fourCCString(description.componentManufacturer))"
}
