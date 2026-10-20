import Foundation
import SwiftUI

// MARK: - A Writer's Options

/// The options a text writer takes (FMT18), which its view in the Export
/// dialog sets under the Convert to picker. A value, so an export takes a
/// copy of them off the main thread while the dialog keeps its own.
protocol TextExportOptions: Sendable, Hashable {}

/// The options of a writer that takes none, as HTML, RTF, and Word's do.
struct NoTextExportOptions: TextExportOptions {}

extension TextExportOptions {
    /// Whether `other` is options of this type with the same values.
    func isEqual(to other: any TextExportOptions) -> Bool {
        (other as? Self) == self
    }
}

// MARK: - A Writer

/// One way to write a text book to a file (FMT18): HTML, RTF, and Word
/// 97-2003, and braille's BRF and PEF from team braille.
///
/// Every writer reads an `ExportDocument`, the one walk of the book's
/// content.md (`ExportDocumentWalker`); Markdown stays the base, and no
/// writer parses it itself. Adding a writer is one new file, holding a type
/// that conforms to this protocol, and one line in `TextExportWriters.all`.
///
/// A writer that takes options names their type as `Options`, the options
/// each dialog starts with in `defaultOptions()`, and their view in
/// `optionsView(_:)`, which the dialog shows under the picker while the
/// writer is chosen. A writer without options leaves all three out.
protocol TextExportWriter: Sendable {
    /// The options the writer takes: none unless it names its own.
    associatedtype Options: TextExportOptions = NoTextExportOptions
    /// The view of the options: nothing unless the writer has options.
    associatedtype OptionsView: View = EmptyView

    /// The writer's name in code, never shown: unique among the writers,
    /// never `TextExportWriters.markdownID`, the picker's tag for the writer,
    /// and what tests and logs call it, such as "html".
    var id: String { get }
    /// The writer's name as the Convert to picker lists it and VoiceOver
    /// speaks it, such as "HTML".
    var name: String { get }
    /// What the picker's hint says while this writer is chosen: a sentence
    /// or two on what the file is, and anything it leaves out.
    var hint: String { get }
    /// The extension of the files the writer makes, without its dot, such
    /// as "html".
    var fileExtension: String { get }

    /// The options each Export dialog starts with.
    @MainActor func defaultOptions() -> Options

    /// The view that sets `options`, shown under the Convert to picker while
    /// this writer is chosen. Each of its controls has a label, a hint, and a
    /// spoken value, and is reached by the keyboard.
    @MainActor func optionsView(_ options: Binding<Options>) -> OptionsView

    /// Writes `document` with `options` as a new file at `url`, where nothing
    /// is yet. The export calls it off the main thread, one book at a time,
    /// and moves the file to its place in the folder chosen once it is done.
    ///
    /// A writer checks `cancellation` between blocks with `checkCancelled()`,
    /// which throws `CancellationError` once Stop is pressed: the export then
    /// removes whatever was written.
    /// - Throws: a `TextExportError`, whose sentence the export names with the
    ///   file, for a book the writer cannot write; `CancellationError` when
    ///   stopped; and whatever writing the file throws.
    func write(
        _ document: ExportDocument,
        options: Options,
        to url: URL,
        cancellation: BookExportCancellation
    ) throws
}

extension TextExportWriter where Options == NoTextExportOptions {
    /// A writer without options starts with none.
    @MainActor func defaultOptions() -> NoTextExportOptions {
        NoTextExportOptions()
    }
}

extension TextExportWriter where OptionsView == EmptyView {
    /// A writer without options shows nothing under the picker.
    @MainActor func optionsView(_ options: Binding<Options>) -> EmptyView {
        EmptyView()
    }
}

/// Why a text writer could not write a book: a sentence of its own, ending
/// with its period, which the export's failure names after the file's name,
/// as in "Couldn't export Moby-Dick - Text.html: <sentence>"
/// (`BookExportWording.failureSentence(_:)`).
struct TextExportError: LocalizedError, Equatable, Sendable {
    /// The sentence.
    let sentence: String

    /// The error saying `sentence`.
    init(_ sentence: String) {
        self.sentence = sentence
    }

    var errorDescription: String? {
        sentence
    }
}

// MARK: - A Writer Chosen

