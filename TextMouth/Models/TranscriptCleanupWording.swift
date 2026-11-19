import Foundation

/// The words of the experimental transcript cleanup (FR05): its command,
/// the Clean Up sheet, and what VoiceOver hears as a cleanup is applied or
/// undone, each built once for the screen and VoiceOver alike.
///
/// Every text is localized (FR34): each is a computed property or a function
/// that reads the String Catalog when it is asked, with a comment for its
/// translators. The rules' own patterns and replacements are the user's
/// content and are shown as they are.
enum TranscriptCleanupWording {
    // MARK: The Command

    /// The command that opens the Clean Up sheet for a transcribed
    /// audiobook, beside Transcribe Audio… in the library's context menu,
    /// its VoiceOver actions, and the reader's Book menu.
    static var commandTitle: String {
        String(localized: "Clean Up Transcript (Experimental)…",
               comment: "Menu item and VoiceOver action that opens the sheet for correcting an audiobook's transcript with rules. The ellipsis means a sheet follows.")
    }

    // MARK: The Sheet

    /// The sheet's heading: "Clean Up the Transcript of Moby-Dick".
    static func sheetTitle(bookTitle: String) -> String {
        String(localized: "Clean Up the Transcript of \(bookTitle)",
               comment: "Heading of the Clean Up Transcript sheet. %@ is the audiobook's title.")
    }

    /// What the sheet says while it reads the transcript and the rules.
    static var checking: String {
        String(localized: "Reading the transcript and the rules…",
               comment: "Line of the Clean Up Transcript sheet while it reads the transcript and the correction rules.")
    }

    /// The line saying what the cleanup is, and that it can be undone.
    static var experimentalLine: String {
        String(localized: "Experimental. These rules correct words the recognizer writes differently from books read aloud. Check the changes before you apply them; Undo Cleanup puts the transcript back.",
               comment: "Line at the top of the Clean Up Transcript sheet. Undo Cleanup is the name of a button of the sheet.")
    }

    /// The line naming the rules in use: "Rules: TextMouth's own, version 1
    /// of October 4, 2026, 6 rules."
    static func rulesLine(_ rules: TranscriptCleanupRuleSet, source: TranscriptCleanupRuleSource) -> String {
        // The version is a number that names the rules, so it is written
        // without digit grouping; the count of rules is a count.
        let version = String(rules.version)
        let count = rules.rules.count
        switch source {
        case .user:
            return String(localized: "Rules: your copy, version \(version) of \(rules.dayName), \(count) rules.",
                          comment: "Line of the Clean Up Transcript sheet naming the correction rules in use, when they are the user's own copy. %1$@ is the rules' version number, written without digit grouping; %2$@ is the date of that version, such as \"October 4, 2026\"; %3$lld is the number of rules.")
        case .builtIn:
            return String(localized: "Rules: TextMouth's own, version \(version) of \(rules.dayName), \(count) rules.",
                          comment: "Line of the Clean Up Transcript sheet naming the correction rules in use, when they are the ones that come with the app. %1$@ is the rules' version number, written without digit grouping; %2$@ is the date of that version, such as \"October 4, 2026\"; %3$lld is the number of rules.")
        }
    }

    /// The line saying the user's copy of the rules waits in the cloud.
    static var userCopyInCloud: String {
        String(localized: "Your copy of the rules is only in the cloud, so TextMouth asked for it and uses its own meanwhile.",
               comment: "Line of the Clean Up Transcript sheet when the user's own rules file has not been downloaded from the cloud drive yet.")
    }

    /// The line saying the user's copy of the rules can't be used.
    static func userCopyUnusable(reason: String) -> String {
        String(localized: "Your rules file can't be used: \(reason). TextMouth keeps it and a copy, and uses its own rules until you correct it.",
               comment: "Line of the Clean Up Transcript sheet when the user's own rules file is damaged. %@ is the reason, a short technical phrase in English.")
    }

    /// The line saying the rules in use hold no rule, and how to add some:
    /// TextMouth's own list is empty, as its measurements found no
    /// correction right in every book
    /// (TRANSCRIPT-CLEANUP-RESEARCH-2026-10-04.md).
    static func noRules(source: TranscriptCleanupRuleSource) -> String {
        switch source {
        case .builtIn:
            return String(localized: "TextMouth has no rules of its own: none was right in every book tested. Edit Rules… opens your copy, where you can add rules, such as a name the recognizer always spells another way.",
                          comment: "Line of the Clean Up Transcript sheet when the rules that come with the app are empty. Edit Rules… is the name of a button of the sheet.")
        case .user:
            return String(localized: "Your copy of the rules is empty. Edit Rules… opens it to add some.",
                          comment: "Line of the Clean Up Transcript sheet when the user's own rules file holds no rule. Edit Rules… is the name of a button of the sheet.")
        }
    }

