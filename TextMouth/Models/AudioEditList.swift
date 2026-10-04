import Foundation

// MARK: - One Edit As Made

/// One edit as the list recorded it: what it changed, when, and an identity
/// of its own, so a render can tell later whether the list still holds the
/// edits it rendered (`AudioEditList.markRendered(entryIDs:at:)`).
struct AudioEditEntry: Codable, Hashable, Sendable, Identifiable {
    /// The entry's identity, never reused.
    let id: UUID
    /// When the edit was made.
    let madeAt: Date
    /// The change.
    let edit: AudioEdit
}

// MARK: - The Original

/// An audio file of a book as it was imported or recorded, kept in the
/// book's package so that every edit can be undone without loss (FR04): a
/// recording's take (`BookOrigin.originalTakeFileName`), or, for an imported
/// book, a copy of the file taken just before the edits were first rendered
/// into it (`AudioEditPackage.originalFile(forAudioFile:)`). How long it
/// stays is the original policy's decision (`AudioOriginalPolicy`).
struct AudioOriginal: Codable, Hashable, Sendable {
    /// Its path inside the package: "original-take.caf", or
    /// "audioEdits/originals/Interview.m4b".
    var file: String
    /// When the audio was last edited from it: when it was kept, and each
    /// time its edit list changes or is rendered. A deletion after some
    /// days counts from here.
    var lastEditedAt: Date
}

// MARK: - Why Undo Stops

/// Why the list can undo no further, for the editor to say so.
enum AudioEditUndoLimit: Equatable, Sendable {
    /// It can undo: the newest applied edit is not yet part of the audio the
    /// edits start from.
    case canUndo
    /// Nothing has been edited, or every edit is undone.
    case nothingToUndo
    /// The policy deleted the original on the date given, so the edits saved
    /// before then are part of the audio and cannot be undone.
    case originalDeleted(Date)
    /// No original is kept: the policy edits in place, or an original was
    /// deleted before its book had an edit history. The edits saved so far
    /// are part of the audio and cannot be undone.
    case editedInPlace
}

// MARK: - The Edit List

/// The edits made to one audio file of a book, in order, with an undo cursor:
/// the record from which that file's audio is made (FR04).
///
/// The list is the record, and the book's audio is derived from it: the
/// original with every applied edit, rendered (`AudioEditRenderer`). The
/// first `cursor` entries are applied; the rest were undone and can be
/// redone. A new edit after an undo discards the undone tail.
///
/// While the original is kept the edits start from it, so every edit can be
/// undone. Without it they start from the audio as last rendered, which
/// already holds the first `renderedCursor` entries: those stay in the list
/// for reference, but undoing past them is impossible (`canUndo`,
/// `undoLimit`).
struct AudioEditList: Hashable, Sendable {
    /// The audio file the list edits, by its path inside the package:
    /// "Interview.m4a" for a book of one file, "audio/Disc 2/03.mp3" for one
    /// track of a book of several.
    let audioFile: String
    /// The audio as imported or recorded, while it is kept; nil when the
    /// policy deleted it or never kept one.
    private(set) var original: AudioOriginal?
    /// When the policy deleted the original, when it did.
    private(set) var originalDeletedAt: Date?
    /// Every edit, oldest first: the applied ones, then the undone ones.
    private(set) var entries: [AudioEditEntry]
    /// How many of `entries` are applied.
    private(set) var cursor: Int
    /// How many of `entries` the book's audio file holds, as last rendered:
    /// 0 before the first render, when the file is still the original. Nil
    /// when the file holds edits the list no longer has, as after a render,
    /// an undo past it, and a new edit that discarded the undone tail.
    private(set) var renderedCursor: Int?
    /// When the edits were last rendered into the book's audio file; nil
    /// before the first render.
    private(set) var lastRenderedAt: Date?

    /// A list for `audioFile` with no edits yet, whose original, when one is
    /// kept already (a recording's take), is `original`.
    init(audioFile: String, original: AudioOriginal? = nil) {
        self.audioFile = audioFile
        self.original = original
        originalDeletedAt = nil
        entries = []
        cursor = 0
        renderedCursor = 0
        lastRenderedAt = nil
    }

    // MARK: State

    /// How many of `entries` the audio the edits start from already holds:
    /// none while the original is kept; otherwise those the book's audio
    /// holds as last rendered. A list whose file holds edits it no longer has
    /// keeps its original until a render (`canForgetOriginal`), so the
    /// fallback to `cursor`, which allows no undo, only guards a hand edit.
    var baseCursor: Int {
        original != nil ? 0 : (renderedCursor ?? cursor)
    }

    /// The applied edits, oldest first.
    var appliedEntries: ArraySlice<AudioEditEntry> {
        entries[..<cursor]
    }

