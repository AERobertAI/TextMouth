import XCTest
@testable import TextMouth

/// The fields that carry saved places' anchors (T06): a reading position's
/// and a bookmark's anchor, and a book's skipped headings, kept in step
/// with its heading IDs for older builds. Each is read leniently and
/// written only when set, so rows and records written before anchors load
/// as they were, and a book with no anchor and no skip is written exactly
/// as before. Nothing captures an anchor yet. Pure: no window, no file.
final class TextAnchorRecordTests: XCTestCase {

    // MARK: - Helpers

    /// An anchor as a capture would make one.
    private let anchor = TextAnchor(before: "the long spanner ", after: "without looking up", fraction: 0.25, measuredIn: "3.0.7/1.0.0")

    /// A skipped heading in today's ID form, with its anchor.
    private var skippedNotes: SkippedHeading {
        SkippedHeading(level: 2, label: "Notes - and - Errata", chapterIndex: 4, characterOffset: 90, anchor: anchor)
    }

    /// A book holding an anchored position, an anchored bookmark, and a
    /// skipped heading with its ID.
    private func anchoredBook() -> Book {
        Book(
            title: "Night Shift",
            format: .txt,
            filePath: "/library/night-shift.txt",
            md5Hash: "hash",
            readingPosition: ReadingPosition(chapterIndex: 2, characterOffset: 40, globalCharacterOffset: 900, anchor: anchor),
            bookmarks: [Bookmark(number: 1, chapterIndex: 2, characterOffset: 40, label: "Spanner", anchor: anchor)],
            tmbDirectoryName: "Night-Shift.tmb",
            skippedHeadingIDs: [skippedNotes.id],
            skippedHeadings: [skippedNotes]
        )
    }

