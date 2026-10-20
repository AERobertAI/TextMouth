import Foundation
import os

/// Checks one of this Mac's VoiceOver braille tables before TextMouth uses it
/// (October 20, 2026, decision 5).
///
/// The Mac's tables are written for its own liblouis (3.34.0 on macOS 26.3),
/// and TextMouth's helper runs its own (`BrailleTableCatalog
/// .bundledLiblouisVersion`), so a table VoiceOver loads may not load in
/// TextMouth: on macOS 26.3 the Greek tables use uppercase virtual dots,
/// which liblouis 3.39.0 refuses, and the Portuguese `pt.tbl` includes a
/// table the Mac's folder lacks. A table whose metadata gives no `dots` may
/// write eight-dot cells, which TextMouth's six-dot files cannot hold
/// (decision 3). And a table may need far more of the helper than the
/// bundled English tables, for which its limits were set: the Mac's
/// Hungarian table holds 28 MB once compiled, and its contracted table reads
/// braille at 7.6 seconds a megabyte (review R1). So before a Mac table is
/// used, the helper loads it (its "check" mode), translates `timingLines`
/// lines of `sample` with it, and reads their braille back, each run
/// measured by the watchdog; the table is used only when all succeed, the
/// sample's cells are six-dot (`writesSixDotsOnly(_:)`) for a table that
/// gives no dots line, and its needs stay under the ceilings
/// (`memoryCeilingBytes`, `secondsPerMBCeiling`). Its runs then get limits
/// raised to fit those needs (`limits(for:raising:direction:bytes:)`).
///
/// The check runs when a Mac table is chosen, in the Braille tab or in
/// Export's braille options (`BrailleTablePickers`), off the main thread, and
/// nothing else waits for it. An import or an export checks too, before a
/// Mac table's first use (`BrailleTranslator.translate`), so that a table
/// named in config.json, or one a macOS update changed or removed, is
/// refused by name, as an unknown table is. Verdicts last the session
/// (`Verdicts`).
///
/// The bundled tables are TextMouth's own, tested with its own liblouis, and
/// are never checked here.
enum MacBrailleTableCheck {
    // MARK: Verdicts

    /// Why one of this Mac's tables cannot be used.
    enum Refusal: Equatable, Sendable {
        /// This Mac no longer offers the table: its folder or its file is
        /// gone, or its metadata no longer offers it.
        case gone
        /// TextMouth's liblouis cannot load it (the helper's status 2).
        case doesNotLoad
        /// Its translation of the sample holds eight-dot cells.
        case writesEightDots
        /// It needs more memory than `memoryCeilingBytes` (review R1).
        case needsTooMuchMemory
        /// It translates more slowly than `secondsPerMBCeiling` either way,
        /// or a run of its check passed the helper's time limit (review R1).
        case tooSlow
        /// The check could not be made, for the reason `why` gives in words
        /// (review R7): the helper is missing, failed, or was stopped, or no
        /// working folder could be made. It says nothing of the table, so it
        /// is not kept for the session, and the next choice or import checks
        /// again.
        case couldNotCheck(why: String)

        /// The reason in words, which ends the sentence the listener hears
        /// when a chosen table is refused, and the log's line. For a check
        /// that could not be made, why it could not.
        var reason: String {
            switch self {
            case .gone:
                return "this Mac no longer has it"
            case .doesNotLoad:
                return "it does not load in TextMouth's liblouis \(BrailleTableCatalog.bundledLiblouisVersion)"
            case .writesEightDots:
                return "it writes eight-dot braille, and TextMouth uses six-dot braille only"
            case .needsTooMuchMemory:
                return "it needs more than \(memoryCeilingBytes / 1_048_576) MB of memory"
            case .tooSlow:
                return "it translates too slowly, under \(Int(1_000 / secondsPerMBCeiling)) KB a second"
            case let .couldNotCheck(why):
                return why
            }
        }

        /// Why a check could not be made when the helper failed.
        static let helperFailed = couldNotCheck(why: "the braille helper failed")
        /// Why a check could not be made when no working folder could be made.
        static let noWorkingFolder = couldNotCheck(why: "TextMouth could not make a folder to check it in")

