#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Combine
import Foundation
import os
import SwiftUI

// MARK: - The Export Setting

/// The preferences Export keeps (FR05), each defined once with its key and
/// stored form, for the settings model and config.json to share.
enum BookExportPreferences {
    /// Whether the reader's toolbar shows an Export button. Off until the
    /// user turns it on in Playback settings or config.json; File > Export…
    /// and the library's context menu are always there.
    static let showInReaderToolbar = StoredPreference.flag("showExportInReaderToolbar", default: false)
}

// MARK: - One Checkbox

/// One checkbox of the Export dialog: a kind, with what the books chosen
/// hold of it.
struct BookExportChoice: Equatable, Identifiable {
    /// The kind the checkbox exports.
    let kind: BookExportKind
    /// The books' items of this kind, in the order of the books.
    let items: [BookExportItem]
    /// How many books the dialog exports from.
    let bookCount: Int

    var id: BookExportKind { kind }

    /// The items that can be exported now: those on this Mac (FR02).
    var availableItems: [BookExportItem] {
        items.filter { !$0.isInCloud }
    }

    /// Whether anything of this kind can be exported now; the checkbox is
    /// unavailable otherwise.
    var isAvailable: Bool {
        !availableItems.isEmpty
    }

    /// How many of the items are only in the cloud.
    var inCloudCount: Int {
        items.count - availableItems.count
    }

    /// The checkbox's label, which the screen shows and VoiceOver speaks
    /// (`BookExportWording.choiceLabel`).
    var label: String {
        label(convertedTo: nil)
    }

    /// The checkbox's label while its text is converted to the writer named
    /// `conversionName` (nil: as it is), as in "Text as HTML, about 12 KB",
    /// or while its transcript is written as `transcriptConversionName`, a
    /// format of captions or a text writer (FMT23; nil: as TextMouth keeps
    /// it), as in "Transcript as WebVTT".
    func label(
        convertedTo conversionName: String?,
        transcriptAs transcriptConversionName: String? = nil
    ) -> String {
        let available = availableItems
        return BookExportWording.choiceLabel(
            kind: kind,
            bookCount: bookCount,
            availableItemCount: available.count,
            fileCount: available.reduce(0) { $0 + $1.files.count },
            byteCount: available.reduce(0) { $0 + $1.byteCount },
            inCloudCount: inCloudCount,
            convertedTo: conversionName,
            transcriptAs: transcriptConversionName
        )
    }

    /// The choices `offers` give: one for each kind any of their books
    /// holds, in the dialog's order. Spoken audio (FMT43) is offered for one
    /// book alone, since its range and sliders are that book's.
    static func choices(for offers: [BookExportOffer]) -> [BookExportChoice] {
        BookExportKind.allCases.compactMap { kind in
            if kind == .spokenAudio && offers.count != 1 { return nil }
            let items = offers.compactMap { $0.item(kind) }
            return items.isEmpty ? nil : BookExportChoice(kind: kind, items: items, bookCount: offers.count)
        }
    }
}

// MARK: - One Choice of the Convert To Picker

/// One choice of the Convert to picker (FMT18): Markdown, the export without
/// a conversion, or a text writer. Beside the Transcript checkbox (FMT23):
/// JSON and Markdown, the export without a conversion, a text writer for the
/// transcript's text, or a format of captions.
struct BookExportConversionChoice: Identifiable, Equatable {
    /// The writer's `id`, or `TextExportWriters.markdownID` for Markdown;
    /// beside Transcript, also `TranscriptExportFormat.jsonAndMarkdownChoiceID`
    /// or a format's `choiceID`.
    let id: String
    /// The choice's name, as the picker lists it and VoiceOver speaks it.
    let name: String
    /// What the picker's hint says while this choice is made.
    let hint: String
}

// MARK: - The Dialog's Model

/// The Export dialog of one or several books (FR05): what they can export,
/// which kinds are checked, where they go, and the export itself.
///
/// What the books hold is listed off the main thread when the dialog opens
/// (`load()`), and listed again for the books as the library holds them
/// when Export is pressed, so a book moved meanwhile is exported from where
/// it is. The export runs off the main thread too, with its progress here,
/// and ends with one announcement naming how many items went where, and
/// anything that could not be exported, in the cloud included.
///
/// A chapter that nests quotes, lists, or emphasis past the reader's limit is
/// put to the person while the export runs (FR24, `DeepChapterPrompt`): write
/// it as plain paragraphs of its lines, do so for every such chapter of the
/// export, or cancel the whole export, which ends as Stop does. The export's
/// thread waits for the answer, and Stop takes the question down as a cancel.
///
/// For one text book the dialog also offers its text as spoken audio (FMT43):
/// the options are made the first time the kind is checked (`speechOptions`),
/// since that reads the book's whole text for its headings, which no other
/// kind needs; an export that takes the kind runs `SpeechExportJob` with them,
/// showing which chapter is being spoken, and saying at its end what it kept
/// for the next export.
@MainActor
final class BookExportModel: ObservableObject, Identifiable {
    /// Where the dialog is.
    enum Phase: Equatable {
        /// Finding what the books hold.
        case listing
        /// Showing the checkboxes, ready to export.
        case ready
        /// Exporting: how many files are done, out of how many.
        case exporting(done: Int, total: Int)
        /// The export ended, as the outcome says.
        case finished(BookExportOutcome)
    }

