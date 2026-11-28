import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The words of the New Book from Text sheet that no other wording enum owns
/// (FR34). Cancel is `LibraryWindowWording.cancel`, and the Title and Author
/// fields' names are `MetadataEditorWording`'s.
enum TextInputWording {
    /// The first word of the default title of a book made from pasted text.
    static var defaultTitleName: String {
        // Translators: The first word of the title a book made from pasted text is given until the user types another, followed by the date and time, as in "Paste 2026-10-04 06:30".
        InterfaceText.line("common.paste", "Paste")
    }

    /// The sentence both Open in Editor failures end with.
    static var pasteOrTypeInstead: String {
        // Translators: Second sentence of the announcement when Open in Editor failed: what to do instead.
        InterfaceText.line("textInput.pasteOrTypeInstead", "Paste or type the text here instead, or try again.")
    }

    /// The caption beside the title field, which VoiceOver skips.
    static var titleCaption: String {
        // Translators: Caption beside the title field of the New Book from Text sheet. VoiceOver skips it; the field has its own label.
        InterfaceText.line("textInput.titleCaption", "Title:")
    }

    /// The caption beside the author field, which VoiceOver skips.
    static var authorCaption: String {
        // Translators: Caption beside the author field of the New Book from Text sheet. VoiceOver skips it; the field has its own label.
        InterfaceText.line("textInput.authorCaption", "Author:")
    }

    /// The button that puts the clipboard's text in the editor.
    static var pasteFromClipboard: String {
        // Translators: Button of the New Book from Text sheet that replaces the text with the text on the system clipboard.
        InterfaceText.line("textInput.pasteFromClipboard", "Paste from Clipboard")
    }

    /// The hint of that button.
    static var pasteHint: String {
        // Translators: Hint of the Paste from Clipboard button of the New Book from Text sheet.
        InterfaceText.line("textInput.pasteHint", "Replaces the text with the text on the clipboard")
    }

    /// The button that opens the text in the user's own editor.
    static var openInEditor: String {
        // Translators: Button of the New Book from Text sheet that opens the text in another app's text editor.
        InterfaceText.line("textInput.openInEditor", "Open in Editor")
    }

    /// The hint of that button.
    static var openInEditorHint: String {
        // Translators: Hint of the Open in Editor button of the New Book from Text sheet.
        InterfaceText.line("textInput.openInEditorHint", "Opens the text in an external editor")
    }

    /// The button that brings the editor's saved file back.
    static var reloadFromEditor: String {
        // Translators: Button of the New Book from Text sheet that reads the text again from the file the other app's editor saved. Shown after Open in Editor.
        InterfaceText.line("textInput.reloadFromEditor", "Reload from Editor")
    }

    /// The hint of that button.
    static var reloadHint: String {
        // Translators: Hint of the Reload from Editor button of the New Book from Text sheet.
        InterfaceText.line("textInput.reloadHint", "Reloads the text from the editor's file")
    }

    /// The text area's label.
    static var textContentLabel: String {
        // Translators: Spoken label of the text area of the New Book from Text sheet.
        InterfaceText.line("textInput.textContentLabel", "Text content")
    }

    /// The text area's hint.
    static var textContentHint: String {
        // Translators: Hint of the text area of the New Book from Text sheet.
        InterfaceText.line("textInput.textContentHint", "Enter or paste the text for the new book")
    }

    /// The text area's value: how much text it holds.
    static func textContentValue(characterCount: Int) -> String {
        characterCount == 0
            // Translators: Spoken value of the text area of the New Book from Text sheet while it holds no text.
            ? InterfaceText.line("textInput.textContentValue.empty", "Empty")
            // Translators: Spoken value of the text area of the New Book from Text sheet: how many characters it holds. %lld is the number of characters.
            : InterfaceText.line("textInput.textContentValue.characters", "\(number: characterCount) characters")
    }

    /// The hint of the Cancel button.
    static var cancelHint: String {
        // Translators: Hint of the Cancel button of the New Book from Text sheet.
        InterfaceText.line("textInput.cancelHint", "Closes this view without making a book")
    }

    /// The button that adds the new book.
    static var addToLibrary: String {
        // Translators: Button of the New Book from Text sheet that adds the new book to the library.
        InterfaceText.line("common.addToLibrary", "Add to Library")
    }

    /// The hint of that button while there is no text to add.
    static var addDisabledHint: String {
        // Translators: Hint of the Add to Library button of the New Book from Text sheet while the text area is empty and the button is dimmed.
        InterfaceText.line("textInput.addDisabledHint", "Enter some text first.")
    }