        /// Why a check could not be made when the watchdog stopped the
        /// helper, for `reason` (`WatchedProcess.KillReason.words`), such as
        /// "it ran longer than 10 seconds".
        static func helperStopped(because reason: String) -> Refusal {
            couldNotCheck(why: "the braille helper was stopped because \(reason)")
        }

        /// Whether the check itself could not be made.
        var isUnchecked: Bool {
            if case .couldNotCheck = self { return true }
            return false
        }
    }

    /// What a check found.
    enum Verdict: Equatable, Sendable {
        /// The table can be used, needing of the helper what its check
        /// measured.
        case usable(TableNeeds)
        /// The table cannot be used, for this reason.
        case refused(Refusal)

        /// Whether the table can be used.
        var isUsable: Bool {
            if case .usable = self { return true }
            return false
        }

        /// Whether the session keeps the verdict: every one but a check that
        /// could not be made.
        var lastsTheSession: Bool {
            if case let .refused(refusal) = self { return !refusal.isUnchecked }
            return true
        }
    }

    /// What one of this Mac's tables needs of the braille helper, as its
    /// check measured it (review R1).
    struct TableNeeds: Equatable, Sendable {
        /// How long a run that only loads the table took, in seconds:
        /// starting the helper and compiling the table.
        var loadSeconds: TimeInterval
        /// How long printing braille takes for each MB of input, in seconds,
        /// beyond loading.
        var forwardSecondsPerMB: TimeInterval
        /// How long reading braille back takes for each MB of input, in
        /// seconds, beyond loading.
        var backSecondsPerMB: TimeInterval
        /// The most resident memory a run held, in bytes.
        var peakResidentBytes: Int64

        /// No need beyond what every table gets: a bundled table's.
        static let none = TableNeeds(loadSeconds: 0, forwardSecondsPerMB: 0, backSecondsPerMB: 0, peakResidentBytes: 0)

        /// `today`, the limits every table gets for a run in `direction`
        /// (nil for "check") on `bytes` of input (`BrailleTranslator
        /// .limits(for:bytes:)`), raised to give this table at least twice
        /// the memory and four times the time it needs (review R1). A limit
        /// is never lowered.
        func limits(
            raising today: WatchedProcess.Limits,
            direction: BrailleTranslator.Direction?,
            bytes: Int64
        ) -> WatchedProcess.Limits {
            let rate: TimeInterval
            switch direction {
            case .printToBraille: rate = forwardSecondsPerMB
            case .brailleToPrint: rate = backSecondsPerMB
            case nil: rate = 0
            }
            let seconds = 4 * (loadSeconds + rate * Double(bytes) / 1_000_000)
            var limits = today
            limits.maximumSeconds = max(today.maximumSeconds, seconds)
            limits.maximumStalledSeconds = max(today.maximumStalledSeconds, seconds)
            limits.maximumResidentBytes = max(today.maximumResidentBytes, 2 * peakResidentBytes)
            return limits
        }
    }

    // MARK: Ceilings

    /// The most memory one of this Mac's tables may need (review R1): 64 MB.
    /// On October 20, 2026 the largest of the Mac's tables, Hungarian with
    /// its 876 KB hyphenation dictionary, held 28 MB once compiled and every
    /// other one 11 MB at most; the ceiling is more than twice the largest,
    /// and with the twofold headroom a run then holds at most 128 MB, a
    /// sixty-fourth of the 8 GB the user's Mac has. A table needing more is
    /// refused.
    static let memoryCeilingBytes: Int64 = 64 * 1_048_576

    /// The slowest one of this Mac's tables may translate, either way: 20
    /// seconds for each MB of input, 50 KB a second (review R1). On October
    /// 20, 2026 the slowest of the Mac's tables that pass the check read
    /// braille back at half a second a megabyte (Mainland Chinese) and wrote
    /// it at about 1.5, the Hungarian ones read it at up to 7.6, and the
    /// bundled English tables do at 0.05; at 20 seconds a megabyte a 1 MB
    /// braille file (3 MB of cells) reads in a minute, and the fourfold
    /// headroom allows four. A table slower than that is refused.
    static let secondsPerMBCeiling: TimeInterval = 20

