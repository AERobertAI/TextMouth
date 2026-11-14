import Foundation

/// One KFX container (a `CONT` file) opened: its symbols and its table of
/// entities, with every offset and length checked against the file
/// (KFX-FORMAT-NOTES-2026-11-05.md, part 4). Nothing of an entity is decoded
/// until `fragments(budget:)` asks for it.
///
/// The container is refused, never read, when it declares a compression or a
/// DRM scheme: the notes find both fields 0 in every readable file, so a
/// nonzero one means something this reader does not know. A copy-protected
/// file does not begin with `CONT` and never gets here (`KFXSignature`).
struct KFXContainer {

    /// The entity table's row: what the entity is and where it lies.
    struct Entity: Equatable {
        /// The entity's id, a symbol id of this container (`348` for none).
        var id: Int
        /// The fragment's type, a shared symbol id such as 260.
        var type: Int
        /// The entity's bytes in the file.
        var range: Range<Int>
    }

    /// A decoded fragment: its type, its name, and its value.
    struct Fragment {
        /// The type as a shared symbol number, such as 260 for sections.
        var type: Int
        /// The fragment's name: its local symbol's text, or "$348" for the
        /// one fragment of a kind that has no name.
        var name: String
        /// The value, with every local symbol as a string of its name, so
        /// that fragments of several containers, whose local ids differ,
        /// can be read together. Shared symbols stay symbols, by number.
        var value: IonValue
        /// The names of the struct fields in `value` that are local symbols
        /// (rather than shared ones, by number), such as a notebook's
        /// `nmdl.canvas_width`; empty in nearly every fragment.
        var localFieldNames: Set<String>
    }

    // MARK: Limits

    /// The most entities a container may list. A book has one per section,
    /// storyline, content, style, anchor, and resource: thousands, not
    /// hundreds of thousands.
    static let maximumEntities = 200_000

    /// How many Ion values all of a container's fragments may hold in all.
    static let maximumValues = 4_000_000

    /// The id an entity has when there is only one of its type.
    static let unnamedEntityID = 348

    /// The known container versions.
    static let supportedVersions = 1...2

    /// The fixed size of the file header.
    private static let headerSize = 18
    /// The fixed size of an entity table row.
    private static let entityRowSize = 24
    /// The smallest an entity header may be: signature, version, length.
    private static let minimumEntityHeader = 10

    // MARK: Fields of the container info (symbol ids of the shared table)

    private static let compressionField = 410, drmField = 411
    private static let entityTableOffsetField = 413, entityTableLengthField = 414
    private static let symbolTableOffsetField = 415, symbolTableLengthField = 416
    private static let entityTypeRaw: Set<Int> = [417, 418]

    // MARK: State

    /// The whole file.
    let view: KFXView
    /// The container's version, 1 or 2.
    let version: Int
    /// The container's symbols.
    let symbols: KFXSymbols
    /// Where each entity lies, in the table's order.
    let entities: [Entity]

    // MARK: Opening

    /// Opens the container in `bytes`.
    /// - Throws: `MOBIError.damaged` for a file that is not a container, stops
    ///   short, or has an offset or length past its end;
    ///   `MOBIError.copyProtected` for a DRM scheme and
    ///   `MOBIError.unsupportedCompression` for a compression type.
    init(bytes: [UInt8]) throws {
        let view = KFXView(bytes)
        self.view = view
        guard view.count >= Self.headerSize, view.hasPrefix(KFXSignature.containerMagic, at: 0) else {
            throw MOBIError.notAKindleBook
        }
        let version = try view.uint16(4, "the container's version")
        guard Self.supportedVersions.contains(version) else {
            throw MOBIError.damaged("the container's version, \(version), is not one TextMouth reads")
        }
        self.version = version
        let headerLength = try view.uint32(6, "the header's length")
        guard headerLength >= Self.headerSize, headerLength <= view.count else {
            throw MOBIError.damaged("the header's length lies outside the book's data")
        }
        let entityBase = headerLength

        // The container info: an Ion struct that places the other tables.
        let infoOffset = try view.uint32(10, "the container info's offset")
        let infoLength = try view.uint32(14, "the container info's length")
        var budget = Self.maximumValues
        let info = try Self.struct(
            of: try view.slice(infoOffset, infoLength, "the container info"),
            what: "container info", budget: &budget)
        try Self.refuseUnreadable(info)

        // The document symbol table, absent when its length is 0.
        let symbolLength = info[Self.symbolTableLengthField]?.intValue ?? 0
        if symbolLength > 0 {
            let symbolOffset = info[Self.symbolTableOffsetField]?.intValue ?? 0
            let table = try IonReader.firstValue(
                in: try view.slice(symbolOffset, symbolLength, "the symbol table"), budget: &budget)
            guard let table else { throw MOBIError.damaged("the symbol table is empty") }
            symbols = try KFXSymbols(table: table)
        } else {
            symbols = .sharedOnly
        }

        // The entity table: rows of 24 bytes.
        let tableOffset = info[Self.entityTableOffsetField]?.intValue ?? 0
        let tableLength = info[Self.entityTableLengthField]?.intValue ?? 0
        let table = try view.slice(tableOffset, tableLength, "the entity table")
        guard tableLength % Self.entityRowSize == 0 else {
            throw MOBIError.damaged("the entity table is not a whole number of rows")
        }
        let rows = tableLength / Self.entityRowSize
        guard rows <= Self.maximumEntities else {
            throw MOBIError.damaged("the book lists more than \(Self.maximumEntities) fragments")
        }
        var entities: [Entity] = []
        entities.reserveCapacity(rows)
        for row in 0..<rows {
            let at = row * Self.entityRowSize
            let offset = try table.uint64(at + 8, "an entity's offset")
            let length = try table.uint64(at + 16, "an entity's length")
            // The entity lies in the file after the header, and holds at
            // least its own header.
            guard length >= Self.minimumEntityHeader, offset <= view.count - entityBase,
                  length <= view.count - entityBase - offset else {
                throw MOBIError.damaged("a fragment lies outside the book's data")
            }
            entities.append(Entity(
                id: try table.uint32(at, "an entity's id"),
                type: try table.uint32(at + 4, "an entity's type"),
                range: (entityBase + offset)..<(entityBase + offset + length)
            ))
        }
        // The entities lie end to end (notes, part 4.3): one that overlaps
        // another, as a row listed many times does, would be decoded again
        // for each row, so it is refused.
        let ranges = entities.map(\.range).sortedStably { $0.lowerBound < $1.lowerBound }
        for (previous, next) in zip(ranges, ranges.dropFirst()) where next.lowerBound < previous.upperBound {
            throw MOBIError.damaged("two fragments overlap")
        }
        self.entities = entities
    }

