import Foundation

/// The words of Export (FR05): what each kind of item is called, why a book
/// in the cloud is not exported, and what an export says when it ends, each
/// built once for the screen and VoiceOver alike.
///
/// Every text is localized (FR34); the English is the key, and a count in a
/// sentence is the sentence's own plural string.
enum BookExportWording {
    // MARK: Kinds

    /// What `kind` is called: the start of its checkbox's label in the
    /// Export dialog.
    static func name(of kind: BookExportKind) -> String {
        switch kind {
        case .audio:
            // Translators: The name of the Audio checkbox in the Export dialog: the book's audio.
            return InterfaceText.line("common.audio", "Audio")
        case .headings:
            // Translators: The name of the Headings checkbox in the Export dialog: a list of the book's headings and where each begins.
            return InterfaceText.line("common.headings", "Headings")
        case .bookmarks:
            // Translators: The name of the Bookmarks checkbox in the Export dialog: a list of the book's bookmarks.
            return InterfaceText.line("common.bookmarks", "Bookmarks")
        case .originalRecording:
            // Translators: The name of a checkbox in the Export dialog: a recording as it was made, before any edits.
            return InterfaceText.line("bookExport.name.originalRecording", "Original recording")
        case .originalAudio:
            // Translators: The name of a checkbox in the Export dialog: the book's audio as it was before its first edit.
            return InterfaceText.line("bookExport.name.originalAudio", "Original audio (before edits)")
        case .transcript:
            // Translators: The name of the Transcript checkbox in the Export dialog: the book's transcript.
            return InterfaceText.line("common.transcript", "Transcript")
        case .originalFile:
            // Translators: The name of a checkbox in the Export dialog: the book's own file as it was imported.
            return InterfaceText.line("bookExport.name.originalFile", "Original file")
        case .markdown:
            // Translators: The name of a checkbox in the Export dialog: the book's text written as Markdown.
            return InterfaceText.line("bookExport.name.markdown", "Text as Markdown")
        case .plainText:
            // Translators: The name of a checkbox in the Export dialog: the words TextMouth reads aloud, as plain text.
            return InterfaceText.line("bookExport.name.plainText", "Text as plain text")
        case .spokenAudio:
            // Translators: The name of a checkbox in the Export dialog: the book's text spoken by its voice into one audio file.
            return InterfaceText.line("bookExport.name.spokenAudio", "Text as spoken audio")
        }
    }

    /// What the checkbox of `kind` exports: its hint.
    static func hint(for kind: BookExportKind) -> String {
        switch kind {
        case .audio:
            // Translators: The hint of the Audio checkbox in the Export dialog.
            return InterfaceText.line("bookExport.hint.audio", "The book's audio: its file, or its tracks in a folder named after the book, each named for its chapter.")
        case .headings:
            return chapterListChoiceHint(for: .standard, source: .headings)
        case .bookmarks:
            return chapterListChoiceHint(for: .audacityLabels, source: .bookmarks)
        case .originalFile:
            // Translators: The hint of the Original file checkbox in the Export dialog.
            return InterfaceText.line("bookExport.hint.originalFile", "The book's file as imported; for an audiobook, its audio files before TextMouth converted them.")
        case .markdown:
            return markdownChoiceHint
        case .plainText:
            // Translators: The hint of the Text as plain text checkbox in the Export dialog.
            return InterfaceText.line("bookExport.hint.plainText", "The words TextMouth reads aloud, as plain text, each chapter under its title.")
        case .spokenAudio:
            // Translators: The hint of the Text as spoken audio checkbox in the Export dialog.
            return InterfaceText.line("bookExport.hint.spokenAudio", "The book's text spoken by its voice into one audio file, with a chapter for each heading.")
        case .originalRecording:
            // Translators: The hint of the Original recording checkbox in the Export dialog.
            return InterfaceText.line("bookExport.hint.originalRecording", "The recording as it was made, before any edits.")
        case .originalAudio:
            // Translators: The hint of the Original audio checkbox in the Export dialog. "Original audio" is the name of a setting.
            return InterfaceText.line("bookExport.hint.originalAudio", "The book's audio as it was before its first edit, which TextMouth keeps while the Original audio setting does.")
        case .transcript:
            // Translators: The hint of the Transcript checkbox in the Export dialog.
            return InterfaceText.line("bookExport.hint.transcript", "The transcript, with its text as Markdown for an audiobook.")
        }
    }

    // MARK: Convert To