    /// How often the watchdog reads the memory of a check's runs, in
    /// seconds: every millisecond, so that even a run of a few hundredths of
    /// a second, as small tables take, is read many times.
    static let measuringPollInterval: TimeInterval = 0.001

    /// How many lines of `sample` the check translates to time a table:
    /// about 20 KB of print, and the braille of it back, which the slowest
    /// table allowed translates in under half a second each way.
    static let timingLines = 120

    // MARK: The Check

    /// The print a table translates in its check, chosen by translating it
    /// with every table this Mac had on October 20, 2026. It holds capitals,
    /// which eight-dot tables write with dot 7, lowercase letters, digits,
    /// which some write with dot 8, and punctuation: of the Mac's 57
    /// eight-dot tables its first words found eight dots in 50 (digits
    /// alone, in 33). Review R1 added typographic punctuation (’ ‘ “ ” „ « »
    /// – — …), each standing alone and in the places it takes in a text,
    /// such as the apostrophe in "it’s": the Mac's Hungarian tables write
    /// ’ and ‘ with eight dots (⡈ and ⡶) alone or inside a word, but not
    /// around one, and its Chinese tables for Hong Kong and Taiwan write
    /// eight-dot cells too.
    static let sample = "Braille 2026, ABC abc: it\u{2019}s \u{2018}one\u{2019}, \u{201C}two\u{201D}, "
        + "\u{201E}three\u{201C} and \u{00AB}four\u{00BB} \u{2013} five \u{2014} six\u{2026} "
        + "\u{2019} \u{2018} \u{201C} \u{201D} \u{201E} \u{00AB} \u{00BB} \u{2013} \u{2014} \u{2026} 0123456789."

    /// Whether every scalar of `cells` is a six-dot braille cell, U+2800 to
    /// U+283F, liblouis's escape backslash aside (`BrailleCells
    /// .escapeBackslash`, which TextMouth's files write as ⠳): a cell with
    /// dot 7 or 8, or a scalar that is no braille cell, is not. The escape
    /// backslash is liblouis's cell, not the table's: the Mac's Urdu tables,
    /// which have no Latin letters, write it for the sample's letters and
    /// are still six-dot tables.
    static func writesSixDotsOnly(_ cells: String) -> Bool {
        cells.unicodeScalars.allSatisfy { scalar in
            scalar == BrailleCells.escapeBackslash || (BrailleCells.isPattern(scalar) && !BrailleCells.usesEightDots(scalar))
        }
    }

    /// The check of `tableID`, made now, with the helper's hidden files in
    /// `folder`, in three measured runs (review R1): loading the table,
    /// printing `timingLines` lines of `sample` in braille, and reading
    /// their braille back. For a table whose metadata gives no `dots` line
    /// the printed sample must be six-dot (decision 3 offers a table that
    /// says `dots: 6` on its word; an eight-dot cell such a table writes for
    /// a book fails that book's export, naming the character). The table's
    /// needs, its memory and its speed each way, must stay under the
    /// ceilings. A bundled table is not checked and is usable. A refusal
    /// that says something of the table is logged.
    /// - Throws: only `ImportCancelled` or `CancellationError`, when an
    ///   import's Cancel or the task's own cancellation stops the helper.
    static func check(_ tableID: String, workingIn folder: URL) throws -> Verdict {
        guard BrailleTableSource.parse(tableID).source == .mac else { return .usable(.none) }
        let verdict: Verdict
        if let table = BrailleTableCatalog.table(withID: tableID) {
            let measure = BrailleTranslator.RunMeasure(memoryCeiling: memoryCeilingBytes, pollInterval: measuringPollInterval)
            do {
                verdict = try measuredVerdict(of: table, workingIn: folder, measure: measure)
            } catch let failure as BrailleTranslator.Failure {
                verdict = .refused(refusal(for: failure, stop: measure.stop))
            }
        } else {
            verdict = .refused(.gone)
        }
        if case let .refused(refusal) = verdict, !refusal.isUnchecked {
            DiagnosticLog.event(.import, "BRAILLE_MAC_TABLE_REFUSED: \(tableID): \(refusal.reason)")
        }
        return verdict
    }