    /// The line saying TextMouth's own rules are newer than the user's copy.
    static func newerBuiltInRules(version: Int) -> String {
        String(localized: "TextMouth's own rules are newer, version \(String(version)). To use them, delete your copy or copy their rules into it.",
               comment: "Line of the Clean Up Transcript sheet when the rules that come with the app are newer than the user's copy. %@ is the new version number, written without digit grouping.")
    }

    /// `count` corrections: "1 correction", "23 corrections".
    private static func corrections(_ count: Int) -> String {
        String(localized: "\(count) corrections",
               comment: "A count of corrections the cleanup rules make in a transcript. %lld is the number of corrections.")
    }

    /// The summary of what would change: "23 corrections in 19 sentences."
    static func summary(corrections: Int, sentences: Int) -> String {
        let changed = String(localized: "\(sentences) sentences",
                             comment: "A count of the transcript's sentences that the cleanup rules would change. %lld is the number of sentences.")
        return String(localized: "\(Self.corrections(corrections)) in \(changed).",
                      comment: "Summary line of the Clean Up Transcript sheet. %1$@ is the number of corrections, such as \"23 corrections\"; %2$@ is the number of sentences they are in, such as \"19 sentences\".")
    }

    /// The summary when the rules change nothing.
    static var nothingToChange: String {
        String(localized: "No rule changes this transcript.",
               comment: "Summary line of the Clean Up Transcript sheet when the rules would change nothing.")
    }

    /// One rule's line: "“alright” becomes “all right”: 4 corrections."
    /// A rule matching inside words says so.
    static func ruleLine(_ rule: TranscriptCleanupRule, corrections: Int) -> String {
        let count = Self.corrections(corrections)
        if rule.wholeWord {
            return String(localized: "“\(rule.pattern)” becomes “\(rule.replacement)”: \(count).",
                          comment: "Heading of one rule's changes in the Clean Up Transcript sheet. %1$@ is the text the rule looks for; %2$@ is the text it puts in its place; %3$@ is the number of corrections, such as \"4 corrections\".")
        }
        return String(localized: "“\(rule.pattern)” becomes “\(rule.replacement)”, inside words too: \(count).",
                      comment: "Heading of one rule's changes in the Clean Up Transcript sheet, for a rule that also changes the text inside longer words. %1$@ is the text the rule looks for; %2$@ is the text it puts in its place; %3$@ is the number of corrections, such as \"4 corrections\".")
    }

    /// An example's line, before and after: "Before: …he felt alright
    /// then. After: …he felt all right then."
    static func exampleLine(_ example: TranscriptCleanup.Example) -> String {
        String(localized: "Before: \(example.before) After: \(example.after)",
               comment: "An example of one change in the Clean Up Transcript sheet. %1$@ is the transcript's text before the change; %2$@ is the text after it.")
    }

    /// The line saying the transcript was cleaned up already: "Cleaned up on
    /// October 4, 2026, with rules version 1: 23 corrections. Undo Cleanup
    /// puts back the transcript from before."
    static func alreadyCleanedUp(_ note: TranscriptCleanupNote, canUndo: Bool) -> String {
        var sentences = [
            String(localized: "Cleaned up on \(TranscriptionWording.day(note.cleanedAt)), with rules version \(String(note.rulesVersion)): \(corrections(note.corrections)).",
                   comment: "Line of the Clean Up Transcript sheet for a transcript that was cleaned up already. %1$@ is a date, such as \"October 4, 2026\"; %2$@ is the rules' version number, written without digit grouping; %3$@ is the number of corrections, such as \"23 corrections\".")
        ]
        if canUndo {
            sentences.append(String(localized: "Undo Cleanup puts back the transcript from before.",
                                    comment: "Last sentence of the Clean Up Transcript sheet's line about a transcript cleaned up already. Undo Cleanup is the name of a button of the sheet."))
        }
        return SentenceWording.joined(sentences)
    }

    /// The line warning that undoing the cleanup undoes the user's later
    /// edits too.
    static func editedSinceCleanup(on date: Date) -> String {
        String(localized: "You edited the transcript on \(TranscriptionWording.day(date)), after the cleanup. Undo Cleanup undoes those edits too.",
               comment: "Line of the Clean Up Transcript sheet warning that undoing the cleanup also undoes the user's later edits. %@ is a date, such as \"October 5, 2026\". Undo Cleanup is the name of a button of the sheet.")
    }

    /// The sheet's buttons.
    static var applyTitle: String {
        String(localized: "Apply",
               comment: "Button of the Clean Up Transcript sheet that makes the corrections in the transcript.")
    }
    static var undoTitle: String {
        String(localized: "Undo Cleanup",
               comment: "Button of the Clean Up Transcript sheet that puts back the transcript from before the last cleanup.")
    }
    static var editRulesTitle: String {
        String(localized: "Edit Rules…",
               comment: "Button of the Clean Up Transcript sheet that opens the rules file in the user's text editor.")
    }
    static var cancelTitle: String { TranscriptionWording.cancelTitle }
    static var okTitle: String { TranscriptionWording.okTitle }
    static var closeTitle: String { TranscriptionWording.closeTitle }

