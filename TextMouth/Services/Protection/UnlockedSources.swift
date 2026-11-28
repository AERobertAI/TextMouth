import Foundation
import os
import PDFKit
import ZIPFoundation

// MARK: - Schemes

/// The password schemes TextMouth opens (FR41): which kind of protection a
/// book's own file has, found by looking at the file and never by asking for
/// the password. DRM is not here: it is refused where each format is read.
enum ProtectionScheme: String, Sendable, Equatable {
    /// A ZIP archive whose entries are encrypted (ZipCrypto or WinZip AES),
    /// and every format inside one: EPUB, DAISY, comic archives, DOCX or
    /// ODT zipped with a password.
    case zip
    /// A PDF with a user password.
    case pdf
    /// A Word document (and its kinds) saved with a password: not a ZIP but
    /// a compound file holding an encrypted package (`OfficeCryptoDecryptor`).
    case officeOpenXML
}

// MARK: - Detection

/// Whether a book's file is protected by a password, by looking at the file.
/// The checks read little (a ZIP's central directory, a PDF's header), and
/// each answer is kept by the file's path, size, and date, so a library of
/// thousands is looked at once. Nothing is stored in a book's record: the
/// record and `library.json` keep their formats, and an older TextMouth
/// reads the same files without a surprise.
enum ProtectionDetector {

    /// What was found for a file at one size and date. Kept in this Mac's
    /// caches between launches, so a library is looked at once, not at
    /// every launch (the file is looked at again when its size or date
    /// changes).
    private struct Remembered: Codable {
        var size: UInt64
        var date: TimeInterval
        var scheme: String?
    }

    /// The answers kept, by file path, read from this Mac's caches the
    /// first time they are asked for.
    private static let remembered = OSAllocatedUnfairLock<[String: Remembered]>(initialState: [:])

    /// Whether the saved answers have been read into `remembered`. They are
    /// read by the first look (`scheme(ofFileAt:format:)`), which runs off
    /// the main thread at launch, never by a list.
    private static let loaded = OSAllocatedUnfairLock(initialState: false)

    /// Reads the saved answers once.
    private static func ensureLoaded() {
        let first = loaded.withLock { done -> Bool in
            let was = !done
            done = true
            return was
        }
        guard first else { return }
        let saved = loadRemembered()
        remembered.withLock { current in current.merge(saved) { fresh, _ in fresh } }
    }

    /// The file the answers are kept in.
    private static var rememberedFile: URL {
        MachineLocalPaths.caches.appendingPathComponent("ProtectionLooks.json")
    }

    /// The answers saved by an earlier launch, or none.
    private static func loadRemembered() -> [String: Remembered] {
        guard let data = try? Data(contentsOf: rememberedFile),
              let saved = try? JSONDecoder().decode([String: Remembered].self, from: data) else { return [:] }
        return saved
    }

    /// Whether a save of the answers is already waiting.
    private static let saveWaiting = OSAllocatedUnfairLock(initialState: false)

