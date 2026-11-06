import XCTest
@testable import TextMouth

/// Layer 1 of the KFX reader (FMT52): a Kindle KFX file is recognized by its
/// bytes, never its name, in both the files Kindle's apps name `.azw` and
/// the sets in a ZIP, and what must be refused is refused with its sentence
/// before anything else is read. Nothing here decrypts.
final class KFXRecognitionTests: XCTestCase {

    // MARK: - The sentences

    private static let protectedSentence =
        "This Kindle book is copy-protected, and TextMouth can't read copy-protected books."
    private static let kindleCreateSentence =
        "This file is a Kindle Create package, which TextMouth can't read yet."

    // MARK: - Helpers

    /// A file named `name` holding `bytes`, in a sandbox folder of its own.
    private func write(_ bytes: [UInt8], named name: String) throws -> URL {
        let url = try makeSandboxDirectory("KFX").appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// The bytes of a protected container: the mark and some payload.
    private var protectedBytes: [UInt8] { KFXSignature.protectedMagic + Array(repeating: 0x55, count: 64) }

    /// The bytes that begin a KFX container (the signature, version 2, and
    /// filler: the walk is not in yet, so no layer reads more).
    private var containerBytes: [UInt8] { KFXSignature.containerMagic + [2, 0] + Array(repeating: 0, count: 64) }

    /// Asserts that reading the file at `url` as KFX throws `expected`, with
    /// that exact sentence.
    private func assertRefused<E: Error & Equatable>(
        _ url: URL, _ expected: E, sentence: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try KFXParser.prepareBook(url: url), file: file, line: line) {
            XCTAssertEqual($0 as? E, expected, file: file, line: line)
            XCTAssertEqual($0.localizedDescription, sentence, file: file, line: line)
        }
    }

    // MARK: - The bytes

    func testTheFirstBytesTellTheKinds() {
        XCTAssertEqual(KFXSignature.kind(ofPrefix: protectedBytes), .protected)
        XCTAssertEqual(KFXSignature.kind(ofPrefix: containerBytes), .container)
        XCTAssertEqual(KFXSignature.kind(ofPrefix: [0x50, 0x4B, 3, 4, 0]), .zip)
        XCTAssertEqual(KFXSignature.kind(ofPrefix: Array("BOOKMOBI".utf8)), .other)
        // A prefix that stops short of a signature is not one.
        XCTAssertEqual(KFXSignature.kind(ofPrefix: [0xEA, 0x44, 0x52]), .other)
        XCTAssertEqual(KFXSignature.kind(ofPrefix: Array("CON".utf8)), .other)
        XCTAssertEqual(KFXSignature.kind(ofPrefix: []), .other)
    }

    // MARK: - Protected books

    func testAProtectedContainerIsRefusedWhateverItsName() throws {
        for name in ["book.kfx", "book.azw8", "book.azw", "book.KFX", "book"] {
            let url = try write(protectedBytes, named: name)
            assertRefused(url, MOBIError.copyProtected, sentence: Self.protectedSentence)
        }
    }

    func testAProtectedContainerOfJustTheMarkIsRefused() throws {
        let url = try write(KFXSignature.protectedMagic, named: "short.kfx")
        assertRefused(url, MOBIError.copyProtected, sentence: Self.protectedSentence)
    }

    func testTheProtectedSentenceIsTheMOBIReadersOwn() {
        XCTAssertEqual(MOBIError.copyProtected.localizedDescription, Self.protectedSentence)
    }

    // MARK: - An .azw file holding KFX

    func testAnAzwHoldingAProtectedContainerIsRefusedAsProtectedNotAsABrokenMOBI() throws {
        let url = try write(protectedBytes, named: "purchase.azw")
        XCTAssertThrowsError(try MOBIParser.prepareBook(url: url)) {
            XCTAssertEqual($0 as? MOBIError, .copyProtected)
        }
        XCTAssertThrowsError(try FileImportService.importFileWithReport(from: url)) {
            XCTAssertTrue($0.localizedDescription.hasSuffix(Self.protectedSentence), $0.localizedDescription)
        }
    }

    func testAnAzwHoldingAContainerGoesToTheKFXReader() throws {
        let url = try write(containerBytes, named: "sent.azw")
        XCTAssertThrowsError(try MOBIParser.prepareBook(url: url)) {
            XCTAssertEqual($0 as? KFXError, .notReadableYet)
        }
    }

    func testAnAzwOfARealMOBIStillReadsAsMOBI() throws {
        let book = try MOBIParser.prepareBook(url: copyOfFormatSample("mobi/pg1952-yellow-wallpaper.mobi", named: "kindle.azw"))
        XCTAssertEqual(book.title, "The Yellow Wallpaper")
    }

    func testAnAzwThatIsNeitherIsStillNotAKindleBook() throws {
        let url = try write(Array("A note, not a book.".utf8), named: "note.azw")
        XCTAssertThrowsError(try MOBIParser.prepareBook(url: url)) {
            XCTAssertEqual($0 as? MOBIError, .notAKindleBook)
        }
    }

    // MARK: - Containers not read yet

