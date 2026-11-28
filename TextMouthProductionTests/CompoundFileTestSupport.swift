import Foundation
@testable import TextMouth

// MARK: - Building Compound Files in Code

/// Writes a compound file ([MS-CFB]) from named streams, so a test can make
/// the files it reads, and damage them at places it knows. Only what the
/// tests need is written: every stream in the root storage, the directory
/// as one right-leaning list (a valid tree, if not a balanced one), and the
/// FAT and DIFAT sectors in full.
struct CompoundFileBuilder {
    /// The root storage's streams, in the order they are written.
    var streams: [(name: String, data: [UInt8])] = []
    /// Version 3 (512-byte sectors) or version 4 (4096-byte sectors).
    var sectorShift = 9

    /// Where the pieces of a built file are, for tests that damage it.
    struct Layout {
        var sectorSize: Int
        /// The first sector of the directory.
        var directorySector: Int
        /// The sector numbers of the FAT sectors.
        var fatSectors: [Int]
        /// The first sector of each stream, by name (of the mini stream for a small one).
        var startSectors: [String: Int]
        /// The sector numbers of the DIFAT sectors.
        var difatSectors: [Int]

        /// The file offset of sector `sector`.
        func offset(ofSector sector: Int) -> Int { (sector + 1) * sectorSize }

        /// The file offset of directory entry `index` (the directory is one
        /// run of sectors in this builder).
        func offset(ofDirectoryEntry index: Int) -> Int { offset(ofSector: directorySector) + index * 128 }

        /// The file offset of the FAT entry for `sector`.
        func offset(ofFATEntryFor sector: Int) -> Int {
            let perSector = sectorSize / 4
            return offset(ofSector: fatSectors[sector / perSector]) + (sector % perSector) * 4
        }
    }

    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let free: UInt32 = 0xFFFF_FFFF

