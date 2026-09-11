import AVFoundation
import XCTest
@testable import LocalFlow

final class AudioCaptureLifecycleTests: XCTestCase {
    func testStopDrainsQueuedTailAndHandsOffBothFormatsTogether() {
        let input = SyntheticCaptureInput()
        let recorder = AudioRecorder(makeCaptureSession: input.open)
        let started = expectation(description: "started")
        recorder.start(retainNativeAudio: true) { error in
            XCTAssertNil(error)
            started.fulfill()
        }
        wait(for: [started], timeout: 2)
        let source = input.latestSource!
        let conversionBlocked = expectation(description: "conversion queue blocked")
        let allowConversion = DispatchSemaphore(value: 0)
        source.queue.async {
            conversionBlocked.fulfill()
            _ = allowConversion.wait(timeout: .now() + 3)
        }
        wait(for: [conversionBlocked], timeout: 2)
        source.send(converted: [0.1, 0.2], native: [0.3, 0.4, 0.5])
        source.send(converted: [0.6, 0.7], native: [0.8, 0.9])
        let stopped = expectation(description: "stopped")
        let prematureHandoff = expectation(description: "handoff must wait for queued conversion")
        prematureHandoff.isInverted = true
        var conversionReleased = false
        recorder.stop { recording in
            if !conversionReleased { prematureHandoff.fulfill() }
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(recording.startError)
            XCTAssertEqual(recording.samples, [0.1, 0.2, 0.6, 0.7])
            XCTAssertEqual(recording.nativeAudio?.samples, [0.3, 0.4, 0.5, 0.8, 0.9])
            XCTAssertEqual(recording.nativeAudio?.sampleRate, 48_000)
            XCTAssertEqual(recording.nativeAudio?.isComplete, true)
            stopped.fulfill()
        }
        wait(for: [prematureHandoff], timeout: 0.05)
        conversionReleased = true
        allowConversion.signal()
        wait(for: [stopped], timeout: 2)
    }

    func testStopHandsOffBeforeHardwareTeardownFinishesAndNextStartWaits() {
        let input = SyntheticCaptureInput()
        let teardownEntered = expectation(description: "teardown entered")
        let allowTeardown = DispatchSemaphore(value: 0)
        input.onStop = {
            teardownEntered.fulfill()
            _ = allowTeardown.wait(timeout: .now() + 3)
        }
        let recorder = AudioRecorder(makeCaptureSession: input.open)
        let started = expectation(description: "started")
        recorder.start { _ in started.fulfill() }
        wait(for: [started], timeout: 2)
        let oldSource = input.latestSource!
        oldSource.send(converted: [0.1], native: [])
        oldSource.send(converted: [0.2], native: [])
        let handedOff = expectation(description: "handoff during teardown")
        recorder.stop { recording in
            XCTAssertEqual(recording.samples, [0.1, 0.2])
            XCTAssertNil(recording.nativeAudio)
            handedOff.fulfill()
        }
        let nextStarted = expectation(description: "next recording started")
        recorder.start(retainNativeAudio: true) { error in
            XCTAssertNil(error)
            nextStarted.fulfill()
        }
        wait(for: [teardownEntered, handedOff], timeout: 2)
        XCTAssertEqual(input.openCount, 1)
        input.onStop = nil
        allowTeardown.signal()
        wait(for: [nextStarted], timeout: 2)

        // Late callbacks from the old input cannot wake or contaminate the
        // replacement recording, even though they use the same sample queue.
        oldSource.send(converted: [0.9], native: [0.9])
        oldSource.send(converted: [0.9], native: [0.9])
        input.latestSource!.send(converted: [0.3], native: [0.4])
        input.latestSource!.send(converted: [0.5], native: [0.6])
        let nextStopped = expectation(description: "next stopped")
        recorder.stop { recording in
            XCTAssertEqual(recording.samples, [0.3, 0.5])
            XCTAssertEqual(recording.nativeAudio?.samples, [0.4, 0.6])
            nextStopped.fulfill()
        }
        wait(for: [nextStopped], timeout: 2)
    }

