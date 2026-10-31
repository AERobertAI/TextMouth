import XCTest
import ZIPFoundation
@testable import TextMouth

/// The DAISY audio books some checkouts keep in TestData, read by
/// TextMouth's own code: the check the library makes for audio before it
/// imports a DAISY ZIP as an audiobook, and the SMIL parser on a real
/// book's synchronization files.
///
/// Git ignores the books, so a linked worktree finds them in the main
/// checkout's TestData (`optionalTestDataArchive(_:)`), and each test skips,
/// saying why, only when no checkout keeps its book. These were legacy
/// scenarios in DAISYAudioTests.swift that returned before asserting
/// anything where a book was missing, and so passed in every worktree.
@MainActor
final class DAISYAudioFixtureTests: XCTestCase {

    // MARK: - Finding the Audio

    /// Fire Safety, a DAISY 2.02 book read by a person, holds audio by the
    /// check the library makes before it imports a DAISY ZIP as an
    /// audiobook.
    func testFireSafetyIsFoundToHoldAudio() throws {
        let found = try hasAudio(TranscriptionFixtureTests.fireSafety)

        XCTAssertTrue(found, "Fire Safety, a DAISY 2.02 book, was not found to hold audio")
    }

    /// Are You Ready, a DAISY 3 book read by a synthetic voice, holds audio
    /// by the same check.
    func testAreYouReadyIsFoundToHoldAudio() throws {
        let found = try hasAudio(TranscriptionFixtureTests.areYouReady)

        XCTAssertTrue(found, "Are You Ready, a DAISY 3 book, was not found to hold audio")
    }

    // MARK: - A Real Book's SMIL Files

    /// Fire Safety's SMIL files hold audio clips as the app's SMIL parser
    /// reads them: the first that holds any, in the archive's order, starts
    /// with the book's first recording, its title heading read aloud, in a
    /// first clip from 0 to 3.578 seconds.
    func testFireSafetysSMILFilesHoldAudioClips() throws {
        let archive = try Archive(url: try optionalTestDataArchive(TranscriptionFixtureTests.fireSafety), accessMode: .read)
        let provider = ArchiveFileProvider(archive: archive)
        var firstClip: DAISYAudioClip?
        for path in provider.listFiles() where path.lowercased().hasSuffix(".smil") {
            firstClip = try parseDAISYAudioSMIL(String(decoding: try provider.readFile(at: path), as: UTF8.self)).first
            if firstClip != nil { break }
        }

        let clip = try XCTUnwrap(firstClip, "no SMIL file in Fire Safety holds an audio clip")
        XCTAssertEqual(clip.file, "01_Fire_Safety__by_Wendy_Blaxland.mp3")
        XCTAssertEqual(clip.startTime, 0, accuracy: Self.millisecond / 2)
        XCTAssertEqual(clip.endTime, 3.578, accuracy: Self.millisecond / 2)
    }

    /// A millisecond, in seconds: the finest time a DAISY book's SMIL files
    /// give a clip.
    static let millisecond: TimeInterval = 0.001

    // MARK: - Helpers

    /// Whether the TestData book `name` holds audio by the library's own
    /// check, `DAISYAudioConverter.hasAudio(in:)`. Skips the test when no
    /// checkout keeps the book.
    private func hasAudio(_ name: String) throws -> Bool {
        let archive = try Archive(url: try optionalTestDataArchive(name), accessMode: .read)
        return DAISYAudioConverter.hasAudio(in: ArchiveFileProvider(archive: archive))
    }
}
