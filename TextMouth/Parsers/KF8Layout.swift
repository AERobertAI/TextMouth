import Foundation

/// How a KF8 book (an .azw3, or the second half of a hybrid Kindle file)
/// lays its markup out in the decompressed text, and the way to join it
/// back into the XHTML documents it was cut from.
///
/// KF8 keeps each XHTML document of the book as a *skeleton* (the document
/// with its body's contents cut out) and a run of *fragments* (the pieces
/// cut out of it, in order). The text holds, for each document in turn, its
/// skeleton followed by its fragments, and three tables say where:
/// - the flow table (FDST) names the *flows* of the text: the markup is the
///   first, then the style sheets, SVG, and the like. Only the first is read.
/// - the skeleton index (SKEL) gives, for each document, its skeleton's place
///   and length in the text and how many fragments belong to it.
/// - the fragment index (FRAG) gives, for each fragment in turn, the place in
///   its document where it goes back (counted in the document as it is once
///   the fragments before it are in), its place and length in the text, and
///   its sequence number, which the book's contents and links name it by.
///
/// Written from the format's specification (the MobileRead wiki's "KF8"
/// page) with foliate-js's `mobi.js` (MIT) read as a map of the algorithm.
/// `KF8Book.init` and `loadText` there are the model of `init(...)` and
/// `markup(of:in:anchors:)` here; the function that joins a part is a piece
/// table where `mobi.js` copies the whole document for each fragment, and
/// nothing else is close to it. No code is copied.
///
/// Everything in the tables is untrusted: each place and length is checked
/// to lie inside the markup flow, and the documents and their fragments must
/// follow one another from the start of that flow to its end, so a hostile
/// book can make no part, and no sum of parts, larger than its own text, and
/// a count or place that is wrong is a damaged book (its sentence says what
/// to do, with no talk of skeletons).
struct KF8Layout {

    /// One fragment: a run of the text that goes back into its document.
    struct Fragment {
        /// Where the fragment goes in its document, counted in the document
        /// with the fragments before this one already in.
        let insertOffset: Int
        /// The fragment's sequence number, which the book's contents and
        /// links name it by.
        let identifier: Int
        /// The fragment's bytes, a range of the decompressed text.
        let range: Range<Int>
    }

    /// One document of the book.
    struct Part {
        /// The skeleton's bytes, a range of the decompressed text.
        let skeleton: Range<Int>
        /// The fragments that go into the skeleton, in the order they go in.
        let fragments: [Fragment]
    }

    /// The book's documents, in reading order.
    let parts: [Part]
    /// The flows of the text, from the flow table (FDST): the first is the
    /// markup, and the others are style sheets, SVG pictures, and the like.
    /// Empty for a layout made from parts alone; one flow (the whole text)
    /// where the book has no readable flow table.
    let flows: [Range<Int>]
    /// Where each fragment is, by its sequence number: its part's index and
    /// its place among that part's fragments. The first fragment to have a
    /// number is its.
    let locations: [Int: (part: Int, fragment: Int)]

    /// Most pieces the joining of one part may weigh up in all (each time a
    /// fragment goes somewhere other than the end of what is built so far,
    /// the pieces before its place are looked through). A real book's
    /// fragments go in order and cost one step each; a hostile book that
    /// sends each to the front would cost the square of their number.
    static let maximumJoiningSteps = 2_000_000

    // MARK: Reading the Tables

