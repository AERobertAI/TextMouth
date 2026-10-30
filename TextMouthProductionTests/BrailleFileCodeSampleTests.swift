import XCTest
@testable import TextMouth

/// Every BRF and BRL format sample reads alike in every braille file code
/// (braillecodes, BRAILLE-CODES-RESEARCH-2026-10-25.md, section 8.7): its
/// cells, written in another code, read as the same pages, the same
/// structure, and the same page labels as the sample itself in North
/// American Braille ASCII.
///
/// The samples are North American Braille ASCII files, so these tests write
/// their cells in each other code, in memory only, and read them back. That
/// proves round trips, not real use: that the reader reads each code's
/// characters as the cells they were written for, and that the analyzer
/// works on cells alone, naming dot patterns by North American Braille
/// ASCII's mnemonic whatever the code. No sample here was written in
/// another code by the software of a country that uses it; such a file is
/// still wanted.
final class BrailleFileCodeSampleTests: XCTestCase {
    /// Each BRF and BRL sample, by its path inside `TestData/format-samples`:
    /// the list `BrailleSampleGoldenTests` compares.
    private static let samples = [
        "brf/grade2-short.brf",
        "brf/pride-and-prejudice-ch1-grade1.brf",
        "brf/wrapped-titles.brf",
        "brl/pride-and-prejudice-ch1-grade1.brl",
    ]

    // MARK: - Tests

    /// Each sample, its cells written in each other code, reads as the same
    /// pages, the same structure, and the same page labels as in North
    /// American Braille ASCII.
    func testEverySampleReadsAlikeInEveryCode() throws {
        var labels: [String?] = []
        for path in Self.samples {
            let copy = try copyOfFormatSample(path)
            let kind = BrailleBookReader.kind(of: copy)
            let northAmerican = try BrailleFileReader.read(copy, as: kind, code: .northAmerican)
            let structure = BraillePageAnalyzer.structure(of: northAmerican)
            labels += structure.pages.map(\.braillePageLabel)
            let bytes = try [UInt8](Data(contentsOf: copy))

            for code in BrailleFileCode.all where code != .northAmerican {
                let written = Self.bytes(bytes, writtenIn: code)
                // The code writes the cells with other bytes, so reading them
                // alike means something.
                XCTAssertNotEqual(written, bytes, "\(path) in \(code.id)")
                let read = try BrailleFileReader.pages(fromText: Data(written), kind: kind, code: code)
                XCTAssertEqual(read, northAmerican, "the pages of \(path) in \(code.id)")
                let readStructure = BraillePageAnalyzer.structure(of: read)
                XCTAssertEqual(readStructure, structure, "the structure of \(path) in \(code.id)")
                XCTAssertEqual(readStructure.pages.map(\.braillePageLabel), structure.pages.map(\.braillePageLabel),
                               "the page labels of \(path) in \(code.id)")
            }
        }
        // The samples carry braille page numbers, so the labels compared are
        // more than nils.
        XCTAssertTrue(labels.contains { $0 != nil }, "No sample has a braille page label.")
    }

    // MARK: - Writing Another Code

    /// The bytes of a file that holds, in `code`, the cells the North
    /// American Braille ASCII `bytes` hold: each byte that is a cell becomes
    /// the byte `code` writes for the same dots or, in Unicode braille
    /// patterns, the pattern's UTF-8; every other byte (a line end, a form
    /// feed, a tab) is kept as it is.
    private static func bytes(_ bytes: [UInt8], writtenIn code: BrailleFileCode) -> [UInt8] {
        var written: [UInt8] = []
        // A pattern takes three bytes, the most a cell can take.
        written.reserveCapacity(bytes.count * 3)
        for byte in bytes {
            guard let dots = SevenBitBrailleTable.northAmerican.dots(forByte: byte) else {
                written.append(byte)
                continue
            }
            switch code.kind {
            case .sevenBit(let table):
                written.append(table.byte(forDots: dots))
            case .unicodePatterns:
                // U+2800 plus the dots, in UTF-8 as Swift itself writes it.
                let pattern = Unicode.Scalar(0x2800 + UInt32(dots)).map { String(Character($0)) } ?? ""
                written += Array(pattern.utf8)
            }
        }
        return written
    }
}
