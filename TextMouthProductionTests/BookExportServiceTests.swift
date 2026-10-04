import XCTest
@testable import TextMouth

/// What a book can export, and the export itself (FR05): every kind a
/// book's package holds, each with its suggested name and size, copied into
/// a folder without writing over anything, and never downloading a file
/// that is only in the cloud.
///
/// Every book lives in a library folder of the test's own, and every export
/// goes to a sandbox folder; nothing reaches the user's Documents. A hosted
/// test cannot make a real dataless file, so the cloud is a
/// `MaintenanceFileAccess` that names the files it pretends are dataless,
/// and the reads it refuses as the system refuses one.
@MainActor
final class BookExportServiceTests: XCTestCase {

    // MARK: - Listing

    /// A text book offers its own file under its own name, its Markdown,
    /// and its reading text, in that order, each sized from the file it
    /// comes from, none in the cloud.
    func testATextBookOffersItsOwnFileItsMarkdownAndItsReadingText() throws {
        let world = try makeIntegrationWorld("Export Text Offer")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let stem = BookExportService.fileNameStem(for: book.title)
        let cache = MarkdownCacheService.cacheURL(for: book)

        let offer = BookExportService.offer(for: book)

        XCTAssertFalse(offer.isPackageInCloud)
        XCTAssertEqual(offer.items.map(\.kind), [.originalFile, .markdown, .plainText])
        XCTAssertEqual(
            offer.items.map(\.suggestedName),
            ["Harbour Pilots.md", "\(stem) - Text.md", "\(stem) - Text.txt"]
        )
        XCTAssertEqual(offer.item(.originalFile)?.byteCount, try byteCount(of: book.bookFileURL))
        XCTAssertEqual(offer.item(.markdown)?.byteCount, try byteCount(of: cache))
        XCTAssertEqual(offer.item(.plainText)?.byteCount, try byteCount(of: cache), "the Markdown's size stands for the text's")
        XCTAssertEqual(offer.item(.markdown)?.files.map(\.source), [.copy(cache)])
        XCTAssertEqual(offer.item(.plainText)?.files.map(\.source), [.readingText(fromMarkdown: cache)])
        XCTAssertTrue(offer.items.allSatisfy { !$0.isInCloud && $0.folderName == nil })
    }

    /// A multi-file audiobook offers its audio alone: its tracks, together
    /// in a folder named after the book, in the order it plays them, each
    /// numbered and named for its chapter.
    func testAMultiFileAudiobookOffersItsTracksNamedForTheirChapters() throws {
        let world = try makeIntegrationWorld("Export Audio Offer")
        let book = try world.makeSilentAudioBook(title: "Tide Clock Recordings", trackDurations: [1, 1, 1])
        let index = try XCTUnwrap(BookInfo.load(from: book.tmbDirectory).contentIndex)

        let offer = BookExportService.offer(for: book)

        XCTAssertEqual(offer.items.map(\.kind), [.audio])
        let audio = try XCTUnwrap(offer.item(.audio))
        XCTAssertEqual(audio.folderName, "Tide Clock Recordings")
        XCTAssertEqual(audio.suggestedName, "Tide Clock Recordings")
        XCTAssertEqual(audio.files.map { $0.source.url.lastPathComponent }, ["01.wav", "02.wav", "03.wav"])
        XCTAssertEqual(
            audio.files.map(\.path),
            index.chapters.enumerated().map { number, chapter in
                "0\(number + 1) - \(BookExportService.safeFileName(chapter.title, fallback: "")).wav"
            }
        )
        let tracks = try audio.files.map { try byteCount(of: $0.source.url) }
        XCTAssertEqual(audio.byteCount, tracks.reduce(0, +))
        XCTAssertFalse(audio.isInCloud)
    }

