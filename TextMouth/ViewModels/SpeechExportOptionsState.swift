import Combine
import Foundation

/// The spoken audio options of the Export dialog for one text book (FMT43):
/// the format of the one audio file the export makes, the part of the book
/// it speaks (from the beginning or a heading, to a heading or the end), and
/// the speed and pitch it speaks at, which start at the book's own. It holds
/// the book's headings as the From and To pop-ups list them, and the voice
/// that speaks. `SpeechExportOptionsView` shows and sets the options; an
/// export takes them as `choices`, and names its file with
/// `fileTitle(bookTitle:)`.
///
/// The range is always in reading order: choosing a From past the To, or a
/// To before the From, moves the other end to the heading chosen, so the
/// range becomes that one heading, never one that ends before it begins.
@MainActor
final class SpeechExportOptionsState: ObservableObject {
    // MARK: Types

    /// Everything the options say an export speaks, as one value the export
    /// takes when it begins.
    struct Choices: Equatable, Sendable {
        /// The format of the audio file.
        var format: SpeechExportFormat
        /// The part of the book spoken.
        var range: SpeechExportRange
        /// The speed, in words per minute.
        var wordsPerMinute: Double
        /// The pitch multiplier; 1 is the voice's own pitch.
        var pitch: Double
    }

    /// One item of the From or To pop-up: a heading, or the book's beginning
    /// (in From) or end (in To).
    struct Item: Identifiable, Equatable {
        /// What the pop-up's selection holds while the item is chosen: the
        /// heading's `Heading.id`, or "" for the beginning in From and the
        /// end in To. No heading's ID is empty, as it holds the heading's
        /// place and level.
        let tag: String
        /// The item's words, which the pop-up shows and VoiceOver speaks.
        let title: String
        /// The item's identity in the pop-up's list: its tag.
        var id: String { tag }
    }

    // MARK: The Book

    /// The book's headings, in reading order (`DocumentContent.allHeadings`).
    let headings: [Heading]
    /// The IDs of the headings the listener skips, which the pop-ups name as
    /// skipped.
    let skippedHeadingIDs: Set<String>
    /// The voice that speaks the book, or nil when no voice is installed.
    let voice: SpeechExportVoiceInfo?
    /// The formats the Format pop-up offers, in order.
    let formats: [SpeechExportFormat]
    /// The From pop-up's items: the book's beginning, then each heading.
    let fromItems: [Item]
    /// The To pop-up's items: each heading, then the book's end.
    let throughItems: [Item]

    /// Where each heading stands in `headings`, by its ID; should two
    /// headings share an ID (the same text and level at the same place),
    /// where the first stands.
    private let places: [String: Int]

    // MARK: The Choices

    /// The format of the audio file: at first the first offered, M4B.
    @Published var format: SpeechExportFormat
    /// The ID of the heading the spoken audio begins at, or nil for the
    /// book's beginning. Set with `setFrom(_:)`, which keeps the range in
    /// reading order.
    @Published private(set) var fromHeadingID: String?
    /// The ID of the heading whose section, with any headings under it, ends
    /// the spoken audio, or nil for the book's end. Set with
    /// `setThrough(_:)`.
    @Published private(set) var throughHeadingID: String?
    /// The speed, in words per minute: at first the book's own, and always
    /// held to the speeds Settings offers, as Settings holds its own
    /// (`NumericSettingRule.validated(_:)`): a speed outside them becomes
    /// the nearer end, and one that is no number the default speed.
    @Published var wordsPerMinute: Double {
        didSet {
            // A held speed is in range, so assigning it here ends there; a
            // speed already in range is left alone, and published once.
            let held = SettingsPolicy.wordsPerMinute.validated(wordsPerMinute)
            if held != wordsPerMinute { wordsPerMinute = held }
        }
    }
    /// The pitch multiplier: at first the book's own, and always held to
    /// the pitches Settings offers, as the speed is held to its speeds.
    @Published var pitch: Double {
        didSet {
            // As for the speed.
            let held = SettingsPolicy.pitchMultiplier.validated(pitch)
            if held != pitch { pitch = held }
        }
    }

    // MARK: Making the Options

    /// The options for a book with `headings` (`DocumentContent.allHeadings`),
    /// of which those in `skippedHeadingIDs` are skipped, spoken by `voice`
    /// (nil when no voice is installed), starting at the speed and pitch of
    /// `settings`, and offering `formats`: the whole book, in the first
    /// format.
    init(
        headings: [Heading],
        skippedHeadingIDs: Set<String>,
        voice: SpeechExportVoiceInfo?,
        settings: SpeechExportVoiceSettings,
        formats: [SpeechExportFormat] = SpeechExportFormat.available
    ) {
        self.headings = headings
        self.skippedHeadingIDs = skippedHeadingIDs
        self.voice = voice
        self.formats = formats
        // M4B, the audiobook, comes first; should a caller offer no formats,
        // it is still the format chosen.
        format = formats.first ?? .m4b
        // An initializer runs no observer, so the speed and pitch are held
        // here as their observers hold them.
        wordsPerMinute = SettingsPolicy.wordsPerMinute.validated(settings.wordsPerMinute)
        pitch = SettingsPolicy.pitchMultiplier.validated(settings.pitch)

        // Each heading is listed once, at its first place: a pop-up's items
        // need tags of their own, and two headings that share an ID are the
        // same text and level at the same place.
        var places: [String: Int] = [:]
        var headingItems: [Item] = []
        for (place, heading) in headings.enumerated() where places[heading.id] == nil {
            places[heading.id] = place
            headingItems.append(Item(
                tag: heading.id,
                title: SpeechExportWording.headingItem(heading, isSkipped: skippedHeadingIDs.contains(heading.id))
            ))
        }
        self.places = places
        fromItems = [Item(tag: "", title: SpeechExportWording.beginningOfBook)] + headingItems
        throughItems = headingItems + [Item(tag: "", title: SpeechExportWording.endOfBook)]
    }

