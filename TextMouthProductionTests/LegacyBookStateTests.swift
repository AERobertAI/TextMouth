import XCTest
@testable import TextMouth

/// Production-backed replacements for the legacy copied `BookState` tests.
final class LegacyBookStateTests: XCTestCase {
    /// Build a minimal production book while allowing state overrides per test.
    private func makeBook(
        localVoiceID: String? = nil,
        localWPM: Double? = nil,
        localPitch: Double? = nil,
        totalWordCount: Int? = nil,
        totalCharacterCount: Int? = nil
    ) -> Book {
        Book(
            title: "State Test",
            format: .txt,
            filePath: "/tmp/state-test.txt",
            md5Hash: "state-test",
            totalWordCount: totalWordCount,
            totalCharacterCount: totalCharacterCount,
            localVoiceID: localVoiceID,
            localWPM: localWPM,
            localPitch: localPitch
        )
    }

    /// Time-based skip units should scale with WPM and retain a one-word floor.
    func testSkipUnitWordCountsAtVariousSpeeds() {
        XCTAssertEqual(SkipUnit.seconds10.wordCount(wpm: 1), 1)
        XCTAssertEqual(SkipUnit.seconds15.wordCount(wpm: 200), 50)
        XCTAssertEqual(SkipUnit.seconds30.wordCount(wpm: 200), 100)
        XCTAssertEqual(SkipUnit.seconds60.wordCount(wpm: 200), 200)
    }

    /// Structural skip units navigate by model objects rather than word counts.
    func testStructuralSkipUnitsHaveNoWordCount() {
        XCTAssertNil(SkipUnit.heading.wordCount(wpm: 200))
        XCTAssertNil(SkipUnit.bookmark.wordCount(wpm: 200))
    }

    /// Format detection should reflect every extension currently supported by the app.
    func testBookFormatDetectionUsesProductionExtensions() {
        XCTAssertEqual(BookFormat.detect(from: URL(fileURLWithPath: "/tmp/book.EPUB")), .epub)
        XCTAssertEqual(BookFormat.detect(from: URL(fileURLWithPath: "/tmp/book.txt")), .txt)
        XCTAssertEqual(BookFormat.detect(from: URL(fileURLWithPath: "/tmp/book.markdown")), .markdown)
        XCTAssertEqual(BookFormat.detect(from: URL(fileURLWithPath: "/tmp/book.xhtml")), .html)
        XCTAssertEqual(BookFormat.detect(from: URL(fileURLWithPath: "/tmp/book.pdf")), .pdf)
        XCTAssertEqual(BookFormat.detect(from: URL(fileURLWithPath: "/tmp/book.docx")), .docx)
        // A Word 97-2003 document is read through textutil (FMT13), never as DOCX.
        XCTAssertEqual(BookFormat.detect(from: URL(fileURLWithPath: "/tmp/book.doc")), .doc)
    }

    /// Playback timestamps and computed counts should survive production state encoding.
    func testBookStateRoundTripsPlaybackTimestamps() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let state = BookState(
            totalWordCount: 1_000,
            totalCharacterCount: 5_000,
            isNew: false,
            tmbDirectoryName: "test.tmb",
            lastPlaybackStarted: now,
            lastPlaybackStopped: now.addingTimeInterval(300)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(BookState.self, from: encoder.encode(state))

        XCTAssertEqual(decoded.totalWordCount, 1_000)
        XCTAssertFalse(decoded.isNew)
        XCTAssertEqual(decoded.lastPlaybackStarted, now)
        XCTAssertEqual(decoded.lastPlaybackStopped, now.addingTimeInterval(300))
    }

