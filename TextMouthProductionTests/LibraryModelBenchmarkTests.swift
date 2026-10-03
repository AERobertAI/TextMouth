import Combine
import XCTest
@testable import TextMouth

/// Benchmarks for the library model's performance items in
/// TODO-2026-09-04.md (PERF10, PERF11, PERF12, PERF07). PERF29's measured
/// the refresh tick (6 publishes per idle minute) and went with it; the
/// test that rows follow live positions without a tick is in
/// LiveReadingPositionsTests.
///
/// Each one measures what its item costs on a generated library the size
/// of the developer's (643 books in 38 folders, `LibraryBenchmarkFixture`)
/// and prints every figure on a line starting "PERFMODEL:", for the test
/// log. Counts are asserted, because they follow from the code alone; times
/// are only printed, because other builds share the machine.
@MainActor
final class LibraryModelBenchmarkTests: XCTestCase {

    // MARK: - PERF10: Deriving the List

    /// How often one update of the library makes a Library window derive its
    /// list, and what a window's reads of the list cost per update.
    ///
    /// LibraryView's body reads its list eight times per pass: the summary
    /// bar and the two focus checks read the books shown (`displayedBooks`),
    /// and the count header, the rotor, the selection, the rows, and the
    /// import button's focus check read them as the search narrows them
    /// (`filteredBooks`). Each read that filters and sorts the library
    /// builds a list of its own, so the lists built in the body pass after
    /// an update count that update's derivations.
    ///
    /// Before PERF10 every read derived: 8 lists per update, a reading
    /// position's included (Debug: Date Added 6.7 ms, Title 86.6 ms, Author
    /// 83.7 ms, File Size 295.5 ms per update). Now the model keeps each
    /// list: a reading position refreshes the kept list's values without
    /// deriving it, and a moved book derives it once.
    func testListDerivationsPerLibraryUpdate() throws {
        let filesFolder = try LibraryBenchmarkFixture.makeFilesFolder(for: self)
        let model = LibraryViewModel(initializeServices: false)
        model.library = try LibraryBenchmarkFixture.library(filesIn: filesFolder)
        let allItems = LibraryLocation(category: .allItems, folderPath: "")

        for (field, ascending) in Self.measuredSorts {
            // Set on the library itself: the model's own setter would save
            // this generated library over the sandbox's index.
            model.library.setSortSetting(
                FolderSortSetting(sortField: field, sortAscending: ascending),
                for: allItems.sortSettingsKey
            )
            let sortName = model.sortState(at: allItems).titleFragment

            // Read once, so the sort just chosen is derived and kept.
            _ = Self.bodyPassReads(of: model, at: allItems)

            // A reading position: a change no list depends on.
            LibraryBenchmarkFixture.moveReadingPosition(in: model)
            var derivations = model.listCache.derivationCount
            let positionLists = Self.listsBuilt(by: Self.bodyPassReads(of: model, at: allItems))
            let positionDerivations = model.listCache.derivationCount - derivations
            let positionTime = LibraryBenchmarkClock.medianMilliseconds(runs: 5) {
                LibraryBenchmarkFixture.moveReadingPosition(in: model)
                _ = Self.bodyPassReads(of: model, at: allItems)
            }
            // A book moved to another folder: a change the lists follow.
            LibraryBenchmarkFixture.moveOneBook(in: model)
            derivations = model.listCache.derivationCount
            let membershipLists = Self.listsBuilt(by: Self.bodyPassReads(of: model, at: allItems))
            let membershipDerivations = model.listCache.derivationCount - derivations
            let membershipTime = LibraryBenchmarkClock.medianMilliseconds(runs: 5) {
                LibraryBenchmarkFixture.moveOneBook(in: model)
                _ = Self.bodyPassReads(of: model, at: allItems)
            }

            LibraryBenchmarkClock.report(
                "PERF10 All Items by \(sortName), a reading position update",
                positionTime,
                note: "\(positionLists) list built by \(Self.readsPerBodyPass) reads, \(positionDerivations) derivations"
            )
            LibraryBenchmarkClock.report(
                "PERF10 All Items by \(sortName), a book moved",
                membershipTime,
                note: "\(membershipLists) list built by \(Self.readsPerBodyPass) reads, \(membershipDerivations) derivation"
            )
            // One list per update, shared by every read: a position only
            // refreshes the kept list's values; a moved book derives it once.
            XCTAssertEqual(positionLists, 1, sortName)
            XCTAssertEqual(positionDerivations, 0, sortName)
            XCTAssertEqual(membershipLists, 1, sortName)
            XCTAssertEqual(membershipDerivations, 1, sortName)
        }

        // A derivation by File Size once its sizes are kept, and a read.
        let oneDerivation = LibraryBenchmarkClock.medianMilliseconds(runs: 9) {
            LibraryBenchmarkFixture.moveOneBook(in: model)
            _ = Self.unsearchedRead(of: model, at: allItems)
        }
        let oneRead = LibraryBenchmarkClock.medianMilliseconds(runs: 9) {
            _ = Self.unsearchedRead(of: model, at: allItems)
        }
        LibraryBenchmarkClock.report("PERF10 one derivation of All Items by File Size Descending", oneDerivation)
        LibraryBenchmarkClock.report("PERF10 one kept read of All Items by File Size Descending", oneRead)
        XCTAssertEqual(
            model.listCache.fileMeasurementCount,
            model.library.books.count,
            "every package was measured once, however many derivations followed"
        )
    }

