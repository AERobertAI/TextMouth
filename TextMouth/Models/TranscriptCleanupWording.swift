import Foundation

/// The words of the experimental transcript cleanup (FR05): its command,
/// the Clean Up sheet, and what VoiceOver hears as a cleanup is applied or
/// undone, each built once for the screen and VoiceOver alike.
enum TranscriptCleanupWording {
    // MARK: The Command

    /// The command that opens the Clean Up sheet for a transcribed
    /// audiobook, beside Transcribe Audio… in the library's context menu,
    /// its VoiceOver actions, and the reader's Book menu.
    static let commandTitle = "Clean Up Transcript (Experimental)…"

    // MARK: The Sheet

    /// The sheet's heading: "Clean Up the Transcript of Moby-Dick".
    static func sheetTitle(bookTitle: String) -> String {
        "Clean Up the Transcript of \(bookTitle)"
    }

    /// What the sheet says while it reads the transcript and the rules.
    static let checking = "Reading the transcript and the rules…"

    /// The line saying what the cleanup is, and that it can be undone.
    static let experimentalLine = "Experimental. These rules correct words the speech recognizer writes differently "
        + "from books read aloud. Check the changes below before you apply them. Undo Cleanup puts the transcript back."

    /// The line naming the rules in use: "Rules: TextMouth's own, version 1
    /// of October 4, 2026, 6 rules."
    static func rulesLine(_ rules: TranscriptCleanupRuleSet, source: TranscriptCleanupRuleSource) -> String {
        let whose = source == .user ? "your copy" : "TextMouth's own"
        let count = CountWording.phrase(rules.rules.count, singular: "rule", plural: "rules")
        return "Rules: \(whose), version \(rules.version) of \(rules.dayName), \(count)."
    }

    /// The line saying the user's copy of the rules waits in the cloud.
    static let userCopyInCloud = "Your copy of the rules is only in the cloud. TextMouth asked for it, and uses its own "
        + "rules until it is on this Mac."

    /// The line saying the user's copy of the rules can't be used.
    static func userCopyUnusable(reason: String) -> String {
        "Your copy of the rules couldn't be used: \(reason). It was kept beside itself, and TextMouth's own rules are used "
            + "until you correct it."
    }

    /// The line saying the rules in use hold no rule, and how to add some:
    /// TextMouth's own list is empty, as its measurements found no
    /// correction right in every book
    /// (TRANSCRIPT-CLEANUP-RESEARCH-2026-10-04.md).
    static func noRules(source: TranscriptCleanupRuleSource) -> String {
        switch source {
        case .builtIn:
            return "TextMouth comes with no rules of its own: measured on books read aloud, no correction was right "
                + "in every book. Edit Rules… opens your own copy, where you can add rules, such as a name the "
                + "recognizer always spells another way."
        case .user:
            return "Your copy of the rules has no rules yet. Edit Rules… opens it, so you can add some."
        }
    }

    /// The line saying TextMouth's own rules are newer than the user's copy.
    static func newerBuiltInRules(version: Int) -> String {
        "TextMouth's own rules are newer, version \(version). To use them, delete your copy, or copy their new rules into it."
    }

    /// The summary of what would change: "23 corrections in 19 sentences."
    static func summary(corrections: Int, sentences: Int) -> String {
        let corrected = CountWording.phrase(corrections, singular: "correction", plural: "corrections")
        let changed = CountWording.phrase(sentences, singular: "sentence", plural: "sentences")
        return "\(corrected) in \(changed)."
    }

    /// The summary when the rules change nothing.
    static let nothingToChange = "Nothing to clean up: no rule changes this transcript."

    /// One rule's line: "“alright” becomes “all right”: 4 corrections."
    /// A rule matching inside words says so.
    static func ruleLine(_ rule: TranscriptCleanupRule, corrections: Int) -> String {
        let count = CountWording.phrase(corrections, singular: "correction", plural: "corrections")
        let inside = rule.wholeWord ? "" : ", inside words too"
        return "“\(rule.pattern)” becomes “\(rule.replacement)”\(inside): \(count)."
    }

