import Foundation
import XCTest
@testable import TextMouth

/// The pack reader over the packs `Scripts/l10n/pack.py` wrote (FR39 phase 2), `lines.pack` and `plurals.pack`, against
/// the `.entries.json` beside each, which spells out every decoded entry; and over `lines-corrupt-utf8.pack`, whose
/// first English entry is the bytes C3 28. Also corrupt copies of a real pack, made in memory.
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

    /// The engine over a fixture pack: a plain line, a reordered one, and the plurals, including the forms that leave
    /// out the number and the English forms the pack holds.
    func testTheEngineReadsTheFixtures() throws {
        let log = InterfaceTextReportLog()
        let lines = InterfaceTextEngine(tables: try pack("lines.pack"), report: log.sink)
        let name = "Ana", pages = 3
        XCTAssertEqual(interfaceLine(lines, "fixture.number", "Page \(number: pages)", language: "es"), "Página 3")
        XCTAssertEqual(interfaceLine(lines, "fixture.reorder", "\(name) read \(number: pages) pages", language: "ar"), "قرأ Ana 3 صفحة")
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

    /// The position in the file of a directory field of blob `index` (0 ids, 1 notes, 2 en, 3 ar, 4 es, ...): `field` is
    /// 12 for the offset, 16 the compressed size, 20 the raw size, and 24 the entry count.
    private func position(blob index: Int, field: Int) -> Int { 48 + 28 * index + field }

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
        var badVersion = whole; badVersion[4] = 2
        var badFlags = whole; badFlags[6] = 1
        let cut = Data(whole.prefix(whole.count - 5))
        let badCount = patched(whole, at: position(blob: spanish, field: 24), to: 5)
        for (name, data) in [("magic", badMagic), ("version", badVersion), ("flags", badFlags), ("a cut blob", cut), ("a wrong entry count", badCount)] {
            XCTAssertThrowsError(try InterfaceTextPack(data: data), name)
        }

        let rawSize = u32(whole, at: position(blob: spanish, field: 20))
        let compressedSize = u32(whole, at: position(blob: spanish, field: 16))
        let damaged = [
            ("a raw size one too large", patched(whole, at: position(blob: spanish, field: 20), to: rawSize + 1)),
            ("a raw size one too small", patched(whole, at: position(blob: spanish, field: 20), to: rawSize - 1)),
            ("a compressed size four short", patched(whole, at: position(blob: spanish, field: 16), to: compressedSize - 4)),
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