    func testFailedStartBelongsToItsQueuedStopAndDoesNotLeakIntoNextRecording() {
        let input = SyntheticCaptureInput()
        input.failStart = true
        let recorder = AudioRecorder(makeCaptureSession: input.open)
        let failed = expectation(description: "failed start")
        recorder.start(retainNativeAudio: true) { error in
            XCTAssertNotNil(error)
            failed.fulfill()
        }
        let stopped = expectation(description: "failed recording handoff")
        recorder.stop { recording in
            XCTAssertNotNil(recording.startError)
            XCTAssertTrue(recording.samples.isEmpty)
            XCTAssertNil(recording.nativeAudio)
            stopped.fulfill()
        }
        wait(for: [failed, stopped], timeout: 3)
        input.failStart = false
        let started = expectation(description: "next start")
        recorder.start { error in
            XCTAssertNil(error)
            started.fulfill()
        }
        wait(for: [started], timeout: 2)
        let nextStopped = expectation(description: "next handoff")
        recorder.stop { recording in
            XCTAssertNil(recording.startError)
            nextStopped.fulfill()
        }
        wait(for: [nextStopped], timeout: 2)
    }

    func testRuntimeFailureRecoversCurrentInputAndIgnoresReplacedInput() {
        let input = SyntheticCaptureInput()
        let recorder = AudioRecorder(makeCaptureSession: input.open)
        let started = expectation(description: "started")
        recorder.start(retainNativeAudio: true) { error in
            XCTAssertNil(error)
            started.fulfill()
        }
        wait(for: [started], timeout: 2)
        let original = input.latestSource!
        original.send(converted: [0.1], native: [0.2])
        original.send(converted: [0.3], native: [0.4])
        let captured = expectation(description: "captured before failure")
        recorder.snapshot { samples in
            XCTAssertEqual(samples, [0.1, 0.3])
            captured.fulfill()
        }
        wait(for: [captured], timeout: 2)

        original.fail()
        let recovered = expectation(description: "recovery preserves captured samples")
        // snapshot drains the control queue after the failure callback, then
        // drains sample conversion, so assertions observe completed recovery.
        recorder.snapshot { samples in
            XCTAssertEqual(samples, [0.1, 0.3])
            XCTAssertEqual(input.openCount, 2)
            XCTAssertEqual(input.stopCount, 1)
            recovered.fulfill()
        }
        wait(for: [recovered], timeout: 2)
        let replacement = input.latestSource!
        XCTAssertFalse(original === replacement)
        replacement.send(converted: [0.5], native: [0.6])
        replacement.send(converted: [0.7], native: [0.8])

        original.fail()
        let staleFailureIgnored = expectation(description: "old failure leaves replacement running")
        recorder.snapshot { samples in
            XCTAssertEqual(samples, [0.1, 0.3, 0.5, 0.7])
            XCTAssertEqual(input.openCount, 2)
            XCTAssertEqual(input.stopCount, 1)
            XCTAssertTrue(input.latestSource === replacement)
            staleFailureIgnored.fulfill()
        }
        wait(for: [staleFailureIgnored], timeout: 2)

        let stopped = expectation(description: "recovered recording handoff")
        recorder.stop { recording in
            XCTAssertNil(recording.startError)
            XCTAssertEqual(recording.samples, [0.1, 0.3, 0.5, 0.7])
            XCTAssertEqual(recording.nativeAudio?.samples, [0.2, 0.4])
            XCTAssertEqual(recording.nativeAudio?.isComplete, false)
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 2)
    }

