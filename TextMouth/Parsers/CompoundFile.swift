import Foundation

// MARK: - Damage

/// Why a compound file, or a format stored in one, could not be read: a
/// number, offset, count, or index the file holds does not fit the file.
/// The reason is for logs and tests; a listener hears the sentence of the
/// reader that met it (`WordDocumentReader` turns it into
/// `TextutilConverter.Failure.unreadable`).
struct OLEDamage: Error, Equatable, LocalizedError {
    /// A short phrase saying what did not fit, such as "a chain loops".
    let reason: String

    var errorDescription: String? {
        "This file could not be read as a compound file. It may be damaged, or another kind of file."
    }
}

// MARK: - Bounds-Checked Bytes

/// A byte array read with bounds-checked little-endian reads. Every read of
/// a number or a range that falls outside the bytes throws `OLEDamage`
/// instead of trapping, so a hostile file's offsets can end a read but never
/// the app.
struct OLEBytes: Sendable {
    /// The bytes, indexed from zero whatever slice of a `Data` they came from.
    let bytes: [UInt8]

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var count: Int { bytes.count }

    /// Whether `length` bytes starting at `offset` lie inside the bytes. The
    /// test is made without adding, so no offset and length can overflow it.
    func contains(offset: Int, length: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= bytes.count && length <= bytes.count - offset
    }

    /// The byte at `offset`.
    func u8(_ offset: Int) throws -> Int {
        guard contains(offset: offset, length: 1) else { throw OLEDamage(reason: "a byte at \(offset) is past the end") }
        return Int(bytes[offset])
    }

    /// The unsigned 16-bit number at `offset`.
    func u16(_ offset: Int) throws -> Int {
        guard contains(offset: offset, length: 2) else { throw OLEDamage(reason: "a number at \(offset) is past the end") }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    /// The unsigned 32-bit number at `offset`.
    func u32(_ offset: Int) throws -> Int {
        guard contains(offset: offset, length: 4) else { throw OLEDamage(reason: "a number at \(offset) is past the end") }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }

    /// The signed 16-bit number at `offset`.
    func i16(_ offset: Int) throws -> Int {
        let value = try u16(offset)
        return value >= 0x8000 ? value - 0x10000 : value
    }

    /// The unsigned 64-bit number at `offset`, which must fit an `Int`.
    func u64(_ offset: Int) throws -> Int {
        let low = try u32(offset)
        let high = try u32(offset + 4)
        guard high < 0x8000_0000 else { throw OLEDamage(reason: "a 64-bit number at \(offset) is too large") }
        return high << 32 | low
    }

    /// The `length` bytes at `offset`.
    func slice(offset: Int, length: Int) throws -> ArraySlice<UInt8> {
        guard contains(offset: offset, length: length) else {
            throw OLEDamage(reason: "\(length) bytes at \(offset) are past the end")
        }
        return bytes[offset..<offset + length]
    }
}

// MARK: - Compound File

/// A Microsoft compound file ([MS-CFB], also called OLE2 or a structured
/// storage file), read from memory: the container of Word 97-2003 documents
/// and of legacy Excel and PowerPoint files. It returns the bytes of a
/// stream in the root storage by name.
///
/// A file is a header, then sectors of 512 bytes (version 3) or 4096
/// (version 4). The header names the sectors of the **FAT**, a table that
/// gives, for each sector, the next sector of the same stream; with more than
/// 109 FAT sectors, a chain of **DIFAT** sectors names the rest. The
/// **directory** (a stream of 128-byte entries, kept as a red-black tree)
/// names every stream and where its chain starts. A stream smaller than
/// 4096 bytes lives in the **mini stream**, itself a stream, cut into 64-byte
/// mini sectors chained by the **mini FAT**.
///
/// The file is untrusted input, so:
/// - every sector index is checked against the sectors the file holds;
/// - a chain is followed only as far as the stream's declared size needs,
///   and a sector reached twice is a loop, which ends the read;
/// - a stream's declared size is held to the size of the file;
/// - the DIFAT chain and the directory's tree are walked with a set of what
///   was seen, and the tree with a stack of its own, so a loop in either
///   ends the read.
///
/// Written from the specification [MS-CFB]; the maps of the algorithm were
/// rust-cfb (MIT) and OLEKit (Apache 2.0), read, never copied.
struct CompoundFile: Sendable {

    // MARK: Constants

    /// The first eight bytes of every compound file.
    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    /// The sector numbers with a special meaning ([MS-CFB] 2.1).
    private static let maximumRegularSector = 0xFFFF_FFFA
    private static let endOfChain = 0xFFFF_FFFE
    private static let freeSector = 0xFFFF_FFFF
    /// "No entry" in the directory's links.
    private static let noStream = 0xFFFF_FFFF