    /// Tells sheets presenting different dialogs apart.
    let id = UUID()
    /// The books to export, as they were chosen.
    let books: [Book]
    /// Where the dialog is now.
    @Published private(set) var phase: Phase = .listing
    /// The checkboxes, once the books have been listed.
    @Published private(set) var choices: [BookExportChoice] = []
    /// The books' offers, once listed.
    @Published private(set) var offers: [BookExportOffer] = []
    /// The kinds checked.
    @Published var checked: Set<BookExportKind> = []
    /// The folder the items go to.
    @Published var destination: URL
    /// Whether a folder has been chosen for `destination`. The Mac's dialog
    /// always starts in one (Documents); the iPhone's starts with none until
    /// the person has chosen one, and Export waits for it (FR31).
    @Published private(set) var isDestinationChosen: Bool
    /// The chosen folder's name as the person is told it, when the caller read it under the folder's scope (the
    /// iPhone's `PhoneExportFolder`); nil on the Mac, whose export names the folder as Finder shows it.
    @Published private(set) var destinationName: String?
    /// The folder's name as the sheet's row and the end of an export say it: the name read under its scope when there is one,
    /// else the name its path gives (`BookExportWording.folderName(of:)`). The one fallback for both.
    var shownFolderName: String {
        destinationName ?? BookExportWording.folderName(of: destination)
    }
    /// How the last export's summary is worded, kept so that `summary` is made in the interface language in use when the
    /// dialog shows it, and follows a switch of language (FR39).
    @Published private var summaryWording: (() -> String)?
    /// What the last export said, kept in the dialog when it did not do
    /// everything asked.
    var summary: String? { summaryWording?() }
    /// How the end of the last export is worded whether or not it did everything
    /// asked, which the iPhone's sheet shows where the Mac's dialog closes.
    @Published private var finishedWording: (() -> String)?
    /// What the last export did, in the interface language in use now: kept
    /// from the end of an export until the next begins.
    var finishedWords: String? { finishedWording?() }
    /// The Convert to picker's choice for each kind that has one: a writer's
    /// `id`. A kind not here is on Markdown, so a dialog nobody touched
    /// exports as it always has. The transcript's picker (FMT23) keeps its
    /// choice here too, and is on JSON and Markdown until one is made.
    @Published private(set) var conversionIDs: [BookExportKind: String] = [:]
    /// How far spoken audio's options are made.
    enum SpeechOptionsMaking {
        /// Not yet: the kind has not been checked.
        case notMade
        /// The book's text is being read for its headings.
        case making
        /// Made, as they stand now.
        case made(SpeechExportOptionsState)
        /// The book's text can't be read, so it can't be spoken.
        case unreadable
    }

    /// How far spoken audio's options are made: they are made the first time
    /// the kind is checked (`setChecked(_:for:)`).
    @Published private(set) var speechOptionsMaking = SpeechOptionsMaking.notMade

    /// The spoken audio options, once made: nil until the kind is first
    /// checked, and for a book whose text can't be read.
    var speechOptions: SpeechExportOptionsState? {
        if case .made(let options) = speechOptionsMaking { return options }
        return nil
    }
    /// How far a speech export has come while it speaks or encodes; nil before
    /// and after it.
    @Published private(set) var speechProgress: SpeechExportProgress?

    /// How files are checked and read without downloading (FR02).
    private let access: MaintenanceFileAccess
    /// The text writers the Convert to picker offers after Markdown, in its
    /// order.
    private let writers: [any TextExportWriter]
    /// The books as the library holds them now, for the export.
    private let currentBooks: @MainActor ([Book]) -> [Book]
    /// Returns once none of the books is having its download taken off this device (the library's
    /// `booksBeingFreed`, FR46); at once without a library.
    private let waitWhileFreeing: @MainActor ([UUID]) async -> Void
    /// The export under way's Cancel.
    private var cancellation: BookExportCancellation?
    /// The options of each writer chosen so far, by writer `id`, kept for the
    /// dialog's life so that choosing another writer and coming back finds
    /// them as they were.
    private var optionsStates: [String: any TextExportOptionsEditing] = [:]
    /// Says, once for each change of any writer's options, that they changed: the one place a view that shows options
    /// beside a list's rows hears them (the iPhone's braille rows, which no row may listen for, since a row
    /// can scroll away and take the listener with it).
    let optionsChanged = PassthroughSubject<Void, Never>()
    /// What forwards each writer's changes to `optionsChanged`.
    private var optionsSubscriptions: [AnyCancellable] = []
    /// What a speech export reaches: the synthesizer, the voices, the power
    /// assertion, the disks, and the folder its chapters are kept in.
    private let speechEnvironment: SpeechExportEnvironment
    /// The kinds the dialog offers: every kind on the Mac, and the iPhone's
    /// (`PhoneExportOffer.kinds`) on the iPhone.
    private let offeredKinds: Set<BookExportKind>
    /// How each file is made and put in the folder chosen: the move on the
    /// Mac, the coordinated copy on the iPhone (`BookExportDelivery`).
    private let delivery: BookExportDelivery
    /// What is asked before a book's text is converted, so that a book too
    /// large for the memory left fails alone (`BookExportMemoryGuard`); nil
    /// on the Mac, which asks nothing.
    private let memoryGuard: BookExportMemoryGuard?
    /// Holds what an export needs from its start to its end, given the
    /// folder it goes to, and returns what lets it go: on the iPhone, the
    /// folder's security scope (the folder the picker returned is reached only
    /// through it) and a background task, so that locking the screen does not
    /// cut a file off. Holds nothing by default, as the Mac's export needs
    /// neither.
    private let holdWhileExporting: @MainActor (URL) -> (@MainActor () -> Void)
    /// The preferences holding the global voice, speed, pitch, and pause
    /// level, which a book without its own speaks with.
    private let speechDefaults: UserDefaults
    /// The substitution rules and repeated-symbol settings speech is prepared
    /// with.
    private let substitutionService: TextSubstitutionService
    /// The speech exports under way, which a quit stops cleanly first.
    private let speechExportsUnderWay: SpeechExportsUnderWay
    /// How the question about a chapter nested too deeply (FR24) is put to
    /// the person; nil where nobody can be asked, when such a chapter fails
    /// its book's file as it did before the question.
    private let deepChapterPrompt: DeepChapterPrompt?
    #if os(macOS)
    // The Mac's alert is its own (`ExportDeepChapterAlert`), so it has no prompt here.
    #else
    /// On the iPhone, the question about a chapter nested too deeply that the
    /// export waits on, which the sheet shows as an alert while it is
    /// pending; nil for any way of asking but the standard one. Named only in
    /// the iPhone's branch, since the Mac never reaches the iPhone's types.
    private(set) var questionPrompt: PhoneExportQuestionPrompt?
    #endif

    /// How the question about a chapter nested too deeply is put to the
    /// person: shown over the dialog's window, and taken down by Stop. Both
    /// run on the main actor, while the export's thread waits for the answer.
    struct DeepChapterPrompt: Sendable {
        /// Shows `question`, over `window` (the Export dialog's own, if it
        /// is known), and returns the answer.
        let ask: @MainActor @Sendable (ExportDeepChapterQuestion, PlatformWindow?) async -> ExportDeepChapterAnswer
        /// Takes the question down if it is showing, answered as Cancel
        /// Export.
        let dismiss: @MainActor @Sendable () -> Void