    /// The name of the Convert to picker beside the Text as Markdown
    /// checkbox.
    static var convertToLabel: String {
        // Translators: The name of the picker beside a checkbox in the Export dialog that chooses the format the text is written in.
        InterfaceText.line("bookExport.convertToLabel", "Convert to")
    }

    /// The name of the Convert to picker beside the checkbox of `kind`:
    /// "Convert transcript to" beside Transcript (FMT23) and "Convert
    /// headings to" beside Headings (FMT24), so no two pickers sound alike
    /// when one export shows them, and `convertToLabel` beside any other.
    /// (Bookmarks, of one format, have no picker.)
    static func convertToLabel(for kind: BookExportKind) -> String {
        switch kind {
        case .transcript:
            // Translators: The name of the picker beside the Transcript checkbox in the Export dialog that chooses the format of the transcript.
            return InterfaceText.line("bookExport.convertToLabel.transcript", "Convert transcript to")
        case .headings:
            // Translators: The name of the picker beside the Headings checkbox in the Export dialog that chooses the format of the headings list.
            return InterfaceText.line("bookExport.convertToLabel.headings", "Convert headings to")
        default: return convertToLabel
        }
    }

    /// What the picker calls its first choice, the picker's default: the
    /// book's text as Markdown (`MarkdownExportWriter`).
    static var markdownChoiceName: String {
        // Translators: The name of the Markdown format, the first choice of the Convert to picker in the Export dialog.
        InterfaceText.line("common.markdown", "Markdown")
    }

    /// What the picker's hint says while Markdown is chosen, and what the
    /// checkbox of "Text as Markdown" says it exports.
    static var markdownChoiceHint: String {
        // Translators: The hint of the Convert to picker in the Export dialog while Markdown is chosen, and of the Text as Markdown checkbox.
        InterfaceText.line("bookExport.markdownChoiceHint", "The book's text as Markdown, with its headings, lists, and emphasis.")
    }

    /// What `kind` is called while its text is converted to `conversionName`:
    /// "Text as HTML". A kind whose text is not converted, or no conversion
    /// (nil), keeps `name(of:)`.
    static func name(of kind: BookExportKind, convertedTo conversionName: String?) -> String {
        guard let conversionName else { return name(of: kind) }
        if kind.writesChapterList {
            return nameAs(name(of: kind), conversionName)
        }
        guard kind.convertsText else { return name(of: kind) }
        // Translators: The name of a text checkbox in the Export dialog while its text is converted. %@ is the name of the format, such as HTML or RTF.
        return InterfaceText.line("bookExport.name", "Text as \(conversionName)")
    }

    /// `kindName` written as `conversionName`: "Headings as CUE sheet",
    /// "Transcript as WebVTT".
    private static func nameAs(_ kindName: String, _ conversionName: String) -> String {
        // Translators: The name of a checkbox in the Export dialog while its list or transcript is written in a format. %1$@ is the checkbox's name, such as Headings or Transcript, and %2$@ the name of the format, such as CUE sheet or WebVTT.
        InterfaceText.line("bookExport.nameAs", "\(kindName) as \(conversionName)")
    }

    /// What the checkbox of `kind` exports while its text is converted to
    /// `conversionName`. A kind whose text is not converted, or no
    /// conversion (nil), keeps `hint(for:)`.
    static func hint(for kind: BookExportKind, convertedTo conversionName: String?) -> String {
        guard let conversionName, kind.convertsText else { return hint(for: kind) }
        // Translators: The hint of a text checkbox in the Export dialog while its text is converted. %@ is the name of the format, such as HTML or RTF.
        return InterfaceText.line("bookExport.hint", "The book's text as \(conversionName), made from its Markdown.")
    }

    // MARK: A Book's Headings and Bookmarks (FMT24, FMT06)

    /// What the picker's hint says while `format` is chosen for a list of
    /// `source`, and what its checkbox exports in it.
    static func chapterListChoiceHint(for format: ChapterListFormat, source: ChapterListSource) -> String {
        switch (format, source) {
        case (.cueSheet, _):
            // Translators: The hint of the Headings checkbox in the Export dialog while CUE sheet is chosen. "Audio" is the name of the Audio checkbox.
            return InterfaceText.line("bookExport.chapterListChoiceHint.exports", "Each heading's title and start, as a CUE sheet naming the audio as Audio exports it.")
        case (.audacityLabels, .headings):
            // Translators: The hint of the Headings checkbox in the Export dialog while Audacity labels are chosen.
            return InterfaceText.line("bookExport.chapterListChoiceHint.audacity", "Each heading's title and start, as Audacity labels, for a book with one audio file.")
        case (.audacityLabels, .bookmarks):
            // Translators: The hint of the Bookmarks checkbox in the Export dialog.
            return InterfaceText.line("bookExport.chapterListChoiceHint.bookmark", "Each bookmark's name and place, as Audacity labels, for a book with one audio file.")
        }
    }

