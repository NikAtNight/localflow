import AVFoundation

enum RetainedAudioFile {
    static func write(samples: [Float], sampleRate: Double, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writePCM(samples: samples, sampleRate: sampleRate, to: temporary)
        // Publish only after AVAudioFile closes and finalizes the header.
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    private static func writePCM(samples: [Float], sampleRate: Double, to url: URL) throws {
        guard sampleRate.isFinite, sampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }
}
