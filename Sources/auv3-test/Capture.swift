import AVFoundation

/// Saves what the plugin rendered in each phase as a WAV file, so a person (or an
/// agent with an audio tool) can listen to exactly what the checks measured.
final class AudioCapture: @unchecked Sendable {
    let directory: URL
    let format: AVAudioFormat
    private var samples: [[Float]] = []
    private var phase: String?
    private var count = 0
    private(set) var written: [URL] = []
    private(set) var errors: [String] = []

    init(directory: URL, format: AVAudioFormat) throws {
        self.directory = directory
        self.format = format
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Starts collecting a phase, with room for `seconds` of audio reserved up front
    /// so appending on the render thread doesn't allocate.
    func begin(_ name: String, seconds: Double) {
        phase = name
        let frames = Int(seconds * format.sampleRate) + 8_192
        samples = (0..<Int(format.channelCount)).map { _ in
            var channel: [Float] = []
            channel.reserveCapacity(frames)
            return channel
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard phase != nil, let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        for channel in samples.indices where channel < Int(buffer.format.channelCount) {
            samples[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: frames))
        }
    }

    /// Writes the phase to `NN-name.wav`.
    func finish() {
        guard let phase else { return }
        self.phase = nil
        count += 1
        let url = directory.appendingPathComponent(String(format: "%02d-%@.wav", count, phase))
        let frames = samples.first?.count ?? 0
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        for (channel, values) in samples.enumerated() {
            values.withUnsafeBufferPointer { destination[channel].update(from: $0.baseAddress!, count: frames) }
        }
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
            written.append(url)
        } catch {
            errors.append("\(url.lastPathComponent): \(error)")
        }
        samples = []
    }
}
