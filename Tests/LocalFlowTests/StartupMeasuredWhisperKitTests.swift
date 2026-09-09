import XCTest
import WhisperKit
@testable import LocalFlow

final class StartupMeasuredWhisperKitTests: XCTestCase {
    func testFailedModelLoadPreservesErrorAndRecordsFailure() async throws {
        let events = TraceEvents()
        let trace = DictationTrace(source: .modelLoad, sink: { events.append($0) })
        // No downloads or model files are needed to exercise the failure path.
        let pipeline = try await StartupMeasuredWhisperKit(WhisperKitConfig(load: false, download: false))
        await DictationTrace.$current.withValue(trace) {
            do {
                try await pipeline.loadModels()
                XCTFail("Loading without a model folder must fail")
            } catch {
                XCTAssertTrue(error is WhisperError)
            }
        }
        XCTAssertEqual(events.events.map(\.name), [.modelInitializationStarted, .modelInitializationFinished])
        XCTAssertEqual(events.events.last?.status, .failed)
        XCTAssertTrue(events.events.allSatisfy { $0.source == .modelLoad && $0.sinceReleaseMs == nil })
    }

    func testFailedTokenizerLoadIsNotReportedAsSuccess() async throws {
        let events = TraceEvents()
        let trace = DictationTrace(source: .modelLoad, sink: { events.append($0) })
        let pipeline = try await StartupMeasuredWhisperKit(WhisperKitConfig(load: false, download: false))
        await DictationTrace.$current.withValue(trace) {
            do {
                try await pipeline.loadTokenizerIfNeeded()
                XCTFail("Tokenizer loading without model dimensions must fail")
            } catch {
                XCTAssertTrue(error is WhisperError)
            }
        }
        XCTAssertEqual(events.events.map(\.name), [.tokenizerLoadStarted, .tokenizerLoadFinished])
        XCTAssertEqual(events.events.last?.status, .failed)
    }
}
