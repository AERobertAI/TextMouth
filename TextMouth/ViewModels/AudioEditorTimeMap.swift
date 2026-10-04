import Foundation

/// Where a time on the edited audio goes when an edit changes it (FR04): the
/// editor's markers and selection follow the sound through every edit, and
/// back through an undo. The rules are the timeline's own for chapter
/// markers (`AudioEditTimeline`), so a marker and a chapter marker at one
/// place stay together:
///
/// - A time before the edited stretch stays; one after it moves by the
///   change in length.
/// - A time where sound is inserted stays before the new sound.
/// - A time inside a removed stretch goes to where it was; inside a moved
///   stretch, with it; inside a replaced or processed stretch, to the same
///   proportion of the new sound.
///
/// Each edit is described by the lengths of the audio before and after it,
/// which give the new length of a stretch a filter or a punch-in changed.
/// Pure functions, so the tests cover them whole.
enum AudioEditorTimeMap {
    /// Where `time`, on the audio as it was before `edit`, lies after it.
    /// `before` and `after` are the audio's lengths around the edit.
    static func forward(_ time: TimeInterval, through edit: AudioEdit, before: TimeInterval, after: TimeInterval) -> TimeInterval {
        let mapped: TimeInterval
        switch edit {
        case .trimStart(let to):
            mapped = time - to
        case .trimEnd(let at):
            mapped = min(time, at)
        case .cut(let range):
            if time <= range.start {
                mapped = time
            } else if time < range.end {
                mapped = range.start
            } else {
                mapped = time - range.duration
            }
        case .move(let range, let to):
            mapped = moved(time, range: range, to: to)
        case .insertSilence(let at, let duration):
            mapped = time <= at ? time : time + duration
        case .insert(let at, let take):
            mapped = time <= at ? time : time + take.range.duration
        case .replace(let range, _):
            mapped = stretched(time, range: range, newLength: range.duration + after - before)
        case .filter(_, let range), .gain(_, let range):
            let stretch = range ?? AudioTimeRange(start: 0, end: before)
            mapped = stretched(time, range: stretch, newLength: stretch.duration + after - before)
        case .setChapter, .removeChapter:
            mapped = time
        }
        return min(max(0, mapped), max(0, after))
    }

    /// Where `time`, on the audio as `edit` left it, lay before it: what an
    /// undo of `edit` does. `before` and `after` are the audio's lengths
    /// around the edit, as it was made.
    static func backward(_ time: TimeInterval, through edit: AudioEdit, before: TimeInterval, after: TimeInterval) -> TimeInterval {
        let mapped: TimeInterval
        switch edit {
        case .trimStart(let to):
            mapped = time + to
        case .trimEnd:
            mapped = time
        case .cut(let range):
            // The cut point stays before the sound put back.
            mapped = time <= range.start ? time : time + range.duration
        case .move(let range, let to):
            // A move is undone by moving the stretch back from where it went.
            let length = range.duration
            let landed = to <= range.start ? to : to - length
            let home = to <= range.start ? range.end : range.start
            mapped = moved(time, range: AudioTimeRange(start: landed, end: landed + length), to: home)
        case .insertSilence(let at, let duration):
            mapped = removed(time, at: at, length: duration)
        case .insert(let at, let take):
            mapped = removed(time, at: at, length: take.range.duration)
        case .replace(let range, _):
            let newLength = range.duration + after - before
            mapped = stretched(time, range: AudioTimeRange(start: range.start, end: range.start + newLength), newLength: range.duration)
        case .filter(_, let range), .gain(_, let range):
            let stretch = range ?? AudioTimeRange(start: 0, end: before)
            let newLength = stretch.duration + after - before
            mapped = stretched(time, range: AudioTimeRange(start: stretch.start, end: stretch.start + newLength), newLength: stretch.duration)
        case .setChapter, .removeChapter:
            mapped = time
        }
        return min(max(0, mapped), max(0, before))
    }

    /// Where an undo or a redo of `edit` leaves the cursor: where the edit
    /// changed the audio, on the audio as it was before the edit.
    static func place(of edit: AudioEdit) -> TimeInterval {
        switch edit {
        case .trimStart:
            return 0
        case .trimEnd(let at):
            return at
        case .cut(let range), .replace(let range, _):
            return range.start
        case .move(let range, _):
            return range.start
        case .insertSilence(let at, _), .insert(let at, _), .setChapter(let at, _), .removeChapter(let at):
            return at
        case .filter(_, let range), .gain(_, let range):
            return range?.start ?? 0
        }
    }

    // MARK: Helpers

