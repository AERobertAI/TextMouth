import Foundation
import XCTest
import os
@testable import TextMouth

// Tests of the braille-table pack (FR40): its reader, the unpacking of a table and what it includes into a folder, the
// catalog read from the index, and the pack each app carries.
//
// Shared with the iPhone's unit bundle (project.yml). They unpack into folders they make, never into the app's own Caches
// (`makeSandboxDirectory`, removed when the test ends), except where a test names the app's own unpacker. They read damaged
// files on purpose, so they run in trains on GitHub, never on the development Mac.

// MARK: - A pack made in memory

/// A `BrailleTables.pack` made in memory, as `Scripts/packs/braille_tables.py` writes one, with each field open to damage.
struct BrailleTablePackBytes {
    /// One group of the pack: the names of its files, in the order their bytes follow one another.
    var groups: [[String]]
    /// The files' text by name.
    var files: [String: String]
    /// Changes the index document before it is written, to make it wrong.
    var damageIndex: (inout [String: Any]) -> Void = { _ in }
    /// Changes each group's raw bytes before they are compressed (by group number), to make them wrong.
    var damageGroup: (Int, inout [UInt8]) -> Void = { _, _ in }
    /// Gives the directory's count of the group's entries.
    var groupCount: (Int, Int) -> Int = { $1 }
    /// The liblouis version the index states.
    var liblouis = "9.9.9"

    /// The files each file's text includes, in order: the second word of each line whose first is `include`.
    static func includes(of text: String) -> [String] {
        var found: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if words.count >= 2, words[0] == "include", !found.contains(words[1]) { found.append(words[1]) }
        }
        return found
    }

    /// The pack's bytes.
    func data() throws -> Data {
        var entries: [[String: Any]] = []
        var raws: [[UInt8]] = []
        for (number, names) in groups.enumerated() {
            var raw: [UInt8] = []
            for name in names {
                let text = try XCTUnwrap(files[name], name)
                let bytes = Array(text.utf8)
                var entry: [String: Any] = ["n": name, "g": number, "o": raw.count, "l": bytes.count]
                let included = Self.includes(of: text)
                if !included.isEmpty { entry["i"] = included }
                let fields = BrailleTableCatalog.metadata(fromHeader: text)
                if fields["type"] != nil { entry["m"] = fields }
                if let only = Self.onlyIncludes(text) { entry["t"] = only }
                entries.append(entry)
                raw += bytes
            }
            raws.append(raw)
        }
        var document: [String: Any] = ["v": 1, "liblouis": liblouis, "files": entries.sorted { ($0["n"] as? String ?? "") < ($1["n"] as? String ?? "") }]
        damageIndex(&document)
        let index = Array(try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]))
        var blobs = [InterfaceTextPackBytes.blob("index", raw: index, count: 1)]
        for (number, var raw) in raws.enumerated() {
            damageGroup(number, &raw)
            blobs.append(InterfaceTextPackBytes.blob(
                BrailleTablePack.groupBlobName(number), raw: raw, count: groupCount(number, groups[number].count)
            ))
        }
        var bytes = InterfaceTextPackBytes(idCount: files.count, blobs: blobs)
        bytes.magic = Array("TMBT".utf8)
        bytes.version = 1
        return bytes.data()
    }

    /// The tables a text includes when it does nothing else (every line a comment, blank, or an include).
    static func onlyIncludes(_ text: String) -> [String]? {
        var targets: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = words.first, !first.hasPrefix("#") else { continue }
            guard first.lowercased() == "include", words.count >= 2 else { return nil }
            targets.append(words[1])
        }
        return targets.isEmpty ? nil : targets
    }

    /// Four small tables in three groups: `plain.ctb` includes `chars.uti` and `digits.uti` (in other groups), `wrap.tbl` only
    /// includes `plain.ctb`, and `other.ctb` includes nothing and is the only file of its own.
    static func sample() -> BrailleTablePackBytes {
        BrailleTablePackBytes(
            groups: [["plain.ctb", "wrap.tbl"], ["chars.uti", "digits.uti"], ["other.ctb"]],
            files: [
                "plain.ctb": "#+type:literary\n#+language:xx\n#-display-name: Plain braille\n#+contraction:no\n\ninclude chars.uti\ninclude digits.uti\n",
                "wrap.tbl": "#+type:literary\n#+language:xx\n#-display-name: Wrapped braille\n#+contraction:full\n\ninclude plain.ctb\n",
                "chars.uti": "letter a 1\nletter b 12\nspace \\s 0\n",
                "digits.uti": "# digits\nsign 1 2\n",
                "other.ctb": "#+type:literary\n#+language:yy\n#-display-name: Other braille\n#+contraction:no\n\nletter a 1\n",
            ]
        )
    }
}