    /// The size of a mini sector: always 64 bytes ([MS-CFB] 2.2, mini sector shift 6).
    private static let miniSectorSize = 64
    /// The size of a directory entry.
    private static let directoryEntrySize = 128
    /// The streams smaller than this live in the mini stream.
    private static let miniStreamCutoff = 4096
    /// How many FAT sector numbers the header holds.
    private static let headerDIFATCount = 109

    // MARK: Directory Entries

    /// One stream or storage in the root storage.
    struct Entry: Equatable, Sendable {
        /// The entry's name as the file spells it.
        let name: String
        /// Whether it is a stream (otherwise a storage).
        let isStream: Bool
        /// The first sector of its chain: of the mini stream for a small stream.
        fileprivate let startSector: Int
        /// The declared size in bytes.
        fileprivate let size: Int
    }

    // MARK: Stored State

    private let bytes: OLEBytes
    private let sectorSize: Int
    /// How many sectors the file holds after its header.
    private let sectorCount: Int
    /// The FAT: for each sector, the next sector of its chain.
    private let fat: [Int]
    /// The mini FAT: the same for the mini stream.
    private let miniFAT: [Int]
    /// The mini stream: the bytes the small streams are cut from.
    private let miniStream: OLEBytes
    /// The streams and storages in the root storage, in no particular order.
    let rootEntries: [Entry]

    // MARK: Opening

    /// Whether `data` begins with the compound file signature.
    static func hasSignature(_ data: Data) -> Bool {
        data.starts(with: signature)
    }

    /// Reads the structure of the compound file in `data`: the header, the
    /// FAT, the mini FAT, the directory, and the mini stream.
    /// - Throws: `OLEDamage` for a file that is not a compound file or whose
    ///   structure does not fit it.
    init(_ data: Data) throws {
        guard Self.hasSignature(data) else { throw OLEDamage(reason: "the signature is missing") }
        let bytes = OLEBytes(data)
        self.bytes = bytes

        // The header: the version fixes the sector size.
        let majorVersion = try bytes.u16(26)
        guard try bytes.u16(28) == 0xFFFE else { throw OLEDamage(reason: "the byte order is not little-endian") }
        let sectorShift = try bytes.u16(30)
        guard (majorVersion == 3 && sectorShift == 9) || (majorVersion == 4 && sectorShift == 12) else {
            throw OLEDamage(reason: "version \(majorVersion) with sector shift \(sectorShift)")
        }
        guard try bytes.u16(32) == 6 else { throw OLEDamage(reason: "the mini sector size is not 64 bytes") }
        guard try bytes.u32(56) == Self.miniStreamCutoff else { throw OLEDamage(reason: "the mini stream cutoff is not 4096") }
        let sectorSize = 1 << sectorShift
        self.sectorSize = sectorSize
        // The header fills the first sector; a version 4 file's is 4096 bytes.
        guard bytes.count >= sectorSize else { throw OLEDamage(reason: "the file ends inside its header") }
        let sectorCount = (bytes.count - sectorSize) / sectorSize
        self.sectorCount = sectorCount

        // The FAT.
        let fat = try Self.readFAT(bytes: bytes, sectorSize: sectorSize, sectorCount: sectorCount)
        self.fat = fat

        // The directory: the sectors of its chain, joined.
        let firstDirectorySector = try bytes.u32(48)
        var directoryBytes: [UInt8] = []
        for sector in try Self.readChain(from: firstDirectorySector, in: fat, sectorCount: sectorCount, neededSectors: nil) {
            directoryBytes += try bytes.slice(offset: (sector + 1) * sectorSize, length: sectorSize)
        }
        let directory = OLEBytes(directoryBytes)

        // The mini FAT, whose sectors are in the FAT.
        let firstMiniFATSector = try bytes.u32(60)
        var miniFAT: [Int] = []
        if firstMiniFATSector != Self.endOfChain, firstMiniFATSector != Self.freeSector {
            for sector in try Self.readChain(from: firstMiniFATSector, in: fat, sectorCount: sectorCount, neededSectors: nil) {
                miniFAT += try Self.u32Values(in: bytes, offset: (sector + 1) * sectorSize, count: sectorSize / 4)
            }
        }
        self.miniFAT = miniFAT

        // The root entry gives the mini stream's chain and size.
        let sizeIsLow32Bits = majorVersion == 3
        let root = try Self.entry(at: 0, in: directory, sizeIsLow32Bits: sizeIsLow32Bits)
        guard root.type == 5 else { throw OLEDamage(reason: "the directory has no root entry") }
        var miniStream = OLEBytes([UInt8]())
        if root.size > 0, root.startSector != Self.endOfChain {
            miniStream = OLEBytes(try Self.readRegularStream(
                from: root.startSector, size: root.size, bytes: bytes, sectorSize: sectorSize, fat: fat, sectorCount: sectorCount
            ))
        }
        self.miniStream = miniStream

        // The root storage's children: a walk over the tree, with a stack.
        self.rootEntries = try Self.rootChildren(of: root, in: directory, sizeIsLow32Bits: sizeIsLow32Bits)
    }