    /// The name a bookmark without one of its own takes in exported labels:
    /// "Bookmark 3", as the reader announces it.
    static func untitledBookmark(number: Int) -> String {
        // The number names the bookmark, so it is written without grouping.
        // Translators: The name of a bookmark that has no name of its own, written into an exported list of labels. %@ is the bookmark's number, an identifier written without digit grouping.
        InterfaceText.line("common.bookmarkValue", "Bookmark \(String(number))")
    }

    /// Why a book's headings were not written: it keeps no record of them
    /// yet, after the file's name in the export's failure sentence.
    static var noHeadingsReason: String {
        // Translators: Why a book's headings could not be exported, after the file's name in a failure sentence such as "Couldn't export Headings: ...".
        InterfaceText.line("bookExport.noHeadingsReason", "TextMouth hasn't read this book's headings yet. Open the book once, then export again.")
    }

    /// Why labels were not written for a book whose audio is in
    /// `fileCount` files: labels mark one file.
    static func labelsNeedOneFileReason(fileCount: Int) -> String {
        // Translators: Why Audacity labels could not be exported, after the file's name in a failure sentence. %lld is the number of audio files the book has, always more than one.
        InterfaceText.line("bookExport.labelsNeedOneFileReason", "Audacity labels mark one audio file, and this book's audio is in \(number: fileCount) files.")
    }

    // MARK: A Transcript's Convert To (FMT23)

    /// What the Transcript checkbox's picker calls its first choice, its
    /// default: the transcript as TextMouth keeps it, today's export.
    static var transcriptJSONChoiceName: String {
        // Translators: The first choice of the Transcript's Convert to picker in the Export dialog: the transcript as TextMouth keeps it, a JSON file and a Markdown file.
        InterfaceText.line("bookExport.transcriptJSONChoiceName", "JSON and Markdown")
    }

    /// What the picker's hint says while JSON and Markdown is chosen.
    static var transcriptJSONChoiceHint: String {
        // Translators: The hint of the Transcript's Convert to picker in the Export dialog while JSON and Markdown is chosen.
        InterfaceText.line("bookExport.transcriptJSONChoiceHint", "The transcript as TextMouth keeps it, in JSON, with its text as Markdown.")
    }

    /// Why a book's captions were not written when its transcript keeps no
    /// times, only its text (S4): "The book has no timed transcript to write
    /// as captions.", after the file's name in the export's failure sentence.
    static var noTimedTranscriptReason: String {
        // Translators: Why a book's captions could not be exported, after the file's name in a failure sentence.
        InterfaceText.line("bookExport.noTimedTranscriptReason", "The book has no timed transcript to write as captions.")
    }

    /// What the picker's hint says while `format` is chosen: what reads the
    /// format, and how its captions are laid out.
    static func transcriptChoiceHint(for format: TranscriptExportFormat) -> String {
        switch format {
        case .webVTT:
            // Translators: The hint of the Transcript's Convert to picker in the Export dialog while WebVTT is chosen. %@ is the format's name, WebVTT.
            return InterfaceText.line("bookExport.transcriptChoiceHint.webVTT", "Captions in \(format.name), which web browsers and most players read: one file, timed from the start of the audio.")
        case .subRip:
            // Translators: The hint of the Transcript's Convert to picker in the Export dialog while SubRip is chosen. %1$@ is the format's name, SubRip, and %2$@ its file extension, srt.
            return InterfaceText.line("bookExport.transcriptChoiceHint.subRip", "Captions in \(format.name) (.\(format.fileExtension)), which nearly every player reads: one file, timed from the start of the audio.")
        }
    }

    /// What the Transcript checkbox is called while its transcript is
    /// written as `conversionName`, a format of captions or a text writer:
    /// "Transcript as WebVTT", "Transcript as HTML".
    static func transcriptName(as conversionName: String) -> String {
        nameAs(name(of: .transcript), conversionName)
    }

