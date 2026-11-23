import CBZip2
import Compression
import Darwin
import Foundation
import XCTest
import os
@testable import TextMouth

// Tests of TextMouth's own interface-text engine (FR39, phase 1): the call's `Format`, the lookup over tables made in
// memory, the specifier check, the pack reader over packs made in memory, the language rules, and the plural rule.
//
// Shared with the iPhone's unit bundle (project.yml). The pack reader's tests and the hostile-text tests read damaged
// files and hostile text on purpose, so they run in trains on GitHub, never on the development Mac (a trap there puts a
// crash report on the person's screen).

// MARK: - Support

/// Tables made in memory: the IDs, and each language's entries as the pack writes them (empty for none, a text, or
/// U+0001 and the forms joined by U+0001). Entries go through the same parser the pack reader uses.
struct InterfaceTextMemoryTables: InterfaceTextTables {
    let ids: [String]
    let languages: [String: [String]]

    /// Tables from `lines`: ID, then language, then the raw entry. An ID a language lacks has no entry there.
    init(lines: [String: [String: String]]) {
        // Local copies, so the closures below do not capture `self` before it is initialized.
        let sortedIDs = lines.keys.sorted()
        let names = Set(lines.values.flatMap { $0.keys })
        ids = sortedIDs
        languages = Dictionary(uniqueKeysWithValues: names.map { name in (name, sortedIDs.map { lines[$0]?[name] ?? "" }) })
    }

    func idList() throws -> InterfaceTextIDList {
        guard let list = InterfaceTextIDList(ids: ids) else { throw InterfaceTextFailure("the IDs are not valid") }
        return list
    }

    func entries(language: String) throws -> [InterfaceTextEntry] {
        guard let raws = languages[language] else { throw InterfaceTextFailure("no \(language) table") }
        let formCount = PluralRules.categories[language]?.count
        return try raws.map { raw in
            guard let entry = InterfaceTextEntry(raw: raw, formCount: formCount) else { throw InterfaceTextFailure("bad entry") }
            return entry
        }
    }
}

/// The reports an engine made, kept safely for a test to read.
final class InterfaceTextReportLog: Sendable {
    private let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
    /// The closure an engine reports to.
    var sink: @Sendable (String) -> Void { { [lines] message in lines.withLock { $0.append(message) } } }
    var messages: [String] { lines.withLock { $0 } }
}

/// A plural entry as the pack writes it: U+0001, then the forms joined by U+0001.
func pluralEntry(_ forms: String...) -> String {
    "\u{1}" + forms.joined(separator: "\u{1}")
}

/// An engine over `lines` that reports to `log`.
func makeInterfaceTextEngine(_ lines: [String: [String: String]], log: InterfaceTextReportLog) -> InterfaceTextEngine {
    InterfaceTextEngine(tables: InterfaceTextMemoryTables(lines: lines), report: log.sink)
}

/// The text of a call in `language`, formatted with the locale the tests use for that language.
func interfaceLine(_ engine: InterfaceTextEngine, _ id: StaticString, _ english: InterfaceText.Format, language: String = "es") -> String {
    engine.text(id: id, english: english, language: language, locale: InterfaceLanguage.locale(forScope: language))
}

/// A pack made in memory, byte for byte as `InterfaceTextPack` reads it, with each field open to damage.
struct InterfaceTextPackBytes {
    /// One blob of the pack: its name, its compressed bytes, and the sizes the directory states.
    struct Blob {
        var name: String
        var compressed: [UInt8]
        var rawSize: Int
        var count: Int
        /// Overrides the offset the directory states (nil: the blob's real place).
        var offset: Int?
        /// The compression method the directory states (`lzma`, `bzip2`, or any other number to damage it).
        var method: UInt32 = InterfaceTextPackBytes.lzma
    }

    /// The directory's method numbers, as the reader and `pack.py` have them.
    static let lzma: UInt32 = 0
    static let bzip2: UInt32 = 1

    var magic = Array("TMSP".utf8)
    var version: UInt16 = 2
    var flags: UInt16 = 0
    var idCount: Int
    var blobs: [Blob]

    /// A blob of `entries` joined and compressed with `method` (LZMA unless given), each entry ended by a NUL, stating the
    /// true sizes.
    static func blob(_ name: String, entries: [String], terminator: UInt8 = 0, method: UInt32 = lzma) -> Blob {
        var raw: [UInt8] = []
        for entry in entries { raw += Array(entry.utf8) + [terminator] }
        return Blob(name: name, compressed: compress(raw, method: method), rawSize: raw.count, count: entries.count, offset: nil, method: method)
    }

    /// A blob of exactly these raw bytes, compressed with `method` (LZMA unless given).
    static func blob(_ name: String, raw: [UInt8], count: Int, method: UInt32 = lzma) -> Blob {
        Blob(name: name, compressed: compress(raw, method: method), rawSize: raw.count, count: count, offset: nil, method: method)
    }

    /// `raw` compressed with `method`: Apple's LZMA, or the system's libbz2 at level 9, the two algorithms the reader
    /// decodes. Any other method compresses as LZMA (a test that names one changes the directory's number only).
    static func compress(_ raw: [UInt8], method: UInt32 = lzma) -> [UInt8] {
        guard !raw.isEmpty else { return [] }
        var output = [UInt8](repeating: 0, count: raw.count + 4096)
        if method == bzip2 {
            var written = UInt32(output.count)
            // libbz2 takes `char *` for both buffers: the source's bytes are rebound only for the call's duration.
            let status = output.withUnsafeMutableBytes { destination in
                raw.withUnsafeBytes { source in
                    BZ2_bzBuffToBuffCompress(
                        destination.baseAddress?.assumingMemoryBound(to: CChar.self), &written,
                        UnsafeMutableRawPointer(mutating: source.baseAddress)?.assumingMemoryBound(to: CChar.self), UInt32(raw.count), 9, 0, 0
                    )
                }
            }
            // A failure is the test's to report: a trap here would end the test host and every test after this one.
            guard status == BZ_OK else {
                XCTFail("the test pack's bzip2 compression failed, with status \(status)")
                return []
            }
            return Array(output[0..<Int(written)])
        }
        let written = compression_encode_buffer(&output, output.count, raw, raw.count, nil, COMPRESSION_LZMA)
        return Array(output[0..<written])
    }

    /// The file's bytes.
    func data() -> Data {
        func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
            withUnsafeBytes(of: value.littleEndian) { Array($0) }
        }
        var header = magic + le(version) + le(flags) + [UInt8](repeating: 0xAB, count: 32) + le(UInt32(idCount)) + le(UInt32(blobs.count))
        var directory: [UInt8] = []
        var body: [UInt8] = []
        var offset = 48 + blobs.count * 32
        for blob in blobs {
            let name = Array(blob.name.utf8)
            directory += name + [UInt8](repeating: 0, count: 12 - name.count)
            directory += le(UInt32(blob.offset ?? offset)) + le(UInt32(blob.compressed.count)) + le(UInt32(blob.rawSize)) + le(UInt32(blob.count)) + le(blob.method)
            body += blob.compressed
            offset += blob.compressed.count
        }
        header += directory + body
        return Data(header)
    }

    /// A good pack of three IDs: English with one plural line, and Spanish. The IDs and English are LZMA blobs and Spanish
    /// a bzip2 one, so every use of the sample reads both methods.
    static func sample() -> InterfaceTextPackBytes {
        InterfaceTextPackBytes(idCount: 3, blobs: [
            blob("ids", entries: ["greeting.hello", "library.books", "library.title"]),
            blob("en", entries: ["", pluralEntry("%lld book", "%lld books"), ""]),
            blob("es", entries: ["Hola", pluralEntry("%lld libro", "%lld libros", "%lld libros"), "Biblioteca"], method: bzip2),
        ])
    }
}

// MARK: - Format

/// `InterfaceText.Format`: a call's English becomes exactly the key Xcode extracts from `String(localized:)` today.
/// Each expected key below is a real key of `Localizable.xcstrings`, named in the test.
final class InterfaceTextTests: XCTestCase {}

extension InterfaceTextTests {
    /// A plain literal: the key `(none)`.
    func testAPlainLiteralIsItsOwnKey() {
        let format: InterfaceText.Format = "(none)"
        XCTAssertEqual(format.format, "(none)")
        XCTAssertTrue(format.arguments.isEmpty)
        XCTAssertNil(format.firstNumber)
    }

    /// A string: the key `%@ - Original Audio`.
    func testAStringInterpolationIsAnAtSign() {
        let title = "Dune"
        let format: InterfaceText.Format = "\(title) - Original Audio"
        XCTAssertEqual(format.format, "%@ - Original Audio")
        XCTAssertEqual(format.arguments, [.text("Dune")])
    }

    /// Anything that is a string interpolates: a substring too.
    func testASubstringInterpolates() {
        let name = "Mr Dune".dropFirst(3)
        let format: InterfaceText.Format = "\"\(name)\" is not a number."
        XCTAssertEqual(format.format, "\"%@\" is not a number.")
        XCTAssertEqual(format.arguments, [.text("Dune")])
    }

