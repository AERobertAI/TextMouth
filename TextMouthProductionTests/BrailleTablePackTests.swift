import CryptoKit
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
                var entry: [String: Any] = [
                    "n": name, "g": number, "o": raw.count, "l": bytes.count,
                    "h": SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined(),
                ]
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

extension XCTestCase {
    /// The tables `files` of the app's own pack, each with every file it includes, unpacked into a new folder this test makes
    /// (removed when the test ends), and that folder. The tests that read the unpacked tables use it, so none writes into the
    /// app's own folder (`BrailleTableUnpacker.app`'s), which only the tests of the real tool name.
    func unpackedAppTables(for files: String...) throws -> URL {
        let app = try XCTUnwrap(BrailleTableUnpacker.app, "the app has no braille table pack")
        let unpacker = BrailleTableUnpacker(pack: app.pack, folder: try makeSandboxDirectory("BrailleTables").appendingPathComponent("tables"))
        for file in files { try unpacker.unpackedFolder(for: file) }
        return unpacker.folder
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

    /// A change to the index document that sets `key` of its first file to `value`, which is how an index is made wrong.
    private func damagingFirstFile(_ key: String, to value: Any) -> (inout [String: Any]) -> Void {
        { document in
            guard var files = document["files"] as? [[String: Any]], let index = files.indices.first else { return }
            files[index][key] = value
            document["files"] = files
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
        try refused("a name that is a path") { $0.damageIndex = damagingFirstFile("n", to: "../x.ctb") }
        try refused("a group the pack lacks") { $0.damageIndex = damagingFirstFile("g", to: 9) }
        try refused("a negative group") { $0.damageIndex = damagingFirstFile("g", to: -1) }
        try refused("an offset past the group") { $0.damageIndex = damagingFirstFile("o", to: 1_000_000) }
        try refused("a length past the group") { $0.damageIndex = damagingFirstFile("l", to: 1_000_000) }
        try refused("a negative length") { $0.damageIndex = damagingFirstFile("l", to: -1) }
        try refused("an offset and length that overflow") { $0.damageIndex = { document in
            self.damagingFirstFile("o", to: Int.max)(&document)
            self.damagingFirstFile("l", to: 5)(&document)
        } }
        try refused("an include the pack lacks") { $0.files["chars.uti"] = "include gone.uti\n" }
        try refused("a group whose count is not its files'") { $0.groupCount = { _, count in count + 1 } }
        try refused("an index that lists fewer files than the header counts") { $0.damageIndex = { document in
            if var files = document["files"] as? [[String: Any]], !files.isEmpty { files.removeLast(); document["files"] = files }
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

/// What an unpacker did, counted through its test hooks: the groups it decoded and the files it hashed. At file scope, not
/// nested in the test class: the tool that counts the iPhone's interface tests (`Scripts/agents/ios_ui_tests.py`) takes a
/// nested type for a scope of its own, and the tests after it would count for no class.
private final class Counts: Sendable {
    let decoded = OSAllocatedUnfairLock<[Int]>(initialState: [])
    let hashed = OSAllocatedUnfairLock<[String]>(initialState: [])
}

final class BrailleTableUnpackerTests: XCTestCase {
    /// An unpacker of `bytes` into a new folder of the test's own (or `folder`), with its work in `counts`.
    private func unpacker(_ bytes: BrailleTablePackBytes = .sample(), folder: URL? = nil, counts: Counts = Counts(), sweeps: Bool = false) throws -> BrailleTableUnpacker {
        BrailleTableUnpacker(
            pack: try BrailleTablePack(data: bytes.data()),
            folder: try folder ?? makeSandboxDirectory("BrailleUnpack").appendingPathComponent("tables"),
            sweepsOtherVersions: sweeps,
            groupDecoded: { number in counts.decoded.withLock { $0.append(number) } },
            fileHashed: { name in counts.hashed.withLock { $0.append(name) } }
        )
    }

    /// The names of the files in `folder`, hidden ones too, sorted.
    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// The file number (inode) of `name` in `folder`: a file written again, or renamed into place, has another.
    private func inode(_ name: String, in folder: URL) throws -> UInt {
        let number = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.systemFileNumber] as? NSNumber
        return try XCTUnwrap(number, name).uintValue
    }

    /// The text of `name` in `folder`.
    private func text(_ name: String, in folder: URL) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    /// A table and every file its includes reach are written, whole, and no other file; the folder is the one returned.
    func testTheClosureIsUnpackedAndNothingElse() throws {
        let unpacker = try unpacker()
        let folder = try unpacker.unpackedFolder(for: "wrap.tbl")
        XCTAssertEqual(folder, unpacker.folder)
        XCTAssertEqual(try names(in: folder), ["chars.uti", "digits.uti", "plain.ctb", "wrap.tbl"])
        let sample = BrailleTablePackBytes.sample()
        for name in try names(in: folder) {
            XCTAssertEqual(try text(name, in: folder), sample.files[name], name)
        }
        // Another table adds its own files beside them.
        try unpacker.unpackedFolder(for: "other.ctb")
        XCTAssertEqual(try names(in: folder), ["chars.uti", "digits.uti", "other.ctb", "plain.ctb", "wrap.tbl"])
    }

    /// A second unpacking of the same table changes nothing: every file is the same file (the same inode, which a write or a
    /// rename would change), and no group is decoded again.
    func testASecondRunChangesNothing() throws {
        let counts = Counts()
        let unpacker = try unpacker(counts: counts)
        let folder = try unpacker.unpackedFolder(for: "plain.ctb")
        let before = try names(in: folder).map { try inode($0, in: folder) }
        let decodedBefore = counts.decoded.withLock { $0 }
        try unpacker.unpackedFolder(for: "plain.ctb")
        XCTAssertEqual(try names(in: folder).map { try inode($0, in: folder) }, before)
        XCTAssertEqual(counts.decoded.withLock { $0 }, decodedBefore, "a group was decoded again")
        XCTAssertEqual(decodedBefore.sorted(), [0, 1], "each group of the closure is decoded once")
    }

    /// A file that is gone, or has the wrong length, is unpacked again.
    func testAMissingOrShortFileIsUnpackedAgain() throws {
        let unpacker = try unpacker()
        let folder = try unpacker.unpackedFolder(for: "plain.ctb")
        let sample = BrailleTablePackBytes.sample()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("chars.uti"))
        try "short".write(to: folder.appendingPathComponent("digits.uti"), atomically: true, encoding: .utf8)
        try unpacker.unpackedFolder(for: "plain.ctb")
        XCTAssertEqual(try text("chars.uti", in: folder), sample.files["chars.uti"])
        XCTAssertEqual(try text("digits.uti", in: folder), sample.files["digits.uti"])
    }

    /// A file of the right length and the wrong bytes is not trusted: the first time a launch (a new unpacker) needs it, its
    /// hash is checked and the file is unpacked again; and a launch hashes each kept file once, however often it is needed.
    func testAFileOfTheRightLengthAndTheWrongBytesIsUnpackedAgainInANewLaunch() throws {
        let first = try unpacker()
        let folder = try first.unpackedFolder(for: "plain.ctb")
        let sample = BrailleTablePackBytes.sample()
        let original = try XCTUnwrap(sample.files["plain.ctb"])
        try String(repeating: "x", count: original.utf8.count).write(to: folder.appendingPathComponent("plain.ctb"), atomically: true, encoding: .utf8)
        try String(repeating: "y", count: try XCTUnwrap(sample.files["chars.uti"]).utf8.count).write(to: folder.appendingPathComponent("chars.uti"), atomically: true, encoding: .utf8)

        let counts = Counts()
        let second = try unpacker(folder: folder, counts: counts)
        try second.unpackedFolder(for: "plain.ctb")
        XCTAssertEqual(try text("plain.ctb", in: folder), original)
        XCTAssertEqual(try text("chars.uti", in: folder), sample.files["chars.uti"])
        // digits.uti was never damaged: kept, after its hash was checked.
        XCTAssertEqual(try text("digits.uti", in: folder), sample.files["digits.uti"])
        let hashedOnce = counts.hashed.withLock { $0.sorted() }
        XCTAssertEqual(hashedOnce, ["chars.uti", "digits.uti", "plain.ctb"])
        try second.unpackedFolder(for: "plain.ctb")
        try second.unpackedFolder(for: "wrap.tbl")
        XCTAssertEqual(counts.hashed.withLock { $0.filter { $0 != "wrap.tbl" }.sorted() }, hashedOnce, "a file checked in this launch is not hashed again")
    }

    /// A file is put in place by a rename, never written in place: a hard link to the old file keeps the old bytes, and the
    /// name gets a new file (another inode) with the right ones.
    func testAFileIsReplacedByARenameNotWrittenInPlace() throws {
        let first = try unpacker()
        let folder = try first.unpackedFolder(for: "plain.ctb")
        let name = "chars.uti"
        let correct = try XCTUnwrap(BrailleTablePackBytes.sample().files[name])
        // Damage the file in place, and keep a second name for the damaged file.
        let damaged = String(repeating: "z", count: correct.utf8.count)
        try damaged.write(to: folder.appendingPathComponent(name), atomically: false, encoding: .utf8)
        let link = folder.deletingLastPathComponent().appendingPathComponent("old-\(name)")
        try FileManager.default.linkItem(at: folder.appendingPathComponent(name), to: link)
        let inodeBefore = try inode(name, in: folder)
        XCTAssertEqual(try inode("old-\(name)", in: link.deletingLastPathComponent()), inodeBefore)

        try unpacker(folder: folder).unpackedFolder(for: "plain.ctb")
        XCTAssertEqual(try text(name, in: folder), correct)
        XCTAssertNotEqual(try inode(name, in: folder), inodeBefore, "the name was written in place, not renamed over")
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), damaged, "the old file kept its bytes")
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

    /// Eight unpackings of the same table started together leave whole files, all return, and the lock makes them one: each
    /// group is decoded once, by the first, and the others find the files there.
    func testEightUnpackingsHeldTogetherDecodeEachGroupOnce() throws {
        let counts = Counts()
        let unpacker = try unpacker(counts: counts)
        let ready = DispatchSemaphore(value: 0), start = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let failures = OSAllocatedUnfairLock<Int>(initialState: 0)
        for _ in 0..<8 {
            finished.enter()
            DispatchQueue.global().async {
                ready.signal()
                _ = start.wait(timeout: .now() + 60)
                do { try unpacker.unpackedFolder(for: "wrap.tbl") } catch { failures.withLock { $0 += 1 } }
                finished.leave()
            }
        }
        for _ in 0..<8 { XCTAssertEqual(ready.wait(timeout: .now() + 60), .success, "a thread did not start") }
        for _ in 0..<8 { start.signal() }
        XCTAssertEqual(finished.wait(timeout: .now() + 60), .success, "an unpacking did not return")
        XCTAssertEqual(failures.withLock { $0 }, 0)
        XCTAssertEqual(counts.decoded.withLock { $0.sorted() }, [0, 1], "a group was decoded more than once")
        let sample = BrailleTablePackBytes.sample()
        for name in ["chars.uti", "digits.uti", "plain.ctb", "wrap.tbl"] {
            XCTAssertEqual(try text(name, in: unpacker.folder), sample.files[name], name)
        }
        XCTAssertFalse(try names(in: unpacker.folder).contains { $0.hasSuffix(".tmp") })
    }

    /// A damaged group makes the tables that need it unavailable, with one report however often they are asked for, naming the
    /// file and no path; the tables of other groups still unpack; nothing traps.
    func testADamagedGroupMakesItsTablesUnavailableAndIsLoggedOnce() throws {
        let pack = try BrailleTablePack(data: try damagedGroupData())
        let unpacker = BrailleTableUnpacker(pack: pack, folder: try makeSandboxDirectory("BrailleDamaged").appendingPathComponent("tables"))
        try TextMouthPaths.ensureDirectoryStructure()
        let tag = "BRAILLE_TABLES_UNAVAILABLE: chars.uti"
        let before = debugLogLines(containing: tag).count
        for _ in 0..<3 {
            XCTAssertThrowsError(try unpacker.unpackedFolder(for: "plain.ctb")) { error in
                guard case .unavailable = error as? BrailleTableUnpacker.Failure else { return XCTFail("\(error)") }
            }
        }
        XCTAssertNoThrow(try unpacker.unpackedFolder(for: "other.ctb"))
        let lines = debugLogLines(containing: tag)
        XCTAssertEqual(lines.count - before, 1, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains(unpacker.folder.path) }, "a path reached the log")
        XCTAssertEqual(try names(in: unpacker.folder).filter { $0.hasSuffix(".tmp") }, [])
    }

    /// A write that fails (the name is taken by a folder, so the rename cannot put a file there) removes its temporary
    /// file, and logs the file with the error's domain and code, once, whatever the number of tries and never a path.
    func testAFailedWriteRemovesItsTemporaryFileAndLogsTheErrorsDomainAndCodeOnce() throws {
        let unpacker = try unpacker()
        try FileManager.default.createDirectory(at: unpacker.folder.appendingPathComponent("digits.uti"), withIntermediateDirectories: true)
        try TextMouthPaths.ensureDirectoryStructure()
        let tag = "BRAILLE_TABLES_UNAVAILABLE: digits.uti: "
        let before = debugLogLines(containing: tag).count
        for _ in 0..<3 {
            XCTAssertThrowsError(try unpacker.unpackedFolder(for: "plain.ctb"))
        }
        let lines = debugLogLines(containing: tag)
        XCTAssertEqual(lines.count - before, 1, "\(lines)")
        XCTAssertTrue(lines.last?.contains("NSPOSIXErrorDomain") == true, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains(unpacker.folder.path) }, "a path reached the log")
        XCTAssertEqual(try names(in: unpacker.folder).filter { $0.hasSuffix(".tmp") }, [], "a temporary file was left")
    }

    /// Two different tables failing the same way, a full disk or any one error, log one line between them: the logged-once set
    /// is keyed by the error's domain and code, not by the table asked for.
    func testTwoTablesFailingTheSameWayLogOneLine() throws {
        let unpacker = try unpacker()
        // Two files each taken by a folder, so writing either fails with the same error, for two different tables.
        for name in ["digits.uti", "other.ctb"] {
            try FileManager.default.createDirectory(at: unpacker.folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try TextMouthPaths.ensureDirectoryStructure()
        func lines() -> Int {
            debugLogLines(containing: "BRAILLE_TABLES_UNAVAILABLE: ").filter { $0.contains("NSPOSIXErrorDomain") }.count
        }
        let before = lines()
        XCTAssertThrowsError(try unpacker.unpackedFolder(for: "plain.ctb"))
        XCTAssertThrowsError(try unpacker.unpackedFolder(for: "other.ctb"))
        XCTAssertThrowsError(try unpacker.unpackedFolder(for: "plain.ctb"))
        XCTAssertEqual(lines() - before, 1, "one line for the one error, whichever table asked")
    }

    /// The first unpacking of a launch removes the temporaries an earlier run left (the old ones, not one that may still be
    /// written) and, for the app's own unpacker, the folders of other liblouis versions beside its own.
    func testTheFirstUnpackingSweepsStrayTemporariesAndOtherVersions() throws {
        let versions = try makeSandboxDirectory("BrailleVersions")
        let mine = versions.appendingPathComponent("9.9.9", isDirectory: true)
        let older = versions.appendingPathComponent("3.0.0", isDirectory: true)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try "old".write(to: older.appendingPathComponent("en.ctb"), atomically: true, encoding: .utf8)
        let stray = mine.appendingPathComponent(".chars.uti.1234.tmp"), fresh = mine.appendingPathComponent(".digits.uti.5678.tmp")
        try "half".write(to: stray, atomically: true, encoding: .utf8)
        try "half".write(to: fresh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: stray.path)

        // An unpacker that does not sweep versions leaves the other folder, and still removes the old temporary file.
        try unpacker(folder: mine).unpackedFolder(for: "other.ctb")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path), "the stray temporary file stayed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "a recent temporary file may be being written")
        XCTAssertTrue(FileManager.default.fileExists(atPath: older.path))
        // The app's own does sweep the other versions, and keeps its own folder.
        try unpacker(folder: mine, sweeps: true).unpackedFolder(for: "other.ctb")
        XCTAssertFalse(FileManager.default.fileExists(atPath: older.path), "an older version's folder stayed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mine.appendingPathComponent("other.ctb").path))
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
        XCTAssertEqual(Set(ids), BrailleTableCatalog.tablesOfEveryPack, "the tables of every pack are the Mac's whole pack")
        XCTAssertEqual(try XCTUnwrap(BrailleTableUnpacker.app).pack.names.count, 20)
        #else
        XCTAssertTrue(BrailleTableCatalog.tablesOfEveryPack.isSubset(of: ids), "\(ids)")
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
    /// A table whose file vanished between the unpacker's look and the helper's open is unpacked again, once, before it is
    /// called unknown: the first run of a stand-in ends as the helper ends for a table it cannot load (status 2), the second
    /// loads. A tool with no folder (a stand-in) is never asked twice, and a table that stays unloadable is unknown after two.
    func testATableThatVanishedIsUnpackedAgainOnceBeforeItIsCalledUnknown() throws {
        let limits = WatchedProcess.Limits(maximumSeconds: 10, maximumResidentBytes: 1 << 30, maximumStalledSeconds: 10, pollInterval: 0.1)
        let work = try makeSandboxDirectory("BrailleVanished")
        func tool(calls: OSAllocatedUnfairLock<Int>, statuses: [Int], withFolder: Bool) -> BrailleTranslator.Tool {
            BrailleTranslator.Tool(
                command: { _, _, _, _ in
                    let call = calls.withLock { total -> Int in total += 1; return total }
                    return (URL(fileURLWithPath: "/bin/sh"), ["-c", "exit \(statuses[min(call, statuses.count) - 1])"])
                },
                limits: { _, _ in limits },
                residentMemory: { _ in nil },
                tablesFolder: { _ in withFolder ? URL(fileURLWithPath: "/var/empty", isDirectory: true) : nil }
            )
        }
        let again = OSAllocatedUnfairLock<Int>(initialState: 0)
        try BrailleTranslator.$tool.withValue(tool(calls: again, statuses: [2, 0], withFolder: true)) {
            try BrailleTranslator.check(table: "en-ueb-g1.ctb", workingIn: work)
        }
        XCTAssertEqual(again.withLock { $0 }, 2)

        let alone = OSAllocatedUnfairLock<Int>(initialState: 0)
        try BrailleTranslator.$tool.withValue(tool(calls: alone, statuses: [2], withFolder: false)) {
            XCTAssertThrowsError(try BrailleTranslator.check(table: "en-ueb-g1.ctb", workingIn: work)) {
                XCTAssertEqual($0 as? BrailleTranslator.Failure, .unknownTable("en-ueb-g1.ctb"))
            }
        }
        XCTAssertEqual(alone.withLock { $0 }, 1, "a tool with no folder was asked twice")

        let never = OSAllocatedUnfairLock<Int>(initialState: 0)
        try BrailleTranslator.$tool.withValue(tool(calls: never, statuses: [2], withFolder: true)) {
            XCTAssertThrowsError(try BrailleTranslator.check(table: "en-ueb-g1.ctb", workingIn: work)) {
                XCTAssertEqual($0 as? BrailleTranslator.Failure, .unknownTable("en-ueb-g1.ctb"))
            }
        }
        XCTAssertEqual(never.withLock { $0 }, 2)
    }

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
