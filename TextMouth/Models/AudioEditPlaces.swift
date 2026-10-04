import Foundation

/// A book's places in its audio, its bookmarks and its saved reading
/// position, moved with the sound when a save of edited audio changes the
/// file they point into (FR04).
///
/// A place is a chapter and a character offset in it, at ten characters a
/// second of audio (`ReaderViewModel.audioCharsPerSecond`), over the
/// chapters the book's content index lays out (`BookContentIndex`). In a
/// book of one file, the chapters follow one another through the file, so
/// a place is a time on the whole file; in a book of several tracks, each
/// track is a chapter of its own, so a place is a time on its track.
///
/// A save moves each place in the file it changed through the layout as it
/// was before the save to the time it names, along the route the edits take
/// (`AudioEditorTimeMap.Route`), and back through the layout after the save:
/// a place before every edit stays, one after an edit moves with the sound,
/// and one inside a stretch cut or trimmed away goes to where that stretch
/// was. A place in another track keeps its time, in its track's chapter
/// should the save have renamed a track. A place the layouts can't place,
/// as in a book whose manifest plays sections, stays where it is.
enum AudioEditPlaces {
    /// The track a save changed in a book of several tracks, by its path
    /// inside the book's folder of tracks before the save and after it,
    /// which differ when the save wrote a format of another extension.
    struct Track: Equatable, Sendable {
        /// Its path before the save: "Disc 2/03.mp3".
        let before: String
        /// Its path after it: "Disc 2/03.m4a".
        let after: String
    }

    /// A place: a chapter, and a character offset in it.
    struct Place: Equatable, Sendable {
        /// The chapter's index.
        let chapter: Int
        /// The offset in the chapter.
        let offset: Int
    }

    /// The book's `bookmarks` and saved reading `position`, moved along
    /// `route` from `previous`, the book's content index before the save, to
    /// `current`, its index after it. `track` names the track the save
    /// changed in a book of several, and is nil for a book of one file. A
    /// bookmark keeps its number, note, and date; a position that moves is
    /// dated `date`, so it wins over an older copy of itself wherever the
    /// two meet, as in another Mac's library index.
    static func follow(
        _ route: AudioEditorTimeMap.Route,
        bookmarks: [Bookmark],
        position: ReadingPosition?,
        track: Track?,
        from previous: BookContentIndex,
        to current: BookContentIndex,
        at date: Date
    ) -> (bookmarks: [Bookmark], position: ReadingPosition?) {
        let movedBookmarks = bookmarks.map { bookmark -> Bookmark in
            let place = Place(chapter: bookmark.chapterIndex, offset: bookmark.characterOffset)
            guard let moved = move(place, along: route, track: track, from: previous, to: current), moved != place else {
                return bookmark
            }
            var copy = bookmark
            copy.chapterIndex = moved.chapter
            copy.characterOffset = moved.offset
            return copy
        }
        let movedPosition = position.map { position -> ReadingPosition in
            let place = Place(chapter: position.chapterIndex, offset: position.characterOffset)
            guard let moved = move(place, along: route, track: track, from: previous, to: current), moved != place else {
                return position
            }
            var copy = position
            copy.chapterIndex = moved.chapter
            copy.characterOffset = moved.offset
            // The offset across the whole book, which the library's time
            // left is worked out from, when the position kept one.
            copy.globalCharacterOffset = position.globalCharacterOffset.map { _ in
                current.chapterStartOffset(moved.chapter) + moved.offset
            }
            copy.lastUpdated = date
            return copy
        }
        return (movedBookmarks, movedPosition)
    }

    /// Where `place` goes, as the type describes; nil when it stays where it
    /// is, as one the layouts can't place does.
    static func move(
        _ place: Place,
        along route: AudioEditorTimeMap.Route,
        track: Track?,
        from previous: BookContentIndex,
        to current: BookContentIndex
    ) -> Place? {
        guard previous.chapters.indices.contains(place.chapter), place.offset >= 0 else { return nil }
        switch (previous.audioLayout, current.audioLayout) {
        case (.singleFile?, .singleFile?):
            // A time on the whole file, which the chapters after the save
            // divide again.
            let time = seconds(previous.chapterStartOffset(place.chapter) + place.offset)
            let location = current.location(forGlobalOffset: characters(route.map(time)))
            return Place(chapter: location.chapterIndex, offset: location.localOffset)
        case (.multiFile?, .multiFile?):
            guard let track, let file = previous.chapters[place.chapter].audioFilePath else { return nil }
            guard file == track.before else {
                // Another track: the same time, in that track's chapter now.
                return chapter(playing: file, in: current).map { Place(chapter: $0, offset: place.offset) }
            }
            guard let chapter = chapter(playing: track.after, in: current) else { return nil }
            // The track's last character at most, as a place at the very
            // end of a book of one file is (`BookContentIndex.location`).
            let last = max(0, current.chapters[chapter].characterCount - 1)
            return Place(chapter: chapter, offset: min(characters(route.map(seconds(place.offset))), last))
        default:
            return nil
        }
    }

    // MARK: Helpers

    /// The index of the chapter of `index` that plays the track at `path`
    /// inside the book's folder of tracks.
    private static func chapter(playing path: String, in index: BookContentIndex) -> Int? {
        index.chapters.firstIndex { $0.audioFilePath == path }
    }

    /// The time `characters` characters stand for, in seconds.
    private static func seconds(_ characters: Int) -> TimeInterval {
        AudioBookParser.time(forCharacterOffset: characters)
    }

    /// The characters standing for `seconds`, to the nearest one, never
    /// fewer than none. Rounded, unlike the reader's count of a playing
    /// time (`AudioBookParser.characterOffset(forTime:)`), so a place no edit
    /// moved comes back as the very same offset after its trip through a
    /// time in seconds.
    private static func characters(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds * ReaderViewModel.audioCharsPerSecond).rounded())
    }
}
