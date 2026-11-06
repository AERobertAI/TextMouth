import Foundation

/// One member of an Ion struct: a field's symbol id and its value.
struct IonField: Equatable {
    var id: Int
    var value: IonValue
}

/// An Ion struct: its members in the order the file wrote them. Structs in
/// a KFX book hold a handful of members, so a lookup is a plain search; when
/// a file repeats a field the first member is the one read.
struct IonStruct: Equatable {
    var fields: [IonField]

    /// The value of the field with symbol id `id`, nil when absent.
    subscript(id: Int) -> IonValue? {
        fields.first { $0.id == id }?.value
    }
}

/// A value of binary Ion (https://amazon-ion.github.io/ion-docs/), as much of
/// it as a KFX book needs (KFX-FORMAT-NOTES-2026-11-05.md, part 5). Decimals,
/// timestamps, clobs, blobs, and integers past 64 bits are present in a book
/// but of no use to a reader of its text, so they are `opaque`: found, their
/// length checked, and not decoded.
indirect enum IonValue: Equatable {
    /// A null of any type, or a pad.
    case null
    case bool(Bool)
    case int(Int64)
    case float(Double)
    /// A symbol, by id; the symbol table gives its text (`KFXSymbols`).
    case symbol(Int)
    case string(String)
    /// A list or an s-expression.
    case list([IonValue])
    case structure(IonStruct)
    /// A value wrapped in annotations, given by symbol id.
    case annotated([Int], IonValue)
    case opaque

    // MARK: Typed access

    /// The value without its annotations.
    var unannotated: IonValue {
        if case .annotated(_, let inner) = self { return inner.unannotated }
        return self
    }

    /// The integer, or nil when this is not one.
    var intValue: Int? {
        if case .int(let number) = unannotated { return Int(exactly: number) }
        return nil
    }

    /// The string, or nil when this is not one.
    var stringValue: String? {
        if case .string(let text) = unannotated { return text }
        return nil
    }

    /// The symbol id, or nil when this is not a symbol.
    var symbolID: Int? {
        if case .symbol(let id) = unannotated { return id }
        return nil
    }

    /// The elements, or nil when this is not a list.
    var listValue: [IonValue]? {
        if case .list(let items) = unannotated { return items }
        return nil
    }

    /// The struct, or nil when this is not one.
    var structValue: IonStruct? {
        if case .structure(let members) = unannotated { return members }
        return nil
    }

    /// The boolean, or nil when this is not one.
    var boolValue: Bool? {
        if case .bool(let flag) = unannotated { return flag }
        return nil
    }

    /// The annotations' symbol ids; empty for an unannotated value.
    var annotations: [Int] {
        if case .annotated(let ids, _) = self { return ids }
        return []
    }
}

/// Reads binary Ion from a window of a KFX file, written from the public
/// specification. A KFX book is untrusted input, so:
/// - every length is checked against the data it must lie in, and a declared
///   count never sizes an allocation (a list is as long as its elements);
/// - nesting is walked with an explicit stack, never by recursion, and is
///   cut at `maximumDepth`;
/// - the values one container may hold are counted against a budget.
enum IonReader {

    /// The deepest nesting read. A node takes two levels (a struct, and a list of
    /// its children), and a book's nodes nest a dozen levels at most.
    static let maximumDepth = 128

    /// The version marker that starts every Ion document.
    static let versionMarker: [UInt8] = [0xE0, 0x01, 0x00, 0xEA]

    /// The most bytes a variable-length unsigned integer may take (nine
    /// bytes hold 63 bits, more than any length, count, or id here).
    private static let maximumVarUIntBytes = 9

    /// One container being read: a list, a struct, or an annotation's single
    /// value, with what it holds so far.
    private struct Frame {
        enum Kind { case list, structure, annotation([Int]) }
        var kind: Kind
        /// Where the container's bytes end.
        var end: Int
        var items: [IonValue] = []
        var fields: [IonField] = []
        /// The field id just read, whose value comes next.
        var pendingField: Int?
    }

    // MARK: Documents