    /// Reads the layout of the KF8 book in `database` (a book whose record 0
    /// is the one `headers` was read from), whose decompressed text is
    /// `textLength` bytes.
    /// - Throws: `MOBIError.damaged` when a table is missing or does not
    ///   read, or names a place or length outside the text, a fragment
    ///   outside its part, or parts that together hold more than the text.
    init(database: MOBIPalmDatabase, headers: MOBIHeaders, textLength: Int) throws {
        guard let skeletonRecord = headers.skeletonIndexRecord, let fragmentRecord = headers.fragmentIndexRecord else {
            throw MOBIError.damaged("")
        }
        // The markup is the first flow of the text; what follows it is not
        // markup. A flow table that is missing or odd leaves the whole text.
        let flows = Self.flowRanges(database: database, headers: headers, textLength: textLength)
        let markup = flows[0]

        let skeletons = try MOBIIndex.table(startingAt: skeletonRecord, in: database).rows
        let fragmentTable = try MOBIIndex.table(startingAt: fragmentRecord, in: database).rows

        var parts: [Part] = []
        // The next row of the fragment index: each skeleton takes the next
        // `fragmentCount` of them.
        var nextFragment = 0
        // Where the next document must begin: the documents lie end to end,
        // each a skeleton and then its fragments, from the start of the
        // markup flow to its end, as every real book's do (kindlegen's and
        // calibre's, 76 of 76 files the review checked). That holds the HTML written
        // for them to the size of the text, whatever the tables say, and
        // makes a wrong count or place a damaged book rather than a silent
        // loss of part of it.
        var nextStart = markup.lowerBound
        for skeleton in skeletons {
            guard let fragmentCount = skeleton.values[1]?.first,
                  let place = skeleton.values[6], place.count >= 2 else {
                throw MOBIError.damaged("")
            }
            guard fragmentCount <= fragmentTable.count - nextFragment else { throw MOBIError.damaged("") }
            let skeletonRange = try Self.range(from: place[0], length: place[1], within: markup.upperBound)
            guard skeletonRange.lowerBound == nextStart else { throw MOBIError.damaged("") }

            // The fragments' places are counted from the end of the skeleton,
            // and each begins where the one before it ended.
            var fragments: [Fragment] = []
            fragments.reserveCapacity(fragmentCount)
            var fragmentStart = skeletonRange.upperBound
            for row in fragmentTable[nextFragment..<(nextFragment + fragmentCount)] {
                guard let place = row.values[6], place.count >= 2,
                      let identifier = row.values[4]?.first,
                      let insertOffset = Self.number(in: row.name) else {
                    throw MOBIError.damaged("")
                }
                let range = try Self.range(
                    from: skeletonRange.upperBound + place[0], length: place[1], within: markup.upperBound)
                guard range.lowerBound == fragmentStart else { throw MOBIError.damaged("") }
                fragmentStart = range.upperBound
                fragments.append(Fragment(insertOffset: insertOffset, identifier: identifier, range: range))
            }
            nextFragment += fragmentCount
            nextStart = fragmentStart
            parts.append(Part(skeleton: skeletonRange, fragments: fragments))
        }
        // The documents fill the markup flow: a skeleton count that is too small, or an index cut short,
        // would otherwise read part of the book and say nothing of the rest.
        guard nextStart == markup.upperBound else { throw MOBIError.damaged("") }
        self.init(parts: parts, flows: flows)
    }

    /// The layout of `parts` that are already read, and have been checked.
    init(parts: [Part], flows: [Range<Int>] = []) {
        var locations: [Int: (part: Int, fragment: Int)] = [:]
        for (partIndex, part) in parts.enumerated() {
            for (position, fragment) in part.fragments.enumerated() where locations[fragment.identifier] == nil {
                locations[fragment.identifier] = (part: partIndex, fragment: position)
            }
        }
        self.parts = parts
        self.locations = locations
        self.flows = flows
    }

    /// The most flows a book may name. A real book has a few dozen (a style
    /// sheet or two, and an SVG picture for each cover or drawing).
    static let maximumFlows = 65_536

    /// Where the flow table (FDST) says the text ends: the end of its last
    /// flow, or 0 when the book has no flow table that reads. The markup is
    /// the first flow, so this is never less than where it ends. A table with
    /// a flow that ends before the one before it, or an entry cut short, is
    /// not believed (0).
    static func flowTableEnd(database: MOBIPalmDatabase, headers: MOBIHeaders) -> Int {
        guard let record = headers.flowTableRecord,
              let table = try? database.record(record, "The flow table"),
              table.hasTag("FDST", at: 0),
              let count = try? table.uint32(8, "The flow count"), count >= 1, count <= maximumFlows else { return 0 }
        var previousEnd = 0
        for index in 0..<count {
            guard let start = try? table.uint32(12 + index * 8, "A flow's start"),
                  let end = try? table.uint32(16 + index * 8, "A flow's end"),
                  start >= previousEnd, start <= end else { return 0 }
            previousEnd = end
        }
        // An end past what a document's text may be is not believed: the text is then read at its declared length.
        return Int64(previousEnd) <= DocumentByteLimit.current ? previousEnd : 0
    }

    /// The flows of the text, in order, from the flow table (FDST). The first
    /// is the markup. A flow table that is missing, or that does not read, or
    /// whose entries do not lie inside the text and in order, leaves one
    /// flow, the whole text.
    private static func flowRanges(database: MOBIPalmDatabase, headers: MOBIHeaders, textLength: Int) -> [Range<Int>] {
        let whole = [0..<textLength]
        guard let record = headers.flowTableRecord,
              let table = try? database.record(record, "The flow table"),
              table.hasTag("FDST", at: 0),
              let count = try? table.uint32(8, "The flow count"), count >= 1, count <= maximumFlows else { return whole }
        var flows: [Range<Int>] = []
        var previousEnd = 0
        for index in 0..<count {
            guard let start = try? table.uint32(12 + index * 8, "A flow's start"),
                  let end = try? table.uint32(16 + index * 8, "A flow's end"),
                  start >= previousEnd, start <= end else { return whole }
            // A flow that the text does not reach (the records hold less than the table says) is left out,
            // with all after it; the markup flow must lie in the text.
            if end > textLength { break }
            flows.append(start..<end)
            previousEnd = end
        }
        if flows.isEmpty { return whole }
        // The markup flow must hold something, or the table is a lie.
        return flows[0].isEmpty ? whole : flows
    }

