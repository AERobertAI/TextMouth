import Foundation

// MARK: - The Generator

/// A small, fully specified pseudo-random generator (SplitMix64), so that a
/// seed reproduces a damaged file byte for byte on any Mac and any macOS.
/// Swift's own `SystemRandomNumberGenerator` cannot be seeded, and
/// `Hasher` is seeded differently in every process, so neither would let a
/// failing case be reproduced from its id.
struct SplitMix64: RandomNumberGenerator {
    /// The generator's whole state; one step adds a constant and scrambles it.
    private var state: UInt64

    /// A generator that always gives the same numbers for the same `seed`.
    init(seed: UInt64) {
        state = seed
    }

    /// The next 64 random bits.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - The Ways to Damage a File

/// One way to damage a copy of a document, to see what the importers do with
/// it (the import fuzz sweep, `ImportFuzzTests`). Each is applied by
/// `ImportFuzzMutator.apply`, and its raw value is the name that appears in a
/// case's id (`alice.epub#flip8#seed=20261016`).
enum ImportFuzzMutation: String, CaseIterable {
    // Truncations: a download that stopped early.
    case truncate10, truncate25, truncate50, truncate75, truncate90, truncate99
    /// A file with no bytes at all.
    case empty
    // Bit rot: a few bytes changed anywhere.
    case flip1, flip8, flip64
    // A 1 KB window zeroed, removed, or repeated: a bad sector, a lost block,
    // a block written twice.
    case zeroWindow, deleteWindow, duplicateWindow
    /// 1 KB of random bytes before the first real byte.
    case prependRandom
    /// 1 KB of random bytes after the last real byte.
    case appendRandom
    /// A ZIP archive's last 64 bytes, which hold its central directory's end.
    case zipTail
    /// A ZIP archive's first local file header, after its signature.
    case zipHead
    // Text damage.
    /// NUL bytes scattered through the text.
    case insertNUL
    /// Byte sequences that no UTF-8 text can hold.
    case invalidUTF8
    /// One line of a megabyte.
    case longLine
    /// 5,000 unclosed `<div>` elements.
    case deepNesting

    /// The truncations' share of the file that is kept, in percent.
    var keptPercent: Int? {
        switch self {
        case .truncate10: return 10
        case .truncate25: return 25
        case .truncate50: return 50
        case .truncate75: return 75
        case .truncate90: return 90
        case .truncate99: return 99
        default: return nil
        }
    }

    /// How many bytes the flips change.
    var flipCount: Int? {
        switch self {
        case .flip1: return 1
        case .flip8: return 8
        case .flip64: return 64
        default: return nil
        }
    }
}

// MARK: - The Mutator

/// Damages the bytes of documents, in seeded, repeatable ways. Pure: it
/// reads and writes no file, so it is cheap to test.
enum ImportFuzzMutator {
    /// The window the window mutations use, and the random bytes the
    /// prepend and append mutations add.
    static let windowSize = 1024
    /// How many bytes at the end of a ZIP archive `zipTail` corrupts.
    static let zipTailSize = 64
    /// A ZIP local file header is 30 bytes long; its first four are the
    /// signature, which `zipHead` leaves so that the file still looks like
    /// a ZIP archive and the damage is in the fields that follow.
    static let zipHeaderSize = 30
    static let zipSignatureSize = 4
    /// How many NUL bytes `insertNUL` scatters.
    static let nulCount = 16
    /// The length of the line `longLine` adds: one megabyte.
    static let longLineSize = 1_048_576
    /// How many `<div>` elements `deepNesting` opens.
    static let nestingDepth = 5_000

    // MARK: Which Mutations Apply

    /// The file extensions of documents that are ZIP archives: the Word
    /// templates and macro documents and the OpenDocument files are ZIPs too.
    private static let zipExtensions: Set<String> = [
        "epub", "docx", "zip", "dotx", "docm", "dotm", "odt", "ott",
    ]
    /// The file extensions of documents that are plain text of some kind:
    /// RTF, SSML, and XML (a DTBook, or Word 2003 XML under an .xml name)
    /// are damaged as text is. A .doc, .dot, or .webarchive is binary and
    /// takes the general damage only.
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "html", "htm", "xhtml", "rtf", "ssml", "xml",
    ]
    /// The file extensions of documents that are HTML.
    private static let htmlExtensions: Set<String> = ["html", "htm", "xhtml"]