    /// `value` through JSON and back.
    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }

    /// `value` written as JSON, its object changed by `edit` (as another
    /// build or a hand would leave it), and read back.
    private func reread<Value: Codable>(_ value: Value, editing edit: (inout [String: Any]) -> Void) throws -> Value {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        edit(&object)
        return try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// `object` with `key` removed from the object at `path` within it.
    private func removing(_ key: String, at path: [String] = [], in object: [String: Any]) -> [String: Any] {
        guard let first = path.first else {
            var copy = object
            copy.removeValue(forKey: key)
            return copy
        }
        var copy = object
        let rest = Array(path.dropFirst())
        if let inner = object[first] as? [String: Any] {
            copy[first] = removing(key, at: rest, in: inner)
        } else if let list = object[first] as? [[String: Any]] {
            copy[first] = list.map { removing(key, at: rest, in: $0) }
        }
        return copy
    }

    // MARK: - Anchors on Places

    /// A position and a bookmark keep their anchors through JSON, and
    /// through a book's record (bookInfo.json) and back.
    func testAPositionAndABookmarkKeepTheirAnchors() throws {
        let book = anchoredBook()
        XCTAssertEqual(try roundTrip(try XCTUnwrap(book.readingPosition)).anchor, anchor)
        XCTAssertEqual(try roundTrip(try XCTUnwrap(book.bookmarks.first)).anchor, anchor)
        XCTAssertEqual(try roundTrip(book), book)

        let rebuilt = Book(record: book.makeBookInfo(), filePath: book.filePath, folderPath: book.folderPath, tmbDirectoryName: book.tmbDirectoryName)
        XCTAssertEqual(rebuilt.readingPosition?.anchor, anchor)
        XCTAssertEqual(rebuilt.bookmarks.first?.anchor, anchor)
        XCTAssertEqual(rebuilt.skippedHeadings, [skippedNotes])
        let record = try roundTrip(book.makeBookInfo())
        XCTAssertEqual(record.state.readingPosition?.anchor, anchor)
        XCTAssertEqual(record.state.skippedHeadings, [skippedNotes])
    }

    /// A row and a record written before anchors (no "anchor" and no
    /// "skippedHeadings" fields) load as they were: no anchors, and skipped
    /// headings made from the heading IDs, without anchors.
    func testRowsAndRecordsWrittenBeforeAnchorsLoad() throws {
        let book = anchoredBook()
        let row = try reread(book) { object in
            object = removing("skippedHeadings", in: object)
            object = removing("anchor", at: ["readingPosition"], in: object)
            object = removing("anchor", at: ["bookmarks"], in: object)
        }
        XCTAssertNil(row.readingPosition?.anchor)
        XCTAssertEqual(row.readingPosition?.characterOffset, 40)
        XCTAssertEqual(row.readingPosition?.globalCharacterOffset, 900)
        XCTAssertNil(row.bookmarks.first?.anchor)
        XCTAssertEqual(row.bookmarks.first?.label, "Spanner")
        XCTAssertEqual(row.skippedHeadingIDs, [skippedNotes.id])
        var withoutAnchor = skippedNotes
        withoutAnchor.anchor = nil
        XCTAssertEqual(row.skippedHeadings, [withoutAnchor])

        let record = try reread(book.makeBookInfo()) { object in
            object = removing("skippedHeadings", at: ["state"], in: object)
            object = removing("anchor", at: ["state", "readingPosition"], in: object)
            object = removing("anchor", at: ["bookmarks"], in: object)
        }
        XCTAssertNil(record.state.readingPosition?.anchor)
        XCTAssertNil(record.bookmarks.first?.anchor)
        XCTAssertEqual(record.state.skippedHeadings, [withoutAnchor])
    }

    /// A damaged anchor or list of skipped headings counts as none, rather
    /// than failing the place, the book, and with it the library: the place
    /// keeps its numbers, and the skipped headings are made again from the
    /// IDs.
    func testDamagedAnchorsAndSkippedHeadingsCountAsNone() throws {
        let book = anchoredBook()
        let row = try reread(book) { object in
            object["skippedHeadings"] = "not a list"
            if var position = object["readingPosition"] as? [String: Any] {
                position["anchor"] = 5
                object["readingPosition"] = position
            }
            if var bookmarks = object["bookmarks"] as? [[String: Any]], var first = bookmarks.first {
                first["anchor"] = ["before": 12, "after": ["x"], "fraction": "half"]
                bookmarks[0] = first
                object["bookmarks"] = bookmarks
            }
        }
        XCTAssertNil(row.readingPosition?.anchor)
        XCTAssertEqual(row.readingPosition?.characterOffset, 40)
        XCTAssertEqual(row.bookmarks.first?.anchor, TextAnchor(before: "", after: "", fraction: 0), "its fields read as empty")
        XCTAssertEqual(row.skippedHeadings?.map(\.id), [skippedNotes.id])
    }

    /// A book with no anchor and no skipped heading is written exactly as
    /// before: no new field in library.json or bookInfo.json.
    func testABookWithoutAnchorsOrSkipsWritesNoNewField() throws {
        let book = Book(
            title: "Plain",
            format: .txt,
            filePath: "/library/plain.txt",
            md5Hash: "hash",
            readingPosition: ReadingPosition(chapterIndex: 1, characterOffset: 3),
            bookmarks: [Bookmark(number: 1, chapterIndex: 1, characterOffset: 3)]
        )
        let row = String(decoding: try JSONEncoder().encode(book), as: UTF8.self)
        let record = String(decoding: try JSONEncoder().encode(book.makeBookInfo()), as: UTF8.self)
        for json in [row, record] {
            XCTAssertFalse(json.contains("\"anchor\""), json)
            XCTAssertFalse(json.contains("\"skippedHeadings\""), json)
        }
        XCTAssertNil(book.skippedHeadings)
    }

    // MARK: - Skipped Headings

    /// A heading ID in today's form names a skipped heading, a label with
    /// hyphens of its own and an empty label included; an ID in any other
    /// form names none. A skip's ID is its heading's.
    func testAHeadingIDNamesASkippedHeading() throws {
        let notes = try XCTUnwrap(SkippedHeading(id: "4-90-2-Notes - and - Errata"))
        XCTAssertEqual(notes, SkippedHeading(level: 2, label: "Notes - and - Errata", chapterIndex: 4, characterOffset: 90))
        XCTAssertEqual(SkippedHeading(id: "1-0-1-")?.label, "")
        for id in ["heading-5", "notes", "", "007-1-1-Seven", "+7-1-1-Seven", "1-2-x-Level", "1--2-3-Negative"] {
            XCTAssertNil(SkippedHeading(id: id), id)
        }
        let heading = Heading(level: 3, text: "CHAPTER I. Down the Rabbit-Hole", chapterIndex: 2, characterOffset: 0)
        XCTAssertEqual(SkippedHeading(heading).id, heading.id)
        XCTAssertEqual(SkippedHeading(id: heading.id), SkippedHeading(heading))
    }

    /// A book's skipped headings stay in step with its heading IDs, which
    /// an older build's row names alone: a change to the IDs keeps each
    /// skipped heading still named (with its anchor), reads each new one
    /// from its ID, and drops each no longer named; an ID in no heading's
    /// form stays among the IDs but names no skipped heading. Both are
    /// written, the IDs for older builds.
    func testSkippedHeadingsKeepInStepWithTheHeadingIDs() throws {
        var book = anchoredBook()
        let intro = Heading(level: 1, text: "Introduction", chapterIndex: 0, characterOffset: 0)
        book.skippedHeadingIDs = (book.skippedHeadingIDs ?? []) + [intro.id]
        XCTAssertEqual(book.skippedHeadings, [skippedNotes, SkippedHeading(intro)])

        book.skippedHeadingIDs = [intro.id, "heading-5"]
        XCTAssertEqual(book.skippedHeadings, [SkippedHeading(intro)])
        XCTAssertEqual(book.skippedHeadingIDs, [intro.id, "heading-5"], "the IDs as the reader saved them")

        book.skippedHeadingIDs = nil
        XCTAssertNil(book.skippedHeadings)

        let json = String(decoding: try JSONEncoder().encode(anchoredBook()), as: UTF8.self)
        XCTAssertTrue(json.contains("\"skippedHeadingIDs\""))
        XCTAssertTrue(json.contains("\"skippedHeadings\""))

        // A book made with skipped headings out of step with its IDs takes
        // the IDs' (as one an older build changed would be read), keeping the
        // anchor of each still named.
        let outOfStep = Book(
            title: "Out of Step", format: .txt, filePath: "/library/out.txt", md5Hash: "hash",
            skippedHeadingIDs: [intro.id, skippedNotes.id],
            skippedHeadings: [skippedNotes, SkippedHeading(level: 1, label: "Gone", chapterIndex: 9, characterOffset: 9)]
        )
        XCTAssertEqual(outOfStep.skippedHeadings, [SkippedHeading(intro), skippedNotes])

        // A record keeps them in step the same way.
        var state = BookState(skippedHeadingIDs: [skippedNotes.id], skippedHeadings: [skippedNotes])
        state.skippedHeadingIDs = [intro.id]
        XCTAssertEqual(state.skippedHeadings, [SkippedHeading(intro)])
    }

    /// What the reader saves since T06's branch B is the skipped headings
    /// themselves, each with its anchor, and the IDs are written from them:
    /// in their order, replacing any ID in no heading's form, with each
    /// heading's own anchor, never one kept from before; none, or nil, skips
    /// nothing and writes neither. The record takes both, in step.
    func testSavedSkippedHeadingsWriteTheirIDs() throws {
        var book = anchoredBook()
        book.skippedHeadingIDs = [skippedNotes.id, "heading-5"]
        let intro = SkippedHeading(
            Heading(level: 1, text: "Introduction", chapterIndex: 0, characterOffset: 0),
            anchor: TextAnchor(before: "", after: "Introduction", fraction: 0, measuredIn: "3.0.7/1.0.0")
        )
        var renewed = skippedNotes
        renewed.anchor = TextAnchor(before: "a new spanner ", after: "without looking up", fraction: 0.3)

        book.setSkippedHeadings([intro, renewed])

        XCTAssertEqual(book.skippedHeadings, [intro, renewed])
        XCTAssertEqual(book.skippedHeadingIDs, [intro.id, renewed.id])
        let record = try roundTrip(book.makeBookInfo())
        XCTAssertEqual(record.state.skippedHeadings, [intro, renewed])
        XCTAssertEqual(record.state.skippedHeadingIDs, [intro.id, renewed.id])
        XCTAssertEqual(try roundTrip(book).skippedHeadings, [intro, renewed], "the row lost them")

        book.setSkippedHeadings([])
        XCTAssertNil(book.skippedHeadings)
        XCTAssertNil(book.skippedHeadingIDs)
        book.setSkippedHeadings([intro])
        book.setSkippedHeadings(nil)
        XCTAssertNil(book.skippedHeadings)
        XCTAssertNil(book.skippedHeadingIDs)
    }
}
