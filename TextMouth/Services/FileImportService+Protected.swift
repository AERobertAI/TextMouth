import Foundation

// MARK: - Importing a Protected Book (FR41)

extension FileImportService {

    /// Publishes `staged`, whose file has a password, as a locked book: its
    /// record is written with an empty index and nothing of its text is
    /// read, so no content.md, no headings, and no words exist beside it.
    /// Its title is the file's name and its author unknown until it is
    /// unlocked and read.
    /// - Throws: an `ImportFailure` naming the step that failed.
    static func publishLockedBook(
        _ staged: Book,
        from staging: ImportStaging,
        run: inout ImportRun
    ) throws -> ImportedBook {
        let book = staging.published(staged)
        // An index with no chapters stands for "not read": the book is read
        // straight from its file each time it is opened.
        let index = BookContentIndex(
            version: BookContentIndex.currentVersion,
            kind: .text,
            format: staged.format,
            generatedAt: Date(),
            totalWordCount: 0,
            totalCharacterCount: 0,
            totalAudioDuration: nil,
            audioLayout: nil,
            chapters: []
        )
        try run.begin(.savingRecord, in: staging.directory)
        try writeVerifiedRecord(of: book, contentIndex: index, into: staging.directory)
        try run.begin(.publishing, in: staging.directory)
        try staging.publish()
        return ImportedBook(book: book)
    }
}
