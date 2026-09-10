import AVFoundation
import Foundation
import XCTest
@testable import LocalFlow

final class PersonalVoiceStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testNativeRecordingPreservesSampleRateExactAudioAndPrivatePermissions() async throws {
        let root = try temporaryDirectory().appendingPathComponent("voice")
        let store = PersonalVoiceStore(folder: root)
        let recording = store.begin(metadata())
        let samples: [Float] = [0, -1, 1, 0.12345679, -0.000001, 0.75]
        recording.capture(native: .init(samples: samples, sampleRate: 48_000, isComplete: true),
                          fallback: [0.5])
        recording.finish(status: "success")

        let snapshot = try await store.snapshot()
        let clip = try XCTUnwrap(snapshot.clips.first)
        XCTAssertEqual(snapshot.clips.count, 1)
        XCTAssertEqual(clip.sampleRate, 48_000)
        XCTAssertEqual(clip.duration, Double(samples.count) / 48_000)
        XCTAssertEqual(clip.audioSource, "nativeMono")
        XCTAssertNil(clip.failureReason)
        let audio = try readAudio(store.audioURL(for: clip.id))
        XCTAssertEqual(audio.sampleRate, 48_000)
        XCTAssertEqual(audio.samples, samples)
        XCTAssertEqual(audio.channels, 1)
        XCTAssertEqual(try permissions(root), 0o700)
        XCTAssertEqual(try permissions(store.audioURL(for: clip.id)), 0o600)
        XCTAssertEqual(try permissions(root.appendingPathComponent("\(clip.id.uuidString)/clip.json")), 0o600)
    }

    func testIncompleteNativeAudioFallsBackToCompleteDictationWithSourceLabel() async throws {
        let store = PersonalVoiceStore(folder: try temporaryDirectory())
        let recording = store.begin(metadata())
        let fallback: [Float] = [0.1, 0.2, 0.3, 0.4]
        recording.capture(native: .init(samples: [0.9], sampleRate: 48_000, isComplete: false),
                          fallback: fallback)

        let snapshot = try await store.snapshot()
        let clip = try XCTUnwrap(snapshot.clips.first)
        XCTAssertEqual(clip.audioSource, "dictation16k")
        XCTAssertEqual(clip.sampleRate, 16_000)
        XCTAssertNotNil(clip.failureReason)
        XCTAssertEqual(try readAudio(store.audioURL(for: clip.id)).samples, fallback)
    }

    func testRepeatedCaptureRetainsOneOriginalAndSeparateUnapprovedTranscripts() async throws {
        let root = try temporaryDirectory()
        let store = PersonalVoiceStore(folder: root)
        let recording = store.begin(metadata())
        recording.setRawTranscript("um I I said this")
        recording.capture(native: nil, fallback: [0.25, -0.25])
        recording.capture(native: nil, fallback: [0.9])
        recording.setFinalTranscript("I said this.")
        recording.finish(status: "success")

        let snapshot = try await store.snapshot()
        let clip = try XCTUnwrap(snapshot.clips.first)
        XCTAssertEqual(snapshot.clips.count, 1)
        XCTAssertEqual(clip.rawTranscript, "um I I said this")
        XCTAssertEqual(clip.finalTranscript, "I said this.")
        XCTAssertNil(clip.reviewedTranscript)
        XCTAssertFalse(clip.approved)
        XCTAssertEqual(try readAudio(store.audioURL(for: clip.id)).samples, [0.25, -0.25])
        let files = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent(clip.id.uuidString), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "wav" }.count, 1)
    }

    func testApprovalRequiresNonemptyTranscriptAndDraftSaveClearsApproval() async throws {
        let store = PersonalVoiceStore(folder: try temporaryDirectory())
        let recording = store.begin(metadata())
        recording.capture(native: nil, fallback: [0.25])
        for empty in ["", " \n\t "] {
            do {
                try await store.updateReview(id: recording.id, transcript: empty, approved: true)
                XCTFail("An empty transcript must not be approved")
            } catch PersonalVoiceStore.ArchiveError.invalidTranscript {}
        }
        try await store.updateReview(id: recording.id, transcript: "I, um, said this.\n", approved: true)
        var snapshot = try await store.snapshot()
        var clip = try XCTUnwrap(snapshot.clips.first)
        XCTAssertTrue(clip.approved)
        XCTAssertEqual(clip.reviewedTranscript, "I, um, said this.\n")

        try await store.updateReview(id: recording.id, transcript: "Still editing", approved: false)
        snapshot = try await store.snapshot()
        clip = try XCTUnwrap(snapshot.clips.first)
        XCTAssertFalse(clip.approved)
        XCTAssertEqual(clip.reviewedTranscript, "Still editing")
    }

    func testExportIncludesOnlyApprovedAudioAndExactReviewedTextWithoutOverwriting() async throws {
        let root = try temporaryDirectory()
        let store = PersonalVoiceStore(folder: root.appendingPathComponent("voice"))
        let approved = store.begin(metadata())
        approved.capture(native: .init(samples: [0.25, -0.5], sampleRate: 44_100, isComplete: true), fallback: [])
        approved.setRawTranscript("wrong recognition")
        approved.setFinalTranscript("Cleaned text.")
        let draft = store.begin(metadata())
        draft.capture(native: nil, fallback: [0.1])
        try await store.updateReview(id: draft.id, transcript: "not approved", approved: false)
        let verbatim = "Um, I said \"this\".\nThen this. "
        try await store.updateReview(id: approved.id, transcript: verbatim, approved: true)
        let destination = root.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let keep = destination.appendingPathComponent("keep.txt")
        try Data("untouched".utf8).write(to: keep)

        let firstCount = try await store.exportApproved(to: destination)
        let secondCount = try await store.exportApproved(to: destination)
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 1)
        XCTAssertEqual(try String(contentsOf: keep), "untouched")
        let exports = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("LocalFlow-Voice-") }
        XCTAssertEqual(exports.count, 2)
        for export in exports {
            let data = try Data(contentsOf: export.appendingPathComponent("manifest.jsonl"))
            let rows = data.split(separator: 0x0a)
            XCTAssertEqual(rows.count, 1)
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rows[0])) as? [String: Any])
            XCTAssertEqual(row["id"] as? String, approved.id.uuidString)
            XCTAssertEqual(row["text"] as? String, verbatim)
            XCTAssertEqual(row["sample_rate"] as? Double, 44_100)
            let relative = try XCTUnwrap(row["audio_path"] as? String)
            XCTAssertEqual(try readAudio(export.appendingPathComponent(relative)).samples, [0.25, -0.5])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: export.appendingPathComponent("wavs").path).count, 1)
            XCTAssertEqual(try permissions(export), 0o700)
            XCTAssertEqual(try permissions(export.appendingPathComponent("manifest.jsonl")), 0o600)
        }
    }

    func testExportRefusesUnreviewedCollection() async throws {
        let root = try temporaryDirectory()
        let store = PersonalVoiceStore(folder: root.appendingPathComponent("voice"))
        let recording = store.begin(metadata())
        recording.capture(native: nil, fallback: [0.1])
        recording.setRawTranscript("Automatic recognition is not approval")
        do {
            _ = try await store.exportApproved(to: root)
            XCTFail("Unreviewed audio must not be exported")
        } catch PersonalVoiceStore.ArchiveError.noApprovedClips {}
    }

    func testCapacityRefusesNewAudioWithoutEvictingExistingClip() async throws {
        let root = try temporaryDirectory()
        let store = PersonalVoiceStore(folder: root, maxBytes: 10_000)
        let samples = Array(repeating: Float(0.25), count: 1_000)
        let first = store.begin(metadata())
        first.capture(native: nil, fallback: samples)
        let before = try await store.snapshot()
        XCTAssertEqual(before.clips.map(\.id), [first.id])
        let firstData = try Data(contentsOf: store.audioURL(for: first.id))
        let rejected = store.begin(metadata())
        rejected.capture(native: nil, fallback: samples)
        rejected.setRawTranscript("late recognition")
        rejected.finish(status: "success")

        let after = try await store.snapshot()
        XCTAssertEqual(after.clips.map(\.id), [first.id])
        XCTAssertEqual(after.usedBytes, before.usedBytes)
        XCTAssertLessThanOrEqual(after.usedBytes, after.maxBytes)
        XCTAssertNotNil(after.issue)
        XCTAssertEqual(try Data(contentsOf: store.audioURL(for: first.id)), firstData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(for: rejected.id).path))
    }

    func testDeletePreventsLateWritesFromRestoringSavedOrPendingRecording() async throws {
        let root = try temporaryDirectory()
        let store = PersonalVoiceStore(folder: root)
        for saveBeforeDelete in [false, true] {
            let recording = store.begin(metadata())
            if saveBeforeDelete { recording.capture(native: nil, fallback: [0.1]) }
            try await store.delete(id: recording.id)
            recording.setRawTranscript("late raw")
            recording.setFinalTranscript("late cleaned")
            recording.capture(native: nil, fallback: [0.9])
            recording.finish(status: "failed")
            let snapshot = try await store.snapshot()
            XCTAssertTrue(snapshot.clips.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(for: recording.id).path))
        }
    }

    func testDiagnosticImportUsesOnlyOriginalAudioPreservesStagesAndDoesNotApprove() async throws {
        let root = try temporaryDirectory()
        let diagnosticFolder = root.appendingPathComponent("diagnostics")
        let diagnostics = DictationDiagnosticStore(folder: diagnosticFolder)
        let source = diagnostics.begin(metadata())
        source.saveAudio([0.25, -0.25])
        source.record(.init(stage: "capture", sampleCount: 2))
        source.saveAudio([0.9], named: "retry.wav")
        source.record(.init(stage: "assembledTranscript", text: "um um original"))
        source.record(.init(stage: "finalTranscript", text: "Original."))
        let noOriginal = diagnostics.begin(metadata())
        noOriginal.saveAudio([0.8], named: "retry.wav")
        diagnostics.flush()
        let store = PersonalVoiceStore(folder: root.appendingPathComponent("voice"), diagnosticsFolder: diagnosticFolder)

        let imported = try await store.importDiagnostics()
        let repeated = try await store.importDiagnostics()
        XCTAssertEqual(imported, 1)
        XCTAssertEqual(repeated, 0)
        let snapshot = try await store.snapshot()
        let clip = try XCTUnwrap(snapshot.clips.first)
        XCTAssertEqual(snapshot.clips.count, 1)
        XCTAssertEqual(clip.id, source.id)
        XCTAssertEqual(clip.rawTranscript, "um um original")
        XCTAssertEqual(clip.finalTranscript, "Original.")
        XCTAssertEqual(clip.sampleRate, 16_000)
        XCTAssertFalse(clip.approved)
        XCTAssertNil(clip.reviewedTranscript)
        XCTAssertEqual(try readAudio(store.audioURL(for: clip.id)).samples, [0.25, -0.25])
        XCTAssertTrue(FileManager.default.fileExists(atPath: diagnosticFolder.appendingPathComponent("\(source.id.uuidString)/original.wav").path))
    }

    func testDiagnosticImportHonorsCapacityAndKeepsAlreadyImportedClip() async throws {
        let root = try temporaryDirectory()
        let diagnosticFolder = root.appendingPathComponent("diagnostics")
        let diagnostics = DictationDiagnosticStore(folder: diagnosticFolder)
        for _ in 0..<2 {
            let recording = diagnostics.begin(metadata())
            recording.saveAudio(Array(repeating: 0.25, count: 2_000))
            recording.record(.init(stage: "capture", sampleCount: 2_000))
        }
        diagnostics.flush()
        // One WAV plus metadata fits, including AVAudioFile's header padding; two do not.
        let store = PersonalVoiceStore(folder: root.appendingPathComponent("voice"), maxBytes: 20_000,
                                       diagnosticsFolder: diagnosticFolder)
        do {
            _ = try await store.importDiagnostics()
            XCTFail("Import should report the storage limit")
        } catch PersonalVoiceStore.ArchiveError.full {}
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.clips.count, 1)
        XCTAssertLessThanOrEqual(snapshot.usedBytes, snapshot.maxBytes)
        XCTAssertNotNil(snapshot.issue)
        let clip = try XCTUnwrap(snapshot.clips.first)
        XCTAssertEqual(try readAudio(store.audioURL(for: clip.id)).samples.count, 2_000)
    }

    func testImportWaitsForCaptureCompletionAndCanImportOnNextAttempt() async throws {
        let root = try temporaryDirectory()
        let diagnosticFolder = root.appendingPathComponent("diagnostics")
        let diagnostics = DictationDiagnosticStore(folder: diagnosticFolder)
        let source = diagnostics.begin(metadata())
        source.saveAudio([0.25, -0.25])
        source.record(.init(stage: "assembledTranscript", text: "Original words"))
        diagnostics.flush()
        let store = PersonalVoiceStore(folder: root.appendingPathComponent("voice"), diagnosticsFolder: diagnosticFolder)

        let incompleteCount = try await store.importDiagnostics()
        let incomplete = try await store.snapshot()
        XCTAssertEqual(incompleteCount, 0)
        XCTAssertTrue(incomplete.clips.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(for: source.id).path))

        source.record(.init(stage: "capture", sampleCount: 2))
        diagnostics.flush()
        let completedCount = try await store.importDiagnostics()
        let completed = try await store.snapshot()
        XCTAssertEqual(completedCount, 1)
        XCTAssertEqual(completed.clips.map(\.id), [source.id])
        XCTAssertEqual(try readAudio(store.audioURL(for: source.id)).samples, [0.25, -0.25])
    }

    func testImportRejectsMismatchedDiagnosticTraceAndKeepsSourceFiles() async throws {
        let root = try temporaryDirectory()
        let diagnosticFolder = root.appendingPathComponent("diagnostics")
        let diagnostics = DictationDiagnosticStore(folder: diagnosticFolder)
        let source = diagnostics.begin(metadata())
        source.saveAudio([0.25])
        source.record(.init(stage: "capture", sampleCount: 1))
        diagnostics.flush()
        let originalDirectory = diagnosticFolder.appendingPathComponent(source.id.uuidString)
        let metadataURL = originalDirectory.appendingPathComponent("metadata.json")
        try rewriteJSONObject(at: metadataURL) { $0["traceID"] = UUID().uuidString }
        let originalMetadata = try Data(contentsOf: metadataURL)
        let audioURL = originalDirectory.appendingPathComponent("original.wav")
        let originalAudio = try Data(contentsOf: audioURL)
        let store = PersonalVoiceStore(folder: root.appendingPathComponent("voice"), diagnosticsFolder: diagnosticFolder)

        do {
            let count = try await store.importDiagnostics()
            XCTAssertEqual(count, 0)
        } catch {
            // Either a reported import error or a skipped source must preserve its files.
        }
        let snapshot = try await store.snapshot()
        XCTAssertTrue(snapshot.clips.isEmpty)
        XCTAssertEqual(try Data(contentsOf: metadataURL), originalMetadata)
        XCTAssertEqual(try Data(contentsOf: audioURL), originalAudio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(for: source.id).path))
    }

    func testAdmittedClipRetainsTranscriptAndReviewUpdatesAfterArchiveIsFull() async throws {
        let root = try temporaryDirectory()
        let store = PersonalVoiceStore(folder: root, maxBytes: 10_000)
        let recording = store.begin(metadata())
        recording.capture(native: nil, fallback: [0.25])
        let admitted = try await store.snapshot()
        XCTAssertEqual(admitted.clips.map(\.id), [recording.id])
        let raw = String(repeating: "spoken words ", count: 1_000)
        let final = String(repeating: "Cleaned words. ", count: 1_000)
        recording.setRawTranscript(raw)
        recording.setFinalTranscript(final)
        recording.finish(status: "success")

        let full = try await store.snapshot()
        let clip = try XCTUnwrap(full.clips.first)
        XCTAssertGreaterThan(full.usedBytes, full.maxBytes)
        XCTAssertEqual(clip.rawTranscript, raw)
        XCTAssertEqual(clip.finalTranscript, final)

        let constrained = PersonalVoiceStore(folder: root, maxBytes: 1)
        try await constrained.updateReview(id: recording.id, transcript: "Exactly what I said.", approved: true)
        let reviewed = try await constrained.snapshot()
        let approved = try XCTUnwrap(reviewed.clips.first)
        XCTAssertEqual(approved.reviewedTranscript, "Exactly what I said.")
        XCTAssertTrue(approved.approved)
        XCTAssertEqual(approved.rawTranscript, raw)
        XCTAssertEqual(approved.finalTranscript, final)
    }

    func testSnapshotRejectsClipIdentityMismatchAndKeepsFiles() async throws {
        let root = try temporaryDirectory()
        let store = PersonalVoiceStore(folder: root)
        let recording = store.begin(metadata())
        recording.capture(native: nil, fallback: [0.25])
        _ = try await store.snapshot()
        let clipURL = root.appendingPathComponent("\(recording.id.uuidString)/clip.json")
        try rewriteJSONObject(at: clipURL) { $0["id"] = UUID().uuidString }
        let corruptMetadata = try Data(contentsOf: clipURL)

        let snapshot = try await store.snapshot()
        XCTAssertTrue(snapshot.clips.isEmpty)
        XCTAssertNotNil(snapshot.issue)
        XCTAssertEqual(try Data(contentsOf: clipURL), corruptMetadata)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: recording.id).path))
    }

    func testSnapshotRejectsNestedTraceIdentityMismatchAndKeepsFiles() async throws {
        let root = try temporaryDirectory()
        let store = PersonalVoiceStore(folder: root)
        let recording = store.begin(metadata())
        recording.capture(native: nil, fallback: [0.25])
        _ = try await store.snapshot()
        let clipURL = root.appendingPathComponent("\(recording.id.uuidString)/clip.json")
        try rewriteJSONObject(at: clipURL) { object in
            var metadata = try XCTUnwrap(object["metadata"] as? [String: Any])
            metadata["traceID"] = UUID().uuidString
            object["metadata"] = metadata
        }
        let corruptMetadata = try Data(contentsOf: clipURL)

        let snapshot = try await store.snapshot()
        XCTAssertTrue(snapshot.clips.isEmpty)
        XCTAssertNotNil(snapshot.issue)
        XCTAssertEqual(try Data(contentsOf: clipURL), corruptMetadata)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: recording.id).path))
    }

    func testConcurrentStoresImportSameDiagnosticOnlyOnceWithinSharedQuota() async throws {
        let root = try temporaryDirectory()
        let diagnosticFolder = root.appendingPathComponent("diagnostics")
        let diagnostics = DictationDiagnosticStore(folder: diagnosticFolder)
        let source = diagnostics.begin(metadata())
        let samples = Array(repeating: Float(0.25), count: 2_000)
        source.saveAudio(samples)
        source.record(.init(stage: "capture", sampleCount: samples.count))
        diagnostics.flush()
        let voiceFolder = root.appendingPathComponent("voice")
        let first = PersonalVoiceStore(folder: voiceFolder, maxBytes: 20_000, diagnosticsFolder: diagnosticFolder)
        let second = PersonalVoiceStore(folder: voiceFolder, maxBytes: 20_000, diagnosticsFolder: diagnosticFolder)

        async let firstImport = first.importDiagnostics()
        async let secondImport = second.importDiagnostics()
        let counts = try await (firstImport, secondImport)

        XCTAssertEqual(counts.0 + counts.1, 1)
        let firstSnapshot = try await first.snapshot()
        let secondSnapshot = try await second.snapshot()
        XCTAssertEqual(firstSnapshot.clips.map(\.id), [source.id])
        XCTAssertEqual(secondSnapshot.clips.map(\.id), [source.id])
        XCTAssertEqual(firstSnapshot.usedBytes, secondSnapshot.usedBytes)
        XCTAssertLessThanOrEqual(firstSnapshot.usedBytes, firstSnapshot.maxBytes)
        XCTAssertNil(firstSnapshot.issue)
        XCTAssertNil(secondSnapshot.issue)
        XCTAssertEqual(try readAudio(first.audioURL(for: source.id)).samples, samples)
    }

    func testInterruptedStagingCountsTowardQuotaAndIsKeptForRecovery() async throws {
        let root = try temporaryDirectory()
        let pending = root.appendingPathComponent(".pending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false)
        let original = pending.appendingPathComponent("audio.wav")
        let data = Data(repeating: 42, count: 10_000)
        try data.write(to: original)
        let store = PersonalVoiceStore(folder: root, maxBytes: 10_000)
        let before = try await store.snapshot()
        XCTAssertTrue(before.clips.isEmpty)
        XCTAssertEqual(before.usedBytes, 10_000)
        XCTAssertNotNil(before.issue)
        let recording = store.begin(metadata())
        recording.capture(native: nil, fallback: [0.25])
        let after = try await store.snapshot()
        XCTAssertTrue(after.clips.isEmpty)
        XCTAssertEqual(after.usedBytes, 10_000)
        XCTAssertEqual(try Data(contentsOf: original), data)
    }

    func testArchiveFolderBelongsToLocalAppAndIsSeparateFromDiagnostics() {
        XCTAssertEqual(PersonalVoiceStore.folder.lastPathComponent, "PersonalVoice")
        XCTAssertEqual(PersonalVoiceStore.folder.deletingLastPathComponent().lastPathComponent, "LocalFlow Local")
        XCTAssertNotEqual(PersonalVoiceStore.folder, DictationDiagnosticStore.folder)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlow-PersonalVoiceStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        temporaryDirectories.append(directory)
        return directory
    }

    private func metadata() -> DictationDiagnosticStore.Metadata {
        .init(traceID: UUID(),
              context: .init(cleanupEnabled: true, styleProfile: .general, corrections: [], snippets: [],
                             ollamaModel: "test-cleaner"),
              whisperModel: "test-whisper", microphone: "synthetic-input", vocabulary: "")
    }

    private func rewriteJSONObject(at url: URL, mutation: (inout [String: Any]) throws -> Void) throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        try mutation(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func readAudio(_ url: URL) throws -> (samples: [Float], sampleRate: Double, channels: AVAudioChannelCount) {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        return (Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))),
                file.fileFormat.sampleRate, file.fileFormat.channelCount)
    }
}
