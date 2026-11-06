import Foundation
import XCTest
@testable import TextMouth

/// A value to be written as binary Ion, for the tests of the KFX reader
/// (FMT52). The reader's own code only reads; this small writer, written
/// from the public Ion specification (https://amazon-ion.github.io/ion-docs/),
/// builds the books and the hostile files the tests read.
indirect enum IonOut {
    case null
    case bool(Bool)
    case int(Int64)
    case float32(Float)
    case float64(Double)
    case symbol(Int)
    case string(String)
    case list([IonOut])
    case sexp([IonOut])
    case structure([(Int, IonOut)])
    /// A sorted struct: descriptor nibble 1, with a length that follows.
    case sortedStructure([(Int, IonOut)])
    case annotated([Int], IonOut)
    /// Padding of this many bytes in all (at least 1).
    case pad(Int)
    /// A decimal, timestamp, clob, or blob (type 5, 6, 9, 10) with this body.
    case opaque(type: Int, body: [UInt8])
    /// A positive integer written with exactly these big-endian bytes.
    case integerBytes([UInt8])
    /// Bytes written as they are, for a malformed value.
    case raw([UInt8])
}

/// Writes `IonOut` values as binary Ion.
enum IonWriter {

    /// The version marker every document starts with.
    static let marker: [UInt8] = [0xE0, 0x01, 0x00, 0xEA]

    /// A VarUInt: seven bits to a byte, the last byte's high bit set.
    static func varUInt(_ value: Int) -> [UInt8] {
        var groups: [UInt8] = [UInt8(value & 0x7F) | 0x80]
        var rest = value >> 7
        while rest > 0 {
            groups.insert(UInt8(rest & 0x7F), at: 0)
            rest >>= 7
        }
        return groups
    }

    /// A descriptor byte for `type` and a body of `length` bytes, with the
    /// VarUInt length after it when the length is 14 or more (or when
    /// `alwaysLong` asks for the long form).
    static func descriptor(_ type: Int, length: Int, alwaysLong: Bool = false) -> [UInt8] {
        if length < 14 && !alwaysLong { return [UInt8(type << 4 | length)] }
        return [UInt8(type << 4 | 14)] + varUInt(length)
    }

    /// The minimal big-endian bytes of `magnitude` (none for 0).
    static func bigEndian(_ magnitude: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var rest = magnitude
        while rest > 0 {
            bytes.insert(UInt8(rest & 0xFF), at: 0)
            rest >>= 8
        }
        return bytes
    }

    /// The body of one value, without a version marker.
    static func encode(_ value: IonOut, alwaysLong: Bool = false) -> [UInt8] {
        func wrap(_ type: Int, _ body: [UInt8]) -> [UInt8] {
            descriptor(type, length: body.count, alwaysLong: alwaysLong) + body
        }
        switch value {
        case .null: return [0x0F]
        case .bool(let flag): return [flag ? 0x11 : 0x10]
        case .int(let number):
            return number >= 0
                ? wrap(2, bigEndian(UInt64(number)))
                : wrap(3, bigEndian(UInt64(bitPattern: 0 &- number)))
        case .float32(let number):
            return wrap(4, withUnsafeBytes(of: number.bitPattern.bigEndian) { Array($0) })
        case .float64(let number):
            return wrap(4, withUnsafeBytes(of: number.bitPattern.bigEndian) { Array($0) })
        case .symbol(let id): return wrap(7, bigEndian(UInt64(id)))
        case .string(let text): return wrap(8, Array(text.utf8))
        case .list(let items): return wrap(11, items.flatMap { encode($0, alwaysLong: alwaysLong) })
        case .sexp(let items): return wrap(12, items.flatMap { encode($0, alwaysLong: alwaysLong) })
        case .structure(let members):
            return wrap(13, members.flatMap { varUInt($0.0) + encode($0.1, alwaysLong: alwaysLong) })
        case .sortedStructure(let members):
            let body = members.flatMap { varUInt($0.0) + encode($0.1, alwaysLong: alwaysLong) }
            return [0xD1] + varUInt(body.count) + body
        case .annotated(let ids, let inner):
            let idBytes = ids.flatMap { varUInt($0) }
            return wrap(14, varUInt(idBytes.count) + idBytes + encode(inner, alwaysLong: alwaysLong))
        case .pad(let total):
            // One byte of padding is the descriptor alone; more is a length.
            if total <= 1 { return [0x00] }
            if total <= 14 { return [UInt8(total - 1)] + [UInt8](repeating: 0, count: total - 1) }
            let body = total - 2
            return descriptor(0, length: body, alwaysLong: true) + [UInt8](repeating: 0, count: body)
        case .opaque(let type, let body): return wrap(type, body)
        case .integerBytes(let bytes): return wrap(2, bytes)
        case .raw(let bytes): return bytes
        }
    }

    /// A whole Ion document: the marker and the values.
    static func document(_ values: IonOut..., alwaysLong: Bool = false) -> [UInt8] {
        marker + values.flatMap { encode($0, alwaysLong: alwaysLong) }
    }
}