    /// What the Transcript checkbox exports while its transcript is written
    /// as captions in `format`: its hint.
    static func transcriptHint(as format: TranscriptExportFormat) -> String {
        // Translators: The hint of the Transcript checkbox in the Export dialog while its transcript is written as captions. %@ is the format's name, such as WebVTT or SubRip.
        InterfaceText.line("bookExport.transcriptHint", "The transcript as \(format.name) captions, one file timed from the start of the audio.")
    }

    /// What the Transcript checkbox exports while its text is written by the
    /// text writer named `writerName` (TODO 3984): its hint, "The
    /// transcript's text as HTML, made from the Markdown TextMouth reads it
    /// from."
    static func transcriptTextHint(as writerName: String) -> String {
        // Translators: The hint of the Transcript checkbox in the Export dialog while its text is written by a text writer. %@ is the writer's name, such as HTML or RTF.
        InterfaceText.line("bookExport.transcriptTextHint", "The transcript's text as \(writerName), made from its Markdown.")
    }

    // MARK: The Dialog

    /// The commands' title in the File menu and the reader's toolbar.
    static var commandTitle: String {
        // Translators: The title of the Export command in the File menu, the library's context menu, and the reader's toolbar.
        InterfaceText.line("common.export", "Export…")
    }

    /// The title of the library's context-menu command for `count` books:
    /// "Export…" for one, "Export 3 Books…" for a selection of several.
    static func commandTitle(count: Int) -> String {
        count > 1
            // Translators: The title of the library's context-menu command that exports a selection of several books. %lld is the number of books selected.
            ? InterfaceText.line("bookExport.commandTitle", "Export \(number: count) Books…")
            : commandTitle
    }

    /// What File > Export… says when no Library window or book is open, as
    /// when only Settings is, so there is nothing it could export.
    static var noWindowOpen: String {
        // Translators: What choosing File, Export says when no Library window or book is open.
        InterfaceText.line("bookExport.noWindowOpen", "No Library window or book is open, so there is nothing to export.")
    }

    /// What File > Export… says when a Library window or a book is open, but
    /// another window, such as Settings, is in front.
    static var noWindowInFront: String {
        // Translators: What choosing File, Export says when another window, such as Settings, is in front of the Library and book windows.
        InterfaceText.line("bookExport.noWindowInFront", "Switch to a Library or book window, then choose Export again.")
    }

    /// The dialog's title: "Export Moby-Dick" for one book, "Export 3
    /// Books" for several.
    static func title(bookTitles: [String]) -> String {
        guard bookTitles.count == 1, let title = bookTitles.first else {
            // Translators: The title of the Export dialog for several books. %lld is the number of books.
            return InterfaceText.line("bookExport.title.books", "Export \(number: bookTitles.count) Books")
        }
        // Translators: The title of the Export dialog for one book. %@ is the book's title.
        return InterfaceText.line("bookExport.title.named", "Export \(title)")
    }

    /// What the dialog shows while it finds what the books hold.
    static var listing: String {
        // Translators: Shown in the Export dialog while it finds what the books hold.
        InterfaceText.line("bookExport.listing", "Finding what can be exported…")
    }

    /// The name of the group of checkboxes.
    static var choicesLabel: String {
        // Translators: The name of the group of checkboxes in the Export dialog.
        InterfaceText.line("bookExport.choicesLabel", "What to export")
    }

    /// What the dialog says when the books hold nothing to export.
    static var nothingToExport: String {
        // Translators: Shown in the Export dialog when the books hold nothing to export.
        InterfaceText.line("bookExport.nothingToExport", "There is nothing to export.")
    }