    /// The verdict of `table`'s three measured runs, made with `measure`.
    /// - Throws: the translator's failures and cancellations, unchanged.
    private static func measuredVerdict(
        of table: BrailleTable,
        workingIn folder: URL,
        measure: BrailleTranslator.RunMeasure
    ) throws -> Verdict {
        try BrailleTranslator.check(table: table.id, workingIn: folder, measure: measure)
        let loadSeconds = measure.lastRunSeconds
        let print = Array(repeating: sample, count: timingLines)
        let cells = try BrailleTranslator.translate(
            print, table: table.id, direction: .printToBraille, workingIn: folder, checksMacTable: false, measure: measure
        )
        let forwardSeconds = measure.lastRunSeconds
        guard table.declaresSixDots || cells.allSatisfy(writesSixDotsOnly) else { return .refused(.writesEightDots) }
        _ = try BrailleTranslator.translate(
            cells, table: table.id, direction: .brailleToPrint, workingIn: folder, checksMacTable: false, measure: measure
        )
        let backSeconds = measure.lastRunSeconds
        let needs = TableNeeds(
            loadSeconds: loadSeconds,
            forwardSecondsPerMB: secondsPerMB(forwardSeconds - loadSeconds, input: print),
            backSecondsPerMB: secondsPerMB(backSeconds - loadSeconds, input: cells),
            peakResidentBytes: measure.peakResidentBytes
        )
        return verdict(for: needs, timedSeconds: max(forwardSeconds, backSeconds) - loadSeconds)
    }

    /// The seconds for each MB of `input`, as the helper reads it (each text
    /// a line of UTF-8), that a run took beyond loading; none below zero.
    static func secondsPerMB(_ seconds: TimeInterval, input: [String]) -> TimeInterval {
        let megabytes = Double(input.reduce(0) { $0 + $1.utf8.count + 1 }) / 1_000_000
        return megabytes > 0 ? max(0, seconds) / megabytes : 0
    }

    /// The least time beyond loading a run of the check must take for its
    /// rate to show a table too slow: a run of a few hundredths of a second
    /// is mostly the time of starting a process, and its rate over a small
    /// input means nothing. A table at the ceiling takes 0.4 seconds to
    /// print the timing sample, so a table too slow is still found.
    static let minimumTimedSeconds: TimeInterval = 0.25

    /// The verdict a table's measured `needs` make, `timedSeconds` being the
    /// longest a timed run took beyond loading: refused when they pass a
    /// ceiling, else usable with them. Speed refuses a table only when
    /// `timedSeconds` reaches `minimumTimedSeconds`.
    static func verdict(for needs: TableNeeds, timedSeconds: TimeInterval) -> Verdict {
        if needs.peakResidentBytes > memoryCeilingBytes { return .refused(.needsTooMuchMemory) }
        if timedSeconds >= minimumTimedSeconds, max(needs.forwardSecondsPerMB, needs.backSecondsPerMB) > secondsPerMBCeiling {
            return .refused(.tooSlow)
        }
        return .usable(needs)
    }

    /// The refusal a translator's `failure` in a check makes, `stop` being
    /// why the watchdog stopped a run, if it did. Status 2 is a table the
    /// helper cannot load; a run stopped for its memory needs too much, and
    /// one stopped for its time is too slow (review R1). Any other failure is
    /// the helper's own, which the translator logs, and leaves the table
    /// unchecked, saying why.
    private static func refusal(for failure: BrailleTranslator.Failure, stop: WatchedProcess.KillReason?) -> Refusal {
        switch failure {
        case .unknownTable:
            return .doesNotLoad
        case let .stopped(reason):
            switch stop {
            case .usedTooMuchMemory?:
                return .needsTooMuchMemory
            case .tookTooLong?, .madeNoProgress?, .usedTooMuchProcessorTime?:
                return .tooSlow
            case .wroteTooMuch?, nil:
                return .helperStopped(because: reason)
            }
        case .failed, .uncheckedTable:
            return .helperFailed
        }
    }

