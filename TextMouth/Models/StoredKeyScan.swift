import Foundation

// MARK: - What a Stored Object's Type Knows

/// The member names a stored JSON object's type knows, and which of those
/// members hold objects described in turn: what `StoredKeyScan` checks a
/// file's bytes against, to say whether the file can hold a key some type
/// does not know (V04, `UnknownKeys`).
///
/// A type that keeps unknown keys gives its schema as `keySchema`
/// (`KeepsUnknownKeys`). Every member whose value is, or is an array of, a
/// type that keeps unknown keys must be listed among the schema's
/// `objects`: a member left out is not looked into, and a file whose only
/// unknown key is inside it would be read as holding none
/// (`UnknownKeysTests` adds a key to each object of a row and of a record,
/// one at a time, and fails for any the scan misses).
struct StoredKeySchema: Sendable {
    /// What a known member's value is to the scan.
    enum Member: Sendable {
        /// A value whose inside is not checked: a scalar, or an object or
        /// array that keeps no unknown keys (a map, a list of names).
        case unchecked
        /// An object, or an array of objects, each checked against the
        /// schema.
        indirect case object(StoredKeySchema)
        /// An object that may keep unknown keys and that no schema here
        /// describes. Its presence alone makes the scan answer that the
        /// file may hold unknown keys.
        case undescribed
    }

    /// What `name` is in an object of this schema, or nil for a name the
    /// type does not know.
    let member: @Sendable (String) -> Member?

    /// The schema of a type that lists its key names (`CodingKey.names`).
    /// Of them, `objects` are the members checked in turn, and
    /// `undescribed` the ones that may keep unknown keys no schema
    /// describes.
    init(names: Set<String>, objects: [String: StoredKeySchema] = [:], undescribed: Set<String> = []) {
        var members: [String: Member] = [:]
        for name in names {
            members[name] = Self.kind(of: name, objects: objects, undescribed: undescribed)
        }
        // A constant, so the closure may be shared between threads.
        let table = members
        member = { table[$0] }
    }

    /// The schema of a type whose coding keys Swift synthesizes, which can
    /// say whether a name is one of them (`isKnown`) but cannot list them.
    init(isKnown: @escaping @Sendable (String) -> Bool, objects: [String: StoredKeySchema] = [:]) {
        member = { isKnown($0) ? Self.kind(of: $0, objects: objects, undescribed: []) : nil }
    }

    /// What the known member `name` is.
    private static func kind(of name: String, objects: [String: StoredKeySchema], undescribed: Set<String>) -> Member {
        if let schema = objects[name] { return .object(schema) }
        return undescribed.contains(name) ? .undescribed : .unchecked
    }
}

// MARK: - The Scan

/// A fast look through the bytes of a JSON file for a member name its
/// schema does not know (V04), so that a file without any, which is every
/// file this TextMouth or an earlier one wrote, is decoded without looking
/// for unknown keys object by object.
///
/// Looking object by object costs a decode about 1.6 microseconds for each
/// object (a second keyed container) and 0.15 for each of its keys (their
/// list): measured in an optimized model of a 1,500-row index, 14
/// milliseconds on a decode of 22. The scan read 2.4 MB of such an index in
/// 4.5 milliseconds, and says whether that work is needed. (In a debug
/// build, as the tests are, the scan is about ten times slower and spares
/// nothing; `UnknownKeysTests` prints both.)
///
/// It reads no values and builds nothing: it steps over strings, numbers,
/// and brackets, and looks up each member name of each object the schema
/// describes. It is never the judge of what a file holds, only of whether
/// to look: whenever it is unsure (text that is not the JSON it expects, a
/// name written with an escape, an object no schema describes) it answers
/// that the file may hold unknown keys, and the decode looks, as it would
/// have without the scan.
enum StoredKeyScan {
    /// What a `JSONDecoder` is told, in its `userInfo`, when a scan found
    /// that the bytes it decodes hold no unknown key: `UnknownKeys` then
    /// reads none, without looking.
    static let noUnknownKeysInfoKey: CodingUserInfoKey = {
        // The name is not empty, so the key is always made.
        guard let key = CodingUserInfoKey(rawValue: "TextMouth.StoredKeyScan.noUnknownKeys") else {
            preconditionFailure("a CodingUserInfoKey of a fixed name")
        }
        return key
    }()

    /// The `userInfo` a decoder of `data` takes, for a file whose top-level
    /// object `schema` describes: the word that the file holds no unknown
    /// key when the scan found none, and nothing otherwise.
    static func userInfo(forDecoding data: Data, schema: StoredKeySchema) -> [CodingUserInfoKey: any Sendable] {
        mayHoldUnknownKeys(data, schema: schema) ? [:] : [noUnknownKeysInfoKey: true]
    }

    /// Whether `decoder` was told that the bytes it decodes hold no unknown
    /// key.
    static func foundNoUnknownKeys(for decoder: Decoder) -> Bool {
        decoder.userInfo[noUnknownKeysInfoKey] as? Bool == true
    }