// MARK: - The reader

final class BrailleTablePackTests: XCTestCase {
    /// The sample pack, opened.
    private func samplePack() throws -> BrailleTablePack {
        try BrailleTablePack(data: BrailleTablePackBytes.sample().data())
    }

    /// The index lists every file with its place, includes, and header fields.
    func testTheIndexListsEveryFile() throws {
        let pack = try samplePack()
        XCTAssertEqual(pack.names, ["chars.uti", "digits.uti", "other.ctb", "plain.ctb", "wrap.tbl"])
        XCTAssertEqual(pack.liblouisVersion, "9.9.9")
        let plain = try XCTUnwrap(pack.files["plain.ctb"])
        XCTAssertEqual(plain.includes, ["chars.uti", "digits.uti"])
        XCTAssertEqual(plain.fields["display-name"], "Plain braille")
        XCTAssertEqual(plain.includeOnly, ["chars.uti", "digits.uti"], "it holds nothing but its includes")
        XCTAssertEqual(pack.files["wrap.tbl"]?.includeOnly, ["plain.ctb"])
        XCTAssertNil(pack.files["other.ctb"]?.includeOnly)
        XCTAssertEqual(pack.files["chars.uti"]?.fields, [:])
    }

    /// A table's closure is the table, then each file its includes reach once, in the order they are reached; a loop ends.
    func testTheClosureOfATable() throws {
        let pack = try samplePack()
        XCTAssertEqual(pack.closure(of: "wrap.tbl"), ["wrap.tbl", "plain.ctb", "chars.uti", "digits.uti"])
        XCTAssertEqual(pack.closure(of: "other.ctb"), ["other.ctb"])
        XCTAssertNil(pack.closure(of: "nothere.ctb"))
        var looped = BrailleTablePackBytes.sample()
        looped.files["chars.uti"] = "include plain.ctb\nletter a 1\n"
        XCTAssertEqual(try BrailleTablePack(data: looped.data()).closure(of: "plain.ctb"), ["plain.ctb", "chars.uti", "digits.uti"])
    }

    /// Every group decodes to the bytes its files' places say, in any order of asking.
    func testEachFilesBytesAreWhereTheIndexSays() throws {
        let pack = try samplePack()
        let sample = BrailleTablePackBytes.sample()
        for name in pack.names.reversed() {
            let file = try XCTUnwrap(pack.files[name])
            let group = try pack.decodedGroup(file.group)
            XCTAssertEqual(BrailleTablePack.bytes(of: file, in: group), Data(try XCTUnwrap(sample.files[name]).utf8), name)
        }
        // A group shorter than a file's place gives nothing, not a trap.
        let file = try XCTUnwrap(pack.files["digits.uti"])
        XCTAssertNil(BrailleTablePack.bytes(of: file, in: []))
    }

    /// A file name is plain: no path, no hidden file, no odd character.
    func testPlainNames() {
        for name in ["en-ueb-g2.ctb", "en_US.tbl", "Es-Es-G0.utb", "a+b.ctb", "x"] {
            XCTAssertTrue(BrailleTablePack.isPlainName(name), name)
        }
        for name in ["", ".", "..", ".hidden", "a/b.ctb", "../x.ctb", "a,b.ctb", "a b.ctb", "caf\u{E9}.ctb", "a\0b", String(repeating: "x", count: 256)] {
            XCTAssertFalse(BrailleTablePack.isPlainName(name), name)
        }
    }

