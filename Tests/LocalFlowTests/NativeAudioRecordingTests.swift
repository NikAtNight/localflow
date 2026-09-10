import AVFoundation
import XCTest
@testable import LocalFlow

final class NativeAudioRecordingTests: XCTestCase {
    private func floatBuffer(_ channels: [[Float]], rate: Double = 48_000,
                             interleaved: Bool = false) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: AVAudioChannelCount(channels.count), interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count))!
        buffer.frameLength = buffer.frameCapacity
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for channel in channels.indices {
            let data = buffers[interleaved ? 0 : channel].mData!.assumingMemoryBound(to: Float.self)
            for frame in channels[channel].indices {
                data[interleaved ? frame * channels.count + channel : frame] = channels[channel][frame]
            }
        }
        return buffer
    }

    func testPreservesNativeRateAndEveryMonoSampleAcrossBuffers() {
        let accumulator = NativeAudioAccumulator()
        accumulator.append(floatBuffer([[0, 0.125, -0.5]]))
        accumulator.append(floatBuffer([[0.75, 0]]))
        XCTAssertEqual(accumulator.recording.sampleRate, 48_000)
        XCTAssertEqual(accumulator.recording.samples, [0, 0.125, -0.5, 0.75, 0])
        XCTAssertTrue(accumulator.recording.isComplete)
    }

    func testDownmixesPlanarAndInterleavedStereoIdentically() {
        for interleaved in [false, true] {
            let accumulator = NativeAudioAccumulator()
            accumulator.append(floatBuffer([[1, 0.5, -1], [-1, 0.25, -0.5]],
                                           interleaved: interleaved))
            XCTAssertEqual(accumulator.recording.samples, [0, 0.375, -0.75])
            XCTAssertTrue(accumulator.recording.isComplete)
        }
    }

    func testConvertsIntegerPCMWithoutChangingRateOrFrameCount() {
        for commonFormat in [AVAudioCommonFormat.pcmFormatInt16, .pcmFormatInt32] {
            let format = AVAudioFormat(commonFormat: commonFormat, sampleRate: 24_000,
                                       channels: 2, interleaved: true)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
            buffer.frameLength = 2
            let data = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)[0].mData!
            if commonFormat == .pcmFormatInt16 {
                let pointer = data.assumingMemoryBound(to: Int16.self)
                pointer[0] = .min
                pointer[1] = 0
                pointer[2] = 16_384
                pointer[3] = 16_384
            } else {
                let pointer = data.assumingMemoryBound(to: Int32.self)
                pointer[0] = .min
                pointer[1] = 0
                pointer[2] = 1_073_741_824
                pointer[3] = 1_073_741_824
            }
            let accumulator = NativeAudioAccumulator()
            accumulator.append(buffer)
            XCTAssertEqual(accumulator.recording.sampleRate, 24_000)
            XCTAssertEqual(accumulator.recording.samples, [-0.5, 0.5])
            XCTAssertTrue(accumulator.recording.isComplete)
        }
    }

    func testConvertsFloat64PCM() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat64, sampleRate: 44_100,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
        buffer.frameLength = 2
        let data = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)[0]
            .mData!.assumingMemoryBound(to: Double.self)
        data[0] = -0.5
        data[1] = 0.25
        let accumulator = NativeAudioAccumulator()
        accumulator.append(buffer)
        XCTAssertEqual(accumulator.recording.samples, [-0.5, 0.25])
        XCTAssertEqual(accumulator.recording.sampleRate, 44_100)
        XCTAssertTrue(accumulator.recording.isComplete)
    }

    func testRateChangeStopsAccumulationAndMarksItIncomplete() {
        let accumulator = NativeAudioAccumulator()
        accumulator.append(floatBuffer([[0.1]], rate: 48_000))
        accumulator.append(floatBuffer([[0.2]], rate: 16_000))
        accumulator.append(floatBuffer([[0.3]], rate: 48_000))
        XCTAssertEqual(accumulator.recording.samples, [0.1])
        XCTAssertEqual(accumulator.recording.sampleRate, 48_000)
        XCTAssertFalse(accumulator.recording.isComplete)
    }

    func testChannelLayoutChangeMarksItIncomplete() {
        let accumulator = NativeAudioAccumulator()
        accumulator.append(floatBuffer([[0.1]]))
        accumulator.append(floatBuffer([[0.2], [0.2]]))
        XCTAssertEqual(accumulator.recording.samples, [0.1])
        XCTAssertFalse(accumulator.recording.isComplete)
    }

    func testSampleAndDurationCapsBoundRetention() {
        for accumulator in [NativeAudioAccumulator(maximumSamples: 3),
                            NativeAudioAccumulator(maximumDuration: 3.0 / 48_000)] {
            accumulator.append(floatBuffer([[0.1, 0.2]]))
            accumulator.append(floatBuffer([[0.3, 0.4]]))
            accumulator.append(floatBuffer([[0.5]]))
            XCTAssertEqual(accumulator.recording.samples, [0.1, 0.2, 0.3])
            XCTAssertFalse(accumulator.recording.isComplete)
        }
    }

    func testCorruptSamplesCannotBecomeTrainingAudio() {
        let accumulator = NativeAudioAccumulator()
        accumulator.append(floatBuffer([[0.1, .nan, 0.3]]))
        XCTAssertEqual(accumulator.recording.samples, [0.1])
        XCTAssertFalse(accumulator.recording.isComplete)
    }

    func testInterleavingChangeAtSameRateAndChannelCountMarksItIncomplete() {
        let accumulator = NativeAudioAccumulator()
        accumulator.append(floatBuffer([[0.1], [0.3]], interleaved: false))
        accumulator.append(floatBuffer([[0.5], [0.7]], interleaved: true))
        XCTAssertEqual(accumulator.recording.samples, [0.2])
        XCTAssertFalse(accumulator.recording.isComplete)
    }

    func testExplicitCaptureFailureAndEmptyCaptureAreIncomplete() {
        let accumulator = NativeAudioAccumulator()
        XCTAssertFalse(accumulator.recording.isComplete)
        accumulator.append(floatBuffer([[0.1]]))
        accumulator.markIncomplete()
        accumulator.append(floatBuffer([[0.2]]))
        XCTAssertEqual(accumulator.recording.samples, [0.1])
        XCTAssertFalse(accumulator.recording.isComplete)
    }

    func testDetachingARecordingPreservesItsSamples() {
        let accumulator = NativeAudioAccumulator()
        accumulator.append(floatBuffer([[0.1]]))
        let detached = accumulator.recording
        accumulator.append(floatBuffer([[0.2]]))
        XCTAssertEqual(detached.samples, [0.1])
        XCTAssertEqual(accumulator.recording.samples, [0.1, 0.2])
    }
}
