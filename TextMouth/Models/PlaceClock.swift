import Foundation

/// The clock that names a book's places by times, and finds the place a
/// time names (P08): where each chapter starts on it and how long it lasts.
///
/// - An audiobook's places count its recording's own time, whatever speed
///   it plays at (`recording(of:)`). That is the time the player, its skips,
///   the audio editor, a transcript's sentences, a chapter list, and show
///   notes all count, so a place keeps its time when the speed changes.
/// - A text book has no recording, so its places count its words at its
///   speed (`reading(of:readingTime:)`), as its times always have.
///
/// A place is a chapter and an offset within it in the reader's units: an
/// audiobook's placeholder characters, ten for each second of its chapter
/// (`ReaderViewModel.audioCharsPerSecond`), or a text book's UTF-16 code
/// units. Go to Time, the Headings sheet's time into the book, and Copy
/// Reading Position's place all count on this clock, so a time any of them
/// shows lands back on its place at every speed.
struct PlaceClock: Equatable, Sendable {
    /// A place in a book: a chapter, and an offset within it in the reader's
    /// units, as `ReaderViewModel.navigateTo(chapterIndex:characterOffset:)`
    /// takes them.
    struct Place: Equatable, Sendable {
        var chapterIndex: Int
        var characterOffset: Int
    }

    /// Where each chapter starts on this clock, in seconds: the chapters
    /// before it, one after another.
    let chapterStarts: [TimeInterval]
    /// How long each chapter lasts on this clock, in seconds.
    let chapterDurations: [TimeInterval]
    /// Each chapter's length in the reader's units.
    let chapterLengths: [Int]
    /// The reader's units in each second within a chapter: ten for an
    /// audiobook, and for a text book its units over its reading time. 0
    /// when the clock has no time to share out (a text book without words).
    let unitsPerSecond: Double
    /// The clock's whole length, in seconds: where its last chapter ends.
    let length: TimeInterval

    /// A clock whose chapters last `chapterDurations` seconds and hold
    /// `chapterLengths` units, `unitsPerSecond` of them each second. A
    /// duration that is no number, or below 0, counts as none, and a rate
    /// that is not above 0 as none, so no clock built from damaged data can
    /// trap; the lists are read pairwise, as far as the shorter goes.
    init(chapterDurations: [TimeInterval], chapterLengths: [Int], unitsPerSecond: Double) {
        let count = min(chapterDurations.count, chapterLengths.count)
        var starts: [TimeInterval] = []
        var durations: [TimeInterval] = []
        starts.reserveCapacity(count)
        durations.reserveCapacity(count)
        var runningStart: TimeInterval = 0
        for duration in chapterDurations.prefix(count) {
            let usable = duration.isFinite ? max(0, duration) : 0
            starts.append(runningStart)
            durations.append(usable)
            runningStart += usable
        }
        chapterStarts = starts
        self.chapterDurations = durations
        self.chapterLengths = chapterLengths.prefix(count).map { max(0, $0) }
        self.unitsPerSecond = unitsPerSecond.isFinite && unitsPerSecond > 0 ? unitsPerSecond : 0
        length = runningStart
    }

    // MARK: - The Two Clocks

    /// An audiobook's recording, as its content index measured it: each
    /// chapter lasting its recorded duration (`BookContentAudioChapterIndex`),
    /// the chapters one after another.
    ///
    /// - One file, with chapter marks or without: the file's own time line,
    ///   which the player plays and the cursor ticks on. The index records
    ///   each chapter as long as its placeholder (a tenth of a second at
    ///   most short of its mark's length), so each chapter starts where the
    ///   reader plays it, at its placeholders' sum
    ///   (`ReaderViewModel.AudioLayout.chapterStartTime`). The index keeps no
    ///   mark's own start: every chapter of one file records 0.
    /// - A file per chapter: the files one after another, each as long as
    ///   its placeholder, as the index records it.
    /// - DAISY sections: the sections one after another, each as long as its
    ///   clips together, which can differ from its placeholder's tenths by a
    ///   tenth of a second, or more for a section shorter than a second,
    ///   whose placeholder holds a whole second.
    ///
    /// A chapter the index does not describe as audio (an index made for
    /// text, as a test's content may carry) lasts its placeholder's seconds.
    static func recording(of index: BookContentIndex) -> PlaceClock {
        let charactersPerSecond = ReaderViewModel.audioCharsPerSecond
        return PlaceClock(
            chapterDurations: index.chapters.map { chapter in
                if let measured = chapter.audio?.duration, measured.isFinite, measured >= 0 {
                    return measured
                }
                return Double(chapter.characterCount) / charactersPerSecond
            },
            chapterLengths: index.chapters.map(\.characterCount),
            unitsPerSecond: charactersPerSecond
        )
    }