    /// Each fault of the index or a group is a failure when the pack opens, and none traps.
    func testADamagedPackIsRefused() throws {
        func refused(_ label: String, _ change: (inout BrailleTablePackBytes) -> Void) throws {
            var bytes = BrailleTablePackBytes.sample()
            change(&bytes)
            XCTAssertThrowsError(try BrailleTablePack(data: bytes.data()), label) { error in
                XCTAssertTrue(error is BrailleTablePackFailure, "\(label): \(error)")
            }
        }
        try refused("a version of the index this reader does not know") { $0.damageIndex = { $0["v"] = 2 } }
        try refused("a liblouis version that is a path") { $0.liblouis = "../3.39.0" }
        try refused("no liblouis version") { $0.liblouis = "" }
        try refused("a file listed twice") { $0.damageIndex = { document in
            if var files = document["files"] as? [[String: Any]], let first = files.first { files.append(first); document["files"] = files }
        } }
        try refused("a name that is a path") { $0.damageIndex = { document in
            if var files = document["files"] as? [[String: Any]] { files[0]["n"] = "../x.ctb"; document["files"] = files }
        } }
        try refused("a group the pack lacks") { $0.damageIndex = { document in
            if var files = document["files"] as? [[String: Any]] { files[0]["g"] = 9; document["files"] = files }
        } }
        try refused("a negative group") { $0.damageIndex = { document in
            if var files = document["files"] as? [[String: Any]] { files[0]["g"] = -1; document["files"] = files }
        } }
        try refused("an offset past the group") { $0.damageIndex = { document in
            if var files = document["files"] as? [[String: Any]] { files[0]["o"] = 1_000_000; document["files"] = files }
        } }
        try refused("a length past the group") { $0.damageIndex = { document in
            if var files = document["files"] as? [[String: Any]] { files[0]["l"] = 1_000_000; document["files"] = files }
        } }
        try refused("a negative length") { $0.damageIndex = { document in
            if var files = document["files"] as? [[String: Any]] { files[0]["l"] = -1; document["files"] = files }
        } }
        try refused("an offset and length that overflow") { $0.damageIndex = { document in
            if var files = document["files"] as? [[String: Any]] { files[0]["o"] = Int.max; files[0]["l"] = 5; document["files"] = files }
        } }
        try refused("an include the pack lacks") { $0.files["chars.uti"] = "include gone.uti\n" }
        try refused("a group whose count is not its files'") { $0.groupCount = { _, count in count + 1 } }
        try refused("an index that lists fewer files than the header counts") { $0.damageIndex = { document in
            if var files = document["files"] as? [[String: Any]] { files.removeLast(); document["files"] = files }
        } }
        try refused("an index that is not an object") { $0.damageIndex = { document in document = ["v": "one"] } }
    }

    /// A pack of another format, a cut pack, and a pack with no index are refused; every byte changed anywhere traps nothing.
    func testShortAndWrongPacksAreRefused() throws {
        let whole = try BrailleTablePackBytes.sample().data()
        for length in 0..<whole.count {
            XCTAssertThrowsError(try BrailleTablePack(data: Data(whole.prefix(length))), "length \(length)")
        }
        XCTAssertThrowsError(try BrailleTablePack(data: InterfaceTextPackBytes.sample().data()), "a Strings.pack")
        var noIndex = InterfaceTextPackBytes(idCount: 0, blobs: [InterfaceTextPackBytes.blob("g000", raw: [], count: 0)])
        noIndex.magic = Array("TMBT".utf8)
        noIndex.version = 1
        XCTAssertThrowsError(try BrailleTablePack(data: noIndex.data()), "no index")
        for index in 0..<whole.count {
            for value in [UInt8(0), 0x7F, 0xFF, whole[index] ^ 0x01] {
                var changed = whole
                changed[index] = value
                guard let pack = try? BrailleTablePack(data: changed) else { continue }
                for name in pack.names { _ = try? pack.decodedGroup(pack.files[name]?.group ?? 0) }
            }
        }
    }
}

// MARK: - The unpacker

final class BrailleTableUnpackerTests: XCTestCase {
    /// An unpacker of the sample pack into a new folder of the test's own.
    private func unpacker(_ bytes: BrailleTablePackBytes = .sample()) throws -> BrailleTableUnpacker {
        BrailleTableUnpacker(pack: try BrailleTablePack(data: bytes.data()), folder: try makeSandboxDirectory("BrailleUnpack").appendingPathComponent("tables"))
    }

