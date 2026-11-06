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
/// The tables only decide what to leave out. A table that does not fit the
/// story, or the other table, or goes back on itself, is not trusted: the
/// whole story is then read, as before, so no note is lost to damage.
enum WordNotes {

    /// The parts of `story` (character positions) to read: all of it, less
    /// the text of each note whose reference mark is not shown.
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
        for index in 0..<count where hidden[index] {
            // The note's text, held to the story.
            let start = min(story.lowerBound + starts[index], story.upperBound)
            let end = min(story.lowerBound + starts[index + 1], story.upperBound)
            if position < start { shown.append(position..<start) }
            position = max(position, end)
        }
        if position < story.upperBound { shown.append(position..<story.upperBound) }
        return shown
    }
}