    /// The limits a run of `table` gets: `today`'s, the tool's for a run in
    /// `direction` on `bytes` of input, raised by the needs its check
    /// measured when it is one of this Mac's tables found usable this
    /// session (review R1). The translator reads this on the caller's
    /// thread, where the verdicts in use are bound.
    static func limits(
        for table: String,
        raising today: WatchedProcess.Limits,
        direction: BrailleTranslator.Direction?,
        bytes: Int64
    ) -> WatchedProcess.Limits {
        guard case let .usable(needs)? = verdicts.verdict(for: table) else { return today }
        return needs.limits(raising: today, direction: direction, bytes: bytes)
    }

    // MARK: The Session's Verdicts

    /// The verdicts of a session (decision 5): each Mac table is checked
    /// once, and its verdict kept until TextMouth quits, unless the check
    /// could not be made. Two threads asking at once may both check; they
    /// find the same.
    final class Verdicts: Sendable {
        /// The verdicts so far, by stored value, behind a lock: the
        /// pop-ups ask on the main thread, an import or an export on its own.
        private let known = OSAllocatedUnfairLock<[String: Verdict]>(initialState: [:])

        /// An empty set of verdicts.
        init() {}

        /// The verdict kept for `tableID`, or nil when it has not been
        /// checked (or its check could not be made).
        func verdict(for tableID: String) -> Verdict? {
            known.withLock { $0[tableID] }
        }

        /// The verdict for `tableID`: the one kept, else `check`'s, which is
        /// kept when it lasts the session.
        func verdict(for tableID: String, checking check: () throws -> Verdict) rethrows -> Verdict {
            if let kept = verdict(for: tableID) { return kept }
            let found = try check()
            if found.lastsTheSession { known.withLock { $0[tableID] = found } }
            return found
        }
    }

    /// The verdicts in use: the session's, unless a test binds its own with
    /// `MacBrailleTableCheck.$verdicts.withValue(_:operation:)`, so that a
    /// stand-in helper's failures are never kept for the real tables. Like
    /// `BrailleTranslator.tool`, it is read on the caller's thread.
    @TaskLocal static var verdicts = Verdicts()

    // MARK: Asking

    /// Throws unless the table can be used: the kept verdict, else a check
    /// made now in `folder`. A bundled table passes at once. The translator
    /// asks this before a Mac table's first use, so a table that fails, or
    /// is gone, is refused by name, as an unknown table is (decision 5),
    /// with `BrailleTranslator.Failure.unknownTable(tableID)`. A check that
    /// could not be made says so, and why, with `.uncheckedTable`, and is
    /// not kept, so the next import tries again (review R7).
    /// - Throws: also `ImportCancelled` or `CancellationError` from the check.
    static func requireUsable(_ tableID: String, workingIn folder: URL) throws {
        guard BrailleTableSource.parse(tableID).source == .mac else { return }
        let verdict = try verdicts.verdict(for: tableID) { try check(tableID, workingIn: folder) }
        guard case let .refused(refusal) = verdict else { return }
        if case let .couldNotCheck(why) = refusal {
            throw BrailleTranslator.Failure.uncheckedTable(tableID, why: why)
        }
        throw BrailleTranslator.Failure.unknownTable(tableID)
    }

    /// The verdict for `tableID` as the pop-ups need it: the kept one at
    /// once, else a check made off the main thread, in a working folder of
    /// its own in the temporary directory, removed afterwards. Nothing waits
    /// for it but the caller. The tool, the verdicts, and the temporary
    /// folder in use are read here and handed to the check, which a detached
    /// task would not otherwise see.
    static func verdictOffTheMainThread(for tableID: String) async -> Verdict {
        let verdicts = self.verdicts
        if let kept = verdicts.verdict(for: tableID) { return kept }
        let tool = BrailleTranslator.tool
        let root = TextutilDocumentReader.temporaryRoot
        return await Task.detached(priority: .userInitiated) {
            BrailleTranslator.$tool.withValue(tool) {
                TextutilDocumentReader.$temporaryRoot.withValue(root) {
                    do {
                        return try verdicts.verdict(for: tableID) {
                            try TextutilDocumentReader.withTemporaryWorkingFolder { try check(tableID, workingIn: $0) }
                        }
                    } catch {
                        // No import's Cancel reaches this check, so only a
                        // working folder that could not be made, or a
                        // cancelled task, ends here: the check was not made.
                        return .refused(.noWorkingFolder)
                    }
                }
            }
        }.value
    }
}
