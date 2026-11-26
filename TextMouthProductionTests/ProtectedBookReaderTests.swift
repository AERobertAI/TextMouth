#if os(macOS)
import Combine
import PDFKit
import XCTest
@testable import TextMouth

/// A reader of a password-protected book (FR41): it asks for the password in
/// place of the book, says aloud when one is wrong and keeps the person at
/// the field, opens with a remembered password without asking, reads the
/// book from memory, writes nothing, and lets go of the plain book when it
/// closes. The PDF is locked by PDFKit in this test's own folder, and the
/// credential store is the in-memory one, so no test touches the Keychain.
@MainActor
final class ProtectedBookReaderTests: XCTestCase {

    /// The folder holding the book, and only the book.
    private var folder = FileManager.default.temporaryDirectory
    /// The locked PDF's book row.
    private var book = Book(title: "", format: .pdf, filePath: "/Users/reader/none.pdf", md5Hash: "none")
    /// What was in the folder when the book was made.
    private var listingAtStart: [String] = []
    /// The store this test uses, in memory.
    private let store = InMemoryCredentialStore()
    /// Puts the default store back.
    private var restoreStore: (() -> Void)?
    /// The announcements made before the test, so only its own are read.
    private var announcementsBefore = 0

    /// Makes the book and puts the in-memory store in use; each test begins
    /// with it (a main-actor setUp is not available to a main-actor class).
    private func prepare() throws {
        restoreStore = CredentialStores.use(store)
        addTeardownBlock { @MainActor [weak self] in self?.restoreStore?() }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProtectedBookReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let open = try PDFFixtures.makePDF(for: self) { context, _ in
            PDFFixtures.drawText("The sluice gate opens at dawn.", size: 14, at: CGPoint(x: 72, y: 700), in: context)
        }
        let url = folder.appendingPathComponent("Sluice Notes.pdf")
        let document = try XCTUnwrap(PDFDocument(url: open))
        XCTAssertTrue(document.write(to: url, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]))
        book = Book(title: "Sluice Notes", format: .pdf, filePath: url.path, md5Hash: "hash-\(UUID().uuidString)")
        listingAtStart = try listing()
        announcementsBefore = VoiceOverAnnouncer.recordedAnnouncements.count
    }

    /// The names in the folder.
    private func listing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// A reader of `book`, closed when the test ends.
    private func makeReader() -> ReaderViewModel {
        let library = LibraryViewModel()
        library.library = Library(books: [book])
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        )
        addTeardownBlock { @MainActor in reader.close() }
        return reader
    }

    /// Waits until `condition` holds of `reader`, checked at each change it publishes.
    private func wait(for reader: ReaderViewModel, _ description: String, until condition: @escaping (ReaderViewModel) -> Bool) {
        if condition(reader) { return }
        let reached = expectation(description: description)
        reached.assertForOverFulfill = false
        let watch = reader.objectWillChange.sink { _ in
            // The change is published before it is made: look on the next turn.
            DispatchQueue.main.async { if condition(reader) { reached.fulfill() } }
        }
        wait(for: [reached], timeout: 30)
        watch.cancel()
    }

    // MARK: - The Prompt

    /// A locked book shows the password panel, not the book, and reads nothing.
    func testALockedBookAsksForItsPassword() {
        XCTAssertNoThrow(try prepare())
        let reader = makeReader()
        wait(for: reader, "the prompt") { $0.unlockPrompt != nil }
        XCTAssertNil(reader.content)
        XCTAssertNil(reader.loadErrorMessage, "a locked book is asked about, not failed")
        XCTAssertFalse(UnlockedSources.isUnlocked(book.bookFileURL))
    }

    /// A wrong password is said aloud and shown, the field is asked to take focus again, and the book stays locked.
    func testAWrongPasswordIsSaidAndKeepsTheField() {
        XCTAssertNoThrow(try prepare())
        let reader = makeReader()
        wait(for: reader, "the prompt") { $0.unlockPrompt != nil }
        reader.submitUnlock(UnlockChoice(password: Secret("nope"), remember: true, removePassword: false))
        wait(for: reader, "the refusal") { $0.unlockPrompt?.failure != nil }
        XCTAssertEqual(reader.unlockPrompt?.failure, ProtectionWording.wrongPassword)
        XCTAssertEqual(reader.unlockPrompt?.wrongAttempts, 1)
        XCTAssertEqual(reader.unlockPrompt?.isWorking, false, "the field can be tried again")
        XCTAssertNil(reader.content)
        XCTAssertNil(store.password(forBook: book.md5Hash), "a wrong password is never remembered")
        let spoken = VoiceOverAnnouncer.recordedAnnouncements.dropFirst(announcementsBefore).map(\.message)
        XCTAssertTrue(spoken.contains(ProtectionWording.wrongPassword), "\(spoken)")
    }

    // MARK: - Unlocking

    /// The right password loads the book from memory, remembers the password, and writes nothing.
    func testTheRightPasswordOpensTheBookAndWritesNothing() throws {
        try prepare()
        let reader = makeReader()
        wait(for: reader, "the prompt") { $0.unlockPrompt != nil }
        reader.submitUnlock(UnlockChoice(password: Secret("secret"), remember: true, removePassword: false))
        wait(for: reader, "the book") { $0.content != nil }
        XCTAssertNil(reader.unlockPrompt)
        let text = reader.content?.chapters.map(\.text).joined() ?? ""
        XCTAssertTrue(text.contains("sluice gate"), text)
        XCTAssertEqual(store.password(forBook: book.md5Hash), Secret("secret"))
        XCTAssertEqual(try listing(), listingAtStart, "nothing was written beside the book")
        let spoken = VoiceOverAnnouncer.recordedAnnouncements.dropFirst(announcementsBefore).map(\.message)
        XCTAssertTrue(spoken.contains(ProtectionWording.unlocked), "\(spoken)")
    }

    /// With Remember off, the password is not kept.
    func testRememberOffKeepsNothing() {
        XCTAssertNoThrow(try prepare())
        let reader = makeReader()
        wait(for: reader, "the prompt") { $0.unlockPrompt != nil }
        reader.submitUnlock(UnlockChoice(password: Secret("secret"), remember: false, removePassword: false))
        wait(for: reader, "the book") { $0.content != nil }
        XCTAssertNil(store.password(forBook: book.md5Hash))
        XCTAssertTrue(store.rememberedPasswords().isEmpty)
    }

    /// A remembered password opens the book at once, with no prompt, and another book's remembered password serves too.
    func testARememberedPasswordOpensWithoutAsking() {
        XCTAssertNoThrow(try prepare())
        store.remember(Secret("other"), forBook: "another-book")
        store.remember(Secret("secret"), forBook: "a-third-book")
        let reader = makeReader()
        wait(for: reader, "the book") { $0.content != nil }
        XCTAssertNil(reader.unlockPrompt)
    }

    /// Closing the last reader locks the book again, and the reader itself drops its hold once.
    func testClosingTheReaderLocksTheBookAgain() {
        XCTAssertNoThrow(try prepare())
        let reader = makeReader()
        wait(for: reader, "the prompt") { $0.unlockPrompt != nil }
        reader.submitUnlock(UnlockChoice(password: Secret("secret"), remember: false, removePassword: false))
        wait(for: reader, "the book") { $0.content != nil }
        XCTAssertTrue(UnlockedSources.isUnlocked(book.bookFileURL))
        reader.close()
        XCTAssertFalse(UnlockedSources.isUnlocked(book.bookFileURL))
        XCTAssertTrue(book.isLocked)
    }

    // MARK: - Removing the Password

    /// Remove the password rewrites the book's own file, in place, with no second copy,
    /// and the book is an ordinary book afterwards that opens without a password.
    func testRemovingThePasswordRewritesTheFileInPlace() throws {
        try prepare()
        let reader = makeReader()
        wait(for: reader, "the prompt") { $0.unlockPrompt != nil }
        reader.submitUnlock(UnlockChoice(password: Secret("secret"), remember: true, removePassword: true))
        wait(for: reader, "the book") { $0.content != nil }
        XCTAssertEqual(try listing(), listingAtStart, "the same one file, and no copy")
        XCTAssertNil(ProtectionDetector.scheme(ofFileAt: book.bookFileURL, format: .pdf))
        XCTAssertFalse(book.isPasswordProtected)
        XCTAssertNil(store.password(forBook: book.md5Hash), "a book with no password has none to remember")
        let document = try XCTUnwrap(PDFDocument(url: book.bookFileURL))
        XCTAssertFalse(document.isLocked)
        XCTAssertTrue(document.string?.contains("sluice gate") == true)
    }

    // MARK: - The Backstops

    /// A locked book asked for its text by any other reader is refused, and writes no cache.
    func testALockedBookIsRefusedByTheAnalysisAndGetsNoCache() throws {
        try prepare()
        XCTAssertThrowsError(try BookContentAnalysisService.load(book: book)) { XCTAssertTrue($0 is BookLockedError) }
        XCTAssertEqual(try listing(), listingAtStart)
        XCTAssertNil(try MarkdownCacheService.generateReportedCacheContent(for: book))
    }

    /// The launch passes leave a protected book out.
    func testBackgroundPassesSkipAProtectedBook() {
        XCTAssertNoThrow(try prepare())
        let protected = Book(title: book.title, format: .pdf, filePath: book.filePath, md5Hash: book.md5Hash, tmbDirectoryName: "Sluice.tmb")
        XCTAssertFalse(LibraryViewModel.needsMetadataRefresh(protected))
        XCTAssertTrue(LibraryViewModel.booksNeedingCacheUpdate([protected], access: .live).isEmpty)
        XCTAssertNil(try? MarkdownCacheService.generateReportedCacheContent(for: protected))
    }
}
#endif
