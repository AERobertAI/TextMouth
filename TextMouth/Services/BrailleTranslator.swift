import Foundation
import os
#if os(iOS)
// The braille translation, which the iPhone app links and calls in its own
// process (DR34); the Mac app links none of it.
import TextMouthBrailleLibrary
#endif

/// Translates paragraphs between print and braille through liblouis (FMT21).
///
/// liblouis is C that reads untrusted text and braille, it has had
/// memory-safety bugs, and it is not thread-safe, so the Mac app never calls
/// it in its own process. On the Mac this type is the only caller of the
/// helper that does, `TextMouthBraille` (`TextMouthBraille/main.c` around the
/// translation in `TextMouthBraille/TextMouthBrailleLibrary.c`): it writes the
/// paragraphs to a hidden file, runs the helper on it under the watchdog
/// (`WatchedProcess`, with a time limit, a memory limit, an output cap, and
/// an import's Cancel), and reads the translations back. A hang or a crash in
/// liblouis costs one run of the helper, never the app or the import. This is
/// the arrangement `TextutilConverter` makes for textutil.
///
/// iOS lets an app start no helper program, so the iPhone calls the same
/// translation in its own process (DR34): the same records, in batches,
/// through `InProcessEngine`, one call at a time on a thread of its own, with
/// the bundled tables only, and with the watchdog's limits as nearly as one
/// process allows (`LibraryBatches`). Both platforms read a book alike, since
/// the C and the Swift around it are the same. iOS 26's own
/// `AXBrailleTranslator` is not used: liblouis gives the iPhone the Mac's own
/// results, the reading passes and the EBAE fixes included.
///
/// Braille, in and out, is Unicode braille patterns (`BrailleCells`), with
/// the blank cell U+2800 between words and never an ASCII space.
///
/// Each paragraph travels with the emphasis of each of its characters
/// (protocol 2, October 21, 2026, defined once for both sides in
/// `TextMouthBraille/include/TextMouthBrailleProtocol.h`): print sent
/// forward carries the book's italic and bold, which liblouis writes as the
/// table's indicators, and print read back carries the emphasis liblouis
/// found in the braille's indicators (`EmphasizedText`, `BrailleEmphasis`).
/// Callers that need only the words use the `[String]` form, which sends
/// none and drops what comes back.
enum BrailleTranslator {
    // MARK: Direction

    /// Which way a translation goes. The raw values are the helper's own
    /// mode arguments.
    enum Direction: String, Sendable {
        /// Print text to braille cells.
        case printToBraille = "forward"
        /// Braille cells to print text.
        case brailleToPrint = "back"

        /// The scalar that separates words in this direction's input: a
        /// space in print, the blank cell in braille.
        fileprivate var inputBreak: Unicode.Scalar {
            self == .printToBraille ? " " : BrailleCells.blank
        }

        /// The scalar that separates words in this direction's output: the
        /// blank cell in braille, a space in print.
        fileprivate var outputBreak: Unicode.Scalar {
            self == .printToBraille ? BrailleCells.blank : " "
        }
    }

    // MARK: Failures

    /// Why a translation could not be made; each sentence is read to the
    /// listener after the import's own ("Could not import “book.brf”.
    /// Reading its text failed: "), so none names the file.
    enum Failure: LocalizedError, Equatable {
        /// TextMouth has no braille table of this name.
        case unknownTable(String)
        /// The watchdog stopped the helper, for this reason in words
        /// (`WatchedProcess.KillReason.words`).
        case stopped(reason: String)
        /// The helper could not translate: it is missing, could not start,
        /// failed, or wrote something other than one line for each piece.
        case failed
        /// One of this Mac's tables could not be checked before its use, for
        /// the reason `why` gives (`MacBrailleTableCheck`, review R7). The
        /// table is not refused: the next use checks it again.
        case uncheckedTable(String, why: String)
        /// A book was read with one of this Mac's tables under liblouis
        /// `then`, and the Mac's tables now have version `now` (nil when they
        /// name none): reading the book again could move its text, so it is
        /// refused (review R2, decision 8).
        case changedTable(String, then: String, now: String?)

        var errorDescription: String? {
            switch self {
            // A table's name is liblouis's or macOS's own, and a liblouis
            // version is a version identifier: neither is translated.
            case let .unknownTable(name):
                // Translators: Why a braille translation was refused: no braille table has this name. %@ is the table's name as liblouis or macOS gives it.
                return InterfaceText.line("failure.unknownTable", "TextMouth has no braille table named \u{201C}\(name)\u{201D}.")
            case let .stopped(reason):
                // Translators: Why a braille translation ended. %@ is the reason, a clause such as "an earlier call was abandoned", which stays English until the engine's sentences convert.
                return InterfaceText.line("failure.stopped.translation", "TextMouth stopped the braille translation because \(reason).")
            case .failed:
                // Translators: Why a braille translation failed, when no more is known.
                return InterfaceText.line("failure.failed", "TextMouth could not translate this braille.")
            case let .uncheckedTable(name, why):
                // Translators: Why a braille translation was refused: one of this Mac's braille tables could not be checked. %1$@ is the table's name as macOS gives it and %2$@ the reason, which stays English.
                return InterfaceText.line("failure.uncheckedTable", "TextMouth could not check this Mac's braille table \u{201C}\(name)\u{201D}: \(why). Try again.")
            #if os(iOS)
            case let .changedTable(name, then, now):
                // Translators: Why a book is not read with its braille table again on an iPhone: the table's liblouis version is not the one the book was read with. %1$@ is the table's name, %2$@ the liblouis version on this iPhone, and %3$@ the version the book was read with.
                return InterfaceText.line("failure.changedTable.phoneBraille", "The braille table \u{201C}\(name)\u{201D} on this iPhone is liblouis \(now ?? BrailleTableCatalog.bundledLiblouisVersion), not liblouis \(then) as when the book was read, so TextMouth keeps the book's text as it was.")
            #else
            case let .changedTable(name, then, now?):
                // Translators: Why a book is not read with its braille table again: the table changed. %1$@ is the table's name as macOS gives it, %2$@ the liblouis version the book was read with, and %3$@ the version now.
                return InterfaceText.line("failure.changedTable.brailleLiblouisSince", "This Mac's braille table \u{201C}\(name)\u{201D} changed from liblouis \(then) to \(now) since the book was read, so TextMouth keeps the book's text as it was.")
            case let .changedTable(name, then, nil):
                // Translators: Why a book is not read with its braille table again: the table may have changed. %1$@ is the table's name as macOS gives it and %2$@ the liblouis version the book was read with.
                return InterfaceText.line("failure.changedTable.brailleSinceLiblouis", "This Mac's braille table \u{201C}\(name)\u{201D} may have changed since liblouis \(then) read the book, so TextMouth keeps the book's text as it was.")
            #endif
            }
        }
    }

    // MARK: The Tool

