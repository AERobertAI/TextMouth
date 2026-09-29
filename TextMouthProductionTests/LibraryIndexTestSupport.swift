import XCTest
@testable import TextMouth

/// The ways a library index fixture can be damaged (TODO S01).
enum LibraryIndexDamage {
    /// Cut off halfway, as a crash or a full disk can leave a file.
    case truncated
    /// Well-formed JSON naming a book format this version does not know, as a
    /// newer TextMouth could write.
    case unknownFormat
    /// Intact JSON that cannot be read: its permissions are mode 000.
    case unreadable
}

/// Stages library index fixtures in the hosted test root for one test and
/// puts everything back afterwards.
///
/// The hosted app's own library model uses that same root, so both index
/// locations must end each test exactly as they began. `capture()` flushes
/// pending saves and records both files; `restore()` gives read permission
/// back, resumes index writes, removes the copies preserved during the test,
/// and restores the original bytes (or removes files that did not exist).
struct LibraryIndexSandbox {
    /// `library.json` in the isolated data root.
    let indexURL: URL
    /// The legacy Application Support index, isolated by `TextMouthPaths`.
    let legacyURL: URL
    private let originalIndex: Data?
    private let originalLegacy: Data?
    private let legacyDirectoryExisted: Bool
    private let copiesBefore: Set<URL>

    /// Records the current state. Pending saves are flushed first, so a
    /// debounced write from earlier work cannot land in the middle of a test.
    static func capture() throws -> LibraryIndexSandbox {
        LibraryPersistenceService.flushPendingSave()
        try TextMouthPaths.ensureDirectoryStructure()
        let indexURL = TextMouthPaths.libraryIndexFile
        let legacyURL = try XCTUnwrap(TextMouthPaths.oldLibraryFile)
        return LibraryIndexSandbox(
            indexURL: indexURL,
            legacyURL: legacyURL,
            originalIndex: try? Data(contentsOf: indexURL),
            originalLegacy: try? Data(contentsOf: legacyURL),
            legacyDirectoryExisted: FileManager.default.fileExists(
                atPath: legacyURL.deletingLastPathComponent().path
            ),
            copiesBefore: Set(Self.preservedCopies(of: [indexURL, legacyURL]))
        )
    }

    /// Puts both index locations back as `capture()` found them and ends any
    /// write suspension the test caused.
    func restore() {
        let copies = Self.preservedCopies(of: [indexURL, legacyURL])
        for url in [indexURL, legacyURL] + copies {
            Self.makeReadable(url)
        }
        LibraryPersistenceService.resumeIndexWrites()
        for copy in copies where !copiesBefore.contains(copy) {
            try? FileManager.default.removeItem(at: copy)
        }
        Self.put(originalIndex, at: indexURL)
        Self.put(originalLegacy, at: legacyURL)
        if !legacyDirectoryExisted {
            try? FileManager.default.removeItem(at: legacyURL.deletingLastPathComponent())
        }
    }

    /// Writes an index damaged by `damage` at `url` and returns the bytes on
    /// disk (for `.unreadable`, the bytes behind the removed permission).
    @discardableResult
    func stage(_ damage: LibraryIndexDamage, at url: URL) throws -> Data {
        let bytes = try Self.damagedBytes(damage)
        try place(bytes, at: url)
        if damage == .unreadable {
            XCTAssertEqual(chmod(url.path, 0o000), 0)
            XCTAssertThrowsError(try Data(contentsOf: url), "the fixture must really be unreadable")
        }
        return bytes
    }

    /// Writes `library` as a valid index at `url` and returns its bytes.
    @discardableResult
    func stageValid(_ library: Library, at url: URL) throws -> Data {
        let bytes = try Self.encoded(library)
        try place(bytes, at: url)
        return bytes
    }

