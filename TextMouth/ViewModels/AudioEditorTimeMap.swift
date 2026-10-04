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
