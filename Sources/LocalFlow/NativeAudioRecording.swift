import AVFoundation

struct NativeAudioRecording {
    let samples: [Float]
    let sampleRate: Double
    let isComplete: Bool
}

/// Keeps one mono recording at the microphone's sample rate. AudioRecorder
/// owns synchronization; this type performs no disk access or resampling.
final class NativeAudioAccumulator {
    private let maximumDuration: Double
    private let maximumSamples: Int
    private var format: AVAudioFormat?
    private var samples: [Float] = []
    private var complete = true

    init(maximumDuration: Double = 310, maximumSamples: Int = 64 * 1_024 * 1_024 / MemoryLayout<Float>.size) {
        self.maximumDuration = maximumDuration
        self.maximumSamples = maximumSamples
    }

    var recording: NativeAudioRecording {
        NativeAudioRecording(samples: samples, sampleRate: format?.sampleRate ?? 0,
                             isComplete: complete && !samples.isEmpty)
    }

    func markIncomplete() {
        complete = false
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard complete else { return }
        let incoming = buffer.format
        guard incoming.sampleRate.isFinite, incoming.sampleRate > 0,
              incoming.channelCount > 0 else {
            markIncomplete()
            return
        }
        if let format, !format.isEqual(incoming) {
            markIncomplete()
            return
        }
        format = incoming
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let bytesPerSample: Int
        switch incoming.commonFormat {
        case .pcmFormatFloat32, .pcmFormatInt32: bytesPerSample = 4
        case .pcmFormatFloat64: bytesPerSample = 8
        case .pcmFormatInt16: bytesPerSample = 2
        default:
            markIncomplete()
            return
        }
        let channels = Int(incoming.channelCount)
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let interleaved = incoming.isInterleaved
        let channelsPerBuffer = interleaved ? channels : 1
        guard buffers.count == (interleaved ? 1 : channels),
              buffers.allSatisfy({
                  $0.mData != nil && Int($0.mNumberChannels) == channelsPerBuffer &&
                      Int($0.mDataByteSize) / bytesPerSample / channelsPerBuffer >= frameCount
              }) else {
            markIncomplete()
            return
        }
        // Clamp as a Double before converting to Int, even for an invalid
        // device rate. The byte cap also bounds high-rate microphones.
        let durationLimit = max(0, min(Double(maximumSamples), incoming.sampleRate * maximumDuration))
        let sampleLimit = Int(durationLimit)
        let acceptedFrames = min(frameCount, max(0, sampleLimit - samples.count))
        for frame in 0..<acceptedFrames {
            var sum = 0.0
            for channel in 0..<channels {
                let data = buffers[interleaved ? 0 : channel].mData!
                let index = interleaved ? frame * channels + channel : frame
                let value: Double
                switch incoming.commonFormat {
                case .pcmFormatFloat32: value = Double(data.assumingMemoryBound(to: Float.self)[index])
                case .pcmFormatFloat64: value = data.assumingMemoryBound(to: Double.self)[index]
                case .pcmFormatInt16: value = Double(data.assumingMemoryBound(to: Int16.self)[index]) / 32_768
                case .pcmFormatInt32: value = Double(data.assumingMemoryBound(to: Int32.self)[index]) / 2_147_483_648
                default: return
                }
                guard value.isFinite else {
                    markIncomplete()
                    return
                }
                sum += value
            }
            let mono = Float(sum / Double(channels))
            guard mono.isFinite else {
                markIncomplete()
                return
            }
            samples.append(mono)
        }
        if acceptedFrames < frameCount || samples.count >= sampleLimit {
            markIncomplete()
        }
    }
}