    /// A segmented audiobook, as a DAISY audiobook is read, offers each of
    /// its files once, in the order its sections first play them, named for
    /// the first section playing each; its manifest is TextMouth's own and
    /// is not offered.
    func testASegmentedAudiobookOffersEachFileOnceInPlayingOrder() throws {
        let world = try makeIntegrationWorld("Export Segmented Offer")
        let sections = try [
            AudioSegment(title: "Landfall", file: "b-second.wav", startTime: 0, endTime: 1),
            XCTUnwrap(AudioSegment(title: "Crossing", clips: [
                AudioClip(file: "b-second.wav", startTime: 1, endTime: 2),
                AudioClip(file: "a-first.wav", startTime: 0, endTime: 1),
            ])),
        ]
        let book = try world.makeSegmentedAudioBook(
            title: "Ferry Log",
            files: ["a-first.wav": 1, "b-second.wav": 2],
            sections: sections
        )

        let audio = try XCTUnwrap(BookExportService.offer(for: book).item(.audio))

        XCTAssertEqual(audio.files.map { $0.source.url.lastPathComponent }, ["b-second.wav", "a-first.wav"])
        XCTAssertEqual(audio.files.map(\.path), ["01 - Landfall.wav", "02 - Crossing.wav"])
    }

    /// The order of an audiobook's files follows its index, a file named
    /// by a section's clips as well as by a chapter, and keeps each file
    /// once; files the index does not name follow in Finder's order, and a
    /// file it names that is gone is left out.
    func testAudioFilesFollowTheIndexThenFindersOrder() {
        let index = Self.audioIndex(chapters: [
            ("Opening", "Disc 2/10.mp3", []),
            ("Middle", "Disc 1/02.mp3", ["Disc 1/02.mp3", "Disc 2/10.mp3", "gone.mp3"]),
            ("", "Disc 1/01.mp3", []),
        ])
        let listed = ["extra 10.mp3", "Disc 1/01.mp3", "extra 9.mp3", "Disc 1/02.mp3", "Disc 2/10.mp3"]

        let ordered = BookExportService.audioFileOrder(listed: listed, index: index)

        XCTAssertEqual(ordered.map(\.path), ["Disc 2/10.mp3", "Disc 1/02.mp3", "Disc 1/01.mp3", "extra 9.mp3", "extra 10.mp3"])
        XCTAssertEqual(ordered.map(\.title), ["Opening", "Middle", "", nil, nil])
        XCTAssertEqual(
            BookExportService.audioFileOrder(listed: ["b.mp3", "a.mp3"], index: nil).map(\.path),
            ["a.mp3", "b.mp3"],
            "with no index, the files keep Finder's order"
        )
    }

    /// A DAISY book kept as loose files offers every file of the book,
    /// laid out as in its own folder, in a folder named after the book,
    /// and none of the files TextMouth keeps beside them.
    func testALooseDAISYBookOffersEveryFileOfTheBook() throws {
        let world = try makeIntegrationWorld("Export DAISY Offer")
        let folder = try DAISYPackageFixtures.writeFolder(
            DAISYPackageFixtures.packageBook,
            named: "Ferry Timetables",
            in: makeSandboxDirectory("Export DAISY Source")
        )
        let book = try world.importBook(from: folder.appendingPathComponent("book.opf"))

        let offer = BookExportService.offer(for: book)

        XCTAssertEqual(offer.items.map(\.kind), [.originalFile, .markdown, .plainText])
        let original = try XCTUnwrap(offer.item(.originalFile))
        XCTAssertEqual(original.folderName, BookExportService.fileNameStem(for: book.title))
        XCTAssertEqual(original.files.map(\.path), DAISYPackageFixtures.packageBookFiles)
        XCTAssertEqual(original.byteCount, Int64(DAISYPackageFixtures.packageBook.values.map { $0.utf8.count }.reduce(0, +)))
    }

    /// A DAISY book in a ZIP offers the ZIP as its own file.
    func testADAISYZipOffersTheZip() throws {
        let world = try makeIntegrationWorld("Export DAISY ZIP Offer")
        let book = try world.importBook(from: requireFile("daisy202_test.zip"))

        let offer = BookExportService.offer(for: book)

        XCTAssertEqual(offer.items.map(\.kind), [.originalFile, .markdown, .plainText])
        XCTAssertEqual(offer.item(.originalFile)?.suggestedName, "daisy202_test.zip")
        XCTAssertNil(offer.item(.originalFile)?.folderName)
    }

