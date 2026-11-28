// The driver of Scripts/test/swiftsoup-corpus/run.py: parses every document of a
// folder, as it is and damaged, with whichever SwiftSoup it is linked against,
// and prints one line of summaries for each. Two builds of SwiftSoup that print
// the same lines build the same trees and write the same text and markup.
//
// It is compiled with TextMouthProductionTests/SwiftSoupCorpusKit.swift, the
// file SwiftSoupCorpusTests uses, so the damage and the summaries are the same.
//
// Usage: soupcorpus DIRECTORY DAMAGED_COPIES
//    or: soupcorpus --time FILE (html|xml) RUNS   (the median parse time)
//   Every file of DIRECTORY, in the order of its name: one line "name TAB html
//   TAB xml TAB fragment"; then, for each file of at most 300,000 bytes,
//   DAMAGED_COPIES lines named "name#damagedN".
import Foundation
import SwiftSoup

/// The largest document that is damaged, in bytes (the test's own limit is
/// smaller, to keep a Debug run short; a Release build is quick).
let largestDamagedDocument = 300_000

/// `markup` without the declarations SwiftSoup 2.13.9's XML builder traps on
/// (a "<?" or "<!" construct that names no element: `doc.child(0)` of an
/// empty document, XmlTreeBuilder.swift line 121). TextMouth never hands it
/// one: `MarkupGuard.parseXML` replaces them with empty comments first. Here
/// every "<?" and every "<!" that opens no comment or CDATA section becomes an
/// ordinary start tag, which is the same input for every build compared.
func xmlSafe(_ markup: String) -> String {
    let withoutInstructions = markup.replacingOccurrences(of: "<?", with: "<pi ")
    return withoutInstructions.replacingOccurrences(
        of: "<!(?!--|\\[CDATA\\[)", with: "<bang ", options: .regularExpression
    )
}

/// The line of three summaries for the bytes of one input: the HTML parser,
/// the XML parser, and a body fragment, as the app parses markup.
func summaries(of bytes: [UInt8]) -> String {
    let markup = SoupCorpusKit.markup(of: bytes)
    return [
        SoupCorpusKit.outcome { try SwiftSoup.parseHTML(markup, "https://example.org/") },
        SoupCorpusKit.outcome { try SwiftSoup.parse(xmlSafe(markup), "", Parser.xmlParser()) },
        SoupCorpusKit.outcome { try SwiftSoup.parseBodyFragment(markup) },
    ].joined(separator: "\t")
}

/// Prints the lines for every file of `directory` and its damaged copies.
func run(directory: String, damagedCopies: Int) throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory)
        .filter { !$0.hasSuffix(".tsv") && !$0.hasPrefix(".") }
        .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    for name in names {
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: directory + "/" + name)))
        print(name + "\t" + summaries(of: bytes))
        guard bytes.count <= largestDamagedDocument, damagedCopies > 0 else { continue }
        var damage = SoupDamage(key: name)
        for copy in 1...damagedCopies {
            print("\(name)#damaged\(copy)\t" + summaries(of: SoupCorpusKit.damaged(bytes, &damage)))
        }
    }
}

/// The median of `runs` timings of parsing `markup`, in milliseconds, with
/// the HTML parser or (`xml`) SwiftSoup's XML parser, after one warm-up parse.
func medianParseMilliseconds(_ markup: String, xml: Bool, runs: Int) throws -> Double {
    func parse() throws {
        _ = xml ? try SwiftSoup.parse(xmlSafe(markup), "", Parser.xmlParser()) : try SwiftSoup.parseHTML(markup, "")
    }
    try parse()
    var times: [Double] = []
    for _ in 0..<runs {
        let start = DispatchTime.now().uptimeNanoseconds
        try parse()
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    times.sort()
    return times[times.count / 2]
}

let arguments = CommandLine.arguments
// Timing mode: soupcorpus --time FILE (html|xml) RUNS prints the median parse time.
if arguments.count == 5, arguments[1] == "--time", let runs = Int(arguments[4]), runs > 0 {
    let bytes = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    let median = try medianParseMilliseconds(SoupCorpusKit.markup(of: [UInt8](bytes)), xml: arguments[3] == "xml", runs: runs)
    print(String(format: "%@ %@ %d bytes: median of %d parses %.2f ms", arguments[2], arguments[3], bytes.count, runs, median))
    exit(0)
}
guard arguments.count == 3, let copies = Int(arguments[2]), copies >= 0 else {
    FileHandle.standardError.write(Data("usage: soupcorpus DIRECTORY DAMAGED_COPIES\n".utf8))
    exit(2)
}
try run(directory: arguments[1], damagedCopies: copies)
