import Foundation
import SwiftUI

// MARK: - Asking for Passwords Before Books Are Added (FR41)

/// The question the library asks when books being added are protected by a
/// password: one panel for all of them, a password tried against each, and
/// the answer Import Locked to add them without. The import itself reads
/// nothing of a protected book either way (`FileImportService.publishLockedBook`);
/// what a password typed here does is remember it, so each book opens
/// without asking.
struct ImportPasswordRequest: Identifiable {
    /// One protected file waiting for a password.
    struct File: Equatable {
        /// The file chosen.
        let url: URL
        /// The format it is read as.
        let format: BookFormat
        /// The checksum the import will know the book by, which a remembered
        /// password is kept under.
        let key: String
    }

    let id = UUID()
    /// The protected files no password has opened yet.
    var remaining: [File]
    /// How the attempts have gone.
    var state = UnlockPromptState()
    /// Carries on with the import of everything chosen.
    let proceed: @MainActor () -> Void
}

extension LibraryViewModel {

    /// The protected files among `urls`: each a plain file in a format a
    /// password can lock, found by looking at it. A folder, a ZIP archive
    /// of books, and a package are not looked into here.
    nonisolated static func protectedFiles(in urls: [URL]) -> [ImportPasswordRequest.File] {
        urls.compactMap { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  url.pathExtension.lowercased() != "zip",
                  let format = BookFormat.detect(from: url),
                  ProtectionDetector.scheme(ofFileAt: url, format: format) != nil,
                  let key = try? FileImportService.importHash(of: url) else { return nil }
            return ImportPasswordRequest.File(url: url, format: format, key: key)
        }
    }

    /// Asks about the protected files among `urls` before they are added.
    /// - Parameter proceed: Carries on with the import, once the person has
    ///   answered; never called when they cancel.
    /// - Returns: Whether a question was asked, so the caller waits for `proceed`.
    @MainActor
    func askForPasswordsBeforeImporting(_ urls: [URL], proceed: @escaping @MainActor () -> Void) -> Bool {
        // The iPhone has no Library window to ask in: its books come in
        // locked, and are unlocked in the reader, which asks.
        #if os(iOS)
        return false
        #else
        let files = Self.protectedFiles(in: urls)
        guard !files.isEmpty, importPasswordRequest == nil else { return false }
        importPasswordRequest = ImportPasswordRequest(remaining: files, proceed: proceed)
        VoiceOverAnnouncer.announce(ProtectionWording.importHeading)
        return true
        #endif
    }

    /// Tries the password the person typed against each protected file still
    /// waiting. The books it opens have it remembered when asked; the import
    /// carries on once none is left, and a password that fits only some says so.
    @MainActor
    func submitImportPassword(_ choice: UnlockChoice) {
        guard var request = importPasswordRequest, !request.state.isWorking else { return }
        request.state.isWorking = true
        request.state.failure = nil
        importPasswordRequest = request
        let files = request.remaining
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Opening is the check: a book that opens is let go at once, since
            // nothing is read here.
            let opened = files.filter { file in
                guard (try? UnlockedSources.unlock(fileAt: file.url, format: file.format, password: choice.password)) != nil else { return false }
                UnlockedSources.release(file.url)
                return true
            }
            DispatchQueue.main.async {
                self?.finishImportPassword(choice: choice, opened: opened)
            }
        }
    }

    /// What follows an attempt against the waiting files.
    @MainActor
    private func finishImportPassword(choice: UnlockChoice, opened: [ImportPasswordRequest.File]) {
        var choice = choice
        defer { choice.password.wipe() }
        guard var request = importPasswordRequest else { return }
        if choice.remember {
            for file in opened { CredentialStores.current.remember(choice.password, forBook: file.key) }
        }
        request.remaining.removeAll { file in opened.contains(file) }
        request.state.isWorking = false
        guard request.remaining.isEmpty else {
            request.state.wrongAttempts += 1
            request.state.failure = opened.isEmpty ? ProtectionWording.wrongPassword : ProtectionWording.partlyOpened
            importPasswordRequest = request
            VoiceOverAnnouncer.announce(request.state.failure ?? "")
            return
        }
        importPasswordRequest = nil
        VoiceOverAnnouncer.announce(ProtectionWording.unlocked)
        request.proceed()
    }

    /// Import Locked: adds the books as they are, with whatever is still locked.
    @MainActor
    func importProtectedBooksLocked() {
        guard let request = importPasswordRequest, !request.state.isWorking else { return }
        importPasswordRequest = nil
        request.proceed()
    }

    /// Cancel: nothing is added.
    @MainActor
    func cancelProtectedImport() {
        importPasswordRequest = nil
    }
}