    /// The clock the tool times its runs by unless a test scripts its own
    /// (`Tool.clock`): on the iPhone the app's, which counts only the time
    /// TextMouth runs (B18), as the engine it translates on is timed; on the
    /// Mac the system's uptime, counted whole.
    #if os(iOS)
    static let toolClock = RunningClock.app
    #else
    static let toolClock = RunningClock.system
    #endif

    /// What runs a translation, and what watches it: the bundled helper in
    /// the app, replaced in tests by a stand-in child (a `sleep`, `false`)
    /// and tight limits.
    struct Tool: Sendable {
        /// The executable and arguments of a run in `mode` ("forward",
        /// "back", or "check") on `table`, a stored value
        /// (`BrailleTableSource`), reading `input` and writing `output` (both
        /// nil for "check"); nil when the helper or the table's folder is
        /// missing.
        /// - Throws: `Failure.unknownTable` for a bundled table that cannot be
        ///   unpacked from the app's pack (`BrailleTableUnpacker`).
        var command: @Sendable (_ mode: String, _ table: String, _ input: URL?, _ output: URL?) throws
            -> (executable: URL, arguments: [String])?
        /// What the watchdog allows a run in `direction` (nil for "check")
        /// on an input of the given size in bytes.
        var limits: @Sendable (Direction?, Int64) -> WatchedProcess.Limits
        /// How the watchdog reads the child's resident memory.
        var residentMemory: @Sendable (pid_t) -> Int64?
        /// The folder of braille tables a run of `table`, a stored value
        /// (`BrailleTableSource`), reads, with the table and every file it
        /// includes in it, nil for a tool that has none. For a bundled table
        /// the app unpacks the table and its includes from its pack into the
        /// Caches folder first (`BrailleTableUnpacker`, FR40); for one of this
        /// Mac's it is the Mac's own folder.
        /// - Throws: `Failure.unknownTable` for a bundled table that cannot be
        ///   unpacked from the app's pack.
        var tablesFolder: @Sendable (_ table: String) throws -> URL?
        /// The clock a measured run and the library's own time are timed by,
        /// which never runs backwards, unless a test scripts its own (review
        /// F8): on the iPhone the app's, which counts only the time TextMouth
        /// runs, so a translation frozen while iOS keeps the app suspended has
        /// spent none of its book's time (B18); on the Mac the system's uptime.
        var clock: RunningClock = BrailleTranslator.toolClock

        /// The folder `table`, a stored value, is read from in the app: this
        /// Mac's own folder for one of its tables, else the app's unpacked
        /// folder with the table and everything it includes in it
        /// (`BrailleTableUnpacker.app`, FR40). The stored value names the
        /// table's folder (decision 6): a table is loaded from inside its
        /// folder by its bare file name, and a run reads one folder, never
        /// both, so a table's includes come from its own liblouis version.
        /// - Throws: `Failure.unknownTable` when the bundled table cannot be
        ///   unpacked: the app has no pack, or a blob of it is damaged (the
        ///   unpacker has logged why, once).
        private static func appTablesFolder(for table: String) throws -> URL? {
            #if os(macOS)
            // A Mac's own table, and a bare value the app's pack lacks that VoiceOver has (`readsFromMacFolder`): read from
            // VoiceOver's folder. Only a Mac has one: a simulator sees the host's folder at its own path, and the iPhone reads
            // its pack alone.
            if BrailleTableCatalog.readsFromMacFolder(table) { return BrailleTableCatalog.macTablesFolder }
            #endif
            guard let unpacker = BrailleTableUnpacker.app else { throw Failure.unknownTable(table) }
            let fileName = BrailleTableSource.parse(table).fileName
            do {
                return try unpacker.unpackedFolder(for: fileName)
            } catch {
                throw Failure.unknownTable(table)
            }
        }

        /// The helper built into the app: `Contents/MacOS/TextMouthBraille`,
        /// reading the bundled tables unpacked from the app's pack and this
        /// Mac's in its own folder (`BrailleTableCatalog.macTablesFolder`).
        static let helper: Tool = {
            let executable = Bundle.main.url(forAuxiliaryExecutable: "TextMouthBraille")
            return Tool(
                command: { mode, table, input, output in
                    guard let executable, let folder = try appTablesFolder(for: table) else { return nil }
                    // The helper's usage: `mode tables table [input output]`.
                    let files = [input, output].compactMap { $0?.path }
                    return (executable, [mode, folder.path, BrailleTableSource.parse(table).fileName] + files)
                },
                limits: { BrailleTranslator.limits(for: $0, bytes: $1) },
                residentMemory: { WatchedProcess.residentMemory(of: $0) },
                tablesFolder: { try appTablesFolder(for: $0) }
            )
        }()
    }

    /// The tool translations use: the bundled helper, unless a test binds a
    /// stand-in with `BrailleTranslator.$tool.withValue(_:operation:)`. It is
    /// read on the caller's thread, as `TextutilConverter.tool` is: a
    /// detached task does not inherit it.
    @TaskLocal static var tool: Tool = .helper

    // MARK: Measuring

    /// The measure of the runs one of this Mac's tables makes in its check
    /// (`MacBrailleTableCheck`, review R1). Each measured run keeps the
    /// tool's time limits, but may hold memory up to `memoryCeiling`, and
    /// the watchdog reads the child's memory every `pollInterval` so that a
    /// run of a fraction of a second is measured too. The measure keeps the
    /// most resident memory any reading saw, how long the last run took, and
    /// why the watchdog stopped a run, if it did. The watchdog reads memory
    /// on its own thread, so the readings are kept behind a lock.
    final class RunMeasure: Sendable {
        /// The most resident memory a measured run may hold, in bytes.
        let memoryCeiling: Int64
        /// How often the watchdog reads a measured run's memory, in seconds.
        let pollInterval: TimeInterval

        /// The readings so far.
        private struct Readings: Sendable {
            var peakResidentBytes: Int64 = 0
            var lastRunSeconds: TimeInterval = 0
            var stop: WatchedProcess.KillReason?
        }
        private let readings = OSAllocatedUnfairLock(initialState: Readings())

        /// A measure allowing `memoryCeiling` bytes, reading every
        /// `pollInterval` seconds.
        init(memoryCeiling: Int64, pollInterval: TimeInterval) {
            self.memoryCeiling = memoryCeiling
            self.pollInterval = pollInterval
        }

        /// The most resident memory any reading of any run saw, in bytes.
        var peakResidentBytes: Int64 { readings.withLock { $0.peakResidentBytes } }
        /// How long the last measured run took, in seconds, start to end.
        var lastRunSeconds: TimeInterval { readings.withLock { $0.lastRunSeconds } }
        /// Why the watchdog stopped a measured run, if it stopped one.
        var stop: WatchedProcess.KillReason? { readings.withLock { $0.stop } }

        /// `limits` as a measured run gets them: memory up to the ceiling,
        /// and read every `pollInterval` (or more often, if they say so).
        fileprivate func measuring(_ limits: WatchedProcess.Limits) -> WatchedProcess.Limits {
            var measured = limits
            measured.maximumResidentBytes = memoryCeiling
            measured.pollInterval = min(limits.pollInterval, pollInterval)
            return measured
        }