    /// A number: the key `%lld Books`, whose argument is an `Int64` whatever integer type gave it.
    func testANumberInterpolationIsLLD() {
        let count: Int = 7
        let small: UInt8 = 200
        let format: InterfaceText.Format = "\(number: count) Books"
        XCTAssertEqual(format.format, "%lld Books")
        XCTAssertEqual(format.arguments, [.number(7)])
        XCTAssertEqual(format.firstNumber, 7)
        let other: InterfaceText.Format = "\(number: small) Books"
        XCTAssertEqual(other.arguments, [.number(200)])
    }

    /// In a literal with interpolations a `%` is doubled: the key `Volume: %lld%%`. A literal with none is kept as
    /// written, since a line with no arguments never reaches the formatter.
    func testAPercentSignIsDoubledOnlyWithInterpolations() {
        let volume = 40
        let format: InterfaceText.Format = "Volume: \(number: volume)%"
        XCTAssertEqual(format.format, "Volume: %lld%%")
        let alone: InterfaceText.Format = "Volume 100%"
        XCTAssertEqual(alone.format, "Volume 100%")
        XCTAssertTrue(alone.arguments.isEmpty)
    }

    /// Two numbers and a string: the keys `%lld of %@, %lld%%` and `%@ - level %lld`.
    func testSeveralArgumentsKeepTheirOrder() {
        let done = 3, percent = 60, name = "Dune", level = 2
        let first: InterfaceText.Format = "\(number: done) of \(name), \(number: percent)%"
        XCTAssertEqual(first.format, "%lld of %@, %lld%%")
        XCTAssertEqual(first.arguments, [.number(3), .text("Dune"), .number(60)])
        let second: InterfaceText.Format = "\(name) - level \(number: level)"
        XCTAssertEqual(second.format, "%@ - level %lld")
    }

    /// Two numbers: the key `%lld by %lld pixels`; the first picks a plural's form.
    func testTheFirstNumberIsThePluralCount() {
        let width = 640, height = 480
        let format: InterfaceText.Format = "\(number: width) by \(number: height) pixels"
        XCTAssertEqual(format.format, "%lld by %lld pixels")
        XCTAssertEqual(format.firstNumber, 640)
    }

    /// Two strings: the key `%@ %@`.
    func testTwoStrings() {
        let first = "a", second = "b"
        let format: InterfaceText.Format = "\(first) \(second)"
        XCTAssertEqual(format.format, "%@ %@")
        XCTAssertEqual(format.arguments, [.text("a"), .text("b")])
    }

    /// An integer too large for 64 bits is held at the largest and never traps.
    func testAHugeIntegerIsClamped() {
        let huge = UInt64.max
        let format: InterfaceText.Format = "\(number: huge)"
        XCTAssertEqual(format.arguments, [.number(Int64.max)])
    }

    /// The arguments reach the formatter as Foundation reads them, and the result is the text of the key.
    func testTheFormatterGivesTheTextOfTheKey() {
        let name = "Dune", count = 3
        let format: InterfaceText.Format = "\(name): \(number: count)%"
        XCTAssertEqual(String(format: format.format, locale: Locale(identifier: "en_US"), arguments: format.formatterArguments), "Dune: 3%")
    }
}

// MARK: - The specifier check

/// `FormatSpecifiers`: the five specifiers only, and only for the arguments the call gives. Hostile texts are refused
/// and so never reach Foundation's formatter.
final class FormatSpecifiersTests: XCTestCase {
    private typealias Kind = FormatSpecifiers.Kind

    func testTheFiveSpecifiersAreAccepted() {
        XCTAssertTrue(FormatSpecifiers.accepts("plain", arguments: []))
        XCTAssertTrue(FormatSpecifiers.accepts("100%% sure", arguments: []))
        XCTAssertTrue(FormatSpecifiers.accepts("%@", arguments: [.text]))
        XCTAssertTrue(FormatSpecifiers.accepts("%lld", arguments: [.number]))
        XCTAssertTrue(FormatSpecifiers.accepts("%2$@ of %1$lld", arguments: [.number, .text]))
        XCTAssertTrue(FormatSpecifiers.accepts("%lld of %@, %lld%%", arguments: [.number, .text, .number]))
    }

    /// A text may leave an argument out (a plural's `one` often drops its number), and may use one twice.
    func testAnArgumentMayBeUnusedOrRepeated() {
        XCTAssertTrue(FormatSpecifiers.accepts("un libro", arguments: [.number]))
        XCTAssertTrue(FormatSpecifiers.accepts("%1$@ y %1$@", arguments: [.text]))
        XCTAssertTrue(FormatSpecifiers.accepts("%@", arguments: [.text, .number]))
    }

    /// The hostile texts: each is refused for the call that gives one string and one number.
    func testHostileTextsAreRefused() {
        let arguments: [Kind] = [.text, .number]
        let hostile = [
            "%s", "%n", "%5$@", "%@ %@ %@", "%lld %lld %lld", "%", "100%", "%%%", "%d", "%ld", "%f", "%x", "%p", "%c", "%S",
            "%1$@ %lld", "%@ %2$lld", "%0$@", "%100$@", "%1$", "%1$s", "%-5@", "%5@", "%.2@", "%l", "%ll", "%llx", "%hhd",
            "%@%", "%1", "%$@", "%99$lld", "%2$@",
        ]
        for text in hostile {
            XCTAssertFalse(FormatSpecifiers.accepts(text, arguments: arguments), "\(text.debugDescription) must be refused")
        }
    }

    /// A kind that does not match its argument: `%@` given a number, `%lld` given a string.
    func testAKindMustMatchItsArgument() {
        XCTAssertFalse(FormatSpecifiers.accepts("%@", arguments: [.number]))
        XCTAssertFalse(FormatSpecifiers.accepts("%lld", arguments: [.text]))
        XCTAssertFalse(FormatSpecifiers.accepts("%lld %@", arguments: [.text, .number]))
        XCTAssertFalse(FormatSpecifiers.accepts("%1$lld", arguments: [.text]))
    }

    /// A specifier with no argument to read.
    func testASpecifierNeedsAnArgument() {
        XCTAssertFalse(FormatSpecifiers.accepts("%@", arguments: []))
        XCTAssertFalse(FormatSpecifiers.accepts("%2$@", arguments: [.text]))
    }

    /// Numbered and unnumbered specifiers in one text are refused, as are text with non-ASCII before and after.
    func testMixingNumberedAndUnnumberedIsRefused() {
        XCTAssertFalse(FormatSpecifiers.accepts("%1$@ %lld", arguments: [.text, .number]))
        XCTAssertTrue(FormatSpecifiers.accepts("é %@ ü %% ✓", arguments: [.text]))
    }

    /// The scanner reads the slots of a text in order.
    func testTheSlotsOfATextInOrder() {
        XCTAssertEqual(FormatSpecifiers.slots(in: "%2$@ %%"), [.init(position: 2, kind: .text)])
        XCTAssertEqual(FormatSpecifiers.slots(in: "%lld%@"), [.init(position: nil, kind: .number), .init(position: nil, kind: .text)])
        XCTAssertNil(FormatSpecifiers.slots(in: "%s"))
    }
}

// MARK: - Entries and IDs

extension InterfaceTextTests {
    func testTheFormsOfAnEntry() {
        XCTAssertEqual(InterfaceTextEntry(raw: "", formCount: 2), .absent)
        XCTAssertEqual(InterfaceTextEntry(raw: "Hola", formCount: nil), .plain("Hola"))
        XCTAssertEqual(InterfaceTextEntry(raw: pluralEntry("a", "b"), formCount: 2), .plural(["a", "b"]))
        XCTAssertEqual(InterfaceTextEntry(raw: pluralEntry("a"), formCount: 1), .plural(["a"]))
        // An empty form stays a form (the specifier check refuses it).
        XCTAssertEqual(InterfaceTextEntry(raw: pluralEntry("", "b"), formCount: 2), .plural(["", "b"]))
    }

    func testMalformedEntriesAreRefused() {
        // The wrong number of forms, and a language with no rule at all.
        XCTAssertNil(InterfaceTextEntry(raw: pluralEntry("a", "b", "c"), formCount: 2))
        XCTAssertNil(InterfaceTextEntry(raw: pluralEntry("a", "b"), formCount: nil))
        // The separator inside a plain text, and a NUL anywhere.
        XCTAssertNil(InterfaceTextEntry(raw: "a\u{1}b", formCount: 2))
        XCTAssertNil(InterfaceTextEntry(raw: "a\u{0}b", formCount: 2))
    }

    func testDecodingATableBlob() throws {
        let bytes = Array("one\0\0three\0".utf8)
        XCTAssertEqual(try InterfaceTextEntry.decodeAll(bytes, count: 3, formCount: 2), [.plain("one"), .absent, .plain("three")])
        XCTAssertEqual(try InterfaceTextEntry.decodeAll([], count: 0, formCount: 2), [])
    }