    /// The built file and where its pieces are.
    func build() -> (data: Data, layout: Layout) {
        let sectorSize = 1 << sectorShift
        let perSector = sectorSize / 4
        var sectors: [[UInt8]] = []
        var fat: [UInt32] = []

        // Appends `bytes` as a chain of sectors and returns the first one.
        func allocate(_ bytes: [UInt8]) -> Int {
            guard !bytes.isEmpty else { return Int(Self.endOfChain) }
            let first = sectors.count
            let count = (bytes.count + sectorSize - 1) / sectorSize
            for index in 0..<count {
                let piece = Array(bytes[index * sectorSize..<min(bytes.count, (index + 1) * sectorSize)])
                sectors.append(piece + [UInt8](repeating: 0, count: sectorSize - piece.count))
                fat.append(index + 1 == count ? Self.endOfChain : UInt32(first + index + 1))
            }
            return first
        }

        // Small streams share the mini stream.
        var miniBytes: [UInt8] = []
        var miniFAT: [UInt32] = []
        var starts: [String: Int] = [:]
        for stream in streams where stream.data.count < 4096 && !stream.data.isEmpty {
            starts[stream.name] = miniBytes.count / 64
            let count = (stream.data.count + 63) / 64
            for index in 0..<count {
                miniFAT.append(index + 1 == count ? Self.endOfChain : UInt32(miniBytes.count / 64 + index + 1))
            }
            miniBytes += stream.data + [UInt8](repeating: 0, count: count * 64 - stream.data.count)
        }
        let miniStart = allocate(miniBytes)
        for stream in streams where stream.data.count >= 4096 { starts[stream.name] = allocate(stream.data) }
        for stream in streams where stream.data.isEmpty { starts[stream.name] = Int(Self.endOfChain) }

        // The mini FAT.
        var miniFATBytes: [UInt8] = []
        for value in miniFAT { miniFATBytes += Self.bytes(of: value) }
        // The unused entries of the mini FAT's last sector are free.
        while !miniFATBytes.isEmpty && miniFATBytes.count % sectorSize != 0 { miniFATBytes += Self.bytes(of: Self.free) }
        let miniFATStart = allocate(miniFATBytes)

        // The directory: the root, then the streams as a right-leaning list.
        var directory = Self.directoryEntry(
            name: "Root Entry", type: 5, left: Self.free, right: Self.free,
            child: streams.isEmpty ? Self.free : 1, start: UInt32(truncatingIfNeeded: miniStart), size: UInt64(miniBytes.count)
        )
        for (index, stream) in streams.enumerated() {
            directory += Self.directoryEntry(
                name: stream.name, type: 2, left: Self.free,
                right: index + 1 < streams.count ? UInt32(index + 2) : Self.free,
                child: Self.free, start: UInt32(truncatingIfNeeded: starts[stream.name] ?? 0), size: UInt64(stream.data.count)
            )
        }
        // The directory fills whole sectors; the unused entries are empty.
        let entriesPerSector = sectorSize / 128
        while (directory.count / 128) % entriesPerSector != 0 {
            directory += Self.directoryEntry(name: "", type: 0, left: Self.free, right: Self.free, child: Self.free, start: 0, size: 0)
        }
        let directoryStart = allocate(directory)

        // The FAT sectors, and the DIFAT sectors when the header's 109 are too few.
        var fatCount = 0
        var difatCount = 0
        while true {
            let total = sectors.count + fatCount + difatCount
            let neededFAT = (total + perSector - 1) / perSector
            let neededDIFAT = neededFAT > 109 ? (neededFAT - 109 + perSector - 2) / (perSector - 1) : 0
            if neededFAT == fatCount && neededDIFAT == difatCount { break }
            fatCount = neededFAT
            difatCount = neededDIFAT
        }
        let fatSectors = Array(sectors.count..<sectors.count + fatCount)
        let difatSectors = Array(sectors.count + fatCount..<sectors.count + fatCount + difatCount)
        for _ in fatSectors { fat.append(0xFFFF_FFFD) }
        for _ in difatSectors { fat.append(0xFFFF_FFFC) }
        while fat.count < fatCount * perSector { fat.append(Self.free) }
        for index in 0..<fatCount {
            var bytes: [UInt8] = []
            for value in fat[index * perSector..<(index + 1) * perSector] { bytes += Self.bytes(of: value) }
            sectors.append(bytes)
        }
        // Each DIFAT sector holds 127 (or 1023) FAT sector numbers, then the next DIFAT sector's.
        for index in 0..<difatCount {
            var bytes: [UInt8] = []
            for slot in 0..<perSector - 1 {
                let position = 109 + index * (perSector - 1) + slot
                bytes += Self.bytes(of: position < fatCount ? UInt32(fatSectors[position]) : Self.free)
            }
            bytes += Self.bytes(of: index + 1 < difatCount ? UInt32(difatSectors[index + 1]) : Self.endOfChain)
            sectors.append(bytes)
        }

        // The header.
        var header = [UInt8](repeating: 0, count: sectorSize)
        func put(_ value: Int, at offset: Int, width: Int) {
            for byte in 0..<width { header[offset + byte] = UInt8((value >> (8 * byte)) & 0xFF) }
        }
        header.replaceSubrange(0..<8, with: CompoundFile.signature)
        put(0x003E, at: 24, width: 2)
        put(sectorShift == 9 ? 3 : 4, at: 26, width: 2)
        put(0xFFFE, at: 28, width: 2)
        put(sectorShift, at: 30, width: 2)
        put(6, at: 32, width: 2)
        put(fatCount, at: 44, width: 4)
        put(directoryStart, at: 48, width: 4)
        put(4096, at: 56, width: 4)
        put(miniFAT.isEmpty ? Int(Self.endOfChain) : miniFATStart, at: 60, width: 4)
        put(miniFAT.isEmpty ? 0 : (miniFATBytes.count + sectorSize - 1) / sectorSize, at: 64, width: 4)
        put(difatCount == 0 ? Int(Self.endOfChain) : difatSectors[0], at: 68, width: 4)
        put(difatCount, at: 72, width: 4)
        for slot in 0..<109 {
            put(slot < fatCount ? fatSectors[slot] : Int(Self.free), at: 76 + slot * 4, width: 4)
        }

        let data = Data(header + sectors.flatMap { $0 })
        let layout = Layout(
            sectorSize: sectorSize, directorySector: directoryStart, fatSectors: fatSectors,
            startSectors: starts, difatSectors: difatSectors
        )
        return (data, layout)
    }

    /// `value` as four little-endian bytes.
    private static func bytes(of value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) }
    }

    /// One 128-byte directory entry.
    private static func directoryEntry(
        name: String, type: UInt8, left: UInt32, right: UInt32, child: UInt32, start: UInt32, size: UInt64
    ) -> [UInt8] {
        var entry = [UInt8](repeating: 0, count: 128)
        let units = Array(name.utf16.prefix(31))
        for (index, unit) in units.enumerated() {
            entry[index * 2] = UInt8(unit & 0xFF)
            entry[index * 2 + 1] = UInt8(unit >> 8)
        }
        let nameLength = units.isEmpty ? 0 : (units.count + 1) * 2
        entry[64] = UInt8(nameLength & 0xFF)
        entry[65] = UInt8(nameLength >> 8)
        entry[66] = type
        entry[67] = 1
        entry.replaceSubrange(68..<72, with: bytes(of: left))
        entry.replaceSubrange(72..<76, with: bytes(of: right))
        entry.replaceSubrange(76..<80, with: bytes(of: child))
        entry.replaceSubrange(116..<120, with: bytes(of: start))
        entry.replaceSubrange(120..<124, with: bytes(of: UInt32(size & 0xFFFF_FFFF)))
        entry.replaceSubrange(124..<128, with: bytes(of: UInt32(size >> 32)))
        return entry
    }
}

// MARK: - Damaging Bytes

extension Data {
    /// This data with the little-endian number `value` written over `width`
    /// bytes at `offset`.
    func patched(at offset: Int, to value: Int, width: Int = 4) -> Data {
        var copy = self
        for byte in 0..<width { copy[offset + byte] = UInt8((value >> (8 * byte)) & 0xFF) }
        return copy
    }
}