        fileprivate func note(memory bytes: Int64?) {
            guard let bytes else { return }
            readings.withLock { $0.peakResidentBytes = max($0.peakResidentBytes, bytes) }
        }

        fileprivate func note(seconds: TimeInterval) {
            readings.withLock { $0.lastRunSeconds = seconds }
        }

        fileprivate func note(stop reason: WatchedProcess.KillReason) {
            readings.withLock { $0.stop = reason }
        }
    }

    // MARK: Limits

    /// What the watchdog allows the helper, from the lead's measurements of
    /// October 19, 2026 (Release build, Apple silicon):
    ///
    /// - 10 MB of braille back to print with en-ueb-g2.ctb took 0.54 second
    ///   and 3.5 MB resident;
    /// - 10 MB of print to Grade 2 took 15.3 seconds and 3.7 MB resident,
    ///   its output 2.3 times its input;
    /// - a table's check took a few hundredths of a second.
    ///
    /// The allowance is about four times that, and 10 seconds more for
    /// starting and compiling the table on a busy Mac: back, a quarter
    /// second for each MB; forward, six seconds for each MB; a check, the 10
    /// seconds alone. The stall allowance equals the time allowance, since a
    /// short input's output is written only at the end.
    ///
    /// The output cap (review finding L3) follows how far liblouis's output
    /// can outgrow its input. Back to print and the check stay at 10 times
    /// the input plus 1 MiB. Forward is 32 times plus 1 MiB: a character a
    /// table lacks is written as an escape of several cells of 3 bytes each,
    /// which for Cyrillic is 11 times the input's bytes in all four tables
    /// and for control characters 24 times, above the old 10 times.
    ///
    /// These were measured with the bundled English tables. One of this
    /// Mac's tables may need more, so its runs get these raised to fit what
    /// its check measured, and never lowered (`MacBrailleTableCheck
    /// .limits(for:raising:direction:bytes:)`, review R1).
    static func limits(for direction: Direction?, bytes: Int64) -> WatchedProcess.Limits {
        let megabytes = Double(bytes) / 1_000_000
        let seconds: TimeInterval
        switch direction {
        case .brailleToPrint: seconds = 10 + megabytes / 4
        case .printToBraille: seconds = 10 + 6 * megabytes
        case nil: seconds = 10
        }
        return WatchedProcess.Limits(
            maximumSeconds: seconds,
            maximumResidentBytes: 16 * 1_048_576,
            maximumStalledSeconds: seconds,
            maximumOutputBytes: (direction == .printToBraille ? 32 : 10) * bytes + 1_048_576
        )
    }

    // MARK: Translating

    /// The most scalars one piece sent to the helper holds: a long text is
    /// split into pieces of at most this many.
    static let maximumPieceScalars = 4_000

    /// The suffixes of the hidden files the helper reads, writes, and is
    /// watched through, each after ".<UUID>". Named once, so a leftover can
    /// be found by them.
    static let inputSuffix = ".braille-in.txt"
    static let outputSuffix = ".braille-out.txt"
    static let checkSuffix = ".braille-check"

    /// The translation of each of `texts`, in order, without emphasis: the
    /// words alone, for the callers that need nothing else. See
    /// `translate(_:table:direction:workingIn:)` for `EmphasizedText`, which
    /// this is.
    static func translate(
        _ texts: [String],
        table: String,
        direction: Direction,
        workingIn folder: URL
    ) throws -> [String] {
        try translate(texts, table: table, direction: direction, workingIn: folder, checksMacTable: true)
    }

    /// The translation of each of `texts`, in order, with its emphasis.
    /// Synchronous, for the import and the cache, which run off the main
    /// thread. `folder` holds the hidden files the helper reads and writes,
    /// which are removed however this ends.
    ///
    /// Print sent forward gives liblouis each character's emphasis, and the
    /// braille that comes back holds it as the table's indicators, with no
    /// emphasis of its own. Braille sent back comes back as print with the
    /// emphasis read from the indicators. UEB braille with a terminator the
    /// helper reads a second time without its terminators, so that the
    /// contraction before one reads as the word it is ("people", not "p"),
    /// keeping the emphasis of the first reading; EBAE's signs, which
    /// liblouis misreads, the helper reads itself where it can tell them
    /// from print, keeping the words liblouis reads (October 24, 2026).
    /// Forward carries only the classes liblouis reads back exactly with
    /// this table (`check_readable` in `TextMouthBraille/TextMouthBrailleLibrary.c`): UEB's,
    /// not EBAE's italic and bold, nor most of this Mac's tables', so with
    /// them an export is plain and read back keeps its words (review E2,
    /// October 21, 2026).
    ///
    /// Line breaks inside a text become one space (print) or blank cell
    /// (braille), and NUL characters are removed, with their emphasis. A
    /// long text is split at its word breaks into pieces
    /// (`pieces(of:direction:)`) and translated piece by piece; no UEB or
    /// EBAE contraction spans a blank cell, so a cut there changes no
    /// translation. An emphasized passage that spans a cut is written as two
    /// passages, each with its own indicators. Read back, liblouis reads each
    /// piece on its own, so where braille is cut inside a passage, the
    /// passage's words after the cut come back plain; only a paragraph of
    /// more than `maximumPieceScalars` cells is cut at all.
    ///
    /// One of this Mac's tables is used only once its check passes, made
    /// before its first use in the session (`MacBrailleTableCheck`,
    /// decision 5); a table that fails it, or is gone, is refused by name, as
    /// an unknown table is. A call with no work checks nothing.
    /// - Parameters:
    ///   - table: The stored value of one of the tables TextMouth offers
    ///     (`BrailleTableCatalog`), such as "en-ueb-g2.ctb" or
    ///     "mac:fr-bfu-g2.ctb".
    ///   - direction: Which way to translate.
    /// - Throws: `Failure`, `ImportCancelled` when the import is cancelled
    ///   meanwhile, and `CancellationError` for any other cancelled task.
    static func translate(
        _ texts: [EmphasizedText],
        table: String,
        direction: Direction,
        workingIn folder: URL
    ) throws -> [EmphasizedText] {
        try translate(texts, table: table, direction: direction, workingIn: folder, checksMacTable: true)
    }

    /// `translate(_:table:direction:workingIn:)` of words alone, checking
    /// one of this Mac's tables first unless `checksMacTable` is false: only
    /// the check's own runs pass false (`MacBrailleTableCheck.check`), which
    /// would otherwise check themselves forever, and they pass a `measure`
    /// too, which the helper's run is measured by (review R1).
    static func translate(
        _ texts: [String],
        table: String,
        direction: Direction,
        workingIn folder: URL,
        checksMacTable: Bool,
        measure: RunMeasure? = nil
    ) throws -> [String] {
        try translate(
            texts.map { EmphasizedText($0) }, table: table, direction: direction, workingIn: folder,
            checksMacTable: checksMacTable, measure: measure
        ).map(\.text)
    }

