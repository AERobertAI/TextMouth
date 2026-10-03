import XCTest
@testable import TextMouth

/// The working copy an open audiobook in a cloud library plays from (FR02):
/// the clone of its package, how the book's files map into it, the sweep of
/// copies a crash left behind, the copy's removal, when no copy is made, and
/// the checks that a book's files are on this Mac.
final class ReaderWorkingCopyTests: XCTestCase {

    // MARK: - Making a Copy

    /// A package is cloned whole into a folder of its own, named after the
    /// book, under the package's own name: every file holds what the
    /// package's does, and the package itself is untouched.
    func testCopyClonesThePackageIntoAFolderOfItsOwn() throws {
        let files = ["bookInfo.json": "{}", "Tracks/01.wav": "first track", "Tracks/02.wav": "second track"]
        let fixture = try makeFixture(files: files)

        let result = fixture.copies.makeCopy(of: fixture.package, isDataless: Self.nothingInTheCloud)

        let copy = try XCTUnwrap(result.copy, "No copy was made: \(result)")
        XCTAssertEqual(Self.path(copy.folder.deletingLastPathComponent()), Self.path(fixture.copiesFolder))
        XCTAssertTrue(
            copy.folder.lastPathComponent.hasPrefix("\(fixture.package.bookID.uuidString)-"),
            copy.folder.lastPathComponent
        )
        XCTAssertEqual(Self.path(copy.root), Self.path(copy.folder.appendingPathComponent("Shoreline.tmb")))
        XCTAssertEqual(Self.path(copy.source), Self.path(fixture.package.url))
        for (name, text) in files {
            XCTAssertEqual(try String(contentsOf: copy.root.appendingPathComponent(name), encoding: .utf8), text, name)
            XCTAssertEqual(
                try String(contentsOf: fixture.package.url.appendingPathComponent(name), encoding: .utf8),
                text,
                "The package changed: \(name)"
            )
        }
    }

    /// An old book kept as a single file outside any package is copied
    /// under its own name, so the copy keeps the extension AVFoundation goes
    /// by, and the book's file maps to that copy.
    func testSingleFileOutsideAPackageKeepsItsName() throws {
        let fixture = try makeFixture(files: [:])
        let file = fixture.library.appendingPathComponent("Harbour Lights.m4a")
        try Data("audio".utf8).write(to: file)
        let package = BookPackage(bookID: UUID(), url: file, isPackage: false, isAudio: true)

        let copy = try XCTUnwrap(fixture.copies.makeCopy(of: package, isDataless: Self.nothingInTheCloud).copy)

        XCTAssertEqual(copy.root.lastPathComponent, "Harbour Lights.m4a")
        XCTAssertEqual(Self.path(copy.location(of: file)), Self.path(copy.root))
        XCTAssertEqual(try String(contentsOf: copy.root, encoding: .utf8), "audio")
    }

