import Foundation
import XCTest
@testable import TextMouth

// Tests of `PackContainer`, the one reader of the container that `Strings.pack` and `BrailleTables.pack` are written in
// (FR40). The interface-text tests (InterfaceTextTests) prove it through `Strings.pack`; these read it with a magic and
// a version of their own, so the container cannot lean on that pack's.
//
// Shared with the iPhone's unit bundle (project.yml). They read damaged files on purpose, so they run in trains on GitHub.

final class PackContainerTests: XCTestCase {
    /// The format these tests give their packs: not `Strings.pack`'s, and with limits small enough to cross.
    private static let format = PackContainer.Format(
        magic: Array("TEST".utf8), version: 5, largestCount: 1_000, largestBlobCount: 8, largestRawSize: 1_024
    )

    /// A good pack: two blobs, `lzma` and `bzip2`, whose raw bytes are "one", "two" and "three" with a NUL after each.
    private func sample() -> InterfaceTextPackBytes {
        var bytes = InterfaceTextPackBytes(idCount: 3, blobs: [
            InterfaceTextPackBytes.blob("lzma", entries: ["one", "two", "three"]),
            InterfaceTextPackBytes.blob("bzip2", entries: ["one", "two", "three"], method: InterfaceTextPackBytes.bzip2),
        ])
        bytes.magic = Array("TEST".utf8)
        bytes.version = 5
        return bytes
    }

    /// Opens `bytes` in this test's format.
    private func container(_ bytes: InterfaceTextPackBytes) throws -> PackContainer {
        try PackContainer(data: bytes.data(), format: Self.format)
    }

    /// The header's count, the digest, and each blob's directory entry are what the file says.
    func testTheDirectoryIsRead() throws {
        let opened = try container(sample())
        XCTAssertEqual(opened.count, 3)
        XCTAssertEqual(opened.digest, [UInt8](repeating: 0xAB, count: 32))
        XCTAssertEqual(Set(opened.blobs.keys), ["lzma", "bzip2"])
        XCTAssertEqual(opened.blobs["lzma"]?.method, .lzma)
        XCTAssertEqual(opened.blobs["bzip2"]?.method, .bzip2)
        XCTAssertEqual(opened.blobs["lzma"]?.rawSize, 14)
        XCTAssertEqual(opened.blobs["lzma"]?.count, 3)
    }

    /// Both methods decode to the raw bytes the directory promised.
    func testBothMethodsDecode() throws {
        let opened = try container(sample())
        let expected = Array("one\0two\0three\0".utf8)
        XCTAssertEqual(try opened.decodedBlob(named: "lzma"), expected)
        XCTAssertEqual(try opened.decodedBlob(named: "bzip2"), expected)
    }

    /// An empty blob decodes to nothing, and a blob the pack lacks is a failure.
    func testAnEmptyBlobAndAMissingBlob() throws {
        var bytes = sample()
        bytes.blobs.append(InterfaceTextPackBytes.blob("empty", entries: []))
        let opened = try container(bytes)
        XCTAssertEqual(try opened.decodedBlob(named: "empty"), [])
        XCTAssertThrowsError(try opened.decodedBlob(named: "absent"))
    }

    /// A pack of another format is refused by its magic or its version, whichever it has wrong.
    func testAnotherFormatIsRefused() throws {
        let faults: [(String, (inout InterfaceTextPackBytes) -> Void)] = [
            ("magic", { $0.magic = Array("TMSP".utf8) }), ("version", { $0.version = 6 }), ("flags", { $0.flags = 1 }),
        ]
        for (label, change) in faults {
            var bytes = sample()
            change(&bytes)
            XCTAssertThrowsError(try container(bytes), label) { XCTAssertTrue($0 is PackContainerFailure, label) }
        }
        // `Strings.pack`'s own sample is no pack of these tests' format, and the reverse.
        XCTAssertThrowsError(try container(InterfaceTextPackBytes.sample()))
        XCTAssertThrowsError(try InterfaceTextPack(data: sample().data()))
    }