    /// The names of the files in `folder`, hidden ones too, sorted.
    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// A table and every file its includes reach are written, whole, and no other file; the folder is the one returned.
    func testTheClosureIsUnpackedAndNothingElse() throws {
        let unpacker = try unpacker()
        let folder = try unpacker.unpackedFolder(for: "wrap.tbl")
        XCTAssertEqual(folder, unpacker.folder)
        XCTAssertEqual(try names(in: folder), ["chars.uti", "digits.uti", "plain.ctb", "wrap.tbl"])
        let sample = BrailleTablePackBytes.sample()
        for name in try names(in: folder) {
            XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8), sample.files[name], name)
        }
        // Another table adds its own files beside them.
        try unpacker.unpackedFolder(for: "other.ctb")
        XCTAssertEqual(try names(in: folder), ["chars.uti", "digits.uti", "other.ctb", "plain.ctb", "wrap.tbl"])
    }

    /// A second unpacking of the same table changes nothing: the files are the same files, not written again.
    func testASecondRunChangesNothing() throws {
        let unpacker = try unpacker()
        let folder = try unpacker.unpackedFolder(for: "plain.ctb")
        func stamps() throws -> [String: Date] {
            Dictionary(uniqueKeysWithValues: try names(in: folder).map { name in
                (name, (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.modificationDate] as? Date) ?? .distantPast)
            })
        }
        let before = try stamps()
        Thread.sleep(forTimeInterval: 1.1)
        try unpacker.unpackedFolder(for: "plain.ctb")
        XCTAssertEqual(try stamps(), before)
    }

    /// A file that is gone, or has the wrong length, is unpacked again; one with the right length is kept as it is.
    func testAMissingOrWrongFileIsUnpackedAgainAndARightOneKept() throws {
        let unpacker = try unpacker()
        let folder = try unpacker.unpackedFolder(for: "plain.ctb")
        let sample = BrailleTablePackBytes.sample()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("chars.uti"))
        try "short".write(to: folder.appendingPathComponent("digits.uti"), atomically: true, encoding: .utf8)
        // A file of the right length is kept, whatever it holds.
        let original = try XCTUnwrap(sample.files["plain.ctb"])
        let sameLength = String(repeating: "x", count: original.utf8.count)
        try sameLength.write(to: folder.appendingPathComponent("plain.ctb"), atomically: true, encoding: .utf8)
        try unpacker.unpackedFolder(for: "plain.ctb")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("chars.uti"), encoding: .utf8), sample.files["chars.uti"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("digits.uti"), encoding: .utf8), sample.files["digits.uti"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("plain.ctb"), encoding: .utf8), sameLength)
    }

    /// Nothing is left behind but the files: no temporary file stays in the folder, and a name the pack lacks is refused.
    func testNoTemporaryFileStaysAndAnUnknownNameIsRefused() throws {
        let unpacker = try unpacker()
        try unpacker.unpackedFolder(for: "wrap.tbl")
        XCTAssertFalse(try names(in: unpacker.folder).contains { $0.hasSuffix(".tmp") || $0.hasPrefix(".") })
        XCTAssertThrowsError(try unpacker.unpackedFolder(for: "nothere.ctb")) {
            XCTAssertEqual($0 as? BrailleTableUnpacker.Failure, .unknownFile("nothere.ctb"))
        }
        XCTAssertThrowsError(try unpacker.unpackedFolder(for: "../plain.ctb"))
    }

    /// Two unpackings of the same table at once leave whole files and both return.
    func testTwoUnpackingsAtOnceLeaveWholeFiles() throws {
        let unpacker = try unpacker()
        let failures = OSAllocatedUnfairLock<Int>(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do { try unpacker.unpackedFolder(for: "wrap.tbl") } catch { failures.withLock { $0 += 1 } }
        }
        XCTAssertEqual(failures.withLock { $0 }, 0)
        let sample = BrailleTablePackBytes.sample()
        for name in ["chars.uti", "digits.uti", "plain.ctb", "wrap.tbl"] {
            XCTAssertEqual(try String(contentsOf: unpacker.folder.appendingPathComponent(name), encoding: .utf8), sample.files[name], name)
        }
        XCTAssertFalse(try names(in: unpacker.folder).contains { $0.hasSuffix(".tmp") })
    }

    /// A damaged group makes the tables that need it unavailable, with one report however often they are asked for; the
    /// tables of other groups still unpack; nothing traps.
    func testADamagedGroupMakesItsTablesUnavailableAndIsLoggedOnce() throws {
        // Group 1 (the include files) is no LZMA stream any more.
        let pack = try BrailleTablePack(data: try damagedGroupData())
        let unpacker = BrailleTableUnpacker(pack: pack, folder: try makeSandboxDirectory("BrailleDamaged").appendingPathComponent("tables"))
        try TextMouthPaths.ensureDirectoryStructure()
        for _ in 0..<3 {
            XCTAssertThrowsError(try unpacker.unpackedFolder(for: "plain.ctb")) { error in
                guard case .unavailable = error as? BrailleTableUnpacker.Failure else { return XCTFail("\(error)") }
            }
        }
        // The table of the other group is not harmed.
        XCTAssertNoThrow(try unpacker.unpackedFolder(for: "other.ctb"))
        XCTAssertEqual(debugLogLines(containing: "BRAILLE_TABLES_UNAVAILABLE: plain.ctb").count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: unpacker.folder.path).filter { $0.hasSuffix(".tmp") }, [])
    }

    /// The sample pack with group 1's blob replaced by bytes that are no LZMA stream.
    private func damagedGroupData() throws -> Data {
        var parts = try BrailleTablePackBytes.sample().data()
        // The directory's records follow the 48-byte header, 32 bytes each: the index, then g000, g001, g002. g001's
        // compressed bytes are overwritten, which leaves its directory entry intact.
        let record = 48 + 2 * 32
        let offset = Int(parts.loadLittleEndianUInt32(at: record + 12))
        let size = Int(parts.loadLittleEndianUInt32(at: record + 16))
        for index in offset..<(offset + size) { parts[index] = 0x5A }
        return parts
    }
}

