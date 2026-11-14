import Foundation

// MARK: - Headings by Size

/// Finds the headings of a Rich Text Format document that names none
/// (FMT47): the paragraphs that are larger than the body text, or bold
/// throughout at the body's size.
///
/// A document written by TextEdit or textutil has no style sheet names:
/// its headings are only bold, larger text. The rule is the one
/// `TextutilHTMLStructure` applies to textutil's HTML, so the same document
/// has the same headings whichever reads it:
/// - the body size is the size with the most characters (a tie goes to the
///   smaller), counted over the whole body;
/// - a paragraph of body text of 1 to 120 characters (not a single letter)
///   is a heading when its own size, the one with the most of its
///   characters, is larger than the body's. The larger sizes in use, largest
///   first, give levels 1, 2, 3, and so on, down to 6;
/// - or, when the body is not mostly bold, when every character is bold and
///   all are at the body's size: the level after the larger sizes' last.
///
/// It is used only when no paragraph is a heading by its style or its
/// outline level: a document that names its headings keeps exactly those.
enum RTFSizeHeadings {
    /// The longest paragraph, in characters, that can be a heading.
    private static let longestHeading = 120

    /// The deepest heading level; smaller sizes share it.
    private static let deepestLevel = 6

    /// How many characters other than white space a set of paragraphs holds,
    /// by font size, and how many of them are bold.
    private struct Census {
        var charactersBySize: [Int: Int] = [:]
        var boldBySize: [Int: Int] = [:]

        /// Counts the paragraphs' text; nil would be an empty census, so an
        /// `isEmpty` check stands in for it.
        init(_ paragraphs: [RTFParagraph]) {
            for paragraph in paragraphs {
                for inline in paragraph.inlines {
                    guard case .text(let words, let bold, _, let size) = inline else { continue }
                    let count = words.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
                    guard count > 0 else { continue }
                    charactersBySize[size, default: 0] += count
                    if bold { boldBySize[size, default: 0] += count }
                }
            }
        }

        /// Whether no character was counted.
        var isEmpty: Bool { charactersBySize.isEmpty }

        /// The size holding the most characters; a tie goes to the smaller.
        var bodySize: Int? {
            charactersBySize.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
        }

        /// Whether every character counted is bold.
        var isEveryCharacterBold: Bool {
            charactersBySize.allSatisfy { boldBySize[$0.key] == $0.value }
        }

        /// Whether more than half the characters at the body size are bold:
        /// a document in bold throughout has no headings from bold.
        var isMostlyBold: Bool {
            guard let size = bodySize else { return false }
            return (boldBySize[size] ?? 0) * 2 > (charactersBySize[size] ?? 0)
        }
    }

    /// `blocks` with each paragraph of body text that is a heading by size
    /// or weight made a heading.
    static func apply(to blocks: [RTFBlock]) -> [RTFBlock] {
        let body = Census(RTFHTMLWriter.paragraphs(of: blocks))
        guard let bodySize = body.bodySize else { return blocks }
        let boldAllowed = !body.isMostlyBold

        // First find the candidates: the larger sizes need all of them
        // before any level can be given.
        var larger: [Int: Int] = [:]      // block index -> its size
        var bold: Set<Int> = []
        for (index, block) in blocks.enumerated() {
            guard case .paragraph(let paragraph) = block, isHeadingLength(paragraph) else { continue }
            let own = Census([paragraph])
            guard !own.isEmpty, let ownSize = own.bodySize else { continue }
            if ownSize > bodySize {
                larger[index] = ownSize
            } else if boldAllowed, own.isEveryCharacterBold, Set(own.charactersBySize.keys) == [bodySize] {
                bold.insert(index)
            }
        }
        guard !larger.isEmpty || !bold.isEmpty else { return blocks }

        // The larger sizes, largest first, give levels 1, 2, 3; bold
        // paragraphs take the level after them.
        let sizes = Set(larger.values).sortedStably(by: >)
        var result = blocks
        for (index, size) in larger {
            if case .paragraph(let paragraph) = blocks[index], let rank = sizes.firstIndex(of: size) {
                result[index] = .heading(paragraph, level: min(rank + 1, deepestLevel))
            }
        }
        for index in bold {
            if case .paragraph(let paragraph) = blocks[index] {
                result[index] = .heading(paragraph, level: min(sizes.count + 1, deepestLevel))
            }
        }
        return result
    }

    /// Whether `paragraph`'s words are short enough to be a heading and are
    /// not a decorative initial: not empty, at most `longestHeading`
    /// characters, and not a single letter (a single digit may be).
    private static func isHeadingLength(_ paragraph: RTFParagraph) -> Bool {
        let label = paragraph.plainText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !label.isEmpty, label.count <= longestHeading else { return false }
        return !(label.count == 1 && label.first?.isLetter == true)
    }
}
