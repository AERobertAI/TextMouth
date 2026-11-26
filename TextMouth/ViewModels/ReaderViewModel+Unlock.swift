import Foundation

// MARK: - Opening a Protected Book (FR41)

extension ReaderViewModel {

    /// Starts unlocking the book before it is read: every password this
    /// device remembers is tried first, the book's own and then the others,
    /// newest first (books from one source often share a password), and the
    /// person is asked only when none opens it. Runs off the main thread,
    /// since a large archive takes a moment to open.
    func beginUnlocking() {
        isLoading = true
        let book = self.book
        loadQueue.async { [weak self] in
            let opened = Self.openWithRememberedPassword(book)
            DispatchQueue.main.async {
                guard let self else {
                    if opened { UnlockedSources.release(book.bookFileURL) }
                    return
                }
                guard !self.hasClosed else {
                    if opened { UnlockedSources.release(book.bookFileURL) }
                    return
                }
                if opened {
                    self.holdsUnlockedBook = true
                    self.unlockPrompt = nil
                    self.loadContent()
                } else {
                    // Ask: the panel takes the place of the book.
                    self.unlockPrompt = UnlockPromptState()
                    self.isLoading = false
                    self.announceToVoiceOver(ProtectionWording.heading(title: book.title))
                }
            }
        }
    }

    /// Opens `book` with a remembered password, if one fits: its own first,
    /// then every other. Nothing is asked and nothing is said.
    /// - Returns: Whether the book is now unlocked for this reader, holding it once.
    nonisolated static func openWithRememberedPassword(_ book: Book) -> Bool {
        let store = CredentialStores.current
        var candidates: [Secret] = []
        if let own = store.password(forBook: book.md5Hash) { candidates.append(own) }
        for secret in store.rememberedPasswords() where !candidates.contains(secret) { candidates.append(secret) }
        for var candidate in candidates {
            defer { candidate.wipe() }
            do {
                try UnlockedSources.unlock(fileAt: book.bookFileURL, format: book.format, password: candidate)
                return true
            } catch UnlockFailure.wrongPassword {
                continue
            } catch {
                // Damaged, unsupported, or not protected: no password helps.
                return false
            }
        }
        return false
    }

    /// Tries the password the person typed (the panel's Unlock). A wrong one
    /// says so, aloud and in a line of text, and leaves the field focused.
    func submitUnlock(_ choice: UnlockChoice) {
        guard var prompt = unlockPrompt, !prompt.isWorking else { return }
        prompt.isWorking = true
        prompt.failure = nil
        unlockPrompt = prompt
        announceToVoiceOver(ProtectionWording.unlocking)
        let book = self.book
        loadQueue.async { [weak self] in
            var outcome: Result<Void, UnlockFailure> = .success(())
            do {
                try UnlockedSources.unlock(fileAt: book.bookFileURL, format: book.format, password: choice.password)
            } catch let failure as UnlockFailure {
                outcome = .failure(failure)
            } catch {
                outcome = .failure(.damaged)
            }
            let finished = outcome
            DispatchQueue.main.async {
                self?.finishUnlock(finished, choice: choice, book: book)
            }
        }
    }

    /// What follows an attempt: on success, the password is remembered when
    /// asked (unless it is being taken off the book), the password is
    /// removed when asked, and the book loads; on failure, the panel says why.
    private func finishUnlock(_ outcome: Result<Void, UnlockFailure>, choice: UnlockChoice, book: Book) {
        var choice = choice
        defer { choice.password.wipe() }
        guard !hasClosed else {
            if case .success = outcome { UnlockedSources.release(book.bookFileURL) }
            return
        }
        switch outcome {
        case .success:
            holdsUnlockedBook = true
            unlockPrompt = nil
            // The library's row stops saying "Locked".
            libraryViewModel.objectWillChange.send()
            // Remembered first, even when the password is about to come off,
            // so a removal that fails leaves the book with its password saved.
            var kept = true
            if choice.remember { kept = CredentialStores.current.remember(choice.password, forBook: book.md5Hash) }
            if choice.removePassword {
                removePasswordThenLoad(passwordWasKept: kept)
            } else {
                announceToVoiceOver(kept ? ProtectionWording.unlocked : ProtectionWording.rememberFailed)
                loadContent()
            }
        case .failure(let failure):
            var prompt = unlockPrompt ?? UnlockPromptState()
            prompt.isWorking = false
            switch failure {
            case .wrongPassword:
                prompt.failure = ProtectionWording.wrongPassword
                prompt.wrongAttempts += 1
            case .unsupported:
                prompt.failure = ProtectionWording.unsupported
            case .damaged, .notProtected:
                prompt.failure = ProtectionWording.damaged
            }
            unlockPrompt = prompt
            announceToVoiceOver(prompt.failure ?? "")
        }
    }

    /// Rewrites the book's file without its password, then loads the book as
    /// any other. A write that fails leaves the file as it was and the book
    /// unlocked for now, which loads as usual.
    private func removePasswordThenLoad(passwordWasKept: Bool) {
        let book = self.book
        loadQueue.async { [weak self] in
            let removed = (try? ProtectionRemoval.removePassword(fromFileAt: book.bookFileURL, format: book.format)) != nil
            // The book is a new file now: it is known by its new checksum.
            let newHash = removed ? try? FileImportService.importHash(of: book.bookFileURL) : nil
            DispatchQueue.main.async {
                guard let self, !self.hasClosed else { return }
                if removed {
                    // An ordinary book now: nothing needs holding, and no
                    // password is kept for the file it was.
                    self.releaseUnlockedBook()
                    self.libraryViewModel.passwordWasRemoved(bookID: book.id, oldHash: book.md5Hash, newHash: newHash)
                    if let newHash { self.book.md5Hash = newHash }
                    self.book.metadataReaderVersion = nil
                    self.announceToVoiceOver(ProtectionWording.removed)
                } else {
                    self.announceToVoiceOver(ProtectionWording.removeFailed)
                }
                self.loadContent()
            }
        }
    }

    /// Lets go of this reader's hold on its book's plain form; the last
    /// window to close frees it. Called when the reader closes.
    func releaseUnlockedBook() {
        guard holdsUnlockedBook else { return }
        holdsUnlockedBook = false
        UnlockedSources.release(book.bookFileURL)
        // The row says "Locked" again once the last window lets go.
        libraryViewModel.objectWillChange.send()
    }
}