    /// The mutations that make sense for the document named `fileName`, in
    /// a stable order: every document can be truncated, emptied, flipped,
    /// windowed, and padded; ZIP archives also lose their ends; text
    /// documents get NULs, invalid UTF-8 and a long line; HTML also nests.
    static func applicable(to fileName: String) -> [ImportFuzzMutation] {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let isZip = zipExtensions.contains(ext)
        let isText = textExtensions.contains(ext)
        let isHTML = htmlExtensions.contains(ext)
        return ImportFuzzMutation.allCases.filter { mutation in
            switch mutation {
            case .zipTail, .zipHead: return isZip
            case .insertNUL, .invalidUTF8, .longLine: return isText
            case .deepNesting: return isHTML
            default: return true
            }
        }
    }

    // MARK: Case Identity

    /// The stable id of one case: the document, the mutation, and the seed
    /// that reproduces it, such as `alice.epub#flip8#seed=20261016`.
    static func caseID(fileName: String, mutation: ImportFuzzMutation, seed: UInt64) -> String {
        "\(fileName)#\(mutation.rawValue)#seed=\(seed)"
    }

    // MARK: Applying a Mutation

    /// `data` damaged by `mutation`. `fileName` and `seed` choose the random
    /// choices (where a window is, which bytes flip), so the same three
    /// arguments always give the same bytes, and a different seed gives
    /// different ones. Empty input stays empty except where the mutation
    /// adds bytes.
    static func apply(_ mutation: ImportFuzzMutation, to data: Data, fileName: String, seed: UInt64) -> Data {
        var rng = SplitMix64(seed: stream(for: mutation, fileName: fileName, seed: seed))
        let bytes = [UInt8](data)
        let count = bytes.count

        if let percent = mutation.keptPercent {
            return Data(bytes.prefix(count * percent / 100))
        }
        if let flips = mutation.flipCount {
            return Data(flipped(bytes, count: flips, in: 0..<count, using: &rng))
        }

        switch mutation {
        case .empty:
            return Data()
        case .zeroWindow:
            let window = pickWindow(in: count, using: &rng)
            var result = bytes
            for index in window { result[index] = 0 }
            return Data(result)
        case .deleteWindow:
            var result = bytes
            result.removeSubrange(pickWindow(in: count, using: &rng))
            return Data(result)
        case .duplicateWindow:
            let window = pickWindow(in: count, using: &rng)
            var result = bytes
            result.insert(contentsOf: bytes[window], at: window.upperBound)
            return Data(result)
        case .prependRandom:
            return Data(randomBytes(windowSize, using: &rng) + bytes)
        case .appendRandom:
            return Data(bytes + randomBytes(windowSize, using: &rng))
        case .zipTail:
            return Data(flipped(bytes, count: zipTailSize, in: max(0, count - zipTailSize)..<count, using: &rng))
        case .zipHead:
            let header = min(zipSignatureSize, count)..<min(zipHeaderSize, count)
            return Data(flipped(bytes, count: header.count, in: header, using: &rng))
        case .insertNUL:
            return Data(inserting(Array(repeating: 0, count: 1), times: nulCount, into: bytes, using: &rng))
        case .invalidUTF8:
            // 0xC0 0xAF is an overlong "/", and a lone 0xFF starts no
            // sequence at all; each goes in at a place of its own.
            let withOverlong = inserting([0xC0, 0xAF], times: 1, into: bytes, using: &rng)
            return Data(inserting([0xFF], times: 1, into: withOverlong, using: &rng))
        case .longLine:
            let line = [UInt8](repeating: UInt8(ascii: "x"), count: longLineSize)
            return Data(inserting(line, times: 1, into: bytes, using: &rng))
        case .deepNesting:
            let opens = [UInt8](String(repeating: "<div>", count: nestingDepth).utf8)
            return Data(insertingAfterBodyTag(opens, into: bytes))
        default:
            // The truncations and flips returned above.
            return data
        }
    }