    /// The format's limits are held: a count, a blob count, and a raw size past them are refused.
    func testTheFormatsLimitsAreHeld() {
        var counted = sample()
        counted.idCount = 1_001
        XCTAssertThrowsError(try container(counted), "a count past the limit")
        var crowded = sample()
        for index in 0..<8 { crowded.blobs.append(InterfaceTextPackBytes.blob("b\(index)", entries: [])) }
        XCTAssertThrowsError(try container(crowded), "more blobs than the limit")
        var bomb = sample()
        bomb.changeFirstBlob { $0.rawSize = 1_025 }
        XCTAssertThrowsError(try container(bomb), "a raw size past the limit")
    }

    /// Each directory fault is a failure, and none traps.
    func testDirectoryFaultsAreRefused() {
        func refused(_ label: String, _ change: (inout InterfaceTextPackBytes) -> Void) {
            var bytes = sample()
            change(&bytes)
            XCTAssertThrowsError(try container(bytes), label)
        }
        refused("an unknown method") { $0.changeFirstBlob { $0.method = 2 } }
        refused("a blob listed twice") { if let first = $0.blobs.first { $0.blobs.append(first) } }
        refused("a blob past the end") { $0.changeFirstBlob { $0.offset = 1_000_000 } }
        refused("a blob inside the directory") { $0.changeFirstBlob { $0.offset = 10 } }
        refused("a name with a space") { $0.changeFirstBlob { $0.name = "a b" } }
        refused("an empty name") { $0.changeFirstBlob { $0.name = "" } }
        // Every proper prefix of a good pack is refused: the last blob ends the file.
        let whole = sample().data()
        for length in 0..<whole.count {
            XCTAssertThrowsError(try PackContainer(data: Data(whole.prefix(length)), format: Self.format), "length \(length)")
        }
    }

    /// A blob whose bytes are not what its directory says is a failure when it is decoded, under both methods.
    func testDamagedBlobsFailWhenDecoded() throws {
        for (name, method) in [("lzma", InterfaceTextPackBytes.lzma), ("bzip2", InterfaceTextPackBytes.bzip2)] {
            let good = InterfaceTextPackBytes.blob(name, entries: ["one", "two", "three"], method: method)
            var cut = good; cut.compressed = Array(good.compressed.dropLast())
            var larger = good; larger.rawSize += 3
            var smaller = good; smaller.rawSize -= 3
            var garbage = good; garbage.compressed = Array(repeating: 0x5A, count: 64)
            // The stream under the other method's number.
            var swapped = good; swapped.method = method == InterfaceTextPackBytes.lzma ? InterfaceTextPackBytes.bzip2 : InterfaceTextPackBytes.lzma
            for (label, blob) in [("cut", cut), ("raw size too large", larger), ("raw size too small", smaller), ("garbage", garbage), ("wrong method", swapped)] {
                var bytes = sample()
                bytes.blobs = [blob]
                guard let opened = try? container(bytes) else { XCTFail("\(name), \(label): the pack did not open"); continue }
                XCTAssertThrowsError(try opened.decodedBlob(named: name), "\(name), \(label)") { XCTAssertTrue($0 is PackContainerFailure) }
            }
        }
    }

    /// Every byte of a good pack, changed to other values: no trap, whatever it gives.
    func testNoChangedByteTraps() {
        let whole = sample().data()
        for index in 0..<whole.count {
            for value in [UInt8(0), 1, 0x7F, 0x80, 0xFF, whole[index] ^ 0x01] {
                var changed = whole
                changed[index] = value
                guard let opened = try? PackContainer(data: changed, format: Self.format) else { continue }
                for name in opened.blobs.keys { _ = try? opened.decodedBlob(named: name) }
            }
        }
    }
}

private extension InterfaceTextPackBytes {
    /// Changes the first blob, which a test makes wrong; nothing when there is none.
    mutating func changeFirstBlob(_ change: (inout Blob) -> Void) {
        guard let index = blobs.indices.first else { return }
        change(&blobs[index])
    }
}
