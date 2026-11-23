import XCTest
@testable import TextMouth

/// Three places show or store the name of an enum case, and write that name
/// out instead of reading it by reflection (`String(describing:)`,
/// `"\(value)"`): the audio editor's log line, the capture error's log text, and
/// the iPhone import question's choice ID. These tests pin each text, so the
/// text stays the same if the way it is made changes (the Release build could
/// drop case names from reflection, `SWIFT_REFLECTION_METADATA_LEVEL =
/// without-names`, which `Scripts/size_settings.py` does not set). They are in
/// `Scripts/test/release-goldens.sh`'s classes, so they also run against the
/// optimizer's output.
final class ReflectionNamesTests: XCTestCase {

    /// Every audio edit error names itself in the debug log by its case
    /// alone, never its payload (a file's name or path).
    @MainActor
    func testAudioEditErrorsAreLoggedByCaseName() {
        let cases: [(AudioEditError, String)] = [
            (.bookNotInLibrary, "bookNotInLibrary"),
            (.fileOutsidePackage, "fileOutsidePackage"),
            (.unreadableAudio, "unreadableAudio"),
            (.missingAudio("A Private Name.wav"), "missingAudio"),
            (.historyInCloud, "historyInCloud"),
            (.historyFromNewerVersion(9), "historyFromNewerVersion"),
            (.historyUnusable("reason"), "historyUnusable"),
            (.invalidEdit("reason"), "invalidEdit"),
            (.processingUnavailable, "processingUnavailable"),
            (.bookIsOpen, "bookIsOpen"),
            (.audioInCloud, "audioInCloud"),
            (.originalNeeded, "originalNeeded"),
            (.renderFailed("reason"), "renderFailed"),
            (.mp3NeedsFFmpeg, "mp3NeedsFFmpeg"),
        ]
        for (error, name) in cases {
            XCTAssertEqual(AudioEditorLauncher.describe(error), name)
        }
    }

    /// A capture error reads as Swift's own description of the case did: its
    /// name, then its words in quotes.
    func testCaptureErrorsReadAsTheirCaseAndWords() {
        XCTAssertEqual("\(RecordingCaptureError.deviceUnavailable)", "deviceUnavailable")
        XCTAssertEqual("\(RecordingCaptureError.setupFailed("no input"))", "setupFailed(\"no input\")")
        XCTAssertEqual("\(RecordingCaptureError.didNotStart("a \"b\""))", "didNotStart(\"a \\\"b\\\"\")")
        XCTAssertEqual("\(RecordingCaptureError.didNotFinish(""))", "didNotFinish(\"\")")
    }

    /// The iPhone's import question tells its choices apart by an ID built
    /// from the action's name: each is its own, and none is the type's name.
    func testImportQuestionChoicesKeepTheirOwnIDs() throws {
        let duplicate = ImportDecision.DuplicateBook(
            book: Book(title: "Dune", format: .epub, filePath: "/tmp/Dune.epub", md5Hash: "hash"),
            existing: Book(title: "Dune", format: .epub, filePath: "/tmp/Dune.epub", md5Hash: "hash"),
            originalURL: nil,
            warning: nil
        )
        let decision = ImportDecision(kind: .duplicate(duplicate), request: ImportRequest())
        let wording = ImportDecisionWording(for: decision, position: 1, total: 1, movesToTrash: false)
        let question = try XCTUnwrap(PhoneImportQuestion(decision: decision, wording: wording))
        XCTAssertEqual(question.choices.map(\.id), ["keepBoth", "replaceExisting", "cancel"])
    }
}