    /// Removing a copy deletes its folder and everything in it.
    func testRemovingACopyDeletesItsFolder() throws {
        let fixture = try makeFixture(files: ["Tracks/01.wav": "track"])
        let copy = try XCTUnwrap(fixture.copies.makeCopy(of: fixture.package, isDataless: Self.nothingInTheCloud).copy)

        try copy.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.package.url.path), "The package went too")
    }

    // MARK: - The Sweep

    /// The session's first copy is made only after every copy a crash left
    /// behind is deleted; later copies delete nothing, so a copy another
    /// reader plays from is never swept away.
    func testOnlyTheSessionsFirstCopySweepsAwayLeftovers() throws {
        let fixture = try makeFixture(files: ["Tracks/01.wav": "track"])
        let fileManager = FileManager.default
        let leftoverCopy = fixture.copiesFolder.appendingPathComponent("leftover-copy/Old.tmb", isDirectory: true)
        try fileManager.createDirectory(at: leftoverCopy, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: leftoverCopy.appendingPathComponent("01.wav"))
        try Data("stray".utf8).write(to: fixture.copiesFolder.appendingPathComponent("stray file"))

        let first = try XCTUnwrap(fixture.copies.makeCopy(of: fixture.package, isDataless: Self.nothingInTheCloud).copy)

        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: fixture.copiesFolder.path), [first.folder.lastPathComponent])

        // Another reader's copy, made after the sweep, must survive the
        // next copy.
        let otherReadersCopy = fixture.copiesFolder.appendingPathComponent("other-reader", isDirectory: true)
        try fileManager.createDirectory(at: otherReadersCopy, withIntermediateDirectories: true)
        let second = try XCTUnwrap(fixture.copies.makeCopy(of: fixture.package, isDataless: Self.nothingInTheCloud).copy)

        XCTAssertEqual(
            Set(try fileManager.contentsOfDirectory(atPath: fixture.copiesFolder.path)),
            [first.folder.lastPathComponent, second.folder.lastPathComponent, "other-reader"]
        )
        XCTAssertNotEqual(first.folder, second.folder)
    }

    // MARK: - No Copy

    /// A clone that fails leaves nothing behind, and the book plays from
    /// its package.
    func testFailedCloneLeavesNothingBehind() throws {
        let fixture = try makeFixture(
            files: ["Tracks/01.wav": "track"],
            clone: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        )

        let result = fixture.copies.makeCopy(of: fixture.package, isDataless: Self.nothingInTheCloud)

        guard case .skipped(let reason) = result else {
            return XCTFail("A copy was made: \(result)")
        }
        XCTAssertTrue(reason.hasPrefix("cloning failed"), reason)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.copiesFolder.path), [])
    }

    /// A clone refused because a file was only in the cloud is skipped like
    /// any failed clone: the copy is a safeguard, and the book's own reads
    /// decide whether it must be downloaded again.
    func testRefusedCloneIsSkipped() throws {
        let fixture = try makeFixture(
            files: ["Tracks/01.wav": "track"],
            clone: { _, _ in throw LocalBookFiles.downloadRefusal }
        )

        let result = fixture.copies.makeCopy(of: fixture.package, isDataless: Self.nothingInTheCloud)

        XCTAssertNil(result.copy)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.copiesFolder.path), [])
    }

    /// A clone holding a file whose content is only in the cloud would hold
    /// nothing to play, so it is deleted and skipped.
    func testCloneHoldingAFileOnlyInTheCloudIsSkipped() throws {
        let fixture = try makeFixture(files: ["Tracks/01.wav": "track"])
        let copiesPath = Self.path(fixture.copiesFolder)

        let result = fixture.copies.makeCopy(of: fixture.package, isDataless: { url in
            Self.path(url).hasPrefix(copiesPath) && url.lastPathComponent == "01.wav"
        })

        XCTAssertNil(result.copy)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.copiesFolder.path), [])
    }

    /// A book on another volume than the Working Copies folder is never
    /// copied: the copy could not be a clone, and would take as much space
    /// and time as the book. (/dev is a volume of its own.)
    func testBookOnAnotherVolumeIsNotCopied() throws {
        let clones = CloneCounter()
        let fixture = try makeFixture(files: [:], clone: { _, _ in clones.count() })
        let elsewhere = BookPackage(
            bookID: UUID(),
            url: URL(fileURLWithPath: "/dev/null"),
            isPackage: false,
            isAudio: true
        )

        let result = fixture.copies.makeCopy(of: elsewhere, isDataless: Self.nothingInTheCloud)

        XCTAssertEqual(result, .skipped("the book is on another volume"))
        XCTAssertEqual(clones.calls, 0)
        XCTAssertFalse(ReaderWorkingCopies.isOnSameVolume(URL(fileURLWithPath: "/dev/null"), as: fixture.copiesFolder))
        XCTAssertTrue(ReaderWorkingCopies.isOnSameVolume(fixture.package.url, as: fixture.copiesFolder))
    }

    // MARK: - Where Each File Plays From

    /// A single-file audiobook's file plays from its copy.
    func testSingleFileBookMapsItsFileIntoTheCopy() {
        let copy = Self.copy(of: "/Library/Fiction/Tidewater.tmb")

        XCTAssertEqual(
            copy.location(of: URL(fileURLWithPath: "/Library/Fiction/Tidewater.tmb/Tidewater.m4b")).path,
            "/Copies/abc/Tidewater.tmb/Tidewater.m4b"
        )
    }

    /// Each chapter file of a multi-file audiobook plays from the same
    /// place in the copy.
    func testMultiFileBookMapsEachChapterFileIntoTheCopy() {
        let copy = Self.copy(of: "/Library/Fiction/Tidewater.tmb")
        let chapters = ["01 Arrival.mp3", "02 The Weir.mp3", "03 Low Water.mp3"].map {
            URL(fileURLWithPath: "/Library/Fiction/Tidewater.tmb/Tracks/\($0)")
        }

        XCTAssertEqual(
            chapters.map { copy.location(of: $0).path },
            [
                "/Copies/abc/Tidewater.tmb/Tracks/01 Arrival.mp3",
                "/Copies/abc/Tidewater.tmb/Tracks/02 The Weir.mp3",
                "/Copies/abc/Tidewater.tmb/Tracks/03 Low Water.mp3",
            ]
        )
    }

    /// A segmented audiobook's audio folder maps into the copy, so every
    /// clip of a chapter, in whichever file, plays from the copy.
    func testSegmentedBookPlaysEveryClipFromTheCopy() throws {
        let copy = Self.copy(of: "/Library/Fiction/Tidewater.tmb")
        let audioFolder = URL(fileURLWithPath: "/Library/Fiction/Tidewater.tmb/audio", isDirectory: true)
        let segment = try XCTUnwrap(AudioSegment(
            title: "The Weir",
            clips: [
                AudioClip(file: "part1.mp3", startTime: 10, endTime: 20),
                AudioClip(file: "part2.mp3", startTime: 0, endTime: 5),
            ]
        ))

        let chain = AudioClipChain(segment: segment, folder: copy.location(of: audioFolder))

        XCTAssertEqual(
            chain.clips.map(\.url.path),
            ["/Copies/abc/Tidewater.tmb/audio/part1.mp3", "/Copies/abc/Tidewater.tmb/audio/part2.mp3"]
        )
    }

    /// The package itself maps to the copy's root; anything outside the
    /// package, a neighbour whose name only begins the same way included,
    /// plays from where it is.
    func testOnlyThePackagesOwnFilesMapIntoTheCopy() {
        let copy = Self.copy(of: "/Library/Fiction/Tidewater.tmb")

        XCTAssertEqual(copy.location(of: URL(fileURLWithPath: "/Library/Fiction/Tidewater.tmb")).path, "/Copies/abc/Tidewater.tmb")
        for outside in ["/Library/Fiction/Other.tmb/Book.m4b", "/Library/Fiction/Tidewater.tmbx/Book.m4b", "/Library/Fiction"] {
            XCTAssertEqual(copy.location(of: URL(fileURLWithPath: outside)).path, outside)
        }
    }

    /// Once the library moves the package, the book's files named where the
    /// package is now map into the copy, which itself stays where it is;
    /// the old place no longer does.
    func testMovedPackageStillMapsIntoTheSameCopy() {
        var copy = Self.copy(of: "/Library/Fiction/Tidewater.tmb")

        copy.sourceMoved(to: URL(fileURLWithPath: "/Library/Shelf/Tidewater.tmb", isDirectory: true))

        XCTAssertEqual(
            copy.location(of: URL(fileURLWithPath: "/Library/Shelf/Tidewater.tmb/Tracks/01.mp3")).path,
            "/Copies/abc/Tidewater.tmb/Tracks/01.mp3"
        )
        XCTAssertEqual(
            copy.location(of: URL(fileURLWithPath: "/Library/Fiction/Tidewater.tmb/Tracks/01.mp3")).path,
            "/Library/Fiction/Tidewater.tmb/Tracks/01.mp3"
        )
        XCTAssertEqual(copy.root.path, "/Copies/abc/Tidewater.tmb")
    }

    // MARK: - Files on This Mac

    /// A package whose files are all on this Mac passes the check.
    func testPackageOnThisMacPassesTheCheck() throws {
        let fixture = try makeFixture(files: ["bookInfo.json": "{}", "Tracks/01.wav": "track"])

        XCTAssertNoThrow(try LocalBookFiles.requireOnThisMac(fixture.package.url, isDataless: Self.nothingInTheCloud))
    }

    /// A package holding a file, or a folder, only in the cloud, or that is
    /// only in the cloud itself, fails the check with the refusal a read
    /// with downloading switched off meets.
    func testPackageWithAnythingOnlyInTheCloudIsRefused() throws {
        let fixture = try makeFixture(files: ["bookInfo.json": "{}", "Tracks/01.wav": "track"])
        let root = fixture.package.url

        for inCloud in ["Tracks/01.wav", "Tracks", ""] {
            let target = Self.path(inCloud.isEmpty ? root : root.appendingPathComponent(inCloud))
            XCTAssertThrowsError(
                try LocalBookFiles.requireOnThisMac(root, isDataless: { Self.path($0) == target }),
                "\(inCloud.isEmpty ? "the package" : inCloud) is only in the cloud"
            ) { error in
                XCTAssertTrue(DatalessFiles.isDownloadRefusal(error), "\(error)")
            }
        }
    }

    /// Hidden files, which a book never reads and a sync service need not
    /// download, are not checked.
    func testHiddenFilesAreNotChecked() throws {
        let fixture = try makeFixture(files: [".DS_Store": "finder", "Tracks/01.wav": "track"])

        XCTAssertNoThrow(try LocalBookFiles.requireOnThisMac(fixture.package.url, isDataless: {
            $0.lastPathComponent == ".DS_Store"
        }))
    }

    /// A chapter's file is on this Mac, only in the cloud, or missing, as
    /// one look at it finds, without reading it.
    func testAvailabilityOfAChaptersFile() throws {
        let fixture = try makeFixture(files: ["Tracks/01.wav": "track"])
        let file = fixture.package.url.appendingPathComponent("Tracks/01.wav")

        XCTAssertEqual(LocalBookFiles.availability(of: file, isDataless: Self.nothingInTheCloud), .onThisMac)
        XCTAssertEqual(LocalBookFiles.availability(of: file, isDataless: { _ in true }), .inCloud)
        XCTAssertEqual(
            LocalBookFiles.availability(of: fixture.package.url.appendingPathComponent("Tracks/09.wav"), isDataless: { _ in true }),
            .missing
        )
    }

    // MARK: - Fixtures

    /// A package of this test's own, the Working Copies folder its copies
    /// go in, and the copies made there.
    private struct Fixture {
        /// The folder standing for the library, holding the package.
        let library: URL
        /// The package, "Shoreline.tmb".
        let package: BookPackage
        /// The Working Copies folder, not made yet.
        let copiesFolder: URL
        /// Copies made in `copiesFolder`.
        let copies: ReaderWorkingCopies
    }

    /// A package named "Shoreline.tmb" holding `files` (paths inside it, and
    /// their text) in a sandbox folder removed when the test ends, with
    /// copies made by `clone` in a Working Copies folder beside it.
    private func makeFixture(
        files: [String: String],
        clone: ReaderWorkingCopies.Cloner? = nil
    ) throws -> Fixture {
        let sandbox = try makeSandboxDirectory("ReaderWorkingCopy")
        let library = sandbox.appendingPathComponent("Library", isDirectory: true)
        let packageURL = library.appendingPathComponent("Shoreline.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        for (name, text) in files {
            let file = packageURL.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        let copiesFolder = sandbox.appendingPathComponent("Working Copies", isDirectory: true)
        let copies = clone.map { ReaderWorkingCopies(folder: copiesFolder, clone: $0) }
            ?? ReaderWorkingCopies(folder: copiesFolder)
        return Fixture(
            library: library,
            package: BookPackage(bookID: UUID(), url: packageURL, isPackage: true, isAudio: true),
            copiesFolder: copiesFolder,
            copies: copies
        )
    }

    /// A copy of the package at `packagePath`, at "/Copies/abc", for the
    /// mapping tests, which touch no file.
    private static func copy(of packagePath: String) -> ReaderWorkingCopy {
        let source = URL(fileURLWithPath: packagePath, isDirectory: true)
        let folder = URL(fileURLWithPath: "/Copies/abc", isDirectory: true)
        return ReaderWorkingCopy(
            folder: folder,
            root: folder.appendingPathComponent(source.lastPathComponent, isDirectory: true),
            source: source
        )
    }

    /// The dataless check of a Mac where everything is downloaded.
    private static let nothingInTheCloud: @Sendable (URL) -> Bool = { _ in false }

    /// `url`'s path with symbolic links resolved, so the sandbox's
    /// /var and /private/var spellings compare equal.
    private static func path(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Counts the clones a test's cloner was asked for, from any thread.
    private final class CloneCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var made = 0

        /// How many clones were asked for.
        var calls: Int { lock.withLock { made } }

        /// Counts one.
        func count() {
            lock.withLock { made += 1 }
        }
    }
}