    /// Refuses a container whose compression or DRM scheme is not 0.
    private static func refuseUnreadable(_ info: IonStruct) throws {
        // A field that is anything but 0 (a number, or a value of another
        // kind) is a scheme this reader does not know.
        if let scheme = info[drmField], scheme != .null, scheme.intValue != 0 { throw MOBIError.copyProtected }
        if let compression = info[compressionField], compression != .null, compression.intValue != 0 {
            throw MOBIError.unsupportedCompression
        }
    }

    /// The struct that `view` holds as its Ion value.
    private static func `struct`(of view: KFXView, what: String, budget: inout Int) throws -> IonStruct {
        guard let members = try IonReader.firstValue(in: view, budget: &budget)?.structValue else {
            throw MOBIError.damaged("the \(what) is not a struct")
        }
        return members
    }

    // MARK: Entities

    /// The bytes of an entity's payload, after its header. The header is
    /// checked here: its signature, its length, and that it declares no
    /// compression or DRM.
    /// - Throws: `MOBIError.damaged`, `.copyProtected`, or `.unsupportedCompression`.
    func payload(of entity: Entity) throws -> KFXView {
        let whole = try view.slice(entity.range.lowerBound, entity.range.count, "a fragment")
        guard whole.hasPrefix(Array("ENTY".utf8), at: 0) else {
            throw MOBIError.damaged("a fragment does not begin with its signature")
        }
        _ = try whole.uint16(4, "a fragment's version")
        let headerLength = try whole.uint32(6, "a fragment header's length")
        guard headerLength >= Self.minimumEntityHeader, headerLength <= whole.count else {
            throw MOBIError.damaged("a fragment header's length lies outside the fragment")
        }
        // The header's own Ion holds the fragment's compression and DRM fields.
        var budget = 1_000
        if let declared = try IonReader.firstValue(
            in: try whole.slice(Self.minimumEntityHeader, headerLength - Self.minimumEntityHeader, "a fragment's header"),
            budget: &budget)?.structValue {
            try Self.refuseUnreadable(declared)
        }
        return try whole.slice(headerLength, whole.count - headerLength, "a fragment's payload")
    }

    /// The raw bytes of a resource entity (`$417` media, `$418` font): the
    /// file itself, not Ion.
    func rawBytes(of entity: Entity) throws -> KFXView { try payload(of: entity) }

    /// Every entity that is not a raw resource, decoded.
    /// - Parameter budget: How many Ion values may still be read, for all
    ///   the containers of a book; it goes down by those read.
    /// - Throws: `MOBIError.damaged` for a fragment that does not read, and
    ///   what `payload(of:)` throws.
    func fragments(budget: inout Int) throws -> [Fragment] {
        var fragments: [Fragment] = []
        for entity in entities where !Self.entityTypeRaw.contains(entity.type) {
            let payload = try payload(of: entity)
            guard var value = try IonReader.firstValue(in: payload, budget: &budget) else {
                throw MOBIError.damaged("a fragment holds no value")
            }
            // A value annotated with its own type, as the entity's, is the
            // type repeated: the fragment is what it wraps.
            if case .annotated(let ids, let inner) = value, ids.contains(entity.type) { value = inner }
            var localFields: Set<String> = []
            value = resolved(value, localFieldNames: &localFields)
            fragments.append(Fragment(
                type: entity.type, name: symbols.name(of: entity.id), value: value, localFieldNames: localFields))
        }
        return fragments
    }

    /// `value` with each local symbol replaced by a string of its name, and
    /// the names of the local struct fields gathered into `localFieldNames`.
    /// The recursion is as deep as the value, which `IonReader.maximumDepth`
    /// caps.
    private func resolved(_ value: IonValue, localFieldNames: inout Set<String>) -> IonValue {
        switch value {
        case .symbol(let id):
            return id > symbols.sharedMaximum ? .string(symbols.name(of: id)) : value
        case .list(let items):
            return .list(items.map { resolved($0, localFieldNames: &localFieldNames) })
        case .structure(let members):
            var fields: [IonField] = []
            fields.reserveCapacity(members.fields.count)
            for field in members.fields {
                if field.id > symbols.sharedMaximum { localFieldNames.insert(symbols.name(of: field.id)) }
                fields.append(IonField(id: field.id, value: resolved(field.value, localFieldNames: &localFieldNames)))
            }
            return .structure(IonStruct(fields: fields))
        case .annotated(let ids, let inner):
            return .annotated(ids, resolved(inner, localFieldNames: &localFieldNames))
        case .null, .bool, .int, .float, .string, .opaque:
            return value
        }
    }
}