    /// What each button does.
    static var applyHint: String {
        String(localized: "Makes these corrections. The transcript from before is kept, so Undo Cleanup can put it back.",
               comment: "VoiceOver hint of the Apply button of the Clean Up Transcript sheet. Undo Cleanup is the name of a button of the sheet.")
    }
    static var undoHint: String {
        String(localized: "Puts back the transcript as it was before the last cleanup.",
               comment: "VoiceOver hint of the Undo Cleanup button of the Clean Up Transcript sheet.")
    }
    static var editRulesHint: String {
        String(localized: "Opens your copy of the rules, transcript-cleanup.json, in your text editor, made from TextMouth's own rules the first time. Changes apply when you return to TextMouth.",
               comment: "VoiceOver hint of the Edit Rules button of the Clean Up Transcript sheet. transcript-cleanup.json is a file name and stays as it is.")
    }
    static var cancelHint: String {
        String(localized: "Closes this without changing the transcript.",
               comment: "VoiceOver hint of the Cancel button of the Clean Up Transcript sheet.")
    }

    /// The heading of the list of changes, which VoiceOver reads as a group.
    static var changesLabel: String {
        String(localized: "Changes by rule",
               comment: "Heading and VoiceOver label of the list of changes in the Clean Up Transcript sheet, one group for each rule.")
    }

    /// What the sheet says while it saves the cleanup.
    static var applyingLine: String {
        String(localized: "Cleaning up the transcript…",
               comment: "Line of the Clean Up Transcript sheet while it saves the corrections.")
    }
    /// What the sheet says while it puts back the transcript from before.
    static var undoingLine: String {
        String(localized: "Putting back the transcript from before…",
               comment: "Line of the Clean Up Transcript sheet while it puts back the transcript from before the cleanup.")
    }

    /// What VoiceOver hears as the sheet appears, after its focus lands:
    /// its lines in one go, the heading first.
    static func sheetAnnouncement(lines: [String]) -> String {
        SentenceWording.joined(lines)
    }

    // MARK: Refusals

    /// Why the sheet does nothing for a book whose transcript is being made.
    static func busyTranscribing(bookTitle: String) -> String {
        String(localized: "\(bookTitle) is being transcribed. Clean up its transcript once that finishes.",
               comment: "Alert shown when Clean Up Transcript is chosen for an audiobook that is being transcribed. %@ is the audiobook's title.")
    }

    /// Why the sheet does nothing for a book without a transcript.
    static func noTranscript(bookTitle: String) -> String {
        String(localized: "\(bookTitle) has no transcript to clean up. Transcribe its audio first.",
               comment: "Alert shown when Clean Up Transcript is chosen for an audiobook with no transcript. %@ is the audiobook's title.")
    }

    /// Why the sheet does nothing for a transcript it can't read.
    static func unreadableTranscript(bookTitle: String) -> String {
        String(localized: "The transcript of \(bookTitle) can't be read. If the book is only in the cloud, download it and try again.",
               comment: "Alert shown when Clean Up Transcript is chosen for an audiobook whose transcript cannot be read. %@ is the audiobook's title.")
    }

    // MARK: What VoiceOver Hears

    /// A cleanup was applied: "Cleaned up the transcript of Moby-Dick: 23
    /// corrections."
    static func applied(bookTitle: String, corrections: Int) -> String {
        String(localized: "Cleaned up the transcript of \(bookTitle): \(Self.corrections(corrections)).",
               comment: "What VoiceOver hears once a transcript is cleaned up. %1$@ is the audiobook's title; %2$@ is the number of corrections, such as \"23 corrections\".")
    }

    /// A cleanup was undone.
    static func undone(bookTitle: String) -> String {
        String(localized: "Undid the cleanup of the transcript of \(bookTitle).",
               comment: "What VoiceOver hears once a transcript's cleanup is undone. %@ is the audiobook's title.")
    }

    /// Why a cleanup failed.
    static func applyFailed(bookTitle: String, reason: String) -> String {
        String(localized: "Couldn't clean up the transcript of \(bookTitle): \(reason)",
               comment: "Alert, and what VoiceOver hears, when a cleanup failed. %1$@ is the audiobook's title; %2$@ is the reason, a sentence.")
    }

    /// Why an undo failed.
    static func undoFailed(bookTitle: String, reason: String) -> String {
        String(localized: "Couldn't undo the cleanup of the transcript of \(bookTitle): \(reason)",
               comment: "Alert, and what VoiceOver hears, when undoing a cleanup failed. %1$@ is the audiobook's title; %2$@ is the reason, a sentence.")
    }

    /// Why the rules could not be opened.
    static func editRulesFailed(reason: String) -> String {
        String(localized: "Couldn't open the rules: \(reason)",
               comment: "Alert shown when the rules file could not be opened in the text editor. %@ is the reason, a sentence.")
    }
}