// MARK: - After a Password Is Taken Off

extension LibraryViewModel {
    /// The row of the book whose file lost its password becomes the row of a
    /// new book: the checksum of the file it is now, no password kept for the
    /// file it was, and the metadata reader's version cleared so the next
    /// refresh reads its real title and author (FR41). A device that syncs
    /// the plain copy then finds a book that is not the protected one.
    @MainActor
    func passwordWasRemoved(bookID: UUID, oldHash: String, newHash: String?) {
        // Unless another copy of the same file is in the library, which still needs it.
        if !library.books.contains(where: { $0.id != bookID && $0.md5Hash == oldHash }) {
            CredentialStores.current.forget(forBook: oldHash)
        }
        guard let index = library.books.firstIndex(where: { $0.id == bookID }) else { return }
        if let newHash { library.books[index].md5Hash = newHash }
        library.books[index].metadataReaderVersion = nil
        let updated = library.books[index]
        save()
        LibraryPersistenceService.saveBookInfo(for: updated)
    }
}

// MARK: - Leftovers of a Password Removal

extension LibraryViewModel {
    /// Deletes, in the background, the plain copies a crash left in a
    /// package while a password was being removed (FR41).
    func sweepPasswordRemovalLeftovers() {
        let packages = library.books.filter { !$0.tmbDirectoryName.isEmpty }.map(\.tmbDirectory)
        DispatchQueue.global(qos: .utility).async {
            for package in packages { ProtectionRemoval.removeLeftovers(inPackageAt: package) }
        }
    }

    /// Looks, in the background, at every book's file for a password, so the
    /// launch's passes and the list find the answers kept (they are saved
    /// in this Mac's caches, so a later launch looks only at files that
    /// changed), and then redraws the list for the "Locked" rows (FR41).
    func lookForProtectedBooks() {
        let books = library.books
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found = false
            for book in books where book.protectionScheme != nil { found = true }
            guard found else { return }
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }
}

// MARK: - The Panel in the Library Window

extension View {
    /// Shows the question about protected books being added, as a sheet.
    func importPasswordSheet(for libraryViewModel: LibraryViewModel) -> some View {
        modifier(ImportPasswordPresenter(libraryViewModel: libraryViewModel))
    }
}

/// Presents `LibraryViewModel.importPasswordRequest` as a sheet over the
/// Library window, with Import Locked beside Unlock.
private struct ImportPasswordPresenter: ViewModifier {
    @ObservedObject var libraryViewModel: LibraryViewModel

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { libraryViewModel.importPasswordRequest != nil },
            // Only an answer settles it, as with the import questions.
            set: { _ in }
        )) {
            if let request = libraryViewModel.importPasswordRequest {
                UnlockBookPanel(
                    heading: ProtectionWording.importHeading,
                    explanation: ProtectionWording.importExplanation,
                    offersRemoval: false,
                    importLocked: { libraryViewModel.importProtectedBooksLocked() },
                    state: request.state,
                    onUnlock: { libraryViewModel.submitImportPassword($0) },
                    onCancel: { libraryViewModel.cancelProtectedImport() }
                )
                .id(request.id)
            }
        }
    }
}