        /// A prompt that asks through `ask` and is taken down by `dismiss`
        /// (which a scripted prompt, with nothing on screen, leaves to do
        /// nothing).
        init(
            ask: @escaping @MainActor @Sendable (ExportDeepChapterQuestion, PlatformWindow?) async -> ExportDeepChapterAnswer,
            dismiss: @escaping @MainActor @Sendable () -> Void = {}
        ) {
            self.ask = ask
            self.dismiss = dismiss
        }
    }

    /// Who puts the question about a chapter nested too deeply.
    enum DeepChapterPrompting {
        /// The app's way: an alert over the dialog on the Mac, and on the
        /// iPhone an alert of the sheet's own.
        case standard
        /// Nobody can be asked: such a chapter fails its book's file.
        case unavailable
        /// A prompt of the caller's own, which a test scripts so that no
        /// alert is shown.
        case custom(DeepChapterPrompt)
    }

    /// The folder an export went to last this session, which the next
    /// dialog starts in.
    private static var lastDestination: URL?

    /// The folder the dialog starts in: where the last export this session
    /// went, or the Documents folder of the home the runtime names, which
    /// is the user's in the app and the test sandbox's under hosted tests
    /// (`TextMouthRuntime`), so no test can write into the user's files.
    static var defaultDestination: URL {
        lastDestination
            ?? TextMouthRuntime.current.homeDirectory.appendingPathComponent("Documents", isDirectory: true)
    }

    /// A dialog exporting `books`.
    /// - Parameters:
    ///   - books: The books chosen.
    ///   - library: The library, whose rows give the books as they are when
    ///     Export is pressed; nil exports the books as chosen.
    ///   - destination: The folder to start in; nil starts in
    ///     `defaultDestination`.
    ///   - access: How files are checked and read; tests pass a cloud of
    ///     their own.
    ///   - writers: The text writers the picker offers. The app always
    ///     passes all of them (`TextExportWriters.all`); a test passes
    ///     writers of its own, such as one with options.
    ///   - speechEnvironment: What a speech export reaches; tests pass fakes,
    ///     so that nothing speaks and nothing keeps the Mac awake.
    ///   - speechDefaults: The preferences holding the global voice, speed,
    ///     pitch, and pause level; the sandbox's under hosted tests.
    ///   - substitutionService: The substitution rules speech is prepared
    ///     with.
    ///   - speechExportsUnderWay: Where a speech export says it begins and
    ///     ends, so that a quit stops it cleanly first; the app's own unless a
    ///     test gives one.
    ///   - deepChapterPrompting: Who puts the question about a chapter nested
    ///     too deeply; the standard way asks with an alert. A test passes a
    ///     scripted answer.
    ///   - offering: The kinds the dialog offers; nil offers every kind. The
    ///     iPhone passes `PhoneExportOffer.kinds`.
    ///   - destinationIsChosen: Whether `destination` is a folder the person
    ///     chose. The Mac's always is; the iPhone's is not until its picker
    ///     has returned one, and Export waits for it.
    ///   - destinationName: The folder's name as read under its scope, which the end of an export says; nil
    ///     names it as Finder shows it.
    ///   - delivery: How each file is made and put in the folder chosen.
    ///   - memoryGuard: What is asked before a book's text is converted.
    ///   - holdWhileExporting: Holds what an export needs while it runs, and
    ///     returns what lets it go.
    init(
        books: [Book],
        library: LibraryViewModel? = nil,
        destination: URL? = nil,
        access: MaintenanceFileAccess = .live,
        writers: [any TextExportWriter] = TextExportWriters.all,
        speechEnvironment: SpeechExportEnvironment = .live,
        speechDefaults: UserDefaults = TextMouthRuntime.current.preferences,
        substitutionService: TextSubstitutionService = .shared,
        speechExportsUnderWay: SpeechExportsUnderWay = .shared,
        deepChapterPrompting: DeepChapterPrompting = .standard,
        offering offeredKinds: Set<BookExportKind>? = nil,
        destinationIsChosen: Bool = true,
        destinationName: String? = nil,
        delivery: BookExportDelivery = .standard,
        memoryGuard: BookExportMemoryGuard? = nil,
        holdWhileExporting: @escaping @MainActor (URL) -> (@MainActor () -> Void) = { _ in {} }
    ) {
        switch deepChapterPrompting {
        case .standard:
            #if os(macOS)
            // The alert is this model's own, so that Stop can take it down.
            let alert = ExportDeepChapterAlert()
            deepChapterPrompt = DeepChapterPrompt(
                ask: { question, window in await alert.ask(question, in: window) },
                dismiss: { alert.dismiss() }
            )
            #else
            // The sheet shows the question as an alert of its own, which Stop
            // takes down as a Cancel Export (`questionPrompt`).
            let prompt = PhoneExportQuestionPrompt()
            questionPrompt = prompt
            deepChapterPrompt = DeepChapterPrompt(
                ask: { question, _ in await prompt.ask(question) },
                dismiss: { prompt.dismiss() }
            )
            #endif
        case .unavailable:
            deepChapterPrompt = nil
        case .custom(let prompt):
            deepChapterPrompt = prompt
        }
        self.books = books
        self.offeredKinds = offeredKinds ?? Set(BookExportKind.allCases)
        self.isDestinationChosen = destinationIsChosen
        self.destinationName = destinationName
        self.delivery = delivery
        self.memoryGuard = memoryGuard
        self.holdWhileExporting = holdWhileExporting
        self.destination = destination ?? Self.defaultDestination
        self.access = access
        self.writers = writers
        self.speechEnvironment = speechEnvironment
        self.speechDefaults = speechDefaults
        self.substitutionService = substitutionService
        self.speechExportsUnderWay = speechExportsUnderWay
        currentBooks = { [weak library] chosen in
            chosen.map { library?.bookByID($0.id) ?? $0 }
        }
        waitWhileFreeing = { [weak library] bookIDs in
            await library?.booksBeingFreed.waitUntilFreed(bookIDs)
        }
    }

    // MARK: Listing

