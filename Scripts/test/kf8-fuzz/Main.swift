import CryptoKit
import Foundation

/// The reader program `fuzz.py` runs, and a way to look at how a real book is cut into chapters.
///
/// - `reader kf8 BOOK` reads a Kindle book as an import does (the Kindle reader, then the shared converter and
///   the chapter parser), prints "OK" and a line of counts, and exits 0; prints "ERR" and the sentence a listener
///   would hear, and exits 1, for a book the reader refuses. A trap is a signal, which `fuzz.py` reports.
/// - `reader sections BOOK` (or `sections6`, which reads a hybrid file's MOBI 6 half) reads a Kindle book (.azw3,
///   .mobi) or an EPUB (.epub) the same way and prints each chapter as a line
///   "NUMBER<TAB>WORDS<TAB>TITLE<TAB>FIRST SIX WORDS ... LAST SIX WORDS", a line "HEADING<TAB>NUMBER<TAB>LEVEL: TEXT"
///   for each heading, then a line "WORDS<TAB>TOTAL<TAB>SHA-256" whose digest is that of
///   the book's words in order (white space made single spaces, the characters no one sees left out), so two
///   files of one book can be compared by eye or by `diff`, as `KF8RealBookTests` compares them. A last line
///   "SOFTHYPHENS<TAB>COUNT" counts the soft hyphens (U+00AD) left in the chapters' text.
///
/// Built by `build-reader.py` from the sources of the repository, with small stand-ins for the app types the
/// Kindle reader touches (`Stubs.swift`).
@main
struct Reader {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, ["kf8", "sections", "sections6"].contains(arguments[1]) else {
            print("usage: reader kf8|sections|sections6 BOOK")
            exit(2)
        }
        let url = URL(fileURLWithPath: arguments[2])
        do {
            // An EPUB goes to the EPUB reader (to compare a Kindle book with), anything else to the Kindle reader.
            let chapters: [Chapter]
            if url.pathExtension.lowercased() == "epub" {
                chapters = try EPUBParser.prepareBook(url: url).chapters.map(\.chapter)
            } else {
                // sections6 reads a hybrid file from its MOBI 6 half, which a library stored before KF8 was read.
                let half: MOBIBook.HybridChoice = arguments[1] == "sections6" ? .mobi6 : .kf8
                chapters = try MOBIParser.prepareBook(url: url, hybrid: half).chapters.map(\.chapter)
            }
            if arguments[1] != "kf8" {
                printSections(chapters)
            } else {
                let words = chapters.reduce(0) { $0 + $1.wordCount }
                print("OK \(chapters.count) chapters, \(words) words")
            }
        } catch {
            print("ERR \(error.localizedDescription)")
            exit(1)
        }
    }

    /// The characters no one sees, which the words of two files of one book are compared without.
    private static let invisible: Set<Unicode.Scalar> = ["\u{AD}", "\u{200B}", "\u{2060}", "\u{FEFF}"]

    /// The words of `chapters` in order: white space made single spaces, the invisible characters left out.
    private static func words(of chapters: [Chapter]) -> [String] {
        chapters.flatMap { chapter in
            chapter.text.split(whereSeparator: \.isWhitespace).map { word in
                String(String.UnicodeScalarView(word.unicodeScalars.filter { !invisible.contains($0) }))
            }
        }.filter { !$0.isEmpty }
    }

    /// Prints a line for each chapter and the line of totals (see the type's comment).
    private static func printSections(_ chapters: [Chapter]) {
        for (index, chapter) in chapters.enumerated() {
            // The chapter's first and last six words, so a misplaced piece shows at a chapter's edges.
            let chapterWords = words(of: [chapter])
            let edges = chapterWords.prefix(6).joined(separator: " ") + " ... " + chapterWords.suffix(6).joined(separator: " ")
            print("\(index + 1)\t\(chapter.wordCount)\t\(chapter.title)\t\(edges)")
        }
        // The headings of each chapter, as "level: text", as `KF8RealBookTests` compares them.
        for (index, chapter) in chapters.enumerated() {
            for heading in chapter.headings { print("HEADING\t\(index + 1)\t\(heading.level): \(heading.text)") }
        }
        let all = words(of: chapters)
        let digest = SHA256.hash(data: Data(all.joined(separator: " ").utf8)).map { String(format: "%02x", $0) }.joined()
        print("WORDS\t\(all.count)\t\(digest)")
        let soft = chapters.reduce(0) { $0 + $1.text.unicodeScalars.filter { $0 == "\u{AD}" }.count }
        print("SOFTHYPHENS\t\(soft)")
    }
}
