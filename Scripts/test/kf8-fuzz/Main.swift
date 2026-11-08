import Foundation

/// The reader program `fuzz.py` runs: `reader kf8 BOOK` reads a Kindle book as an import does (the Kindle reader,
/// then the shared converter and the chapter parser), prints "OK" and a line of counts, and exits 0; prints "ERR"
/// and the sentence a listener would hear, and exits 1, for a book the reader refuses. A trap is a signal, which
/// `fuzz.py` reports. Built by `build-reader.py` from the sources of the repository, with small stand-ins for the
/// app types the Kindle reader touches (`Stubs.swift`).
@main
struct Reader {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, arguments[1] == "kf8" else {
            print("usage: reader kf8 BOOK")
            exit(2)
        }
        let url = URL(fileURLWithPath: arguments[2])
        do {
            let book = try MOBIParser.prepareBook(url: url)
            let words = book.chapters.reduce(0) { $0 + $1.chapter.wordCount }
            print("OK \(book.chapters.count) chapters, \(words) words")
        } catch {
            print("ERR \(error.localizedDescription)")
            exit(1)
        }
    }
}