    /// The range of `length` bytes from `start`, which must lie inside
    /// `0..<limit`.
    /// - Throws: `MOBIError.damaged` otherwise.
    private static func range(from start: Int, length: Int, within limit: Int) throws -> Range<Int> {
        // Written without adding, so no value from the file can overflow.
        guard start >= 0, length >= 0, start <= limit, length <= limit - start else {
            throw MOBIError.damaged("")
        }
        return start..<(start + length)
    }

    /// The decimal number that `name` spells (digits, perhaps padded with
    /// zeros), or nil when it is not one or is longer than a number can be.
    private static func number(in name: [UInt8]) -> Int? {
        guard !name.isEmpty, name.count <= 10 else { return nil }
        var value = 0
        for byte in name {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return value
    }

    // MARK: Joining a Part

    /// A place in a part's text where an anchor is written: the byte offset
    /// in the text it goes before, and the anchor's id.
    struct Anchor {
        var position: Int
        var id: String
    }

    /// The part `part` as markup: its skeleton with each of its fragments put
    /// back at the place it names, and an empty link (`<a id="..."></a>`)
    /// written before each of `anchors` that lies in a piece of the text the
    /// part is made of. `anchors` must be in ascending order of position.
    ///
    /// The join is one pass over the pieces: the part is first a list of
    /// pieces (ranges of `text`), each fragment splits the piece it goes in
    /// and takes its place between the halves, and the bytes are written
    /// once at the end. Fragments of a real book go one after another at the
    /// end of what is built, which costs one step each.
    /// - Throws: `MOBIError.damaged` for a fragment that goes outside the
    ///   part built so far, or a join that costs more than
    ///   `maximumJoiningSteps`.
    func markup(of part: Part, in text: [UInt8], anchors: [Anchor]) throws -> [UInt8] {
        // The pieces in order, and the length they make together.
        var pieces: [Range<Int>] = [part.skeleton]
        var length = part.skeleton.count
        var steps = 0
        for fragment in part.fragments {
            let place = fragment.insertOffset - part.skeleton.lowerBound
            guard place >= 0, place <= length else {
                throw MOBIError.damaged("a fragment goes outside the document it belongs to")
            }
            // The piece the place lies in and where that piece begins. The
            // last piece is tried first: the fragments of a real book go
            // into it, one after another.
            var index = pieces.count - 1
            var pieceStart = length - pieces[index].count
            if place < pieceStart {
                index = 0
                pieceStart = 0
                while pieceStart + pieces[index].count < place {
                    pieceStart += pieces[index].count
                    index += 1
                    steps += 1
                }
                // The pieces after it are moved by the split below.
                steps += pieces.count - index
                guard steps <= Self.maximumJoiningSteps else {
                    throw MOBIError.damaged("its fragments are not in the order a book puts them")
                }
            }
            // Split that piece at the place, and put the fragment between.
            let piece = pieces[index]
            let split = piece.lowerBound + (place - pieceStart)
            // A fragment with no bytes puts nothing back.
            guard !fragment.range.isEmpty else { continue }
            var replacement: [Range<Int>] = []
            if split > piece.lowerBound { replacement.append(piece.lowerBound..<split) }
            replacement.append(fragment.range)
            if split < piece.upperBound { replacement.append(split..<piece.upperBound) }
            pieces.replaceSubrange(index...index, with: replacement)
            length += fragment.range.count
        }
        return Self.bytes(of: pieces, in: text, anchors: anchors)
    }

    /// The bytes of `pieces` of `text` in order, with an anchor written
    /// before the byte it names wherever one lies in a piece.
    private static func bytes(of pieces: [Range<Int>], in text: [UInt8], anchors: [Anchor]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(pieces.reduce(0) { $0 + $1.count } + (anchors.isEmpty ? 0 : 64))
        for piece in pieces {
            var cursor = piece.lowerBound
            // The first anchor at or after the piece's first byte.
            var next = firstAnchor(atOrAfter: piece.lowerBound, in: anchors)
            while next < anchors.count, anchors[next].position < piece.upperBound {
                let anchor = anchors[next]
                output.append(contentsOf: text[cursor..<anchor.position])
                cursor = anchor.position
                output.append(contentsOf: "<a id=\"\(anchor.id)\"></a>".utf8)
                next += 1
            }
            output.append(contentsOf: text[cursor..<piece.upperBound])
        }
        return output
    }

    /// The index of the first of `anchors` (in ascending order of position)
    /// whose position is `position` or later; their count when none is.
    private static func firstAnchor(atOrAfter position: Int, in anchors: [Anchor]) -> Int {
        var low = 0
        var high = anchors.count
        while low < high {
            let middle = (low + high) / 2
            if anchors[middle].position < position { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