    // MARK: Reading a Stream

    /// The entry named `name` in the root storage (compared without regard to
    /// case, as the specification compares), or nil.
    func entry(named name: String) -> Entry? {
        let wanted = name.uppercased()
        return rootEntries.first { $0.name.uppercased() == wanted }
    }

    /// The bytes of the stream `name` in the root storage, or nil when the
    /// root has no stream of that name.
    /// - Throws: `OLEDamage` when the stream's declared size or chain does not
    ///   fit the file.
    func stream(named name: String) throws -> Data? {
        guard let entry = entry(named: name), entry.isStream else { return nil }
        return Data(try contents(of: entry))
    }

    /// The bytes of `entry`, held to its declared size.
    private func contents(of entry: Entry) throws -> [UInt8] {
        if entry.size < Self.miniStreamCutoff {
            return try readMiniStream(from: entry.startSector, size: entry.size)
        }
        return try Self.readRegularStream(
            from: entry.startSector, size: entry.size, bytes: bytes, sectorSize: sectorSize, fat: fat, sectorCount: sectorCount
        )
    }

    /// A small stream: `size` bytes cut from the mini stream along the mini FAT.
    private func readMiniStream(from start: Int, size: Int) throws -> [UInt8] {
        guard size > 0 else { return [] }
        guard size <= miniStream.count else { throw OLEDamage(reason: "a small stream is larger than the mini stream") }
        let needed = (size + Self.miniSectorSize - 1) / Self.miniSectorSize
        let chain = try Self.readChain(
            from: start, in: miniFAT, sectorCount: miniStream.count / Self.miniSectorSize, neededSectors: needed
        )
        var result: [UInt8] = []
        result.reserveCapacity(needed * Self.miniSectorSize)
        for sector in chain {
            result += try miniStream.slice(offset: sector * Self.miniSectorSize, length: Self.miniSectorSize)
        }
        return Array(result.prefix(size))
    }

    /// A large stream: `size` bytes along the FAT chain from `start`. The
    /// size is held to the file's before any byte is gathered.
    private static func readRegularStream(
        from start: Int, size: Int, bytes: OLEBytes, sectorSize: Int, fat: [Int], sectorCount: Int
    ) throws -> [UInt8] {
        guard size <= bytes.count else { throw OLEDamage(reason: "a stream is declared larger than the file") }
        guard size > 0 else { return [] }
        let needed = (size + sectorSize - 1) / sectorSize
        let chain = try readChain(from: start, in: fat, sectorCount: sectorCount, neededSectors: needed)
        var result: [UInt8] = []
        result.reserveCapacity(needed * sectorSize)
        for sector in chain {
            result += try bytes.slice(offset: (sector + 1) * sectorSize, length: sectorSize)
        }
        return Array(result.prefix(size))
    }

    // MARK: Chains

    /// The sectors of the chain that starts at `start` in `table`, in order.
    /// - Parameters:
    ///   - sectorCount: how many sectors exist; a number at or past it is damage.
    ///   - neededSectors: the sectors wanted, or nil for the whole chain. A
    ///     chain longer than wanted is cut there; one that ends sooner is damage.
    /// - Throws: `OLEDamage` for a sector out of range, a free or special
    ///   sector inside the chain, a chain that loops, or a chain too short.
    private static func readChain(from start: Int, in table: [Int], sectorCount: Int, neededSectors: Int?) throws -> [Int] {
        var chain: [Int] = []
        // The sectors passed: reaching one again is a loop, and there are
        // only as many to pass as the table has entries.
        var passed: Set<Int> = []
        var sector = start
        while sector != endOfChain {
            if let neededSectors, chain.count == neededSectors { return chain }
            guard sector <= maximumRegularSector, sector < sectorCount, sector < table.count else {
                throw OLEDamage(reason: "a chain reaches sector \(sector), which does not exist")
            }
            guard passed.insert(sector).inserted else { throw OLEDamage(reason: "a chain loops") }
            chain.append(sector)
            sector = table[sector]
        }
        if let neededSectors, chain.count < neededSectors {
            throw OLEDamage(reason: "a chain has \(chain.count) sectors where its stream needs \(neededSectors)")
        }
        return chain
    }