    func testDamagedTableBlobsAreRefused() {
        // No terminator on the last entry, a wrong count either way, and a stray byte after the last NUL.
        XCTAssertThrowsError(try InterfaceTextEntry.decodeAll(Array("a\0b".utf8), count: 2, formCount: 2))
        XCTAssertThrowsError(try InterfaceTextEntry.decodeAll(Array("a\0b\0".utf8), count: 3, formCount: 2))
        XCTAssertThrowsError(try InterfaceTextEntry.decodeAll(Array("a\0b\0".utf8), count: 1, formCount: 2))
        // Bad UTF-8: a lone continuation byte, an overlong form, a surrogate, and a cut sequence.
        for bad: [UInt8] in [[0x80, 0], [0xC0, 0xAF, 0], [0xED, 0xA0, 0x80, 0], [0xE2, 0x82, 0]] {
            XCTAssertThrowsError(try InterfaceTextEntry.decodeAll(bad, count: 1, formCount: 2), "\(bad)")
        }
    }

    func testTheIDListFindsEveryIDAndNothingElse() throws {
        let ids = ["common.cancel", "common.ok", "feed.add", "feed.addFolder", "zebra.last"]
        let list = try XCTUnwrap(InterfaceTextIDList(ids: ids))
        XCTAssertEqual(list.count, 5)
        XCTAssertEqual(list.index(of: "common.cancel"), 0)
        XCTAssertEqual(list.index(of: "feed.add"), 2)
        XCTAssertEqual(list.index(of: "feed.addFolder"), 3)
        XCTAssertEqual(list.index(of: "zebra.last"), 4)
        for miss: StaticString in ["common", "common.cancel2", "feed.ad", "feed.addFolderX", "a", "zzz", ""] {
            XCTAssertNil(list.index(of: miss), "\(miss)")
        }
        XCTAssertEqual(list.id(at: 3), "feed.addFolder")
        XCTAssertEqual(try XCTUnwrap(InterfaceTextIDList(ids: [])).count, 0)
        XCTAssertNil(try XCTUnwrap(InterfaceTextIDList(ids: [])).index(of: "x.y"))
    }

    func testTheIDListRefusesBadLists() {
        XCTAssertNil(InterfaceTextIDList(ids: ["b.x", "a.x"]), "out of order")
        XCTAssertNil(InterfaceTextIDList(ids: ["a.x", "a.x"]), "given twice")
        XCTAssertNil(InterfaceTextIDList(ids: ["a.x", ""]), "empty")
        XCTAssertNil(InterfaceTextIDList(ids: ["a b.x"]), "a space")
        XCTAssertNil(InterfaceTextIDList(ids: ["é.x"]), "not ASCII")
    }

    /// A decoded ids blob: ended by NUL or line feed, the last terminator optional, exactly the stated count.
    func testTheIDListOfABlob() {
        XCTAssertEqual(InterfaceTextIDList(blob: Array("a.x\0b.y\0".utf8), count: 2)?.count, 2)
        XCTAssertEqual(InterfaceTextIDList(blob: Array("a.x\nb.y".utf8), count: 2)?.count, 2)
        XCTAssertNil(InterfaceTextIDList(blob: Array("a.x\0b.y\0".utf8), count: 3))
        XCTAssertNil(InterfaceTextIDList(blob: Array("a.x\0\0b.y\0".utf8), count: 3), "an empty ID")
    }
}

// MARK: - The lookup

/// The lookup over tables made in memory.
extension InterfaceTextTests {
    func testAPlainLine() {
        let log = InterfaceTextReportLog()
        let engine = makeInterfaceTextEngine(["greeting.hello": ["es": "Hola", "fr": "Bonjour"]], log: log)
        XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello", language: "es"), "Hola")
        XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello", language: "fr"), "Bonjour")
        XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello", language: "en"), "Hello")
        XCTAssertEqual(log.messages, [])
    }

    /// English is the code's own: a pack's English text for a plain line is never used in its place.
    func testEnglishIsTheCallsOwnForAPlainLine() {
        let log = InterfaceTextReportLog()
        let engine = makeInterfaceTextEngine(["greeting.hello": ["en": "Howdy"]], log: log)
        XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello", language: "en"), "Hello")
    }

    func testAnArgumentIsFormatted() {
        let log = InterfaceTextReportLog()
        let engine = makeInterfaceTextEngine(["book.by": ["es": "%2$@ de %1$@"]], log: log)
        let title = "Quijote", author = "Cervantes"
        XCTAssertEqual(interfaceLine(engine, "book.by", "\(title) by \(author)"), "Cervantes de Quijote", "positions reorder")
        XCTAssertEqual(interfaceLine(engine, "book.by", "\(title) by \(author)", language: "en"), "Quijote by Cervantes")
    }

    /// A percent sign in the English comes out once, from `%%`.
    func testAPercentSignInTheEnglish() {
        let engine = makeInterfaceTextEngine([:], log: InterfaceTextReportLog())
        let level = 40
        XCTAssertEqual(interfaceLine(engine, "volume.level", "Volume: \(number: level)%", language: "en"), "Volume: 40%")
    }

    func testPluralsInArabic() {
        let engine = makeInterfaceTextEngine(["common.books": ["ar": pluralEntry("z", "o", "t", "f %lld", "m %lld", "x %lld")]], log: InterfaceTextReportLog())
        let expected: [(Int, String)] = [(0, "z"), (1, "o"), (2, "t"), (3, "f 3"), (10, "f 10"), (11, "m 11"), (99, "m 99"),
                                         (100, "x 100"), (103, "f 103"), (111, "m 111")]
        for (count, text) in expected {
            XCTAssertEqual(interfaceLine(engine, "common.books", "\(number: count) books", language: "ar"), text, "\(count)")
        }
    }

    func testPluralsInRussian() {
        let engine = makeInterfaceTextEngine(["common.books": ["ru": pluralEntry("%lld книга", "%lld книги", "%lld книг", "%lld книги")]], log: InterfaceTextReportLog())
        let expected: [(Int, String)] = [(1, "1 книга"), (2, "2 книги"), (4, "4 книги"), (5, "5 книг"), (11, "11 книг"),
                                         (12, "12 книг"), (21, "21 книга"), (22, "22 книги"), (100, "100 книг"), (101, "101 книга")]
        for (count, text) in expected {
            XCTAssertEqual(interfaceLine(engine, "common.books", "\(number: count) books", language: "ru"), text, "\(count)")
        }
    }

    func testPluralsInPolish() {
        let engine = makeInterfaceTextEngine(["common.books": ["pl": pluralEntry("%lld książka", "%lld książki", "%lld książek", "%lld książki")]], log: InterfaceTextReportLog())
        let expected: [(Int, String)] = [(1, "1 książka"), (2, "2 książki"), (5, "5 książek"), (12, "12 książek"),
                                         (22, "22 książki"), (21, "21 książek")]
        for (count, text) in expected {
            XCTAssertEqual(interfaceLine(engine, "common.books", "\(number: count) books", language: "pl"), text, "\(count)")
        }
    }

    func testPluralsInJapanese() {
        let engine = makeInterfaceTextEngine(["common.books": ["ja": pluralEntry("%lld 冊")]], log: InterfaceTextReportLog())
        for count in [0, 1, 2, 100] {
            XCTAssertEqual(interfaceLine(engine, "common.books", "\(number: count) books", language: "ja"), "\(count) 冊")
        }
    }

    /// A plural line of English reads the pack's English forms, whichever form the code's literal is; a line the pack
    /// has no plural English entry for shows the call's format at every count.
    func testEnglishPluralFormsComeFromThePack() {
        let log = InterfaceTextReportLog()
        let engine = makeInterfaceTextEngine(["common.books": ["en": pluralEntry("%lld book", "%lld books")]], log: log)
        XCTAssertEqual(interfaceLine(engine, "common.books", "\(number: 1) books", language: "en"), "1 book")
        XCTAssertEqual(interfaceLine(engine, "common.books", "\(number: 2) books", language: "en"), "2 books")
        // The literal's own wording does not matter: the entry is the English (the build packs the catalog every time).
        XCTAssertEqual(interfaceLine(engine, "common.books", "\(number: 1) volumes", language: "en"), "1 book")
        // An ID with no plural English entry shows the call's format at every count.
        XCTAssertEqual(interfaceLine(engine, "common.nothing", "\(number: 2) volumes", language: "en"), "2 volumes")
        XCTAssertEqual(log.messages.count, 1, "only the unknown ID is reported: \(log.messages)")
    }

    /// The code's literal may be the `one` form ("...is kept..."): the other counts still read the `other` form (Apple's
    /// English table picks the form, so "are kept" at every count but one). A finding of the pack test on the real pack.
    func testAnEnglishLiteralThatIsTheOneFormStillGetsEveryForm() {
        let log = InterfaceTextReportLog()
        let engine = makeInterfaceTextEngine(["kept.count": ["en": pluralEntry("%lld is kept", "%lld are kept")]], log: log)
        XCTAssertEqual(interfaceLine(engine, "kept.count", "\(number: 1) is kept", language: "en"), "1 is kept")
        XCTAssertEqual(interfaceLine(engine, "kept.count", "\(number: 0) is kept", language: "en"), "0 are kept")
        XCTAssertEqual(interfaceLine(engine, "kept.count", "\(number: 12345) is kept", language: "en"), "12,345 are kept")
        XCTAssertEqual(log.messages, [])
    }