    // MARK: - PERF11: Live Reading Positions

    /// How many times a minute of listening publishes the library model,
    /// which re-renders every Library window's list and every reader
    /// window's root, and what the model's own work costs.
    ///
    /// A playing reader reports its cursor about once a second and writes a
    /// checkpoint every 30 seconds (`PlaybackCheckpointPolicy`). Before
    /// PERF11 each live report set the book's row in the library, copying
    /// every row and publishing the model: 60 publishes per listening
    /// minute (Debug: 63.8 ms of the model's own work). Now live reports go
    /// to `livePositions`, which redraws only the book's row and the
    /// summary bar, and only the two checkpoints publish the library.
    func testLibraryPublishesPerListeningMinute() throws {
        let model = LibraryViewModel(initializeServices: false)
        model.library = try LibraryBenchmarkFixture.library()
        let bookID = model.library.books[model.library.books.count / 2].id
        let entry = model.livePositions.entry(for: bookID)
        let otherEntry = model.livePositions.entry(for: model.library.books[0].id)
        var publishes = 0
        var rowPublishes = 0
        var otherRowPublishes = 0
        let subscriptions = [
            model.objectWillChange.sink { publishes += 1 },
            entry.objectWillChange.sink { rowPublishes += 1 },
            otherEntry.objectWillChange.sink { otherRowPublishes += 1 }
        ]
        defer { subscriptions.forEach { $0.cancel() } }

        let minute = LibraryBenchmarkClock.medianMilliseconds(runs: 1) {
            Self.listen(seconds: 60, to: bookID, in: model)
        }

        LibraryBenchmarkClock.report("PERF11 library publishes per listening minute", count: publishes)
        LibraryBenchmarkClock.report("PERF11 the playing book's row redraws per listening minute", count: rowPublishes)
        LibraryBenchmarkClock.report("PERF11 the model's own work per listening minute", minute, note: "643 books")
        XCTAssertEqual(publishes, 2, "only the two checkpoints publish the library")
        XCTAssertEqual(rowPublishes, 58, "one per live report")
        XCTAssertEqual(otherRowPublishes, 0, "another book's row redrew")
    }