    /// The applied edits the audio the edits start from does not hold yet:
    /// what a preview or a render applies over it.
    var entriesOverBase: ArraySlice<AudioEditEntry> {
        entries[min(baseCursor, cursor)..<cursor]
    }

    /// Whether an edit can be undone: the newest applied one is not part of
    /// the audio the edits start from.
    var canUndo: Bool {
        cursor > baseCursor
    }

    /// Whether an undone edit can be redone.
    var canRedo: Bool {
        cursor < entries.count
    }

    /// The edit an undo would undo, for the Edit menu's "Undo Cut 2.5
    /// Seconds"; nil when none can be undone.
    var nextUndo: AudioEditEntry? {
        canUndo ? entries[cursor - 1] : nil
    }

    /// The edit a redo would redo; nil when none can be redone.
    var nextRedo: AudioEditEntry? {
        canRedo ? entries[cursor] : nil
    }

    /// Whether the book's audio file holds exactly the applied edits, so
    /// nothing waits to be rendered.
    var isRendered: Bool {
        renderedCursor == cursor
    }

    /// Why undo stops, or `.canUndo` when it doesn't. When edits are applied
    /// but none can be undone, the audio the edits start from already holds
    /// them, which only happens without an original: one the policy deleted,
    /// or none ever kept.
    var undoLimit: AudioEditUndoLimit {
        if canUndo { return .canUndo }
        if cursor == 0 { return .nothingToUndo }
        if let originalDeletedAt { return .originalDeleted(originalDeletedAt) }
        return .editedInPlace
    }

    /// Whether the original may be deleted now without losing anything the
    /// list can still reach: only when the book's audio holds exactly the
    /// applied edits. Then the audio as rendered becomes the start of every
    /// later edit; any other time, an undone edit or one not yet rendered
    /// could only be made again from the original.
    var canForgetOriginal: Bool {
        original != nil && isRendered
    }

    /// Every take the edits that can still be applied use: those from the
    /// audio the edits start from onward, applied or undone. A take used only
    /// by edits the base audio already holds is no longer needed.
    var takesInUse: Set<String> {
        Set(entries[min(baseCursor, entries.count)...].compactMap { $0.edit.take?.file })
    }

    // MARK: Changes

    /// Records `edit`, made at `date`, as the newest applied edit, after
    /// discarding any undone edits, and returns its entry. The original, when
    /// kept, counts as edited at `date`.
    @discardableResult
    mutating func record(_ edit: AudioEdit, id: UUID = UUID(), at date: Date) -> AudioEditEntry {
        // Discarding an undone edit the book's audio holds leaves that audio
        // holding edits the list no longer has.
        if let rendered = renderedCursor, rendered > cursor {
            renderedCursor = nil
        }
        entries.removeSubrange(cursor...)
        let entry = AudioEditEntry(id: id, madeAt: date, edit: edit)
        entries.append(entry)
        cursor += 1
        noteEdited(at: date)
        return entry
    }

    /// Undoes the newest applied edit, at `date`, and returns it; nil, with
    /// nothing changed, when none can be undone (`canUndo`).
    @discardableResult
    mutating func undo(at date: Date) -> AudioEditEntry? {
        guard canUndo else { return nil }
        cursor -= 1
        noteEdited(at: date)
        return entries[cursor]
    }

    /// Redoes the oldest undone edit, at `date`, and returns it; nil, with
    /// nothing changed, when none was undone.
    @discardableResult
    mutating func redo(at date: Date) -> AudioEditEntry? {
        guard canRedo else { return nil }
        cursor += 1
        noteEdited(at: date)
        return entries[cursor - 1]
    }

    /// Records that the book's audio file was rendered, at `date`, from the
    /// edits `entryIDs` names: the identities of the applied entries, oldest
    /// first, when the render began. The list may have changed while it ran.
    /// When it still begins with exactly those entries, the file holds them
    /// and the result is true; otherwise the file holds edits the list no
    /// longer has, and the result is false.
    @discardableResult
    mutating func markRendered(entryIDs: [UUID], at date: Date) -> Bool {
        lastRenderedAt = date
        noteEdited(at: date)
        guard entryIDs.count <= entries.count,
              zip(entries, entryIDs).allSatisfy({ $0.id == $1 }) else {
            renderedCursor = nil
            return false
        }
        renderedCursor = entryIDs.count
        return true
    }

    /// Keeps `original` as the audio the edits start from: a copy of the
    /// book's file taken just before the edits are first rendered into it.
    mutating func keepOriginal(_ original: AudioOriginal) {
        self.original = original
        originalDeletedAt = nil
    }