    /// Lists what the books hold, off the main thread, and shows the
    /// checkboxes, the first kind that can be exported checked. Nothing reads
    /// a book's text here: spoken audio's options are made once the kind is
    /// checked.
    func load() async {
        phase = .listing
        let listed = await Self.offers(for: books, access: access)
        offers = listed
        speechOptionsMaking = .notMade
        choices = BookExportChoice.choices(for: listed).filter { offeredKinds.contains($0.kind) }
        if let first = choices.first(where: \.isAvailable) {
            checked = [first.kind]
        }
        phase = .ready
    }

    /// What `books` can export, listed off the main thread.
    private static func offers(for books: [Book], access: MaintenanceFileAccess) async -> [BookExportOffer] {
        await OffMainWork.run {
            books.map { BookExportService.offer(for: $0, access: access) }
        }
    }

    /// The spoken audio options of the one book `offers` list: its headings,
    /// read off the main thread as the reader parses them, and the voice,
    /// speed, and pitch it is read with now, as the library holds it. Nil when
    /// its text cache cannot be read.
    private func makeSpeechOptions(from offers: [BookExportOffer]) async -> SpeechExportOptionsState? {
        guard let offer = offers.first, let markdown = offer.item(.spokenAudio)?.files.first?.source.url else {
            return nil
        }
        let access = self.access
        let title = offer.book.title
        let headings = await OffMainWork.run { () -> [Heading]? in
            try? access.read(markdown) {
                let bytes = try Data(contentsOf: markdown)
                return try BookExportService.readingContent(fromMarkdown: bytes, at: markdown, title: title).allHeadings
            }
        }
        guard let headings else { return nil }
        let book = currentBooks([offer.book]).first ?? offer.book
        let environment = speechEnvironment
        let settings = SpeechExportVoiceSettings.of(
            book,
            defaults: speechDefaults,
            isInstalled: { environment.voiceInfo($0) != nil }
        )
        return SpeechExportOptionsState(
            headings: headings,
            skippedHeadingIDs: Set(book.skippedHeadingIDs ?? []),
            voice: settings.voiceIdentifier.flatMap { environment.voiceInfo($0) },
            settings: settings
        )
    }

    // MARK: State the Dialog Shows

    /// The dialog's title (`BookExportWording.title(bookTitles:)`).
    var title: String {
        BookExportWording.title(bookTitles: books.map(\.title))
    }

    /// Whether the checkbox of `kind` is checked.
    func isChecked(_ kind: BookExportKind) -> Bool {
        checked.contains(kind)
    }

    /// Checks or unchecks the checkbox of `kind`. Spoken audio checked for
    /// the first time, and on this Mac, has its options made.
    func setChecked(_ isChecked: Bool, for kind: BookExportKind) {
        if isChecked {
            checked.insert(kind)
            if kind == .spokenAudio {
                makeSpeechOptionsOnce()
            }
        } else {
            checked.remove(kind)
        }
    }

    /// Makes spoken audio's options, off the main thread, unless they are
    /// made or being made, or the kind is not on this Mac: reading the book's
    /// whole text for its headings takes up to a second for a large book,
    /// which only someone who wants spoken audio waits for.
    private func makeSpeechOptionsOnce() {
        guard case .notMade = speechOptionsMaking,
              choices.contains(where: { $0.kind == .spokenAudio && $0.isAvailable }) else { return }
        speechOptionsMaking = .making
        let listed = offers
        Task {
            let made = await makeSpeechOptions(from: listed)
            // A dialog listed again meanwhile makes them afresh.
            guard case .making = speechOptionsMaking else { return }
            speechOptionsMaking = made.map(SpeechOptionsMaking.made) ?? .unreadable
        }
    }

    /// Whether an export is under way.
    var isExporting: Bool {
        if case .exporting = phase { return true }
        return false
    }

    /// Whether Export can be pressed: the books are listed, nothing is
    /// being exported, a folder is chosen, and a checked kind has something
    /// on this Mac, spoken audio only once its options are made.
    var canExport: Bool {
        switch phase {
        case .listing, .exporting:
            return false
        case .ready, .finished:
            return isDestinationChosen && choices.contains { choice in
                checked.contains(choice.kind) && choice.isAvailable && (choice.kind != .spokenAudio || speechOptions != nil)
            }
        }
    }

    /// Why some of the books' items cannot be exported now, being only in
    /// the cloud (FR02), in the list's words; nil when none is.
    var cloudNotice: String? {
        let titles = offers
            .filter { offer in offer.isPackageInCloud || offer.items.contains(where: \.isInCloud) }
            .map(\.book.title)
        return titles.isEmpty ? nil : LibraryCloudWording.notDownloaded(titles: titles)
    }

    /// The export's progress as the dialog shows and speaks it, while one
    /// is under way: which chapter is being spoken, or that the audio file is
    /// being encoded, while a speech export works; otherwise how many items
    /// are done.
    var progressText: String? {
        guard case .exporting(let done, let total) = phase else { return nil }
        if let speechProgress, let words = SpeechExportWording.progress(speechProgress) {
            return words
        }
        return BookExportWording.progress(done: done, total: total)
    }

    /// How full the progress bar is, from 0 to 1, while an export is under
    /// way: the speech export's own fraction while it works, otherwise the
    /// items done of all; nil before the items have been counted, when the
    /// bar says only that something is happening.
    var progressFraction: Double? {
        guard case .exporting(let done, let total) = phase else { return nil }
        if let fraction = speechProgress?.fraction {
            return fraction
        }
        return total > 0 ? Double(done) / Double(total) : nil
    }

    /// Whether the export under way takes spoken audio, whose Stop keeps the
    /// chapters already spoken. The checkboxes are disabled while an export
    /// runs, so the kinds checked are the kinds it took.
    var isExportingSpeech: Bool {
        isExporting && isChecked(.spokenAudio)
    }

    /// Words that start the sentence of the export's end, set by the iPhone's session when iOS, not the person, stopped it
    /// (`PhoneExportSession.stopBySystem(_:)`); nil for any other end. Taken, and cleared, as the export ends.
    var wordsBeforeTheEnd: String?

    /// How urgent the announcement of the export's end is: high while the sheet shows, low once the sheet has closed on
    /// an export that goes on, whose end is a background result (`PhoneExportSession.sheetClosed(_:)`).
    var announcementPriority: NSAccessibilityPriorityLevel = .high

