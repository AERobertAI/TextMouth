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
    /// `conversionName` (nil: as it is), as in "Text as HTML, about 12 KB".
    func label(convertedTo conversionName: String?) -> String {
        let available = availableItems
        return BookExportWording.choiceLabel(
            kind: kind,
            bookCount: bookCount,
            availableItemCount: available.count,
            fileCount: available.reduce(0) { $0 + $1.files.count },
            byteCount: available.reduce(0) { $0 + $1.byteCount },
            inCloudCount: inCloudCount,
            convertedTo: conversionName
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
/// a conversion, or a text writer.
struct BookExportConversionChoice: Identifiable, Equatable {
    /// The writer's `id`, or `TextExportWriters.markdownID` for Markdown.
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
/// For one text book the dialog also offers its text as spoken audio (FMT43):
/// the options are made as the book is listed (`speechOptions`), and an export
/// that takes the kind runs `SpeechExportJob` with them, showing which chapter
/// is being spoken, and saying at its end what it kept for the next export.
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
    /// What the last export said, kept in the dialog when it did not do
    /// everything asked.
    @Published private(set) var summary: String?
    /// The Convert to picker's choice for each kind that has one: a writer's
    /// `id`. A kind not here is on Markdown, so a dialog nobody touched
    /// exports as it always has.
    @Published private(set) var conversionIDs: [BookExportKind: String] = [:]
    /// The spoken audio options, once the books have been listed: nil unless
    /// the dialog exports one text book whose text can be read here.
    @Published private(set) var speechOptions: SpeechExportOptionsState?
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
    /// The export under way's Cancel.
    private var cancellation: BookExportCancellation?
    /// The options of each writer chosen so far, by writer `id`, kept for the
    /// dialog's life so that choosing another writer and coming back finds
    /// them as they were.
    private var optionsStates: [String: any TextExportOptionsEditing] = [:]
    /// What a speech export reaches: the synthesizer, the voices, the power
    /// assertion, the disks, and the folder its chapters are kept in.
    private let speechEnvironment: SpeechExportEnvironment
    /// The preferences holding the global voice, speed, pitch, and pause
    /// level, which a book without its own speaks with.
    private let speechDefaults: UserDefaults
    /// The substitution rules and repeated-symbol settings speech is prepared
    /// with.
    private let substitutionService: TextSubstitutionService

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
    init(
        books: [Book],
        library: LibraryViewModel? = nil,
        destination: URL? = nil,
        access: MaintenanceFileAccess = .live,
        writers: [any TextExportWriter] = TextExportWriters.all,
        speechEnvironment: SpeechExportEnvironment = .live,
        speechDefaults: UserDefaults = TextMouthRuntime.current.preferences,
        substitutionService: TextSubstitutionService = .shared
    ) {
        self.books = books
        self.destination = destination ?? Self.defaultDestination
        self.access = access
        self.writers = writers
        self.speechEnvironment = speechEnvironment
        self.speechDefaults = speechDefaults
        self.substitutionService = substitutionService
        currentBooks = { [weak library] chosen in
            chosen.map { library?.bookByID($0.id) ?? $0 }
        }
    }

    // MARK: Listing

    /// Lists what the books hold, off the main thread, and shows the
    /// checkboxes, the first kind that can be exported checked. Spoken audio
    /// that can be exported gets its options first; a book whose text cannot
    /// be read has none, and is not offered the kind.
    func load() async {
        phase = .listing
        let listed = await Self.offers(for: books, access: access)
        offers = listed
        var listedChoices = BookExportChoice.choices(for: listed)
        if listedChoices.contains(where: { $0.kind == .spokenAudio && $0.isAvailable }) {
            speechOptions = await makeSpeechOptions(from: listed)
            if speechOptions == nil {
                listedChoices.removeAll { $0.kind == .spokenAudio }
            }
        }
        choices = listedChoices
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

    /// Checks or unchecks the checkbox of `kind`.
    func setChecked(_ isChecked: Bool, for kind: BookExportKind) {
        if isChecked {
            checked.insert(kind)
        } else {
            checked.remove(kind)
        }
    }

    /// Whether an export is under way.
    var isExporting: Bool {
        if case .exporting = phase { return true }
        return false
    }

    /// Whether Export can be pressed: the books are listed, nothing is
    /// being exported, and a checked kind has something on this Mac.
    var canExport: Bool {
        switch phase {
        case .listing, .exporting:
            return false
        case .ready, .finished:
            return choices.contains { checked.contains($0.kind) && $0.isAvailable }
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

    // MARK: Converting

    /// The choices of the Convert to picker beside the checkbox of `kind`:
    /// Markdown, then each text writer in order, for a kind whose text a
    /// writer can convert; none for any other kind.
    func conversionChoices(for kind: BookExportKind) -> [BookExportConversionChoice] {
        guard kind.convertsText else { return [] }
        let markdown = BookExportConversionChoice(
            id: TextExportWriters.markdownID,
            name: BookExportWording.markdownChoiceName,
            hint: BookExportWording.markdownChoiceHint
        )
        return [markdown] + writers.map {
            BookExportConversionChoice(id: $0.id, name: $0.name, hint: $0.hint)
        }
    }

    /// The writer whose `id` is `id` among the picker's writers; nil for
    /// Markdown and for an unknown `id`.
    private func writer(id: String) -> (any TextExportWriter)? {
        writers.first { $0.id == id }
    }

    /// The `id` of the picker's choice for `kind`: Markdown until another is
    /// chosen.
    func conversionID(for kind: BookExportKind) -> String {
        conversionIDs[kind] ?? TextExportWriters.markdownID
    }

    /// Chooses `id` in the picker beside the checkbox of `kind`. A kind with
    /// no picker, and an `id` the picker does not list, change nothing. The
    /// first time a writer is chosen, its options are made as each dialog
    /// starts them.
    func setConversionID(_ id: String, for kind: BookExportKind) {
        guard conversionChoices(for: kind).contains(where: { $0.id == id }) else { return }
        conversionIDs[kind] = id
        if let writer = writer(id: id), optionsStates[id] == nil {
            optionsStates[id] = TextExportWriters.optionsState(for: writer)
        }
    }

    /// The choice the picker beside the checkbox of `kind` shows; nil for a
    /// kind with no picker.
    func conversionChoice(for kind: BookExportKind) -> BookExportConversionChoice? {
        let id = conversionID(for: kind)
        return conversionChoices(for: kind).first { $0.id == id }
    }

    /// The name of the writer `kind`'s text is converted to; nil on Markdown
    /// and for a kind with no picker, which the checkbox says as it is.
    private func conversionName(for kind: BookExportKind) -> String? {
        guard kind.convertsText else { return nil }
        return writer(id: conversionID(for: kind))?.name
    }

    /// The label of `choice`'s checkbox, saying the conversion chosen.
    func label(for choice: BookExportChoice) -> String {
        choice.label(convertedTo: conversionName(for: choice.kind))
    }

    /// The hint of the checkbox of `kind`, saying the conversion chosen.
    func hint(for kind: BookExportKind) -> String {
        BookExportWording.hint(for: kind, convertedTo: conversionName(for: kind))
    }

    /// The options view to show under the checkbox of `kind`: spoken audio's
    /// own, or the one of the writer chosen in the kind's picker; nil while
    /// the kind is unchecked, on Markdown, or when the writer takes no
    /// options.
    func optionsView(for kind: BookExportKind) -> AnyView? {
        if kind == .spokenAudio {
            guard isChecked(kind), let speechOptions else { return nil }
            return AnyView(SpeechExportOptionsView(state: speechOptions))
        }
        guard isChecked(kind), let state = optionsStates[conversionID(for: kind)], state.hasOptions else {
            return nil
        }
        return state.makeView()
    }

    /// The conversions an export makes now: for each checked kind on a
    /// writer, that writer with its options as they are. Markdown has no
    /// options state, so a kind on Markdown has no conversion here: its
    /// files stay as the offer lists them, the Markdown the offer writes.
    /// Spoken audio, while checked, is the speech its options ask for.
    var conversions: [BookExportKind: BookExportConversion] {
        var made: [BookExportKind: BookExportConversion] = [:]
        for kind in checked {
            if let state = optionsStates[conversionID(for: kind)] {
                made[kind] = .text(state.conversion())
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
    /// - Returns: What the export did; nil when it could not start.
    @discardableResult
    func export(announcingFrom window: PlatformWindow? = nil) async -> BookExportOutcome? {
        guard canExport else { return nil }
        let earlier = (phase: phase, summary: summary)
        let cancellation = BookExportCancellation()
        self.cancellation = cancellation
        summary = nil
        phase = .exporting(done: 0, total: 0)
        // A braille table just chosen in the options may still be checked.
        // Waiting for it is part of exporting (review R5, F3): Stop is offered
        // meanwhile, and Stop, or the dialog closing, ends the export before
        // it reads its options or writes anything. It then writes with the
        // table the pop-ups show once the check has passed, or the one they
        // returned to.
        await BrailleTableChoiceChecks.shared.finished(unless: cancellation)
        guard !cancellation.isCancelled else {
            self.cancellation = nil
            (phase, summary) = earlier
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
        guard !Self.isInsideDataDirectory(folder) else {
            self.cancellation = nil
            phase = earlier.phase
            summary = BookExportWording.destinationInLibrary
            VoiceOverAnnouncer.announce(BookExportWording.destinationInLibrary, from: window)
            return nil
        }
        let access = self.access
        Self.lastDestination = folder

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
        let outcome = await OffMainWork.run {
            let offers = books.map { BookExportService.offer(for: $0, access: access) }
            return BookExportService.export(
                offers,
                kinds: kinds,
                conversions: conversions,
                to: folder,
                access: access,
                cancellation: cancellation,
                progress: report,
                speech: speech
            )
        }
        self.cancellation = nil
        speechProgress = nil
        phase = .finished(outcome)
        var words = BookExportWording.finished(outcome, folderName: BookExportWording.folderName(of: folder))
        if case .ended(let kept, let total)? = speechRecord.latest,
           let keptWords = SpeechExportWording.kept(done: kept, total: total) {
            words += " " + keptWords
        }
        // An MP3 made of more chapters than it has chapters for says so.
        if speechFormat == .mp3, case .ended(_, let chapters)? = speechRecord.latest, chapters > MP3Tag.maximumChapters,
           outcome.exported.contains(where: { $0.pathExtension == SpeechExportFormat.mp3.fileExtension }) {
            words += " " + SpeechExportWording.mp3ChaptersKept(of: chapters)
        }
        summary = Self.didEverything(outcome) ? nil : words
        VoiceOverAnnouncer.announce(words, from: window)
        return outcome
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

    /// Stops the export under way before its next file, or within a moment
    /// while a chapter is spoken or the audio file encoded.
    func stop() {
        cancellation?.cancel()
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
        let root = TextMouthPaths.root
        return folder.standardizedFileURL.path == root.standardizedFileURL.path
            || MaintenanceFileAccess.isItem(folder, inside: root)
    }

    /// Whether `outcome` did everything asked: wrote something, and met no
    /// failure, no book in the cloud, and no Cancel. The dialog then closes.
    static func didEverything(_ outcome: BookExportOutcome) -> Bool {
        !outcome.exported.isEmpty && outcome.failures.isEmpty && outcome.booksInCloud.isEmpty && !outcome.wasCancelled
    }

    // MARK: Choosing the Folder

    #if os(macOS)
    /// The folder chooser of the dialog's Choose Folder… button: one folder,
    /// with a button that makes a new one, starting in `folder`.
    static func makeDestinationPanel(startingIn folder: URL) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.title = BookExportWording.panelTitle
        panel.message = BookExportWording.panelMessage
        panel.prompt = BookExportWording.panelPrompt
        panel.directoryURL = folder
        return panel
    }

    /// Opens the folder chooser, as a sheet on `window` when there is one,
    /// and makes the folder chosen the destination.
    func chooseDestination(from window: PlatformWindow?) {
        let panel = Self.makeDestinationPanel(startingIn: destination)
        let take: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            self?.destination = folder
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: take)
        } else {
            panel.begin(completionHandler: take)
        }
    }
    #else
    /// Phase 0 stand-in: the Mac opens a folder chooser here; iOS has no
    /// folder panel yet (phase 1 brings the document picker), so choosing
    /// does nothing and the destination stays as it was.
    func chooseDestination(from window: PlatformWindow?) {}
    #endif
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