    /// A kind's checkbox label, which the screen shows and VoiceOver
    /// speaks: its name, then, for several books, how many hold it on this
    /// Mac, or, for one book, how many files it is when more than one; its
    /// size ("about" for reading text, made from the Markdown it is sized
    /// by); and what is in the cloud. As in "Original file, 1.2 MB", "Audio,
    /// 12 files, 340 MB", "Audio, 2 books, 680 MB, 1 book in the cloud", or
    /// "Text as Markdown, in the cloud". A converted text says no size:
    /// "Text as HTML", "Text as RTF, 2 books, 1 book in the cloud".
    /// Nor does a transcript written as captions or by a text writer
    /// (FMT23), which says no count of files either, being one file for each
    /// book: "Transcript as WebVTT", "Transcript as HTML". Spoken audio, one
    /// file whose size is unknown until it is spoken (FMT43), says neither a
    /// size nor a file count: "Text as spoken audio", or "Text as spoken
    /// audio, in the cloud". Nor do an audiobook's headings, one file written
    /// in the format chosen (FMT24): "Headings as CUE sheet".
    /// - Parameters:
    ///   - kind: The checkbox's kind.
    ///   - bookCount: How many books the dialog exports from.
    ///   - availableItemCount: How many of them hold it on this Mac.
    ///   - fileCount: How many files those items are.
    ///   - byteCount: Their size in bytes.
    ///   - inCloudCount: How many books hold it only in the cloud.
    ///   - conversionName: The name of the writer the kind's text is
    ///     converted to ("HTML"), or of the format an audiobook's headings
    ///     are written in ("CUE sheet"), which the label says and leaves the size
    ///     out for: a converted file's size is not known until it is written,
    ///     and the Markdown's would mislead (RTF of Cyrillic text is about
    ///     3.2 times larger, Word 97-2003 two or more times); nil for the
    ///     kind as it is.
    ///   - transcriptConversionName: The name of what the transcript is
    ///     written as (FMT23), a format of captions ("WebVTT") or a text
    ///     writer ("HTML"), which the label names; nil for the transcript as
    ///     TextMouth keeps it. Every other kind ignores it.
    static func choiceLabel(
        kind: BookExportKind,
        bookCount: Int,
        availableItemCount: Int,
        fileCount: Int,
        byteCount: Int64,
        inCloudCount: Int,
        convertedTo conversionName: String? = nil,
        transcriptAs transcriptConversionName: String? = nil
    ) -> String {
        let transcriptConversion = kind == .transcript ? transcriptConversionName : nil
        // A chapter list (FMT24) is always written, never copied, so it has
        // no size before it is written either.
        let converted = (conversionName != nil && kind.convertsText) || kind.writesChapterList || transcriptConversion != nil
        // Spoken audio is one file, whose size is unknown until it is spoken.
        let spoken = kind == .spokenAudio
        var parts = [transcriptConversion.map(transcriptName(as:)) ?? name(of: kind, convertedTo: conversionName)]
        if bookCount > 1 {
            if availableItemCount > 0 {
                parts.append(CountWording.books(availableItemCount))
            }
        } else if fileCount > 1, !spoken, transcriptConversion == nil {
            parts.append(files(fileCount))
        }
        // A converted or spoken file's size is unknown until it is written,
        // and the Markdown's would mislead, so neither says one.
        if availableItemCount > 0, !converted, !spoken {
            let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
            parts.append(kind == .plainText ? aboutSize(size) : size)
        }
        if inCloudCount > 0 {
            parts.append(bookCount > 1 ? booksInTheCloud(inCloudCount) : inTheCloud)
        }
        return SentenceWording.commaJoined(parts)
    }

    /// `count` files: "2 files", as a checkbox's label counts a book's audio.
    private static func files(_ count: Int) -> String {
        // Translators: A count of files, part of a checkbox's label in the Export dialog. %lld is the number of files.
        InterfaceText.line("common.countFiles", "\(number: count) files")
    }

    /// `size` of a text that is sized by its Markdown: "about 12 KB".
    private static func aboutSize(_ size: String) -> String {
        // Translators: Part of a checkbox's label in the Export dialog for text whose size is only close. %@ is a size such as 12 KB.
        InterfaceText.line("common.aboutValue", "about \(size)")
    }

    /// `count` books held only in the cloud: "2 books in the cloud".
    private static func booksInTheCloud(_ count: Int) -> String {
        // Translators: Part of a checkbox's label in the Export dialog: how many books hold this item only in the cloud. %@ is a count of books, such as 2 books.
        InterfaceText.line("bookExport.booksInTheCloud", "\(CountWording.books(count)) in the cloud")
    }

    /// The part of a checkbox's label for the one book whose item is only in
    /// the cloud.
    private static var inTheCloud: String {
        // Translators: Part of a checkbox's label in the Export dialog: the one book's item is only in the cloud.
        InterfaceText.line("bookExport.inTheCloud", "in the cloud")
    }

    /// The line naming the folder the items go to: "Export to: Documents".
    static func destination(folderName: String) -> String {
        // Translators: The line in the Export dialog naming the folder the items go to. %@ is the folder's name as Finder shows it.
        InterfaceText.line("bookExport.destination", "Export to: \(folderName)")
    }

