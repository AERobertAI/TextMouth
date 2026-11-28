import XCTest
@testable import TextMouth

/// The merge's properties (FR43): random changes of two or three devices,
/// delivered in random orders, some twice, give one state everywhere, each
/// value its highest entry's. 300 seeded cases; the seed is in the failure.
final class SyncMergePropertyTests: XCTestCase {
    private typealias Fixtures = SyncTestFixtures

    /// How many random cases each property runs.
    private static let caseCount = 300

    /// A small world of IDs, so that random entries often meet on one key.
    private struct World {
        // Fixed IDs, so a printed seed replays its case.
        let books = (1...3).map { SyncTestFixtures.id($0) }
        let folders = (11...13).map { SyncTestFixtures.id($0) }
    }

    /// A random entry of one of `devices`, over the keys of `world`.
    private func randomEntry(_ world: World, devices: [String], using generator: inout SyncSeededGenerator) -> SyncEntry {
        let book = world.books.randomElement(using: &generator) ?? SyncTestFixtures.id(1)
        let folder = world.folders.randomElement(using: &generator) ?? SyncTestFixtures.id(11)
        let wall = Int64.random(in: 1...8, using: &generator)
        let device = devices.randomElement(using: &generator) ?? "a"
        let byHand = Int.random(in: 0..<6, using: &generator) == 0
        let bookmark = SyncTestFixtures.id(Int.random(in: 21...23, using: &generator))
        let pick = Int.random(in: 0..<10, using: &generator)
        let key: SyncKey, value: JSONValue
        switch pick {
        case 0: (key, value) = (.book(book, .presence), Bool.random(using: &generator) ? .bool(true) : .null)
        case 1, 2: (key, value) = (.book(book, .title), .string("T\(Int.random(in: 0...3, using: &generator))"))
        case 3: (key, value) = (.book(book, .rate), .integer(Int64.random(in: 100...300, using: &generator)))
        case 4: (key, value) = (.bookmark(book: book, id: bookmark), Bool.random(using: &generator) ? .null : SyncValueCoding.json(SyncBookmarkValue(Bookmark(number: 1, chapterIndex: Int.random(in: 0...3, using: &generator), characterOffset: 0))))
        case 5: (key, value) = (.folder(folder, .presence), Bool.random(using: &generator) ? .bool(true) : .null)
        case 6: (key, value) = (.folder(folder, .name), .string(["A", "a", "B"].randomElement(using: &generator) ?? "A"))
        case 7: (key, value) = (.folder(folder, .parent), Bool.random(using: &generator) ? .null : SyncValueCoding.id(world.folders.randomElement(using: &generator)))
        case 8: (key, value) = (.readingList(book: book), Bool.random(using: &generator) ? .null : .string(["A", "M", "V"].randomElement(using: &generator) ?? "V"))
        default: (key, value) = (.book(book, .folder), SyncValueCoding.id(world.folders.randomElement(using: &generator)))
        }
        return SyncEntry(key: key, value: value, stamp: SyncStamp(wall: wall, counter: 0, device: device), byHand: byHand)
    }

    /// Random entries split into batches, each batch delivered in a random order, some of them twice.
    private func deliveries(of entries: [SyncEntry], using generator: inout SyncSeededGenerator) -> [SyncEntry] {
        var delivered = entries.shuffled(using: &generator)
        for entry in entries where Int.random(in: 0..<4, using: &generator) == 0 { delivered.insert(entry, at: Int.random(in: 0...delivered.count, using: &generator)) }
        return delivered
    }