    // MARK: Helpers

    /// The generator seed for one case: the caller's seed mixed with a
    /// stable hash (FNV-1a, which unlike `Hasher` does not change from run to
    /// run) of the document's name and the mutation, so two cases of one run
    /// do not make the same random choices.
    private static func stream(for mutation: ImportFuzzMutation, fileName: String, seed: UInt64) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in "\(fileName)#\(mutation.rawValue)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return seed ^ hash
    }

    /// `count` random bytes.
    private static func randomBytes(_ count: Int, using rng: inout SplitMix64) -> [UInt8] {
        (0..<count).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
    }

    /// A random whole number in `0..<upperBound`; `upperBound` must be above 0.
    private static func randomIndex(below upperBound: Int, using rng: inout SplitMix64) -> Int {
        Int(rng.next() % UInt64(upperBound))
    }

    /// A window of `windowSize` bytes (fewer when the file is shorter) at a
    /// random place in a file of `count` bytes; empty when `count` is 0.
    private static func pickWindow(in count: Int, using rng: inout SplitMix64) -> Range<Int> {
        let length = min(windowSize, count)
        guard length > 0 else { return 0..<0 }
        let start = randomIndex(below: count - length + 1, using: &rng)
        return start..<(start + length)
    }

    /// `bytes` with `count` distinct bytes inside `range` changed (fewer
    /// when the range is shorter). Each is XORed with a non-zero value, so
    /// every chosen byte really differs.
    private static func flipped(
        _ bytes: [UInt8],
        count: Int,
        in range: Range<Int>,
        using rng: inout SplitMix64
    ) -> [UInt8] {
        guard !range.isEmpty else { return bytes }
        var result = bytes
        var chosen = Set<Int>()
        while chosen.count < min(count, range.count) {
            chosen.insert(range.lowerBound + randomIndex(below: range.count, using: &rng))
        }
        // Sorted, so the random values are drawn in the same order every run.
        for index in chosen.sorted() {
            let mask = UInt8(truncatingIfNeeded: rng.next() % 255) + 1  // 1...255
            result[index] ^= mask
        }
        return result
    }

    /// `bytes` with `piece` inserted `times` times at random places, each
    /// place drawn from the file as it stands.
    private static func inserting(
        _ piece: [UInt8],
        times: Int,
        into bytes: [UInt8],
        using rng: inout SplitMix64
    ) -> [UInt8] {
        var result = bytes
        for _ in 0..<times {
            let position = randomIndex(below: result.count + 1, using: &rng)
            result.insert(contentsOf: piece, at: position)
        }
        return result
    }

    /// `bytes` with `piece` inserted just after the first `<body ...>` tag,
    /// or at the start when there is none, so the nesting is inside the
    /// page's body where a parser reads it.
    private static func insertingAfterBodyTag(_ piece: [UInt8], into bytes: [UInt8]) -> [UInt8] {
        let marker = [UInt8]("<body".utf8)
        var position = 0
        if let start = firstIndex(of: marker, in: bytes),
           let close = bytes[start...].firstIndex(of: UInt8(ascii: ">")) {
            position = close + 1
        }
        var result = bytes
        result.insert(contentsOf: piece, at: position)
        return result
    }

    /// The first place `needle` occurs in `haystack`, comparing letters
    /// without regard to case; nil when it does not.
    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        func lowered(_ byte: UInt8) -> UInt8 {
            (byte >= 65 && byte <= 90) ? byte + 32 : byte
        }
        for start in 0...(haystack.count - needle.count) {
            var matches = true
            for offset in 0..<needle.count where lowered(haystack[start + offset]) != needle[offset] {
                matches = false
                break
            }
            if matches { return start }
        }
        return nil
    }
}
