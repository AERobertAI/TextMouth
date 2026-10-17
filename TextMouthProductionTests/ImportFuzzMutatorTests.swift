import XCTest

/// The import fuzz sweep's mutator (`ImportFuzzMutator`): the same seed gives
/// the same damaged bytes on every Mac, each mutation does exactly what its
/// name says, and each document type is offered only the damage that makes
/// sense for it. Pure and quick: no file is read or written.
final class ImportFuzzMutatorTests: XCTestCase {
    /// A document of 5,000 bytes, none of them 0, so a zeroed window, a
    /// changed byte, or an inserted NUL always shows. Fixed, never random.
    private let sample: Data = {
        var rng = SplitMix64(seed: 42)
        return Data((0..<5_000).map { _ in UInt8(truncatingIfNeeded: rng.next() % 255) + 1 })
    }()

    /// Applies `mutation` to `sample` with the usual name and a seed.
    private func damaged(
        _ mutation: ImportFuzzMutation,
        seed: UInt64 = 7,
        name: String = "book.epub",
        from data: Data? = nil
    ) -> Data {
        ImportFuzzMutator.apply(mutation, to: data ?? sample, fileName: name, seed: seed)
    }

    /// How many positions of two equally long byte strings differ.
    private func differingBytes(_ first: Data, _ second: Data) -> Int {
        XCTAssertEqual(first.count, second.count, "the lengths differ, so a byte-by-byte comparison means nothing")
        return zip(first, second).filter { $0 != $1 }.count
    }

    // MARK: - Repeatability

    /// The same file name, mutation, and seed give identical bytes, for
    /// every mutation: a case id is enough to reproduce a failure.
    func testTheSameSeedGivesIdenticalBytes() {
        for mutation in ImportFuzzMutation.allCases {
            XCTAssertEqual(damaged(mutation), damaged(mutation), "\(mutation) is not repeatable")
        }
    }

    /// A different seed gives different bytes for every mutation whose
    /// damage is random (the truncations, the empty file, and the nesting,
    /// which goes in at a fixed place, are not).
    func testADifferentSeedGivesDifferentBytes() {
        let fixed: Set<ImportFuzzMutation> = [
            .truncate10, .truncate25, .truncate50, .truncate75, .truncate90, .truncate99, .empty, .deepNesting,
        ]
        for mutation in ImportFuzzMutation.allCases where !fixed.contains(mutation) {
            XCTAssertNotEqual(damaged(mutation, seed: 1), damaged(mutation, seed: 2), "\(mutation) ignores its seed")
        }
    }

    /// Two documents in one run do not make the same random choices.
    func testADifferentFileNameGivesDifferentBytes() {
        XCTAssertNotEqual(
            damaged(.flip64, name: "a.epub"),
            damaged(.flip64, name: "b.epub")
        )
    }

    /// The generator is a fixed algorithm: its first numbers never change,
    /// or every saved seed would reproduce something else (SplitMix64's
    /// published values for seed 0).
    func testTheGeneratorMatchesItsPublishedSequence() {
        var rng = SplitMix64(seed: 0)
        XCTAssertEqual(rng.next(), 0xE220_A839_7B1D_CDAF)
        XCTAssertEqual(rng.next(), 0x6E78_9E6A_A1B9_65F4)
        XCTAssertEqual(rng.next(), 0x06C4_5D18_8009_454F)
    }

    // MARK: - Truncation and Emptying

    /// Each truncation keeps exactly its share of the bytes, from the start.
    func testTruncationKeepsTheStatedShareFromTheStart() {
        let expected: [(ImportFuzzMutation, Int)] = [
            (.truncate10, 500), (.truncate25, 1_250), (.truncate50, 2_500),
            (.truncate75, 3_750), (.truncate90, 4_500), (.truncate99, 4_950),
        ]
        for (mutation, length) in expected {
            let result = damaged(mutation)
            XCTAssertEqual(result.count, length, "\(mutation)")
            XCTAssertEqual(result, sample.prefix(length), "\(mutation) changed the bytes it kept")
        }
    }

    /// A file too small to cut still gives a valid result, never a crash.
    func testTruncationOfTinyFilesIsSafe() {
        for size in 0...3 {
            let tiny = Data(repeating: 9, count: size)
            for mutation in ImportFuzzMutation.allCases {
                // Only the absence of a trap is asserted.
                _ = damaged(mutation, from: tiny)
            }
        }
        XCTAssertEqual(damaged(.truncate99, from: Data(repeating: 9, count: 1)).count, 0)
    }

    /// The empty mutation leaves no bytes.
    func testEmptyIsEmpty() {
        XCTAssertTrue(damaged(.empty).isEmpty)
    }

    // MARK: - Flips

    /// Each flip changes exactly the stated number of bytes, none by
    /// coincidence of equal values, and keeps the length.
    func testFlipsChangeExactlyTheStatedNumberOfBytes() {
        let expected: [(ImportFuzzMutation, Int)] = [(.flip1, 1), (.flip8, 8), (.flip64, 64)]
        for (mutation, changed) in expected {
            XCTAssertEqual(differingBytes(damaged(mutation), sample), changed, "\(mutation)")
        }
    }