/// Builds a KFX container (a `CONT` file) from fragments, laid out as the
/// real files are (KFX-FORMAT-NOTES-2026-11-05.md, part 4): header, entity
/// table, document symbol table, container info, then the entities.
struct KFXContainerBuilder {

    /// One entity: its id and type (symbol ids), and its Ion value, or its
    /// raw bytes for a resource.
    struct Entity {
        var id: Int
        var type: Int
        var value: IonOut?
        var raw: [UInt8]?
        /// The compression and DRM fields of the entity's own header.
        var headerCompression = 0
        var headerDRM = 0
    }

    var version = 2
    /// The import's `max_id`: the shared symbols run to here.
    var sharedMaximum = 859
    /// The local symbols, the first having id `sharedMaximum + 1`.
    var localSymbols: [String] = []
    var entities: [Entity] = []
    /// The compression and DRM fields of the container info.
    var compression = 0
    var drm = 0

    /// The id the entity table gives a fragment that has no name.
    static let noName = 348

    /// The id of the local symbol `name`, which must be in `localSymbols`.
    func id(of name: String) -> Int {
        sharedMaximum + 1 + (localSymbols.firstIndex(of: name) ?? 0)
    }

    /// Adds a fragment of `type` named `name` (a local symbol) or unnamed.
    mutating func add(type: Int, name: String? = nil, _ value: IonOut) {
        entities.append(Entity(id: name.map(id(of:)) ?? Self.noName, type: type, value: value))
    }

    /// Adds a raw resource (`$417`).
    mutating func addResource(name: String, _ bytes: [UInt8], type: Int = 417) {
        entities.append(Entity(id: id(of: name), type: type, raw: bytes))
    }

    /// The bytes of one entity: signature, version, header, payload.
    private func bytes(of entity: Entity) -> [UInt8] {
        let header = IonWriter.document(.structure([
            (410, .int(Int64(entity.headerCompression))), (411, .int(Int64(entity.headerDRM))),
        ]))
        let payload = entity.raw ?? IonWriter.document(entity.value ?? .null)
        var out = Array("ENTY".utf8) + [1, 0]
        out += le32(10 + header.count) + header + payload
        return out
    }

    private func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
    private func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
    private func le64(_ value: Int) -> [UInt8] { (0..<8).map { UInt8(value >> (8 * $0) & 0xFF) } }

    /// The container's bytes.
    func build() -> [UInt8] {
        let encoded = entities.map(bytes(of:))
        // The entity table: id, type, offset from the end of the header, length.
        var table: [UInt8] = []
        var offset = 0
        for (entity, bytes) in zip(entities, encoded) {
            table += le32(entity.id) + le32(entity.type) + le64(offset) + le64(bytes.count)
            offset += bytes.count
        }
        let symbolTable = IonWriter.document(.annotated([3], .structure([
            (8, .int(Int64(sharedMaximum + localSymbols.count))),
            (6, .list([.structure([
                (4, .string("YJ_symbols")), (5, .int(10)), (8, .int(Int64(sharedMaximum))),
            ])])),
            (7, .list(localSymbols.map { .string($0) })),
        ])))
        // The info's own length depends on the offsets it holds, which do
        // not depend on its length when it is written last.
        let tableOffset = 18
        let symbolOffset = tableOffset + table.count
        let infoOffset = symbolOffset + symbolTable.count
        let info = IonWriter.document(.structure([
            (409, .string("CR!TESTCONTAINER")),
            (410, .int(Int64(compression))), (411, .int(Int64(drm))), (412, .int(4096)),
            (413, .int(Int64(tableOffset))), (414, .int(Int64(table.count))),
            (415, .int(Int64(symbolOffset))), (416, .int(Int64(symbolTable.count))),
        ]))
        let headerLength = infoOffset + info.count
        var file = Array("CONT".utf8) + le16(version) + le32(headerLength)
        file += le32(infoOffset) + le32(info.count)
        file += table + symbolTable + info
        for bytes in encoded { file += bytes }
        return file
    }
}

extension XCTestCase {
    /// Runs `body` and fails when it takes a second or more: a hostile file
    /// is refused at once, never worked on.
    func assertQuick<T>(
        _ what: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> T
    ) rethrows -> T {
        let start = Date()
        defer { XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, what, file: file, line: line) }
        return try body()
    }

    /// Asserts that `body` throws a `MOBIError` of the damaged kind (or
    /// another of the reader's own errors), quickly, and returns it.
    @discardableResult
    func assertRefusedQuickly<T>(
        _ what: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> T
    ) -> Error? {
        var caught: Error?
        assertQuick(what, file: file, line: line) {
            do { _ = try body(); XCTFail("\(what): did not throw", file: file, line: line) } catch { caught = error }
        }
        if let caught {
            XCTAssertTrue(
                caught is MOBIError || caught is KFXError || caught is DocumentTooLargeError,
                "\(what): threw \(caught)", file: file, line: line)
        }
        return caught
    }
}

/// A fixed-seed generator, so a byte-flip run is the same every time.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        // SplitMix64.
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