    /// English plural forms that number their specifiers (`%1$@ ... %2$lld`) are served as well.
    func testEnglishPluralFormsWithPositionsAreServed() {
        let log = InterfaceTextReportLog()
        let engine = makeInterfaceTextEngine(["pages.held": ["en": pluralEntry("%1$@ holds %2$lld page", "%1$@ holds %2$lld pages")]], log: log)
        let name = "Atlas"
        XCTAssertEqual(interfaceLine(engine, "pages.held", "\(name) holds \(number: 1) pages", language: "en"), "Atlas holds 1 page")
        XCTAssertEqual(interfaceLine(engine, "pages.held", "\(name) holds \(number: 3) pages", language: "en"), "Atlas holds 3 pages")
        XCTAssertEqual(log.messages, [])
    }

    /// An English plural entry that does not fit the call's arguments is not used: the call's own format shows.
    func testAnEnglishPluralEntryThatDoesNotFitTheCallIsNotUsed() {
        let engine = makeInterfaceTextEngine(["books.bad": ["en": pluralEntry("%@ book", "%@ books")]], log: InterfaceTextReportLog())
        XCTAssertEqual(interfaceLine(engine, "books.bad", "\(number: 2) books", language: "en"), "2 books")
    }

    /// A line with no entry in the language shows English, including its plural.
    func testALineWithoutAnEntryShowsEnglish() {
        let log = InterfaceTextReportLog()
        let engine = makeInterfaceTextEngine(["common.books": ["en": pluralEntry("%lld book", "%lld books")], "greeting.hello": ["es": "Hola"]], log: log)
        XCTAssertEqual(interfaceLine(engine, "common.books", "\(number: 1) books", language: "es"), "1 book")
        XCTAssertEqual(log.messages, [], "an absent entry is the normal fallback, not a problem")
    }

    func testAnUnknownIDShowsEnglishAndReportsOnce() {
        let log = InterfaceTextReportLog()
        let engine = makeInterfaceTextEngine(["greeting.hello": ["es": "Hola"]], log: log)
        for _ in 0..<3 { XCTAssertEqual(interfaceLine(engine, "nobody.knows", "Never seen"), "Never seen") }
        XCTAssertEqual(log.messages.count, 1)
        XCTAssertTrue(log.messages[0].contains("nobody.knows"), log.messages[0])
    }

    /// The entry point for an ID that is not a literal (tools and tests) answers as the `StaticString` one does: the
    /// pack's text, an argument formatted, the person's own line, and an unknown ID shown in English and reported once.
    func testARuntimeIDAnswersAsALiteralDoes() {
        let log = InterfaceTextReportLog()
        let engine = makeInterfaceTextEngine(["book.by": ["es": "%2$@ de %1$@"], "greeting.hello": ["es": "Hola"]], log: log)
        let title = "Quijote", author = "Cervantes"
        let english: InterfaceText.Format = "\(title) by \(author)"
        let locale = InterfaceLanguage.locale(forScope: "es")
        let runtimeID = ["book", "by"].joined(separator: ".")
        XCTAssertEqual(engine.text(runtimeID: runtimeID, english: english, language: "es", locale: locale), "Cervantes de Quijote")
        XCTAssertEqual(engine.text(runtimeID: runtimeID, english: english, language: "es", locale: locale),
                       interfaceLine(engine, "book.by", english))
        engine.setOverrides(["es": ["greeting.hello": .plain("Buenas")]])
        XCTAssertEqual(engine.text(runtimeID: "greeting.hello", english: "Hello", language: "es", locale: locale), "Buenas")
        for _ in 0..<2 { XCTAssertEqual(engine.text(runtimeID: "nobody.knows", english: "Never seen", language: "es", locale: locale), "Never seen") }
        XCTAssertEqual(log.messages.count, 1)
        XCTAssertTrue(log.messages[0].contains("nobody.knows"), log.messages[0])
    }

