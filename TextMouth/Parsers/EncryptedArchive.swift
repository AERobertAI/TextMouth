import Foundation

// MARK: - The Refusal

/// A ZIP archive holds entries that are protected by a password. ZIPFoundation
/// cannot see such an entry, and ends its listing at the first one, so an
/// archive with a password used to import empty or short without a word of why
/// (B27). Every reader of a ZIP opens it through `EncryptedArchiveGuard` and
/// meets this refusal first.
struct EncryptedArchiveError: LocalizedError, LogDescribing, Equatable {
    /// The paths of the encrypted entries, in the archive's order.
    let names: [String]

    /// How many names the sentence quotes before it says there were others.
    static let namesShown = 3

    /// The reason, naming the files that could not be read: "This ZIP archive
    /// is protected by a password. It couldn't read
    /// “a.txt”, “b.txt”, “c.txt”, and others."
    var errorDescription: String? {
        let shown = names.prefix(Self.namesShown).map { "“\($0)”" }
        let list = names.count > shown.count
            // Translators: The first three file names a ZIP archive's password kept TextMouth from reading, then a word that says there were others. %@ is the three names, in quotes, separated by commas.
            ? InterfaceText.line("encryptedArchive.namesAndOthers", "\(shown.joined(separator: ", ")), and others")
            : CountWording.list(Array(shown))
        // Translators: Why a ZIP archive could not be imported: its files are protected by a password, which TextMouth cannot use. %@ is the names of the files it could not read, in quotes.
        return InterfaceText.line("encryptedArchive.protected", "This ZIP archive is protected by a password. It couldn't read \(list).")
    }

    /// The error in English for the debug log: how many entries, and never
    /// their names, which a protected archive's owner may want private.
    var logDescription: String {
        "A ZIP archive holds \(names.count) entries protected by a password." // l10n: no (debug log)
    }
}

// MARK: - The Guard

/// Looks for password-protected entries in a ZIP archive before a reader opens it.
enum EncryptedArchiveGuard {

    /// The paths of the files of the ZIP archive at `url` that are
    /// encrypted, in the archive's order; empty for an archive with none,
    /// and for a file whose central directory cannot be read, which is some
    /// other kind of damage that the readers report in their own words.
    /// A folder flagged encrypted counts: ZIPFoundation returns no entry for
    /// it either, and ends its listing there.
    static func encryptedNames(inFileAt url: URL) -> [String] {
        (ZipCentralDirectory.records(ofFileAt: url) ?? [])
            .filter(\.isEncrypted)
            .map(\.name)
    }

    /// Throws `EncryptedArchiveError` when the ZIP archive at `url` holds an
    /// encrypted file, and returns otherwise. Every place TextMouth opens a
    /// ZIP archive for reading calls this first.
    static func refuseEncrypted(at url: URL) throws {
        let names = encryptedNames(inFileAt: url)
        if !names.isEmpty { throw EncryptedArchiveError(names: names) }
    }
}