    /// The button that chooses the folder, and its hint.
    static var chooseFolderTitle: String {
        // Translators: The button in the Export dialog that chooses the folder to export to.
        InterfaceText.line("bookExport.chooseFolderTitle", "Choose Folder…")
    }
    static var chooseFolderHint: String {
        // Translators: The hint of the Choose Folder button in the Export dialog.
        InterfaceText.line("bookExport.chooseFolderHint", "Chooses the folder the checked items are exported to.")
    }

    /// The button that exports, and its hint.
    static var exportTitle: String {
        // Translators: The button in the Export dialog that exports the checked items.
        InterfaceText.line("bookExport.export", "Export")
    }
    static var exportHint: String {
        // Translators: The hint of the Export button in the Export dialog.
        InterfaceText.line("bookExport.exportHint", "Exports the checked items to the folder.")
    }
    /// The Export button's hint while a braille table just chosen in the
    /// options is still being checked, which an export waits for (review R5).
    static var exportWaitsHint: String {
        // Translators: The hint of the Export button in the Export dialog while a braille table just chosen in the braille options is still being checked.
        InterfaceText.line("bookExport.exportWaitsHint", "Exports the checked items once the braille table just chosen is checked.")
    }

    /// The button that stops an export under way, and its hint.
    static var stopTitle: String {
        // Translators: The button in the Export dialog that stops an export under way.
        InterfaceText.line("common.stop", "Stop")
    }
    static var stopHint: String {
        // Translators: The hint of the Stop button in the Export dialog.
        InterfaceText.line("bookExport.stopHint", "Stops the export. The file being made is not kept.")
    }

    /// The button that closes the dialog without exporting.
    static var cancelTitle: String {
        // Translators: The button in the Export dialog that closes it without exporting.
        InterfaceText.line("common.cancel", "Cancel")
    }

    /// The button that closes the dialog after an export that did not do
    /// everything asked, whose words stay in it.
    static var closeTitle: String {
        // Translators: The button in the Export dialog that closes it after an export that did not do everything asked.
        InterfaceText.line("common.close", "Close")
    }

    /// The progress of an export under way: "Exporting 3 of 40 items…", or
    /// "Exporting…" before it has counted them.
    static func progress(done: Int, total: Int) -> String {
        total > 0
            // Translators: The progress of an export under way. %1$lld is how many items are written and %2$@ is the total as a count of items, such as 40 items.
            ? InterfaceText.line("bookExport.progress.exportingCount", "Exporting \(number: done) of \(items(total))…")
            // Translators: The progress of an export under way before it has counted its items.
            : InterfaceText.line("bookExport.progress.exporting", "Exporting…")
    }

    /// Why Export refuses the folder chosen: it is TextMouth's own data
    /// directory, or inside it.
    static var destinationInLibrary: String {
        // Translators: Why the Export dialog refuses the folder chosen: it is TextMouth's own library folder or inside it.
        InterfaceText.line("bookExport.destinationInLibrary", "Export can't write into TextMouth's library folder. Choose another folder.")
    }

    /// The folder chooser's title, message, and button.
    static var panelTitle: String {
        // Translators: The title of the folder chooser that the Export dialog opens.
        InterfaceText.line("bookExport.panelTitle", "Export To")
    }
    static var panelMessage: String {
        // Translators: The message of the folder chooser that the Export dialog opens. "New Folder" is the chooser's own button.
        InterfaceText.line("bookExport.panelMessage", "Choose the folder to export to. New Folder makes one.")
    }
    static var panelPrompt: String {
        // Translators: The confirm button of the folder chooser that the Export dialog opens.
        InterfaceText.line("bookExport.panelPrompt", "Choose")
    }

    // MARK: The Reader's Toolbar

    /// The reader toolbar's Export button: its title, its spoken label, and
    /// its hint.
    static var toolbarTitle: String {
        // Translators: The title of the Export button in a reader's toolbar.
        InterfaceText.line("bookExport.export", "Export")
    }
    static var toolbarLabel: String {
        // Translators: The spoken label of the Export button in a reader's toolbar.
        InterfaceText.line("bookExport.toolbarLabel", "Export this book")
    }
    static var toolbarHint: String {
        // Translators: The hint of the Export button in a reader's toolbar.
        InterfaceText.line("bookExport.toolbarHint", "Opens the Export dialog: the book's audio, its text, or its own file.")
    }