    func testALanguageThePackLacksShowsEnglishAndReportsOnce() {
        let log = InterfaceTextReportLog()
        let engine = makeInterfaceTextEngine(["greeting.hello": ["es": "Hola"]], log: log)
        for _ in 0..<3 { XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello", language: "de"), "Hello") }
        XCTAssertEqual(log.messages.count, 1)
    }

    func testAMissingPackShowsEnglishAndReportsOnce() {
        let log = InterfaceTextReportLog()
        let engine = InterfaceTextEngine(open: { nil }, report: log.sink)
        for _ in 0..<3 { XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello"), "Hello") }
        XCTAssertEqual(log.messages.count, 1)
        XCTAssertNil(engine.idCount)
    }

    func testAnUnreadablePackShowsEnglishAndReportsOnce() {
        let log = InterfaceTextReportLog()
        let engine = InterfaceTextEngine(open: { throw InterfaceTextFailure("damaged") }, report: log.sink)
        for _ in 0..<3 { XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello"), "Hello") }
        XCTAssertEqual(log.messages.count, 1)
        XCTAssertTrue(log.messages[0].contains("damaged"))
    }

    /// A table with a malformed entry is refused whole: English, reported once.
    func testAMalformedTableShowsEnglish() {
        let log = InterfaceTextReportLog()
        // Three forms for a language of two categories.
        let engine = makeInterfaceTextEngine(["common.books": ["de": pluralEntry("a", "b", "c")], "greeting.hello": ["de": "Hallo"]], log: log)
        XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello", language: "de"), "Hello")
        XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello", language: "de"), "Hello")
        XCTAssertEqual(log.messages.count, 1)
    }

    /// A text that fails its check shows English, and is reported once however often it is asked for.
    func testAFailingTextShowsEnglishAndReportsOnce() {
        let log = InterfaceTextReportLog()
        let engine = makeInterfaceTextEngine(["greeting.hello": ["es": "%s hola"]], log: log)
        let name = "N"
        for _ in 0..<5 { XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello \(name)"), "Hello N") }
        XCTAssertEqual(log.messages.count, 1)
    }

    /// A line with no arguments is never formatted (as Apple's `String(localized:)` does not): a lone `%` stays, in the
    /// code's English and in a translation, and a translation that looks like a specifier is shown as it is.
    func testALineWithNoArgumentsIsNeverFormatted() {
        let log = InterfaceTextReportLog()
        let engine = makeInterfaceTextEngine(["volume.full": ["es": "Volumen 100%"], "odd.line": ["es": "50%% %s %@"]], log: log)
        XCTAssertEqual(interfaceLine(engine, "volume.full", "Volume 100%", language: "en"), "Volume 100%")
        XCTAssertEqual(interfaceLine(engine, "volume.full", "Volume 100%"), "Volumen 100%")
        XCTAssertEqual(interfaceLine(engine, "odd.line", "Odd"), "50%% %s %@")
        XCTAssertEqual(log.messages, [])
    }

    /// A plural form may leave out its number ("Un libro") and may name only some arguments; a form that drops the
    /// first argument and then uses an unnumbered `%@` reads slot 1, which holds the number: refused, English shown.
    func testAPluralFormMayLeaveOutItsNumber() {
        let log = InterfaceTextReportLog()
        let engine = makeInterfaceTextEngine([
            "common.books": ["es": pluralEntry("Un libro", "%lld libros", "%lld libros"), "en": pluralEntry("%lld book", "%lld books")],
            "common.by": ["es": pluralEntry("Uno de %2$@", "%1$lld de %2$@", "%1$lld de %2$@")],
            "common.bad": ["es": pluralEntry("Uno de %@", "%lld de %@", "%lld de %@")],
        ], log: log)
        let one = 1, many = 5, name = "Ana"
        XCTAssertEqual(interfaceLine(engine, "common.books", "\(number: one) books"), "Un libro")
        XCTAssertEqual(interfaceLine(engine, "common.books", "\(number: many) books"), "5 libros")
        XCTAssertEqual(interfaceLine(engine, "common.by", "\(number: one) by \(name)"), "Uno de Ana")
        XCTAssertEqual(interfaceLine(engine, "common.by", "\(number: many) by \(name)"), "5 de Ana")
        // The whole entry is refused, so every count shows English.
        XCTAssertEqual(interfaceLine(engine, "common.bad", "\(number: one) by \(name)"), "1 by Ana")
        XCTAssertEqual(interfaceLine(engine, "common.bad", "\(number: many) by \(name)"), "5 by Ana")
        XCTAssertEqual(log.messages.count, 1, "\(log.messages)")
    }

    /// Apple's own behavior, which the engine matches: `String(localized:)` of a key with no interpolation keeps its
    /// `%` and does not format a translation. A sandbox bundle holds the key `Volume 100%` translated with a lone `%`.
    func testAppleKeepsALonePercentInALineWithNoArguments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InterfaceTextPercent-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("es.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let table = ["Volume 100%": "Volumen 100%"]
        try PropertyListSerialization.data(fromPropertyList: table, format: .binary, options: 0)
            .write(to: folder.appendingPathComponent("Localizable.strings"))
        let bundle = try XCTUnwrap(Bundle(path: folder.path))
        let key: String.LocalizationValue = "Volume 100%"
        let apple = String(localized: key, bundle: bundle, locale: Locale(identifier: "es_US"))
        XCTAssertEqual(apple, "Volumen 100%")
        let engine = makeInterfaceTextEngine(["volume.full": ["es": "Volumen 100%"]], log: InterfaceTextReportLog())
        XCTAssertEqual(interfaceLine(engine, "volume.full", "Volume 100%"), apple)
    }

    /// Every hostile text, as a pack entry, shows English: none reaches Foundation's formatter (which `%s` or `%n`
    /// could crash or exploit), because what shows is the call's English and not the text.
    func testHostileTextsNeverReachTheFormatter() {
        let hostile = ["%s", "%n", "%5$@ x", "%@ %@", "100%", "%1$@ %lld", "%d", "%.1000000d", "%99999999999$@", "%*d", "%lld"]
        for (position, text) in hostile.enumerated() {
            let log = InterfaceTextReportLog()
            let engine = makeInterfaceTextEngine(["x.line": ["es": text]], log: log)
            let name = "N"
            XCTAssertEqual(interfaceLine(engine, "x.line", "Hi \(name)"), "Hi N", "\(text.debugDescription) at \(position)")
        }
        // A `%@` for a line that gives a number, and a `%lld` for one that gives a string.
        let engine = makeInterfaceTextEngine(["number.line": ["es": "%@ cosas"], "string.line": ["es": "Hola %lld"]], log: InterfaceTextReportLog())
        let count = 3, name = "N"
        XCTAssertEqual(interfaceLine(engine, "number.line", "\(number: count) things"), "3 things")
        XCTAssertEqual(interfaceLine(engine, "string.line", "Hi \(name)"), "Hi N")
    }

    /// An empty form of a plural is refused like any bad text.
    func testAnEmptyPluralFormShowsEnglish() {
        let engine = makeInterfaceTextEngine(["common.books": ["es": pluralEntry("", "%lld libros", "%lld libros")]], log: InterfaceTextReportLog())
        let count = 1
        XCTAssertEqual(interfaceLine(engine, "common.books", "\(number: count) books"), "1 books")
    }

    /// A plural entry for a call with no number gives its last form, `other`.
    func testAPluralEntryWithoutANumberGivesOther() {
        let engine = makeInterfaceTextEngine(["common.books": ["es": pluralEntry("uno", "millones", "libros")]], log: InterfaceTextReportLog())
        XCTAssertEqual(interfaceLine(engine, "common.books", "Books"), "libros")
    }

    /// The person's own line wins, if it passes the same check.
    func testThePersonsOwnLineWins() {
        let log = InterfaceTextReportLog()
        let engine = makeInterfaceTextEngine(["greeting.hello": ["es": "Hola"]], log: log)
        engine.setOverrides(["es": ["greeting.hello": .plain("Buenas")]])
        XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello"), "Buenas")
        XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello", language: "en"), "Hello", "another language is unchanged")
        engine.setOverrides(["es": ["greeting.hello": .plain("%s")]])
        let name = "N"
        XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello \(name)"), "Hello N", "a hostile own line shows English")
        engine.setOverrides([:])
        XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello"), "Hola")
    }

    /// The pack is opened once, at the first lookup, however many follow.
    func testThePackOpensOnceAtTheFirstLookup() {
        let opened = OSAllocatedUnfairLock(initialState: 0)
        let tables = InterfaceTextMemoryTables(lines: ["greeting.hello": ["es": "Hola"]])
        let engine = InterfaceTextEngine(open: { opened.withLock { $0 += 1 }; return tables }, report: { _ in })
        XCTAssertEqual(opened.withLock { $0 }, 0)
        for _ in 0..<10 { _ = interfaceLine(engine, "greeting.hello", "Hello") }
        XCTAssertEqual(opened.withLock { $0 }, 1)
        XCTAssertEqual(engine.idCount, 1)
    }

    /// English is decoded in an English session for a call with a number, and in another language only when a line
    /// falls back to it: a Spanish line with its own entry never decodes English.
    func testEnglishIsDecodedOnlyWhenItIsNeeded() {
        let asked = OSAllocatedUnfairLock<[String]>(initialState: [])
        let tables = InterfaceTextMemoryTables(lines: [
            "common.books": ["en": pluralEntry("%lld book", "%lld books"), "es": pluralEntry("%lld libro", "%lld libros", "%lld libros")],
            "common.shelves": ["en": pluralEntry("%lld shelf", "%lld shelves")],
        ])
        let engine = InterfaceTextEngine(open: {
            struct Counting: InterfaceTextTables {
                let inner: InterfaceTextMemoryTables
                let asked: OSAllocatedUnfairLock<[String]>
                func idList() throws -> InterfaceTextIDList { try inner.idList() }
                func entries(language: String) throws -> [InterfaceTextEntry] {
                    asked.withLock { $0.append(language) }
                    return try inner.entries(language: language)
                }
            }
            return Counting(inner: tables, asked: asked)
        }, report: { _ in })
        let count = 2
        XCTAssertEqual(interfaceLine(engine, "common.books", "\(number: count) books", language: "es"), "2 libros")
        XCTAssertEqual(asked.withLock { $0 }, ["es"], "a line with its own entry needs no English")
        XCTAssertEqual(interfaceLine(engine, "common.shelves", "\(number: count) shelves", language: "es"), "2 shelves")
        XCTAssertEqual(asked.withLock { $0 }, ["es", "en"], "a fallback with a number reads English")
        XCTAssertEqual(interfaceLine(engine, "common.shelves", "\(number: count) shelves", language: "es"), "2 shelves")
        XCTAssertEqual(asked.withLock { $0 }, ["es", "en"], "and once")
    }

    /// Many threads at once, under a time limit.
    func testConcurrentLookups() {
        let log = InterfaceTextReportLog()
        let engine = makeInterfaceTextEngine([
            "common.books": ["es": pluralEntry("%lld libro", "%lld libros", "%lld libros"), "ru": pluralEntry("%lld книга", "%lld книги", "%lld книг", "%lld книги"),
                          "en": pluralEntry("%lld book", "%lld books")],
            "greeting.hello": ["es": "Hola", "ru": "Привет"],
            "bad.line": ["es": "%s"],
        ], log: log)
        let group = DispatchGroup()
        let wrong = OSAllocatedUnfairLock(initialState: 0)
        for thread in 0..<16 {
            group.enter()
            DispatchQueue.global().async {
                for round in 0..<2_000 {
                    let language = (thread + round) % 2 == 0 ? "es" : "ru"
                    if interfaceLine(engine, "greeting.hello", "Hello", language: language) != (language == "es" ? "Hola" : "Привет") { wrong.withLock { $0 += 1 } }
                    if interfaceLine(engine, "common.books", "\(number: 1) books", language: language) != (language == "es" ? "1 libro" : "1 книга") { wrong.withLock { $0 += 1 } }
                    if interfaceLine(engine, "bad.line", "Bad \(number: thread)", language: "es") != "Bad \(thread)" { wrong.withLock { $0 += 1 } }
                    if interfaceLine(engine, "no.such", "None", language: language) != "None" { wrong.withLock { $0 += 1 } }
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success, "the lookups did not finish in a minute")
        XCTAssertEqual(wrong.withLock { $0 }, 0)
        // Each problem once: the bad text, and the unknown ID.
        XCTAssertEqual(log.messages.count, 2, "\(log.messages)")
    }
}

// MARK: - The language

extension InterfaceTextTests {
    func testTheLanguageOfTheBundle() {
        XCTAssertEqual(InterfaceLanguage.resolve("es"), "es")
        XCTAssertEqual(InterfaceLanguage.resolve("pt-BR"), "pt-BR")
        XCTAssertEqual(InterfaceLanguage.resolve("zh-Hans"), "zh-Hans")
        XCTAssertEqual(InterfaceLanguage.resolve("zh-Hant"), "zh-Hant")
        XCTAssertEqual(InterfaceLanguage.resolve("zh_Hant_TW"), "zh-Hant")
        XCTAssertEqual(InterfaceLanguage.resolve("zh"), "zh-Hans")
        XCTAssertEqual(InterfaceLanguage.resolve("pt"), "pt-BR")
        XCTAssertEqual(InterfaceLanguage.resolve("iw"), "he")
        XCTAssertEqual(InterfaceLanguage.resolve("fr-CA"), "fr")
        XCTAssertEqual(InterfaceLanguage.resolve("ES"), "es")
        XCTAssertEqual(InterfaceLanguage.resolve("nb"), "en", "not one of the 25")
        XCTAssertEqual(InterfaceLanguage.resolve("xx"), "en")
        XCTAssertEqual(InterfaceLanguage.resolve(""), "en")
        XCTAssertEqual(InterfaceLanguage.resolve(nil), "en")
    }

    func testEveryCarriedLanguageResolvesToItself() {
        for language in PluralRules.categories.keys { XCTAssertEqual(InterfaceLanguage.resolve(language), language) }
    }

    func testSystemInAHostedTestIsEnglishWithTheUnitedStates() {
        let state = InterfaceLanguage.systemState(hostsTestBundle: true, preferredLocalizations: ["es"], currentLocale: Locale(identifier: "es_ES"))
        XCTAssertEqual(state.language, "en")
        XCTAssertEqual(state.locale.identifier, "en_US")
        // And this process, which hosts the tests, uses it.
        XCTAssertTrue(TextMouthRuntime.current.hostsTestBundle)
        XCTAssertEqual(InterfaceLanguage.current.language, "en")
    }

    /// The iPhone app a UI test launched is sandboxed but hosts no bundle: it follows its launch language
    /// (`-AppleLanguages (es) -AppleLocale es_ES`) with the current locale, as the app does.
    func testSystemInAUITestsLaunchFollowsItsLaunchLanguage() {
        let locale = Locale(identifier: "es_ES")
        let state = InterfaceLanguage.systemState(hostsTestBundle: false, preferredLocalizations: ["es"], currentLocale: locale)
        XCTAssertEqual(state, InterfaceLanguage.State(language: "es", locale: locale))
    }

    func testSystemInTheAppFollowsThePreferredLocalization() {
        let locale = Locale(identifier: "es_US")
        let state = InterfaceLanguage.systemState(hostsTestBundle: false, preferredLocalizations: ["es", "en"], currentLocale: locale)
        XCTAssertEqual(state, InterfaceLanguage.State(language: "es", locale: locale))
        XCTAssertEqual(InterfaceLanguage.systemState(hostsTestBundle: false, preferredLocalizations: [], currentLocale: locale).language, "en")
    }

    func testATestLanguageIsBoundForOneScopeOnly() {
        XCTAssertEqual(InterfaceLanguage.current.language, "en")
        InterfaceLanguage.$scopedLanguage.withValue("ru") {
            XCTAssertEqual(InterfaceLanguage.current.language, "ru")
            XCTAssertEqual(InterfaceLanguage.current.locale.identifier, "ru_US")
        }
        XCTAssertEqual(InterfaceLanguage.current.language, "en")
    }

    func testTheLocaleOfATestLanguage() {
        XCTAssertEqual(InterfaceLanguage.locale(forScope: "es").identifier, "es_US")
        XCTAssertEqual(InterfaceLanguage.locale(forScope: "pt-BR").identifier, "pt_US")
        XCTAssertEqual(InterfaceLanguage.locale(forScope: "zh-Hans").language.languageCode?.identifier, "zh")
        XCTAssertEqual(InterfaceLanguage.locale(forScope: "fa").numberingSystem.identifier, "latn")
    }

    /// The call a view makes, for an ID the shipped pack does not hold (a made-up one): every language shows the call's
    /// English, whether the host ships a pack (it does since the "Pack interface text" phase) or not.
    func testTheCallShowsEnglishForAnIDThePackLacks() {
        let count = 3
        XCTAssertEqual(InterfaceText.line("interfaceTextTests.sample", "Count: \(number: count), 100%"), "Count: 3, 100%")
        XCTAssertEqual(InterfaceText.line("interfaceTextTests.sample", "Count: \(number: count), 100%", language: "es"), "Count: 3, 100%")
        InterfaceLanguage.$scopedLanguage.withValue("ru") {
            XCTAssertEqual(InterfaceText.line("interfaceTextTests.plain", "Plain"), "Plain")
        }
    }
}

// MARK: - The plural rule

extension InterfaceTextTests {
    func testTheCategoriesOfSampleCounts() {
        XCTAssertEqual(PluralRules.category(of: 1, language: "en"), "one")
        XCTAssertEqual(PluralRules.category(of: 0, language: "fr"), "one")
        XCTAssertEqual(PluralRules.category(of: 1_000_000, language: "es"), "many")
        XCTAssertEqual(PluralRules.category(of: 22, language: "ru"), "few")
        XCTAssertEqual(PluralRules.category(of: 5, language: "ar"), "few")
        XCTAssertEqual(PluralRules.category(of: 2, language: "he"), "two")
        XCTAssertNil(PluralRules.category(of: 1, language: "xx"))
    }

    /// A negative count is judged by its size, and `Int.min` and `Int.max` do not trap.
    func testNegativeAndExtremeCounts() {
        XCTAssertEqual(PluralRules.category(of: -1, language: "en"), "one")
        XCTAssertEqual(PluralRules.category(of: -22, language: "ru"), "few")
        for language in PluralRules.categories.keys {
            XCTAssertNotNil(PluralRules.category(of: Int.min, language: language))
            XCTAssertNotNil(PluralRules.category(of: Int.max, language: language))
        }
    }

    /// The form index follows the language's category order, ending with `other`.
    func testTheFormIndex() {
        XCTAssertEqual(PluralRules.formIndex(of: 0, language: "ar"), 0)
        XCTAssertEqual(PluralRules.formIndex(of: 1, language: "ar"), 1)
        XCTAssertEqual(PluralRules.formIndex(of: 100, language: "ar"), 5)
        XCTAssertEqual(PluralRules.formIndex(of: 7, language: "ja"), 0)
        XCTAssertEqual(PluralRules.formIndex(of: 5, language: "en"), 1)
        XCTAssertNil(PluralRules.formIndex(of: 5, language: "xx"))
    }

    /// Every language's table ends with `other`, which the form index relies on, and every category the rule returns
    /// is one of the language's.
    func testEveryLanguageEndsWithOtherAndOnlyAnswersItsOwnCategories() {
        for (language, categories) in PluralRules.categories {
            XCTAssertEqual(categories.last, "other", language)
            for count in [0, 1, 2, 3, 5, 11, 21, 100, 1_000_000] {
                XCTAssertTrue(categories.contains(PluralRules.category(of: count, language: language) ?? ""), "\(language) \(count)")
            }
        }
    }

    /// Every language the bundle lists has a plural rule in `PluralRules`, so a language added later is checked at every
    /// count, not skipped. (Moved from `LanguagePackTests`, which read the languages of the app's own tables, FR39 phase 8.)
    func testEveryLanguageTheBundleListsHasAPluralRule() {
        let listed = Bundle.main.localizations.filter { $0 != "Base" }
        XCTAssertFalse(listed.isEmpty, "the bundle lists no language")
        let without = listed.filter { PluralRules.category(of: 1, language: $0) == nil }
        XCTAssertTrue(without.isEmpty, "Add a plural rule to PluralRules for: \(without)")
    }

    /// The arguments a key's format takes (`LanguagePackLookups.arguments`, which the harness and the hosted pack test
    /// feed every lookup with): sequential and positional specifiers, `%%`, and a precision. (Moved from
    /// `LanguagePackTests`.)
    func testTheArgumentsOfAKeyFollowItsSpecifiers() {
        XCTAssertEqual(LanguagePackLookups.arguments(forKey: "No specifier", count: 3)?.count, 0)
        XCTAssertEqual(LanguagePackLookups.arguments(forKey: "%lld books", count: 3)?.count, 1)
        // `%%` takes no argument: the text, the count, then the text.
        XCTAssertEqual(LanguagePackLookups.arguments(forKey: "%lld%% of %@ and %@", count: 3)?.count, 3)
        // A positional specifier goes to its own slot, and a gap before it is filled.
        XCTAssertEqual(LanguagePackLookups.arguments(forKey: "%2$lld then %1$@", count: 3)?.count, 2)
        XCTAssertEqual(LanguagePackLookups.arguments(forKey: "%3$lld", count: 3)?.count, 3)
        // A conversion the lookups cannot feed is reported, not guessed.
        XCTAssertNil(LanguagePackLookups.arguments(forKey: "%s", count: 3))
        XCTAssertEqual(LanguagePackLookups.specifiers(in: "%1$@ of %2$lld")?.map(\.position), [1, 2])
    }

    /// The counts the plural probe asks Apple about: every count from 0 to 10,000, then each power of ten from 10^4
    /// to 10^15 with the counts on either side, then the counts just below 2^53, the largest whole number a `Double`
    /// holds exactly (Foundation rounds the count through a `Double`, so above it the category is no longer the
    /// language's rule; no count in the app comes near), and the 13 counts the pack proof asks every line
    /// (`InterfaceTextProof.counts`), so that the rule it relies on is Apple's at each of them.
    static let pluralProbeCounts: [Int] = {
        var counts = Array(0...10_000)
        var power = 10_000
        for _ in 4...15 {
            counts.append(contentsOf: [power - 1, power, power + 1])
            power *= 10
        }
        let limit = 1 << 53
        counts.append(contentsOf: (limit - 3)...limit)
        counts.append(contentsOf: InterfaceTextProof.counts.map { Int($0) })
        return Array(Set(counts)).sorted()
    }()

    /// Apple's own plural rule picks, at each count the helpers use, the category `PluralRules` expects (CLDR's, and the
    /// table `Scripts/l10n/catalog.py` keeps), for every language the table names. Each language gets a small bundle in the
    /// test's own sandbox whose `.stringsdict` has a form for every category that names it, so the text that comes back is
    /// the category Apple chose. The apps ship no table of Apple's, so this test writes its own (moved from
    /// `LanguagePackTests`, FR39 phase 8); it stays so that an operating system that changes a rule shows.
    func testApplesPluralRuleAgreesWithTheTableForEveryLanguage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluralRules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        // Every category the languages use, each form's text being the category's own name. `zero` goes in only for
        // a language whose own rule has it (Arabic): Foundation reads an explicit `zero` form as "the count is 0" in
        // every language, which is not a language's own rule (the first run of this test, on GitHub, showed German at
        // 0 choosing `zero`).
        let key = "%lld probe"
        func probeTable(withZero: Bool) throws -> Data {
            var forms: [String: Any] = ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld"]
            for category in ["one", "two", "few", "many", "other"] + (withZero ? ["zero"] : []) {
                forms[category] = "\(category) %lld"
            }
            let table: [String: Any] = [key: ["NSStringLocalizedFormatKey": "%#@value@", "value": forms]]
            return try PropertyListSerialization.data(fromPropertyList: table, format: .binary, options: 0)
        }

        // Every count is compared in one pass, and the mismatches are collected, so a failure lists them all and the
        // 250,000 comparisons carry no assertion each. The time is printed for the report, never asserted.
        let counts = Self.pluralProbeCounts
        var checked = 0
        var wrong: [String] = []
        let started = Date()
        for (language, categories) in PluralRules.categories.sorted(by: { $0.key < $1.key }) {
            let folder = root.appendingPathComponent("\(language).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try probeTable(withZero: categories.contains("zero")).write(to: folder.appendingPathComponent("Localizable.stringsdict"))
            let bundle = try XCTUnwrap(LanguagePackLookups.bundle(language: language, in: root), language)
            // The bundle's text for the key, and the locale, are the same for every count: ask once for each language.
            let format = LanguagePackLookups.effectiveText(bundle, key: key)
            let locale = Locale(identifier: language)
            for count in counts {
                guard let expected = PluralRules.category(of: count, language: language), categories.contains(expected) else {
                    wrong.append("\(language) at \(count): the table has no category in \(categories)")
                    continue
                }
                // The text is "<category> <count>": the category is the first word.
                let text = String(format: format, locale: locale, count)
                let chosen = text.split(separator: " ").first.map(String.init)
                if chosen != expected { wrong.append("\(language) at \(count): Apple picked \(String(describing: chosen)), the table \(expected)") }
                checked += 1
            }
        }
        print("Plural probe: \(checked) counts in \(PluralRules.categories.count) languages took \(Date().timeIntervalSince(started)) s")
        XCTAssertTrue(wrong.isEmpty, "\(wrong.count) counts differ; the first:\n" + wrong.prefix(10).joined(separator: "\n"))
        XCTAssertEqual(checked, PluralRules.categories.count * counts.count)
    }
}

// MARK: - The pack reader

/// The pack reader over packs made in memory: good packs read back, and every kind of damage gives a thrown failure,
/// never a trap. Run in trains only, since the damage is the point.
final class InterfaceTextPackTests: XCTestCase {
    func testAGoodPackReadsBack() throws {
        let pack = try InterfaceTextPack(data: InterfaceTextPackBytes.sample().data())
        XCTAssertEqual(pack.idCount, 3)
        let ids = try pack.idList()
        XCTAssertEqual(ids.index(of: "library.books"), 1)
        XCTAssertEqual(try pack.entries(language: "es"), [.plain("Hola"), .plural(["%lld libro", "%lld libros", "%lld libros"]), .plain("Biblioteca")])
        XCTAssertEqual(try pack.entries(language: "en"), [.absent, .plural(["%lld book", "%lld books"]), .absent])
        XCTAssertTrue(pack.hasLanguage("es"))
        XCTAssertFalse(pack.hasLanguage("ids"))
        XCTAssertFalse(pack.hasLanguage("de"))
        XCTAssertThrowsError(try pack.entries(language: "de"))
    }

    /// The engine over a pack made in memory: the whole path from file bytes to a line.
    func testTheEngineReadsAPack() throws {
        let log = InterfaceTextReportLog()
        let pack = try InterfaceTextPack(data: InterfaceTextPackBytes.sample().data())
        let engine = InterfaceTextEngine(tables: pack, report: log.sink)
        XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello"), "Hola")
        let count = 2
        XCTAssertEqual(interfaceLine(engine, "library.books", "\(number: count) books"), "2 libros")
        XCTAssertEqual(interfaceLine(engine, "library.books", "\(number: count) books", language: "en"), "2 books")
        XCTAssertEqual(log.messages, [])
    }

    func testAnEmptyPackIsValid() throws {
        let pack = try InterfaceTextPack(data: InterfaceTextPackBytes(idCount: 0, blobs: [InterfaceTextPackBytes.blob("ids", entries: [])]).data())
        XCTAssertEqual(try pack.idList().count, 0)
    }

    /// Each header and directory fault is a thrown failure.
    func testDamagedHeadersAreRefused() {
        func refused(_ name: String, _ change: (inout InterfaceTextPackBytes) -> Void, file: StaticString = #filePath, line: UInt = #line) {
            var pack = InterfaceTextPackBytes.sample()
            change(&pack)
            XCTAssertThrowsError(try InterfaceTextPack(data: pack.data()), name, file: file, line: line)
        }
        refused("bad magic") { $0.magic = Array("TMSX".utf8) }
        refused("version 0") { $0.version = 0 }
        refused("version 1, the format before each blob named its method") { $0.version = 1 }
        refused("version 3") { $0.version = 3 }
        refused("an unknown method") { $0.blobs[1].method = 2 }
        refused("a method with a high bit set") { $0.blobs[1].method = 0x8000_0001 }
        refused("flags") { $0.flags = 1 }
        refused("no ids blob") { $0.blobs.removeFirst() }
        refused("a blob listed twice") { $0.blobs.append($0.blobs[1]) }
        refused("a count that is not the ID count") { $0.blobs[1].count = 2 }
        refused("an ID count that is not the blobs'") { $0.idCount = 4 }
        refused("a blob past the end") { $0.blobs[1].offset = 1_000_000 }
        refused("a blob inside the directory") { $0.blobs[1].offset = 10 }
        refused("a blob that starts at the end and runs on") { $0.blobs[2].offset = $0.data().count - 1 }
        refused("a raw size that is a bomb") { $0.blobs[1].rawSize = 1_000_000_000 }
        refused("a name with a space") { $0.blobs[1].name = "e n" }
        refused("an empty name") { $0.blobs[1].name = "" }
        refused("a name with a control character") { $0.blobs[1].name = "e\u{1}" }
    }

    func testShortFilesAreRefused() {
        let whole = InterfaceTextPackBytes.sample().data()
        // Every proper prefix of a good pack, from nothing to one byte short, is refused: the last blob ends the file.
        for length in 0..<whole.count {
            XCTAssertThrowsError(try InterfaceTextPack(data: Data(whole.prefix(length))), "length \(length)")
        }
    }

    /// Every byte of a good pack, changed to every other value we try: no trap, whatever it gives.
    func testNoChangedByteTraps() {
        let whole = InterfaceTextPackBytes.sample().data()
        for index in 0..<whole.count {
            for value in [UInt8(0), 1, 0x7F, 0x80, 0xFF, whole[index] ^ 0x01] {
                var changed = whole
                changed[index] = value
                guard let pack = try? InterfaceTextPack(data: changed) else { continue }
                _ = try? pack.idList()
                _ = try? pack.entries(language: "es")
                _ = try? pack.entries(language: "en")
            }
        }
    }

    /// A blob whose bytes are not a stream of the method its directory names.
    func testGarbageInPlaceOfALanguageBlobGivesEnglish() throws {
        for method in [InterfaceTextPackBytes.lzma, InterfaceTextPackBytes.bzip2] {
            var bytes = InterfaceTextPackBytes.sample()
            bytes.blobs[2] = InterfaceTextPackBytes.Blob(
                name: "es", compressed: Array(repeating: 0x5A, count: 64), rawSize: 100, count: 3, offset: nil, method: method
            )
            let log = InterfaceTextReportLog()
            let engine = InterfaceTextEngine(tables: try InterfaceTextPack(data: bytes.data()), report: log.sink)
            for _ in 0..<3 { XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello"), "Hello", "method \(method)") }
            XCTAssertEqual(log.messages.count, 1, "method \(method)")
        }
    }

    /// A blob cut short, a raw size too large or too small, a wrong entry count, bad UTF-8, a missing terminator: each
    /// fails the blob and the lookup shows English, with one report. Each is tried under both compression methods, and
    /// bzip2 has two faults of its own: a byte changed inside the stream, which fails its CRC, and a stream that is
    /// longer than the raw size says.
    func testDamagedLanguageBlobsGiveEnglish() throws {
        let spanish = ["Hola", pluralEntry("%lld libro", "%lld libros", "%lld libros"), "Biblioteca"]
        for method in [InterfaceTextPackBytes.lzma, InterfaceTextPackBytes.bzip2] {
            func blob(_ entries: [String]) -> InterfaceTextPackBytes.Blob { InterfaceTextPackBytes.blob("es", entries: entries, method: method) }
            func blob(raw: [UInt8]) -> InterfaceTextPackBytes.Blob { InterfaceTextPackBytes.blob("es", raw: raw, count: 3, method: method) }
            var cases: [(String, InterfaceTextPackBytes.Blob)] = []
            let good = blob(spanish)
            var cut = good; cut.compressed = Array(good.compressed.prefix(good.compressed.count / 2)); cases.append(("cut", cut))
            var cutByOne = good; cutByOne.compressed.removeLast(); cases.append(("cut by one byte", cutByOne))
            var longer = good; longer.rawSize += 5; cases.append(("raw size too large", longer))
            var shorter = good; shorter.rawSize -= 5; cases.append(("raw size too small", shorter))
            var shortCount = good; shortCount.count = 2; cases.append(("count in the directory", shortCount))
            var twoEntries = blob(Array(spanish.prefix(2))); twoEntries.count = 3
            cases.append(("two entries under a directory that says three", twoEntries))
            var fourEntries = blob(spanish + ["extra"]); fourEntries.count = 3
            cases.append(("four entries under a directory that says three", fourEntries))
            cases.append(("no last terminator", blob(raw: Array("Hola\0".utf8) + Array("x\0".utf8) + Array("Biblioteca".utf8))))
            cases.append(("bad UTF-8", blob(raw: [0x48, 0xFF, 0, 0x78, 0, 0x79, 0])))
            cases.append(("overlong UTF-8", blob(raw: [0xC0, 0xAF, 0, 0x78, 0, 0x79, 0])))
            cases.append(("surrogate", blob(raw: [0xED, 0xA0, 0x80, 0, 0x78, 0, 0x79, 0])))
            cases.append(("a plural of the wrong size", blob(["Hola", pluralEntry("a", "b"), "x"])))
            if method == InterfaceTextPackBytes.bzip2 {
                // The stream's block CRC covers the text, so a changed byte in the middle fails it (or the block's structure).
                var flipped = good; flipped.compressed[flipped.compressed.count / 2] ^= 0xFF; cases.append(("a changed byte", flipped))
                // The stream's own end-of-stream CRC, the last four bytes before the padding.
                var checksum = good; checksum.compressed[checksum.compressed.count - 3] ^= 0x01; cases.append(("a wrong checksum", checksum))
                // A stream that decodes to more bytes than the directory's raw size.
                var tooLong = InterfaceTextPackBytes.blob("es", entries: spanish + ["more text than the directory says there is"], method: method)
                tooLong.rawSize = good.rawSize; tooLong.count = 3; cases.append(("a stream longer than the raw size", tooLong))
            }
            for (name, blob) in cases {
                var bytes = InterfaceTextPackBytes.sample()
                bytes.blobs[2] = blob
                let log = InterfaceTextReportLog()
                guard let pack = try? InterfaceTextPack(data: bytes.data()) else { continue }
                let engine = InterfaceTextEngine(tables: pack, report: log.sink)
                for _ in 0..<3 { XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello"), "Hello", "\(name), method \(method)") }
                XCTAssertEqual(log.messages.count, 1, "\(name), method \(method): \(log.messages)")
            }
        }
    }

    /// One pack with an LZMA blob and a bzip2 blob reads both, and the sample's own (Spanish bzip2, English LZMA) says so.
    func testABzip2BlobAndAnLZMABlobReadInOnePack() throws {
        let bytes = InterfaceTextPackBytes.sample()
        XCTAssertEqual(bytes.blobs.map(\.method), [InterfaceTextPackBytes.lzma, InterfaceTextPackBytes.lzma, InterfaceTextPackBytes.bzip2])
        let pack = try InterfaceTextPack(data: bytes.data())
        XCTAssertEqual(try pack.entries(language: "es").first, .plain("Hola"))
        XCTAssertEqual(try pack.entries(language: "en").count, 3)
        XCTAssertEqual(try pack.idList().count, 3)
    }

    /// A blob under the wrong method (an LZMA stream said to be bzip2, and the reverse) is damaged, not read as the other.
    func testAStreamUnderTheWrongMethodGivesEnglish() throws {
        for (actual, stated) in [(InterfaceTextPackBytes.lzma, InterfaceTextPackBytes.bzip2), (InterfaceTextPackBytes.bzip2, InterfaceTextPackBytes.lzma)] {
            var bytes = InterfaceTextPackBytes.sample()
            var blob = InterfaceTextPackBytes.blob("es", entries: ["Hola", pluralEntry("%lld libro", "%lld libros", "%lld libros"), "Biblioteca"], method: actual)
            blob.method = stated
            bytes.blobs[2] = blob
            let log = InterfaceTextReportLog()
            let engine = InterfaceTextEngine(tables: try InterfaceTextPack(data: bytes.data()), report: log.sink)
            XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello"), "Hello")
            XCTAssertEqual(log.messages.count, 1)
        }
    }

    /// Damage in the ids blob: no language can then be used at all.
    func testDamagedIDBlobsGiveEnglish() throws {
        var twoIDs = InterfaceTextPackBytes.blob("ids", entries: ["greeting.hello", "library.books"]); twoIDs.count = 3
        let cases: [(String, InterfaceTextPackBytes.Blob)] = [
            ("out of order", InterfaceTextPackBytes.blob("ids", entries: ["library.title", "greeting.hello", "library.books"])),
            ("given twice", InterfaceTextPackBytes.blob("ids", entries: ["greeting.hello", "greeting.hello", "library.books"])),
            ("an invalid ID", InterfaceTextPackBytes.blob("ids", entries: ["greeting hello", "library.books", "library.title"])),
            ("two IDs under a directory that says three", twoIDs),
        ]
        for (name, blob) in cases {
            var bytes = InterfaceTextPackBytes.sample()
            bytes.blobs[0] = blob
            guard let pack = try? InterfaceTextPack(data: bytes.data()) else { continue }
            let log = InterfaceTextReportLog()
            let engine = InterfaceTextEngine(tables: pack, report: log.sink)
            XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello"), "Hello", name)
            XCTAssertEqual(log.messages.count, 1, "\(name): \(log.messages)")
        }
    }

    /// The IDs in a blob ended by line feeds (as the design's prototype wrote them) read the same.
    func testIDsEndedByLineFeedsRead() throws {
        var bytes = InterfaceTextPackBytes.sample()
        bytes.blobs[0] = InterfaceTextPackBytes.blob("ids", raw: Array("greeting.hello\nlibrary.books\nlibrary.title".utf8), count: 3)
        let pack = try InterfaceTextPack(data: bytes.data())
        XCTAssertEqual(try pack.idList().count, 3)
    }

    // MARK: Numbers for the report

    /// The time of a decode and of a lookup, and the memory a decoded language takes, for a pack of the real size: 4,200
    /// lines of about 40 bytes. The numbers are printed for the report and never asserted.
    func testMeasureTheDecodeAndTheLookup() throws {
        let lineCount = 4_200
        let ids = (0..<lineCount).map { String(format: "area.member%04d", $0) }
        let texts = (0..<lineCount).map { "Línea número \($0) con un texto de largo parecido al real, y %@" }
        let blobs = [InterfaceTextPackBytes.blob("ids", entries: ids), InterfaceTextPackBytes.blob("es", entries: texts), InterfaceTextPackBytes.blob("en", entries: texts)]
        let pack = try InterfaceTextPack(data: InterfaceTextPackBytes(idCount: lineCount, blobs: blobs).data())

        let before = Self.footprint()
        var started = Date()
        let list = try pack.idList()
        let idSeconds = Date().timeIntervalSince(started)
        started = Date()
        let entries = try pack.entries(language: "es")
        let decodeSeconds = Date().timeIntervalSince(started)
        let kept = Self.footprint() - before
        XCTAssertEqual(entries.count, lineCount)
        XCTAssertEqual(list.count, lineCount)

        let engine = InterfaceTextEngine(tables: pack, report: { _ in })
        let name = "N"
        _ = interfaceLine(engine, "area.member0100", "x \(name)")
        let lookups = 100_000
        started = Date()
        for _ in 0..<lookups { _ = interfaceLine(engine, "area.member2100", "x \(name)") }
        let perLookup = Date().timeIntervalSince(started) / Double(lookups)
        print("Interface text: ids decode \(idSeconds * 1000) ms, a language decode \(decodeSeconds * 1000) ms, memory kept \(kept) bytes, a lookup \(perLookup * 1_000_000) us (\(lineCount) lines)")
    }

    /// The process's memory footprint in bytes, for the number above.
    private static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