    /// Whether the spoken audio file is being made now: its chapters spoken, or the file encoded. Only then may the
    /// iPhone's sheet close and the export go on. A file of the same book can follow it (a transcript, an original), and
    /// asks about a chapter nested too deeply, which needs the sheet; with the sheet closed the iPhone's prompt answers
    /// Cancel Export (`PhoneExportQuestionPrompt.sheetClosed()`).
    var isMakingSpeech: Bool {
        isExporting && speechProgress != nil
    }

    // MARK: Converting

    /// The choices of the Convert to picker beside the checkbox of `kind`:
    /// Markdown, then each text writer in order, for a kind whose text a
    /// writer can convert; JSON and Markdown, each text writer, then each
    /// format of captions, for the transcript (FMT23,
    /// `transcriptConversionChoices`); none for any other kind.
    func conversionChoices(for kind: BookExportKind) -> [BookExportConversionChoice] {
        if kind == .transcript {
            return transcriptConversionChoices
        }
        // An audiobook's headings and bookmarks are always written in a
        // format chosen here (FMT24, FMT06), the first until another is. A
        // kind of one format (bookmarks, as Audacity labels) has no pop-up:
        // its checkbox names the format ("Bookmarks as Audacity labels").
        if let source = kind.chapterListSource {
            let formats = ChapterListFormat.formats(for: source)
            guard formats.count > 1 else { return [] }
            return formats.map { format in
                BookExportConversionChoice(
                    id: format.choiceID,
                    name: format.name,
                    hint: BookExportWording.chapterListChoiceHint(for: format, source: source)
                )
            }
        }
        guard kind.convertsText else { return [] }
        let markdown = BookExportConversionChoice(
            id: TextExportWriters.markdownID,
            name: BookExportWording.markdownChoiceName,
            hint: BookExportWording.markdownChoiceHint
        )
        return [markdown] + writerChoices
    }

    /// The text writers as choices of a picker, in order, each by its `id`,
    /// name, and hint, the same beside Text as Markdown and beside
    /// Transcript.
    private var writerChoices: [BookExportConversionChoice] {
        writers.map {
            BookExportConversionChoice(id: $0.id, name: $0.name, hint: $0.hint)
        }
    }

    /// The choices of the Convert transcript to picker beside the Transcript
    /// checkbox (FMT23): JSON and Markdown, the transcript as TextMouth keeps
    /// it (the default, today's export); each text writer, which writes the
    /// transcript's text (TODO 3984); then each format of captions.
    private var transcriptConversionChoices: [BookExportConversionChoice] {
        let asKept = BookExportConversionChoice(
            id: TranscriptExportFormat.jsonAndMarkdownChoiceID,
            name: BookExportWording.transcriptJSONChoiceName,
            hint: BookExportWording.transcriptJSONChoiceHint
        )
        let captions = TranscriptExportFormat.allCases.map { format in
            BookExportConversionChoice(
                id: format.choiceID,
                name: format.name,
                hint: BookExportWording.transcriptChoiceHint(for: format)
            )
        }
        return [asKept] + writerChoices + captions
    }

    /// The writer whose `id` is `id` among the picker's writers; nil for
    /// Markdown and for an unknown `id`.
    private func writer(id: String) -> (any TextExportWriter)? {
        writers.first { $0.id == id }
    }

    /// The `id` of the picker's choice for `kind`: its first choice until
    /// another is chosen, which is Markdown, or JSON and Markdown beside
    /// Transcript (FMT23). A kind with no picker gives Markdown's `id`, as it
    /// always did.
    func conversionID(for kind: BookExportKind) -> String {
        conversionIDs[kind] ?? conversionChoices(for: kind).first?.id ?? TextExportWriters.markdownID
    }

    /// Chooses `id` in the picker beside the checkbox of `kind`. A kind with
    /// no picker, and an `id` the picker does not list, change nothing. The
    /// first time a writer is chosen, its options are made as each dialog
    /// starts them.
    func setConversionID(_ id: String, for kind: BookExportKind) {
        guard conversionChoices(for: kind).contains(where: { $0.id == id }) else { return }
        conversionIDs[kind] = id
        if let writer = writer(id: id), optionsStates[id] == nil {
            let state = TextExportWriters.optionsState(for: writer)
            optionsStates[id] = state
            optionsSubscriptions.append(state.changes.sink { [optionsChanged] in optionsChanged.send() })
        }
    }

    /// The choice the picker beside the checkbox of `kind` shows; nil for a
    /// kind with no picker.
    func conversionChoice(for kind: BookExportKind) -> BookExportConversionChoice? {
        let id = conversionID(for: kind)
        return conversionChoices(for: kind).first { $0.id == id }
    }

    /// The name of the writer `kind`'s text is converted to; nil on Markdown
    /// and for a kind with no picker, which the checkbox says as it is, and
    /// for the transcript, whose checkbox names its own conversion
    /// (`transcriptFormat(for:)`, `transcriptWriter(for:)`).
    private func conversionName(for kind: BookExportKind) -> String? {
        if let format = chapterListFormat(for: kind) {
            return format.name
        }
        guard kind.convertsText else { return nil }
        return writer(id: conversionID(for: kind))?.name
    }

    /// The format an audiobook's headings or bookmarks are written in
    /// (FMT24, FMT06): the one chosen beside the checkbox, the kind's first
    /// until another is; nil for every other kind.
    private func chapterListFormat(for kind: BookExportKind) -> ChapterListFormat? {
        guard let source = kind.chapterListSource else { return nil }
        let formats = ChapterListFormat.formats(for: source)
        return formats.first { $0.choiceID == conversionID(for: kind) } ?? formats.first
    }

    /// The format of captions the transcript is written in (FMT23): the one
    /// chosen beside the Transcript checkbox; nil on JSON and Markdown, on a
    /// text writer, and for every other kind.
    private func transcriptFormat(for kind: BookExportKind) -> TranscriptExportFormat? {
        guard kind == .transcript else { return nil }
        return TranscriptExportFormat(choiceID: conversionID(for: kind))
    }

    /// The text writer the transcript's text is written by (TODO 3984): the
    /// one chosen beside the Transcript checkbox; nil on JSON and Markdown,
    /// on a format of captions, and for every other kind.
    private func transcriptWriter(for kind: BookExportKind) -> (any TextExportWriter)? {
        guard kind == .transcript else { return nil }
        return writer(id: conversionID(for: kind))
    }