    /// Reports `seconds` seconds of listening to `bookID` as a playing
    /// reader does: a live position each second, and on every 30th second a
    /// checkpoint instead, of which this sets what changes in memory (the
    /// row's position, as `persistReadingPosition` sets it before saving).
    static func listen(seconds: Int, to bookID: UUID, in model: LibraryViewModel) {
        for second in 1...seconds {
            let offset = second * 15
            let position = ReadingPosition(chapterIndex: 0, characterOffset: offset, globalCharacterOffset: offset)
            if second % 30 == 0 {
                model.library.updateReadingPosition(bookID: bookID, position: position)
            } else {
                model.updateLiveReadingPosition(bookID: bookID, position: position)
            }
        }
    }

    // MARK: - Reading the List as LibraryView Does

    /// The sorts the list benchmark measures: the developer's saved sort
    /// (Date Added, newest first), then Title, Author, and File Size.
    static let measuredSorts: [(LibrarySortField, Bool)] = [
        (.dateAdded, false), (.title, true), (.author, true), (.fileSize, false)
    ]

    /// How many times one LibraryView body pass reads its list.
    static let readsPerBodyPass = 8

    /// The search LibraryView's searched reads use while nothing is typed.
    static let noSearch = ""

    /// The books LibraryView shows at `location` before a search narrows
    /// them, read as its `displayedBooks` reads them.
    static func unsearchedRead(of model: LibraryViewModel, at location: LibraryLocation) -> [Book] {
        model.displayedBooks(at: location)
    }

    /// The books LibraryView shows at `location` narrowed by `search`, read
    /// as its `filteredBooks` reads them.
    static func searchedRead(of model: LibraryViewModel, at location: LibraryLocation, search: String) -> [Book] {
        model.displayedBooks(at: location, matching: search)
    }

    /// One body pass's reads, in LibraryView's mix: four of the books shown
    /// and four as the (empty) search narrows them. Returns each read's
    /// result, so a caller can check what the reads saw.
    static func bodyPassReads(of model: LibraryViewModel, at location: LibraryLocation) -> [[Book]] {
        (0..<readsPerBodyPass / 2).map { _ in unsearchedRead(of: model, at: location) }
            + (0..<readsPerBodyPass / 2).map { _ in searchedRead(of: model, at: location, search: noSearch) }
    }

    /// How many lists `reads` were built as: reads handed the same array
    /// share its storage, so each distinct storage is one list built. The
    /// reads are all alive here, so no storage can have been reused.
    static func listsBuilt(by reads: [[Book]]) -> Int {
        Set(reads.map { read in
            read.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        }).count
    }
}

// MARK: - The Generated Library

/// A generated library the size of the developer's: 643 books in 38
/// folders (six top-level folders, five subfolders in each, and two deeper
/// ones), with twelve books at the root. Titles and authors have realistic
/// lengths, books were added over two years, two in three have been opened
/// and have a reading position, and the first top-level folder is kept in
/// manual order. A seeded generator (the parser tests' SplitMix64) makes the
/// same library every time.
enum LibraryBenchmarkFixture {
    /// The number of books, as in the developer's library.json.
    static let bookCount = 643
    /// Books placed at the root of the library.
    static let rootBookCount = 12

    /// The top-level folders; the first holds about a fifth of the books.
    static let topLevelFolders = ["Science Fiction", "Essays", "History", "Poetry", "Reference", "Travel"]
    /// The subfolders made inside each top-level folder.
    static let subfolderNames = ["Anthologies", "Classics", "Collected Works", "Novellas", "Short Fiction"]

