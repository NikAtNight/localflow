import XCTest
@testable import LocalFlow

final class TextInjectorTests: XCTestCase {
    func testUTF16ChunksRoundTripWithoutSplittingSurrogatePairs() async {
        // Nine ASCII units followed by an emoji puts the high surrogate exactly
        // at a naive ten-unit boundary.
        let text = "123456789😀tail"
        let chunks = await TextInjector.utf16Chunks(text, maxUnits: 10)

        XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 10 })
        for chunk in chunks {
            XCTAssertFalse((0xD800 ... 0xDBFF).contains(chunk.last!))
            XCTAssertFalse((0xDC00 ... 0xDFFF).contains(chunk.first!))
        }
    }

    func testUTF16ChunksHandlesEmptyAndASCIIText() async {
        let empty = await TextInjector.utf16Chunks("")
        let ascii = await TextInjector.utf16Chunks("abcdefgh", maxUnits: 3)

        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(ascii.map(\.count), [3, 3, 2])
        XCTAssertEqual(ascii.flatMap { $0 }, Array("abcdefgh".utf16))
    }
}
