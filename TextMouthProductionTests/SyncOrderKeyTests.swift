import XCTest
@testable import TextMouth

/// The reading list's order keys (FR43): a key between any two, and a new key
/// only for a book that moved.
final class SyncOrderKeyTests: XCTestCase {
    /// Whether `keys` are strictly increasing.
    private func isIncreasing(_ keys: [String]) -> Bool {
        zip(keys, keys.dropFirst()).allSatisfy { $0 < $1 }
    }

    /// A key can be made with no neighbour, or one on either side.
    func testBetweenOpenEnds() {
        let first = SyncOrderKey.between(nil, nil)
        let after = SyncOrderKey.between(first, nil)
        let before = SyncOrderKey.between(nil, first)
        XCTAssertLessThan(first, after)
        XCTAssertLessThan(before, first)
    }

    /// Repeated keys between the same neighbours stay between them and in order.
    func testBetweenRepeatedlyFromOneSide() {
        var low: String? = nil
        let high = SyncOrderKey.between(nil, nil)
        for _ in 0..<200 {
            let key = SyncOrderKey.between(low, high)
            XCTAssertLessThan(key, high)
            if let low { XCTAssertLessThan(low, key) }
            XCTAssertFalse(key.hasSuffix("0"))
            low = key
        }
    }

    /// Keys made again and again just below one key never run out of room.
    func testBetweenRepeatedlyTowardTheLowerKey() {
        var high = SyncOrderKey.between(nil, nil)
        for _ in 0..<100 {
            let key = SyncOrderKey.between(nil, high)
            XCTAssertLessThan(key, high)
            high = key
        }
    }

    /// Keys for a whole list are in order and stay short.
    func testKeysForAWholeList() {
        let keys = SyncOrderKey.keys(count: 750, between: nil, nil)
        XCTAssertEqual(keys.count, 750)
        XCTAssertTrue(isIncreasing(keys))
        XCTAssertLessThanOrEqual(keys.map(\.count).max() ?? 0, 8)
    }

    /// Keys between two neighbours stay between them.
    func testKeysBetweenNeighbours() {
        let low = "V", high = "W"
        let keys = SyncOrderKey.keys(count: 20, between: low, high)
        XCTAssertTrue(isIncreasing([low] + keys + [high]))
    }

    /// Out-of-order bounds give a key above the lower one rather than a trap.
    func testBoundsOutOfOrderDoNotTrap() {
        XCTAssertLessThan("b", SyncOrderKey.between("b", "a"))
    }

    /// Books whose keys already stand in order get none.
    func testAssignChangesNothingForAnOrderedList() {
        let ids = (0..<5).map { _ in UUID() }
        let keys = SyncOrderKey.keys(count: 5, between: nil, nil)
        let existing = Dictionary(uniqueKeysWithValues: zip(ids, keys))
        XCTAssertTrue(SyncOrderKey.assign(order: ids, existing: existing).isEmpty)
    }

    /// One book moved to the front is the only one given a key.
    func testAssignGivesAKeyOnlyToTheMovedBook() {
        let ids = (0..<6).map { _ in UUID() }
        let keys = SyncOrderKey.keys(count: 6, between: nil, nil)
        let existing = Dictionary(uniqueKeysWithValues: zip(ids, keys))
        let moved = [ids[4]] + ids.filter { $0 != ids[4] }
        let made = SyncOrderKey.assign(order: moved, existing: existing)
        XCTAssertEqual(Set(made.keys), [ids[4]])
        XCTAssertLessThan(made[ids[4]] ?? "~", keys[0])
    }

    /// Books added on one side of a kept book get keys that keep the whole list in order.
    func testAssignKeysNewBooksIntoPlace() {
        let kept = (0..<3).map { _ in UUID() }
        let keys = SyncOrderKey.keys(count: 3, between: nil, nil)
        var existing = Dictionary(uniqueKeysWithValues: zip(kept, keys))
        let added = [UUID(), UUID()]
        let order = [added[0], kept[0], added[1], kept[1], kept[2]]
        let made = SyncOrderKey.assign(order: order, existing: existing)
        XCTAssertEqual(Set(made.keys), Set(added))
        existing.merge(made) { _, new in new }
        XCTAssertTrue(isIncreasing(order.compactMap { existing[$0] }))
    }

    /// Whatever the list, assigning leaves every book a key and the list in order.
    func testAssignAlwaysEndsInOrder() {
        var generator = SyncSeededGenerator(seed: 7)
        for _ in 0..<100 {
            let ids = (1...Int.random(in: 1...12, using: &generator)).map { SyncTestFixtures.id($0) }
            // Some books have keys, all different and in no relation to the list's order.
            let pool = SyncOrderKey.keys(count: ids.count, between: nil, nil).shuffled(using: &generator)
            var existing: [UUID: String] = [:]
            for (id, key) in zip(ids, pool) where Bool.random(using: &generator) { existing[id] = key }
            let order = ids.shuffled(using: &generator)
            existing.merge(SyncOrderKey.assign(order: order, existing: existing)) { _, new in new }
            let sorted = order.map { SyncOrderKey.SortKey(key: existing[$0] ?? "", id: $0.uuidString) }
            XCTAssertTrue(zip(sorted, sorted.dropFirst()).allSatisfy { $0 < $1 }, "seed 7")
            XCTAssertTrue(order.allSatisfy { existing[$0] != nil })
        }
    }
}

/// A random number generator that gives the same numbers for the same seed,
/// so a failing case can be run again.
struct SyncSeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    /// A generator that starts from `seed`.
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    /// The next number (SplitMix64).
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