private extension Data {
    /// The little-endian u32 at `offset`.
    func loadLittleEndianUInt32(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(self[startIndex + offset + $1]) << UInt32(8 * $1)) }
    }
}

// MARK: - The catalog from the index

/// The catalog read from a pack's index is the catalog read from the same files in a folder, for the sample pack and for the
/// pack the app carries; and the app's pack is what its platform ships.
final class BrailleTablePackCatalogTests: XCTestCase {
    /// Every file of `unpacker`'s pack, unpacked into its folder.
    private func unpackEverything(_ unpacker: BrailleTableUnpacker) throws {
        for name in unpacker.pack.names { try unpacker.unpackedFolder(for: name) }
    }

    /// The sample pack lists its tables as a folder of the same files does: the twin that only includes another table of its
    /// language is left out, in the same order and with the same fields.
    func testTheSamplePackListsWhatItsFilesList() throws {
        let pack = try BrailleTablePack(data: BrailleTablePackBytes.sample().data())
        let unpacker = BrailleTableUnpacker(pack: pack, folder: try makeSandboxDirectory("BrailleCatalogSample").appendingPathComponent("tables"))
        try unpackEverything(unpacker)
        let fromIndex = BrailleTableCatalog.tables(in: pack)
        XCTAssertEqual(fromIndex.map(\.id), ["plain.ctb", "other.ctb"], "wrap.tbl only includes plain.ctb, so it is a twin")
        XCTAssertEqual(fromIndex, BrailleTableCatalog.tables(in: unpacker.folder))
        XCTAssertEqual(fromIndex.first?.displayName, "Plain braille")
        XCTAssertEqual(fromIndex.first?.contraction, Contraction.no)
    }

    /// The pack the app carries, unpacked whole: each file is the length the index says, the header fields and include-only
    /// targets the index records (`braille_tables.py`) are what Swift reads from the file itself, and the catalog from the
    /// index is the catalog from the files, table for table.
    func testTheAppsPackListsWhatItsFilesList() throws {
        let app = try XCTUnwrap(BrailleTableUnpacker.app, "the app has no braille table pack")
        let unpacker = BrailleTableUnpacker(pack: app.pack, folder: try makeSandboxDirectory("BrailleCatalogApp").appendingPathComponent("tables"))
        try unpackEverything(unpacker)
        let catalogKeys: Set = ["type", "dots", "display-name", "language", "locale", "contraction", "grade", "direction", "index-name", "system", "region"]
        for name in unpacker.pack.names {
            let file = try XCTUnwrap(unpacker.pack.files[name])
            let url = unpacker.folder.appendingPathComponent(name)
            let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            XCTAssertEqual(size, file.length, name)
            let read = BrailleTableCatalog.metadata(ofTableAt: url)
            let expected = read["type"] == nil ? [:] : read.filter { catalogKeys.contains($0.key) }
            XCTAssertEqual(file.fields, expected, "\(name): the fields")
            XCTAssertEqual(file.includeOnly, BrailleTableCatalog.includeOnlyTargets(ofTableAt: url), "\(name): the include-only targets")
        }
        XCTAssertEqual(BrailleTableCatalog.tables(in: app.pack), BrailleTableCatalog.tables(in: unpacker.folder))
        XCTAssertEqual(BrailleTableCatalog.bundled, BrailleTableCatalog.tables(in: unpacker.folder))
    }