    /// Any order of delivery, with repeats, gives the same registers, and each key holds its highest entry.
    func testOrderOfDeliveryDoesNotMatter() {
        for seed in 0..<UInt64(Self.caseCount) {
            var generator = SyncSeededGenerator(seed: seed)
            let world = World()
            let entries = (0..<Int.random(in: 1...30, using: &generator)).map { _ in randomEntry(world, devices: ["a", "b", "c"], using: &generator) }
            var reference = SyncRegisters()
            reference.merge(entries)
            for _ in 0..<3 {
                var other = SyncRegisters()
                // Batches, as files arrive: each merged on its own.
                var rest = deliveries(of: entries, using: &generator)[...]
                while !rest.isEmpty {
                    let size = Int.random(in: 1...5, using: &generator)
                    other.merge(Array(rest.prefix(size)))
                    rest = rest.dropFirst(size)
                }
                XCTAssertEqual(other, reference, "seed \(seed)")
            }
            // Each key's winner is not outranked by any entry for it.
            for entry in entries {
                if let winner = reference.entries[entry.key] {
                    XCTAssertFalse(entry.outranks(winner), "seed \(seed)")
                } else {
                    XCTFail("seed \(seed): a key has no winner")
                }
            }
        }
    }

    /// Merging again changes nothing, and reports no key.
    func testMergingAgainChangesNothing() {
        for seed in 0..<UInt64(Self.caseCount) {
            var generator = SyncSeededGenerator(seed: seed)
            let world = World()
            let entries = (0..<Int.random(in: 1...30, using: &generator)).map { _ in randomEntry(world, devices: ["a", "b"], using: &generator) }
            var registers = SyncRegisters()
            registers.merge(entries)
            let before = registers
            XCTAssertTrue(registers.merge(entries).isEmpty, "seed \(seed)")
            XCTAssertEqual(registers, before, "seed \(seed)")
        }
    }

    /// Applying the registers is the same however they were delivered, applying again to the result changes nothing more, and no removal takes a change it had not seen.
    func testApplyIsSteadyAndRemovalsRespectLaterChanges() {
        for seed in 0..<UInt64(Self.caseCount) {
            var generator = SyncSeededGenerator(seed: seed)
            let world = World()
            let entries = (0..<Int.random(in: 1...30, using: &generator)).map { _ in randomEntry(world, devices: ["a", "b", "c"], using: &generator) }
            let library = Fixtures.library(books: world.books.map { Fixtures.book(id: $0) })

            var one = SyncRegisters(), two = SyncRegisters()
            one.merge(entries)
            two.merge(deliveries(of: entries, using: &generator))
            let first = SyncMerge.apply(one, to: library, voices: nil)
            let second = SyncMerge.apply(two, to: library, voices: nil)
            XCTAssertEqual(first.library, second.library, "seed \(seed)")
            XCTAssertEqual(first.booksToRemove, second.booksToRemove, "seed \(seed)")
            XCTAssertEqual(first.entriesToRecord, second.entriesToRecord, "seed \(seed)")

            // Once applied, applying again is a no-op for the books and the folders.
            let again = SyncMerge.apply(one, to: first.library, voices: nil)
            XCTAssertEqual(again.library.books, first.library.books, "seed \(seed)")
            XCTAssertEqual(again.library.folders, first.library.folders, "seed \(seed)")

            // A removed book's mark is later than every change of it that is not itself a removal.
            for id in first.booksToRemove {
                let mark = one.entries[.book(id, .presence)]
                XCTAssertEqual(mark?.value, .null, "seed \(seed)")
                for (key, entry) in one.entries where key.bookID == id && key != .book(id, .presence) {
                    if key.marksRemoval(entry.value) { continue }
                    XCTAssertLessThanOrEqual(entry.stamp, mark?.stamp ?? entry.stamp, "seed \(seed)")
                }
            }
            // Folders never exceed the depth limit or share a name under one parent.
            XCTAssertLessThanOrEqual(first.library.folders.map(\.depth).max() ?? 0, BookFolder.maxDepth, "seed \(seed)")
            let paths = first.library.folders.map { $0.fullPath.precomposedStringWithCanonicalMapping.lowercased() }
            XCTAssertEqual(Set(paths).count, paths.count, "seed \(seed)")
        }
    }
}
