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
        ids = lines.keys.sorted()
        let names = Set(lines.values.flatMap { $0.keys })
        languages = Dictionary(uniqueKeysWithValues: names.map { name in (name, ids.map { lines[$0]?[name] ?? "" }) })
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
    engine.text(id: id, english: english, language: language, locale: InterfaceLanguage.locale(forTesting: language))
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
    }

    var magic = Array("TMSP".utf8)
    var version: UInt16 = 1
    var flags: UInt16 = 0
    var idCount: Int
    var blobs: [Blob]

    /// A blob of `entries` joined and compressed with LZMA, each entry ended by a NUL, stating the true sizes.
    static func blob(_ name: String, entries: [String], terminator: UInt8 = 0) -> Blob {
        var raw: [UInt8] = []
        for entry in entries { raw += Array(entry.utf8) + [terminator] }
        return Blob(name: name, compressed: compress(raw), rawSize: raw.count, count: entries.count, offset: nil)
    }

    /// A blob of exactly these raw bytes, compressed.
    static func blob(_ name: String, raw: [UInt8], count: Int) -> Blob {
        Blob(name: name, compressed: compress(raw), rawSize: raw.count, count: count, offset: nil)
    }

    /// `raw` compressed with Apple's LZMA, the algorithm the reader decodes.
    static func compress(_ raw: [UInt8]) -> [UInt8] {
        guard !raw.isEmpty else { return [] }
        var output = [UInt8](repeating: 0, count: raw.count + 4096)
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
        var offset = 48 + blobs.count * 28
        for blob in blobs {
            let name = Array(blob.name.utf8)
            directory += name + [UInt8](repeating: 0, count: 12 - name.count)
            directory += le(UInt32(blob.offset ?? offset)) + le(UInt32(blob.compressed.count)) + le(UInt32(blob.rawSize)) + le(UInt32(blob.count))
            body += blob.compressed
            offset += blob.compressed.count
        }
        header += directory + body
        return Data(header)
    }

    /// A good pack of three IDs: English with one plural line, and Spanish.
    static func sample() -> InterfaceTextPackBytes {
        InterfaceTextPackBytes(idCount: 3, blobs: [
            blob("ids", entries: ["greeting.hello", "library.books", "library.title"]),
            blob("en", entries: ["", pluralEntry("%lld book", "%lld books"), ""]),
            blob("es", entries: ["Hola", pluralEntry("%lld libro", "%lld libros"), "Biblioteca"]),
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

    /// A plural line of English reads the pack's English forms when their `other` is the call's format; else the call's
    /// format serves every count.
    func testEnglishPluralFormsComeFromThePackWhenTheyMatch() {
        let log = InterfaceTextReportLog()
        let engine = makeInterfaceTextEngine(["common.books": ["en": pluralEntry("%lld book", "%lld books")]], log: log)
        XCTAssertEqual(interfaceLine(engine, "common.books", "\(number: 1) books", language: "en"), "1 book")
        XCTAssertEqual(interfaceLine(engine, "common.books", "\(number: 2) books", language: "en"), "2 books")
        XCTAssertEqual(interfaceLine(engine, "common.books", "\(number: 1) volumes", language: "en"), "1 volumes", "the code was reworded")
        XCTAssertEqual(log.messages, [])
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
            "common.books": ["es": pluralEntry("Un libro", "%lld libros", "%lld libros")],
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

    /// Many threads at once, under a time limit.
    func testConcurrentLookups() {
        let log = InterfaceTextReportLog()
        let engine = makeInterfaceTextEngine([
            "common.books": ["es": pluralEntry("%lld libro", "%lld libros", "%lld libros"), "ru": pluralEntry("%lld книга", "%lld книги", "%lld книг", "%lld книги")],
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
        let state = InterfaceLanguage.systemState(isHostedTest: true, preferredLocalizations: ["es"], currentLocale: Locale(identifier: "es_ES"))
        XCTAssertEqual(state.language, "en")
        XCTAssertEqual(state.locale.identifier, "en_US")
        // And this process, which hosts the tests, uses it.
        XCTAssertTrue(TextMouthRuntime.current.isHostedTest)
        XCTAssertEqual(InterfaceLanguage.current.language, "en")
    }

    func testSystemInTheAppFollowsThePreferredLocalization() {
        let locale = Locale(identifier: "es_US")
        let state = InterfaceLanguage.systemState(isHostedTest: false, preferredLocalizations: ["es", "en"], currentLocale: locale)
        XCTAssertEqual(state, InterfaceLanguage.State(language: "es", locale: locale))
        XCTAssertEqual(InterfaceLanguage.systemState(isHostedTest: false, preferredLocalizations: [], currentLocale: locale).language, "en")
    }

    func testATestLanguageIsBoundForOneScopeOnly() {
        XCTAssertEqual(InterfaceLanguage.current.language, "en")
        InterfaceLanguage.$testLanguage.withValue("ru") {
            XCTAssertEqual(InterfaceLanguage.current.language, "ru")
            XCTAssertEqual(InterfaceLanguage.current.locale.identifier, "ru_US")
        }
        XCTAssertEqual(InterfaceLanguage.current.language, "en")
    }

    func testTheLocaleOfATestLanguage() {
        XCTAssertEqual(InterfaceLanguage.locale(forTesting: "es").identifier, "es_US")
        XCTAssertEqual(InterfaceLanguage.locale(forTesting: "pt-BR").identifier, "pt_US")
        XCTAssertEqual(InterfaceLanguage.locale(forTesting: "zh-Hans").language.languageCode?.identifier, "zh")
        XCTAssertEqual(InterfaceLanguage.locale(forTesting: "fa").numberingSystem.identifier, "latn")
    }

    /// The call a view makes: no pack ships yet, so every line shows the call's English in every language.
    func testTheCallShowsEnglishWhileNoPackShips() {
        let count = 3
        XCTAssertEqual(InterfaceText.line("interfaceTextTests.sample", "Count: \(number: count), 100%"), "Count: 3, 100%")
        XCTAssertEqual(InterfaceText.line("interfaceTextTests.sample", "Count: \(number: count), 100%", language: "es"), "Count: 3, 100%")
        InterfaceLanguage.$testLanguage.withValue("ru") {
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
        XCTAssertEqual(try pack.entries(language: "es"), [.plain("Hola"), .plural(["%lld libro", "%lld libros"]), .plain("Biblioteca")])
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
        refused("version 2") { $0.version = 2 }
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

    /// A blob whose bytes are not an LZMA stream.
    func testGarbageInPlaceOfALanguageBlobGivesEnglish() throws {
        var bytes = InterfaceTextPackBytes.sample()
        bytes.blobs[2] = InterfaceTextPackBytes.Blob(name: "es", compressed: Array(repeating: 0x5A, count: 64), rawSize: 100, count: 3, offset: nil)
        let log = InterfaceTextReportLog()
        let engine = InterfaceTextEngine(tables: try InterfaceTextPack(data: bytes.data()), report: log.sink)
        for _ in 0..<3 { XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello"), "Hello") }
        XCTAssertEqual(log.messages.count, 1)
    }

    /// A blob cut short, a raw size too large or too small, a wrong entry count, bad UTF-8, a missing terminator: each
    /// fails the blob and the lookup shows English, with one report.
    func testDamagedLanguageBlobsGiveEnglish() throws {
        let spanish = ["Hola", pluralEntry("%lld libro", "%lld libros"), "Biblioteca"]
        var cases: [(String, InterfaceTextPackBytes.Blob)] = []
        let good = InterfaceTextPackBytes.blob("es", entries: spanish)
        var cut = good; cut.compressed = Array(good.compressed.prefix(good.compressed.count / 2)); cases.append(("cut", cut))
        var longer = good; longer.rawSize += 5; cases.append(("raw size too large", longer))
        var shorter = good; shorter.rawSize -= 5; cases.append(("raw size too small", shorter))
        var shortCount = good; shortCount.count = 2; cases.append(("count in the directory", shortCount))
        var twoEntries = InterfaceTextPackBytes.blob("es", entries: Array(spanish.prefix(2))); twoEntries.count = 3
        cases.append(("two entries under a directory that says three", twoEntries))
        var fourEntries = InterfaceTextPackBytes.blob("es", entries: spanish + ["extra"]); fourEntries.count = 3
        cases.append(("four entries under a directory that says three", fourEntries))
        cases.append(("no last terminator", InterfaceTextPackBytes.blob("es", raw: Array("Hola\0".utf8) + Array("x\0".utf8) + Array("Biblioteca".utf8), count: 3)))
        cases.append(("bad UTF-8", InterfaceTextPackBytes.blob("es", raw: [0x48, 0xFF, 0, 0x78, 0, 0x79, 0], count: 3)))
        cases.append(("overlong UTF-8", InterfaceTextPackBytes.blob("es", raw: [0xC0, 0xAF, 0, 0x78, 0, 0x79, 0], count: 3)))
        cases.append(("surrogate", InterfaceTextPackBytes.blob("es", raw: [0xED, 0xA0, 0x80, 0, 0x78, 0, 0x79, 0], count: 3)))
        cases.append(("a plural of the wrong size", InterfaceTextPackBytes.blob("es", entries: ["Hola", pluralEntry("a", "b", "c"), "x"])))
        for (name, blob) in cases {
            var bytes = InterfaceTextPackBytes.sample()
            bytes.blobs[2] = blob
            let log = InterfaceTextReportLog()
            guard let pack = try? InterfaceTextPack(data: bytes.data()) else { continue }
            let engine = InterfaceTextEngine(tables: pack, report: log.sink)
            for _ in 0..<3 { XCTAssertEqual(interfaceLine(engine, "greeting.hello", "Hello"), "Hello", name) }
            XCTAssertEqual(log.messages.count, 1, "\(name): \(log.messages)")
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