    /// Optional playback fields must remain absent when loading older state JSON.
    func testBookStateDecodesWithoutPlaybackTimestamps() throws {
        let data = Data(#"{"isNew":true,"tmbDirectoryName":"old.tmb","totalWordCount":500}"#.utf8)
        let decoded = try JSONDecoder().decode(BookState.self, from: data)

        XCTAssertEqual(decoded.totalWordCount, 500)
        XCTAssertTrue(decoded.isNew)
        XCTAssertNil(decoded.lastPlaybackStarted)
        XCTAssertNil(decoded.lastPlaybackStopped)
    }

    /// Smart rewind should distinguish pauses below, at, and above its threshold.
    func testSmartRewindThresholdCalculation() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(ReaderViewModel.hasReachedSmartRewindThreshold(lastStoppedAt: now.addingTimeInterval(-30), now: now, threshold: 70))
        XCTAssertTrue(ReaderViewModel.hasReachedSmartRewindThreshold(lastStoppedAt: now.addingTimeInterval(-70), now: now, threshold: 70))
        XCTAssertTrue(ReaderViewModel.hasReachedSmartRewindThreshold(lastStoppedAt: now.addingTimeInterval(-120), now: now, threshold: 70))
    }

    /// Voice and speed overrides should survive production state encoding.
    func testBookStateRoundTripsLocalVoiceAndSpeed() throws {
        let state = BookState(localVoiceID: "voice.identifier", localWPM: 300)
        let decoded = try JSONDecoder().decode(BookState.self, from: JSONEncoder().encode(state))

        XCTAssertEqual(decoded.localVoiceID, "voice.identifier")
        XCTAssertEqual(decoded.localWPM, 300)
    }