    // MARK: Reading the Options

    /// Whether the book has headings to choose a range from. Without them
    /// the whole book is exported, and the From and To pop-ups give way to a
    /// line saying so.
    var hasHeadings: Bool {
        !headings.isEmpty
    }

    /// The From pop-up's selection: the From heading's ID, or "" for the
    /// book's beginning.
    var fromTag: String {
        fromHeadingID ?? ""
    }

    /// The To pop-up's selection: the To heading's ID, or "" for the book's
    /// end.
    var throughTag: String {
        throughHeadingID ?? ""
    }

    /// Everything the options say an export speaks.
    var choices: Choices {
        Choices(
            format: format,
            range: SpeechExportRange(fromHeadingID: fromHeadingID, throughHeadingID: throughHeadingID),
            wordsPerMinute: wordsPerMinute,
            pitch: pitch
        )
    }

    /// How many headings the chosen range reads, its skipped ones left out:
    /// the chapters it makes, besides any text before the first heading.
    /// The text's own count of what a range reads
    /// (`SpeechExportText.headingPlaces(of:in:)`); 0 for a range that holds
    /// nothing.
    var headingCount: Int {
        guard let places = try? SpeechExportText.headingPlaces(of: choices.range, in: headings) else { return 0 }
        return headings[places].filter { !skippedHeadingIDs.contains($0.id) }.count
    }

    /// The line the options show under the Format pop-up while MP3 is
    /// chosen for a range of more headings than an MP3 has chapters for;
    /// nil otherwise.
    var mp3ChapterNote: String? {
        guard format == .mp3, headingCount > MP3Tag.maximumChapters else { return nil }
        return SpeechExportWording.mp3ChapterLimit(headings: headingCount)
    }

    // MARK: Choosing the Range

    /// Chooses where the spoken audio begins, by a From item's tag: "" for
    /// the book's beginning, or a heading's ID. A tag naming none of the
    /// book's headings changes nothing. A heading past the To moves the To
    /// to it as well, so the range is that one heading.
    func setFrom(_ tag: String) {
        guard isChoice(tag) else { return }
        fromHeadingID = Self.headingID(forTag: tag)
        if fromPlace > throughPlace {
            throughHeadingID = fromHeadingID
        }
    }

    /// Chooses where the spoken audio ends, by a To item's tag: "" for the
    /// book's end, or a heading's ID. A tag naming none of the book's
    /// headings changes nothing. A heading before the From moves the From to
    /// it as well, so the range is that one heading.
    func setThrough(_ tag: String) {
        guard isChoice(tag) else { return }
        throughHeadingID = Self.headingID(forTag: tag)
        if fromPlace > throughPlace {
            fromHeadingID = throughHeadingID
        }
    }

    /// Whether a pop-up's `tag` can be chosen: "" (the book's beginning or
    /// end) or the ID of one of the book's headings.
    private func isChoice(_ tag: String) -> Bool {
        tag.isEmpty || places[tag] != nil
    }

    /// The heading ID a pop-up's `tag` stands for: nil for "", the book's
    /// beginning or end, else the tag itself.
    private static func headingID(forTag tag: String) -> String? {
        tag.isEmpty ? nil : tag
    }

    /// Where the From stands in reading order: its heading's place in
    /// `headings`, or -1, before every heading, for the book's beginning.
    private var fromPlace: Int {
        fromHeadingID.flatMap { places[$0] } ?? -1
    }

    /// Where the To stands in reading order: its heading's place in
    /// `headings`, or `headings.count`, past every heading, for the book's
    /// end.
    private var throughPlace: Int {
        throughHeadingID.flatMap { places[$0] } ?? headings.count
    }

    // MARK: Naming the File

    /// The exported file's name, without its extension, for the book titled
    /// `bookTitle`, whose part of the name, the stem, is the book's title as
    /// every export names a book (`BookExportService.fileNameStem(for:)`):
    /// - the whole book: "<stem> - Audio";
    /// - one heading, the From and the To being the same: "<stem> - <heading>";
    /// - any other range: "<stem> - <From heading, or Beginning> to <To
    ///   heading, or End>".
    ///
    /// A heading is named by its text on one line. The whole name is made
    /// safe as a file's name, and cut to its longest, by
    /// `BookExportService.safeFileName(_:fallback:)`, the stem standing in
    /// should nothing be left.
    func fileTitle(bookTitle: String) -> String {
        let stem = BookExportService.fileNameStem(for: bookTitle)
        let part: String
        switch (fromHeadingID, throughHeadingID) {
        case (nil, nil):
            part = SpeechExportWording.wholeBookName
        case let (from?, through?) where from == through:
            part = nameWords(ofHeading: from, stem: stem)
        case let (from, through):
            part = SpeechExportWording.rangeName(
                from: from.map { nameWords(ofHeading: $0, stem: stem) } ?? SpeechExportWording.beginningName,
                through: through.map { nameWords(ofHeading: $0, stem: stem) } ?? SpeechExportWording.endName
            )
        }
        return BookExportService.safeFileName(SpeechExportWording.fileName(stem: stem, part: part), fallback: stem)
    }

    /// The words of the heading with ID `id` in a file's name: its text on
    /// one line; or, for a heading whose text is blank, `stem`, the book's
    /// title, which the export titles that heading's chapter with too
    /// (`SpeechExportSection.title`).
    private func nameWords(ofHeading id: String, stem: String) -> String {
        let words = places[id].map { SpeechExportWording.oneLine(headings[$0].text) } ?? ""
        return words.isEmpty ? stem : words
    }
}