/// A writer with the options chosen for it, as one value of one type: what
/// the dialog's model hands the export's job runner, which writes with it
/// off the main thread without knowing the options' own type.
struct TextExportConversion: Sendable, Equatable {
    /// The writer's `id`.
    let writerID: String
    /// The writer's `name`.
    let name: String
    /// The writer's `fileExtension`.
    let fileExtension: String
    /// The options chosen, which `==` compares.
    private let options: any TextExportOptions
    /// The writer's `write`, with the options chosen.
    private let writeDocument: @Sendable (ExportDocument, URL, BookExportCancellation) throws -> Void

    /// `writer` with `options`.
    init<Writer: TextExportWriter>(_ writer: Writer, options: Writer.Options) {
        writerID = writer.id
        name = writer.name
        fileExtension = writer.fileExtension
        self.options = options
        writeDocument = { document, url, cancellation in
            try writer.write(document, options: options, to: url, cancellation: cancellation)
        }
    }

    /// Writes `document` as a new file at `url`, as the writer does with the
    /// options chosen (`TextExportWriter.write(_:options:to:cancellation:)`).
    func write(_ document: ExportDocument, to url: URL, cancellation: BookExportCancellation) throws {
        try writeDocument(document, url, cancellation)
    }

    /// Two conversions are the same when they name the same writer with the
    /// same options.
    static func == (lhs: TextExportConversion, rhs: TextExportConversion) -> Bool {
        lhs.writerID == rhs.writerID && lhs.options.isEqual(to: rhs.options)
    }
}

// MARK: - A Writer's Options in the Dialog

/// The options of one writer while an Export dialog is open, whichever the
/// writer: what the dialog's model keeps for each writer chosen, so that
/// choosing another writer and coming back finds them as they were.
@MainActor
protocol TextExportOptionsEditing: AnyObject {
    /// The writer's `id`.
    var writerID: String { get }
    /// Whether the writer takes options, so the dialog shows their view.
    var hasOptions: Bool { get }
    /// The writer's options view, bound to the options kept here.
    func makeView() -> AnyView
    /// The writer with its options as they are now, for an export.
    func conversion() -> TextExportConversion
}

/// The options of a `Writer` while an Export dialog is open: what its view
/// sets, and what an export takes a copy of.
@MainActor
final class TextExportOptionsState<Writer: TextExportWriter>: ObservableObject, TextExportOptionsEditing {
    /// The writer.
    let writer: Writer
    /// Its options, as the view last set them.
    @Published var options: Writer.Options

    /// The options of `writer`, as each dialog starts them.
    init(_ writer: Writer) {
        self.writer = writer
        options = writer.defaultOptions()
    }

    var writerID: String {
        writer.id
    }

    var hasOptions: Bool {
        Writer.Options.self != NoTextExportOptions.self
    }

    func makeView() -> AnyView {
        AnyView(TextExportOptionsHost(state: self))
    }

    func conversion() -> TextExportConversion {
        TextExportConversion(writer, options: options)
    }
}

/// A writer's options view, drawn again as its options change.
private struct TextExportOptionsHost<Writer: TextExportWriter>: View {
    /// The options the view sets.
    @ObservedObject var state: TextExportOptionsState<Writer>

    var body: some View {
        state.writer.optionsView($state.options)
    }
}

// MARK: - Every Writer

/// The text writers the Convert to picker offers after Markdown, in the
/// picker's order. Adding a writer: write its file, and add one line here.
enum TextExportWriters {
    /// Every writer, in the picker's order.
    static let all: [any TextExportWriter] = [
        HTMLExportWriter(),
    ]

    /// The picker's tag for Markdown, the book's content.md copied as it is
    /// (today's export, and the picker's default), which no writer's `id`
    /// may be.
    static let markdownID = "markdown"

    /// The writer whose `id` is `id`, if there is one.
    static func writer(id: String) -> (any TextExportWriter)? {
        all.first { $0.id == id }
    }

    /// The options of `writer`, as each dialog starts them, kept in a state
    /// of the writer's own options type.
    @MainActor
    static func optionsState(for writer: any TextExportWriter) -> any TextExportOptionsEditing {
        makeOptionsState(writer)
    }

    /// `optionsState(for:)` with the writer's type known, which Swift opens
    /// from the `any TextExportWriter` it is given.
    @MainActor
    private static func makeOptionsState<Writer: TextExportWriter>(_ writer: Writer) -> any TextExportOptionsEditing {
        TextExportOptionsState(writer)
    }
}