    /// A file shorter than the flip count has every byte changed, no more.
    func testFlipsOfAShortFileChangeEveryByte() {
        let short = Data([1, 2, 3])
        XCTAssertEqual(differingBytes(damaged(.flip8, from: short), short), 3)
    }

    // MARK: - Windows

    /// The zeroed window is one run of exactly 1,024 zero bytes; nothing
    /// else changes, and the length stays.
    func testZeroWindowZeroesOneKilobyte() {
        let result = damaged(.zeroWindow)
        XCTAssertEqual(result.count, sample.count)
        let zeroed = result.enumerated().filter { $0.element == 0 }.map(\.offset)
        XCTAssertEqual(zeroed.count, 1_024)
        if let first = zeroed.first, let last = zeroed.last {
            XCTAssertEqual(last - first + 1, 1_024, "the zeroes are not one window")
        }
        XCTAssertEqual(differingBytes(result, sample), 1_024)
    }

    /// The deleted window shortens the file by 1,024 bytes, and what is left
    /// is the start and the end of the original.
    func testDeleteWindowRemovesOneKilobyte() {
        let result = damaged(.deleteWindow)
        XCTAssertEqual(result.count, sample.count - 1_024)
        // Find where the deletion was: the first byte that differs from the start.
        let start = zip(result, sample).prefix { $0 == $1 }.count
        XCTAssertEqual(result.suffix(result.count - start), sample.suffix(result.count - start))
    }

    /// The duplicated window makes the file 1,024 bytes longer: the
    /// original with one stretch of it twice.
    func testDuplicateWindowRepeatsOneKilobyte() {
        let result = damaged(.duplicateWindow)
        XCTAssertEqual(result.count, sample.count + 1_024)
        // Removing the second copy (found where the files part) gives the original back.
        let start = zip(result, sample).prefix { $0 == $1 }.count
        // The copy is at `start - window ... start` or later; try every
        // place the second copy could begin.
        let restored = (0...start).contains { copyStart in
            var candidate = result
            guard copyStart + 1_024 <= candidate.count else { return false }
            candidate.removeSubrange(copyStart..<(copyStart + 1_024))
            return candidate == sample
        }
        XCTAssertTrue(restored, "removing 1 KB does not give the original back")
    }

    /// A file shorter than the window loses or doubles all of itself, safely.
    func testWindowsOfAShortFileCoverTheWholeFile() {
        let short = Data([5, 6, 7])
        XCTAssertEqual(damaged(.zeroWindow, from: short), Data([0, 0, 0]))
        XCTAssertTrue(damaged(.deleteWindow, from: short).isEmpty)
        XCTAssertEqual(damaged(.duplicateWindow, from: short), Data([5, 6, 7, 5, 6, 7]))
    }

    // MARK: - Padding

    /// Random bytes go before the original, which follows intact.
    func testPrependAddsOneKilobyteBeforeTheOriginal() {
        let result = damaged(.prependRandom)
        XCTAssertEqual(result.count, sample.count + 1_024)
        XCTAssertEqual(result.suffix(sample.count), sample)
    }

    /// Random bytes go after the original, which stays intact.
    func testAppendAddsOneKilobyteAfterTheOriginal() {
        let result = damaged(.appendRandom)
        XCTAssertEqual(result.count, sample.count + 1_024)
        XCTAssertEqual(result.prefix(sample.count), sample)
    }

    // MARK: - ZIP Damage

    /// The tail mutation changes exactly the last 64 bytes and none before.
    func testZipTailTouchesOnlyTheLast64Bytes() {
        let result = damaged(.zipTail)
        XCTAssertEqual(result.count, sample.count)
        XCTAssertEqual(result.prefix(sample.count - 64), sample.prefix(sample.count - 64))
        XCTAssertEqual(differingBytes(result.suffix(64), sample.suffix(64)), 64)
    }

    /// The head mutation changes the header fields after the 4-byte
    /// signature, up to the header's 30 bytes, and nothing else.
    func testZipHeadTouchesOnlyTheFirstHeadersFields() {
        let result = damaged(.zipHead)
        XCTAssertEqual(result.count, sample.count)
        XCTAssertEqual(result.prefix(4), sample.prefix(4), "the signature must stay")
        XCTAssertEqual(result.dropFirst(30), sample.dropFirst(30))
        XCTAssertEqual(differingBytes(result.prefix(30), sample.prefix(30)), 26)
    }

    // MARK: - Text Damage

    /// 16 NUL bytes are added, and removing them gives the original back.
    func testInsertNULAddsSixteenNULs() {
        let result = damaged(.insertNUL)
        XCTAssertEqual(result.count, sample.count + 16)
        XCTAssertEqual(result.filter { $0 == 0 }.count, 16)
        XCTAssertEqual(result.filter { $0 != 0 }, sample)
    }

