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