    /// Whether `data`, a JSON text in UTF-8, may hold a member that
    /// `schema`, the schema of its top-level object, does not know, at any
    /// depth the schema describes. False only when the whole text was
    /// understood and every member name of every described object is
    /// known.
    static func mayHoldUnknownKeys(_ data: Data, schema: StoredKeySchema) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var scanner = Scanner(bytes: raw.bindMemory(to: UInt8.self))
            // A value that was not understood, or text after it, is not
            // the JSON this scan vouches for.
            guard scanner.value(.object(schema)), scanner.atEnd() else { return true }
            return false
        }
    }

    /// The scan's place in the bytes.
    private struct Scanner {
        /// The whole text.
        let bytes: UnsafeBufferPointer<UInt8>
        /// The next byte to read.
        var index = 0
        /// How deep the value being read is nested.
        var depth = 0

        /// How deep a text may nest before the scan gives up on it, so
        /// that no text can run the stack out: far deeper than any file
        /// TextMouth writes.
        static let maximumDepth = 128

        init(bytes: UnsafeBufferPointer<UInt8>) {
            self.bytes = bytes
        }

        /// Steps over white space, and says whether nothing else was left.
        mutating func atEnd() -> Bool {
            skipSpace()
            return index == bytes.count
        }

        /// Steps over spaces, tabs, and line ends.
        private mutating func skipSpace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }

        /// Steps over one value, checking the member names of the objects
        /// `member` describes. False when the text is not understood, a
        /// described object holds a name its schema does not know, or an
        /// undescribed object is met.
        mutating func value(_ member: StoredKeySchema.Member) -> Bool {
            skipSpace()
            guard index < bytes.count else { return false }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                // An object no schema describes may keep unknown keys.
                if case .undescribed = member { return false }
                index += 1
                return nested { $0.object(member) }
            case UInt8(ascii: "["):
                index += 1
                return nested { $0.array(member) }
            case UInt8(ascii: "\""):
                index += 1
                return string() != nil
            default:
                return scalar()
            }
        }

        /// Runs `body` one level deeper, refusing a text nested too deep.
        private mutating func nested(_ body: (inout Scanner) -> Bool) -> Bool {
            guard depth < Self.maximumDepth else { return false }
            depth += 1
            defer { depth -= 1 }
            return body(&self)
        }

        /// Steps over a number, `true`, `false`, or `null`: everything up
        /// to the next delimiter. False when nothing is there.
        private mutating func scalar() -> Bool {
            let start = index
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D:
                    return index > start
                default:
                    index += 1
                }
            }
            return index > start
        }

        /// Steps over the rest of an array whose "[" was just read. Its
        /// elements are what the array is: objects of the schema, or
        /// unchecked values.
        private mutating func array(_ member: StoredKeySchema.Member) -> Bool {
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return true
            }
            while true {
                guard value(member) else { return false }
                guard let closed = endOfElement(closing: UInt8(ascii: "]")) else { return false }
                if closed { return true }
            }
        }

        /// Steps over the rest of an object whose "{" was just read,
        /// looking up each member name when `member` describes the object.
        private mutating func object(_ member: StoredKeySchema.Member) -> Bool {
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return true
            }
            while true {
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return false }
                index += 1
                guard let name = string() else { return false }
                var inner = StoredKeySchema.Member.unchecked
                if case .object(let schema) = member {
                    // A name written with an escape is not looked up: no
                    // name TextMouth knows needs one.
                    guard !holdsBackslash(name) else { return false }
                    let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[name]), as: UTF8.self)
                    guard let known = schema.member(text) else { return false }
                    inner = known
                }
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return false }
                index += 1
                guard value(inner) else { return false }
                guard let closed = endOfElement(closing: UInt8(ascii: "}")) else { return false }
                if closed { return true }
            }
        }

        /// Steps over what follows an element of an array or a member of
        /// an object: true for the bracket that closes it (`closing`),
        /// false for a comma, nil for anything else.
        private mutating func endOfElement(closing: UInt8) -> Bool? {
            skipSpace()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            index += 1
            if byte == closing { return true }
            return byte == UInt8(ascii: ",") ? false : nil
        }

        /// Whether the bytes at `range` hold a backslash, as an escape does.
        private func holdsBackslash(_ range: Range<Int>) -> Bool {
            guard let base = bytes.baseAddress, !range.isEmpty else { return false }
            return memchr(base + range.lowerBound, Int32(UInt8(ascii: "\\")), range.count) != nil
        }

        /// Steps over the rest of a string whose opening quote was just
        /// read, and returns where its text is; nil when the string never
        /// ends.
        private mutating func string() -> Range<Int>? {
            let start = index
            guard let base = bytes.baseAddress else { return nil }
            while index < bytes.count {
                // Straight to the next quote: most of a file is strings.
                guard let found = memchr(base + index, Int32(UInt8(ascii: "\"")), bytes.count - index) else { return nil }
                let quote = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
                // A quote after an odd run of backslashes is escaped, and
                // the string goes on.
                var backslashes = 0
                var before = quote - 1
                while before >= start, bytes[before] == UInt8(ascii: "\\") {
                    backslashes += 1
                    before -= 1
                }
                index = quote + 1
                if backslashes.isMultiple(of: 2) { return start..<quote }
            }
            return nil
        }
    }
}