    /// `time` after `range` moved to `to`, a time on the audio before the
    /// move: inside the range it goes with it; elsewhere it closes up over
    /// the range's old place and opens up for its new one, a time right at
    /// the new place staying before the moved sound.
    private static func moved(_ time: TimeInterval, range: AudioTimeRange, to: TimeInterval) -> TimeInterval {
        let length = range.duration
        let landed = to <= range.start ? to : to - length
        if time >= range.start, time < range.end {
            return landed + (time - range.start)
        }
        let closed = time < range.start ? time : time - length
        return closed <= landed ? closed : closed + length
    }

    /// `time` once the stretch of `length` seconds at `at` is taken out
    /// again: a time inside it goes to where it was.
    private static func removed(_ time: TimeInterval, at: TimeInterval, length: TimeInterval) -> TimeInterval {
        if time <= at { return time }
        if time < at + length { return at }
        return time - length
    }

    /// `time` once `range` is replaced by sound `newLength` seconds long: a
    /// time inside it goes to the same proportion of the new sound, and one
    /// after it moves by the change in length.
    private static func stretched(_ time: TimeInterval, range: AudioTimeRange, newLength: TimeInterval) -> TimeInterval {
        if time <= range.start { return time }
        if time >= range.end { return time + newLength - range.duration }
        guard range.duration > 0 else { return range.start }
        return range.start + (time - range.start) * newLength / range.duration
    }
}

// MARK: - Routes Between Two States of the Audio

extension AudioEditorTimeMap {
    /// One edit as a route crosses it (FR04): its entry in the edit list,
    /// and the audio's lengths just before and just after the edit as it
    /// was made, which `forward` and `backward` need for an edit whose new
    /// sound has a length of its own, as a filter's has.
    struct Crossing: Equatable, Sendable {
        /// The entry's identity in the edit list.
        let entryID: UUID
        /// The edit.
        let edit: AudioEdit
        /// How long the audio lasted just before the edit, in seconds.
        let before: TimeInterval
        /// How long it lasted just after it.
        let after: TimeInterval

        /// `entry`, made when the audio lasted `before` seconds, leaving it
        /// `after` seconds long.
        init(_ entry: AudioEditEntry, before: TimeInterval, after: TimeInterval) {
            entryID = entry.id
            edit = entry.edit
            self.before = before
            self.after = after
        }
    }

    /// The way from one state of the edited audio to another, edit by edit
    /// (FR04): from the book's file as last saved to the audio as it is
    /// edited now (`AudioEditSession.savedFileRoute`), which a save moves
    /// the book's bookmarks and saved reading position along.
    ///
    /// A route undoes the edits its start holds and its end doesn't, newest
    /// first, then makes the edits its end holds and its start doesn't,
    /// oldest first. It grows as the end changes: an edit made at the end,
    /// or one undone or redone there, is one more crossing, unless it takes
    /// back the crossing before it, which then goes. So an edit made and
    /// undone before a save moves nothing, and a time comes back exactly
    /// where it was, which mapping through the edit and back would not do
    /// for a time inside a cut.
    struct Route: Equatable, Sendable {
        /// The edits the start holds and the end doesn't, newest first: the
        /// order they are undone in.
        private(set) var undone: [Crossing] = []
        /// The edits the end holds and the start doesn't, oldest first: the
        /// order they are made in.
        private(set) var made: [Crossing] = []

        /// A route from a state of the audio to itself.
        init() {}

        /// Whether the route goes nowhere: its two ends hold the same edits.
        var isEmpty: Bool {
            undone.isEmpty && made.isEmpty
        }

        /// Extends the route by an edit its end has just made, or redone:
        /// one the start holds, redone as the next of them, takes back its
        /// undo; any other is made.
        mutating func make(_ crossing: Crossing) {
            if made.isEmpty, undone.last?.entryID == crossing.entryID {
                undone.removeLast()
            } else {
                made.append(crossing)
            }
        }

        /// Extends the route by an edit its end has just undone: its newest
        /// edit, which takes back the crossing that made it, or, when the
        /// end has made none, one more of the start's edits undone. Returns
        /// false, changing nothing, when the edit is neither, so the route
        /// no longer describes the audio and its owner must drop it.
        mutating func undo(_ crossing: Crossing) -> Bool {
            if let last = made.last {
                guard last.entryID == crossing.entryID else { return false }
                made.removeLast()
            } else {
                undone.append(crossing)
            }
            return true
        }

        /// Where `time`, on the audio at the route's start, lies at its end:
        /// back through each edit undone, then on through each edit made,
        /// kept inside the audio at every step.
        func map(_ time: TimeInterval) -> TimeInterval {
            let unmade = undone.reduce(time) { time, crossing in
                AudioEditorTimeMap.backward(time, through: crossing.edit, before: crossing.before, after: crossing.after)
            }
            return made.reduce(unmade) { time, crossing in
                AudioEditorTimeMap.forward(time, through: crossing.edit, before: crossing.before, after: crossing.after)
            }
        }
    }
}
