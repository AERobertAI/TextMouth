#if os(macOS)
import PDFKit
import Security
import XCTest
import ZIPFoundation
@testable import TextMouth

/// Books unlocked for now (FR41): a protected book's plain form is held in
/// memory while a window has it open, the parsers read it from there, and
/// nothing is written. Fixtures: a PDF locked by PDFKit and a ZIP locked by
/// the `zip` tool macOS ships, each made in this test's own folder.
final class UnlockedSourcesTests: XCTestCase {

    /// The folder this test's files are made in.
    private var folder = FileManager.default.temporaryDirectory

    /// The words the fixtures hold.
    private let words = "The sluice gate opens at dawn."

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("UnlockedSourcesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A PDF holding `words`, locked with the user password "secret".
    private func lockedPDF() throws -> URL {
        let open = try PDFFixtures.makePDF(for: self) { context, _ in
            PDFFixtures.drawText(words, size: 14, at: CGPoint(x: 72, y: 700), in: context)
        }
        let document = try XCTUnwrap(PDFDocument(url: open))
        let url = folder.appendingPathComponent("Locked.pdf")
        XCTAssertTrue(document.write(to: url, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]))
        return url
    }

    /// A ZIP holding `notes.txt`, locked with ZipCrypto and the password "secret".
    private func lockedZIP() throws -> URL {
        let tool = "/usr/bin/zip"
        guard FileManager.default.isExecutableFile(atPath: tool) else { throw XCTSkip("zip is not here") }
        try words.write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let url = folder.appendingPathComponent("Locked.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-q", "-P", "secret", url.path, "notes.txt"]
        process.currentDirectoryURL = folder
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw XCTSkip("zip could not make the fixture") }
        return url
    }

    /// The names of the files in the test folder, to prove nothing was written.
    private func folderListing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    // MARK: - PDF

    /// A locked PDF is found, refused, unlocked with the password, read, and refused again once released.
    func testALockedPDFReadsOnlyWhileUnlocked() throws {
        let url = try lockedPDF()
        XCTAssertEqual(ProtectionDetector.scheme(ofFileAt: url, format: .pdf), .pdf)
        XCTAssertThrowsError(try PDFTextParser.extract(from: url, recognizer: nil)) {
            guard case .passwordProtected? = $0 as? PDFParserError else { return XCTFail("\($0)") }
        }
        let before = try folderListing()

        XCTAssertThrowsError(try UnlockedSources.unlock(fileAt: url, format: .pdf, password: Secret("wrong"))) {
            XCTAssertEqual($0 as? UnlockFailure, .wrongPassword)
        }
        XCTAssertFalse(UnlockedSources.isUnlocked(url))

        try UnlockedSources.unlock(fileAt: url, format: .pdf, password: Secret("secret"))
        let extraction = try PDFTextParser.extract(from: url, recognizer: nil)
        XCTAssertTrue(extraction.markdown.contains("sluice gate"), extraction.markdown)

        UnlockedSources.release(url)
        XCTAssertFalse(UnlockedSources.isUnlocked(url))
        XCTAssertThrowsError(try PDFTextParser.extract(from: url, recognizer: nil))
        XCTAssertEqual(try folderListing(), before, "nothing was written beside the book")
    }

    /// The owner password opens a PDF too.
    func testTheOwnerPasswordUnlocksAPDF() throws {
        let url = try lockedPDF()
        try UnlockedSources.unlock(fileAt: url, format: .pdf, password: Secret("owner"))
        UnlockedSources.release(url)
    }

    /// A PDF with no password has nothing to unlock.
    func testAnOpenPDFIsNotProtected() throws {
        let open = try PDFFixtures.makePDF(for: self) { context, _ in
            PDFFixtures.drawText(words, size: 14, at: CGPoint(x: 72, y: 700), in: context)
        }
        XCTAssertNil(ProtectionDetector.scheme(ofFileAt: open, format: .pdf))
        XCTAssertThrowsError(try UnlockedSources.unlock(fileAt: open, format: .pdf, password: Secret("x"))) {
            XCTAssertEqual($0 as? UnlockFailure, .notProtected)
        }
    }

    // MARK: - ZIP

    /// A locked ZIP is refused, then read from memory once unlocked, and refused again once released.
    func testALockedZIPReadsFromMemoryOnlyWhileUnlocked() throws {
        let url = try lockedZIP()
        XCTAssertEqual(ProtectionDetector.scheme(ofFileAt: url, format: .epub), .zip)
        XCTAssertThrowsError(try UnlockedSources.refuseIfLocked(at: url)) { XCTAssertTrue($0 is EncryptedArchiveError) }
        let before = try folderListing()

        XCTAssertThrowsError(try UnlockedSources.unlock(fileAt: url, format: .epub, password: Secret("nope"))) {
            XCTAssertEqual($0 as? UnlockFailure, .wrongPassword)
        }

        try UnlockedSources.unlock(fileAt: url, format: .epub, password: Secret("secret"))
        XCTAssertNoThrow(try UnlockedSources.refuseIfLocked(at: url))
        let archive = try UnlockedSources.openArchive(at: url)
        let entry = try XCTUnwrap(archive["notes.txt"])
        let bytes = try ArchiveEntryReader.read(entry, in: archive).data
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), words)

        UnlockedSources.release(url)
        XCTAssertThrowsError(try UnlockedSources.refuseIfLocked(at: url))
        XCTAssertEqual(try folderListing(), before, "nothing was written beside the book")
    }

    /// Two windows hold one book: it stays unlocked until the second lets go.
    func testTheLastWindowToCloseLocksTheBook() throws {
        let url = try lockedZIP()
        try UnlockedSources.unlock(fileAt: url, format: .epub, password: Secret("secret"))
        try UnlockedSources.unlock(fileAt: url, format: .epub, password: Secret("secret"))
        UnlockedSources.release(url)
        XCTAssertTrue(UnlockedSources.isUnlocked(url))
        UnlockedSources.release(url)
        XCTAssertFalse(UnlockedSources.isUnlocked(url))
        // A release with nothing held is harmless.
        UnlockedSources.release(url)
    }

    /// A format that no password locks is never reported protected.
    func testAFormatWithNoSchemeIsNeverProtected() throws {
        let url = try lockedZIP()
        XCTAssertNil(ProtectionDetector.scheme(ofFileAt: url, format: .txt))
    }

    /// The detector sees a file that was rewritten: what it kept goes with the old size and date.
    func testTheDetectorFollowsARewrittenFile() throws {
        let url = try lockedZIP()
        XCTAssertEqual(ProtectionDetector.scheme(ofFileAt: url, format: .epub), .zip)
        let plain = try makeTemporaryZip(prefix: "rewritten", entries: ["notes.txt": Data(words.utf8)])
        defer { try? FileManager.default.removeItem(at: plain) }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: plain)
        XCTAssertNil(ProtectionDetector.scheme(ofFileAt: url, format: .epub))
    }

    /// Write to File refuses a protected EPUB, even unlocked, and leaves the file byte for byte as it was.
    func testWriteToFileRefusesAProtectedEPUB() throws {
        let url = try lockedZIP()
        let before = try Data(contentsOf: url)
        try UnlockedSources.unlock(fileAt: url, format: .epub, password: Secret("secret"))
        defer { UnlockedSources.release(url) }
        let metadata = EPUBMetadata(title: "T", author: "A", publisher: "", publicationDate: "", isbn: "", language: "", identifier: "", epubVersion: "")
        XCTAssertThrowsError(try EPUBParser.writeMetadata(metadata, to: url)) { XCTAssertTrue($0 is PasswordProtectedDocument, "\($0)") }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try folderListing().filter { $0.hasSuffix(".epub") }, [], "no copy was left")
    }

    /// The detector's answer is kept by path, size, and date: asking for it without looking finds
    /// nothing before the first look, the kept answer after, and nothing once the file is rewritten.
    func testTheDetectorKeepsItsAnswerWithoutLookingAgain() throws {
        let url = try lockedZIP()
        XCTAssertNil(ProtectionDetector.keptScheme(ofFileAt: url))
        XCTAssertEqual(ProtectionDetector.scheme(ofFileAt: url, format: .epub), .zip)
        XCTAssertEqual(ProtectionDetector.keptScheme(ofFileAt: url), .zip)
        XCTAssertNil(ProtectionDetector.keptScheme(ofFileAt: folder.appendingPathComponent("gone.zip")))
        ProtectionDetector.forget(url)
        XCTAssertNil(ProtectionDetector.keptScheme(ofFileAt: url))
    }

    /// A copy a crash left in a package is deleted by its exact name, and nothing else is.
    func testALeftoverPlainCopyIsSweptAndNothingElse() throws {
        let leftover = folder.appendingPathComponent(ProtectionRemoval.temporaryPrefix + UUID().uuidString)
        let keeper = folder.appendingPathComponent("Book.pdf")
        try Data("plain".utf8).write(to: leftover)
        try Data("book".utf8).write(to: keeper)
        XCTAssertEqual(ProtectionRemoval.removeLeftovers(inPackageAt: folder), 1)
        XCTAssertEqual(try folderListing(), ["Book.pdf"])
    }

    /// The Keychain's list query follows the documented rules, which the in-memory fake cannot check:
    /// it asks for attributes, never for data together with every match (errSecParam for a password item),
    /// and it stays on this device's items.
    func testTheKeychainListQueryFollowsTheDocumentedRules() {
        let query = KeychainCredentialStore.listQuery()
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitAll as String)
        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertNil(query[kSecReturnData as String], "data with every match is not allowed for password items")
        XCTAssertEqual(query[kSecAttrService as String] as? String, KeychainCredentialStore.service)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
    }

    // MARK: - Secrets and the store

    /// A password never prints itself, however it is interpolated or dumped.
    func testASecretPrintsNothingOfItself() {
        let secret = Secret("hunter2")
        XCTAssertEqual("\(secret)", "redacted")
        XCTAssertFalse(String(reflecting: secret).contains("hunter2"))
        XCTAssertFalse("\(Optional(secret) as Any)".contains("hunter2"))
    }

    /// Wiping leaves nothing behind.
    func testWipingEmptiesASecret() {
        var secret = Secret("hunter2")
        secret.wipe()
        XCTAssertTrue(secret.isEmpty)
    }

    /// Hosted tests get the in-memory store, so none can reach the Keychain.
    func testHostedTestsUseTheInMemoryStore() {
        XCTAssertTrue(CredentialStores.current is InMemoryCredentialStore)
    }

    /// The store remembers by book, replaces, forgets, and lists newest first.
    func testTheStoreKeepsPasswordsNewestFirst() {
        let store = InMemoryCredentialStore()
        store.remember(Secret("one"), forBook: "a")
        store.remember(Secret("two"), forBook: "b")
        store.remember(Secret("three"), forBook: "a")
        XCTAssertEqual(store.password(forBook: "a"), Secret("three"))
        XCTAssertEqual(store.rememberedPasswords(), [Secret("three"), Secret("two")])
        store.forget(forBook: "a")
        XCTAssertNil(store.password(forBook: "a"))
        XCTAssertEqual(store.rememberedPasswords(), [Secret("two")])
    }

    /// A test's own store is used until it puts the default back.
    func testATestCanReplaceTheStore() {
        let mine = InMemoryCredentialStore()
        let restore = CredentialStores.use(mine)
        XCTAssertTrue(CredentialStores.current as AnyObject === mine)
        restore()
        XCTAssertFalse(CredentialStores.current as AnyObject === mine)
    }

    /// Each scheme gets the encodings it can use, composed and decomposed, without repeats.
    func testPasswordEncodingsCoverTheForms() {
        let secret = Secret("p\u{E4}ss")
        let zip = PasswordEncoding.candidates(for: secret, scheme: .zipCrypto)
        XCTAssertTrue(zip.contains(Array("p\u{E4}ss".utf8)))
        XCTAssertTrue(zip.contains(Array("pa\u{308}ss".utf8)))
        XCTAssertTrue(zip.contains([0x70, 0xE4, 0x73, 0x73]), "Latin-1")
        XCTAssertEqual(Set(zip).count, zip.count)
        XCTAssertEqual(PasswordEncoding.candidates(for: Secret("ab"), scheme: .utf16LittleEndian), [[0x61, 0x00, 0x62, 0x00]])
        XCTAssertEqual(PasswordEncoding.candidates(for: Secret("ab"), scheme: .utf8), [[0x61, 0x62]])
    }
}
#endif