    func testAContainerIsRefusedUntilTheWalkExists() throws {
        let url = try write(containerBytes, named: "book.kfx")
        assertRefused(
            url, KFXError.notReadableYet,
            sentence: "This Kindle book is in the newer KFX format, which TextMouth can't read yet.")
    }

    func testAFileOfAnotherKindNamedKFXIsNotAKindleBook() throws {
        let url = try write(Array("not a container".utf8), named: "note.kfx")
        assertRefused(url, MOBIError.notAKindleBook, sentence: "This file is not a Kindle book that TextMouth can read.")
    }

    // MARK: - Sets and packages in a ZIP

    /// A ZIP holding `entries`, named `name`, in a sandbox folder.
    private func archive(_ entries: [TestZIPEntry], named name: String) throws -> URL {
        let made = try makeTemporaryZip(prefix: "kfx-set", orderedEntries: entries)
        addTeardownBlock { try? FileManager.default.removeItem(at: made) }
        let url = try makeSandboxDirectory("KFXZip").appendingPathComponent(name)
        try FileManager.default.copyItem(at: made, to: url)
        return url
    }

    func testASetWithAProtectedMemberIsRefusedWhicheverMemberItIs() throws {
        for order in [[0, 1], [1, 0]] {
            let members = [
                TestZIPEntry("Book.kfx", Data(containerBytes)),
                TestZIPEntry("Book_metadata.kfx", Data(protectedBytes)),
            ]
            let url = try archive(order.map { members[$0] }, named: "set.kfx-zip")
            assertRefused(url, MOBIError.copyProtected, sentence: Self.protectedSentence)
        }
    }

    func testASetHoldingAVoucherIsRefusedEvenWhenItsContainersLookPlain() throws {
        for voucher in ["voucher", "B0ABC.voucher", "Book.sdr/assets/voucher"] {
            let url = try archive([
                TestZIPEntry("Book.kfx", Data(containerBytes)),
                TestZIPEntry(voucher, Data("key".utf8)),
            ], named: "set.kfx-zip")
            assertRefused(url, MOBIError.copyProtected, sentence: Self.protectedSentence)
        }
    }

    func testAKindleCreatePackageIsRefusedWithItsOwnSentence() throws {
        let url = try archive([
            TestZIPEntry("book.kdf", Data("SQLite format 3\0".utf8)),
            TestZIPEntry("book.kcb", Data("{}".utf8)),
        ], named: "book.kpf")
        assertRefused(url, KFXError.kindleCreatePackage, sentence: Self.kindleCreateSentence)
    }

    func testAKindleCreatePackageIsNeverReadEvenWhenItsKdfIsProtected() throws {
        // The protection check comes first: a payload in it is never read.
        let url = try archive([TestZIPEntry("book.kdf", Data(protectedBytes))], named: "book.kpf")
        assertRefused(url, MOBIError.copyProtected, sentence: Self.protectedSentence)
    }

    func testASetOfPlainContainersIsRefusedUntilTheWalkExists() throws {
        let url = try archive([TestZIPEntry("Book.kfx", Data(containerBytes))], named: "set.kfx-zip")
        XCTAssertThrowsError(try KFXParser.prepareBook(url: url)) {
            XCTAssertEqual($0 as? KFXError, .notReadableYet)
        }
    }

    func testAZIPWithNoContainerIsNotAKindleBook() throws {
        let url = try archive([TestZIPEntry("readme.txt", Data("hello".utf8))], named: "other.kfx-zip")
        assertRefused(url, MOBIError.notAKindleBook, sentence: "This file is not a Kindle book that TextMouth can read.")
    }

    func testAnEmptyFileIsRefusedWithoutTrapping() throws {
        let url = try write([], named: "empty.kfx")
        XCTAssertThrowsError(try KFXParser.prepareBook(url: url))
    }

    // MARK: - The format

    func testKFXIsRecognizedByItsExtensions() {
        XCTAssertEqual(BookFormat.kfx.rawValue, "kfx")
        XCTAssertEqual(BookFormat.kfx.displayName, "Kindle Book (KFX)")
        XCTAssertEqual(BookFormat.kfx.fileExtensions, ["kfx", "kfx-zip", "azw8", "kpf"])
        for name in ["a.kfx", "a.KFX", "a.kfx-zip", "a.azw8", "a.kpf"] {
            XCTAssertEqual(BookFormat.detect(from: URL(fileURLWithPath: "/tmp/\(name)")), .kfx, name)
        }
        // An .azw file stays a MOBI-named file, read by its bytes.
        XCTAssertEqual(BookFormat.detect(from: URL(fileURLWithPath: "/tmp/a.azw")), .mobi)
    }

    func testThePanelOffersKFXBooks() {
        XCTAssertTrue(FileImportService.supportedTypes.contains { $0.identifier == "com.textmouth.kfx" })
    }

    func testImportingAProtectedKFXFailsWithTheProtectionSentence() throws {
        let url = try write(protectedBytes, named: "purchase.kfx")
        XCTAssertThrowsError(try FileImportService.importFileWithReport(from: url)) {
            XCTAssertTrue($0.localizedDescription.hasSuffix(Self.protectedSentence), $0.localizedDescription)
        }
    }
}
