import Foundation

/// A sentence for the debug log saying why a braille table pack, or a table in it, cannot be used.
struct BrailleTablePackFailure: Error, CustomStringConvertible, Equatable {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// The reader of `BrailleTables.pack` (FR40): liblouis's tables, one compressed blob for each group of files whose names
/// share a prefix, and an index of every file.
///
/// The container is `PackContainer`'s (the magic `TMBT`, version 1, the header's count the number of files); the builder is
/// `Scripts/packs/braille_tables.py`. The pack holds:
/// - the blob `index`, one JSON document, `{"v": 1, "liblouis": "3.39.0", "files": [...]}`, whose entries, in name order,
///   are each file's name (`n`), its group (`g`), its offset (`o`) and length (`l`) in the group's decoded bytes, the SHA-256
///   of its bytes (`h`), the files it includes (`i`), the header fields the catalog reads when it is a table (`m`), and, when it only includes other
///   tables, those (`t`);
/// - the blobs `g000`, `g001`, ..., each one LZMA stream of its files' bytes one after another.
///
/// Opening the pack reads and checks the index, and nothing else: no group is decoded until a file of it is wanted, so the
/// catalog, which lists tables from the index, unpacks nothing. The pack is untrusted bytes: a damaged or hostile one fails
/// (`BrailleTablePackFailure`) and never traps. Every name is plain (letters, digits, and `_.+-`, with no leading dot), so
/// no name is ever a path; every place lies inside its group; every group's entry count is the number of files that name it;
/// and every include is a file of the pack.
///
/// Foundation and the container only.
struct BrailleTablePack: Sendable {
    /// One file of the pack, as the index describes it.
    struct File: Sendable, Equatable {
        /// The file's name in the tables folder, such as "en-ueb-g2.ctb".
        let name: String
        /// The number of the group blob that holds the file's bytes.
        let group: Int
        /// Where the file begins in its group's decoded bytes, and how many bytes it has.
        let offset: Int
        let length: Int
        /// The SHA-256 of the file's bytes, in lowercase hexadecimal, which the unpacker checks a kept file against.
        let sha256: String
        /// The files the file includes, in the order its `include` lines name them.
        let includes: [String]
        /// The header fields the catalog reads, by lowercase key, for a file that has a `type`; empty for any other.
        let fields: [String: String]
        /// The tables the file includes when it does nothing else (`BrailleTableCatalog.includeOnlyTargets(ofTableAt:)`'s
        /// answer for it), or nil.
        let includeOnly: [String]?
    }

    /// Which of the release's literary tables write braille from print only (`direction: forward`), by file name, judged over the whole release though a pack carries some of its files: the Mac, which carries four, judges
    /// VoiceOver's older copies of a table by it whenever the release has a table of that file name: a table the release marks
    /// print-only is print-only on the Mac, and a mark in VoiceOver's own file stands too (`BrailleTableCatalog`).
    struct ReleaseDirections: Sendable, Equatable {
        /// The names of the tables that write braille only. The tables that are not marked need no list: nothing reads one.
        let printOnly: Set<String>
    }

    /// The file's name inside an app's resources.
    static let resourceName = "BrailleTables"  // l10n: no (a resource's file name, never shown)
    static let resourceExtension = "pack"

    /// What a `BrailleTables.pack` is, for the container: the magic and the version, and the limits that stop a hostile
    /// header. The real pack has under 500 files in under 100 groups, and the biggest group is 3 MB raw.
    static let format = PackContainer.Format(
        magic: Array("TMBT".utf8), version: 1, largestCount: 100_000, largestBlobCount: 4_096, largestRawSize: 64 * 1024 * 1024
    )

    /// The index's version, which this reader accepts alone.
    private static let supportedIndexVersion = 1
    /// The most files an index may list, the most an include list may hold, and the longest a header value or a name may be.
    private static let largestIncludeCount = 1_000
    private static let largestFieldLength = 1_000
    private static let largestNameLength = 255
    /// The index's blob.
    private static let indexBlobName = "index"

    /// The container: the mapped bytes and the directory.
    private let container: PackContainer
    /// The liblouis release the tables are from, such as "3.39.0".
    let liblouisVersion: String
    /// The release's directions (`ReleaseDirections`), empty for a pack whose index names none.
    let releaseDirections: ReleaseDirections
    /// Every file, by name.
    let files: [String: File]
    /// Every file's name, in order.
    let names: [String]

    // MARK: - Opening