    /// `translate(_:table:direction:workingIn:)`, checking one of this Mac's
    /// tables first unless `checksMacTable` is false, and measured by
    /// `measure`, as the `[String]` form says.
    static func translate(
        _ texts: [EmphasizedText],
        table: String,
        direction: Direction,
        workingIn folder: URL,
        checksMacTable: Bool,
        measure: RunMeasure? = nil
    ) throws -> [EmphasizedText] {
        try requireOfferedTable(table)
        #if os(iOS)
        // The iPhone translates in its own process, with no files (DR34).
        return try translateInProcess(texts, table: table, direction: direction)
        #else
        let id = UUID().uuidString
        let input = folder.appendingPathComponent(".\(id)\(inputSuffix)")
        let output = folder.appendingPathComponent(".\(id)\(outputSuffix)")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }

        // Cut each text into pieces and write them to the input file as they
        // are made, one record per piece (`InputWriter`). Only how many
        // pieces each text has, and which end at a word break, is kept:
        // joining the output needs no more. The texts' pieces are never all
        // in memory at once, nor joined into one string or copied into a
        // whole-input `Data` (review finding E5: a 32 MB book's translation
        // peaked at 431 MB that way).
        var writer = InputWriter(at: input)
        let layout: PieceLayout
        do {
            layout = try layOut(texts, direction: direction) { try writer.append($0) }
            try writer.finish()
        } catch {
            throw logged(.failed, direction.rawValue, table, "could not write the input: \(error.localizedDescription)")
        }
        // No work, no run: an empty list, or only empty texts, has no pieces.
        guard layout.pieceCount > 0 else { return texts.map { _ in EmphasizedText() } }

        // One of this Mac's tables runs only once its check has passed.
        if checksMacTable { try MacBrailleTableCheck.requireUsable(table, workingIn: folder) }

        try runHelper(
            mode: direction.rawValue, table: table, input: input, output: output,
            watching: output, inputBytes: writer.bytesWritten, direction: direction, measure: measure
        )

