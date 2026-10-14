import Foundation

/// How an audiobook of tracks' saved places follow their tracks when an
/// edited manifest rearranges the book (FR17, item 5).
///
/// A manifest adds no track and removes none (a track it leaves out is
/// still a heading), so an edit only renumbers the book's chapters, one per
/// track. Every place saved by chapter and offset (the reading position,
/// each bookmark, and each skipped heading) moves to the chapter that plays
/// its track now, at the same time into it: each old chapter is mapped to
/// its file, and the file to its new chapter. A group heading or a title
/// changed moves no place; only the headings change.
enum TrackPlaces {
    /// The chapter of `new` that plays the track each chapter of `old`
    /// played, by chapter of `old`: each chapter's file, as the indexes
    /// record it relative to the book's folder. A chapter whose file `new`
    /// does not play, or that names none, has no entry.
    static func chapterMap(from old: BookContentIndex, to new: BookContentIndex) -> [Int: Int] {
        var chapterOfFile: [String: Int] = [:]
        for (chapter, entry) in new.chapters.enumerated() {
            if let file = entry.audioFilePath, chapterOfFile[file] == nil {
                chapterOfFile[file] = chapter
            }
        }
        var map: [Int: Int] = [:]
        for (chapter, entry) in old.chapters.enumerated() {
            if let file = entry.audioFilePath, let moved = chapterOfFile[file] {
                map[chapter] = moved
            }
        }
        return map
    }

    /// `places`, saved by chapter and offset in `old`, the book as it was
    /// arranged, moved to `new`, the book as the edited manifest arranges
    /// it: each to the chapter playing its track now, at the same offset
    /// (the same time) into it. A place whose chapter cannot be mapped
    /// stays where it is.
    ///
    /// - The reading position takes its new chapter and its offset across
    ///   the whole book anew, when it kept one, and is dated `date` when its
    ///   chapter changed, so it wins over an older copy elsewhere, as a
    ///   place a rebuild of a text moves is (T06). Its heading index, a
    ///   bookmark's identity, number, label, and date, and every anchor
    ///   stay as they were: a move is not a read.
    /// - A skipped heading that is its track's own heading follows the
    ///   track, taking the level and label that heading has now, so a
    ///   retitled or regrouped track stays skipped. A skipped group heading
    ///   follows its words: it names the first group heading of the same
    ///   label `new` has, and waits, naming no heading, when `new` has
    ///   none (`PlaceRelocator.Places.waitingSkippedHeadings`).
    static func moved(_ places: PlaceRelocator.Places, from old: BookContentIndex, to new: BookContentIndex, at date: Date) -> PlaceRelocator.Places {
        let map = chapterMap(from: old, to: new)
        var moved = places

        if var position = places.position, let chapter = map[position.chapterIndex] {
            if chapter != position.chapterIndex {
                position.chapterIndex = chapter
                position.lastUpdated = date
            }
            if position.globalCharacterOffset != nil {
                position.globalCharacterOffset = new.chapterStartOffset(chapter) + position.characterOffset
            }
            moved.position = position
        }

        moved.bookmarks = places.bookmarks.map { bookmark in
            guard let chapter = map[bookmark.chapterIndex] else { return bookmark }
            var copy = bookmark
            copy.chapterIndex = chapter
            return copy
        }

        var skipped: [SkippedHeading] = []
        var waiting = places.waitingSkippedHeadings
        for skip in places.skippedHeadings {
            switch movedSkip(skip, from: old, to: new, map: map) {
            case .named(let heading):
                if !skipped.contains(heading) {
                    skipped.append(heading)
                }
            case .waiting:
                waiting.append(skip)
            }
        }
        moved.skippedHeadings = skipped
        moved.waitingSkippedHeadings = waiting
        return moved
    }

    /// Where a skipped heading goes.
    private enum MovedSkip {
        /// It names this heading of the new arrangement.
        case named(SkippedHeading)
        /// It names no heading of the new arrangement, and waits.
        case waiting
    }

    /// Where `skip`, a heading skipped in `old`, goes in `new`, as
    /// `moved(_:from:to:at:)` describes: a track's own heading, the last at
    /// its chapter's start, follows the track; a group heading follows its
    /// label. A skip `old` does not hold, as one saved against an older
    /// arrangement, stays as it was when its chapter cannot be mapped.
    private static func movedSkip(_ skip: SkippedHeading, from old: BookContentIndex, to new: BookContentIndex, map: [Int: Int]) -> MovedSkip {
        guard old.chapters.indices.contains(skip.chapterIndex) else { return .named(skip) }
        let headings = old.chapters[skip.chapterIndex].headings.filter { $0.characterOffset == skip.characterOffset }
        let isTrackHeading = headings.last.map { $0.level == skip.level && $0.text == skip.label } ?? false
        if isTrackHeading {
            guard let chapter = map[skip.chapterIndex], let heading = new.chapters[chapter].headings.last else {
                return .named(skip)
            }
            var moved = skip
            moved.chapterIndex = chapter
            moved.characterOffset = heading.characterOffset
            moved.level = heading.level
            moved.label = heading.text
            return .named(moved)
        }
        // A group heading: the first of its label in the new arrangement,
        // a heading before its chapter's track heading.
        for (chapter, entry) in new.chapters.enumerated() {
            guard let group = entry.headings.dropLast().first(where: { $0.text == skip.label }) else { continue }
            var moved = skip
            moved.chapterIndex = chapter
            moved.characterOffset = group.characterOffset
            moved.level = group.level
            return .named(moved)
        }
        return .waiting
    }
}
