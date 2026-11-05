import Foundation

// MARK: - The List Table

/// What a Rich Text Format document's `\listtable` and `\listoverridetable`
/// say about the lists its paragraphs belong to (FMT47): whether the items
/// at a level of a list are bullets or numbered.
///
/// A paragraph names its list with `\lsN` (a list override) and its level
/// with `\ilvlN`. The override table maps `\lsN` to a list (`\listidN`), and
/// the list table gives each list's levels, whose `\levelnfcN` is the
/// number format: 23 is a bullet, 255 is no number, and every other value is
/// a number or a letter.
struct RTFListTable {
    /// The most lists, and the most levels of a list, kept.
    private static let most = 10_000

    /// The number formats (`\levelnfc`) of each list's levels, by `\listid`.
    private var levelFormats: [Int: [Int]] = [:]
    /// The list each `\ls` override names, by `\ls`.
    private var overrides: [Int: Int] = [:]

    // MARK: Building

    /// The list being read in the list table, with the levels read so far.
    private var currentList: (id: Int?, formats: [Int])?
    /// The override being read in the override table: its list and its
    /// `\ls`.
    private var currentOverride: (listID: Int?, number: Int?)?

    /// A `\list` group begins.
    mutating func beginList() {
        finishList()
        currentList = (nil, [])
    }

    /// A `\listlevel` group begins in the list being read.
    mutating func beginLevel() {
        guard var list = currentList, list.formats.count < Self.most else { return }
        // 0 (Arabic numbers) until the level's own `\levelnfc` says.
        list.formats.append(0)
        currentList = list
    }

    /// `\levelnfcN` in the level being read.
    mutating func setLevelFormat(_ format: Int) {
        guard var list = currentList, !list.formats.isEmpty else { return }
        list.formats[list.formats.count - 1] = format
        currentList = list
    }

    /// `\listidN`: in a list, its own id; in an override, the list it names.
    mutating func setListID(_ id: Int) {
        if var item = currentOverride {
            item.listID = id
            currentOverride = item
        } else if var list = currentList {
            list.id = id
            currentList = list
        }
    }

    /// A `\listoverride` group begins.
    mutating func beginOverride() {
        finishList()
        finishOverride()
        currentOverride = (nil, nil)
    }

    /// `\lsN` in the override being read.
    mutating func setOverrideNumber(_ number: Int) {
        guard var item = currentOverride else { return }
        item.number = number
        currentOverride = item
    }

    /// Ends the table being read: the last list or override is recorded.
    mutating func finish() {
        finishList()
        finishOverride()
    }

    /// Records the list being read, if it has an id.
    private mutating func finishList() {
        if let list = currentList, let id = list.id, levelFormats.count < Self.most {
            levelFormats[id] = list.formats
        }
        currentList = nil
    }

    /// Records the override being read, if it has an `\ls` and a list.
    private mutating func finishOverride() {
        if let item = currentOverride, let number = item.number, let listID = item.listID,
           overrides.count < Self.most {
            overrides[number] = listID
        }
        currentOverride = nil
    }

    // MARK: Asking

    /// Whether the items at `level` of override `ls` are numbered: true for
    /// every number format but a bullet (23) or none (255); nil when the
    /// table does not know the override or the level, so the caller decides
    /// another way.
    func isNumbered(ls: Int, level: Int) -> Bool? {
        // An `\ls` the override table does not name is tried as a list id.
        let listID = overrides[ls] ?? ls
        guard let formats = levelFormats[listID], level >= 0, level < formats.count else { return nil }
        return formats[level] != 23 && formats[level] != 255
    }
}
