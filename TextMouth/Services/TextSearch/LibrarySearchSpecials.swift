import Foundation

/// The non-ASCII characters Foundation's search can match against ASCII
/// text (LIBRARY-SEARCH-RESEARCH-2026-11-13.md, section 3): a line holding one
/// of them may hold a match of a query's ASCII anchor though the anchor's
/// bytes are not there, so `LibrarySearchPrefilter` searches every such line.
///
/// They are those whose full case folding holds ASCII, when case is ignored
/// (the long s for "s", ß and capital ß for "ss", the Kelvin sign for "k",
/// the dotted capital I for "i" with its dot, the Latin ligatures for "ff",
/// "fi", "fl", "ffi", "ffl", and "st", and the letters with a mark that fold
/// to an ASCII letter and the mark), and those whose canonical decomposition
/// is one ASCII character, which match it whether or not case is ignored
/// (the Kelvin sign for "K", the Greek question mark for ";", and the Greek
/// varia for "`"). `LibrarySearchSpecialsTests` checks every scalar against
/// Foundation, so a macOS that matches more fails the test rather than
/// missing matches.
enum LibrarySearchSpecials {
    /// The characters that can match ASCII when case is ignored.
    static let ignoringCase: Set<UInt32> = matchingCase.union([
        0x00DF, // ß: "ss"
        0x0130, // İ: "i" and a combining dot above
        0x0149, // ŉ: "ʼn"
        0x017F, // ſ: "s"
        0x01F0, // ǰ: "j" and a combining caron
        0x1E96, // ẖ: "h" and a combining macron below
        0x1E97, // ẗ: "t" and a combining diaeresis
        0x1E98, // ẘ: "w" and a combining ring above
        0x1E99, // ẙ: "y" and a combining ring above
        0x1E9A, // ẚ: "a" and a modifier letter right half ring
        0x1E9E, // ẞ: "ss"
        0xFB00, // ﬀ: "ff"
        0xFB01, // ﬁ: "fi"
        0xFB02, // ﬂ: "fl"
        0xFB03, // ﬃ: "ffi"
        0xFB04, // ﬄ: "ffl"
        0xFB05, // ﬅ: "st"
        0xFB06, // ﬆ: "st"
    ])

    /// The characters that can match ASCII when case must match: those
    /// canonically equivalent to one ASCII character.
    static let matchingCase: Set<UInt32> = [
        0x037E, // Greek question mark: ";"
        0x1FEF, // Greek varia: "`"
        0x212A, // Kelvin sign: "K"
    ]
}