    /// An example's line, before and after: "Before: …he felt alright
    /// then. After: …he felt all right then."
    static func exampleLine(_ example: TranscriptCleanup.Example) -> String {
        "Before: \(example.before) After: \(example.after)"
    }

    /// The line saying the transcript was cleaned up already: "Cleaned up on
    /// October 4, 2026, with rules version 1: 23 corrections. Undo Cleanup
    /// puts back the transcript from before."
    static func alreadyCleanedUp(_ note: TranscriptCleanupNote, canUndo: Bool) -> String {
        let count = CountWording.phrase(note.corrections, singular: "correction", plural: "corrections")
        let cleaned = "Cleaned up on \(TranscriptionWording.day(note.cleanedAt)), with rules version \(note.rulesVersion): \(count)."
        return canUndo ? cleaned + " Undo Cleanup puts back the transcript from before." : cleaned
    }

    /// The line warning that undoing the cleanup undoes the user's later
    /// edits too.
    static func editedSinceCleanup(on date: Date) -> String {
        "You edited the transcript on \(TranscriptionWording.day(date)), after the cleanup. Undo Cleanup undoes those edits too."
    }

    /// The sheet's buttons.
    static let applyTitle = "Apply"
    static let undoTitle = "Undo Cleanup"
    static let editRulesTitle = "Edit Rules…"
    static let cancelTitle = TranscriptionWording.cancelTitle
    static let okTitle = TranscriptionWording.okTitle
    static let closeTitle = TranscriptionWording.closeTitle

    /// What each button does.
    static let applyHint = "Makes these corrections in the transcript. The transcript from before is kept, so Undo Cleanup "
        + "can put it back."
    static let undoHint = "Puts back the transcript as it was before the last cleanup."
    static let editRulesHint = "Opens your copy of the rules, transcript-cleanup.json, in your text editor, making it from "
        + "TextMouth's own rules the first time. Your changes are used when you come back to TextMouth."
    static let cancelHint = "Closes this without changing the transcript."

    /// The heading of the list of changes, which VoiceOver reads as a group.
    static let changesLabel = "Changes by rule"

    /// What the sheet says while it saves the cleanup.
    static let applyingLine = "Cleaning up the transcript…"
    /// What the sheet says while it puts back the transcript from before.
    static let undoingLine = "Putting back the transcript from before…"

    /// What VoiceOver hears as the sheet appears, after its focus lands:
    /// its lines in one go, the heading first.
    static func sheetAnnouncement(lines: [String]) -> String {
        lines.joined(separator: " ")
    }

    // MARK: Refusals

    /// Why the sheet does nothing for a book whose transcript is being made.
    static func busyTranscribing(bookTitle: String) -> String {
        "\(bookTitle) is being transcribed. Clean up its transcript once that finishes."
    }

    /// Why the sheet does nothing for a book without a transcript.
    static func noTranscript(bookTitle: String) -> String {
        "\(bookTitle) has no transcript to clean up. Transcribe its audio first."
    }

    /// Why the sheet does nothing for a transcript it can't read.
    static func unreadableTranscript(bookTitle: String) -> String {
        "The transcript of \(bookTitle) can't be read now. If the book is only in the cloud, download it, then try again."
    }

    // MARK: What VoiceOver Hears

    /// A cleanup was applied: "Cleaned up the transcript of Moby-Dick: 23
    /// corrections."
    static func applied(bookTitle: String, corrections: Int) -> String {
        let count = CountWording.phrase(corrections, singular: "correction", plural: "corrections")
        return "Cleaned up the transcript of \(bookTitle): \(count)."
    }

    /// A cleanup was undone.
    static func undone(bookTitle: String) -> String {
        "Undid the cleanup of the transcript of \(bookTitle)."
    }

    /// Why a cleanup failed.
    static func applyFailed(bookTitle: String, reason: String) -> String {
        "Couldn't clean up the transcript of \(bookTitle): \(reason)"
    }

    /// Why an undo failed.
    static func undoFailed(bookTitle: String, reason: String) -> String {
        "Couldn't undo the cleanup of the transcript of \(bookTitle): \(reason)"
    }

    /// Why the rules could not be opened.
    static func editRulesFailed(reason: String) -> String {
        "Couldn't open the rules: \(reason)"
    }
}