    /// The label of `choice`'s checkbox, saying the conversion chosen.
    func label(for choice: BookExportChoice) -> String {
        let transcriptConversion = transcriptFormat(for: choice.kind)?.name ?? transcriptWriter(for: choice.kind)?.name
        return choice.label(convertedTo: conversionName(for: choice.kind), transcriptAs: transcriptConversion)
    }

    /// The hint of the checkbox of `kind`, saying the conversion chosen.
    func hint(for kind: BookExportKind) -> String {
        if let format = transcriptFormat(for: kind) {
            return BookExportWording.transcriptHint(as: format)
        }
        if let format = chapterListFormat(for: kind), let source = kind.chapterListSource {
            return BookExportWording.chapterListChoiceHint(for: format, source: source)
        }
        if let textWriter = transcriptWriter(for: kind) {
            return BookExportWording.transcriptTextHint(as: textWriter.name)
        }
        return BookExportWording.hint(for: kind, convertedTo: conversionName(for: kind))
    }

    /// The options view to show under the checkbox of `kind`: spoken audio's
    /// own, or the one of the writer chosen in the kind's picker; nil while
    /// the kind is unchecked, on Markdown, or when the writer takes no
    /// options. Beside Transcript, the same: nil too on JSON and Markdown and
    /// on captions. A writer chosen beside both checkboxes has one options
    /// state, which both views set.
    func optionsView(for kind: BookExportKind) -> AnyView? {
        optionsState(for: kind)?.makeView() ?? spokenAudioOptionsView(for: kind)
    }

    /// The options of the writer chosen beside the checkbox of `kind`, which
    /// the iPhone's rows read and set where the Mac's view does; nil while
    /// the kind is unchecked, on Markdown, on a format of captions, for
    /// spoken audio, and when the writer takes no options.
    func optionsState(for kind: BookExportKind) -> (any TextExportOptionsEditing)? {
        guard kind != .spokenAudio, isChecked(kind),
              let state = optionsStates[conversionID(for: kind)], state.hasOptions else {
            return nil
        }
        return state
    }

    /// Spoken audio's options view, or the line saying why there is none yet,
    /// under its checkbox; nil for any other kind, and while the kind is
    /// unchecked.
    private func spokenAudioOptionsView(for kind: BookExportKind) -> AnyView? {
        if kind == .spokenAudio {
            guard isChecked(kind) else { return nil }
            switch speechOptionsMaking {
            case .notMade:
                return nil
            case .making:
                return AnyView(ProgressView(SpeechExportWording.readingHeadings).progressViewStyle(.linear))
            case .made(let options):
                return AnyView(SpeechExportOptionsView(state: options))
            case .unreadable:
                return AnyView(Text(SpeechExportWording.unreadableText).fixedSize(horizontal: false, vertical: true))
            }
        }
        return nil
    }

    /// The conversions an export makes now: for each checked kind on a
    /// writer, that writer with its options as they are. Markdown has no
    /// options state, so a kind on Markdown has no conversion here: its
    /// files stay as the offer lists them, the Markdown the offer writes.
    /// Spoken audio, while checked, is the speech its options ask for. The
    /// transcript, checked and on a format of captions, is written as
    /// captions (FMT23), and on a writer, its text by that writer, as a text
    /// book's is (TODO 3984); on JSON and Markdown, it has no conversion
    /// either.
    var conversions: [BookExportKind: BookExportConversion] {
        var made: [BookExportKind: BookExportConversion] = [:]
        for kind in checked {
            if let state = optionsStates[conversionID(for: kind)] {
                made[kind] = .text(state.conversion())
            }
            if let format = transcriptFormat(for: kind) {
                made[kind] = .timedText(format)
            }
            if let format = chapterListFormat(for: kind), let source = kind.chapterListSource {
                made[kind] = .chapterList(format, of: source)
            }
        }
        if isChecked(.spokenAudio), let request = speechRequest {
            made[.spokenAudio] = .speech(request)
        }
        return made
    }

    /// What a speech export of the one book speaks, as the library holds the
    /// book now and the options stand now; nil without options.
    private var speechRequest: SpeechExportRequest? {
        guard let options = speechOptions, let book = currentBooks(books).first else { return nil }
        let choices = options.choices
        let fileTitle = options.fileTitle(bookTitle: book.title)
        return SpeechExportRequest(
            bookID: book.id,
            bookTitle: book.title,
            fileTitle: fileTitle,
            // A range is titled as its file is named, so that a player's list
            // tells it from the whole book and from the book's other ranges.
            titleTag: choices.range.isWholeBook ? book.title : fileTitle,
            author: ExportBookDetails(book).author,
            format: choices.format,
            range: choices.range,
            voice: SpeechExportVoiceSettings(
                voiceIdentifier: options.voice?.identifier,
                wordsPerMinute: choices.wordsPerMinute,
                pitch: choices.pitch
            ),
            skippedHeadingIDs: Set(book.skippedHeadingIDs ?? []),
            preparation: SpeechPreparationSettings.current(substitutions: substitutionService, defaults: speechDefaults)
        )
    }

    // MARK: Exporting

