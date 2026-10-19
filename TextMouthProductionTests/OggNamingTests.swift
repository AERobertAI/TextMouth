import Darwin
import XCTest
@testable import TextMouth

/// How a converted Ogg file is named (REV17a findings 3 and 7): the short
/// hidden name it has while it is written, and the final name it takes, which
/// must work on a file system without `RENAME_EXCL` (exFAT) and must fit the
/// 255-unit name limit when a number is added. No test uses audio: the files
/// are plain files with a few bytes in them, and nothing is converted.
final class OggNamingTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try AudioTestFixtures.makeTemporaryDirectory()
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    // MARK: - Helpers

    /// A source URL named `<stem>.ogg` in the test folder; the file itself
    /// is not made (naming never reads it).
    private func source(stem: String) -> URL {
        folder.appendingPathComponent("\(stem).ogg")
    }

    /// Writes `text` to a new plain file named `name` in the test folder.
    @discardableResult
    private func write(_ text: String, named name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// A finished conversion of `stem`.ogg whose hidden file holds
    /// "converted"; `makeFile` false leaves the hidden file unmade.
    private func conversion(stem: String, makeFile: Bool = true) throws -> ImportAudioConverter.Conversion {
        let hidden = ImportAudioConverter.temporaryURL(beside: source(stem: stem))
        if makeFile { try Data("converted".utf8).write(to: hidden) }
        return ImportAudioConverter.Conversion(
            source: source(stem: stem),
            converted: hidden,
            duration: 1,
            secondsTaken: 1,
            bytesBefore: 1,
            bytesAfter: 9,
            bitRate: nil
        )
    }

    /// The text in the file named `name` in the test folder, or nil.
    private func contents(of name: String) -> String? {
        try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    /// An exclusive rename that fails with `code` every time.
    private func failing(with code: Int32) -> (String, String) -> Int32 {
        { _, _ in
            errno = code
            return -1
        }
    }

    /// The file names in the test folder, hidden ones included.
    private func fileNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    // MARK: - The Temporary Name

    func testTemporaryNameIsHiddenShortAndBesideTheSource() {
        let url = ImportAudioConverter.temporaryURL(beside: source(stem: "Chapter"))
        let name = url.lastPathComponent
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        XCTAssertTrue(name.hasPrefix("."))
        XCTAssertTrue(name.hasSuffix(ImportAudioConverter.temporarySuffix))
        XCTAssertEqual(name.count, 58)
    }

    func testTemporaryNamesDifferAndIgnoreTheStemsLength() {
        let short = ImportAudioConverter.temporaryURL(beside: source(stem: "a.b.c"))
        let again = ImportAudioConverter.temporaryURL(beside: source(stem: "a.b.c"))
        let long = ImportAudioConverter.temporaryURL(beside: source(stem: String(repeating: "x", count: 251)))
        XCTAssertNotEqual(short.lastPathComponent, again.lastPathComponent)
        XCTAssertEqual(short.lastPathComponent.count, long.lastPathComponent.count)
    }

    func testAFileCanBeMadeUnderTheTemporaryNameOfALongestStemAndIsSwept() throws {
        // A 251-character stem makes a 255-character source name, the longest
        // there is: the old temporary name (57 characters more) was refused.
        let url = ImportAudioConverter.temporaryURL(beside: source(stem: String(repeating: "x", count: 251)))
        try Data("partial".utf8).write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        ImportAudioConverter.removeLeftovers(in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - The Final Name

    func testTheFinalNameIsTheStemWithM4aAndTheContentsArrive() throws {
        let named = try ImportAudioConverter.givingFinalName(try conversion(stem: "x"))
        XCTAssertEqual(named.converted.lastPathComponent, "x.m4a")
        XCTAssertEqual(contents(of: "x.m4a"), "converted")
        XCTAssertEqual(fileNames(), ["x.m4a"], "the hidden file is gone")
    }

    func testATakenNameGetsTheNextFreeNumberAndReplacesNothing() throws {
        try write("first", named: "x.m4a")
        let second = try ImportAudioConverter.givingFinalName(try conversion(stem: "x"))
        XCTAssertEqual(second.converted.lastPathComponent, "x 2.m4a")
        let third = try ImportAudioConverter.givingFinalName(try conversion(stem: "x"))
        XCTAssertEqual(third.converted.lastPathComponent, "x 3.m4a")
        XCTAssertEqual(contents(of: "x.m4a"), "first")
        XCTAssertEqual(contents(of: "x 2.m4a"), "converted")
        XCTAssertEqual(contents(of: "x 3.m4a"), "converted")
    }

    // MARK: - Without RENAME_EXCL (exFAT)

    func testEachUnsupportedErrnoFallsBackToAnExclusiveCreate() throws {
        for code in [ENOTSUP, EOPNOTSUPP] {
            let named = try ImportAudioConverter.givingFinalName(
                try conversion(stem: "x"),
                exclusiveRename: failing(with: code)
            )
            XCTAssertEqual(named.converted.lastPathComponent, "x.m4a", "errno \(code)")
            XCTAssertEqual(contents(of: "x.m4a"), "converted")
            // Clear the name for the next errno.
            try FileManager.default.removeItem(at: named.converted)
        }
    }

    func testTheFallbackSkipsTakenNamesAndReplacesNothing() throws {
        try write("first", named: "x.m4a")
        try write("second", named: "x 2.m4a")
        let named = try ImportAudioConverter.givingFinalName(
            try conversion(stem: "x"),
            exclusiveRename: failing(with: ENOTSUP)
        )
        XCTAssertEqual(named.converted.lastPathComponent, "x 3.m4a")
        XCTAssertEqual(contents(of: "x.m4a"), "first")
        XCTAssertEqual(contents(of: "x 2.m4a"), "second")
        XCTAssertEqual(contents(of: "x 3.m4a"), "converted")
    }

    func testAnotherErrnoIsCannotNameAndLeavesTheHiddenFile() throws {
        let pending = try conversion(stem: "x")
        XCTAssertThrowsError(
            try ImportAudioConverter.givingFinalName(pending, exclusiveRename: failing(with: EACCES))
        ) { error in
            XCTAssertEqual(error as? ImportAudioConverter.Failure, .cannotName(fileName: "x.ogg"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.converted.path))
        XCTAssertEqual(fileNames(), [pending.converted.lastPathComponent])
    }

    func testAFallbackWhoseRenameFailsRemovesItsReservationAndThrows() throws {
        // The converted file is gone, so renaming it over the reservation fails.
        let missing = try conversion(stem: "x", makeFile: false)
        XCTAssertThrowsError(
            try ImportAudioConverter.givingFinalName(missing, exclusiveRename: failing(with: ENOTSUP))
        ) { error in
            XCTAssertEqual(error as? ImportAudioConverter.Failure, .cannotName(fileName: "x.ogg"))
        }
        XCTAssertEqual(fileNames(), [], "the empty reservation is removed")
    }

    // MARK: - Long Numbered Names

    /// Takes the name `<stem>.m4a`, names a conversion of the same stem, and
    /// returns the name it got.
    private func numberedName(forStem stem: String) throws -> String {
        try write("first", named: "\(stem).m4a")
        let named = try ImportAudioConverter.givingFinalName(try conversion(stem: stem))
        XCTAssertEqual(contents(of: "\(stem).m4a"), "first", "the taken file is untouched")
        return named.converted.lastPathComponent
    }

    func testANumberedNameOfALongestStemStillFitsAndKeepsTheStemsStart() throws {
        let stem = String(repeating: "x", count: 251)
        let name = try numberedName(forStem: stem)
        XCTAssertLessThanOrEqual(name.utf16.count, 255)
        XCTAssertTrue(name.hasSuffix(" 2.m4a"))
        XCTAssertTrue(name.hasPrefix(String(stem.prefix(240))))
    }

    func testANumberedNameNeverCutsATwoUnitCharacterInHalf() throws {
        // 125 emoji of two UTF-16 units each: 250 units, so ".m4a" fits and " 2.m4a" does not.
        let stem = String(repeating: "\u{1F600}", count: 125)
        let name = try numberedName(forStem: stem)
        XCTAssertLessThanOrEqual(name.utf16.count, 255)
        XCTAssertTrue(name.hasSuffix(" 2.m4a"))
        let kept = String(name.dropLast(" 2.m4a".count))
        XCTAssertFalse(kept.isEmpty)
        XCTAssertEqual(kept, String(repeating: "\u{1F600}", count: kept.count), "only whole emoji remain")
    }

    func testANumberedNameNeverCutsACombiningSequenceInHalf() throws {
        // 125 letters each with a combining accent: 250 units, 125 characters.
        let unit = "e\u{0301}"
        let stem = String(repeating: unit, count: 125)
        let name = try numberedName(forStem: stem)
        XCTAssertLessThanOrEqual(name.utf16.count, 255)
        XCTAssertTrue(name.hasSuffix(" 2.m4a"))
        let kept = String(name.dropLast(" 2.m4a".count))
        XCTAssertFalse(kept.isEmpty)
        XCTAssertEqual(kept, String(repeating: unit, count: kept.count), "no accent is parted from its letter")
    }
}