    /// The pack in the main bundle, or nil when the bundle has none. Throws when it is there and cannot be used.
    static func inMainBundle() throws -> BrailleTablePack? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: resourceExtension) else { return nil }
        return try BrailleTablePack(contentsOf: url)
    }

    /// The pack in the file at `url`, mapped rather than read.
    init(contentsOf url: URL) throws {
        try self.init(opening: { try PackContainer(contentsOf: url, format: Self.format) })
    }

    /// The pack in `data`, whose header, directory, and index are checked here.
    init(data: Data) throws {
        try self.init(opening: { try PackContainer(data: data, format: Self.format) })
    }

    /// The pack that `open` makes a container of, with its index read and checked. The container's failures are given this
    /// reader's own failure type.
    private init(opening open: () throws -> PackContainer) throws {
        let opened: PackContainer
        let document: IndexDocument
        do {
            opened = try open()
            guard opened.blobs[Self.indexBlobName] != nil else { throw PackContainerFailure("the pack has no index blob") }  // l10n: no (English text for the debug log, never shown)
            document = try Self.decodeIndex(try opened.decodedBlob(named: Self.indexBlobName))
        } catch let failure as PackContainerFailure {
            throw BrailleTablePackFailure(failure.description)
        }
        let checked = try Self.checkedFiles(of: document, in: opened)
        self.container = opened
        self.liblouisVersion = document.liblouis
        self.releaseDirections = try Self.checkedDirections(of: document)
        self.files = checked
        self.names = checked.keys.sorted()
    }

    // MARK: - The index

    /// The index document as the builder writes it (`build_index` in braille_tables.py), before it is checked.
    private struct IndexDocument: Decodable {
        let v: Int
        let liblouis: String
        let files: [IndexFile]
        /// The release's tables that write braille only (`ReleaseDirections`).
        let f: [String]?
    }

    /// One file's entry of the index.
    private struct IndexFile: Decodable {
        let n: String
        let g: Int
        let o: Int
        let l: Int
        let h: String
        let i: [String]?
        let m: [String: String]?
        let t: [String]?
    }

    /// The index in `bytes`, decoded: a document of the supported version.
    private static func decodeIndex(_ bytes: [UInt8]) throws -> IndexDocument {
        let document: IndexDocument
        do {
            document = try JSONDecoder().decode(IndexDocument.self, from: Data(bytes))
        } catch {
            throw BrailleTablePackFailure("the index is not valid: \(error.localizedDescription)")  // l10n: no (English text for the debug log, never shown)
        }
        guard document.v == supportedIndexVersion else {
            throw BrailleTablePackFailure("the index's version is \(document.v), not \(supportedIndexVersion)")  // l10n: no (English text for the debug log, never shown)
        }
        guard isPlainName(document.liblouis), document.liblouis.count <= 32 else {
            throw BrailleTablePackFailure("the index names no usable liblouis version")  // l10n: no (English text for the debug log, never shown)
        }
        return document
    }

    /// Whether `name` is plain enough to be a file in the tables folder and a part of a path: not empty, at most 255 ASCII
    /// letters, digits, and `_.+-`, and not starting with a dot, so it is never a path, a hidden file, `.`, or `..`.
    static func isPlainName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= largestNameLength, name.utf8.first != UInt8(ascii: ".") else { return false }
        return name.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-")
        }
    }

    /// The release's directions in `document`, every name plain and no list absurdly long.
    private static func checkedDirections(of document: IndexDocument) throws -> ReleaseDirections {
        let printOnly = document.f ?? []
        guard printOnly.count <= 10_000, printOnly.allSatisfy(isPlainName) else {
            throw BrailleTablePackFailure("the index's directions are not file names")  // l10n: no (English text for the debug log, never shown)
        }
        return ReleaseDirections(printOnly: Set(printOnly))
    }

    /// The name of the blob that holds group `number`.
    static func groupBlobName(_ number: Int) -> String {
        let digits = String(number)
        // At least three digits, as the builder names them ("g000"); a negative number gives a name no blob has.
        return "g" + String(repeating: "0", count: max(0, 3 - digits.count)) + digits
    }

    /// The files of `document`, checked against `container`: the count the header gives, plain unique names, a group blob
    /// that exists for each file with the file inside it, each group's entry count equal to the files that name it, and
    /// includes that are files of the pack.
    private static func checkedFiles(of document: IndexDocument, in container: PackContainer) throws -> [String: File] {
        guard document.files.count == container.count else {
            throw BrailleTablePackFailure("the header says \(container.count) files and the index lists \(document.files.count)")  // l10n: no (English text for the debug log, never shown)
        }
        var files: [String: File] = [:]
        var perGroup: [Int: Int] = [:]
        for entry in document.files {
            guard isPlainName(entry.n) else { throw BrailleTablePackFailure("the index lists a file with an unusable name")  }  // l10n: no (English text for the debug log, never shown)
            guard files[entry.n] == nil else { throw BrailleTablePackFailure("the index lists \(entry.n) twice") }  // l10n: no (English text for the debug log, never shown)
            guard let blob = container.blobs[groupBlobName(entry.g)] else {
                throw BrailleTablePackFailure("\(entry.n) is in group \(entry.g), which the pack lacks")  // l10n: no (English text for the debug log, never shown)
            }
            // A place inside the group's decoded bytes, with no sum that can overflow.
            guard entry.o >= 0, entry.l >= 0, entry.o <= blob.rawSize, entry.l <= blob.rawSize - entry.o else {
                throw BrailleTablePackFailure("\(entry.n) lies outside its group")  // l10n: no (English text for the debug log, never shown)
            }
            guard entry.h.utf8.count == 64, entry.h.utf8.allSatisfy({ ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f")) })
            else { throw BrailleTablePackFailure("the index gives \(entry.n) no SHA-256") }  // l10n: no (English text for the debug log, never shown)
            let includes = entry.i ?? []
            let fields = entry.m ?? [:]
            guard includes.count <= largestIncludeCount, (entry.t?.count ?? 0) <= largestIncludeCount,
                  fields.count <= 64, fields.allSatisfy({ $0.key.utf8.count <= 64 && $0.value.utf8.count <= largestFieldLength })
            else { throw BrailleTablePackFailure("the index entry of \(entry.n) is too large") }  // l10n: no (English text for the debug log, never shown)
            perGroup[entry.g, default: 0] += 1
            files[entry.n] = File(
                name: entry.n, group: entry.g, offset: entry.o, length: entry.l, sha256: entry.h,
                includes: includes, fields: fields, includeOnly: entry.t
            )
        }
        for (name, blob) in container.blobs where name != indexBlobName {
            guard name.hasPrefix("g"), let number = Int(name.dropFirst()), groupBlobName(number) == name else {
                throw BrailleTablePackFailure("the pack has a blob named \(name), which is neither the index nor a group")  // l10n: no (English text for the debug log, never shown)
            }
            guard perGroup[number, default: 0] == blob.count else {
                throw BrailleTablePackFailure("the group \(name) holds \(blob.count) files and the index gives it \(perGroup[number, default: 0])")  // l10n: no (English text for the debug log, never shown)
            }
        }
        for file in files.values {
            for target in file.includes where files[target] == nil {
                throw BrailleTablePackFailure("\(file.name) includes \(target), which the pack lacks")  // l10n: no (English text for the debug log, never shown)
            }
        }
        return files
    }

    // MARK: - Reading

    /// The names `name` reaches by includes, itself first and then each in the order it is first reached: the files a
    /// table needs in one folder to load. Nil when the pack has no file `name`; a loop of includes is walked once.
    func closure(of name: String) -> [String]? {
        guard files[name] != nil else { return nil }
        var order: [String] = []
        var seen: Set<String> = []
        var pending = [name]
        while !pending.isEmpty {
            let current = pending.removeFirst()
            guard seen.insert(current).inserted else { continue }
            order.append(current)
            // Every include is a file of the pack (checked as the pack opened), so none is skipped here.
            pending.append(contentsOf: files[current]?.includes ?? [])
        }
        return order
    }

    /// The decoded bytes of group `number`.
    func decodedGroup(_ number: Int) throws -> [UInt8] {
        do {
            return try container.decodedBlob(named: Self.groupBlobName(number))
        } catch let failure as PackContainerFailure {
            throw BrailleTablePackFailure(failure.description)
        }
    }

    /// The bytes of `file` in `group`, the decoded bytes of its group, or nil when the group is shorter than the file's place
    /// (a group that decoded to its directory's raw size is never).
    static func bytes(of file: File, in group: [UInt8]) -> Data? {
        guard file.offset >= 0, file.length >= 0, file.offset <= group.count, file.length <= group.count - file.offset else { return nil }
        return Data(group[file.offset..<(file.offset + file.length)])
    }
}