    /// Saves the answers a few seconds from now, once for every look made
    /// meanwhile. A cache that cannot be written is only slower next launch.
    private static func saveSoon() {
        guard !saveWaiting.withLock({ waiting -> Bool in
            let was = waiting
            waiting = true
            return was
        }) else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            saveWaiting.withLock { $0 = false }
            let snapshot = remembered.withLock { $0 }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: MachineLocalPaths.caches, withIntermediateDirectories: true)
            try? data.write(to: rememberedFile, options: .atomic)
        }
    }

    /// The size and date a file's answer is kept against, or nil.
    private static func stamp(of url: URL) -> (size: UInt64, date: TimeInterval)? {
        guard !DatalessFiles.isDataless(url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.standardizedFileURL.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let date = attributes[.modificationDate] as? Date else { return nil }
        return (size, date.timeIntervalSinceReferenceDate)
    }

    /// The answer kept for the file at `url`: a lookup in memory, with no
    /// stat and no file read, for a list that must not wait on anything
    /// (nil when none is kept, which reads as no password until the
    /// background look has made its pass). A file replaced since is
    /// corrected by that pass (and at once by `forget(_:)` for a removal).
    static func keptScheme(ofFileAt url: URL) -> ProtectionScheme? {
        remembered.withLock { $0[url.standardizedFileURL.path] }?.scheme.flatMap(ProtectionScheme.init(rawValue:))
    }

    /// The formats whose file is a ZIP archive that a password can lock.
    private static let zipFormats: Set<BookFormat> = [.epub, .daisy, .comic, .kfx, .docx, .odt]

    /// The scheme protecting the file at `url`, read as `format`, or nil when
    /// it has no password (or cannot be looked at). Whether it is unlocked
    /// for now does not matter here (`UnlockedSources.isUnlocked`).
    static func scheme(ofFileAt url: URL, format: BookFormat) -> ProtectionScheme? {
        guard format == .pdf || zipFormats.contains(format) else { return nil }
        // (A .docx may be a ZIP archive with a password or an encrypted package.)
        let path = url.standardizedFileURL.path
        // A file that is only in the cloud is not looked at: any read would
        // download it. It is looked at once it is here.
        ensureLoaded()
        guard let stamp = stamp(of: url) else { return nil }
        if let known = remembered.withLock({ $0[path] }), known.size == stamp.size, known.date == stamp.date {
            return known.scheme.flatMap(ProtectionScheme.init(rawValue:))
        }
        let found = DatalessFiles.withoutDownloading { look(at: url, format: format) }
        remembered.withLock { $0[path] = Remembered(size: stamp.size, date: stamp.date, scheme: found?.rawValue) }
        saveSoon()
        return found
    }

    /// The scheme of the file, looked at afresh.
    private static func look(at url: URL, format: BookFormat) -> ProtectionScheme? {
        if format == .pdf {
            // A PDF needs a password to open only with a user password; one
            // that restricts only copying or printing opens and reads as usual.
            return PDFDocument(url: url)?.isLocked == true ? .pdf : nil
        }
        if !EncryptedArchiveGuard.encryptedNames(inFileAt: url).isEmpty { return .zip }
        // A password-protected Word document is a compound file, not a ZIP.
        if format == .docx, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           OfficeCryptoDecryptor.isEncryptedPackage(data) {
            return .officeOpenXML
        }
        return nil
    }

    /// Whether the file at `url`, read as `format`, is protected by a
    /// password: unlocked for now, or found so by a look. A file unlocked for
    /// now is protected whatever a look says meanwhile, since only a
    /// protected file is ever unlocked (`UnlockedSources.unlock`) and its
    /// plain form is in memory: a look that finds nothing while it is open
    /// (its file only in the cloud, replaced by a sync, or not readable for
    /// a moment) can never let that plain form be written to a file.
    static func isProtected(fileAt url: URL, format: BookFormat) -> Bool {
        UnlockedSources.isUnlocked(url) || scheme(ofFileAt: url, format: format) != nil
    }

    /// Forgets what was found about the file at `url`, after it was rewritten.
    static func forget(_ url: URL) {
        remembered.withLock { _ = $0.removeValue(forKey: url.standardizedFileURL.path) }
        saveSoon()
    }
}

// MARK: - Unlocked for Now

/// Why a book could not be unlocked.
enum UnlockFailure: Error, Equatable {
    /// The password does not fit.
    case wrongPassword
    /// The file uses a scheme TextMouth does not open (strong encryption, a
    /// provider outside TextMouth).
    case unsupported
    /// The file is damaged.
    case damaged
    /// The file has no password.
    case notProtected
}

/// The books unlocked for now: what a reader window holds while a protected
/// book is open, and nothing else (FR41, question 1). A ZIP's plain bytes
/// and a PDF's password live here in memory, by the book's file path, and
/// the parsers ask here before they open a file; the last window of a book
/// to close lets go of it, and nothing was written.
enum UnlockedSources {

    /// What is held for one book.
    private enum Held {
        /// The plain ZIP archive made from a protected one.
        case archive(Data)
        /// The password of a PDF, for `unlock(withPassword:)`.
        case pdfPassword(Secret)
    }

    /// A held source and how many windows hold it.
    private struct Entry {
        var held: Held
        var holders: Int
    }

    /// Everything held, by standardized file path.
    private static let entries = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

    /// The key of the file at `url`.
    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    // MARK: Unlocking