    /// The Playback settings section holding the reader toolbar's options,
    /// and its checkbox showing the Export button: the title on screen, the
    /// label VoiceOver speaks, and the hint.
    static var settingSection: String {
        // Translators: The heading of the Playback settings section that holds the options of the reader's toolbar.
        InterfaceText.line("bookExport.settingSection", "Reader Toolbar")
    }
    static var settingTitle: String {
        // Translators: The title of the Playback settings checkbox that shows the Export button in the reader's toolbar.
        InterfaceText.line("bookExport.settingTitle", "Show Export in the reader toolbar")
    }
    static var settingLabel: String {
        // Translators: The spoken label of the Playback settings checkbox that shows the Export button in the reader's toolbar.
        InterfaceText.line("bookExport.settingLabel", "Show the Export button in the reader toolbar")
    }
    static var settingHint: String {
        // Translators: The hint of the Playback settings checkbox that shows the Export button in the reader's toolbar. "File, Export" is the menu command.
        InterfaceText.line("bookExport.settingHint", "Adds an Export button to each reader's toolbar. File, Export works either way.")
    }

    // MARK: Words Written Into an Exported File

    // What TextMouth writes into an exported file for people to read is in
    // the interface language at the time of the export (FR34, question 10).
    // A file format's own syntax is not (the writers mark it).

    /// The heading of the contents list an exported EPUB's navigation
    /// document holds, and the label of the contents list in an exported
    /// web page.
    static var contentsHeading: String {
        // Translators: The heading of the contents list written into an exported EPUB's navigation document, and the label of the contents list in an exported web page.
        InterfaceText.line("bookExport.contentsHeading", "Contents")
    }

    /// The heading of the page list an exported EPUB's navigation document
    /// holds.
    static var pagesHeading: String {
        // Translators: The heading of the page list written into an exported EPUB's navigation document.
        InterfaceText.line("common.pages", "Pages")
    }

    /// What an exported file or folder is named after a book whose title has
    /// nothing in it, and what a heading, chapter, or page without words is
    /// called in an exported EPUB.
    static var untitled: String {
        // Translators: The name given to an exported file or folder, or to an entry of an exported EPUB, when the book's title or the heading has no words.
        InterfaceText.line("bookExport.untitled", "Untitled")
    }

    /// The name of the file holding a book's original recording, as it is
    /// exported: "Moby-Dick - Original Recording.m4a".
    static func originalRecordingFileName(stem: String, fileExtension: String) -> String {
        // Translators: The name of an exported file holding a recording as it was made. %1$@ is the book's title made safe for a file name and %2$@ the file's extension, such as m4a.
        InterfaceText.line("bookExport.originalRecordingFileName", "\(stem) - Original Recording.\(fileExtension)")
    }

    /// The name of the folder holding a book's audio from before its first
    /// edit, as it is exported: "Moby-Dick - Original Audio".
    static func originalAudioFolderName(stem: String) -> String {
        // Translators: The name of an exported folder holding a book's audio as it was before its first edit. %@ is the book's title made safe for a file name.
        InterfaceText.line("bookExport.originalAudioFolderName", "\(stem) - Original Audio")
    }

    /// The name of the folder holding the audio files an audiobook was
    /// imported with, before TextMouth converted them, as it is exported:
    /// "Moby-Dick - Original Files".
    static func originalFilesFolderName(stem: String) -> String {
        // Translators: The name of an exported folder holding an audiobook's audio files as they were before TextMouth converted them. %@ is the book's title made safe for a file name.
        InterfaceText.line("bookExport.originalFilesFolderName", "\(stem) - Original Files")
    }

    // MARK: When an Export Ends