    /// The files a recording and a transcription keep in a package are
    /// offered by kind, whatever else the book is: an original take, and a
    /// transcript with, for an audiobook, the text written from it.
    func testAPackageWithATranscriptAndAnOriginalTakeOffersBoth() throws {
        let world = try makeIntegrationWorld("Export Extra Files")
        let audiobook = try world.makeSilentAudioBook(title: "Night Shift Notes", trackDurations: [1])
        try addExtraFiles(to: audiobook, includingText: "<!-- chapter: Start -->\nThe tide turns at nine.")
        let textBook = try world.importBook(from: writeSource(named: "Lock Keeper.md", Self.twoChapters))
        try addExtraFiles(to: textBook, includingText: nil)

        let audioOffer = BookExportService.offer(for: audiobook)
        let textOffer = BookExportService.offer(for: textBook)

        XCTAssertEqual(audioOffer.items.map(\.kind), [.audio, .originalRecording, .transcript])
        XCTAssertEqual(audioOffer.item(.originalRecording)?.suggestedName, "Night Shift Notes - Original Recording.caf")
        XCTAssertEqual(
            audioOffer.item(.transcript)?.files.map(\.path),
            ["Night Shift Notes - Transcript.json", "Night Shift Notes - Transcript.md"]
        )
        XCTAssertEqual(textOffer.items.map(\.kind), [.originalFile, .markdown, .plainText, .originalRecording, .transcript])
        let stem = BookExportService.fileNameStem(for: textBook.title)
        XCTAssertEqual(textOffer.item(.transcript)?.files.map(\.path), ["\(stem) - Transcript.json"])
        XCTAssertEqual(textOffer.item(.originalRecording)?.byteCount, Int64(Self.takeBytes.count))
    }

    // MARK: - Originals an Edit Kept