    /// Writes `bytes` at `url`, creating its folder and replacing any earlier
    /// file. The legacy index is read only when the current one is absent, so
    /// placing a legacy fixture also removes the current index.
    private func place(_ bytes: Data, at url: URL) throws {
        if url != indexURL {
            try? FileManager.default.removeItem(at: indexURL)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: url, options: .atomic)
    }

    // MARK: - Fixtures

    /// A library whose folders, sort settings, manual order, and reading state
    /// live only in the index: exactly what an unreadable index used to lose.
    static func sampleLibrary() -> Library {
        let shelf = "Recovery Shelf \(UUID().uuidString.prefix(8))"
        let reading = Book(
            title: "Index Recovery Fixture",
            author: "Test Fixture",
            format: .txt,
            filePath: "/nonexistent/index-recovery/reading.txt",
            md5Hash: "index-recovery-\(UUID().uuidString)",
            folderPath: shelf,
            readingPosition: ReadingPosition(chapterIndex: 2, characterOffset: 140),
            bookmarks: [Bookmark(number: 1, chapterIndex: 1, characterOffset: 12, label: "Kept")],
            tmbDirectoryName: "IndexRecoveryReading-\(UUID().uuidString).tmb",
            manualSortOrder: 1
        )
        let unread = Book(
            title: "Second Index Recovery Fixture",
            author: "Test Fixture",
            format: .markdown,
            filePath: "/nonexistent/index-recovery/unread.md",
            md5Hash: "index-recovery-\(UUID().uuidString)",
            folderPath: shelf,
            tmbDirectoryName: "IndexRecoveryUnread-\(UUID().uuidString).tmb",
            manualSortOrder: 0
        )
        return Library(
            books: [reading, unread],
            folders: [BookFolder(name: shelf)],
            folderSortSettings: [
                shelf: FolderSortSetting(sortField: .manual, sortAscending: true),
                "__recent__": .recentDefault
            ]
        )
    }

    /// `library` encoded exactly as `LibraryPersistenceService` writes it.
    static func encoded(_ library: Library) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        return try encoder.encode(library)
    }

    /// The bytes of a sample index damaged by `damage`. An unreadable fixture
    /// keeps intact JSON; `stage` removes its read permission.
    static func damagedBytes(_ damage: LibraryIndexDamage) throws -> Data {
        let intact = try encoded(sampleLibrary())
        switch damage {
        case .truncated:
            return intact.prefix(intact.count / 2)
        case .unknownFormat:
            var index = try XCTUnwrap(JSONSerialization.jsonObject(with: intact) as? [String: Any])
            var books = try XCTUnwrap(index["books"] as? [[String: Any]])
            books[0]["format"] = "mobi"
            index["books"] = books
            return try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted])
        case .unreadable:
            return intact
        }
    }

    /// JSON reserialized with sorted keys, so two encodings of the same index
    /// compare equal whatever order their dictionaries were written in.
    static func canonicalJSON(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: - File Helpers

    /// The copies preserved beside any of `indexes`.
    static func preservedCopies(of indexes: [URL]) -> [URL] {
        indexes.flatMap { LibraryIndexQuarantine.existingCopies(of: $0) }
    }

    /// Gives an unreadable fixture its read permission back. Hard-linked
    /// copies share the permission, so they become readable too.
    static func makeReadable(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            chmod(url.path, 0o644)
        }
    }

    /// The inode number of the item at `url`, read without opening it. An
    /// atomic replacement gives a file a new inode, so an unchanged inode shows
    /// that nothing was written over it.
    static func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value
    }

    /// Writes `data` at `url`, or removes `url` when `data` is nil.
    private static func put(_ data: Data?, at url: URL) {
        if let data {
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension XCTestCase {
    /// Gives a debounced library save (0.5 seconds) time to fire, so a test can
    /// show that a save which must not happen really did not happen.
    func waitPastLibrarySaveDebounce() {
        let elapsed = expectation(description: "Library save debounce interval elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { elapsed.fulfill() }
        wait(for: [elapsed], timeout: 5)
    }
}
