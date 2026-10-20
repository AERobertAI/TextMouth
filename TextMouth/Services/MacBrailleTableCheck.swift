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
/// (decision 3). So before a Mac table is used, the helper loads it (its
/// "check" mode) and translates `sample` with it, and the table is used only
/// when both succeed and the sample's cells are six-dot
/// (`writesSixDotsOnly(_:)`).
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
        /// The check could not be made: the helper is missing, failed, or
        /// was stopped, or no working folder could be made. It says nothing
        /// of the table, so it is not kept for the session, and the next
        /// choice checks again.
        case couldNotCheck

        /// The reason in words, which ends the sentence the listener hears
        /// when a chosen table is refused, and the log's line.
        var reason: String {
            switch self {
            case .gone:
                return "this Mac no longer has it"
            case .doesNotLoad:
                return "it does not load in TextMouth's liblouis \(BrailleTableCatalog.bundledLiblouisVersion)"
            case .writesEightDots:
                return "it writes eight-dot braille, and TextMouth uses six-dot braille only"
            case .couldNotCheck:
                return "it could not be checked"
            }
        }
    }

    /// What a check found.
    enum Verdict: Equatable, Sendable {
        /// The table can be used.
        case usable
        /// The table cannot be used, for this reason.
        case refused(Refusal)

        /// Whether the session keeps the verdict: every one but a check that
        /// could not be made.
        var lastsTheSession: Bool { self != .refused(.couldNotCheck) }
    }

    // MARK: The Check

    /// The print a table translates in its check, chosen by translating it
    /// with every table this Mac had on October 20, 2026. It holds capitals,
    /// which eight-dot tables write with dot 7, lowercase letters, digits,
    /// which some write with dot 8, and punctuation. Of the Mac's 57
    /// eight-dot tables it found eight dots in 50 (digits alone, in 33), and
    /// it found them in none of the six-dot tables the catalog offers.
    static let sample = "Braille 2026, ABC abc."

    /// liblouis's escape backslash: the cell it writes the backslash of its
    /// escape notation with (`'\x0041'` for a character a table lacks) when
    /// the table has no backslash of its own, braille ASCII's ⠳ with dot 7
    /// (`_lou_charToFallbackDots` in `Vendor/liblouis/liblouis/utils.c`).
    /// It is liblouis's cell, not the table's, and TextMouth's writers make
    /// it ⠳ (`BrailleFileWriter`), so it is not counted as eight-dot braille:
    /// the Mac's Urdu tables, which have no Latin letters, write it for the
    /// sample's letters and are still six-dot tables.
    static let escapeBackslash = Unicode.Scalar(0x2873)!

    /// Whether every scalar of `cells` is a six-dot braille cell, U+2800 to
    /// U+283F, `escapeBackslash` aside: a cell with dot 7 or 8, or a scalar
    /// that is no braille cell, is not.
    static func writesSixDotsOnly(_ cells: String) -> Bool {
        cells.unicodeScalars.allSatisfy { scalar in
            scalar == escapeBackslash || (BrailleCells.isPattern(scalar) && !BrailleCells.usesEightDots(scalar))
        }
    }

    /// The check of `tableID`, made now, with the helper's hidden files in
    /// `folder`: whether the table loads, and whether it writes the sample
    /// in six-dot cells. A bundled table is not checked and is usable. A
    /// refusal that says something of the table is logged.
    /// - Throws: only `ImportCancelled` or `CancellationError`, when an
    ///   import's Cancel or the task's own cancellation stops the helper.
    static func check(_ tableID: String, workingIn folder: URL) throws -> Verdict {
        guard BrailleTableSource.parse(tableID).source == .mac else { return .usable }
        let verdict: Verdict
        if BrailleTableCatalog.table(withID: tableID) == nil {
            verdict = .refused(.gone)
        } else {
            do {
                try BrailleTranslator.check(table: tableID, workingIn: folder)
                let cells = try BrailleTranslator.translate(
                    [sample], table: tableID, direction: .printToBraille, workingIn: folder, checksMacTable: false
                )
                verdict = cells.allSatisfy(writesSixDotsOnly) ? .usable : .refused(.writesEightDots)
            } catch let failure as BrailleTranslator.Failure {
                // Status 2 is a table the helper cannot load; any other
                // failure is the helper's own, which the translator logs.
                if case .unknownTable = failure { verdict = .refused(.doesNotLoad) } else { verdict = .refused(.couldNotCheck) }
            }
        }
        if case let .refused(refusal) = verdict, refusal != .couldNotCheck {
            DiagnosticLog.event(.import, "BRAILLE_MAC_TABLE_REFUSED: \(tableID): \(refusal.reason)")
        }
        return verdict
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

    /// Throws `BrailleTranslator.Failure.unknownTable(tableID)` unless the
    /// table can be used: the kept verdict, else a check made now in
    /// `folder`. A bundled table passes at once. The translator asks this
    /// before a Mac table's first use, so a table that fails, or is gone, is
    /// refused by name, as an unknown table is (decision 5).
    /// - Throws: also `ImportCancelled` or `CancellationError` from the check.
    static func requireUsable(_ tableID: String, workingIn folder: URL) throws {
        guard BrailleTableSource.parse(tableID).source == .mac else { return }
        let verdict = try verdicts.verdict(for: tableID) { try check(tableID, workingIn: folder) }
        if case .refused = verdict { throw BrailleTranslator.Failure.unknownTable(tableID) }
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
                        return .refused(.couldNotCheck)
                    }
                }
            }
        }.value
    }
}
