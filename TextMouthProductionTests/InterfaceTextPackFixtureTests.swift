import Foundation
import XCTest
@testable import TextMouth

/// The pack reader over the packs `Scripts/l10n/pack.py` wrote (FR39 phase 2), `lines.pack` and `plurals.pack`, against
/// the `.entries.json` beside each, which spells out every decoded entry; and over `lines-corrupt-utf8.pack`, whose
/// first English entry is the bytes C3 28; and `lines-mixed-methods.pack`, the first catalog's pack with the ids, English,
/// and Spanish blobs LZMA and the rest bzip2. Also corrupt copies of a real pack, made in memory.
///
/// The fixture folder is a resource of both test bundles (project.yml), read where it is in the repository; a run
/// without the resource finds the same files through this file's own path. Shared with the iPhone's unit bundle. The
/// tests read damaged files on purpose, so they run in trains on GitHub, never on the development Mac.
/// The helpers (`InterfaceTextReportLog`, `interfaceLine`) are in `InterfaceTextTests.swift`.
final class InterfaceTextPackFixtureTests: XCTestCase {
    /// The URL of a file in the fixture folder: the bundle's resource folder if it holds the file, else the repository's.
    private func fixture(_ name: String, file: String = #filePath) throws -> URL {
        let bundled = Bundle(for: Self.self).resourceURL?.appendingPathComponent("pack/\(name)")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let repository = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
        let url = repository.appendingPathComponent("Scripts/l10n/tests/fixtures/pack/\(name)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "no fixture \(name)")
        return url
    }

    /// A pack read from its file, mapped as the app reads its own.
    private func pack(_ name: String) throws -> InterfaceTextPack {
        try InterfaceTextPack(contentsOf: try fixture(name))
    }

    /// The decoded entries a fixture's `.entries.json` states: the IDs, then each language's entry for each ID (`text` a
    /// plain entry, `forms` a plural one, null none).
    private func expected(_ name: String) throws -> (ids: [String], languages: [String: [String: InterfaceTextEntry]]) {
        let data = try Data(contentsOf: try fixture("\(name).entries.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ids = try XCTUnwrap(root["ids"] as? [String])
        let languages = try XCTUnwrap(root["languages"] as? [String: [String: Any]])
        var result: [String: [String: InterfaceTextEntry]] = [:]
        for (language, lines) in languages {
            for (id, value) in lines {
                let line = value as? [String: Any]
                if let text = line?["text"] as? String {
                    result[language, default: [:]][id] = .plain(text)
                } else if let forms = line?["forms"] as? [String] {
                    result[language, default: [:]][id] = .plural(forms)
                } else {
                    result[language, default: [:]][id] = .absent
                }
            }
        }
        return (ids, result)
    }

    /// Every entry of every language of each fixture pack equals its `.entries.json`, and its IDs are the file's.
    func testEveryEntryEqualsItsFixtureCatalog() throws {
        for name in ["lines", "plurals"] {
            let pack = try self.pack("\(name).pack")
            let (ids, languages) = try expected(name)
            XCTAssertEqual(pack.idCount, ids.count, name)
            let list = try pack.idList()
            XCTAssertEqual((0..<list.count).map { list.id(at: $0) }, ids, name)
            XCTAssertFalse(languages.isEmpty)
            for (language, lines) in languages {
                XCTAssertTrue(pack.hasLanguage(language), "\(name) \(language)")
                let entries = try pack.entries(language: language)
                XCTAssertEqual(entries, ids.map { lines[$0] ?? .absent }, "\(name) \(language)")
            }
        }
    }

    /// The pack that holds both compression methods reads to the same entries as the pack that took the smaller of each.
    func testAPackWithBothMethodsReadsTheSameEntries() throws {
        let mixed = try pack("lines-mixed-methods.pack"), smaller = try pack("lines.pack")
        XCTAssertEqual(mixed.idCount, smaller.idCount)
        XCTAssertEqual(try mixed.idList().count, try smaller.idList().count)
        let (_, languages) = try expected("lines")
        for language in languages.keys {
            XCTAssertEqual(try mixed.entries(language: language), try smaller.entries(language: language), language)
        }
        XCTAssertEqual(try mixed.notes(), try smaller.notes())
    }

    /// The engine over a fixture pack: a plain line, a reordered one, and the plurals, including the forms that leave
    /// out the number and the English forms the pack holds.
    func testTheEngineReadsTheFixtures() throws {
        let log = InterfaceTextReportLog()
        let lines = InterfaceTextEngine(tables: try pack("lines.pack"), report: log.sink)
        let name = "Ana", pages = 3
        XCTAssertEqual(interfaceLine(lines, "fixture.number", "Page \(number: pages)", language: "es"), "Página 3")
        // Foundation wraps a `%@` argument in direction isolates (U+2066 to U+2069) when the format starts with
        // right-to-left text, as Apple's `String(localized:)` does, and the engine hands the text to Foundation. The mark
        // is U+2068 on the Mac and another isolate on the iPhone (train 1121-1946), so the test strips all four and
        // asks that some were there.
        let reordered = interfaceLine(lines, "fixture.reorder", "\(name) read \(number: pages) pages", language: "ar")
        let isolates = Set("\u{2066}\u{2067}\u{2068}\u{2069}".unicodeScalars)
        XCTAssertEqual(String(String.UnicodeScalarView(reordered.unicodeScalars.filter { !isolates.contains($0) })), "قرأ Ana 3 صفحة")
        XCTAssertTrue(reordered.unicodeScalars.contains { isolates.contains($0) }, "Foundation isolates the argument: \(reordered.debugDescription)")
        XCTAssertEqual(interfaceLine(lines, "fixture.englishOnly", "Only English", language: "ja"), "Only English")
        let plurals = InterfaceTextEngine(tables: try pack("plurals.pack"), report: log.sink)
        let one = 1, five = 5
        XCTAssertEqual(interfaceLine(plurals, "fixture.ownedBooks", "\(name) has \(number: one) books", language: "es"), "Ana tiene un libro")
        XCTAssertEqual(interfaceLine(plurals, "fixture.ownedBooks", "\(name) has \(number: five) books", language: "es"), "Ana tiene 5 libros")
        XCTAssertEqual(interfaceLine(plurals, "fixture.pages", "\(number: one) pages", language: "en"), "One page")
        XCTAssertEqual(interfaceLine(plurals, "fixture.pages", "\(number: five) pages", language: "en"), "5 pages")
        XCTAssertEqual(interfaceLine(plurals, "fixture.pages", "\(number: one) pages", language: "ar"), "صفحة واحدة")
        XCTAssertEqual(log.messages, [])
    }

    /// The corrupt pack: its directory is whole, so it opens; its English blob holds the bytes C3 28, so that blob
    /// throws and the others read. A lookup that needs English shows the call's own English and reports once.
    func testTheCorruptUTF8PackFailsOnlyItsEnglishBlob() throws {
        let corrupt = try pack("lines-corrupt-utf8.pack")
        XCTAssertThrowsError(try corrupt.entries(language: "en"))
        XCTAssertNoThrow(try corrupt.entries(language: "es"))
        let log = InterfaceTextReportLog()
        let engine = InterfaceTextEngine(tables: corrupt, report: log.sink)
        let pages = 3
        XCTAssertEqual(interfaceLine(engine, "fixture.number", "Page \(number: pages)", language: "es"), "Página 3", "no English is needed")
        XCTAssertEqual(log.messages, [])
        for _ in 0..<3 {
            XCTAssertEqual(interfaceLine(engine, "fixture.englishOnly", "Only English \(number: pages)", language: "en"), "Only English 3")
        }
        XCTAssertEqual(log.messages.count, 1, "\(log.messages)")
    }

    // MARK: Corrupt copies, made in memory

    /// `data` with the little-endian u32 at `offset` replaced.
    private func patched(_ data: Data, at offset: Int, to value: UInt32) -> Data {
        var copy = data
        for byte in 0..<4 { copy[offset + byte] = UInt8((value >> UInt32(8 * byte)) & 0xFF) }
        return copy
    }

    /// `data` with the byte at `offset` replaced.
    private func patchedByte(_ data: Data, at offset: Int, to value: UInt8) -> Data {
        var copy = data
        copy[offset] = value
        return copy
    }

    /// The position in the file of a directory field of blob `index` (0 ids, 1 notes, 2 en, 3 ar, 4 es, ...): `field` is
    /// 12 for the offset, 16 the compressed size, 20 the raw size, 24 the entry count, and 28 the compression method.
    private func position(blob index: Int, field: Int) -> Int { 48 + 32 * index + field }

    /// `data` with the byte `index` bytes into blob `blob`'s compressed stream XORed with `mask`.
    private func changedByte(_ data: Data, blob: Int, from index: Int, with mask: UInt8) -> Data {
        let at = Int(u32(data, at: position(blob: blob, field: 12))) + index
        return patchedByte(data, at: at, to: data[at] ^ mask)
    }

    /// The u32 at `offset` of `data`.
    private func u32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << UInt32(8 * $1) }
    }

    /// Faults the pack refuses as it opens: the magic, the version, the flags, a cut file, an entry count that is not the
    /// ID count. Faults in a blob, found as it is decoded: the lookup shows English and reports once. Then every byte of
    /// the file changed to other values, which must never trap, whatever the result.
    func testCorruptCopiesOfARealPackGiveEnglishAndNeverTrap() throws {
        let whole = try Data(contentsOf: try fixture("lines.pack"))
        let spanish = 4
        var badMagic = whole; badMagic[0] = UInt8(ascii: "X")
        var badVersion = whole; badVersion[4] = 3
        let formerVersion = patchedByte(whole, at: 4, to: 1)
        let unknownMethod = patched(whole, at: position(blob: spanish, field: 28), to: 2)
        var badFlags = whole; badFlags[6] = 1
        let cut = Data(whole.prefix(whole.count - 5))
        let badCount = patched(whole, at: position(blob: spanish, field: 24), to: 5)
        for (name, data) in [
            ("magic", badMagic), ("version", badVersion), ("the former version", formerVersion), ("flags", badFlags),
            ("a cut blob", cut), ("a wrong entry count", badCount), ("an unknown method", unknownMethod),
        ] {
            XCTAssertThrowsError(try InterfaceTextPack(data: data), name)
        }

        let rawSize = u32(whole, at: position(blob: spanish, field: 20))
        let compressedSize = u32(whole, at: position(blob: spanish, field: 16))
        let damaged = [
            ("a raw size one too large", patched(whole, at: position(blob: spanish, field: 20), to: rawSize + 1)),
            ("a raw size one too small", patched(whole, at: position(blob: spanish, field: 20), to: rawSize - 1)),
            ("a compressed size four short", patched(whole, at: position(blob: spanish, field: 16), to: compressedSize - 4)),
            // The Spanish blob of the pack is bzip2: a method that says LZMA of its bytes, a changed byte in the middle of
            // its stream (the block's CRC fails), and its last bytes (the end-of-stream CRC) changed.
            ("bzip2 bytes said to be LZMA", patched(whole, at: position(blob: spanish, field: 28), to: 0)),
            ("a changed byte inside the stream", changedByte(whole, blob: spanish, from: Int(compressedSize) / 2, with: 0xFF)),
            ("a wrong checksum", changedByte(whole, blob: spanish, from: Int(compressedSize) - 3, with: 0x01)),
        ]
        for (name, data) in damaged {
            let log = InterfaceTextReportLog()
            let engine = InterfaceTextEngine(tables: try InterfaceTextPack(data: data), report: log.sink)
            for _ in 0..<3 { XCTAssertEqual(interfaceLine(engine, "fixture.plain", "Hello", language: "es"), "Hello", name) }
            XCTAssertEqual(log.messages.count, 1, "\(name): \(log.messages)")
        }

        for index in 0..<whole.count {
            for value in [UInt8(0), 0x01, 0x7F, 0x80, 0xFF, whole[index] ^ 0x10] {
                var changed = whole
                changed[index] = value
                guard let pack = try? InterfaceTextPack(data: changed) else { continue }
                _ = try? pack.idList()
                for language in ["en", "ar", "es", "ja", "ru"] { _ = try? pack.entries(language: language) }
            }
        }
    }
}
