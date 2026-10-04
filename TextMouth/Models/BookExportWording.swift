import Foundation

/// The words of Export (FR05): what each kind of item is called, why a book
/// in the cloud is not exported, and what an export says when it ends, each
/// built once for the screen and VoiceOver alike.
enum BookExportWording {
    // MARK: Kinds

    /// What `kind` is called: the start of its checkbox's label in the
    /// Export dialog.
    static func name(of kind: BookExportKind) -> String {
        switch kind {
        case .audio: return "Audio"
        case .originalRecording: return "Original recording"
        case .transcript: return "Transcript"
        case .originalFile: return "Original file"
        case .markdown: return "Text as Markdown"
        case .plainText: return "Text as plain text"
        }
    }

    // MARK: When an Export Ends

    /// How an export names the folder `url`: as Finder shows it, such as
    /// "Documents".
    static func folderName(of url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
    }

    /// What an export says once it ends, `outcome`, into the folder named
    /// `folderName`: how many items it wrote, as in "Exported 3 items to
    /// Documents.", then whether it was stopped, what it could not write and
    /// why, and the books it left in the cloud. Each part is a sentence of
    /// its own; an export that wrote nothing and met nothing says so.
    static func finished(_ outcome: BookExportOutcome, folderName: String) -> String {
        var sentences: [String] = []
        let count = outcome.exported.count
        if count > 0 {
            sentences.append("Exported \(items(count)) to \(folderName).")
        } else if outcome.failures.isEmpty && outcome.booksInCloud.isEmpty {
            sentences.append(outcome.wasCancelled ? "Export stopped. Nothing was exported." : "Nothing was exported.")
        }
        if outcome.wasCancelled && count > 0 {
            sentences.append("The export was stopped before the rest.")
        }
        if let failures = failureSentence(outcome.failures) {
            sentences.append(failures)
        }
        if !outcome.booksInCloud.isEmpty {
            sentences.append(LibraryCloudWording.notDownloaded(titles: outcome.booksInCloud.map(\.title)))
        }
        return sentences.joined(separator: " ")
    }

    /// The sentence naming the files an export could not write, with why;
    /// nil for none. Every failure is named, up to three; past that, the
    /// first stands for the rest.
    static func failureSentence(_ failures: [BookExportFailure]) -> String? {
        guard let first = failures.first else { return nil }
        let described = { (failure: BookExportFailure) in "\(failure.name): \(sentenceBody(failure.reason))" }
        switch failures.count {
        case 1:
            return "Couldn't export \(described(first))."
        case 2...3:
            return "Couldn't export \(items(failures.count)): \(failures.map(described).joined(separator: "; "))."
        default:
            return "Couldn't export \(items(failures.count)). The first was \(described(first))."
        }
    }

    /// `count` items: "1 item", "3 items".
    static func items(_ count: Int) -> String {
        CountWording.phrase(count, singular: "item", plural: "items")
    }

    /// `text` without the period the system's messages end with, so it can
    /// sit inside a sentence of ours.
    private static func sentenceBody(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
    }
}