    /// A text book's words at its speed: `readingTime`, the whole book's
    /// reading time at its words per minute
    /// (`DocumentContent.estimatedReadingTime(wpm:)`), shared out over its
    /// UTF-16 code units, as every time the reader shows for a text book has
    /// always been shared out.
    static func reading(of index: BookContentIndex, readingTime: TimeInterval) -> PlaceClock {
        let lengths = index.chapters.map(\.characterCount)
        let units = lengths.reduce(0) { $0 + max(0, $1) }
        // Seconds for each unit; none when there is no time or no text.
        let secondsPerUnit = readingTime.isFinite && readingTime > 0 && units > 0
            ? readingTime / Double(units)
            : 0
        return PlaceClock(
            chapterDurations: lengths.map { Double(max(0, $0)) * secondsPerUnit },
            chapterLengths: lengths,
            unitsPerSecond: secondsPerUnit > 0 ? 1 / secondsPerUnit : 0
        )
    }

    // MARK: - Places and Times

    /// The time of a place: where its chapter starts, and the time into the
    /// chapter its offset stands for, never past the chapter's own end. A
    /// chapter's end is where the chapter ends on the clock, so the end of
    /// the last chapter is the clock's end. A chapter before the first is at
    /// 0, and one after the last at the end.
    func time(chapterIndex: Int, characterOffset: Int) -> TimeInterval {
        guard let last = chapterStarts.indices.last, chapterIndex >= 0 else { return 0 }
        guard chapterIndex <= last else { return length }
        let chapterLength = chapterLengths[chapterIndex]
        let duration = chapterDurations[chapterIndex]
        let offset = min(max(characterOffset, 0), chapterLength)
        let intoChapter: TimeInterval
        if offset >= chapterLength {
            intoChapter = duration
        } else if unitsPerSecond > 0 {
            intoChapter = min(Double(offset) / unitsPerSecond, duration)
        } else {
            intoChapter = 0
        }
        return chapterStarts[chapterIndex] + intoChapter
    }

    /// The time of `place`.
    func time(of place: Place) -> TimeInterval {
        time(chapterIndex: place.chapterIndex, characterOffset: place.characterOffset)
    }

    /// The place at `time`: in the chapter that holds it, at the offset
    /// nearest to it. A time at or before 0, or one that is no number, is
    /// the book's beginning, and one at or after the clock's end is the end
    /// of the last chapter. A chapter lasting no time holds no time; its
    /// start belongs to the chapter after it.
    func place(atTime time: TimeInterval) -> Place {
        guard let last = chapterStarts.indices.last, !time.isNaN, time > 0 else {
            return Place(chapterIndex: 0, characterOffset: 0)
        }
        guard time < length else {
            return Place(chapterIndex: last, characterOffset: chapterLengths[last])
        }
        let chapterIndex = lastChapter(startingAtOrBefore: time)
        let units = ((time - chapterStarts[chapterIndex]) * unitsPerSecond).rounded()
        // A chapter can last a little longer than its units stand for (a
        // DAISY section's measured clips), so the offset stops at its end.
        let offset = min(max(units, 0), Double(chapterLengths[chapterIndex]))
        return Place(chapterIndex: chapterIndex, characterOffset: Int(offset))
    }

    /// The place a time typed into Go to Time names: the heading that starts
    /// less than a second after `time`, when one does, so that a heading's
    /// time, shown in whole seconds with its tenths dropped, lands on the
    /// heading itself rather than a moment before it, perhaps at the end of
    /// the chapter before; otherwise the place at `time`. Of several
    /// headings starting within that second, the earliest is taken, and a
    /// heading starting up to half a unit before `time` counts as starting
    /// at it. `headings` may come in any order.
    func place(forTypedTime time: TimeInterval, headings: [Heading]) -> Place {
        let tolerance = unitsPerSecond > 0 ? 0.5 / unitsPerSecond : 0
        var nearest: (heading: Heading, time: TimeInterval)?
        for heading in headings {
            let headingTime = self.time(chapterIndex: heading.chapterIndex, characterOffset: heading.characterOffset)
            guard headingTime >= time - tolerance, headingTime < time + Self.headingSnapWindow else { continue }
            if nearest.map({ headingTime < $0.time }) ?? true {
                nearest = (heading, headingTime)
            }
        }
        guard let heading = nearest?.heading else { return place(atTime: time) }
        return Place(chapterIndex: heading.chapterIndex, characterOffset: heading.characterOffset)
    }

    /// How far before a heading a typed time still lands on it: the second
    /// that a time shown in whole seconds can fall short of the heading by.
    static let headingSnapWindow: TimeInterval = 1

    // MARK: - Finding a Chapter

    /// The last chapter that starts at or before `time`, which is 0 or more
    /// and before the clock's end. Starts never decrease, so a binary search
    /// finds it; a chapter lasting no time shares its start with the next,
    /// which is found instead.
    private func lastChapter(startingAtOrBefore time: TimeInterval) -> Int {
        var low = 0
        var high = chapterStarts.count - 1
        while low < high {
            // Round up, so the range always shrinks when low moves.
            let middle = (low + high + 1) / 2
            if chapterStarts[middle] <= time {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }
}
