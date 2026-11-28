import Foundation

// MARK: - Which Notes Are Shown

/// Which footnotes and endnotes of a Word 97-2003 document a person reading it
/// sees. A note is shown by its reference mark in the main text; when the mark
/// is in hidden text, or in text a tracked change deleted, the note is not
/// shown either, so the reader leaves its text out.
///
/// Two tables say where each note is ([MS-DOC] PlcffndRef and PlcffndTxt,
/// and the endnotes' PlcfendRef and PlcfendTxt): the reference
/// table is a list of the character positions of the marks in the main text
/// (`n` of them, then one more position, then an `FRD` of 2 bytes for each),
/// and the text table a list of the positions in the note story where each
/// of the `n` notes begins, then where the last ends, and then the story's
/// end. The i-th mark belongs to the i-th note.
///
/// The tables decide what to leave out, and where each note begins, so that
/// each is read as a story of its own (its list numbers count from the start).
/// A table that does not fit the story, or the other table, or goes back on
/// itself, is not trusted: the whole story is then read, as before, so no
/// note is lost to damage.
enum WordNotes {

    /// The notes of `story` (character positions) to read, one range for each
    /// note whose reference mark is shown, in order, and the stretches the
    /// note table puts in no note (a note story ends with a mark of its own).
    /// A note table that is missing or does not fit reads the story as one range.
    /// - Parameters:
    ///   - references: where the reference table lies in `table`, or nil.
    ///   - texts: where the text table lies in `table`, or nil.
    ///   - isNotShown: for the positions of the marks (in order), whether
    ///     each is in hidden or deleted text.
    static func shownRanges(
        of story: Range<Int>, references: Range<Int>?, texts: Range<Int>?, in table: OLEBytes,
        isNotShown: ([Int]) -> [Bool]
    ) -> [Range<Int>] {
        guard !story.isEmpty else { return [] }
        // A table that is missing, or whose size is not a whole number of
        // entries, tells nothing: read the whole story.
        guard let references, let texts, references.count >= 4, (references.count - 4) % 6 == 0,
              texts.count % 4 == 0 else { return [story] }
        let count = (references.count - 4) / 6
        guard count > 0, texts.count / 4 >= count + 1,
              let marks = try? (0..<count).map({ try table.u32(references.lowerBound + $0 * 4) }),
              let starts = try? (0...count).map({ try table.u32(texts.lowerBound + $0 * 4) }),
              zip(marks, marks.dropFirst()).allSatisfy({ $0 <= $1 }),
              zip(starts, starts.dropFirst()).allSatisfy({ $0 <= $1 }) else { return [story] }

        let hidden = isNotShown(marks)
        guard hidden.count == count else { return [story] }
        var shown: [Range<Int>] = []
        var position = story.lowerBound
        for index in 0..<count {
            // The note's text, held to the story.
            let start = min(story.lowerBound + starts[index], story.upperBound)
            let end = min(story.lowerBound + starts[index + 1], story.upperBound)
            // What lies before the note, outside every note.
            if position < start { shown.append(position..<start) }
            if !hidden[index], start < end { shown.append(start..<end) }
            position = max(position, end)
        }
        if position < story.upperBound { shown.append(position..<story.upperBound) }
        return shown
    }

    /// The text boxes of `story` (character positions) to read, one range for
    /// each box: the text table (`PlcftxbxTxt`) is a list of `n` + 2
    /// positions, each box running from one to the next, and the last range
    /// (the story's end mark, in a file with real boxes) "MUST be ignored".
    /// A table that is missing or does not fit reads the story as one range.
    static func boxRanges(of story: Range<Int>, texts: Range<Int>?, in table: OLEBytes) -> [Range<Int>] {
        guard !story.isEmpty else { return [] }
        // n + 1 positions of 4 bytes and, for each of the n boxes, a 22-byte FTXBXS.
        guard let texts, (texts.count + 22) % 26 == 0 else { return [story] }
        let positions = (texts.count + 22) / 26
        guard positions >= 2,
              let cps = try? (0..<positions).map({ try table.u32(texts.lowerBound + $0 * 4) }),
              zip(cps, cps.dropFirst()).allSatisfy({ $0 <= $1 }) else { return [story] }
        var boxes: [Range<Int>] = []
        for index in 0..<(positions - 2) {
            let start = min(story.lowerBound + cps[index], story.upperBound)
            let end = min(story.lowerBound + cps[index + 1], story.upperBound)
            if start < end { boxes.append(start..<end) }
        }
        return boxes
    }
}