    /// Forgets the original, which the policy deleted at `date`: from now on
    /// the edits start from the book's audio as last rendered. Only allowed
    /// when `canForgetOriginal`; otherwise nothing changes and the result is
    /// false.
    @discardableResult
    mutating func forgetOriginal(at date: Date) -> Bool {
        guard canForgetOriginal else { return false }
        original = nil
        originalDeletedAt = date
        return true
    }

    /// Counts the original, when one is kept, as edited at `date`: the
    /// policy's days count from the last change.
    private mutating func noteEdited(at date: Date) {
        original?.lastEditedAt = date
    }
}

// MARK: - edits.json

/// A list is written with its file, its original, its entries, and its
/// cursors. Reading one checks that the cursors lie within the entries: a
/// list that fails is damaged, never repaired, since a wrong cursor would
/// apply edits the user undid.
extension AudioEditList: Codable {
    private enum CodingKeys: String, CodingKey {
        case audioFile, original, originalDeletedAt, entries, cursor, renderedCursor, lastRenderedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        audioFile = try container.decode(String.self, forKey: .audioFile)
        original = try container.decodeIfPresent(AudioOriginal.self, forKey: .original)
        originalDeletedAt = try container.decodeIfPresent(Date.self, forKey: .originalDeletedAt)
        entries = try container.decode([AudioEditEntry].self, forKey: .entries)
        cursor = try container.decode(Int.self, forKey: .cursor)
        renderedCursor = try container.decodeIfPresent(Int.self, forKey: .renderedCursor)
        lastRenderedAt = try container.decodeIfPresent(Date.self, forKey: .lastRenderedAt)
        guard (0...entries.count).contains(cursor) else {
            throw DecodingError.dataCorruptedError(
                forKey: .cursor,
                in: container,
                debugDescription: "cursor \(cursor) is outside 0 to \(entries.count)"
            )
        }
        if let renderedCursor, !(0...entries.count).contains(renderedCursor) {
            throw DecodingError.dataCorruptedError(
                forKey: .renderedCursor,
                in: container,
                debugDescription: "renderedCursor \(renderedCursor) is outside 0 to \(entries.count)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(audioFile, forKey: .audioFile)
        try container.encodeIfPresent(original, forKey: .original)
        try container.encodeIfPresent(originalDeletedAt, forKey: .originalDeletedAt)
        try container.encode(entries, forKey: .entries)
        try container.encode(cursor, forKey: .cursor)
        try container.encodeIfPresent(renderedCursor, forKey: .renderedCursor)
        try container.encodeIfPresent(lastRenderedAt, forKey: .lastRenderedAt)
    }
}

// MARK: - A Book's Edit History

/// Everything a book's package records about edits to its audio (FR04): one
/// edit list for each audio file edited, and the book's own original policy.
/// The package keeps it as edits.json in its audioEdits folder
/// (`AudioEditHistoryStore`).
struct AudioEditHistory: Codable, Equatable, Sendable {
    /// The layout of edits.json this version of TextMouth writes and reads.
    /// A history of another layout, as a later TextMouth on another Mac
    /// sharing the library could write, is left as it is and not read.
    static let currentVersion = 1

    /// The layout this history is written in (`currentVersion`).
    private(set) var version: Int
    /// This book's own original policy, which wins over the global setting
    /// for every original the book keeps; nil follows the global setting.
    var policyOverride: AudioOriginalPolicy?
    /// One list for each audio file edited, in the order they were first
    /// edited.
    private(set) var files: [AudioEditList]

    /// A history holding `files`, under the book's own `policyOverride`.
    init(policyOverride: AudioOriginalPolicy? = nil, files: [AudioEditList] = []) {
        version = Self.currentVersion
        self.policyOverride = policyOverride
        self.files = files
    }

    /// The list of `audioFile`, or nil when it was never edited.
    func list(for audioFile: String) -> AudioEditList? {
        files.first { $0.audioFile == audioFile }
    }

    /// The list of `audioFile`, or a new one with no edits when it was never
    /// edited.
    func listOrNew(for audioFile: String) -> AudioEditList {
        list(for: audioFile) ?? AudioEditList(audioFile: audioFile)
    }

    /// Puts `list` in place of the list of the same file, or adds it.
    mutating func setList(_ list: AudioEditList) {
        if let index = files.firstIndex(where: { $0.audioFile == list.audioFile }) {
            files[index] = list
        } else {
            files.append(list)
        }
    }

    /// The policy this book's originals are kept under: its own, or else
    /// `global`.
    func effectivePolicy(global: AudioOriginalPolicy) -> AudioOriginalPolicy {
        policyOverride ?? global
    }

    /// Every take any list can still use (`AudioEditList.takesInUse`).
    var takesInUse: Set<String> {
        files.reduce(into: Set<String>()) { $0.formUnion($1.takesInUse) }
    }
}