    /// Exports the checked kinds of the books, as the library holds them
    /// now, into `destination`, off the main thread, and announces how it
    /// ended from `window`. The dialog keeps the summary when anything
    /// could not be exported. An export that ends without its spoken audio
    /// file says too what it kept for the next export.
    /// `dialog` is the Export dialog's own window, which the question about a
    /// chapter nested too deeply is shown over (FR24).
    /// - Returns: What the export did; nil when it could not start.
    @discardableResult
    func export(
        announcingFrom window: PlatformWindow? = nil,
        presentingFrom dialog: PlatformWindow? = nil
    ) async -> BookExportOutcome? {
        guard canExport else { return nil }
        let earlier = (phase: phase, summary: summaryWording, finished: finishedWording)
        let cancellation = BookExportCancellation()
        self.cancellation = cancellation
        summaryWording = nil
        finishedWording = nil
        phase = .exporting(done: 0, total: 0)
        // A braille table just chosen in the options may still be checked.
        // Waiting for it is part of exporting (review R5, F3): Stop is offered
        // meanwhile, and Stop, or the dialog closing, ends the export before
        // it reads its options or writes anything. It then writes with the
        // table the pop-ups show once the check has passed, or the one they
        // returned to.
        await BrailleTableChoiceChecks.shared.finished(unless: cancellation)
        // A removal of a book's download whose last look has said yes ends first (FR46), so the export never reads
        // a book's files as they go; Stop is offered meanwhile too. Nothing waits from here until the books are
        // noted as being exported, so no removal begins between.
        await waitWhileFreeing(self.books.map(\.id))
        guard !cancellation.isCancelled else {
            self.cancellation = nil
            (phase, summaryWording, finishedWording) = earlier
            return nil
        }
        let kinds = checked
        // The conversions are read here, on the main actor, with the options
        // as they are now; the export takes the copy off the main thread.
        let conversions = self.conversions
        let speechFormat: SpeechExportFormat?
        if case .speech(let request)? = conversions[.spokenAudio] {
            speechFormat = request.format
        } else {
            speechFormat = nil
        }
        let folder = destination
        // The name as the row shows it, taken before the run's hold lets go of the folder's scope.
        let knownFolderName = shownFolderName
        guard !Self.isInsideDataDirectory(folder) else {
            self.cancellation = nil
            phase = earlier.phase
            summaryWording = { BookExportWording.destinationInLibrary }
            VoiceOverAnnouncer.announce(BookExportWording.destinationInLibrary, from: window)
            return nil
        }
        // The folder speech exports keep their chapters in is emptied when a
        // speech export finishes, and at the next launch, so nothing is
        // exported into it.
        guard !Self.isFolder(folder, inside: speechEnvironment.storeRoot) else {
            self.cancellation = nil
            phase = earlier.phase
            summaryWording = { SpeechExportWording.destinationInKeptChapters }
            VoiceOverAnnouncer.announce(SpeechExportWording.destinationInKeptChapters, from: window)
            return nil
        }
        let access = self.access
        Self.lastDestination = folder
        // What the run needs is held for the whole of it, and let go at its end.
        let releaseHold = holdWhileExporting(folder)
        defer { releaseHold() }
        let delivery = self.delivery
        let memoryGuard = self.memoryGuard

        let books = currentBooks(self.books)
        // The books are in use until the export ends, so no rule of the
        // feed engine removes a download it is reading (REV11 F1).
        let reading = books.map(\.id)
        Self.noteExportStarted(reading)
        defer { Self.noteExportEnded(reading) }
        // Each file done is shown on the main actor, as it is reported.
        let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in
                self?.showProgress(done: done, total: total)
            }
        }
        // The speech export's progress is kept as it is told, on the export's
        // own threads, so the end below reads the last of it for certain, and
        // shown on the main actor, always the latest, however the tasks that
        // show it interleave.
        let speechRecord = SpeechProgressRecord()
        let speech = SpeechExportContext(environment: speechEnvironment, progress: { [weak self] progress in
            speechRecord.keep(progress)
            Task { @MainActor in
                self?.showSpeechProgress(speechRecord.latest)
            }
        })
        // A chapter nested too deeply is put to the person (FR24): the export's
        // thread waits while the main actor asks. Stop or Close may come between
        // the thread's asking and the main actor's turn, when there is no alert
        // to take down yet, so the main actor looks again before it asks. With
        // nobody to ask, there is no question and such a chapter fails its file.
        let askAboutDeepChapters: ExportDeepChapterQuestioner.Ask? = deepChapterPrompt.map { prompt -> ExportDeepChapterQuestioner.Ask in
            return { question in
                let answer = try? AsyncBridge.waitForResult {
                    await Self.put(question, through: prompt, over: dialog, unless: cancellation)
                }
                return answer ?? .cancelExport
            }
        }
        // While spoken audio is made, a quit stops it cleanly first, with its
        // chapters kept, rather than cutting a chapter off midway.
        let underWay = speechFormat == nil ? nil : speechExportsUnderWay.begin(cancellation)
        let outcome = await OffMainWork.run {
            // The scratch folders an earlier run of the app left (the iPhone's; the Mac has none to sweep).
            delivery.removeStaleScratchFolders()
            let offers = books.map { BookExportService.offer(for: $0, access: access) }
            return BookExportService.export(
                offers,
                kinds: kinds,
                conversions: conversions,
                to: folder,
                access: access,
                cancellation: cancellation,
                progress: report,
                speech: speech,
                delivery: delivery,
                memoryGuard: memoryGuard,
                askAboutDeepChapters: askAboutDeepChapters
            )
        }
        if let underWay {
            speechExportsUnderWay.ended(underWay)
        }
        self.cancellation = nil
        speechProgress = nil
        phase = .finished(outcome)
        // The finished sentence is made from values taken now, by a closure that can be run again in another language.
        let latest = speechRecord.latest
        let format = speechFormat
        let folderName = knownFolderName
        // What the iPhone adds to the end's sentence: that iOS stopped the export, and that a question came with no one to ask.
        // iOS's words are for an export it stopped: one that finished before the stop took effect says it finished.
        let before = outcome.wasCancelled ? wordsBeforeTheEnd : nil
        wordsBeforeTheEnd = nil
        #if os(macOS)
        let after: String? = nil
        #else
        let after = questionPrompt?.wordsAfterTheEnd
        #endif
        let words: () -> String = {
            (before.map { $0 + " " } ?? "")
                + Self.finishedWords(outcome, folderName: folderName, latest: latest, speechFormat: format)
                + (after.map { " " + $0 } ?? "")
        }
        summaryWording = Self.didEverything(outcome) ? nil : words
        finishedWording = words
        VoiceOverAnnouncer.announce(words(), from: window, priority: announcementPriority)
        return outcome
    }

    /// The sentence an export's end says: what was exported, what speech kept, and, for an MP3 with more chapters than it
    /// has chapters for, that. Made from values, so it can be made again in another interface language.
    private static func finishedWords(
        _ outcome: BookExportOutcome,
        folderName: String,
        latest: SpeechExportProgress?,
        speechFormat: SpeechExportFormat?
    ) -> String {
        var words = BookExportWording.finished(outcome, folderName: folderName)
        if case .ended(let kept, let total)? = latest,
           let keptWords = SpeechExportWording.kept(done: kept, total: total) {
            words += " " + keptWords
        }
        // An MP3 made of more chapters than it has chapters for says so.
        if speechFormat == .mp3, case .ended(_, let chapters)? = latest, chapters > MP3Tag.maximumChapters,
           outcome.exported.contains(where: { $0.pathExtension == SpeechExportFormat.mp3.fileExtension }) {
            words += " " + SpeechExportWording.mp3ChaptersKept(of: chapters)
        }
        return words
    }

    /// Shows that `done` files of `total` are exported, while the export is
    /// still under way: a report arriving after it ended changes nothing.
    private func showProgress(done: Int, total: Int) {
        guard isExporting else { return }
        phase = .exporting(done: done, total: total)
    }

    /// Shows how far the speech export has come, while the export is still
    /// under way: a report arriving after it ended changes nothing, and once
    /// the speech export has ended the bar goes back to the items done.
    /// (Not private so that a test can show each stage while it holds an
    /// export at a chosen place.)
    func showSpeechProgress(_ progress: SpeechExportProgress?) {
        guard isExporting else { return }
        speechProgress = progress?.fraction == nil ? nil : progress
    }

    /// Puts `question` to the person through `prompt`, over `dialog`, on the
    /// main actor, unless `cancellation` says the export has stopped: Stop or
    /// Close may come between the export thread's asking and the main actor's
    /// turn, when there is no alert yet for `stop()` to take down, and a
    /// question for a stopped export would then be shown, over the Library
    /// window if the dialog had closed. A stopped export answers Cancel Export.
    @MainActor
    static func put(
        _ question: ExportDeepChapterQuestion,
        through prompt: DeepChapterPrompt,
        over dialog: PlatformWindow?,
        unless cancellation: BookExportCancellation
    ) async -> ExportDeepChapterAnswer {
        guard !cancellation.isCancelled else { return .cancelExport }
        return await prompt.ask(question, dialog)
    }

    /// Stops the export under way before its next file, or within a moment
    /// while a chapter is spoken or the audio file encoded. A question about a
    /// chapter nested too deeply that is on screen is answered Cancel Export,
    /// so the export, which waits for it, ends too.
    func stop() {
        cancellation?.cancel()
        deepChapterPrompt?.dismiss()
    }

    // MARK: Books Being Exported

    /// How many exports under way read each book, by ID: every dialog's
    /// export counts apart, so two exports of one book both end before the
    /// book is no longer read (REV11 F1).
    private static var exportsReading: [UUID: Int] = [:]

    /// The books the exports under way are reading now, by ID. The feed
    /// engine's rules never remove a download one of them reads, leaving it
    /// for their next pass (`LibraryViewModel.feedBooksInUse`), so no
    /// export loses its file partway (REV11 F1).
    static var booksBeingExported: Set<UUID> {
        Set(exportsReading.keys)
    }

    /// Notes that an export reads the books `bookIDs` from now until
    /// `noteExportEnded(_:)` says it ended.
    static func noteExportStarted(_ bookIDs: [UUID]) {
        for bookID in Set(bookIDs) {
            exportsReading[bookID, default: 0] += 1
        }
    }

    /// Notes that an export of the books `bookIDs`, begun with
    /// `noteExportStarted(_:)`, has ended; a book another export still reads
    /// stays in use.
    static func noteExportEnded(_ bookIDs: [UUID]) {
        for bookID in Set(bookIDs) {
            guard let count = exportsReading[bookID] else { continue }
            exportsReading[bookID] = count > 1 ? count - 1 : nil
        }
    }

    /// Whether `folder` is TextMouth's data directory or inside it, where
    /// exported files would sit among the library's own folders and files.
    static func isInsideDataDirectory(_ folder: URL) -> Bool {
        isFolder(folder, inside: TextMouthPaths.root)
    }

    /// Whether `folder` is `root` or inside it.
    private static func isFolder(_ folder: URL, inside root: URL) -> Bool {
        folder.standardizedFileURL.path == root.standardizedFileURL.path
            || MaintenanceFileAccess.isItem(folder, inside: root)
    }

    /// Whether `outcome` did everything asked: wrote something, and met no
    /// failure, no book in the cloud, and no Cancel. The dialog then closes.
    static func didEverything(_ outcome: BookExportOutcome) -> Bool {
        !outcome.exported.isEmpty && outcome.failures.isEmpty && outcome.booksInCloud.isEmpty && !outcome.wasCancelled
    }

    // MARK: Choosing the Folder

    #if os(macOS)
    /// The settings of the folder chooser of the dialog's Choose Folder…
    /// button: one folder, with a button that makes a new one, starting in
    /// `folder`. Settings only; the panel is built where it is presented.
    static func makeDestinationPanel(startingIn folder: URL) -> FolderPanelSettings {
        FolderPanelSettings(
            canCreateDirectories: true,
            title: BookExportWording.panelTitle,
            message: BookExportWording.panelMessage,
            prompt: BookExportWording.panelPrompt,
            directoryURL: folder
        )
    }

    /// Opens the folder chooser, as a sheet on `window` when there is one,
    /// and makes the folder chosen the destination.
    func chooseDestination(from window: PlatformWindow?) {
        let panel = Self.makeDestinationPanel(startingIn: destination).makePanel()
        let take: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            self?.chooseDestination(folder)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: take)
        } else {
            panel.begin(completionHandler: take)
        }
    }
    #else
    /// The iPhone's sheet opens the system's folder picker itself
    /// (`fileImporter`), which returns the folder to `chooseDestination(_:)`,
    /// so there is no panel to open here and choosing does nothing.
    func chooseDestination(from window: PlatformWindow?) {}
    #endif

    /// Makes `folder` the folder the items go to: the Mac's panel returned
    /// it, or the iPhone's picker, or the kept folder it starts with. The iPhone gives the folder's `name`,
    /// read under its scope.
    func chooseDestination(_ folder: URL, named name: String? = nil) {
        destination = folder
        destinationName = name
        isDestinationChosen = true
    }
}

// MARK: - A Speech Export's Latest Progress

/// The latest progress a speech export has told, kept in a lock: the export
/// tells it on its own threads, the synthesizer's and the encoder's, and the
/// dialog reads it on the main actor.
private final class SpeechProgressRecord: Sendable {
    /// The latest progress, nil before the first.
    private let progress = OSAllocatedUnfairLock<SpeechExportProgress?>(initialState: nil)

    /// The latest progress told, nil before the first.
    var latest: SpeechExportProgress? {
        progress.withLock { $0 }
    }

    /// Keeps `progress` as the latest.
    func keep(_ progress: SpeechExportProgress) {
        self.progress.withLock { $0 = progress }
    }
}
