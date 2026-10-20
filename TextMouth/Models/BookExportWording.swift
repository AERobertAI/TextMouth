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
        case .originalAudio: return "Original audio (before edits)"
        case .transcript: return "Transcript"
        case .originalFile: return "Original file"
        case .markdown: return "Text as Markdown"
        case .plainText: return "Text as plain text"
        }
    }

    /// What the checkbox of `kind` exports: its hint.
    static func hint(for kind: BookExportKind) -> String {
        switch kind {
        case .audio:
            return "The book's audio: its file, or its tracks in a folder named after the book, each named for its chapter."
        case .originalFile:
            return "The book's own file, as it was imported; for an audiobook, its audio files as they were before "
                + "TextMouth converted them."
        case .markdown:
            return "The book's text as Markdown, the file TextMouth reads it from, with a line marking each chapter."
        case .plainText:
            return "The words TextMouth reads aloud, as plain text, each chapter under its title."
        case .originalRecording:
            return "The recording as it was made, before any edits."
        case .originalAudio:
            return "The book's audio as it was before its first edit, which TextMouth keeps while the Original audio "
                + "setting does."
        case .transcript:
            return "The transcript, with its text as Markdown for an audiobook."
        }
    }

    // MARK: Convert To

    /// The name of the Convert to picker beside the Text as Markdown
    /// checkbox.
    static let convertToLabel = "Convert to"

    /// What the picker calls its first choice, today's export: the book's
    /// content.md copied as it is.
    static let markdownChoiceName = "Markdown"

    /// What the picker's hint says while Markdown is chosen.
    static let markdownChoiceHint = "The book's text as Markdown, the file TextMouth reads it from, as it is."

    /// What `kind` is called while its text is converted to `conversionName`:
    /// "Text as HTML". A kind whose text is not converted, or no conversion
    /// (nil), keeps `name(of:)`.
    static func name(of kind: BookExportKind, convertedTo conversionName: String?) -> String {
        guard let conversionName, kind.convertsText else { return name(of: kind) }
        return "Text as \(conversionName)"
    }

    /// What the checkbox of `kind` exports while its text is converted to
    /// `conversionName`. A kind whose text is not converted, or no
    /// conversion (nil), keeps `hint(for:)`.
    static func hint(for kind: BookExportKind, convertedTo conversionName: String?) -> String {
        guard let conversionName, kind.convertsText else { return hint(for: kind) }
        return "The book's text as \(conversionName), made from the Markdown TextMouth reads it from."
    }

    // MARK: The Dialog

    /// The commands' title in the File menu and the reader's toolbar.
    static let commandTitle = "Export…"

    /// The title of the library's context-menu command for `count` books:
    /// "Export…" for one, "Export 3 Books…" for a selection of several.
    static func commandTitle(count: Int) -> String {
        count > 1 ? "Export \(CountWording.phrase(count, singular: "Book", plural: "Books"))…" : commandTitle
    }

    /// What File > Export… says when no Library window or book is open, as
    /// when only Settings is, so there is nothing it could export.
    static let noWindowOpen = "No Library window or book is open, so there is nothing to export."

    /// What File > Export… says when a Library window or a book is open, but
    /// another window, such as Settings, is in front.
    static let noWindowInFront = "To export, switch to a Library window or a book's window, then choose Export again."

    /// The dialog's title: "Export Moby-Dick" for one book, "Export 3
    /// Books" for several.
    static func title(bookTitles: [String]) -> String {
        guard bookTitles.count == 1, let title = bookTitles.first else {
            return "Export \(CountWording.phrase(bookTitles.count, singular: "Book", plural: "Books"))"
        }
        return "Export \(title)"
    }

    /// What the dialog shows while it finds what the books hold.
    static let listing = "Finding what can be exported…"

    /// The name of the group of checkboxes.
    static let choicesLabel = "What to export"

    /// What the dialog says when the books hold nothing to export.
    static let nothingToExport = "There is nothing to export."

    /// A kind's checkbox label, which the screen shows and VoiceOver
    /// speaks: its name, then, for several books, how many hold it on this
    /// Mac, or, for one book, how many files it is when more than one; its
    /// size ("about" for reading text, made from the Markdown it is sized
    /// by); and what is in the cloud. As in "Original file, 1.2 MB", "Audio,
    /// 12 files, 340 MB", "Audio, 2 books, 680 MB, 1 book in the cloud", or
    /// "Text as Markdown, in the cloud". A converted text says no size:
    /// "Text as HTML", "Text as RTF, 2 books, 1 book in the cloud".
    /// - Parameters:
    ///   - kind: The checkbox's kind.
    ///   - bookCount: How many books the dialog exports from.
    ///   - availableItemCount: How many of them hold it on this Mac.
    ///   - fileCount: How many files those items are.
    ///   - byteCount: Their size in bytes.
    ///   - inCloudCount: How many books hold it only in the cloud.
    ///   - conversionName: The name of the writer the kind's text is
    ///     converted to ("HTML"), which the label says and leaves the size
    ///     out for: a converted file's size is not known until it is written,
    ///     and the Markdown's would mislead (RTF of Cyrillic text is about
    ///     3.2 times larger, Word 97-2003 two or more times); nil for the
    ///     kind as it is.
    static func choiceLabel(
        kind: BookExportKind,
        bookCount: Int,
        availableItemCount: Int,
        fileCount: Int,
        byteCount: Int64,
        inCloudCount: Int,
        convertedTo conversionName: String? = nil
    ) -> String {
        let converted = conversionName != nil && kind.convertsText
        var parts = [name(of: kind, convertedTo: conversionName)]
        if bookCount > 1 {
            if availableItemCount > 0 {
                parts.append(CountWording.books(availableItemCount))
            }
        } else if fileCount > 1 {
            parts.append(CountWording.phrase(fileCount, singular: "file", plural: "files"))
        }
        // A converted file's size is unknown until it is written, and the
        // Markdown's would mislead, so a conversion says none.
        if availableItemCount > 0, !converted {
            let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
            parts.append(kind == .plainText ? "about \(size)" : size)
        }
        if inCloudCount > 0 {
            parts.append(bookCount > 1 ? "\(CountWording.books(inCloudCount)) in the cloud" : "in the cloud")
        }
        return parts.joined(separator: ", ")
    }

    /// The line naming the folder the items go to: "Export to: Documents".
    static func destination(folderName: String) -> String {
        "Export to: \(folderName)"
    }

    /// The button that chooses the folder, and its hint.
    static let chooseFolderTitle = "Choose Folder…"
    static let chooseFolderHint = "Chooses the folder the checked items are exported to."

    /// The button that exports, and its hint.
    static let exportTitle = "Export"
    static let exportHint = "Exports the checked items to the folder."

    /// The button that stops an export under way, and its hint.
    static let stopTitle = "Stop"
    static let stopHint = "Stops the export. The file being made is not kept."

    /// The button that closes the dialog without exporting.
    static let cancelTitle = "Cancel"

    /// The button that closes the dialog after an export that did not do
    /// everything asked, whose words stay in it.
    static let closeTitle = "Close"

    /// The progress of an export under way: "Exporting 3 of 40 items…", or
    /// "Exporting…" before it has counted them.
    static func progress(done: Int, total: Int) -> String {
        total > 0 ? "Exporting \(done) of \(items(total))…" : "Exporting…"
    }

    /// Why Export refuses the folder chosen: it is TextMouth's own data
    /// directory, or inside it.
    static let destinationInLibrary = "Export can't write into TextMouth's library folder. Choose another folder."

    /// The folder chooser's title, message, and button.
    static let panelTitle = "Export To"
    static let panelMessage = "Choose the folder to export to. New Folder makes one."
    static let panelPrompt = "Choose"

    // MARK: The Reader's Toolbar

    /// The reader toolbar's Export button: its title, its spoken label, and
    /// its hint.
    static let toolbarTitle = "Export"
    static let toolbarLabel = "Export this book"
    static let toolbarHint = "Opens the Export dialog: the book's audio, its text, or its own file."

    /// The Playback settings section holding the reader toolbar's options,
    /// and its checkbox showing the Export button: the title on screen, the
    /// label VoiceOver speaks, and the hint.
    static let settingSection = "Reader Toolbar"
    static let settingTitle = "Show Export in the reader toolbar"
    static let settingLabel = "Show the Export button in the reader toolbar"
    static let settingHint = "Adds a button to each reader's toolbar that opens the Export dialog. File, Export is there either way."

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