    func testSnapshotDoesNotDetachNativeAudioOrDiscardLaterSamples() {
        let input = SyntheticCaptureInput()
        let recorder = AudioRecorder(makeCaptureSession: input.open)
        let started = expectation(description: "started")
        recorder.start(retainNativeAudio: true) { _ in started.fulfill() }
        wait(for: [started], timeout: 2)
        let source = input.latestSource!
        source.send(converted: [0.1], native: [0.2])
        source.send(converted: [0.3], native: [0.4])
        let snapshot = expectation(description: "snapshot")
        recorder.snapshot { samples in
            XCTAssertEqual(samples, [0.1, 0.3])
            snapshot.fulfill()
        }
        wait(for: [snapshot], timeout: 2)
        source.send(converted: [0.5], native: [0.6])
        let stopped = expectation(description: "stopped")
        recorder.stop { recording in
            XCTAssertEqual(recording.samples, [0.1, 0.3, 0.5])
            XCTAssertEqual(recording.nativeAudio?.samples, [0.2, 0.4, 0.6])
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 2)
    }
}

/// Supplies buffers at the same queue seam as AVCaptureAudioDataOutput.
/// Recording state, live gating, draining, and handoff all remain in AudioRecorder.
private final class SyntheticCaptureInput {
    final class Source {
        let queue: DispatchQueue
        let onRaw: (AVAudioPCMBuffer?) -> Void
        let onPCM: (AVAudioPCMBuffer) -> Void
        let onFailure: () -> Void

        init(queue: DispatchQueue, onRaw: @escaping (AVAudioPCMBuffer?) -> Void,
             onPCM: @escaping (AVAudioPCMBuffer) -> Void,
             onFailure: @escaping () -> Void) {
            self.queue = queue
            self.onRaw = onRaw
            self.onPCM = onPCM
            self.onFailure = onFailure
        }

        func fail() { onFailure() }

        func send(converted: [Float], native: [Float]) {
            queue.async {
                self.onRaw(Self.buffer(native, rate: 48_000))
                self.onPCM(Self.buffer(converted, rate: 16_000))
            }
        }

        private static func buffer(_ samples: [Float], rate: Double) -> AVAudioPCMBuffer {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                       channels: 1, interleaved: false)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                          frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            for (index, sample) in samples.enumerated() {
                buffer.floatChannelData![0][index] = sample
            }
            return buffer
        }
    }

    private let lock = NSLock()
    private var source: Source?
    private var opens = 0
    private var stops = 0
    private var shouldFail = false
    private var stopCallback: (() -> Void)?

    var latestSource: Source? {
        lock.lock(); defer { lock.unlock() }
        return source
    }
    var openCount: Int {
        lock.lock(); defer { lock.unlock() }
        return opens
    }
    var stopCount: Int {
        lock.lock(); defer { lock.unlock() }
        return stops
    }
    var failStart: Bool {
        get { lock.lock(); defer { lock.unlock() }; return shouldFail }
        set { lock.lock(); defer { lock.unlock() }; shouldFail = newValue }
    }
    var onStop: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stopCallback }
        set { lock.lock(); defer { lock.unlock() }; stopCallback = newValue }
    }

    func open(deviceUID: String?, fallbackToDefaultIfUnavailable: Bool,
              targetFormat: AVAudioFormat, sampleQueue: DispatchQueue,
              onRaw: @escaping (AVAudioPCMBuffer?) -> Void,
              onPCM: @escaping (AVAudioPCMBuffer) -> Void,
              onFailure: @escaping () -> Void) throws -> AudioCaptureSession {
        lock.lock()
        opens += 1
        if shouldFail {
            lock.unlock()
            throw AudioRecorder.RecorderError.noInput
        }
        source = Source(queue: sampleQueue, onRaw: onRaw, onPCM: onPCM, onFailure: onFailure)
        lock.unlock()
        return AudioCaptureSession(deviceUID: deviceUID, microphoneName: "Synthetic input",
                                   isRunning: { true }, stop: {
            self.lock.lock()
            self.stops += 1
            let callback = self.stopCallback
            self.lock.unlock()
            callback?()
        })
    }
}
