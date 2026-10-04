import AVFoundation
import XCTest
@testable import TextMouth

/// The audio edit list, the version control of a book's audio (FR04): edits
/// recorded in order and undone and redone by a cursor, a new edit after an
/// undo discarding the undone tail; what the book's audio holds as last
/// rendered; undo stopping where the audio the edits start from already
/// holds them once the original is gone; edits.json written, read back,
/// preserved when damaged, and left alone when newer or only in the cloud;
/// a recording's take recorded by its origin record until its first edit;
/// and the originals and takes the package keeps.
final class AudioEditListTests: XCTestCase {

    /// When the edits in these tests were made.
    private static let start = Date(timeIntervalSince1970: 1_791_000_000)

    /// A moment `seconds` after `start`.
    private func moment(_ seconds: TimeInterval) -> Date {
        Self.start.addingTimeInterval(seconds)
    }

    // MARK: - Edits in edits.json

    /// Every kind of edit reads back from JSON exactly as it was written.
    func testEveryEditRoundTripsThroughJSON() throws {
        let take = AudioEditTake(file: "audioEdits/takes/A.caf", range: AudioTimeRange(start: 0.25, end: 2))
        let edits: [AudioEdit] = [
            .trimStart(to: 1.5),
            .trimEnd(at: 590),
            .cut(AudioTimeRange(start: 5, end: 7)),
            .move(AudioTimeRange(start: 10, end: 12), to: 2),
            .insertSilence(at: 3, duration: 1),
            .replace(AudioTimeRange(start: 4, end: 6), with: take),
            .setChapter(at: 120, title: "Part Two: The Ferry"),
            .removeChapter(at: 120),
            .filter(chain: "highpass=f=80,volume=3dB", range: AudioTimeRange(start: 0, end: 10)),
            .filter(chain: "loudnorm=I=-16", range: nil),
            .gain(decibels: -3, range: AudioTimeRange(start: 1, end: 2)),
            .gain(decibels: 6, range: nil),
        ]
        let data = try JSONEncoder().encode(edits)
        XCTAssertEqual(try JSONDecoder().decode([AudioEdit].self, from: data), edits)
    }

