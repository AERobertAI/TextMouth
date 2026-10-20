import Foundation

/// Translates paragraphs between print and braille through liblouis (FMT21).
///
/// liblouis is C that reads untrusted text and braille, it has had
/// memory-safety bugs, and it is not thread-safe, so TextMouth never calls it
/// in its own process. This type is the only caller of the helper that does,
/// `TextMouthBraille` (`TextMouthBraille/main.c`): it writes the paragraphs
/// to a hidden file, runs the helper on it under the watchdog
/// (`WatchedProcess`, with a time limit, a memory limit, an output cap, and
/// an import's Cancel), and reads the translations back. A hang or a crash in
/// liblouis costs one run of the helper, never the app or the import. This is
/// the arrangement `TextutilConverter` makes for textutil.
///
/// Braille, in and out, is Unicode braille patterns (`BrailleCells`), with
/// the blank cell U+2800 between words and never an ASCII space.
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

        var errorDescription: String? {
            switch self {
            case let .unknownTable(name):
                return "TextMouth has no braille table named \u{201C}\(name)\u{201D}."
            case let .stopped(reason):
                return "TextMouth stopped the braille translation because \(reason)."
            case .failed:
                return "TextMouth could not translate this braille."
            }
        }
    }

    // MARK: The Tool

    /// What runs a translation, and what watches it: the bundled helper in
    /// the app, replaced in tests by a stand-in child (a `sleep`, `false`)
    /// and tight limits.
    struct Tool: Sendable {
        /// The executable and arguments of a run in `mode` ("forward",
        /// "back", or "check") on `table`, reading `input` and writing
        /// `output` (both nil for "check"); nil when the helper is missing.
        var command: @Sendable (_ mode: String, _ table: String, _ input: URL?, _ output: URL?)
            -> (executable: URL, arguments: [String])?
        /// What the watchdog allows a run in `direction` (nil for "check")
        /// on an input of the given size in bytes.
        var limits: @Sendable (Direction?, Int64) -> WatchedProcess.Limits
        /// How the watchdog reads the child's resident memory.
        var residentMemory: @Sendable (pid_t) -> Int64?
        /// The folder of braille tables the helper reads, nil when the
        /// bundle lacks it.
        var tablesFolder: URL?

        /// The helper built into the app: `Contents/MacOS/TextMouthBraille`,
        /// reading the tables in `Contents/Resources/liblouis/tables`.
        static let helper: Tool = {
            let executable = Bundle.main.url(forAuxiliaryExecutable: "TextMouthBraille")
            let tables = Bundle.main.resourceURL?.appendingPathComponent("liblouis/tables", isDirectory: true)
            return Tool(
                command: { mode, table, input, output in
                    guard let executable, let tables else { return nil }
                    // The helper's usage: `mode tables table [input output]`.
                    let files = [input, output].compactMap { $0?.path }
                    return (executable, [mode, tables.path, table] + files)
                },
                limits: { BrailleTranslator.limits(for: $0, bytes: $1) },
                residentMemory: { WatchedProcess.residentMemory(of: $0) },
                tablesFolder: tables
            )
        }()
    }

    /// The tool translations use: the bundled helper, unless a test binds a
    /// stand-in with `BrailleTranslator.$tool.withValue(_:operation:)`. It is
    /// read on the caller's thread, as `TextutilConverter.tool` is: a
    /// detached task does not inherit it.
    @TaskLocal static var tool: Tool = .helper

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
            maximumOutputBytes: 10 * bytes + 1_048_576
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

    /// The translation of each of `texts`, in order. Synchronous, for the
    /// import and the cache, which run off the main thread. `folder` holds
    /// the hidden files the helper reads and writes, which are removed
    /// however this ends.
    ///
    /// Line breaks inside a text become one space (print) or blank cell
    /// (braille), and NUL characters are removed. A long text is split at
    /// its word breaks into pieces (`pieces(of:direction:)`) and translated
    /// piece by piece; no UEB or EBAE contraction spans a blank cell, so a
    /// cut there changes no translation.
    /// - Parameters:
    ///   - table: A bare file name of a table in the tables folder.
    ///   - direction: Which way to translate.
    /// - Throws: `Failure`, `ImportCancelled` when the import is cancelled
    ///   meanwhile, and `CancellationError` for any other cancelled task.
    static func translate(
        _ texts: [String],
        table: String,
        direction: Direction,
        workingIn folder: URL
    ) throws -> [String] {
        guard isBareTableName(table) else { throw Failure.unknownTable(table) }
        // Split every text into pieces, and number the pieces in the order
        // they go to the helper, one line each.
        let split = texts.map { pieces(of: $0, direction: direction) }
        let lines = split.flatMap { $0.map(\.text) }
        // No work, no run: an empty list, or only empty texts, has no pieces.
        guard !lines.isEmpty else { return texts.map { _ in "" } }

        let id = UUID().uuidString
        let input = folder.appendingPathComponent(".\(id)\(inputSuffix)")
        let output = folder.appendingPathComponent(".\(id)\(outputSuffix)")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }

        // One piece per line, each ending in a line feed (no piece holds one).
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        do {
            try data.write(to: input)
        } catch {
            throw logged(.failed, direction.rawValue, table, "could not write the input: \(error.localizedDescription)")
        }

        try runHelper(
            mode: direction.rawValue, table: table, input: input, output: output,
            watching: output, inputBytes: Int64(data.count), direction: direction
        )

        // The output has one line for each piece, in order.
        let translated = try outputLines(of: output, expecting: lines.count, mode: direction.rawValue, table: table)
        var next = translated.startIndex
        return split.map { pieces in
            var result = ""
            for (index, piece) in pieces.enumerated() {
                result += translated[next]
                next += 1
                // Between two pieces, the word break the cut dropped is back.
                if index < pieces.count - 1, piece.endsAtBreak { result.unicodeScalars.append(direction.outputBreak) }
            }
            return result
        }
    }

    /// Checks that the helper can load `table`, with every table it
    /// includes, by running its "check" mode.
    /// - Throws: `Failure.unknownTable` for a table that is not there or
    ///   does not compile, as `translate` does, and its other failures.
    static func check(table: String, workingIn folder: URL) throws {
        guard isBareTableName(table) else { throw Failure.unknownTable(table) }
        // The watchdog needs a file to watch; a check writes none, so an
        // empty one stands in.
        let watched = folder.appendingPathComponent(".\(UUID().uuidString)\(checkSuffix)")
        defer { try? FileManager.default.removeItem(at: watched) }
        guard FileManager.default.createFile(atPath: watched.path, contents: nil) else {
            throw logged(.failed, "check", table, "could not make the watched file")
        }
        try runHelper(
            mode: "check", table: table, input: nil, output: nil,
            watching: watched, inputBytes: 0, direction: nil
        )
    }

    // MARK: Pieces

    /// One piece of a text, as sent to the helper.
    struct Piece: Equatable {
        /// The piece's text: no line break, and no break at its ends that
        /// the cut dropped.
        var text: String
        /// Whether the cut was at a word break, which it dropped; the
        /// translations of this piece and the next are joined by a break.
        /// False for a piece cut in the middle of a word, and for the last.
        var endsAtBreak: Bool
    }

    /// The pieces `text` is sent in, for `direction`: its line breaks made
    /// word breaks and its NULs removed (`prepared(_:direction:)`), then cut
    /// into pieces of at most `maximumPieceScalars` scalars, each at the last
    /// word break within that length, the break dropped. A piece with no
    /// break in its first `maximumPieceScalars` scalars is cut at that
    /// length, mid-word. An empty text has no pieces.
    static func pieces(of text: String, direction: Direction) -> [Piece] {
        let scalars = prepared(text, direction: direction)
        let wordBreak = direction.inputBreak
        var pieces: [Piece] = []
        var start = 0
        while start < scalars.count {
            // The rest fits in one piece.
            if scalars.count - start <= maximumPieceScalars {
                pieces.append(Piece(text: string(scalars[start...]), endsAtBreak: false))
                break
            }
            // Look back from the longest cut for a word break. One at the
            // piece's very start would make an empty piece, so it is not
            // looked for: the cut is then mid-word.
            let limit = start + maximumPieceScalars
            var cut = limit
            while cut > start, scalars[cut] != wordBreak { cut -= 1 }
            if cut > start {
                pieces.append(Piece(text: string(scalars[start..<cut]), endsAtBreak: true))
                start = cut + 1  // the break itself is dropped
            } else {
                pieces.append(Piece(text: string(scalars[start..<limit]), endsAtBreak: false))
                start = limit
            }
        }
        return pieces
    }

    /// `text`'s scalars as the helper takes them: every line break (CR LF as
    /// one, CR, LF, U+0085, U+2028, U+2029) one word break, NUL removed, and
    /// in braille an ASCII space the blank cell too.
    static func prepared(_ text: String, direction: Direction) -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(text.unicodeScalars.count)
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            let isCR = scalar == "\r"
            defer { previousWasCR = isCR }
            switch scalar.value {
            case 0:
                continue
            case 0x0A where previousWasCR:
                continue  // the LF of a CR LF: one break, already added
            case 0x0A, 0x0D, 0x85, 0x2028, 0x2029:
                result.append(direction.inputBreak)
            case 0x20 where direction == .brailleToPrint:
                result.append(BrailleCells.blank)
            default:
                result.append(scalar)
            }
        }
        return result
    }

    /// The string of `scalars`.
    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(scalars))
    }

    /// Whether `table` is a bare file name: not empty, no "/", not starting
    /// with ".", no "," (liblouis separates a list of tables with it), and
    /// no NUL. Anything else names no table of the tables folder.
    static func isBareTableName(_ table: String) -> Bool {
        !table.isEmpty && !table.hasPrefix(".") && !table.unicodeScalars.contains { $0 == "/" || $0 == "," || $0 == "\0" }
    }

    // MARK: Running

    /// Runs the helper in `mode` on `table` under the watchdog, and returns
    /// when it exits with status 0.
    /// - Parameters:
    ///   - watching: The file the watchdog watches for growth.
    ///   - inputBytes: The input's size, which sets the limits.
    ///   - direction: The direction, nil for "check".
    /// - Throws: `Failure`, and `ImportCancelled` when the import's Cancel
    ///   killed the child.
    private static func runHelper(
        mode: String,
        table: String,
        input: URL?,
        output: URL?,
        watching: URL,
        inputBytes: Int64,
        direction: Direction?
    ) throws {
        // The tool and the import's cancellation are read here, on the
        // caller's thread: the detached task below inherits no task-locals.
        let tool = BrailleTranslator.tool
        let cancellation = ImportCancellation.current
        guard let command = tool.command(mode, table, input, output) else {
            throw logged(.failed, mode, table, "the helper is missing")
        }
        let limits = tool.limits(direction, inputBytes)
        let outcome: WatchedProcess.Outcome
        do {
            outcome = try AsyncBridge.waitForResult(cancelledBy: cancellation) {
                try await WatchedProcess.run(
                    command.executable,
                    arguments: command.arguments,
                    watching: watching,
                    limits: limits,
                    residentMemory: tool.residentMemory
                )
            }
        } catch is CancellationError where cancellation?.isCancelled == true {
            // The reader cancelled the import: the child is gone, and the
            // import ends as a cancelled one does.
            throw ImportCancelled()
        }

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
            DiagnosticLog.event(.import, "BRAILLE_HELPER_KILLED: \(mode) \(table): \(reason.words)")
            throw Failure.stopped(reason: reason.words)
        }
    }

    /// The lines of the helper's output at `output`, which must number
    /// `count`: one for each piece sent. Invalid UTF-8 becomes U+FFFD.
    private static func outputLines(of output: URL, expecting count: Int, mode: String, table: String) throws -> [String] {
        let data: Data
        do {
            data = try Data(contentsOf: output)
        } catch {
            throw logged(.failed, mode, table, "wrote no output")
        }
        // Split at line feed bytes (a CR LF is not a line end of the helper's
        // own), and drop the empty string after the last line feed.
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.count == count else {
            throw logged(.failed, mode, table, "wrote \(lines.count) lines for \(count) pieces")
        }
        return lines.map { String(decoding: $0, as: UTF8.self) }
    }

    /// `failure`, after writing one import event for it. The line names the
    /// mode, the table, and what happened, and never any book text.
    private static func logged(_ failure: Failure, _ mode: String, _ table: String, _ what: String) -> Failure {
        DiagnosticLog.event(.import, "BRAILLE_HELPER_FAILED: \(mode) \(table): \(what)")
        return failure
    }
}
