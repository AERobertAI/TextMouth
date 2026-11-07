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
/// to lie inside the text, and the parts to lie inside the markup flow, and
/// together to hold no more bytes than the text does, so a hostile book can
/// make no part, and no sum of parts, larger than its own text.
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
            throw MOBIError.damaged("it is a KF8 book without a skeleton or fragment index")
        }
        // The markup is the first flow of the text; what follows it is not
        // read. A flow table that is missing or odd leaves the whole text.
        let markupEnd = Self.markupFlowEnd(database: database, headers: headers, textLength: textLength)

        let skeletons = try MOBIIndex.table(startingAt: skeletonRecord, in: database).rows
        let fragmentTable = try MOBIIndex.table(startingAt: fragmentRecord, in: database).rows

        var parts: [Part] = []
        // The next row of the fragment index: each skeleton takes the next
        // `fragmentCount` of them.
        var nextFragment = 0
        // The bytes of all the parts so far, held to the text's own size.
        var bytesOfParts = 0
        for skeleton in skeletons {
            guard let fragmentCount = skeleton.values[1]?.first,
                  let place = skeleton.values[6], place.count >= 2 else {
                throw MOBIError.damaged("a row of the skeleton index is missing its place or fragment count")
            }
            guard fragmentCount <= fragmentTable.count - nextFragment else {
                throw MOBIError.damaged("the skeleton index names more fragments than the fragment index holds")
            }
            let skeletonRange = try Self.range(from: place[0], length: place[1], within: markupEnd, "a skeleton")

            // The fragments' places are counted from the end of the skeleton.
            var fragments: [Fragment] = []
            fragments.reserveCapacity(fragmentCount)
            for row in fragmentTable[nextFragment..<(nextFragment + fragmentCount)] {
                guard let place = row.values[6], place.count >= 2,
                      let identifier = row.values[4]?.first,
                      let insertOffset = Self.number(in: row.name) else {
                    throw MOBIError.damaged("a row of the fragment index is missing its place, number, or name")
                }
                let range = try Self.range(
                    from: skeletonRange.upperBound + place[0], length: place[1], within: markupEnd, "a fragment")
                fragments.append(Fragment(insertOffset: insertOffset, identifier: identifier, range: range))
            }
            nextFragment += fragmentCount

            // A part is the skeleton and the fragments after it, and holds
            // nothing else: the sum of what the book's parts hold is held
            // to the text's size, so the HTML written for them is.
            let partBytes = skeletonRange.count + fragments.reduce(0) { $0 + $1.range.count }
            bytesOfParts += partBytes
            guard bytesOfParts <= textLength else {
                throw MOBIError.damaged("its documents hold more than the text does")
            }

            parts.append(Part(skeleton: skeletonRange, fragments: fragments))
        }
        self.init(parts: parts)
    }

    /// The layout of `parts` that are already read, and have been checked.
    init(parts: [Part]) {
        var locations: [Int: (part: Int, fragment: Int)] = [:]
        for (partIndex, part) in parts.enumerated() {
            for (position, fragment) in part.fragments.enumerated() where locations[fragment.identifier] == nil {
                locations[fragment.identifier] = (part: partIndex, fragment: position)
            }
        }
        self.parts = parts
        self.locations = locations
    }

    /// Where the markup flow of the text ends: the end of the first entry of
    /// the flow table (FDST) when there is one and it lies inside the text,
    /// else the end of the text.
    private static func markupFlowEnd(database: MOBIPalmDatabase, headers: MOBIHeaders, textLength: Int) -> Int {
        guard let record = headers.flowTableRecord,
              let table = try? database.record(record, "The flow table"),
              table.hasTag("FDST", at: 0),
              let count = try? table.uint32(8, "The flow count"), count >= 1,
              let end = try? table.uint32(16, "The markup flow's end"),
              end > 0, end <= textLength else { return textLength }
        return end
    }

    /// The range of `length` bytes from `start`, which must lie inside
    /// `0..<limit`.
    /// - Throws: `MOBIError.damaged` otherwise, naming `what`.
    private static func range(from start: Int, length: Int, within limit: Int, _ what: String) throws -> Range<Int> {
        // Written without adding, so no value from the file can overflow.
        guard start >= 0, length >= 0, start <= limit, length <= limit - start else {
            throw MOBIError.damaged("\(what) lies outside the text")
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