    /// Every value of the Ion document in `view`, in order: version markers
    /// and pads are skipped. A fragment holds one value, a document with
    /// several is read in full.
    /// - Parameter budget: How many more values may be read; it goes down
    ///   by each value read, and the read throws when it runs out.
    /// - Throws: `MOBIError.damaged` for data that is not valid Ion, nests
    ///   too deep, or holds more values than the budget.
    static func values(in view: KFXView, budget: inout Int) throws -> [IonValue] {
        var values: [IonValue] = []
        var position = 0
        while position < view.count {
            if view.hasPrefix(versionMarker, at: position) {
                position += versionMarker.count
                continue
            }
            let (value, next) = try readValue(in: view, at: position, limit: view.count, budget: &budget)
            if let value { values.append(value) }
            position = next
        }
        return values
    }

    /// The first value of the Ion document in `view`, nil for a document
    /// with none.
    static func firstValue(in view: KFXView, budget: inout Int) throws -> IonValue? {
        try values(in: view, budget: &budget).first
    }

    // MARK: Values

    /// Reads the value that starts at `start`, whose container ends at
    /// `limit`, and returns it with the position after it. A pad is read and
    /// returned as nil.
    private static func readValue(
        in view: KFXView, at start: Int, limit: Int, budget: inout Int
    ) throws -> (IonValue?, Int) {
        var stack: [Frame] = []
        var position = start
        // Where a finished value goes: into the container being read, or
        // out as the result when no container is open.
        var result: IonValue??
        func deliver(_ value: IonValue?) throws {
            guard stack.indices.last != nil else { result = .some(value); return }
            let top = stack.count - 1
            switch stack[top].kind {
            case .list, .annotation:
                if let value { stack[top].items.append(value) }
            case .structure:
                if let value, let field = stack[top].pendingField {
                    stack[top].fields.append(IonField(id: field, value: value))
                }
                stack[top].pendingField = nil
            }
        }

        while result == nil {
            // A container whose last byte has been read is finished.
            if let top = stack.last, position >= top.end {
                guard position == top.end else { throw MOBIError.damaged("a value runs past the end of its container") }
                stack.removeLast()
                try deliver(try finished(top))
                continue
            }
            let containerEnd = stack.last?.end ?? limit
            // A struct member starts with its field's symbol id.
            if let top = stack.last, case .structure = top.kind {
                let (field, next) = try varUInt(in: view, at: position, limit: containerEnd)
                stack[stack.count - 1].pendingField = field
                position = next
            }
            guard position < containerEnd else { throw MOBIError.damaged("a struct member has no value") }
            budget -= 1
            guard budget >= 0 else { throw MOBIError.damaged("the book holds more values than TextMouth reads") }

            let descriptor = Int(view.bytes[view.range.lowerBound + position])
            position += 1
            let type = descriptor >> 4
            let nibble = descriptor & 0x0F

            // A null of any type: the length nibble 15. (A type 0 null is
            // read here too; a pad has a smaller nibble.)
            if nibble == 15 {
                guard type != 15 else { throw MOBIError.damaged("a value has a reserved type") }
                try deliver(.null)
                continue
            }
            // A boolean holds its value in the nibble and has no body.
            if type == 1 {
                guard nibble <= 1 else { throw MOBIError.damaged("a boolean has an unknown value") }
                try deliver(.bool(nibble == 1))
                continue
            }
            // The length of the value's body: the nibble, or a length that
            // follows when the nibble is 14 (and for a sorted struct, 1).
            var length = nibble
            if nibble == 14 || (type == 13 && nibble == 1) {
                (length, position) = try varUInt(in: view, at: position, limit: containerEnd)
            }
            guard length <= containerEnd - position else {
                throw MOBIError.damaged("a value runs past the end of its container")
            }
            let end = position + length
            let body = try view.slice(position, length, "a value")

            switch type {
            case 0:
                // Padding: skipped, wherever it stands.
                position = end
                try deliver(nil)
            case 2, 3:
                position = end
                try deliver(try integer(from: body, negative: type == 3))
            case 4:
                position = end
                try deliver(try float(from: body))
            case 5, 6, 9, 10:
                // Decimal, timestamp, clob, blob.
                position = end
                try deliver(.opaque)
            case 7:
                position = end
                guard case .int(let id) = try integer(from: body, negative: false), id <= Int64(Int32.max) else {
                    throw MOBIError.damaged("a symbol id is out of range")
                }
                try deliver(.symbol(Int(id)))
            case 8:
                position = end
                try deliver(.string(String(decoding: body.bytes[body.range], as: UTF8.self)))
            case 11, 12, 13:
                guard stack.count < maximumDepth else { throw MOBIError.damaged("values nest too deeply") }
                stack.append(Frame(kind: type == 13 ? .structure : .list, end: end))
            case 14:
                guard length >= 3 else { throw MOBIError.damaged("an annotation is too short") }
                guard stack.count < maximumDepth else { throw MOBIError.damaged("values nest too deeply") }
                let ids = try annotationIDs(in: view, at: position, limit: end)
                stack.append(Frame(kind: .annotation(ids.ids), end: end))
                position = ids.next
            default:
                throw MOBIError.damaged("a value has a reserved type")
            }
        }
        return (result ?? nil, position)
    }