    /// Older state JSON without voice fields should decode them as absent.
    func testBookStateDecodesWithoutLocalVoiceAndSpeed() throws {
        let data = Data(#"{"isNew":true,"tmbDirectoryName":"old.tmb"}"#.utf8)
        let decoded = try JSONDecoder().decode(BookState.self, from: data)

        XCTAssertNil(decoded.localVoiceID)
        XCTAssertNil(decoded.localWPM)
    }

    /// Per-book playback navigation defaults must survive package-state round trips.
    func testBookStateRoundTripsLocalSkipUnits() throws {
        let state = BookState(
            localSkipForwardUnit: SkipUnit.heading.rawValue,
            localSkipBackwardUnit: SkipUnit.sentence.rawValue
        )

        let decoded = try JSONDecoder().decode(
            BookState.self,
            from: JSONEncoder().encode(state)
        )

        XCTAssertEqual(decoded.localSkipForwardUnit, SkipUnit.heading.rawValue)
        XCTAssertEqual(decoded.localSkipBackwardUnit, SkipUnit.sentence.rawValue)
    }

    /// The library model must copy navigation defaults into package metadata,
    /// which is the durable source used when a managed book is adopted again.
    func testBookInfoIncludesLocalSkipUnits() {
        let book = Book(
            title: "Navigation State Test",
            format: .txt,
            filePath: "/tmp/navigation-state-test.txt",
            md5Hash: "navigation-state-test",
            localSkipForwardUnit: SkipUnit.heading.rawValue,
            localSkipBackwardUnit: SkipUnit.seconds30.rawValue
        )

        let info = book.makeBookInfo()

        XCTAssertEqual(info.state.localSkipForwardUnit, SkipUnit.heading.rawValue)
        XCTAssertEqual(info.state.localSkipBackwardUnit, SkipUnit.seconds30.rawValue)
    }

    /// Older package state has no navigation overrides and must keep using globals.
    func testBookStateDecodesWithoutLocalSkipUnits() throws {
        let data = Data(#"{"isNew":true,"tmbDirectoryName":"old.tmb"}"#.utf8)
        let decoded = try JSONDecoder().decode(BookState.self, from: data)

        XCTAssertNil(decoded.localSkipForwardUnit)
        XCTAssertNil(decoded.localSkipBackwardUnit)
    }

    /// Hidden menus always use the two global units, even when a book retains
    /// overrides that should become available again if menus are re-enabled.
    func testHiddenPlaybackNavigationMenusUseGlobalUnits() {
        let resolved = PlaybackSkipUnitPolicy.resolve(
            mode: .none,
            localForwardRawValue: SkipUnit.heading.rawValue,
            localBackwardRawValue: SkipUnit.paragraph.rawValue,
            globalForward: .seconds30,
            globalBackward: .seconds15
        )

        XCTAssertEqual(resolved.forward, .seconds30)
        XCTAssertEqual(resolved.backward, .seconds15)
    }

    /// Shared mode deliberately applies one per-book unit to both buttons.
    func testSharedPlaybackNavigationMenuUsesOneUnitForBothDirections() {
        let resolved = PlaybackSkipUnitPolicy.resolve(
            mode: .shared,
            localForwardRawValue: SkipUnit.bookmark.rawValue,
            localBackwardRawValue: SkipUnit.paragraph.rawValue,
            globalForward: .seconds15,
            globalBackward: .seconds30
        )

        XCTAssertEqual(resolved.forward, .bookmark)
        XCTAssertEqual(resolved.backward, .bookmark)
    }

    /// Separate mode preserves independent book defaults and safely falls back
    /// when a manually edited package contains an unknown value.
    func testSeparatePlaybackNavigationMenusResolveEachDirection() {
        let resolved = PlaybackSkipUnitPolicy.resolve(
            mode: .separate,
            localForwardRawValue: "Unknown unit",
            localBackwardRawValue: SkipUnit.subheading.rawValue,
            globalForward: .seconds60,
            globalBackward: .seconds10
        )

        XCTAssertEqual(resolved.forward, .seconds60)
        XCTAssertEqual(resolved.backward, .subheading)
    }

    /// Direction-aware symbols must update when the effective unit changes.
    func testSkipUnitIconsReflectUnitAndDirection() {
        XCTAssertEqual(SkipUnit.seconds30.iconName(forward: true), "goforward.30")
        XCTAssertEqual(SkipUnit.seconds30.iconName(forward: false), "gobackward.30")
        XCTAssertEqual(SkipUnit.heading.iconName(forward: true), "forward.end.fill")
        XCTAssertEqual(SkipUnit.heading.iconName(forward: false), "backward.end.fill")
    }

    /// Closed navigation menus expose one complete phrase without repeating
    /// or abbreviating the selected time unit.
    func testPlaybackNavigationMenuAccessibilityLabelsAreComplete() {
        XCTAssertEqual(
            SkipUnit.seconds15.playbackMenuAccessibilityLabel(),
            "Navigation unit: 15 seconds"
        )
        XCTAssertEqual(
            SkipUnit.seconds30.playbackMenuAccessibilityLabel(direction: .forward),
            "Forward navigation unit: 30 seconds"
        )
        XCTAssertEqual(
            SkipUnit.paragraph.playbackMenuAccessibilityLabel(direction: .backward),
            "Backward navigation unit: Paragraph"
        )
        XCTAssertFalse(SkipUnit.seconds15.playbackMenuAccessibilityLabel().contains("15s"))
    }

    /// Updated labels describe the actual control layouts while persisted raw
    /// values stay compatible with existing AppStorage data.
    func testPlaybackNavigationControlModeDisplayNamesDescribeCurrentLayouts() {
        XCTAssertEqual(PlaybackNavigationUnitControlMode.shared.displayName, "One Unit for Both Directions")
        XCTAssertEqual(PlaybackNavigationUnitControlMode.separate.displayName, "Separate Forward and Backward Units")
        XCTAssertEqual(PlaybackNavigationUnitControlMode.shared.rawValue, "One Shared Menu")
        XCTAssertEqual(PlaybackNavigationUnitControlMode.separate.rawValue, "Menu for Each Button")
    }

    /// A book-specific speed should override the supplied global fallback.
    func testEffectiveWPMUsesLocalOverride() {
        XCTAssertEqual(makeBook(localWPM: 350).effectiveWPM(fallback: 200), 350)
    }

    /// A book without a speed override should use the supplied global fallback.
    func testEffectiveWPMUsesGlobalFallback() {
        XCTAssertEqual(makeBook().effectiveWPM(fallback: 200), 200)
    }

    /// Remaining-time estimates should use the book-specific WPM override.
    func testEstimatedTimeRemainingUsesLocalWPM() {
        let book = makeBook(localWPM: 300, totalWordCount: 1_000, totalCharacterCount: 5_000)
        let estimate = book.estimatedTimeRemaining(wpm: 200)
        XCTAssertNotNil(estimate)
        XCTAssertEqual(estimate ?? 0, 200, accuracy: 0.001)
    }

    /// A local speed alone should mark the book as having local voice settings.
    func testHasLocalSettingsWithLocalWPM() {
        XCTAssertTrue(makeBook(localWPM: 250).hasLocalVoiceSettings)
    }

    /// A local voice alone should mark the book as having local voice settings.
    func testHasLocalSettingsWithLocalVoice() {
        XCTAssertTrue(makeBook(localVoiceID: "voice.identifier").hasLocalVoiceSettings)
    }

    /// A book with no overrides should use global voice settings completely.
    func testHasLocalSettingsWithoutVoiceOrSpeed() {
        XCTAssertFalse(makeBook().hasLocalVoiceSettings)
    }

    /// Pitch should survive production state encoding alongside voice and speed.
    func testBookStateRoundTripsLocalPitch() throws {
        let state = BookState(localVoiceID: "voice.identifier", localWPM: 300, localPitch: 1.5)
        let decoded = try JSONDecoder().decode(BookState.self, from: JSONEncoder().encode(state))

        XCTAssertEqual(decoded.localPitch, 1.5)
        XCTAssertEqual(decoded.localVoiceID, "voice.identifier")
        XCTAssertEqual(decoded.localWPM, 300)
    }

    /// Older state JSON without pitch should preserve other overrides and use nil pitch.
    func testBookStateDecodesWithoutLocalPitch() throws {
        let data = Data(#"{"isNew":true,"tmbDirectoryName":"old.tmb","localWPM":200}"#.utf8)
        let decoded = try JSONDecoder().decode(BookState.self, from: data)

        XCTAssertNil(decoded.localPitch)
        XCTAssertEqual(decoded.localWPM, 200)
    }

    /// A pitch override alone should count as a local voice setting.
    func testHasLocalSettingsWithOnlyPitch() {
        XCTAssertTrue(makeBook(localPitch: 1.3).hasLocalVoiceSettings)
    }

    /// Absence of all three override fields should report no local settings.
    func testHasLocalSettingsWithoutAnyOverride() {
        XCTAssertFalse(makeBook().hasLocalVoiceSettings)
    }

    /// Pitch conversion should clamp values below the supported range.
    func testPitchConversionClampsLowMultiplier() {
        XCTAssertEqual(AudioEngineService.pitchCents(for: 0.2), -1_200, accuracy: 0.001)
    }

    /// Pitch conversion should clamp values above the supported range.
    func testPitchConversionClampsHighMultiplier() {
        XCTAssertEqual(AudioEngineService.pitchCents(for: 3.5), 1_200, accuracy: 0.001)
    }

    /// In-range pitch multipliers should pass through without clamping.
    func testPitchConversionPreservesNormalMultiplier() {
        XCTAssertEqual(AudioEngineService.pitchCents(for: 1.3), 1200 * log2(1.3), accuracy: 0.001)
    }

    /// A normal pitch multiplier should convert to zero cents.
    func testNormalPitchConvertsToZeroCents() {
        XCTAssertEqual(AudioEngineService.pitchCents(for: 1), 0, accuracy: 0.001)
    }

    /// Double pitch should convert to one octave above normal.
    func testDoublePitchConvertsToPositiveOctave() {
        XCTAssertEqual(AudioEngineService.pitchCents(for: 2), 1_200, accuracy: 0.001)
    }

    /// Half pitch should convert to one octave below normal.
    func testHalfPitchConvertsToNegativeOctave() {
        XCTAssertEqual(AudioEngineService.pitchCents(for: 0.5), -1_200, accuracy: 0.001)
    }

    // MARK: - Repairing saved positions

    /// Negative indices and offsets in a saved position become 0 instead of
    /// reaching the reader.
    func testSavedPositionWithNegativeIndicesDecodesToZero() throws {
        let position = try decodeSaved(ReadingPosition.self, """
        {"chapterIndex": -3, "headingIndex": -2, "characterOffset": -40,
         "globalCharacterOffset": -1, "lastUpdated": "2026-01-02T03:04:05Z"}
        """)

        XCTAssertEqual(position.chapterIndex, 0)
        XCTAssertEqual(position.headingIndex, 0)
        XCTAssertEqual(position.characterOffset, 0)
        XCTAssertEqual(position.globalCharacterOffset, 0)
    }

    /// An offset no `Int` can hold, or one saved as text, no longer fails the
    /// whole position: a required one becomes 0 and an optional one is dropped.
    func testSavedPositionWithUnreadableOffsetsStillDecodes() throws {
        let position = try decodeSaved(ReadingPosition.self, """
        {"chapterIndex": 2, "characterOffset": 1e30, "globalCharacterOffset": "far",
         "headingIndex": 3.5, "lastUpdated": "2026-01-02T03:04:05Z"}
        """)

        XCTAssertEqual(position.chapterIndex, 2)
        XCTAssertEqual(position.characterOffset, 0)
        XCTAssertNil(position.globalCharacterOffset)
        XCTAssertNil(position.headingIndex)
    }

    /// Valid positions decode unchanged, including an offset past any real
    /// content, which the reader clamps against the loaded text.
    func testValidSavedPositionDecodesUnchanged() throws {
        let original = ReadingPosition(
            chapterIndex: 4, headingIndex: 1, characterOffset: 12_345, globalCharacterOffset: Int.max
        )

        let decoded = try roundTrip(original)

        XCTAssertEqual(decoded.chapterIndex, 4)
        XCTAssertEqual(decoded.headingIndex, 1)
        XCTAssertEqual(decoded.characterOffset, 12_345)
        XCTAssertEqual(decoded.globalCharacterOffset, Int.max)
    }

    /// A bookmark saved at a negative location decodes at the start instead
    /// of failing its book; its other fields are kept.
    func testBookmarkWithNegativeLocationDecodesToZero() throws {
        let bookmark = try decodeSaved(Bookmark.self, """
        {"id": "3F2A6C1E-0000-4000-8000-000000000001", "number": 2, "chapterIndex": -1,
         "characterOffset": -500, "label": "Margin note", "dateCreated": "2026-01-02T03:04:05Z"}
        """)

        XCTAssertEqual(bookmark.chapterIndex, 0)
        XCTAssertEqual(bookmark.characterOffset, 0)
        XCTAssertEqual(bookmark.number, 2)
        XCTAssertEqual(bookmark.label, "Margin note")
    }

    /// One book with an unreadable position used to fail library.json as a
    /// whole, which loads as an empty library. Every book now loads, and the
    /// damaged position is repaired.
    func testLibraryWithOneDamagedPositionStillLoadsEveryBook() throws {
        let intact = Book(
            title: "Intact", format: .txt, filePath: "/tmp/intact.txt", md5Hash: "intact",
            readingPosition: ReadingPosition(chapterIndex: 1, characterOffset: 20)
        )
        let damaged = Book(
            title: "Damaged", format: .txt, filePath: "/tmp/damaged.txt", md5Hash: "damaged",
            readingPosition: ReadingPosition(chapterIndex: 2, characterOffset: 30)
        )
        var file = try jsonObject(Library(books: [intact, damaged]))
        var books = try XCTUnwrap(file["books"] as? [[String: Any]])
        // The file was encoded from two books; guard the second before it is read and written by position.
        _ = try XCTUnwrap(books[safe: 1], "the encoded library has no second book")
        var position = try XCTUnwrap(books[1]["readingPosition"] as? [String: Any])
        position["chapterIndex"] = -2
        position["characterOffset"] = "thirty"
        books[1]["readingPosition"] = position
        file["books"] = books

        let library = try savedDataDecoder.decode(Library.self, from: JSONSerialization.data(withJSONObject: file))

        XCTAssertEqual(library.books.map(\.title), ["Intact", "Damaged"])
        // The decoded library may hold fewer books than were saved; fail rather than trap.
        _ = try XCTUnwrap(library.books[safe: 1], "the decoded library has no second book")
        XCTAssertEqual(library.books[0].readingPosition?.characterOffset, 20)
        XCTAssertEqual(library.books[1].readingPosition?.chapterIndex, 0)
        XCTAssertEqual(library.books[1].readingPosition?.characterOffset, 0)
    }

    // MARK: - Repairing saved speeds, pitches, and counts

    /// A text book's saved speed is clamped to the words-per-minute range and
    /// its pitch to the pitch range, like the global settings.
    func testTextBookSpeedAndPitchAreClampedToTheSettingsRanges() throws {
        let fast = try decodeLibraryBook(format: .txt, #""localWPM": 10000, "localPitch": 9"#)
        let slow = try decodeLibraryBook(format: .txt, #""localWPM": 12, "localPitch": 0.1"#)

        XCTAssertEqual(fast.localWPM, 650)
        XCTAssertEqual(fast.localPitch, 2)
        XCTAssertEqual(slow.localWPM, 50)
        XCTAssertEqual(slow.localPitch, 0.5)
    }

    /// Speeds and pitches that cannot be one (zero, negative, a number too
    /// large for `Double`, or text) are dropped, so the book follows the
    /// global settings, and the rest of the book still loads.
    func testUnusableSavedSpeedsAndPitchesAreDropped() throws {
        let cases = [
            #""localWPM": -200, "localPitch": 0"#,
            #""localWPM": 0, "localPitch": -1"#,
            #""localWPM": 1e999, "localPitch": 1e999"#,
            #""localWPM": "fast", "localPitch": "high""#,
        ]
        for fields in cases {
            let book = try decodeLibraryBook(
                format: .txt,
                fields + #", "totalWordCount": 1000, "totalCharacterCount": 5000"#
            )
            XCTAssertNil(book.localWPM, fields)
            XCTAssertNil(book.localPitch, fields)
            XCTAssertEqual(book.title, "Saved", fields)
            // The estimate falls back to the global speed: 1,000 words at 200 WPM.
            XCTAssertEqual(book.estimatedTimeRemaining(wpm: 200) ?? -1, 300, accuracy: 0.001, fields)
        }
    }

    /// An audio book's saved multiplier is normalized exactly as the reader
    /// and player normalize it; an unusable one plays at normal speed.
    func testAudioBookSpeedIsNormalizedLikeThePlayer() throws {
        for (saved, expected) in [(1.2345, 1.25), (99, 4), (0.1, 0.25), (1.5, 1.5)] {
            let book = try decodeLibraryBook(format: .audio, #""localWPM": \#(saved)"#)
            XCTAssertEqual(book.localWPM, expected, "\(saved)")
            XCTAssertEqual(book.localWPM, AudioSpeed.normalized(saved), "\(saved)")
        }
        XCTAssertNil(try decodeLibraryBook(format: .audio, #""localWPM": 0"#).localWPM)
    }

    /// Negative or unreadable word and character counts are dropped, as for
    /// a book that has not been measured yet; valid counts are kept.
    func testNegativeOrUnreadableCountsAreDropped() throws {
        let damaged = try decodeLibraryBook(format: .txt, #""totalWordCount": -5, "totalCharacterCount": "many""#)
        let intact = try decodeLibraryBook(format: .txt, #""totalWordCount": 0, "totalCharacterCount": 42"#)

        XCTAssertNil(damaged.totalWordCount)
        XCTAssertNil(damaged.totalCharacterCount)
        XCTAssertNil(damaged.percentComplete)
        XCTAssertEqual(intact.totalWordCount, 0)
        XCTAssertEqual(intact.totalCharacterCount, 42)
    }

    /// bookInfo.json applies the same rules: its state repairs counts and
    /// pitch and drops speeds no book can have, and the package applies the
    /// format's speed range once it knows the format.
    func testBookInfoAppliesTheFormatSpeedRange() throws {
        let audio = try decodePackage(format: .audio, #""localWPM": 99, "localPitch": 5, "totalWordCount": -3"#)
        let text = try decodePackage(format: .txt, #""localWPM": 10000"#)
        let unusable = try decodePackage(format: .epub, #""localWPM": -1"#)

        XCTAssertEqual(audio.state.localWPM, 4)
        XCTAssertEqual(audio.state.localPitch, 2)
        XCTAssertNil(audio.state.totalWordCount)
        XCTAssertEqual(text.state.localWPM, 650)
        XCTAssertNil(unusable.state.localWPM)
    }

    /// Without its package, saved state cannot know the format, so it only
    /// drops impossible speeds and leaves the range to `BookInfo`.
    func testStandaloneStateOnlyDropsImpossibleSpeeds() throws {
        let fast = try decodeSaved(BookState.self, #"{"isNew": false, "tmbDirectoryName": "x.tmb", "localWPM": 10000}"#)
        let negative = try decodeSaved(BookState.self, #"{"isNew": false, "tmbDirectoryName": "x.tmb", "localWPM": -1}"#)

        XCTAssertEqual(fast.localWPM, 10_000)
        XCTAssertNil(negative.localWPM)
    }

    // MARK: - Saved data helpers

    /// Decodes a library.json book entry with `fields` added to a minimal,
    /// valid entry.
    private func decodeLibraryBook(format: BookFormat, _ fields: String) throws -> Book {
        try decodeSaved(Book.self, """
        {"id": "5D1E7A20-0000-4000-8000-000000000002", "title": "Saved", "author": "Unknown",
         "format": "\(format.rawValue)", "filePath": "/tmp/saved", "md5Hash": "saved",
         "folderPath": "", "dateAdded": "2026-01-02T03:04:05Z", "bookmarks": [], \(fields)}
        """)
    }

    /// Decodes a bookInfo.json with `stateFields` added to a minimal state.
    private func decodePackage(format: BookFormat, _ stateFields: String) throws -> BookInfo {
        try decodeSaved(BookInfo.self, """
        {"metadata": {"title": "Saved", "author": "Unknown", "format": "\(format.rawValue)",
          "md5Hash": "saved", "dateAdded": "2026-01-02T03:04:05Z", "originalFileName": "saved",
          "folderPath": "", "bookID": "5D1E7A20-0000-4000-8000-000000000003"},
         "state": {"isNew": false, "tmbDirectoryName": "saved.tmb", \(stateFields)},
         "bookmarks": []}
        """)
    }

    /// Decoder configured like the app's library and bookInfo.json readers.
    private var savedDataDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Encoder configured like the app's library and bookInfo.json writers.
    private var savedDataEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Decodes hand-written saved data, as someone editing the file would.
    private func decodeSaved<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try savedDataDecoder.decode(type, from: Data(json.utf8))
    }

    /// Encodes and decodes a value the way the app saves and reloads it.
    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try savedDataDecoder.decode(T.self, from: savedDataEncoder.encode(value))
    }

    /// The JSON object the app saves for `value`, for editing into damage.
    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: savedDataEncoder.encode(value)) as? [String: Any])
    }
}