    /// An edit is one object naming its kind, with only the fields its kind
    /// uses; a filter over the whole file has no range at all.
    func testAnEditIsWrittenAsItsKindAndFields() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            String(decoding: try encoder.encode(AudioEdit.cut(AudioTimeRange(start: 5, end: 7))), as: UTF8.self),
            #"{"end":7,"kind":"cut","start":5}"#
        )
        XCTAssertEqual(
            String(decoding: try encoder.encode(AudioEdit.filter(chain: "areverse", range: nil)), as: UTF8.self),
            #"{"chain":"areverse","kind":"filter"}"#
        )
    }

    /// A kind this version does not know is refused, never guessed at.
    func testAnUnknownKindIsRefused() {
        XCTAssertThrowsError(try JSONDecoder().decode(AudioEdit.self, from: Data(#"{"kind":"warp","at":3}"#.utf8)))
    }

    // MARK: - Undo and Redo

    /// The cursor counts the applied edits: undo moves it back, redo forward,
    /// and the applied edits are the ones before it, oldest first.
    func testEditsAreAppliedInOrderAndUndoneAndRedoneByTheCursor() {
        var list = AudioEditList(audioFile: "Ferry.m4a", original: AudioOriginal(file: "original-take.caf", lastEditedAt: Self.start))
        let cut = list.record(.cut(AudioTimeRange(start: 5, end: 7)), at: moment(1))
        let silence = list.record(.insertSilence(at: 3, duration: 1), at: moment(2))

        XCTAssertEqual(list.cursor, 2)
        XCTAssertEqual(list.appliedEntries.map(\.id), [cut.id, silence.id])
        XCTAssertTrue(list.canUndo)
        XCTAssertFalse(list.canRedo)
        XCTAssertEqual(list.nextUndo, silence)

        XCTAssertEqual(list.undo(at: moment(3)), silence)
        XCTAssertEqual(list.appliedEntries.map(\.id), [cut.id])
        XCTAssertEqual(list.nextRedo, silence)
        XCTAssertEqual(list.undo(at: moment(4)), cut)
        XCTAssertEqual(list.cursor, 0)
        XCTAssertFalse(list.canUndo)
        XCTAssertEqual(list.undoLimit, .nothingToUndo)

        XCTAssertEqual(list.redo(at: moment(5)), cut)
        XCTAssertEqual(list.redo(at: moment(6)), silence)
        XCTAssertEqual(list.entries.count, 2)
        XCTAssertEqual(list.cursor, 2)
    }

    /// A new edit after an undo discards the undone edits: they can no
    /// longer be redone.
    func testANewEditAfterAnUndoDiscardsTheUndoneTail() {
        var list = AudioEditList(audioFile: "Ferry.m4a", original: AudioOriginal(file: "original-take.caf", lastEditedAt: Self.start))
        let first = list.record(.cut(AudioTimeRange(start: 1, end: 2)), at: moment(1))
        list.record(.cut(AudioTimeRange(start: 3, end: 4)), at: moment(2))
        list.record(.cut(AudioTimeRange(start: 5, end: 6)), at: moment(3))
        list.undo(at: moment(4))
        list.undo(at: moment(5))

        let replacement = list.record(.trimEnd(at: 30), at: moment(6))

        XCTAssertEqual(list.entries.map(\.id), [first.id, replacement.id])
        XCTAssertEqual(list.cursor, 2)
        XCTAssertFalse(list.canRedo)
    }

    /// Undo with nothing to undo, and redo with nothing undone, change
    /// nothing.
    func testUndoAndRedoChangeNothingAtTheirEnds() {
        var list = AudioEditList(audioFile: "Ferry.m4a")
        let before = list
        XCTAssertNil(list.undo(at: moment(1)))
        XCTAssertNil(list.redo(at: moment(1)))
        XCTAssertEqual(list, before)
    }

    /// The policy's days count from the last change: every edit, undo, redo,
    /// and render counts the original as edited.
    func testEachChangeCountsTheOriginalAsEdited() throws {
        var list = AudioEditList(audioFile: "Ferry.m4a", original: AudioOriginal(file: "original-take.caf", lastEditedAt: Self.start))
        let edit = list.record(.cut(AudioTimeRange(start: 1, end: 2)), at: moment(10))
        XCTAssertEqual(list.original?.lastEditedAt, moment(10))
        list.undo(at: moment(20))
        XCTAssertEqual(list.original?.lastEditedAt, moment(20))
        list.redo(at: moment(30))
        XCTAssertEqual(list.original?.lastEditedAt, moment(30))
        list.markRendered(entryIDs: [edit.id], at: moment(40))
        XCTAssertEqual(list.original?.lastEditedAt, moment(40))
        XCTAssertEqual(list.entries.first?.madeAt, moment(10), "an entry keeps the time it was made")
    }

    // MARK: - The Rendered State

    /// Before any render the book's audio is the original; a render of the
    /// applied edits leaves nothing to render, until the next edit.
    func testARenderOfTheAppliedEditsLeavesNothingToRender() {
        var list = AudioEditList(audioFile: "Ferry.m4a", original: AudioOriginal(file: "original-take.caf", lastEditedAt: Self.start))
        XCTAssertTrue(list.isRendered, "the untouched file is the original")
        let cut = list.record(.cut(AudioTimeRange(start: 1, end: 2)), at: moment(1))
        XCTAssertFalse(list.isRendered)

        XCTAssertTrue(list.markRendered(entryIDs: [cut.id], at: moment(2)))
        XCTAssertTrue(list.isRendered)
        XCTAssertEqual(list.renderedCursor, 1)
        XCTAssertEqual(list.lastRenderedAt, moment(2))

        list.undo(at: moment(3))
        XCTAssertFalse(list.isRendered, "an undo past the render is a change to render")
    }

    /// Discarding undone edits the book's audio holds leaves that audio
    /// holding edits the list no longer has.
    func testDiscardingRenderedEditsLeavesTheAudioHoldingEditsNoLongerListed() {
        var list = AudioEditList(audioFile: "Ferry.m4a", original: AudioOriginal(file: "original-take.caf", lastEditedAt: Self.start))
        let first = list.record(.cut(AudioTimeRange(start: 1, end: 2)), at: moment(1))
        let second = list.record(.cut(AudioTimeRange(start: 3, end: 4)), at: moment(2))
        list.markRendered(entryIDs: [first.id, second.id], at: moment(3))
        list.undo(at: moment(4))

        list.record(.insertSilence(at: 1, duration: 1), at: moment(5))

        XCTAssertNil(list.renderedCursor)
        XCTAssertFalse(list.isRendered)
        XCTAssertFalse(list.canForgetOriginal, "only the original can make the list's state again")
    }

    /// A render made from edits the list has since replaced is not taken
    /// for the list's own: the file holds edits it no longer has.
    func testARenderOfEditsTheListNoLongerHoldsIsNotTakenForTheList() {
        var list = AudioEditList(audioFile: "Ferry.m4a", original: AudioOriginal(file: "original-take.caf", lastEditedAt: Self.start))
        let first = list.record(.cut(AudioTimeRange(start: 1, end: 2)), at: moment(1))
        list.undo(at: moment(2))
        list.record(.cut(AudioTimeRange(start: 8, end: 9)), at: moment(3))

        XCTAssertFalse(list.markRendered(entryIDs: [first.id], at: moment(4)))
        XCTAssertNil(list.renderedCursor)
    }

    // MARK: - Without the Original

    /// Once the original is gone, the edits start from the rendered audio:
    /// edits since the render can be undone, the rendered ones stay in the
    /// list for reference but cannot, and the model says why.
    func testWithoutTheOriginalUndoStopsAtTheRenderedAudio() {
        var list = AudioEditList(audioFile: "Ferry.m4a", original: AudioOriginal(file: "original-take.caf", lastEditedAt: Self.start))
        let first = list.record(.cut(AudioTimeRange(start: 1, end: 2)), at: moment(1))
        let second = list.record(.cut(AudioTimeRange(start: 3, end: 4)), at: moment(2))
        list.markRendered(entryIDs: [first.id, second.id], at: moment(3))

        XCTAssertTrue(list.forgetOriginal(at: moment(4)))
        XCTAssertNil(list.original)
        XCTAssertEqual(list.originalDeletedAt, moment(4))
        XCTAssertEqual(list.baseCursor, 2)
        XCTAssertFalse(list.canUndo)
        XCTAssertEqual(list.undoLimit, .originalDeleted(moment(4)))
        XCTAssertEqual(list.entries.count, 2, "the rendered edits are kept for reference")

        let third = list.record(.trimEnd(at: 40), at: moment(5))
        XCTAssertTrue(list.canUndo, "an edit since the render can still be undone")
        XCTAssertEqual(list.entriesOverBase.map(\.id), [third.id])
        list.undo(at: moment(6))
        XCTAssertFalse(list.canUndo)
        XCTAssertTrue(list.canRedo)
    }

    /// The original is forgotten only while the book's audio holds exactly
    /// the applied edits: an edit not yet rendered, or an undo past the
    /// render, could only be made again from it.
    func testTheOriginalIsForgottenOnlyWhenTheAudioHoldsTheAppliedEdits() {
        var list = AudioEditList(audioFile: "Ferry.m4a", original: AudioOriginal(file: "original-take.caf", lastEditedAt: Self.start))
        let cut = list.record(.cut(AudioTimeRange(start: 1, end: 2)), at: moment(1))
        XCTAssertFalse(list.forgetOriginal(at: moment(2)), "an edit not rendered yet")
        list.markRendered(entryIDs: [cut.id], at: moment(3))
        list.undo(at: moment(4))
        XCTAssertFalse(list.forgetOriginal(at: moment(5)), "an undo past the render")
        XCTAssertNotNil(list.original)
        list.redo(at: moment(6))
        XCTAssertTrue(list.forgetOriginal(at: moment(7)))
    }

    /// Editing in place, with no original ever kept, undoes only what has
    /// not been rendered yet.
    func testEditingInPlaceUndoesOnlyWhatIsNotRendered() {
        var list = AudioEditList(audioFile: "Ferry.m4a")
        let cut = list.record(.cut(AudioTimeRange(start: 1, end: 2)), at: moment(1))
        XCTAssertTrue(list.canUndo)
        list.markRendered(entryIDs: [cut.id], at: moment(2))
        XCTAssertFalse(list.canUndo)
        XCTAssertEqual(list.undoLimit, .editedInPlace)
        XCTAssertEqual(
            AudioEditWording.undoLimit(.editedInPlace),
            "No original audio is kept for this book, so saved edits can't be undone."
        )
    }

    // MARK: - Damage

    /// A cursor outside the list's entries is damage, never repaired: a
    /// wrong cursor would apply edits the user undid.
    func testACursorOutsideTheEntriesIsDamage() {
        let json = #"{"audioFile":"Ferry.m4a","entries":[],"cursor":2,"renderedCursor":0}"#
        XCTAssertThrowsError(try JSONDecoder().decode(AudioEditList.self, from: Data(json.utf8)))
        let rendered = #"{"audioFile":"Ferry.m4a","entries":[],"cursor":0,"renderedCursor":5}"#
        XCTAssertThrowsError(try JSONDecoder().decode(AudioEditList.self, from: Data(rendered.utf8)))
    }

    // MARK: - Takes

    /// The takes in use are those of every edit that can still be applied,
    /// undone ones included, but not of edits the audio the edits start
    /// from already holds.
    func testTakesInUseAreThoseOfEditsThatCanStillApply() {
        func punchIn(_ name: String) -> AudioEdit {
            .replace(AudioTimeRange(start: 1, end: 2), with: AudioEditTake(file: name, range: AudioTimeRange(start: 0, end: 1)))
        }
        var list = AudioEditList(audioFile: "Ferry.m4a", original: AudioOriginal(file: "original-take.caf", lastEditedAt: Self.start))
        let first = list.record(punchIn("takes/one.caf"), at: moment(1))
        list.record(punchIn("takes/two.caf"), at: moment(2))
        list.undo(at: moment(3))
        XCTAssertEqual(list.takesInUse, ["takes/one.caf", "takes/two.caf"])

        list.markRendered(entryIDs: [first.id], at: moment(4))
        list.forgetOriginal(at: moment(5))
        XCTAssertEqual(list.takesInUse, ["takes/two.caf"], "the rendered audio holds the first take")
    }

    // MARK: - The History File

    /// A history is written as edits.json in the package's audioEdits folder
    /// and reads back exactly, with the book's own policy.
    func testAHistoryIsWrittenAndReadBackAsEditsJSON() throws {
        let package = try makePackage()
        var list = AudioEditList(audioFile: "Ferry.m4b")
        list.record(.setChapter(at: 60, title: "Crossing"), at: moment(1))
        let history = AudioEditHistory(policyOverride: .deleteAfter(days: 3), files: [list])

        try AudioEditHistoryStore.write(history, source: .noRecord, toPackage: package, bookFile: "Ferry.m4b")

        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("audioEdits/edits.json").path))
        XCTAssertEqual(
            AudioEditHistoryStore.read(fromPackage: package, bookFile: "Ferry.m4b"),
            .found(history, .editsFile)
        )
        let text = try String(contentsOf: AudioEditPackage.historyURL(in: package), encoding: .utf8)
        XCTAssertTrue(text.contains(#""version" : 1"#), text)
    }

    /// A package never edited has an empty history, and no file is made for
    /// it by reading.
    func testAPackageWithoutAHistoryHasAnEmptyOne() throws {
        let package = try makePackage()
        XCTAssertEqual(AudioEditHistoryStore.read(fromPackage: package, bookFile: "Ferry.m4b"), .found(AudioEditHistory(), .noRecord))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AudioEditPackage.folder(in: package).path))
    }

    /// A damaged history is preserved beside itself and reported unusable,
    /// and a change refuses to replace it unless asked to start over.
    func testADamagedHistoryIsPreservedAndReportedUnusable() throws {
        let package = try makePackage()
        let url = AudioEditPackage.historyURL(in: package)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"files":[{"audioFile":"Ferry.m4b""#.utf8).write(to: url)

        guard case .unusable = AudioEditHistoryStore.read(fromPackage: package, bookFile: "Ferry.m4b") else {
            return XCTFail("a damaged history was read")
        }
        let copies = LibraryIndexQuarantine.existingCopies(of: url)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(copies.first)), try Data(contentsOf: url))

        XCTAssertThrowsError(try AudioEditHistoryStore.update(package: package, bookFile: "Ferry.m4b") { _ in }) { error in
            guard case AudioEditError.historyUnusable = error else { return XCTFail("\(error)") }
        }
        try AudioEditHistoryStore.update(package: package, bookFile: "Ferry.m4b", startingOver: true) { history in
            history.setList(AudioEditList(audioFile: "Ferry.m4b"))
        }
        guard case .found(let fresh, .editsFile) = AudioEditHistoryStore.read(fromPackage: package, bookFile: "Ferry.m4b") else {
            return XCTFail("the history was not started over")
        }
        XCTAssertEqual(fresh.files.map(\.audioFile), ["Ferry.m4b"])
        XCTAssertEqual(LibraryIndexQuarantine.existingCopies(of: url).count, 1, "the damaged copy stays")
    }

    /// A history a later TextMouth wrote is left exactly as it is: not read,
    /// not preserved, not replaced.
    func testAHistoryFromANewerVersionIsLeftAlone() throws {
        let package = try makePackage()
        let url = AudioEditPackage.historyURL(in: package)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let newer = Data(#"{"version":2,"lanes":[]}"#.utf8)
        try newer.write(to: url)

        XCTAssertEqual(AudioEditHistoryStore.read(fromPackage: package, bookFile: "Ferry.m4b"), .unsupportedVersion(2))
        XCTAssertThrowsError(try AudioEditHistoryStore.update(package: package, bookFile: "Ferry.m4b") { history in
            history.policyOverride = .keep
        }) { error in
            XCTAssertEqual(error as? AudioEditError, .historyFromNewerVersion(2))
        }
        XCTAssertEqual(try Data(contentsOf: url), newer)
        XCTAssertTrue(LibraryIndexQuarantine.existingCopies(of: url).isEmpty)
    }

    /// A history only in the cloud, or the origin record standing for one,
    /// is never read, so it is never downloaded.
    func testAHistoryOnlyInTheCloudIsNotRead() throws {
        let package = try makePackage()
        let refusal = NSError(domain: NSPOSIXErrorDomain, code: Int(EDEADLK))
        XCTAssertEqual(
            AudioEditHistoryStore.read(fromPackage: package, bookFile: "Ferry.m4b", using: { _ in throw refusal }),
            .inCloud
        )
        XCTAssertEqual(
            AudioEditHistoryStore.read(fromPackage: package, bookFile: "Ferry.m4b", loadOrigin: { _ in throw refusal }),
            .inCloud
        )
        XCTAssertThrowsError(try AudioEditHistoryStore.update(
            package: package,
            bookFile: "Ferry.m4b",
            using: { _ in throw refusal }
        ) { _ in }) { error in
            XCTAssertEqual(error as? AudioEditError, .historyInCloud)
        }
    }

    /// A change that changes nothing writes nothing.
    func testAnUnchangedHistoryIsNotWritten() throws {
        let package = try makePackage()
        try AudioEditHistoryStore.update(package: package, bookFile: "Ferry.m4b") { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: AudioEditPackage.historyURL(in: package).path))
    }

    // MARK: - A Recording's Take

    /// A recording never edited has its take, as its origin record holds
    /// it, as the original of its file, under the record's own policy.
    func testARecordingsTakeIsTheOriginalOfItsFile() throws {
        let package = try makePackage(recording: true, takePolicy: .keep)

        guard case .found(let history, .recordingOrigin) = AudioEditHistoryStore.read(fromPackage: package, bookFile: "Ferry.m4a") else {
            return XCTFail("the take was not found")
        }
        XCTAssertEqual(history.policyOverride, .keep)
        XCTAssertEqual(
            history.list(for: "Ferry.m4a")?.original,
            AudioOriginal(file: BookOrigin.originalTakeFileName, lastEditedAt: Self.start)
        )
    }

    /// Until the recording is edited, its origin record keeps describing the
    /// take: a change of its policy or its date goes there, and no edits.json
    /// is made.
    func testARecordingKeepsItsTakeInItsOriginRecordUntilItIsEdited() throws {
        let package = try makePackage(recording: true)

        try AudioEditHistoryStore.update(package: package, bookFile: "Ferry.m4a") { history in
            history.policyOverride = .deleteAfter(days: 9)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: AudioEditPackage.historyURL(in: package).path))
        let take = try XCTUnwrap(try BookOrigin.load(fromPackage: package)?.originalTake)
        XCTAssertEqual(take.policyOverride, .deleteAfter(days: 9))
        XCTAssertEqual(take.fileName, BookOrigin.originalTakeFileName)
    }

    /// The first edit moves the take's record into edits.json, and the origin
    /// record no longer describes it, so one record describes it at a time.
    func testTheFirstEditMovesTheTakesRecordIntoTheHistory() throws {
        let package = try makePackage(recording: true, takePolicy: .keep)

        try AudioEditHistoryStore.update(package: package, bookFile: "Ferry.m4a") { history in
            var list = history.listOrNew(for: "Ferry.m4a")
            list.record(.cut(AudioTimeRange(start: 1, end: 2)), at: self.moment(60))
            history.setList(list)
        }

        let origin = try XCTUnwrap(try BookOrigin.load(fromPackage: package))
        XCTAssertNil(origin.originalTake)
        XCTAssertEqual(origin.kind, .recording, "the rest of the origin record stays")
        guard case .found(let history, .editsFile) = AudioEditHistoryStore.read(fromPackage: package, bookFile: "Ferry.m4a") else {
            return XCTFail("edits.json was not written")
        }
        XCTAssertEqual(history.policyOverride, .keep)
        XCTAssertEqual(history.list(for: "Ferry.m4a")?.original?.file, BookOrigin.originalTakeFileName)
        XCTAssertEqual(history.list(for: "Ferry.m4a")?.original?.lastEditedAt, moment(60))
    }

    // MARK: - Files in the Package

    /// The history's folder is never taken for the book itself: a package
    /// whose record is lost still finds its one book file beside it.
    func testTheEditFolderIsNeverTakenForTheBook() throws {
        let package = try makePackage()
        try FileManager.default.removeItem(at: package.appendingPathComponent("audio"))
        try AudioEditHistoryStore.write(
            AudioEditHistory(files: [AudioEditList(audioFile: "Ferry.m4b")]),
            source: .noRecord,
            toPackage: package,
            bookFile: "Ferry.m4b"
        )
        XCTAssertFalse(FileImportService.isPackageContentName(AudioEditPackage.folderName))
        XCTAssertEqual(try FileImportService.retainedContentURL(in: package).lastPathComponent, "Ferry.m4b")
    }

    /// A path a history names is used only when it stays inside the package.
    func testPathsMustStayInsideThePackage() throws {
        let package = try makePackage()
        for path in ["original-take.caf", "audioEdits/originals/audio/Disc 2/03.mp3", "a.b/c"] {
            XCTAssertEqual(AudioEditPackage.url(of: path, in: package), package.appendingPathComponent(path), path)
        }
        for path in ["", "/etc/hosts", "../Other.tmb/book.m4a", "audioEdits/../../x", "a//b", "./a", "a/."] {
            XCTAssertNil(AudioEditPackage.url(of: path, in: package), path)
        }
        XCTAssertEqual(
            AudioEditPackage.path(of: package.appendingPathComponent("audio/Disc 2/03.mp3"), in: package),
            "audio/Disc 2/03.mp3"
        )
        XCTAssertNil(AudioEditPackage.path(of: package.deletingLastPathComponent().appendingPathComponent("x.m4a"), in: package))
    }

    /// An original is a copy of the file as it is, under the originals
    /// folder at the file's own path, and an earlier original whose record
    /// was lost is never overwritten.
    func testAnOriginalIsACopyThatNeverOverwritesAnother() throws {
        let package = try makePackage()
        let original = try AudioEditPackage.keepOriginal(ofAudioFile: "Ferry.m4b", inPackage: package, at: moment(1))
        XCTAssertEqual(original, AudioOriginal(file: "audioEdits/originals/Ferry.m4b", lastEditedAt: moment(1)))
        XCTAssertEqual(
            try Data(contentsOf: package.appendingPathComponent(original.file)),
            try Data(contentsOf: package.appendingPathComponent("Ferry.m4b"))
        )

        let second = try AudioEditPackage.keepOriginal(ofAudioFile: "Ferry.m4b", inPackage: package, at: moment(2))
        XCTAssertEqual(second.file, "audioEdits/originals/Ferry 2.m4b")

        let track = try AudioEditPackage.keepOriginal(ofAudioFile: "audio/Disc 2/03.mp3", inPackage: package, at: moment(3))
        XCTAssertEqual(track.file, "audioEdits/originals/audio/Disc 2/03.mp3")
        XCTAssertThrowsError(try AudioEditPackage.keepOriginal(ofAudioFile: "../Ferry.m4b", inPackage: package, at: moment(4)))
    }

    /// A take of 16-bit samples is kept as Apple Lossless, smaller and
    /// decoding to the very same samples.
    func testAnIntegerTakeIsKeptLosslesslyCompressed() throws {
        let package = try makePackage()
        let source = package.deletingLastPathComponent().appendingPathComponent("take.caf")
        try AudioTestFixtures.writeInt16Pattern(to: source, frames: 24_000)

        let path = try AudioEditPackage.keepTake(from: source, inPackage: package)

        XCTAssertTrue(path.hasPrefix("audioEdits/takes/"), path)
        XCTAssertTrue(path.hasSuffix(".caf"), path)
        let kept = package.appendingPathComponent(path)
        let format = AudioEditPackage.streamDescription(of: try AVAudioFile(forReading: kept).fileFormat)
        XCTAssertEqual(format.mFormatID, kAudioFormatAppleLossless)
        XCTAssertEqual(try AudioTestFixtures.int16Samples(of: kept), try AudioTestFixtures.int16Samples(of: source))
        let sizes = try [source, kept].map { try XCTUnwrap($0.resourceValues(forKeys: [.fileSizeKey]).fileSize) }
        XCTAssertLessThan(sizes[1], sizes[0])
    }

    /// A take of floating-point samples, which Apple Lossless cannot hold,
    /// is copied as it is.
    func testAFloatTakeIsKeptAsItIs() throws {
        let package = try makePackage()
        let source = package.deletingLastPathComponent().appendingPathComponent("take.wav")
        try AudioTestFixtures.writeIdentityRamp(to: source, frames: 8_000, source: .take)

        let path = try AudioEditPackage.keepTake(from: source, inPackage: package)

        XCTAssertTrue(path.hasSuffix(".wav"), path)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent(path)), try Data(contentsOf: source))
    }

    /// A change of the history deletes the takes no edit can use any more:
    /// here, one whose edit was discarded after an undo.
    func testUnusedTakesAreRemoved() throws {
        let package = try makePackage()
        let source = package.deletingLastPathComponent().appendingPathComponent("take.caf")
        try AudioTestFixtures.writeInt16Pattern(to: source, frames: 800)
        let kept = try AudioEditPackage.keepTake(from: source, inPackage: package)
        let discarded = try AudioEditPackage.keepTake(from: source, inPackage: package)
        let range = AudioTimeRange(start: 0, end: 0.1)

        try AudioEditHistoryStore.update(package: package, bookFile: "Ferry.m4b") { history in
            var list = history.listOrNew(for: "Ferry.m4b")
            list.record(.replace(range, with: AudioEditTake(file: kept, range: range)), at: self.moment(1))
            list.record(.replace(range, with: AudioEditTake(file: discarded, range: range)), at: self.moment(2))
            list.undo(at: self.moment(3))
            list.record(.trimEnd(at: 5), at: self.moment(4))
            history.setList(list)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent(kept).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent(discarded).path))
    }

    // MARK: - Wording

    /// Lengths keep tenths, and each edit has a name for the Edit menu.
    func testDurationsAndActionNames() {
        XCTAssertEqual(AudioEditWording.duration(2.5), "2.5 seconds")
        XCTAssertEqual(AudioEditWording.duration(1), "1 second")
        XCTAssertEqual(AudioEditWording.duration(0.04), "0.04 seconds")
        XCTAssertEqual(AudioEditWording.duration(64.2), "1 minute, 4.2 seconds")
        XCTAssertEqual(AudioEditWording.duration(3_600), "1 hour")
        XCTAssertEqual(AudioEditWording.duration(61, titleCase: true), "1 Minute, 1 Second")
        XCTAssertEqual(AudioEditWording.actionName(.cut(AudioTimeRange(start: 1, end: 3.5))), "Cut 2.5 Seconds")
        XCTAssertEqual(AudioEditWording.actionName(.insertSilence(at: 0, duration: 1)), "Insert 1 Second of Silence")
        XCTAssertEqual(AudioEditWording.actionName(.gain(decibels: -3, range: nil)), "Change Volume by -3 dB")
        XCTAssertEqual(AudioEditWording.actionName(.setChapter(at: 3, title: "One")), "Set Chapter Marker")
    }

    // MARK: - Helpers

    /// A book's package in a folder of this test's own, removed when the test
    /// ends: "Ferry.m4b" and a track "audio/Disc 2/03.mp3" whose bytes stand
    /// in for audio, and, for a `recording`, a recording's file "Ferry.m4a",
    /// its take, and an origin record holding the take, saved at `start`
    /// under the book's own `takePolicy` (nil follows the global policy).
    private func makePackage(recording: Bool = false, takePolicy: AudioOriginalPolicy? = nil) throws -> URL {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let package = folder.appendingPathComponent("Ferry-Unknown-1-\(UUID().uuidString.prefix(8)).tmb", isDirectory: true)
        try FileManager.default.createDirectory(
            at: package.appendingPathComponent("audio/Disc 2", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("book audio".utf8).write(to: package.appendingPathComponent("Ferry.m4b"))
        try Data("track audio".utf8).write(to: package.appendingPathComponent("audio/Disc 2/03.mp3"))
        if recording {
            try Data("recording".utf8).write(to: package.appendingPathComponent("Ferry.m4a"))
            try Data("take".utf8).write(to: package.appendingPathComponent(BookOrigin.originalTakeFileName))
            try BookOrigin(
                kind: .recording,
                recordedAt: Self.start.addingTimeInterval(-120),
                duration: 95,
                inputDeviceName: "MacBook Air Microphone",
                originalTake: BookOrigin.OriginalTake(
                    fileName: BookOrigin.originalTakeFileName,
                    lastEditedAt: Self.start,
                    policyOverride: takePolicy
                )
            ).save(toPackage: package)
        }
        return package
    }
}