    /// The sheet's window title.
    static var windowTitle: String {
        // Translators: Window title of the sheet that makes a new book from typed or pasted text.
        InterfaceText.line("textInput.windowTitle", "New Book from Text")
    }
}

enum TextImportPolicy {
    static func defaultTitle(for date: Date = Date()) -> String {
        timestampedTitle(TextInputWording.defaultTitleName, at: date)
    }

    /// `name` followed by `date` to the minute, as "Paste 2026-10-04 06:30":
    /// the default title of a book TextMouth makes itself, from pasted text
    /// or from a recording, so each is told apart by when it was made.
    static func timestampedTitle(_ name: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(name) \(formatter.string(from: date))"
    }

    static func canAdd(text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Pasting and the External Editor

    /// What VoiceOver says when Paste from Clipboard finds no text on the
    /// clipboard: nothing on the screen would tell a listener it did nothing.
    static var noClipboardTextAnnouncement: String {
        SentenceWording.joined([
            // Translators: First sentence of the announcement when Paste from Clipboard finds no text on the clipboard.
            InterfaceText.line("textImportPolicy.noClipboardText.unchanged", "The clipboard has no text to paste, so the text is unchanged."),
            // Translators: Second sentence of the announcement when Paste from Clipboard finds no text on the clipboard: what to do.
            InterfaceText.line("textImportPolicy.noClipboardText.again", "Copy some text, then paste again."),
        ])
    }

    /// What VoiceOver says when Open in Editor could not write the text to a
    /// file for the editor to open.
    static var editorOpenFailedAnnouncement: String {
        SentenceWording.joined([
            // Translators: First sentence of the announcement when Open in Editor could not write the text to a file for the editor.
            InterfaceText.line("textImportPolicy.editorOpenFailedAnnouncement", "Could not open the text in an editor, because its file could not be written."),
            TextInputWording.pasteOrTypeInstead,
        ])
    }

    /// What VoiceOver says when Open in Editor wrote the file but no app
    /// opened it, as when nothing on this Mac opens plain text files.
    static var editorNotOpenedAnnouncement: String {
        SentenceWording.joined([
            // Translators: First sentence of the announcement when Open in Editor wrote the file but no app opened it, as when nothing on this Mac opens plain text files.
            InterfaceText.line("textImportPolicy.editorNotOpenedAnnouncement", "Could not open the text in an editor, because no app opened its file."),
            TextInputWording.pasteOrTypeInstead,
        ])
    }

    /// What VoiceOver says when Reload from Editor could not read the editor's
    /// file back, so the text here is unchanged. The editor may have been
    /// closed, or the file moved, so Open in Editor is named as another way.
    static var reloadFailedAnnouncement: String {
        SentenceWording.joined([
            // Translators: First sentence of the announcement when Reload from Editor could not read the editor's file back.
            InterfaceText.line("textImportPolicy.reloadFailed.unchanged", "Could not read the text back from the editor's file, so the text here is unchanged."),
            // Translators: Second sentence of the announcement when Reload from Editor could not read the editor's file back: what to do. %1$@ is the name of the Reload from Editor button. %2$@ is the name of the Open in Editor button.
            InterfaceText.line("textImportPolicy.reloadFailedAnnouncement.choose", "Save the file in the editor, then choose \(TextInputWording.reloadFromEditor) again, or choose \(TextInputWording.openInEditor) to start again."),
        ])
    }

    /// What VoiceOver says after Reload from Editor read a file whose
    /// encoding nothing in it could tell, so some characters may be wrong.
    static var reloadMayBeMisreadAnnouncement: String {
        SentenceWording.joined([
            // Translators: First sentence of the note after Reload from Editor read a file whose text encoding nothing in it tells.
            InterfaceText.line("textImportPolicy.reloadMayBeMisread.characters", "The text was reloaded, but the editor's file does not say what encoding it is in, so some characters may be wrong."),
            // Translators: Second sentence of the note after Reload from Editor read a file whose text encoding nothing in it tells: what to do. UTF-8 is the name of a text encoding. %@ is the name of the Reload from Editor button.
            InterfaceText.line("textImportPolicy.reloadMayBeMisread.choose", "Check the text, or save the file in the editor as UTF-8 and choose \(TextInputWording.reloadFromEditor) again."),
        ])
    }

    /// The text to put in the editor from the clipboard's text: nil when the
    /// clipboard holds none, or an empty string, which pastes nothing.
    static func pastedText(fromClipboard string: String?) -> String? {
        guard let string, !string.isEmpty else { return nil }
        return string
    }

    /// The text of the file an external editor saved, and whether it may be
    /// misread.
    struct ReloadedText: Equatable {
        /// The text, line endings made line feeds.
        var text: String
        /// Whether the text is Windows-1252 only because nothing in the file
        /// told its encoding, and it holds characters beyond ASCII: an
        /// editor that saved a legacy encoding the guess could not settle
        /// shows its characters wrong, and nothing else tells the listener.
        var mayBeMisread: Bool
    }

    /// The text of the file an external editor saved, read as a file of an
    /// import is: UTF-8, or the encoding a byte-order mark names, or the
    /// encoding the bytes look like (`TextEncodingGuesser`), and Windows-1252
    /// only when no guess can be trusted. The text goes into the draft as it
    /// is, so no guess needs recording. Nil when the file cannot be read at
    /// all.
    static func reloadedText(from url: URL) -> ReloadedText? {
        guard let decoded = try? TextFileDecoder.readDecodedText(at: url, format: .txt, policy: .guess) else {
            return nil
        }
        return ReloadedText(
            text: decoded.text,
            mayBeMisread: decoded.usedFallback && !decoded.text.allSatisfy(\.isASCII)
        )
    }

    /// Writes `text` to a new file in `folder` for an external editor to
    /// open, and returns its URL, or nil when the file could not be written
    /// (a folder that is not there, one that cannot be written to, a full
    /// disk).
    static func writeForEditor(_ text: String, inFolder folder: URL) -> URL? {
        let url = folder.appendingPathComponent("TextMouth_\(UUID().uuidString).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// The title a book made from text is given: the one typed without its
    /// surrounding blanks, or "Untitled" when it holds nothing else, so a
    /// title of spaces is no title and no file named for spaces.
    static func resolvedTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed // l10n: no (stored id: the placeholder title a book is saved with)
    }

    /// Produces a single safe path component while keeping the book's
    /// display title unchanged in metadata.
    static func textFilename(for title: String) -> String {
        fileName(for: title, extension: "txt")
    }

    /// A single safe path component for the file of a book titled `title`,
    /// ending in `fileExtension`: the title, with each run of characters a
    /// file name cannot hold, or that Finder shows differently, made a
    /// hyphen, and "Untitled" for a title of none of the others. The book's
    /// display title stays as it was, in its record.
    static func fileName(for title: String, extension fileExtension: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let pieces = resolvedTitle(title).components(separatedBy: forbidden)
        let base = pieces.filter { !$0.isEmpty }.joined(separator: "-")
        return "\(base.isEmpty ? "Untitled" : base).\(fileExtension)" // l10n: no (a file name, not interface text)
    }
}

struct TextInputView: View {
    let onAdd: (String, String, String) -> Void  // title, author, text
    let onCancel: () -> Void

    @State private var title: String
    @State private var author = Book.unknownAuthor
    @State private var textContent = ""
    @State private var editorTempURL: URL?
    @State private var showReload = false
    /// Why the last paste, Open in Editor, or Reload did not do its work,
    /// shown beside the buttons as well as spoken, so a braille display
    /// shows it too and a missed announcement leaves a trace. Cleared when
    /// the text changes and when the next of the three begins.
    @State private var failureMessage: String?
    /// What to check after a Reload, shown and spoken like a failure but
    /// kept while the reloaded text stays: its characters may be wrong.
    @State private var reloadNote: String?
    /// The text the note is about. The note is shown only while the text is
    /// still this: once the listener edits it, the doubt is theirs to settle.
    @State private var reloadedContent: String?

    init(onAdd: @escaping (String, String, String) -> Void, onCancel: @escaping () -> Void) {
        self.onAdd = onAdd
        self.onCancel = onCancel
        self._title = State(initialValue: TextImportPolicy.defaultTitle())
    }

    var body: some View {
        VStack(spacing: 12) {
            // MARK: - Title and Author Fields
            HStack {
                Text(TextInputWording.titleCaption)
                    .accessibilityHidden(true)
                TextField(MetadataEditorWording.titleField, text: $title)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(MetadataEditorWording.titleField)
            }

            HStack {
                Text(TextInputWording.authorCaption)
                    .accessibilityHidden(true)
                TextField(MetadataEditorWording.authorField, text: $author)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(MetadataEditorWording.authorField)
            }

            // MARK: - Top Button Bar
            HStack(spacing: 10) {
                Button(TextInputWording.pasteFromClipboard) {
                    pasteFromClipboard()
                }
                .accessibilityLabel(TextInputWording.pasteFromClipboard)
                .accessibilityHint(TextInputWording.pasteHint)

                Button(TextInputWording.openInEditor) {
                    openInEditor()
                }
                .accessibilityLabel(TextInputWording.openInEditor)
                .accessibilityHint(TextInputWording.openInEditorHint)

                if showReload {
                    Button(TextInputWording.reloadFromEditor) {
                        reloadFromEditor()
                    }
                    .accessibilityLabel(TextInputWording.reloadFromEditor)
                    .accessibilityHint(TextInputWording.reloadHint)
                }

                Spacer()
            }

            // MARK: - Text Editor
            TextEditor(text: $textContent)
                .font(.body)
                .border(Color.secondary.opacity(0.3), width: 1)
                .accessibilityLabel(TextInputWording.textContentLabel)
                .accessibilityHint(TextInputWording.textContentHint)
                .accessibilityValue(TextInputWording.textContentValue(characterCount: textContent.count))

            // MARK: - Why Something Did Not Work
            if let failureMessage {
                OperationFailureNotice(message: failureMessage)
            }
            if let reloadNote, textContent == reloadedContent {
                Text(reloadNote)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // MARK: - Bottom Buttons
            HStack {
                Spacer()

                Button(LibraryWindowWording.cancel) {
                    cleanupTempFile()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(LibraryWindowWording.cancel)
                .accessibilityHint(TextInputWording.cancelHint)

                Button(TextInputWording.addToLibrary) {
                    cleanupTempFile()
                    onAdd(title, author, textContent)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!TextImportPolicy.canAdd(text: textContent))
                .accessibilityLabel(TextInputWording.addToLibrary)
                // The hint says why the button is dimmed; once it is not, the label says all.
                .accessibilityHint(!TextImportPolicy.canAdd(text: textContent) ? TextInputWording.addDisabledHint : "")
            }
        }
        .padding()
        .frame(width: 600, height: 500)
        .navigationTitle(TextInputWording.windowTitle)
        // A reason that no longer applies is never read beside new input.
        .clearingFailure($failureMessage, whenChanged: textContent)
    }

    // MARK: - Actions

    /// Shows `message` beside the buttons and has VoiceOver say it, once.
    private func fail(_ message: String) {
        failureMessage = message
        VoiceOverAnnouncer.announce(message)
    }

    /// Forgets the last action's failure and note, as the next one begins.
    private func beginAction() {
        failureMessage = nil
        reloadNote = nil
        reloadedContent = nil
    }

    private func pasteFromClipboard() {
        beginAction()
        #if os(macOS)
        let clipboardText = NSPasteboard.general.string(forType: .string)
        #else
        // iOS: the general pasteboard's plain text, when it holds any.
        let clipboardText = UIPasteboard.general.string
        #endif
        if let pasted = TextImportPolicy.pastedText(fromClipboard: clipboardText) {
            textContent = pasted
        } else {
            // Nothing changed, and nothing on the screen would say so.
            fail(TextImportPolicy.noClipboardTextAnnouncement)
        }
    }

    private func openInEditor() {
        beginAction()
        #if os(macOS)
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        guard let fileURL = TextImportPolicy.writeForEditor(textContent, inFolder: folder) else {
            // The user can try again, or paste or type; but not in silence.
            fail(TextImportPolicy.editorOpenFailedAnnouncement)
            return
        }
        // Nothing may open the file; then there is no editor to reload from,
        // and Reload, if an earlier Open in Editor showed it, keeps reading
        // the earlier file, which an editor did open.
        guard NSWorkspace.shared.open(fileURL) else {
            try? FileManager.default.removeItem(at: fileURL)
            fail(TextImportPolicy.editorNotOpenedAnnouncement)
            return
        }
        cleanupTempFile()
        editorTempURL = fileURL
        showReload = true
        #else
        // Phase 0: iOS has no external editor to open the text in; phase 1
        // decides what stands in for it. Nothing happens, and nothing throws.
        #endif
    }

    private func reloadFromEditor() {
        beginAction()
        guard let url = editorTempURL, let reloaded = TextImportPolicy.reloadedText(from: url) else {
            // The content stays as it was, and the listener is told so.
            fail(TextImportPolicy.reloadFailedAnnouncement)
            return
        }
        textContent = reloaded.text
        if reloaded.mayBeMisread {
            reloadNote = TextImportPolicy.reloadMayBeMisreadAnnouncement
            reloadedContent = reloaded.text
            VoiceOverAnnouncer.announce(TextImportPolicy.reloadMayBeMisreadAnnouncement)
        }
    }

    private func cleanupTempFile() {
        guard let url = editorTempURL else { return }
        try? FileManager.default.removeItem(at: url)
        editorTempURL = nil
    }
}