    /// An audiobook whose file the audio editor first edited offers its
    /// original audio, kept by the engine's own call in the package's
    /// originals folder, under its own extension; exporting copies that
    /// original byte for byte, while Audio stays the book's file as edited.
    func testAnEditedAudiobookOffersItsOriginalAudio() throws {
        let world = try makeIntegrationWorld("Export Original Audio")
        let (book, kept) = try makeEditedAudiobook(in: world)
        let stem = BookExportService.fileNameStem(for: book.title)
        let destination = try makeSandboxDirectory("Export Original Audio Destination")

        let offer = BookExportService.offer(for: book)
        let outcome = BookExportService.export([offer], kinds: [.originalAudio], to: destination)

        XCTAssertEqual(offer.items.map(\.kind), [.audio, .originalAudio])
        let item = try XCTUnwrap(offer.item(.originalAudio))
        XCTAssertNil(item.folderName)
        XCTAssertEqual(item.suggestedName, "\(stem) - Original Audio.wav")
        XCTAssertEqual(item.files.map(\.source.url.path), [kept.path])
        XCTAssertEqual(item.byteCount, try byteCount(of: kept))
        XCTAssertFalse(item.isInCloud)
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.exported.map(\.lastPathComponent), ["\(stem) - Original Audio.wav"])
        let exported = try Data(contentsOf: destination.appendingPathComponent("\(stem) - Original Audio.wav"))
        XCTAssertEqual(exported, try Data(contentsOf: kept))
        XCTAssertNotEqual(exported, try Data(contentsOf: book.bookFileURL), "the edited audio was exported as the original")
    }

    /// A book of tracks offers the originals of the tracks it edited
    /// together, in a folder named for its original audio, each under its
    /// path in the book's audio folder, one edited track as much as two.
    func testABookOfTracksOffersTheOriginalsOfItsEditedTracksInAFolder() throws {
        let world = try makeIntegrationWorld("Export Track Originals")
        let book = try world.makeSilentAudioBook(title: "Tide Clock Recordings", trackDurations: [1, 1, 1])
        let tracks = try XCTUnwrap(AudioEditPackage.path(of: book.bookFileURL, in: book.tmbDirectory))
        _ = try AudioEditPackage.keepOriginal(ofAudioFile: "\(tracks)/03.wav", inPackage: book.tmbDirectory, at: Date())

        let one = try XCTUnwrap(BookExportService.offer(for: book).item(.originalAudio))
        XCTAssertEqual(one.folderName, "Tide Clock Recordings - Original Audio")
        XCTAssertEqual(one.files.map(\.path), ["03.wav"])

        _ = try AudioEditPackage.keepOriginal(ofAudioFile: "\(tracks)/01.wav", inPackage: book.tmbDirectory, at: Date())
        let offer = BookExportService.offer(for: book)
        let destination = try makeSandboxDirectory("Export Track Originals Destination")
        let outcome = BookExportService.export([offer], kinds: [.originalAudio], to: destination)

        XCTAssertEqual(offer.items.map(\.kind), [.audio, .originalAudio])
        XCTAssertEqual(offer.item(.originalAudio)?.files.map(\.path), ["01.wav", "03.wav"])
        XCTAssertEqual(outcome.failures, [])
        let folder = destination.appendingPathComponent("Tide Clock Recordings - Original Audio", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["01.wav", "03.wav"])
    }

    /// Only originals the engine kept are offered: a book never edited
    /// offers none, nor does an originals folder holding only a hidden file,
    /// and a recording's take stays its Original recording alone.
    func testOnlyOriginalsTheEngineKeptAreOffered() throws {
        let world = try makeIntegrationWorld("Export No Originals")
        let book = try world.makeSilentAudioBook(title: "Night Shift Notes", trackDurations: [1])
        try addExtraFiles(to: book, includingText: nil)
        XCTAssertNil(BookExportService.offer(for: book).item(.originalAudio))

        let originals = AudioEditPackage.folder(in: book.tmbDirectory)
            .appendingPathComponent(AudioEditPackage.originalsFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try Data("Finder".utf8).write(to: originals.appendingPathComponent(".DS_Store"))

        let offer = BookExportService.offer(for: book)
        XCTAssertNil(offer.item(.originalAudio))
        XCTAssertEqual(offer.items.map(\.kind), [.audio, .originalRecording, .transcript])
    }

    /// Originals only in the cloud are offered as such and never exported,
    /// the book named in the list's words: a folder that can't be listed
    /// without downloading it, and a kept file that is dataless.
    func testOriginalsInTheCloudAreRefused() throws {
        let world = try makeIntegrationWorld("Export Cloud Originals")
        let (book, kept) = try makeEditedAudiobook(in: world)
        let folder = AudioEditPackage.folder(in: book.tmbDirectory)
            .appendingPathComponent(AudioEditPackage.originalsFolderName, isDirectory: true)
        let destination = try makeSandboxDirectory("Export Cloud Originals Destination")

        for (dataless, inCloud) in [(folder, folder), (kept, kept)] {
            let cloud = Self.cloud(dataless: [dataless])
            let offer = BookExportService.offer(for: book, access: cloud)
            let outcome = BookExportService.export([offer], kinds: [.originalAudio], to: destination, access: cloud)

            XCTAssertEqual(offer.item(.originalAudio)?.fileInCloud, inCloud)
            XCTAssertEqual(outcome.exported, [])
            XCTAssertEqual(outcome.booksInCloud.map(\.title), [book.title])
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    // MARK: - Exporting

    /// Exporting a text book's three kinds copies its own file and its
    /// Markdown byte for byte and writes its reading text, all straight
    /// into the folder chosen, and says so.
    func testExportingATextBookWritesEachKindIntoTheFolder() throws {
        let world = try makeIntegrationWorld("Export Text Copy")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let stem = BookExportService.fileNameStem(for: book.title)
        let destination = try makeSandboxDirectory("Export Text Destination")

        let outcome = BookExportService.export(
            [BookExportService.offer(for: book)],
            kinds: [.originalFile, .markdown, .plainText],
            to: destination
        )

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.booksInCloud, [])
        XCTAssertFalse(outcome.wasCancelled)
        XCTAssertEqual(
            outcome.exported.map(\.lastPathComponent),
            ["Harbour Pilots.md", "\(stem) - Text.md", "\(stem) - Text.txt"]
        )
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: destination.path)),
            ["Harbour Pilots.md", "\(stem) - Text.md", "\(stem) - Text.txt"]
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("Harbour Pilots.md")),
            try Data(contentsOf: book.bookFileURL)
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("\(stem) - Text.md")),
            try Data(contentsOf: MarkdownCacheService.cacheURL(for: book))
        )
        let text = try String(contentsOf: destination.appendingPathComponent("\(stem) - Text.txt"), encoding: .utf8)
        XCTAssertFalse(text.contains("<!--"), "the reading text holds no chapter markers")
        XCTAssertFalse(text.contains("#"), "the reading text holds no Markdown")
        for words in ["One two three.", "Four five.", "Six seven eight."] {
            XCTAssertTrue(text.contains(words), "the reading text lacks \(words)")
        }
        XCTAssertEqual(BookExportWording.finished(outcome, folderName: "Exports"), "Exported 3 items to Exports.")
    }

    /// An export never writes over anything: a name already taken in the
    /// folder, as by an earlier export, is followed by a number.
    func testExportingAgainNumbersTheNewFiles() throws {
        let world = try makeIntegrationWorld("Export Twice")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let destination = try makeSandboxDirectory("Export Twice Destination")
        let offer = BookExportService.offer(for: book)
        let stem = BookExportService.fileNameStem(for: book.title)
        try Data("Someone else's notes".utf8).write(to: destination.appendingPathComponent("\(stem) - Text.md"))

        let outcome = BookExportService.export([offer], kinds: [.markdown, .plainText], to: destination)
        let again = BookExportService.export([offer], kinds: [.plainText], to: destination)

        XCTAssertEqual(outcome.exported.map(\.lastPathComponent), ["\(stem) - Text 2.md", "\(stem) - Text.txt"])
        XCTAssertEqual(again.exported.map(\.lastPathComponent), ["\(stem) - Text 2.txt"])
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("\(stem) - Text.md"), encoding: .utf8),
            "Someone else's notes",
            "an existing file was written over"
        )
    }

    /// One audiobook's tracks go into a folder named after it; several
    /// books each get a folder of their own, whatever they export.
    func testTracksAndSeveralBooksEachGetAFolder() throws {
        let world = try makeIntegrationWorld("Export Folders")
        let audiobook = try world.makeSilentAudioBook(title: "Tide Clock Recordings", trackDurations: [1, 1])
        let textBook = try world.importBook(from: writeSource(named: "Lock Keeper.md", Self.twoChapters))
        let one = try makeSandboxDirectory("Export One Audiobook")
        let several = try makeSandboxDirectory("Export Several Books")
        let audioOffer = BookExportService.offer(for: audiobook)
        let textOffer = BookExportService.offer(for: textBook)
        let textStem = BookExportService.fileNameStem(for: textBook.title)

        let alone = BookExportService.export([audioOffer], kinds: [.audio], to: one)
        let together = BookExportService.export([audioOffer, textOffer], kinds: [.audio, .markdown], to: several)

        XCTAssertEqual(alone.failures, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: one.path), ["Tide Clock Recordings"])
        XCTAssertEqual(
            alone.exported.map { $0.pathComponents.suffix(2).joined(separator: "/") },
            audioOffer.item(.audio)?.files.map { "Tide Clock Recordings/\($0.path)" }
        )
        XCTAssertEqual(together.exported.count, 3)
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: several.path)),
            ["Tide Clock Recordings", textStem]
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: several.appendingPathComponent(textStem).path),
            ["\(textStem) - Text.md"]
        )
    }

    /// A DAISY book kept as loose files is exported with every file of the
    /// book, laid out as in its own folder.
    func testALooseDAISYBookIsExportedWithItsLayout() throws {
        let world = try makeIntegrationWorld("Export DAISY Copy")
        let folder = try DAISYPackageFixtures.writeFolder(
            DAISYPackageFixtures.navigationBook,
            named: "Rope Splicing",
            in: makeSandboxDirectory("Export DAISY Copy Source")
        )
        let book = try world.importBook(from: folder)
        let destination = try makeSandboxDirectory("Export DAISY Copy Destination")
        let stem = BookExportService.fileNameStem(for: book.title)

        let outcome = BookExportService.export([BookExportService.offer(for: book)], kinds: [.originalFile], to: destination)

        XCTAssertEqual(outcome.failures, [])
        let exported = destination.appendingPathComponent(stem, isDirectory: true)
        for (path, text) in DAISYPackageFixtures.navigationBook {
            XCTAssertEqual(
                try String(contentsOf: exported.appendingPathComponent(path), encoding: .utf8),
                text,
                "\(path) was not exported as it is"
            )
        }
        XCTAssertEqual(outcome.exported.count, DAISYPackageFixtures.navigationBook.count)
    }

    /// A file that cannot be written is named with the reason, and the
    /// rest are still written.
    func testAFileThatCannotBeWrittenIsNamedWithTheReason() throws {
        let world = try makeIntegrationWorld("Export Failure")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let destination = try makeSandboxDirectory("Export Failure Destination")
        let stem = BookExportService.fileNameStem(for: book.title)
        let offer = BookExportService.offer(for: book)
        // content.md that nothing may read cannot be copied; the book's own
        // file beside it still is.
        let cache = MarkdownCacheService.cacheURL(for: book)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: cache.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cache.path) }

        let outcome = BookExportService.export([offer], kinds: [.originalFile, .markdown], to: destination)

        XCTAssertEqual(outcome.exported.map(\.lastPathComponent), ["Harbour Pilots.md"])
        XCTAssertEqual(outcome.booksInCloud, [])
        let failure = try XCTUnwrap(outcome.failures.first)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(failure.name, "\(stem) - Text.md")
        XCTAssertFalse(failure.reason.isEmpty)
        let reason = failure.reason.hasSuffix(".") ? String(failure.reason.dropLast()) : failure.reason
        XCTAssertEqual(
            BookExportWording.finished(outcome, folderName: "Exports"),
            "Exported 1 item to Exports. Couldn't export \(stem) - Text.md: \(reason)."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("\(stem) - Text.md").path),
            "a failed copy left a file behind"
        )
    }

    /// Cancel stops an export before its next file.
    func testCancelStopsBeforeTheNextFile() throws {
        let world = try makeIntegrationWorld("Export Cancel")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let destination = try makeSandboxDirectory("Export Cancel Destination")
        let cancellation = BookExportCancellation()
        cancellation.cancel()

        let outcome = BookExportService.export(
            [BookExportService.offer(for: book)],
            kinds: [.originalFile, .markdown],
            to: destination,
            cancellation: cancellation
        )

        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(outcome.exported, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(BookExportWording.finished(outcome, folderName: "Exports"), "Export stopped. Nothing was exported.")
    }

    // MARK: - The Cloud

    /// An item with a file only in the cloud is offered as such and never
    /// exported, its book named in the list's words; the rest of the book
    /// is exported, and nothing is downloaded.
    func testAnItemInTheCloudIsRefusedAndTheRestIsExported() throws {
        let world = try makeIntegrationWorld("Export Cloud Item")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let cache = MarkdownCacheService.cacheURL(for: book)
        let cloud = Self.cloud(dataless: [cache])
        let destination = try makeSandboxDirectory("Export Cloud Item Destination")

        let offer = BookExportService.offer(for: book, access: cloud)
        let outcome = BookExportService.export([offer], kinds: [.originalFile, .markdown, .plainText], to: destination, access: cloud)

        XCTAssertNil(offer.item(.originalFile)?.fileInCloud)
        XCTAssertEqual(offer.item(.markdown)?.fileInCloud, cache)
        XCTAssertEqual(offer.item(.plainText)?.fileInCloud, cache)
        XCTAssertEqual(outcome.exported.map(\.lastPathComponent), ["Harbour Pilots.md"])
        XCTAssertEqual(outcome.booksInCloud, [BookExportBookName(book)])
        XCTAssertEqual(
            BookExportWording.finished(outcome, folderName: "Exports"),
            "Exported 1 item to Exports. \(book.title) isn't downloaded. "
                + "Download it first: select it in the library, then choose Download Now."
        )
    }

    /// A package only in the cloud, as iCloud Drive keeps a book it has
    /// evicted, lists nothing and exports nothing.
    func testAPackageOnlyInTheCloudListsNothing() throws {
        let world = try makeIntegrationWorld("Export Cloud Package")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let cloud = Self.cloud(dataless: [book.tmbDirectory])
        let destination = try makeSandboxDirectory("Export Cloud Package Destination")

        let offer = BookExportService.offer(for: book, access: cloud)
        let outcome = BookExportService.export([offer], kinds: Set(BookExportKind.allCases), to: destination, access: cloud)

        XCTAssertTrue(offer.isPackageInCloud)
        XCTAssertEqual(offer.items, [])
        XCTAssertEqual(outcome.exported, [])
        XCTAssertEqual(outcome.booksInCloud.map(\.title), [book.title])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    /// A file that goes to the cloud after it was offered is refused as the
    /// system refuses its read, and nothing is left where it would have
    /// gone.
    func testAFileThatGoesToTheCloudBeforeItIsCopiedIsRefused() throws {
        let world = try makeIntegrationWorld("Export Cloud Late")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let destination = try makeSandboxDirectory("Export Cloud Late Destination")
        let offer = BookExportService.offer(for: book)
        let source = book.bookFileURL
        let refusing = MaintenanceFileAccess(isDataless: { _ in false }, refusesRead: { $0 == source })

        let outcome = BookExportService.export([offer], kinds: [.originalFile], to: destination, access: refusing)

        XCTAssertEqual(outcome.exported, [])
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.booksInCloud.map(\.title), [book.title])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    // MARK: - Reading Text and Names

    /// The reading text puts each chapter under its title, once, keeps the
    /// chapters apart, leaves out a chapter with no words, and ends with a
    /// line break.
    func testReadingTextPutsEachChapterUnderItsTitleOnce() {
        let chapters = [
            Chapter(title: "The Harbour", text: "The Harbour\n\nBoats come in."),
            Chapter(title: "Empty", text: "  \n"),
            Chapter(title: "Low Water", text: "Mud flats shine."),
            Chapter(title: "", text: "An untitled ending."),
        ]

        XCTAssertEqual(
            BookExportService.plainText(of: chapters),
            "The Harbour\n\nBoats come in.\n\n\nLow Water\n\nMud flats shine.\n\n\nAn untitled ending.\n"
        )
        XCTAssertEqual(BookExportService.plainText(of: []), "")
    }

    /// A title becomes a safe name: no slash or colon, no control
    /// character, no leading dot, no run of spaces, and no more bytes than a
    /// name has room for, cut between characters.
    func testTitlesBecomeSafeNames() {
        XCTAssertEqual(BookExportService.safeFileName("Tides: A/B Guide", fallback: "x"), "Tides- A-B Guide")
        XCTAssertEqual(BookExportService.safeFileName("..hidden\tname\n", fallback: "x"), "hidden name")
        XCTAssertEqual(BookExportService.safeFileName("  ", fallback: "Untitled"), "Untitled")
        XCTAssertEqual(BookExportService.fileNameStem(for: "..."), "Untitled")
        let long = String(repeating: "é", count: 200)
        let cut = BookExportService.safeFileName(long, fallback: "x")
        XCTAssertLessThanOrEqual(cut.utf8.count, BookExportService.maximumStemByteCount)
        XCTAssertEqual(cut, String(repeating: "é", count: BookExportService.maximumStemByteCount / 2))
    }

    // MARK: - Words

    /// Books in the cloud are named, up to three, then counted, with what
    /// to do in the list's words; a move of the library says the same.
    func testBooksInTheCloudAreNamedInTheListsWords() {
        XCTAssertEqual(
            LibraryCloudWording.notDownloaded(titles: ["Emma"]),
            "Emma isn't downloaded. Download it first: select it in the library, then choose Download Now."
        )
        XCTAssertEqual(
            LibraryCloudWording.notDownloaded(titles: ["Emma", "Persuasion"]),
            "Emma and Persuasion aren't downloaded. Download them first: select them in the library, then choose Download Now."
        )
        XCTAssertEqual(
            LibraryCloudWording.notDownloaded(titles: ["A", "B", "C", "D"]),
            "4 books aren't downloaded. Download them first: select them in the library, then choose Download Now."
        )
        XCTAssertEqual(
            DataDirectoryMoveRefusal.booksNotDownloaded(1).errorDescription,
            "1 book isn't downloaded. Download it first: select it in the library, then choose Download Now."
        )
        XCTAssertEqual(
            DataDirectoryMoveRefusal.booksNotDownloaded(3).errorDescription,
            "3 books aren't downloaded. Download them first: select them in the library, then choose Download Now."
        )
    }

    /// Failures are named with their reasons, up to three; past that, the
    /// first stands for the rest.
    func testFailuresAreNamedWithTheirReasons() {
        let failures = (1...4).map { BookExportFailure(name: "\($0).mp3", reason: "The disk is full.") }

        XCTAssertNil(BookExportWording.failureSentence([]))
        XCTAssertEqual(
            BookExportWording.failureSentence(Array(failures.prefix(1))),
            "Couldn't export 1.mp3: The disk is full."
        )
        XCTAssertEqual(
            BookExportWording.failureSentence(Array(failures.prefix(2))),
            "Couldn't export 2 items: 1.mp3: The disk is full; 2.mp3: The disk is full."
        )
        XCTAssertEqual(
            BookExportWording.failureSentence(failures),
            "Couldn't export 4 items. The first was 1.mp3: The disk is full."
        )
    }

    // MARK: - Fixtures

    /// Two chapters, as a Markdown book with chapter markers holds them.
    private static let twoChapters = """
    <!-- chapter: First -->
    # First

    One two three.

    <!-- chapter: Second -->
    # Second

    Four five.

    ## Later

    Six seven eight.
    """

    /// The stand-in bytes of an original take.
    private static let takeBytes = Data("caff stand-in".utf8)

    /// Writes `text` as a file named `name` in a sandbox folder of its own,
    /// for an import to read.
    private func writeSource(named name: String, _ text: String) throws -> URL {
        let file = try makeSandboxDirectory("Export Source").appendingPathComponent(name)
        try Data(text.utf8).write(to: file)
        return file
    }

    /// Puts a transcript and an original take in `book`'s package, as the
    /// transcription and the recording code would, and, when `text` is
    /// given, the transcript's text as its content.md.
    private func addExtraFiles(to book: Book, includingText text: String?) throws {
        let package = book.tmbDirectory
        try Data(#"{"segments":[]}"#.utf8).write(to: TextMouthPaths.transcriptPath(in: package))
        try Self.takeBytes.write(to: package.appendingPathComponent(BookOrigin.originalTakeFileName))
        if let text {
            try Data(text.utf8).write(to: MarkdownCacheService.cacheURL(for: book))
        }
    }

    /// An audiobook of one WAVE file whose audio the editor has edited: its
    /// original kept by the engine's own call (`AudioEditPackage.keepOriginal`),
    /// then the book's file written again, longer, as a saved edit does.
    /// Returns the book and its kept original.
    private func makeEditedAudiobook(in world: IntegrationWorld) throws -> (book: Book, original: URL) {
        let source = try makeSandboxDirectory("Export Edited Source").appendingPathComponent("Weir Survey.wav")
        try AudioTestFixtures.writeSilence(to: source, duration: 1)
        let book = try world.importBook(from: source)
        let file = try XCTUnwrap(AudioEditPackage.path(of: book.bookFileURL, in: book.tmbDirectory))
        let original = try AudioEditPackage.keepOriginal(ofAudioFile: file, inPackage: book.tmbDirectory, at: Date())
        try AudioTestFixtures.writeSilence(to: book.bookFileURL, duration: 2)
        return (book, book.tmbDirectory.appendingPathComponent(original.file))
    }

    /// The size of the file at `url`.
    private func byteCount(of url: URL) throws -> Int64 {
        try XCTUnwrap(FileStamp(of: url)?.byteCount)
    }

    /// An access that calls `dataless` dataless and refuses their reads,
    /// as a sync service's evicted files are.
    private static func cloud(dataless: [URL]) -> MaintenanceFileAccess {
        let paths = Set(dataless.map(\.standardizedFileURL.path))
        return MaintenanceFileAccess(
            isDataless: { paths.contains($0.standardizedFileURL.path) },
            refusesRead: { paths.contains($0.standardizedFileURL.path) }
        )
    }

    /// An audiobook's index whose chapters each start in a file and may
    /// play clips of others: (title, file, the files of its clips).
    private static func audioIndex(chapters: [(title: String, file: String, clips: [String])]) -> BookContentIndex {
        BookContentIndex(
            version: BookContentIndex.currentVersion,
            kind: .audio,
            format: .audio,
            generatedAt: Date(timeIntervalSince1970: 0),
            totalWordCount: 0,
            totalCharacterCount: 0,
            totalAudioDuration: nil,
            audioLayout: .segmented,
            chapters: chapters.enumerated().map { number, chapter in
                BookContentChapterIndex(
                    chapterIndex: number,
                    title: chapter.title,
                    startCharacterOffset: 0,
                    characterCount: 0,
                    wordCount: 0,
                    headings: [],
                    audio: BookContentAudioChapterIndex(
                        relativeFilePath: chapter.file,
                        startTime: 0,
                        duration: 1,
                        clips: chapter.clips.isEmpty ? nil : chapter.clips.map {
                            BookContentAudioClipIndex(relativeFilePath: $0, startTime: 0, duration: 1)
                        }
                    )
                )
            }
        )
    }
}