    /// Words titles are made from.
    private static let titleWords = [
        "Harbor", "Ledger", "Saltworks", "Tramline", "Orchard", "Ferry", "Granary", "Kiln", "Atlas",
        "Canal", "Bramble", "Lantern", "Quarry", "Weir", "Signal", "Junction", "Almanac", "Cartographer",
        "Foundry", "Meridian", "Embassy", "Parish", "Observatory", "Tannery", "Viaduct", "Courier",
        "Ballast", "Furlong", "Gazetteer", "Hinterland", "Isthmus", "Keel", "Larder", "Mill", "Nave",
        "Oxbow", "Pantry", "Rookery", "Sextant", "Threshold", "Upland", "Vestry", "Wharf", "Yardarm"
    ]
    /// Connecting words that make some titles longer.
    private static let titleJoiners = ["of the", "and the", "beyond the", "under the", "for a", "at"]
    /// Given names authors are made from.
    private static let givenNames = [
        "Odile", "Tobiah", "Henrike", "Anselm", "Wilhelmina", "Casimir", "Ottoline", "Benedek", "Ruairi",
        "Ines", "Bartosz", "Leocadia", "Florin", "Signe", "Dagny", "Emeric", "Philippa", "Teodor",
        "Marguerite", "Ingvar", "Rosalind", "Augustin", "Yevgenia", "Lorcan"
    ]
    /// Family names authors are made from.
    private static let familyNames = [
        "Halvorsen", "Okonkwo", "Varga", "Lindqvist", "Abernethy", "Castellanos", "Petrakis", "Ferreira",
        "Nakashima", "Dunmore", "Kowalczyk", "Achterberg", "Mbeki", "Szabo", "Rautio", "Quarles",
        "Delacroix", "Ishikawa", "Mendelsohn", "Oyelaran", "Van Rensburg", "Thorvaldsen"
    ]

    /// Every folder path of the generated library: the top-level folders,
    /// their subfolders, and two deeper ones, 38 in all.
    static var folderPaths: [String] {
        var paths: [String] = []
        for top in topLevelFolders {
            paths.append(top)
            paths.append(contentsOf: subfolderNames.map { "\(top)/\($0)" })
        }
        paths.append("Science Fiction/Classics/Golden Age")
        paths.append("History/Collected Works/Letters")
        return paths
    }