        // The output has one record for each piece, in order.
        let translated = try outputRecords(of: output, expecting: layout.pieceCount, mode: direction.rawValue, table: table)
        return joined(translated, layout: layout, direction: direction)
        #endif
    }

    /// Cuts each of `texts` into its pieces (`pieces(of:direction:)`) and
    /// hands each piece to `take`, in order, as it is made, so that the
    /// pieces are never all in memory at once; returns what joining their
    /// translations needs.
    private static func layOut(
        _ texts: [EmphasizedText],
        direction: Direction,
        into take: (Piece) throws -> Void
    ) rethrows -> PieceLayout {
        var layout = PieceLayout()
        for text in texts {
            let made = pieces(of: text, direction: direction)
            for piece in made { try take(piece) }
            layout.add(made)
        }
        return layout
    }

    /// The translation of each text, from `translated`, the translations of
    /// every text's pieces in order, laid out as `layout` says. Between two
    /// pieces cut at a word break, the break is back, with the emphasis both
    /// its neighbours have, so that a passage cut there reads as one.
    private static func joined(
        _ translated: [EmphasizedText],
        layout: PieceLayout,
        direction: Direction
    ) -> [EmphasizedText] {
        // The index of the next piece, in `translated` and in the layout.
        var next = 0
        return layout.counts.map { count in
            var result = EmphasizedText()
            for index in 0..<count {
                result.append(translated[next])
                if index < count - 1, layout.endsAtBreak[next] {
                    let shared = translated[next].lastEmphasis.intersection(translated[next + 1].firstEmphasis)
                    result.append(direction.outputBreak, shared)
                }
                next += 1
            }
            return result
        }
    }

    /// Checks that the helper can load `table`, with every table it
    /// includes, by running its "check" mode, measured by `measure` when
    /// one of this Mac's tables is checked (review R1).
    /// - Throws: `Failure.unknownTable` for a table that is not there or
    ///   does not compile, as `translate` does, and its other failures.
    static func check(table: String, workingIn folder: URL, measure: RunMeasure? = nil) throws {
        try requireOfferedTable(table)
        #if os(iOS)
        // The library loads the table in this process and translates nothing,
        // within the tool's time for a check, as the Mac's helper does.
        let bundled = try requireBundledTable(table)
        _ = try runLibrary(direction: nil, table: bundled, input: Data(), seconds: tool.limits(nil, 0).maximumSeconds)
        #else
        // The watchdog needs a file to watch; a check writes none, so an
        // empty one stands in.
        let watched = folder.appendingPathComponent(".\(UUID().uuidString)\(checkSuffix)")
        defer { try? FileManager.default.removeItem(at: watched) }
        guard FileManager.default.createFile(atPath: watched.path, contents: nil) else {
            throw logged(.failed, "check", table, "could not make the watched file")
        }
        try runHelper(
            mode: "check", table: table, input: nil, output: nil,
            watching: watched, inputBytes: 0, direction: nil, measure: measure
        )
        #endif
    }

    // MARK: Pieces

    /// One piece of a text, as sent to the helper.
    struct Piece: Equatable {
        /// The piece's text: no line break, and no break at its ends that
        /// the cut dropped.
        var text: String
        /// The emphasis of each Unicode scalar of `text`, in order; empty
        /// when none has any, as most pieces have.
        var emphasis: [BrailleEmphasis] = []
        /// Whether the cut was at a word break, which it dropped; the
        /// translations of this piece and the next are joined by a break.
        /// False for a piece cut in the middle of a word, and for the last.
        var endsAtBreak: Bool
    }

    /// What joining the output needs to know of every text's pieces
    /// (FMT21, review finding E5): how many pieces each text has, and, for
    /// every piece of every text in order, whether it ends at a word break.
    /// Two flat arrays, with no array of its own for each text.
    private struct PieceLayout {
        /// How many pieces each text has.
        private(set) var counts: [Int] = []
        /// For each piece of each text, in order, `Piece.endsAtBreak`.
        private(set) var endsAtBreak: [Bool] = []

        /// The number of pieces in all.
        var pieceCount: Int { endsAtBreak.count }

        /// Records the pieces of the next text.
        mutating func add(_ pieces: [Piece]) {
            counts.append(pieces.count)
            endsAtBreak.append(contentsOf: pieces.lazy.map(\.endsAtBreak))
        }
    }

    /// The protocol's header line, with its line feed, which every input and
    /// every output begins with (`TextMouthBrailleProtocol.h`).
    private static let headerLine = Data((BrailleEmphasis.protocolHeader + "\n").utf8)

    /// Appends the record of `piece` to `data`, in the helper's protocol:
    /// its text on one line, then the code of each of its scalars' emphasis
    /// (`BrailleEmphasis.code`) on the next, or an empty line for a piece
    /// with none. No piece holds a line feed, and no code is one. The Mac's
    /// input file and the iPhone's batches hold the same records.
    private static func appendRecord(of piece: Piece, to data: inout Data) {
        data.append(contentsOf: piece.text.utf8)
        data.append(0x0A)
        data.append(contentsOf: piece.emphasis.lazy.map(\.code))
        data.append(0x0A)
    }

    /// Writes the helper's input file one piece at a time, through a buffer
    /// of about `bufferBytes`, so that the input is never held whole
    /// (FMT21, review finding E5). The file is made when the first piece
    /// arrives, so an input with no pieces makes none.
    ///
    /// The file is in the helper's protocol (`TextMouthBrailleProtocol.h`):
    /// the header line, then a record for each piece, its text on one line
    /// and the code of each scalar's emphasis on the next (`BrailleEmphasis
    /// .code`), or an empty line for a piece with none. No piece holds a
    /// line feed, and no code is one.
    private struct InputWriter {
        /// About how many bytes wait in memory before they are written.
        static let bufferBytes = 1_048_576

        private let url: URL
        private var handle: FileHandle?
        /// The bytes not yet written.
        private var buffer = Data()
        /// The bytes already written to the file.
        private var written: Int64 = 0
        /// Whether the header has been put in the buffer: before the first
        /// piece, so that an input with no pieces stays unwritten.
        private var hasHeader = false

        init(at url: URL) {
            self.url = url
        }

        /// How many bytes the input holds so far, written or waiting.
        var bytesWritten: Int64 { written + Int64(buffer.count) }

        /// Adds the record of `piece`: its text and its codes, each with its
        /// line feed, after the header when it is the first.
        /// - Throws: The file system's error for a file that cannot be made or written.
        mutating func append(_ piece: Piece) throws {
            if !hasHeader {
                buffer.append(BrailleTranslator.headerLine)
                hasHeader = true
            }
            BrailleTranslator.appendRecord(of: piece, to: &buffer)
            if buffer.count >= Self.bufferBytes { try flush() }
        }

        /// Writes what waits and closes the file.
        mutating func finish() throws {
            try flush()
            try handle?.close()
            handle = nil
        }

        /// Writes the waiting bytes to the file, which it makes first if it
        /// is not yet made.
        private mutating func flush() throws {
            guard !buffer.isEmpty else { return }
            if handle == nil {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
                }
                handle = try FileHandle(forWritingTo: url)
            }
            try handle?.write(contentsOf: buffer)
            written += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
        }
    }

    /// The pieces `text` is sent in, for `direction`, with no emphasis: see
    /// `pieces(of:direction:)` for `EmphasizedText`, which this is.
    static func pieces(of text: String, direction: Direction) -> [Piece] {
        pieces(of: EmphasizedText(text), direction: direction)
    }

    /// The pieces `text` is sent in, for `direction`: its line breaks made
    /// word breaks and its NULs removed (`prepared(_:direction:)`), then cut
    /// into pieces of at most `maximumPieceScalars` scalars, each at the last
    /// word break within that length, the break dropped. A piece with no
    /// break in its first `maximumPieceScalars` scalars is cut at that
    /// length, mid-word. An empty text has no pieces. Each piece keeps the
    /// emphasis of its own scalars, or none when they have none.
    static func pieces(of text: EmphasizedText, direction: Direction) -> [Piece] {
        let (scalars, emphasis) = prepared(text, direction: direction)
        let wordBreak = direction.inputBreak
        var pieces: [Piece] = []
        var start = 0
        // The piece of `scalars[range]`, with their emphasis when any has some.
        func piece(_ range: Range<Int>, endsAtBreak: Bool) -> Piece {
            let flags = emphasis.isEmpty ? [] : emphasis[range]
            return Piece(
                text: string(scalars[range]),
                emphasis: flags.contains { !$0.isEmpty } ? Array(flags) : [],
                endsAtBreak: endsAtBreak
            )
        }
        while start < scalars.count {
            // The rest fits in one piece.
            if scalars.count - start <= maximumPieceScalars {
                pieces.append(piece(start..<scalars.count, endsAtBreak: false))
                break
            }
            // Look back from the longest cut for a word break. One at the
            // piece's very start would make an empty piece, so it is not
            // looked for: the cut is then mid-word.
            let limit = start + maximumPieceScalars
            var cut = limit
            while cut > start, scalars[cut] != wordBreak { cut -= 1 }
            if cut > start {
                pieces.append(piece(start..<cut, endsAtBreak: true))
                start = cut + 1  // the break itself is dropped
            } else {
                pieces.append(piece(start..<limit, endsAtBreak: false))
                start = limit
            }
        }
        return pieces
    }

    /// `text`'s scalars as the helper takes them, with no emphasis: see
    /// `prepared(_:direction:)` for `EmphasizedText`, which this is.
    static func prepared(_ text: String, direction: Direction) -> [Unicode.Scalar] {
        prepared(EmphasizedText(text), direction: direction).scalars
    }

    /// `text`'s scalars as the helper takes them: every line break (CR LF as
    /// one, CR, LF, U+0085, U+2028, U+2029) one word break, NUL removed, and
    /// in braille an ASCII space the blank cell too. `emphasis` keeps each
    /// remaining scalar's emphasis in step (a break takes its line break's;
    /// a CR LF's, its CR's), or is empty when the text has none.
    static func prepared(
        _ text: EmphasizedText,
        direction: Direction
    ) -> (scalars: [Unicode.Scalar], emphasis: [BrailleEmphasis]) {
        var scalars: [Unicode.Scalar] = []
        var emphasis: [BrailleEmphasis] = []
        scalars.reserveCapacity(text.text.unicodeScalars.count)
        if text.hasEmphasis { emphasis.reserveCapacity(text.emphasis.count) }
        var previousWasCR = false
        for (index, scalar) in text.text.unicodeScalars.enumerated() {
            let isCR = scalar == "\r"
            defer { previousWasCR = isCR }
            let kept: Unicode.Scalar
            switch scalar.value {
            case 0:
                continue
            case 0x0A where previousWasCR:
                continue  // the LF of a CR LF: one break, already added
            case 0x0A, 0x0D, 0x85, 0x2028, 0x2029:
                kept = direction.inputBreak
            case 0x20 where direction == .brailleToPrint:
                kept = BrailleCells.blank
            default:
                kept = scalar
            }
            scalars.append(kept)
            if text.hasEmphasis { emphasis.append(text.emphasis[index]) }
        }
        return (scalars, emphasis)
    }

    /// The string of `scalars`.
    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(scalars))
    }

    /// Throws `Failure.unknownTable` unless `table` is one of the tables
    /// TextMouth offers (`BrailleTableCatalog`), before anything starts.
    /// That is the whole list of names the helper may be given, from either
    /// source (decision 6): a record could be edited to name any other file
    /// of a tables folder, such as an include file (`spaces.uti`), which
    /// liblouis would load and the book would read as its escapes. A name
    /// the catalog lacks is also never a path ("../x"), a list ("a,b"), or
    /// empty. The stored name is never changed: a library from a newer
    /// TextMouth, with more tables, keeps its books' tables, and such a book
    /// is refused by name, as is a book of one of this Mac's tables once a
    /// macOS update has removed it.
    private static func requireOfferedTable(_ table: String) throws {
        guard BrailleTableCatalog.table(withID: table) != nil else { throw Failure.unknownTable(table) }
    }

    // MARK: In This Process (the iPhone)

    #if os(iOS)
    /// The engine the iPhone's braille translations run on (DR34): liblouis
    /// and TextMouth's translation around it, called in the app one at a
    /// time on a thread of their own, since iOS lets an app start no helper
    /// program. A call past its time is abandoned, and every later
    /// translation is refused until TextMouth is closed and opened again, in
    /// the engine's sentences (`InProcessEngineWording`).
    static let libraryEngine = InProcessEngine(name: "liblouis", work: "the braille translation") // l10n: no (a fragment inside InProcessEngineWording's English sentences until that area converts)

    /// The engine translations run on: `libraryEngine`, unless a test binds
    /// one of its own with `$engine.withValue(_:operation:)`, so that a test
    /// that abandons a call refuses no other test's translations. It is read
    /// on the caller's thread, as `tool` is.
    @TaskLocal static var engine: InProcessEngine = libraryEngine

    /// Whether braille is read back by liblouis alone, without TextMouth's
    /// reading passes (the library's `back-liblouis`), which only tests ask
    /// for, to show what a pass changes: the iPhone's counterpart of the
    /// Mac's helper run in that mode by a test's stand-in `Tool`. Read on the
    /// caller's thread, as `engine` is.
    @TaskLocal static var readsByLiblouisAlone = false

    /// About how many bytes of records one call of the library is sent: a
    /// quarter of a MiB, so that a call holds little more than its batch and
    /// its output, which may grow at most to the Mac's cap on that batch (32
    /// times it and 1 MiB forward, 9 MiB in all), within the 16 MB the Mac's
    /// watchdog lets its helper hold.
    static let batchBytes = 262_144

    /// The bundled table `table`, a stored value, names, by its bare file
    /// name: its own for a bundled value, and for a Mac's `mac:<file>` the
    /// pack's table of the same file name when the pack has one (FR40).
    /// - Throws: `Failure.unknownTable` unless the pack has the table: the
    ///   iPhone reads no other, so nothing a person supplies is ever read as
    ///   a table, and a Mac's own tables the pack lacks stay the Mac's.
    private static func requireBundledTable(_ table: String) throws -> String {
        guard let bundled = BrailleTableCatalog.bundledID(forStored: table) else { throw Failure.unknownTable(table) }
        return bundled
    }

    /// `translate(_:table:direction:workingIn:checksMacTable:measure:)` on
    /// the iPhone: the Mac's pieces and records, sent to the library in this
    /// process in batches (`LibraryBatches`) and joined as the Mac joins
    /// them. An empty list, or only empty texts, calls nothing.
    private static func translateInProcess(
        _ texts: [EmphasizedText],
        table: String,
        direction: Direction
    ) throws -> [EmphasizedText] {
        let bundled = try requireBundledTable(table)
        var batches = LibraryBatches(table: bundled, direction: direction)
        let layout = try layOut(texts, direction: direction) { try batches.append($0) }
        guard layout.pieceCount > 0 else { return texts.map { _ in EmphasizedText() } }
        return joined(try batches.finish(), layout: layout, direction: direction)
    }

    /// The records of one translation, sent to the library in this process
    /// in batches of about `batchBytes`, each one call of the engine with
    /// the protocol's header of its own, and the translations of their
    /// records, in order (DR34).
    ///
    /// Its limits are the tool's (`BrailleTranslator.tool`, read once, on the
    /// caller's thread, as `runHelper` reads it), which in the app are the
    /// Mac's watchdog's (`limits(for:bytes:)`), kept as nearly as one process
    /// allows; a test binds a stand-in tool with tight ones:
    /// - **A record** holds at most `maximumPieceScalars` characters, as
    ///   every piece does; the library refuses a longer one (status 4).
    /// - **The output** of a batch may grow at most to the Mac's cap on the
    ///   batch's own input, which the library checks after each record
    ///   (status 9), and the whole translation's to the Mac's cap on its
    ///   whole input.
    /// - **The time** the library takes, over all the batches, is what the
    ///   Mac allows its helper for the input sent so far: each call is told to
    ///   stop once that is spent, and the engine abandons one that has not
    ///   returned its grace later.
    /// - **The memory** of a call is its batch, about `batchBytes`, and its
    ///   output, at most its cap, where the Mac's helper may hold 16 MB.
    private struct LibraryBatches {
        let table: String
        let direction: Direction
        /// The tool's limits for a run in a direction on so many bytes.
        private let limits: @Sendable (Direction?, Int64) -> WatchedProcess.Limits
        /// The records of the batch being made, with no header.
        private var batch = Data()
        /// How many records `batch` holds.
        private var batchRecords = 0
        /// The bytes of the whole translation's input so far, as the Mac's
        /// input file would hold them: the header once, then every record.
        private var inputBytes = Int64(BrailleTranslator.headerLine.count)
        /// The bytes of its output so far, counted the same way.
        private var outputBytes = Int64(BrailleTranslator.headerLine.count)
        /// The seconds the library has taken so far, over all the batches.
        private var librarySeconds: TimeInterval = 0
        /// The translations of the records sent so far, in order.
        private var translated: [EmphasizedText] = []

        /// The batches of a translation in `direction` with `table`, within
        /// the limits of the tool in force on the caller's thread.
        init(table: String, direction: Direction) {
            self.table = table
            self.direction = direction
            self.limits = BrailleTranslator.tool.limits
        }

        /// Adds the record of `piece`, and sends the batch once it holds
        /// `batchBytes` or more.
        mutating func append(_ piece: Piece) throws {
            BrailleTranslator.appendRecord(of: piece, to: &batch)
            batchRecords += 1
            if batch.count >= BrailleTranslator.batchBytes { try send() }
        }

        /// Sends what is left, and returns every record's translation, in
        /// order.
        mutating func finish() throws -> [EmphasizedText] {
            try send()
            return translated
        }

        /// Sends the batch being made, when it holds a record, within the
        /// limits the type's comment gives, and keeps its translations.
        private mutating func send() throws {
            guard batchRecords > 0 else { return }
            let mode = direction.rawValue
            inputBytes += Int64(batch.count)
            // The limits for the whole input so far.
            let soFar = limits(direction, inputBytes)
            var input = BrailleTranslator.headerLine
            input.append(batch)
            let (output, seconds) = try BrailleTranslator.runLibrary(
                direction: direction, table: table, input: input,
                seconds: max(0, soFar.maximumSeconds - librarySeconds),
                maximumOutputBytes: limits(direction, Int64(input.count)).maximumOutputBytes ?? 0,
                timeAllowed: soFar.maximumSeconds
            )
            librarySeconds += seconds
            // Every batch's output begins with the header, which the Mac's
            // output file holds once.
            outputBytes += Int64(output.count - BrailleTranslator.headerLine.count)
            if let cap = soFar.maximumOutputBytes, outputBytes > cap {
                throw BrailleTranslator.stopped(.wroteTooMuch(bytes: cap), mode, table)
            }
            translated += try BrailleTranslator.outputRecords(in: output, expecting: batchRecords, mode: mode, table: table)
            batch.removeAll(keepingCapacity: true)
            batchRecords = 0
        }
    }

    /// What one call of the library gave: its status, and its output when
    /// done.
    private struct LibraryOutcome: Sendable {
        let status: Int32
        let output: Data
        /// How long the library took, on the engine's thread: its own time,
        /// with no wait behind another call in it.
        var seconds: TimeInterval = 0
    }

    /// One call of the braille library in this process, on the engine: the
    /// mode of `direction` (a check for nil) on `table`, a bundled table,
    /// with `input` in the protocol, told to stop after `seconds`, and with an
    /// output of at most `maximumOutputBytes` (0 for no cap). `timeAllowed`
    /// is the whole translation's time, which a stop for time names.
    /// - Returns: The output, when the library is done, and the seconds
    ///   the library took, on the engine's thread.
    /// - Throws: `Failure.unknownTable` for a table that does not load;
    ///   `Failure.stopped` past the time or a cap; `ImportCancelled` after the
    ///   import's Cancel; `Failure.failed` for any other status; and the
    ///   engine's own failures for a call abandoned past its time, or refused
    ///   after one was.
    private static func runLibrary(
        direction: Direction?,
        table: String,
        input: Data,
        seconds: TimeInterval,
        maximumOutputBytes: Int64 = 0,
        timeAllowed: TimeInterval? = nil
    ) throws -> (output: Data, seconds: TimeInterval) {
        do {
            return try runLibraryOnce(
                direction: direction, table: table, input: input, seconds: seconds,
                maximumOutputBytes: maximumOutputBytes, timeAllowed: timeAllowed
            )
        } catch let failure as Failure where failure == .unknownTable(table) && BrailleTableSource.parse(table).source == .bundled
            && ((try? BrailleTranslator.tool.tablesFolder(table)) ?? nil) != nil {
            // iOS may clear the Caches folder between the unpacker's look at a table's files and liblouis's open of
            // them: the table is unpacked again (asking the tool for its folder does it), once, before it is called
            // unknown. A tool with no folder, a test's stand-in, is not asked twice.
            return try runLibraryOnce(
                direction: direction, table: table, input: input, seconds: seconds,
                maximumOutputBytes: maximumOutputBytes, timeAllowed: timeAllowed
            )
        }
    }

    /// One try of `runLibrary`.
    private static func runLibraryOnce(
        direction: Direction?,
        table: String,
        input: Data,
        seconds: TimeInterval,
        maximumOutputBytes: Int64,
        timeAllowed: TimeInterval?
    ) throws -> (output: Data, seconds: TimeInterval) {
        let mode = direction?.rawValue ?? "check"
        // The engine, the tool, and the import's cancellation are read here,
        // on the caller's thread: the engine's thread inherits no
        // task-locals.
        let engine = BrailleTranslator.engine
        let tool = BrailleTranslator.tool
        let cancellation = ImportCancellation.current
        // The tool's tables: in the app, the table and what it includes,
        // unpacked from the app's pack (`Tool.helper`, FR40).
        guard let folder = try tool.tablesFolder(table)?.path else {
            throw logged(.failed, mode, table, "the bundled tables are missing")
        }
        let libraryMode: UInt32
        switch direction {
        case .printToBraille: libraryMode = TMB_MODE_FORWARD.rawValue
        case .brailleToPrint: libraryMode = (readsByLiblouisAlone ? TMB_MODE_BACK_LIBLOUIS : TMB_MODE_BACK).rawValue
        case nil: libraryMode = TMB_MODE_CHECK.rawValue
        }
        let outcome: LibraryOutcome
        do {
            // The library's own time, by the tool's clock, on the engine's
            // thread, so that no wait behind another call is in it.
            let clock = tool.clock
            outcome = try engine.run(limit: seconds, cancelledBy: cancellation) { call in
                let started = clock.now()
                var result = callLibrary(
                    mode: libraryMode, folder: folder, table: table, input: input,
                    maximumOutputBytes: maximumOutputBytes, call: call
                )
                result.seconds = clock.now() - started
                return result
            }
        } catch let failure as InProcessEngine.Failure {
            let what = failure == .refused(work: engine.work)
                ? "refused, as an earlier call was abandoned" : "abandoned past its time" // l10n: no (a debug log reason, which stays English)
            DiagnosticLog.event(.import, "BRAILLE_HELPER_FAILED: \(mode) \(table): the call was \(what)")
            throw failure
        }
        switch Int(outcome.status) {
        case Int(TMB_EXIT_DONE):
            return (outcome.output, outcome.seconds)
        case Int(TMB_EXIT_TABLE):
            throw Failure.unknownTable(table)
        case Int(TMB_EXIT_STOPPED):
            // Told to stop: by the import's Cancel, which ends the import as a
            // cancelled one ends, or by the time the translation was allowed.
            if cancellation?.isCancelled == true { throw ImportCancelled() }
            throw stopped(.tookTooLong(seconds: timeAllowed ?? seconds), mode, table)
        case Int(TMB_EXIT_OUTPUT_CAP):
            throw stopped(.wroteTooMuch(bytes: maximumOutputBytes), mode, table)
        default:
            throw logged(.failed, mode, table, "the library ended with status \(outcome.status)")
        }
    }

    /// Calls `tmb_translate` once, on the engine's thread: the request with
    /// its limits (at most `maximumPieceScalars` characters a record, the
    /// output cap, and the call's stop check), and the output it gives, taken
    /// over without a copy and freed with the `Data`.
    private static func callLibrary(
        mode: UInt32,
        folder: String,
        table: String,
        input: Data,
        maximumOutputBytes: Int64,
        call: InProcessEngine.Call
    ) -> LibraryOutcome {
        folder.withCString { folder in
            table.withCString { table in
                input.withUnsafeBytes { bytes in
                    var request = tmb_request()
                    request.mode = tmb_mode(rawValue: mode)
                    request.tables_folder = folder
                    request.table = table
                    request.input = bytes.baseAddress
                    request.input_length = bytes.count
                    request.limits.max_record_chars = maximumPieceScalars
                    request.limits.max_output_bytes = Int(clamping: maximumOutputBytes)
                    request.limits.should_stop = InProcessEngine.Call.stopCheck
                    request.limits.context = call.context
                    var response = tmb_response()
                    tmb_translate(&request, &response)
                    let output = response.output.map {
                        Data(bytesNoCopy: $0, count: response.output_length, deallocator: .free)
                    } ?? Data()
                    return LibraryOutcome(status: response.status, output: output)
                }
            }
        }
    }
    #endif

    // MARK: Running

    /// Runs the helper in `mode` on `table` under the watchdog, and returns
    /// when it exits with status 0.
    /// - Parameters:
    ///   - watching: The file the watchdog watches for growth.
    ///   - inputBytes: The input's size, which sets the limits.
    ///   - direction: The direction, nil for "check".
    ///   - measure: The measure of a Mac table's check, which this run is
    ///     measured by and runs under (review R1); nil for any other run,
    ///     which gets the tool's limits raised by the needs its table's
    ///     check measured (`MacBrailleTableCheck.limits(for:raising:direction:bytes:)`).
    /// - Throws: `Failure`, and `ImportCancelled` when the import's Cancel
    ///   killed the child.
    private static func runHelper(
        mode: String,
        table: String,
        input: URL?,
        output: URL?,
        watching: URL,
        inputBytes: Int64,
        direction: Direction?,
        measure: RunMeasure?
    ) throws {
        do {
            try runHelperOnce(
                mode: mode, table: table, input: input, output: output, watching: watching,
                inputBytes: inputBytes, direction: direction, measure: measure
            )
        } catch let failure as Failure where failure == .unknownTable(table) && BrailleTableSource.parse(table).source == .bundled
            && !BrailleTableCatalog.readsFromMacFolder(table) && ((try? BrailleTranslator.tool.tablesFolder(table)) ?? nil) != nil {
            // A table file that vanished between the unpacker's look and the helper's open (the system may clear the
            // Caches folder at any time) is unpacked again, once, before the table is called unknown.
            try runHelperOnce(
                mode: mode, table: table, input: input, output: output, watching: watching,
                inputBytes: inputBytes, direction: direction, measure: measure
            )
        }
    }

    /// One try of `runHelper`.
    private static func runHelperOnce(
        mode: String,
        table: String,
        input: URL?,
        output: URL?,
        watching: URL,
        inputBytes: Int64,
        direction: Direction?,
        measure: RunMeasure?
    ) throws {
        // The tool, the import's cancellation, and the verdicts that set a
        // Mac table's limits are read here, on the caller's thread: the
        // detached task below inherits no task-locals.
        let tool = BrailleTranslator.tool
        let cancellation = ImportCancellation.current
        guard let command = try tool.command(mode, table, input, output) else {
            throw logged(.failed, mode, table, "the helper is missing")
        }
        let toolLimits = tool.limits(direction, inputBytes)
        let limits = measure?.measuring(toolLimits)
            ?? MacBrailleTableCheck.limits(for: table, raising: toolLimits, direction: direction, bytes: inputBytes)
        // A measured run's memory readings are kept as they are made.
        let residentMemory: @Sendable (pid_t) -> Int64? = { pid in
            let bytes = tool.residentMemory(pid)
            measure?.note(memory: bytes)
            return bytes
        }
        let started = tool.clock.now()
        let outcome: WatchedProcess.Outcome
        do {
            outcome = try AsyncBridge.waitForResult(cancelledBy: cancellation) {
                try await WatchedProcess.run(
                    command.executable,
                    arguments: command.arguments,
                    watching: watching,
                    limits: limits,
                    residentMemory: residentMemory
                )
            }
        } catch is CancellationError where cancellation?.isCancelled == true {
            // The reader cancelled the import: the child is gone, and the
            // import ends as a cancelled one does.
            throw ImportCancelled()
        }
        measure?.note(seconds: tool.clock.now() - started)

        switch outcome {
        case .exited(status: 0):
            return
        case .exited(status: 2):
            // The helper could not load the table.
            throw Failure.unknownTable(table)
        case let .exited(status):
            throw logged(.failed, mode, table, "exited with status \(status)")
        case .couldNotStart:
            throw logged(.failed, mode, table, "could not start")
        case let .killed(reason):
            measure?.note(stop: reason)
            throw stopped(reason, mode, table)
        }
    }

    /// The records of the helper's output at `output`, which must begin with
    /// the protocol's header and hold `count` records: one for each piece
    /// sent, its text and its emphasis codes (`InputWriter` writes the same
    /// form). Invalid UTF-8 becomes U+FFFD. An output of another protocol,
    /// of the wrong length, or with codes that do not fit their text is a
    /// failure, never read as far as it goes.
    private static func outputRecords(
        of output: URL,
        expecting count: Int,
        mode: String,
        table: String
    ) throws -> [EmphasizedText] {
        let data: Data
        do {
            data = try Data(contentsOf: output)
        } catch {
            throw logged(.failed, mode, table, "wrote no output")
        }
        return try outputRecords(in: data, expecting: count, mode: mode, table: table)
    }

    /// The records of an output in the protocol, `data`, as
    /// `outputRecords(of:expecting:mode:table:)` reads a file of the
    /// helper's: the header, then `count` records, or a failure.
    private static func outputRecords(
        in data: Data,
        expecting count: Int,
        mode: String,
        table: String
    ) throws -> [EmphasizedText] {
        // Split at line feed bytes (a CR LF is not a line end of the helper's
        // own), and drop the empty string after the last line feed.
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard let header = lines.first, String(decoding: header, as: UTF8.self) == BrailleEmphasis.protocolHeader else {
            throw logged(.failed, mode, table, "wrote no protocol header")
        }
        guard lines.count == 1 + 2 * count else {
            throw logged(.failed, mode, table, "wrote \(lines.count - 1) lines for \(count) pieces")
        }
        var records: [EmphasizedText] = []
        records.reserveCapacity(count)
        for index in 0..<count {
            let text = String(decoding: lines[1 + 2 * index], as: UTF8.self)
            guard let record = record(text, codes: lines[2 + 2 * index]) else {
                throw logged(.failed, mode, table, "wrote codes that do not fit their text")
            }
            records.append(record)
        }
        return records
    }

    /// `text` with the emphasis its code line `codes` gives, one code for
    /// each of its scalars, or no emphasis for an empty line; nil when a
    /// byte is no code or the codes do not number the scalars.
    private static func record(_ text: String, codes: Data.SubSequence) -> EmphasizedText? {
        guard !codes.isEmpty else { return EmphasizedText(text) }
        var emphasis: [BrailleEmphasis] = []
        emphasis.reserveCapacity(codes.count)
        for byte in codes {
            guard let flags = BrailleEmphasis(code: byte) else { return nil }
            emphasis.append(flags)
        }
        return EmphasizedText(text, emphasis: emphasis)
    }

    /// `failure`, after writing one import event for it. The line names the
    /// mode, the table, and what happened, and never any book text.
    private static func logged(_ failure: Failure, _ mode: String, _ table: String, _ what: String) -> Failure {
        DiagnosticLog.event(.import, "BRAILLE_HELPER_FAILED: \(mode) \(table): \(what)")
        return failure
    }

    /// The failure of a translation stopped for `reason`, by the Mac's
    /// watchdog or by the iPhone's own limits, after writing one import
    /// event for it, which names the mode, the table, and the reason.
    private static func stopped(_ reason: WatchedProcess.KillReason, _ mode: String, _ table: String) -> Failure {
        DiagnosticLog.event(.import, "BRAILLE_HELPER_KILLED: \(mode) \(table): \(reason.words)")
        return Failure.stopped(reason: reason.words)
    }
}