    /// The value a finished container holds.
    private static func finished(_ frame: Frame) throws -> IonValue {
        switch frame.kind {
        case .list: return .list(frame.items)
        case .structure: return .structure(IonStruct(fields: frame.fields))
        case .annotation(let ids):
            guard frame.items.count == 1 else { throw MOBIError.damaged("an annotation does not wrap exactly one value") }
            return .annotated(ids, frame.items[0])
        }
    }

    // MARK: Numbers

    /// The variable-length unsigned integer at `position`, with the position
    /// after it: seven bits to a byte, most significant first, the last
    /// byte's high bit set.
    private static func varUInt(in view: KFXView, at position: Int, limit: Int) throws -> (Int, Int) {
        var value = 0
        var cursor = position
        for _ in 0..<maximumVarUIntBytes {
            guard cursor < limit else { throw MOBIError.damaged("a length or id is cut short") }
            let byte = Int(view.bytes[view.range.lowerBound + cursor])
            cursor += 1
            value = value << 7 | (byte & 0x7F)
            if byte & 0x80 != 0 { return (value, cursor) }
        }
        throw MOBIError.damaged("a length or id is too long")
    }

    /// The annotation ids that open an annotation wrapper at `position`
    /// (a length, then the ids), and the position of the wrapped value.
    private static func annotationIDs(in view: KFXView, at position: Int, limit: Int) throws -> (ids: [Int], next: Int) {
        let (idBytes, afterLength) = try varUInt(in: view, at: position, limit: limit)
        guard idBytes > 0, idBytes < limit - afterLength else { throw MOBIError.damaged("an annotation list is the wrong length") }
        let idsEnd = afterLength + idBytes
        var ids: [Int] = []
        var cursor = afterLength
        while cursor < idsEnd {
            let (id, next) = try varUInt(in: view, at: cursor, limit: idsEnd)
            ids.append(id)
            cursor = next
        }
        return (ids, idsEnd)
    }

    /// The integer whose magnitude is the big-endian `body`. One past 64
    /// bits is opaque. A negative zero is damage.
    private static func integer(from body: KFXView, negative: Bool) throws -> IonValue {
        var magnitude: UInt64 = 0
        for offset in 0..<body.count {
            let byte = UInt64(body.bytes[body.range.lowerBound + offset])
            // A leading byte that would push the value past 64 bits.
            if magnitude >> 56 != 0 { return .opaque }
            magnitude = magnitude << 8 | byte
        }
        if negative {
            guard magnitude != 0 else { throw MOBIError.damaged("an integer is a negative zero") }
            guard magnitude <= UInt64(Int64.max) else { return .opaque }
            return .int(-Int64(magnitude))
        }
        guard magnitude <= UInt64(Int64.max) else { return .opaque }
        return .int(Int64(magnitude))
    }

    /// The 0-, 4-, or 8-byte float in `body`.
    private static func float(from body: KFXView) throws -> IonValue {
        var bits: UInt64 = 0
        for offset in 0..<body.count { bits = bits << 8 | UInt64(body.bytes[body.range.lowerBound + offset]) }
        switch body.count {
        case 0: return .float(0)
        case 4: return .float(Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits))))
        case 8: return .float(Double(bitPattern: bits))
        default: throw MOBIError.damaged("a float has an unknown size")
        }
    }
}