    /// The generated library. With `filesIn`, each book's file is a package
    /// folder holding one file of a few kilobytes, so File Size sorts
    /// measure real files.
    static func library(bookCount: Int = bookCount, filesIn folder: URL? = nil) throws -> Library {
        var generator = SeededGenerator(state: 0x5EED_0643)
        let folders = folderPaths
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var books: [Book] = []
        books.reserveCapacity(bookCount)
        for number in 0..<bookCount {
            let folderPath = number < rootBookCount
                ? ""
                : folders[skewedIndex(folders.count, using: &generator)]
            let id = UUID(uuid: uuidBytes(number))
            var filePath = "/nonexistent/benchmark/\(number).epub"
            if let folder {
                let package = folder.appendingPathComponent("Book \(number).tmb", isDirectory: true)
                try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
                let file = package.appendingPathComponent("book.epub")
                try Data(count: 1_024 + Int(generator.next() % 8_192)).write(to: file)
                filePath = package.path
            }
            let opened = generator.next() % 3 != 0
            let totalCharacters = 50_000 + Int(generator.next() % 900_000)
            var book = Book(
                id: id,
                title: title(using: &generator),
                author: author(using: &generator),
                format: .epub,
                filePath: filePath,
                md5Hash: "benchmark-\(number)",
                folderPath: folderPath,
                dateAdded: start.addingTimeInterval(Double(number) * 97_000 + Double(generator.next() % 50_000)),
                lastOpened: opened ? start.addingTimeInterval(Double(generator.next() % 60_000_000)) : nil,
                totalWordCount: totalCharacters / 6,
                totalCharacterCount: totalCharacters,
                tmbDirectoryName: "Book \(number).tmb"
            )
            if opened {
                let offset = Int(generator.next() % UInt64(totalCharacters))
                book.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: offset, globalCharacterOffset: offset)
            }
            books.append(book)
        }
        // The first top-level folder is kept in manual order.
        let manualFolder = topLevelFolders[0]
        var position = 0
        for index in books.indices where books[index].folderPath == manualFolder {
            books[index].manualSortOrder = position
            position += 1
        }
        let library = Library(
            books: books,
            folders: folders.map { BookFolder(name: ($0 as NSString).lastPathComponent, parentPath: ($0 as NSString).deletingLastPathComponent) }
        )
        return library
    }

    /// A temporary folder for the generated books' files, removed when
    /// `testCase` ends.
    static func makeFilesFolder(for testCase: XCTestCase) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryBenchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// Moves the reading position of the library's middle book a little,
    /// as a reader's checkpoint does: a change no list depends on.
    @MainActor
    static func moveReadingPosition(in model: LibraryViewModel) {
        let index = model.library.books.count / 2
        let offset = (model.library.books[index].readingPosition?.characterOffset ?? 0) + 1_000
        model.library.books[index].readingPosition = ReadingPosition(
            chapterIndex: 0,
            characterOffset: offset,
            globalCharacterOffset: offset
        )
    }

    /// Moves one book to the next top-level folder, a change every list
    /// showing either folder, and All Items' folder counts, depend on.
    @MainActor
    static func moveOneBook(in model: LibraryViewModel) {
        let index = model.library.books.count / 3
        let current = model.library.books[index].folderPath
        let next = topLevelFolders[((topLevelFolders.firstIndex(of: current) ?? -1) + 1) % topLevelFolders.count]
        model.library.books[index].folderPath = next
    }

    // MARK: Generating

    /// A folder index weighted toward the first folders, so folder sizes
    /// vary as a real library's do.
    private static func skewedIndex(_ count: Int, using generator: inout SeededGenerator) -> Int {
        let a = Int(generator.next() % UInt64(count))
        let b = Int(generator.next() % UInt64(count))
        return min(a, b)
    }

    /// A title of one to four words, some joined by a short phrase.
    private static func title(using generator: inout SeededGenerator) -> String {
        let first = titleWords[Int(generator.next() % UInt64(titleWords.count))]
        let second = titleWords[Int(generator.next() % UInt64(titleWords.count))]
        switch generator.next() % 4 {
        case 0: return first
        case 1: return "\(first) \(second)"
        case 2: return "The \(first) \(titleJoiners[Int(generator.next() % UInt64(titleJoiners.count))]) \(second)"
        default: return "\(first) \(titleJoiners[Int(generator.next() % UInt64(titleJoiners.count))]) \(second), Volume \(generator.next() % 9 + 1)"
        }
    }

    /// An author's name, given name then family name.
    private static func author(using generator: inout SeededGenerator) -> String {
        let given = givenNames[Int(generator.next() % UInt64(givenNames.count))]
        let family = familyNames[Int(generator.next() % UInt64(familyNames.count))]
        return "\(given) \(family)"
    }

    /// The bytes of a stable book ID for `number`, so runs compare alike.
    private static func uuidBytes(_ number: Int) -> uuid_t {
        let value = UInt32(truncatingIfNeeded: number)
        return (0xB0, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00,
                UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value))
    }
}

// MARK: - Timing

/// Times work for the benchmarks and prints what it measured.
enum LibraryBenchmarkClock {
    /// Runs `body` `runs` times and returns the median time in milliseconds.
    static func medianMilliseconds(runs: Int, _ body: () throws -> Void) rethrows -> Double {
        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<max(1, runs) {
            let elapsed = try clock.measure(body)
            samples.append(Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    /// Prints one measurement on a "PERFMODEL:" line.
    static func report(_ name: String, _ milliseconds: Double, note: String = "") {
        print("PERFMODEL: \(name): \(String(format: "%.3f", milliseconds)) ms\(note.isEmpty ? "" : " (\(note))")")
    }

    /// Prints one count on a "PERFMODEL:" line.
    static func report(_ name: String, count: Int, note: String = "") {
        print("PERFMODEL: \(name): \(count)\(note.isEmpty ? "" : " (\(note))")")
    }
}