    /// Opens the protected book at `url` with `password` and holds its plain
    /// form until `release(_:)` has been called as often as this has.
    /// - Throws: `UnlockFailure`.
    static func unlock(fileAt url: URL, format: BookFormat, password: Secret) throws {
        guard let scheme = ProtectionDetector.scheme(ofFileAt: url, format: format) else {
            // A book that is not protected holds nothing, and needs nothing.
            throw UnlockFailure.notProtected
        }
        let held: Held
        switch scheme {
        case .zip:
            do {
                held = .archive(try ZipDecryptor.decrypt(archiveAt: url, password: password))
            } catch let failure as ZipDecryptor.Failure {
                switch failure {
                case .wrongPassword: throw UnlockFailure.wrongPassword
                case .unsupported: throw UnlockFailure.unsupported
                case .damaged: throw UnlockFailure.damaged
                }
            }
        case .officeOpenXML:
            do {
                // Held to the document limit every reader takes (64 MB).
                let file = try DocumentByteLimit.contents(of: url)
                held = .archive(try OfficeCryptoDecryptor.decrypt(file, password: password))
            } catch let failure as OfficeCryptoDecryptor.Failure {
                switch failure {
                case .wrongPassword: throw UnlockFailure.wrongPassword
                case .unsupported: throw UnlockFailure.unsupported
                case .damaged: throw UnlockFailure.damaged
                }
            } catch is DocumentTooLargeError {
                throw UnlockFailure.unsupported
            } catch {
                throw UnlockFailure.damaged
            }
        case .pdf:
            guard let document = PDFDocument(url: url) else { throw UnlockFailure.damaged }
            // As typed, then decomposed: a PDF's password was composed or not by its writer.
            let typed = password.text
            let forms = [typed, typed.decomposedStringWithCanonicalMapping, typed.precomposedStringWithCanonicalMapping]
            guard let working = forms.first(where: { document.unlock(withPassword: $0) }) else { throw UnlockFailure.wrongPassword }
            held = .pdfPassword(Secret(working))
        }
        entries.withLock { all in
            let path = key(url)
            if var existing = all[path] {
                existing.held = held
                existing.holders += 1
                all[path] = existing
            } else {
                all[path] = Entry(held: held, holders: 1)
            }
        }
    }

    /// Lets go of one hold on the book at `url`; the last one frees its
    /// plain bytes and wipes a held password.
    static func release(_ url: URL) {
        entries.withLock { all in
            let path = key(url)
            guard var entry = all[path] else { return }
            entry.holders -= 1
            if entry.holders > 0 {
                all[path] = entry
                return
            }
            if case .pdfPassword(var secret) = entry.held { secret.wipe() }
            all.removeValue(forKey: path)
        }
    }

    /// Whether the book at `url` is unlocked for now.
    static func isUnlocked(_ url: URL) -> Bool {
        entries.withLock { $0[key(url)] != nil }
    }

    // MARK: What Parsers Ask

    /// The plain archive held for the file at `url`, or nil.
    private static func archiveData(for url: URL) -> Data? {
        entries.withLock { all in
            if case .archive(let data)? = all[key(url)]?.held { return data }
            return nil
        }
    }

    /// The plain archive held for the book at `url`, for rewriting its file
    /// without the password (`ProtectionRemoval`); nil when none is held.
    static func plainArchiveData(for url: URL) -> Data? { archiveData(for: url) }

    /// The ZIP archive at `url`, opened for reading: from memory when the
    /// book is unlocked for now, from the file otherwise.
    /// - Throws: ZIPFoundation's own errors, as `Archive(url:accessMode:)` does.
    static func openArchive(at url: URL) throws -> Archive {
        if let data = archiveData(for: url) {
            return try Archive(data: data, accessMode: .read)
        }
        return try Archive(url: url, accessMode: .read)
    }

    /// The archive at `url` as `Archive.openedForReading(at:)` gives it:
    /// nil when it cannot be opened.
    static func archiveOpenedForReading(at url: URL) -> Archive? {
        try? openArchive(at: url)
    }

    /// Refuses a ZIP archive that holds encrypted files and is not unlocked
    /// for now, with the words that say a password is why (B27).
    /// - Throws: `EncryptedArchiveError`.
    static func refuseIfLocked(at url: URL) throws {
        guard archiveData(for: url) == nil else { return }
        try EncryptedArchiveGuard.refuseEncrypted(at: url)
    }

    /// The PDF at `url`, opened, and unlocked when the book is unlocked for
    /// now. A locked PDF whose book is not unlocked comes back locked, as
    /// PDFKit gives it, for the caller to refuse.
    static func openPDF(at url: URL) -> PDFDocument? {
        guard let document = PDFDocument(url: url) else { return nil }
        if document.isLocked,
           case .pdfPassword(let secret)? = entries.withLock({ $0[key(url)]?.held }) {
            _ = document.unlock(withPassword: secret.text)
        }
        return document
    }
}