    /// The Mac's pack holds exactly the four English tables, and the iPhone's holds those and many more, each language's
    /// tables in the catalog.
    func testWhatThePlatformsPackShips() throws {
        let english = ["en-us-g1.ctb", "en_US.tbl", "en-ueb-g1.ctb", "en-ueb-g2.ctb"]
        let ids = BrailleTableCatalog.bundled.map(\.id)
        #if os(macOS)
        XCTAssertEqual(ids, english)
        XCTAssertEqual(try XCTUnwrap(BrailleTableUnpacker.app).pack.names.count, 20)
        #else
        XCTAssertTrue(Set(english).isSubset(of: ids), "\(ids)")
        XCTAssertGreaterThan(ids.count, 100)
        XCTAssertTrue(Set(BrailleTableCatalog.bundled.map(\.language)).isSuperset(of: ["en", "fr", "es", "it", "ar"]))
        #endif
        XCTAssertEqual(try XCTUnwrap(BrailleTableUnpacker.app).pack.liblouisVersion, BrailleTableCatalog.bundledLiblouisVersion)
    }

    /// A Mac's `mac:<file>` value names the table of that file name among `bundled`, and nothing when there is none; a
    /// bundled value names itself when it is listed.
    func testAMacsValueNamesTheBundledTableOfTheSameFile() throws {
        let tables = BrailleTableCatalog.tables(in: try BrailleTablePack(data: BrailleTablePackBytes.sample().data()))
        XCTAssertEqual(BrailleTableCatalog.bundledID(forStored: "mac:plain.ctb", among: tables), "plain.ctb")
        XCTAssertEqual(BrailleTableCatalog.bundledID(forStored: "plain.ctb", among: tables), "plain.ctb")
        XCTAssertEqual(BrailleTableCatalog.bundledID(forStored: "mac:other.ctb", among: tables), "other.ctb")
        XCTAssertNil(BrailleTableCatalog.bundledID(forStored: "mac:wrap.tbl", among: tables), "a twin is not offered")
        XCTAssertNil(BrailleTableCatalog.bundledID(forStored: "mac:nothere.ctb", among: tables))
        XCTAssertNil(BrailleTableCatalog.bundledID(forStored: "nothere.ctb", among: tables))
        XCTAssertNil(BrailleTableCatalog.bundledID(forStored: "", among: tables))
    }

    #if os(macOS)
    /// The Mac's real helper loads a table that is not English, and its includes, from the folder a pack was unpacked into,
    /// by its bare name, and translates with it: the sample pack's `plain.ctb`, which includes two files of another group.
    func testTheHelperReadsATableFromAnUnpackedFolder() throws {
        let unpacker = BrailleTableUnpacker(
            pack: try BrailleTablePack(data: BrailleTablePackBytes.sample().data()),
            folder: try makeSandboxDirectory("BrailleHelperUnpacked").appendingPathComponent("tables")
        )
        let folder = try unpacker.unpackedFolder(for: "plain.ctb")
        let work = try makeSandboxDirectory("BrailleHelperWork")
        let input = work.appendingPathComponent("input.txt"), output = work.appendingPathComponent("output.txt")
        try Data("\(BrailleEmphasis.protocolHeader)\nab ba\n\n".utf8).write(to: input)
        XCTAssertEqual(try runHelper(["check", folder.path, "plain.ctb"]), 0)
        XCTAssertEqual(try runHelper(["forward", folder.path, "plain.ctb", input.path, output.path]), 0)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "\(BrailleEmphasis.protocolHeader)\n\u{2801}\u{2803}\u{2800}\u{2803}\u{2801}\n\n")
        // A folder that holds the table without the file it includes does not load: the closure is what makes a table work.
        let bare = work.appendingPathComponent("bare", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: folder.appendingPathComponent("plain.ctb"), to: bare.appendingPathComponent("plain.ctb"))
        XCTAssertNotEqual(try runHelper(["check", bare.path, "plain.ctb"]), 0)
    }

    /// Runs the real braille helper with `arguments`, within 30 seconds, and returns its exit status.
    private func runHelper(_ arguments: [String]) throws -> Int32 {
        let executable = try XCTUnwrap(Bundle.main.url(forAuxiliaryExecutable: "TextMouthBraille"))
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 30) == .timedOut {
            process.terminate()
            XCTFail("the helper took more than 30 seconds")
            return -1
        }
        return process.terminationStatus
    }
    #endif
}
