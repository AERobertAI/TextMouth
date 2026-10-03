import XCTest
import ZIPFoundation
@testable import TextMouth

final class AudioZIPClassificationTests: XCTestCase {
    func testZIPContainingOnlyAudioAndManifestIsClassifiedAsAudio() throws {
        let zip = try makeZIP(entries: [
            "track1.mp3": "first",
            "track2.m4a": "second",
            "manifest.json": "{}"
        ])
        defer { try? FileManager.default.removeItem(at: zip) }

        XCTAssertTrue(LibraryViewModel.isAudioZip(url: zip))
    }

    func testZIPMixingAudioAndReadableBookContentIsNotClassifiedAsAudio() throws {
        let zip = try makeZIP(entries: [
            "track1.mp3": "audio",
            "book.epub": "not an epub, but still a supported content extension"
        ])
        defer { try? FileManager.default.removeItem(at: zip) }

        XCTAssertFalse(LibraryViewModel.isAudioZip(url: zip))
    }

    func testAudioZIPWithMacOSMetadataIsNotMisclassifiedAsDAISY() throws {
        // Finder-created archives can contain AppleDouble metadata alongside
        // audio tracks. This mirrors the structure that exposed the import
        // regression without depending on a developer-local test fixture.
        let zip = try makeZIP(entries: [
            "Episode 01.mp3": "first",
            "Episode 02.mp3": "second",
            "__MACOSX/._Episode 02.mp3": "apple-double metadata"
        ])
        defer { try? FileManager.default.removeItem(at: zip) }

        // ZIP routing checks DAISY before audio, so both classifications are
        // asserted to protect the complete decision made by the importer.
        XCTAssertFalse(DAISYParser.isDAISYZip(url: zip))
        XCTAssertTrue(LibraryViewModel.isAudioZip(url: zip))
    }

    func testZIPWithUnrelatedXMLIsNotClassifiedAsDAISY() throws {
        // Standalone DTBook XML is a valid DAISY fallback, but arbitrary XML
        // must not make an otherwise ordinary archive look like DAISY 3.
        let zip = try makeZIP(entries: [
            "metadata.xml": "<metadata><title>Ordinary archive</title></metadata>"
        ])
        defer { try? FileManager.default.removeItem(at: zip) }

        XCTAssertFalse(DAISYParser.isDAISYZip(url: zip))
    }

    /// A file that cannot be opened as a ZIP archive, whether it holds
    /// something else or is not there at all, is never an audio archive:
    /// the check answers false rather than failing (TODO Q06 pins this
    /// before the archive is opened through another initializer).
    func testFileThatCannotBeOpenedAsAnArchiveIsNotAnAudioArchive() throws {
        let folder = try makeSandboxDirectory("audio-classification")
        let notAnArchive = folder.appendingPathComponent("Episode 01.zip")
        try Data("plain text, not a ZIP archive".utf8).write(to: notAnArchive)

        XCTAssertFalse(LibraryViewModel.isAudioZip(url: notAnArchive))
        XCTAssertFalse(LibraryViewModel.isAudioZip(url: folder.appendingPathComponent("Missing.zip")))
    }

    private func makeZIP(entries: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextMouthAudioClassification-\(UUID().uuidString).zip")
        let archive = try Archive(url: url, accessMode: .create)
        for (path, contents) in entries {
            let data = Data(contents.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, size in
                    let start = Int(position)
                    let end = min(start + size, data.count)
                    return data[start..<end]
                }
            )
        }
        return url
    }
}