    /// `count` unsigned 32-bit numbers from `offset`.
    private static func u32Values(in bytes: OLEBytes, offset: Int, count: Int) throws -> [Int] {
        var values: [Int] = []
        values.reserveCapacity(count)
        for index in 0..<count {
            values.append(try bytes.u32(offset + index * 4))
        }
        return values
    }

    /// The FAT: the entries of the sectors the header and the DIFAT chain name.
    private static func readFAT(bytes: OLEBytes, sectorSize: Int, sectorCount: Int) throws -> [Int] {
        // The FAT sectors' numbers: the header's, then the DIFAT chain's.
        var fatSectors = try u32Values(in: bytes, offset: 76, count: headerDIFATCount)
        var difatSector = try bytes.u32(68)
        // The chain is read for the sectors the header declares, no more, and
        // never twice over the same sector: a loop ends the read.
        let declaredDIFATSectors = try bytes.u32(72)
        guard declaredDIFATSectors <= sectorCount else { throw OLEDamage(reason: "more DIFAT sectors than the file holds") }
        var seen: Set<Int> = []
        while difatSector != endOfChain, difatSector != freeSector, seen.count < declaredDIFATSectors {
            guard difatSector < sectorCount else { throw OLEDamage(reason: "a DIFAT sector \(difatSector) does not exist") }
            guard seen.insert(difatSector).inserted else { throw OLEDamage(reason: "the DIFAT chain loops") }
            let offset = (difatSector + 1) * sectorSize
            let entries = sectorSize / 4 - 1
            fatSectors += try u32Values(in: bytes, offset: offset, count: entries)
            // The last number of a DIFAT sector is the next one's.
            difatSector = try bytes.u32(offset + entries * 4)
        }
        // The numbers in use; the file cannot have more FAT sectors than sectors.
        let inUse = fatSectors.filter { $0 != freeSector }
        guard inUse.count <= sectorCount else { throw OLEDamage(reason: "more FAT sectors than the file holds") }
        var fat: [Int] = []
        for sector in inUse {
            guard sector < sectorCount else { throw OLEDamage(reason: "a FAT sector \(sector) does not exist") }
            fat += try u32Values(in: bytes, offset: (sector + 1) * sectorSize, count: sectorSize / 4)
        }
        return fat
    }

    // MARK: Directory

    /// A directory entry as the directory spells it.
    private struct RawEntry {
        let name: String
        let type: Int
        let left: Int
        let right: Int
        let child: Int
        let startSector: Int
        let size: Int
    }

    /// The directory entry with index `index`. A version 3 file's size is its
    /// low 32 bits alone (`sizeIsLow32Bits`); a version 4 file's may use the
    /// high bits, which the stream read then holds to the file's size.
    private static func entry(at index: Int, in directory: OLEBytes, sizeIsLow32Bits: Bool) throws -> RawEntry {
        let base = index * directoryEntrySize
        guard directory.contains(offset: base, length: directoryEntrySize) else {
            throw OLEDamage(reason: "directory entry \(index) is past the directory")
        }
        // The name: UTF-16LE with a terminating null, 64 bytes at most.
        let nameLength = try directory.u16(base + 64)
        guard nameLength <= 64, nameLength % 2 == 0 else { throw OLEDamage(reason: "a directory name is \(nameLength) bytes long") }
        var units: [UInt16] = []
        for position in 0..<max(nameLength / 2 - 1, 0) {
            units.append(UInt16(try directory.u16(base + position * 2)))
        }
        return RawEntry(
            name: String(decoding: units, as: UTF16.self),
            type: try directory.u8(base + 66),
            left: try directory.u32(base + 68),
            right: try directory.u32(base + 72),
            child: try directory.u32(base + 76),
            startSector: try directory.u32(base + 116),
            size: try (sizeIsLow32Bits ? directory.u32(base + 120) : directory.u64(base + 120))
        )
    }

    /// The streams and storages in the tree that hangs from `root`'s child,
    /// walked with a stack and a set of the entries seen: an entry reached
    /// twice is a loop, and ends the read.
    private static func rootChildren(of root: RawEntry, in directory: OLEBytes, sizeIsLow32Bits: Bool) throws -> [Entry] {
        var children: [Entry] = []
        var seen: Set<Int> = []
        var pending = [root.child]
        while let index = pending.popLast() {
            if index == noStream { continue }
            guard seen.insert(index).inserted else { throw OLEDamage(reason: "the directory tree loops") }
            let entry = try Self.entry(at: index, in: directory, sizeIsLow32Bits: sizeIsLow32Bits)
            if entry.type == 1 || entry.type == 2 {
                children.append(Entry(name: entry.name, isStream: entry.type == 2, startSector: entry.startSector, size: entry.size))
            }
            pending.append(entry.left)
            pending.append(entry.right)
        }
        return children
    }
}