    /// The overlong "/" (0xC0 0xAF) and the lone 0xFF are added, so the
    /// bytes are no longer valid UTF-8, and the original's bytes remain in
    /// order.
    func testInvalidUTF8AddsTheSequences() {
        let ascii = Data("plain text only".utf8)
        let result = damaged(.invalidUTF8, from: ascii)
        XCTAssertEqual(result.count, ascii.count + 3)
        XCTAssertNil(String(data: result, encoding: .utf8))
        XCTAssertTrue(result.contains(0xFF))
        XCTAssertTrue(result.contains(0xC0))
        XCTAssertTrue(result.contains(0xAF))
    }

    /// One megabyte of "x" with no line break is added.
    func testLongLineAddsOneMegabyteWithoutALineBreak() {
        let text = Data("line one\nline two\n".utf8)
        let result = damaged(.longLine, from: text)
        XCTAssertEqual(result.count, text.count + 1_048_576)
        XCTAssertEqual(result.filter { $0 == UInt8(ascii: "x") }.count, 1_048_576)
        XCTAssertEqual(result.filter { $0 == 10 }.count, 2)
    }

    /// 5,000 opening div tags go just inside the body.
    func testDeepNestingOpensFiveThousandDivsInsideTheBody() throws {
        let page = Data("<html><body class=\"a\"><p>Hi</p></body></html>".utf8)
        let result = damaged(.deepNesting, from: page)
        let text = try XCTUnwrap(String(data: result, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("<html><body class=\"a\">" + String(repeating: "<div>", count: 5_000) + "<p>"))
        XCTAssertEqual(text.components(separatedBy: "<div>").count - 1, 5_000)
    }

    /// A page with no body tag gets the nesting at its start.
    func testDeepNestingWithoutABodyGoesFirst() throws {
        let result = damaged(.deepNesting, from: Data("<p>Hi</p>".utf8))
        let text = try XCTUnwrap(String(data: result, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("<div>"))
        XCTAssertTrue(text.hasSuffix("<p>Hi</p>"))
    }

    // MARK: - Which Mutations Apply

    /// ZIP-based documents get the ZIP damage and no text damage.
    func testZipDocumentsGetZipDamageOnly() {
        for name in ["alice.epub", "alice.DOCX", "daisy.zip"] {
            let applicable = ImportFuzzMutator.applicable(to: name)
            XCTAssertTrue(applicable.contains(.zipTail), name)
            XCTAssertTrue(applicable.contains(.zipHead), name)
            XCTAssertFalse(applicable.contains(.insertNUL), name)
            XCTAssertFalse(applicable.contains(.longLine), name)
            XCTAssertFalse(applicable.contains(.deepNesting), name)
        }
    }

    /// Text documents get the text damage and no ZIP damage; only HTML nests.
    func testTextDocumentsGetTextDamageOnly() {
        for name in ["pride.txt", "sample.md", "page.html", "page.xhtml"] {
            let applicable = ImportFuzzMutator.applicable(to: name)
            XCTAssertFalse(applicable.contains(.zipTail), name)
            XCTAssertFalse(applicable.contains(.zipHead), name)
            for mutation in [ImportFuzzMutation.insertNUL, .invalidUTF8, .longLine] {
                XCTAssertTrue(applicable.contains(mutation), "\(name) \(mutation)")
            }
        }
        XCTAssertTrue(ImportFuzzMutator.applicable(to: "page.html").contains(.deepNesting))
        XCTAssertFalse(ImportFuzzMutator.applicable(to: "sample.md").contains(.deepNesting))
        XCTAssertFalse(ImportFuzzMutator.applicable(to: "pride.txt").contains(.deepNesting))
    }

    /// Every document, whatever its type, is offered the general damage.
    func testEveryDocumentGetsTheGeneralDamage() {
        let general: [ImportFuzzMutation] = [
            .truncate10, .truncate25, .truncate50, .truncate75, .truncate90, .truncate99, .empty,
            .flip1, .flip8, .flip64, .zeroWindow, .deleteWindow, .duplicateWindow, .prependRandom, .appendRandom,
        ]
        for name in ["alice.epub", "sample.md", "book.pdf", "unknown.bin", "noextension"] {
            let applicable = ImportFuzzMutator.applicable(to: name)
            for mutation in general {
                XCTAssertTrue(applicable.contains(mutation), "\(name) \(mutation)")
            }
        }
    }

    // MARK: - Case Identity

    /// A case id is the document, the mutation, and the seed, in text that
    /// is the same every run.
    func testCaseIDsAreStableText() {
        XCTAssertEqual(
            ImportFuzzMutator.caseID(fileName: "alice.epub", mutation: .flip8, seed: 20_261_016),
            "alice.epub#flip8#seed=20261016"
        )
        let ids = ImportFuzzMutation.allCases.map {
            ImportFuzzMutator.caseID(fileName: "a.zip", mutation: $0, seed: 1)
        }
        XCTAssertEqual(Set(ids).count, ids.count, "two mutations share an id")
    }
}