    /// How an export names the folder `url`: as Finder shows it, such as
    /// "Documents". On the iPhone, the folder's localized name
    /// (`PhoneExportFolder.name(of:)`): `displayName(atPath:)` may name a
    /// folder of iCloud Drive as its path spells it.
    static func folderName(of url: URL) -> String {
        #if os(macOS)
        FileManager.default.displayName(atPath: url.path)
        #else
        PhoneExportFolder.name(of: url)
        #endif
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
            // Translators: What an export says once it ends. %1$@ is a count of items, such as 3 items, and %2$@ the folder's name as Finder shows it.
            sentences.append(InterfaceText.line("bookExport.finished.exported", "Exported \(items(count)) to \(folderName)."))
        } else if outcome.failures.isEmpty && outcome.booksInCloud.isEmpty {
            sentences.append(outcome.wasCancelled
                // Translators: What an export says once it ends when it was stopped before it wrote anything.
                ? InterfaceText.line("bookExport.finished.stopped", "Export stopped. Nothing was exported.")
                // Translators: What an export says once it ends when it wrote nothing.
                : InterfaceText.line("bookExport.finished.nothing", "Nothing was exported."))
        }
        if outcome.wasCancelled && count > 0 {
            // Translators: A sentence of what an export says once it ends: it was stopped after it wrote some items.
            sentences.append(InterfaceText.line("bookExport.finished.before", "The export was stopped before the rest."))
        }
        if let failures = failureSentence(outcome.failures) {
            sentences.append(failures)
        }
        if !outcome.booksInCloud.isEmpty {
            sentences.append(LibraryCloudWording.notDownloaded(titles: outcome.booksInCloud.map(\.title)))
        }
        return SentenceWording.joined(sentences)
    }

    /// The sentence naming the files an export could not write, with why;
    /// nil for none. Every failure is named, up to three; past that, the
    /// first stands for the rest.
    static func failureSentence(_ failures: [BookExportFailure]) -> String? {
        guard let first = failures.first else { return nil }
        // One failure, "<name>: <reason>", with the reason's closing full stop dropped.
        let described = { (failure: BookExportFailure) in
            SentenceWording.labelled(failure.name, sentenceBody(failure.reason))
        }
        switch failures.count {
        case 1:
            // Translators: A sentence of what an export says once it ends: one file could not be written. %@ is the file's name and the reason, such as "Headings: TextMouth has not read this book's headings yet".
            return InterfaceText.line("bookExport.failureSentence.oneFile", "Couldn't export \(described(first)).")
        case 2...3:
            let all = SentenceWording.semicolonJoined(failures.map(described))
            // Translators: A sentence of what an export says once it ends: two or three files could not be written. %1$@ is a count of items, such as 2 items, and %2$@ the files' names with their reasons, separated by semicolons.
            return InterfaceText.line("bookExport.failureSentence.severalFiles", "Couldn't export \(items(failures.count)): \(all).")
        default:
            // Translators: A sentence of what an export says once it ends: several files could not be written. %1$@ is a count of items, such as 5 items, and %2$@ the first file's name and reason.
            return InterfaceText.line("bookExport.failureSentence.other", "Couldn't export \(items(failures.count)). The first was \(described(first)).")
        }
    }

    /// Why a book's text was not exported when a chapter of it nests quotes,
    /// lists, or emphasis past `limit` levels (`ExportWalkError`), and what
    /// to do, as the end of the sentence that names the file: "Chapter 2
    /// of this book nests quotes, lists, or emphasis more than 128 levels
    /// deep, which TextMouth can't export safely. Choose Edit Text, flatten
    /// the nesting, and save; then export again." The chapter is named by its
    /// number, since its title is the book's text, which the log of a failure
    /// may not hold. A text with no chapter markers (`chapter` nil) says "The
    /// text of this book" instead.
    static func nestedTooDeeply(chapter: Int?, limit: Int) -> String {
        // The clause that says how deep is `MarkdownNestingWording`'s, one
        // phrase shared with Edit Text's refusal.
        let nests = MarkdownNestingWording.nestsTooDeeply(limit: limit)
        guard let chapter else {
            // Translators: Why a book's text was not exported: it nests quotes, lists, or emphasis too deeply, and has no chapter markers. %@ is the clause that says how deep, such as "nests quotes, lists, or emphasis more than 128 levels deep". "Edit Text" is a command.
            return InterfaceText.line("bookExport.nestedTooDeeply.flatten", "The text of this book \(nests), which TextMouth can't export safely. Choose Edit Text, flatten the nesting, and save; then export again.")
        }
        // The chapter's number names it, so it is written without grouping.
        // Translators: Why a book's text was not exported: a chapter of it nests quotes, lists, or emphasis too deeply. %1$@ is the chapter's number, an identifier written without digit grouping, and %2$@ the clause that says how deep, such as "nests quotes, lists, or emphasis more than 128 levels deep". "Edit Text" is a command.
        return InterfaceText.line("bookExport.nestedTooDeeply.chapter", "Chapter \(String(chapter)) of this book \(nests), which TextMouth can't export safely. Choose Edit Text, flatten the nesting, and save; then export again.")
    }

    /// `count` items: "1 item", "3 items".
    static func items(_ count: Int) -> String {
        // Translators: A count of items an export wrote or could not write, inside a sentence. %lld is the number of items.
        InterfaceText.line("common.countItems", "\(number: count) items")
    }

    /// `text` without the period the system's messages end with, so it can
    /// sit inside a sentence of ours.
    private static func sentenceBody(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
    }
}
