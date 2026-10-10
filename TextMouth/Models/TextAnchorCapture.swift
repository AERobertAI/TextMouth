import Foundation

// MARK: - Capturing Saved Places' Words (T06's Branch B)

extension DocumentContent {
    /// The anchor of `place` in this text (T06): the words just before and
    /// after it in its chapter's reading text, its share of the whole book,
    /// and `measure`, the text it was measured in
    /// (`TextAnchor.measure(ofTextCachedBy:)`). Nil for a chapter this text
    /// lacks.
    ///
    /// An offset outside its chapter is quoted at the chapter's nearer edge
    /// (`TextAnchor.init(capturingAt:in:chapterStart:bookLength:measuredIn:)`),
    /// which is where the user's answer to T06's question 7 puts a place
    /// past its chapter's end; its share still counts the offset as given,
    /// so a place at or past the end of the last chapter marks the end of
    /// the book, as `Book.restsAtEnd` reads it finished.
    func anchor(at place: TextPlace, measuredIn measure: String?) -> TextAnchor? {
        guard chapters.indices.contains(place.chapter) else { return nil }
        return TextAnchor(
            capturingAt: place.offset,
            in: chapters[place.chapter].text,
            chapterStart: chapterStartOffset(place.chapter),
            bookLength: totalCharacterCount,
            measuredIn: measure
        )
    }
}
