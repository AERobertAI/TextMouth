"""The classifier: one case per bucket and per rule, from real lines of the app.

Each test's comment names the file and line of the real code its snippet is taken from, as the
line stood on November 18, 2026 (commit 5a067cde6); the snippet keeps the code around the
literal that the rule looks at. A snippet marked "synthetic" is for a form the app does not
use yet (it uses no String(localized:) before the conversion starts).
"""

from __future__ import annotations

import unittest

from scan_case import PARSER, WORDING, ScanCase, scan_snippet


class CountedBucketTests(ScanCase):
    """The four buckets that are interface text: ui, wording, error, prose, and word."""

    def test_ui_a_text_in_a_call_that_shows_text(self) -> None:
        # Views/Library/LibraryView.swift:588. A ternary of two literals inside Label is read as
        # a key: the compiler extracts both branches, so both are localized.
        found = scan_snippet('Label(isEditMode ? "Done" : "Edit", systemImage: "checkmark.circle")')
        self.assertEqual([(l.text, l.bucket, l.rule, l.status) for l in found], [
            ("Done", "ui", "localized-key", "apple-lookup"),
            ("Edit", "ui", "localized-key", "apple-lookup"),
            ("checkmark.circle", "code", "code-label", ""),
        ])
        # A call that shows text but is not one the compiler extracts: unlocalized ui text.
        self.assertClass('NSMenu(title: "Open Book")', "ui", "ui-call", "unlocalized")

    def test_wording_a_literal_in_a_wording_type(self) -> None:
        # Models/LibraryCloudWording.swift:312 (a file whose name holds Wording).
        code = 'enum LibraryCloudWording {\n    static func note() -> String {\n        return "\\(subject) downloaded. Try again."\n    }\n}'
        self.assertClass(code, "wording", "wording-type", "unlocalized", path=WORDING)

    def test_wording_by_the_type_not_the_file(self) -> None:
        # Views/Settings/LogsSettingsSection.swift:5 and :22: a Wording type inside a view file.
        code = 'enum LogsSettingsWording {\n    static let pickerLabel = "Log location"\n}'
        self.assertClass(code, "wording", "wording-type", "unlocalized")

    def test_error_the_body_of_error_description(self) -> None:
        # Services/SavedFile.swift:105.
        code = ('struct InCloudError: LocalizedError {\n    var errorDescription: String? {\n'
                '        "\\(fileName) is only in the cloud and isn\'t on this Mac yet."\n    }\n}')
        self.assertClass(code, "error", "error-decl", "unlocalized")

    def test_prose_a_sentence_outside_the_known_places(self) -> None:
        # Views/Library/LibraryIndexRecoveryViews.swift:42.
        code = 'enum Recovery {\n    static let quit = "Quits TextMouth without writing the library index."\n}'
        self.assertClass(code, "prose", "sentence", "unlocalized")

    def test_word_a_capitalized_single_word_returned_from_code(self) -> None:
        # Services/MediaGestureDetector.swift:58.
        code = 'var displayName: String {\n    switch self {\n    case .play: return "Play"\n    }\n}'
        self.assertClass(code, "word", "capitalized-word", "unlocalized")

    def test_wording_a_title_in_a_label_that_usually_names_a_key(self) -> None:
        # Services/TextSubstitutionService.swift:963: name: is a code label, but "Skip URLs"
        # is the rule's title in Settings.
        code = 'SubstitutionRule(name: "Skip URLs", pattern: "https?://\\\\S+", replacement: "link", isRegex: true)'
        found = scan_snippet(code)
        self.assertEqual([(l.text, l.bucket, l.rule) for l in found], [
            ("Skip URLs", "prose", "sentence"), ("https?://\\S+", "code", "code-label"), ("link", "token", "identifier")])

    def test_wording_a_fragment_of_a_sentence_in_a_wording_type(self) -> None:
        # Models/AudioEditWording.swift:28 and App/QuitFinisher.swift:32: words a sentence is built from.
        code = ('enum AudioEditWording {\n    static func seconds(_ rest: Double) -> String {\n'
                '        "\\(number(rest)) \\(rest == 1 ? "second" : "seconds")"\n    }\n'
                '    static func pair(_ a: String, _ b: String) -> String { "\\(a) and \\(b)" }\n}')
        found = scan_snippet(code, path=WORDING)
        self.assertEqual([(l.text, l.bucket, l.rule) for l in found], [
            ("%@ %@", "code", "no-letters"), ("second", "wording", "wording-fragment"),
            ("seconds", "wording", "wording-fragment"), ("%@ and %@", "wording", "wording-fragment")])

    def test_a_lowercase_word_outside_a_wording_type_stays_a_token(self) -> None:
        # The same words in a service are keys, as in Parsers/WordMLStyles.swift:26.
        self.assertClass('case "second": unit = .second', "token", "identifier")

    def test_plural_nouns_of_a_hand_built_plural_are_words(self) -> None:
        # Models/CountWording.swift:34 (phrase's callers), e.g. books(_:).
        found = scan_snippet('static func books(_ count: Int) -> String {\n    phrase(count, singular: "book", plural: "books")\n}')
        self.assertEqual([(l.bucket, l.rule, l.status, l.findings) for l in found],
                         [("word", "plural-noun", "unlocalized", ("plural",))] * 2)


class UncountedBucketTests(ScanCase):
    """The buckets that are not interface text, and the rule that puts a literal in each."""

    def test_code_no_letters(self) -> None:
        # Services/TextMouthPaths.swift:696.
        found = scan_snippet('s = s.replacingOccurrences(of: " ", with: "_")')
        self.assertEqual([(l.bucket, l.rule) for l in found], [("code", "no-letters")] * 2)

    def test_code_a_label_that_names_a_key_or_a_symbol(self) -> None:
        # Models/KeyboardShortcut.swift:1701 and Views/Library/LibraryView.swift:963.
        self.assertClass('KeyBinding(key: "w", isDoublePress: true)', "code", "code-label")
        self.assertClass('return String(format: "%d:%02d", minutes, secs)', "code", "code-label")

    def test_code_a_call_whose_arguments_are_code(self) -> None:
        # Parsers/ODTStyles.swift:213.
        self.assertClass('name.hasPrefix("style:")', "code", "code-call")

    def test_code_a_path_or_a_url(self) -> None:
        # Services/SoundEffectService.swift:194.
        self.assertClass('static let systemSoundsPath = "/System/Library/Sounds"', "code", "path-or-url")
        self.assertClass('let site = "https://example.com/feed.xml"', "code", "path-or-url")
        self.assertClass('let who = "reader@example.com"', "code", "path-or-url")

    def test_code_punctuation_that_no_sentence_has(self) -> None:
        # Services/Export/RTFExportWriter.swift:86.
        self.assertClass('lines.append(#"{\\rtf1\\ansi\\ansicpg1252\\deff0\\uc1"#)', "code", "code-punctuation")

    def test_code_a_date_format(self) -> None:
        # Services/RecordingTake.swift:76 and Views/Library/TextInputView.swift:19.
        self.assertClass('private static let nameDateFormat = "yyyy-MM-dd HH.mm.ss"', "code", "date-format")
        self.assertClass('formatter.dateFormat = "yyyy-MM-dd HH:mm"', "code", "date-format")

    def test_code_the_raw_value_of_an_enum_case(self) -> None:
        # Models/TimedText.swift:18: a stored identifier that is no title.
        self.assertClass('enum TimedTextFormat: String {\n    case webvtt = "webvtt"\n}', "code", "raw-value")
        # A capital with no lowercase letter is a code too (Services/AudioBuiltInFilter.swift has such cases).
        self.assertClass('enum Unit: String {\n    case mp3 = "MP3"\n}', "code", "raw-value")

    def test_rawtitle_a_raw_value_that_reads_as_a_title(self) -> None:
        # Models/KeyboardShortcut.swift:137 (ShortcutAction.title returns the raw value, and
        # config.json stores it), ViewModels/SettingsViewModel.swift:7 and ViewModels/LibraryViewModel.swift:8.
        for code in ('enum ShortcutAction: String {\n    case importFolder = "Import Folder…"\n}',
                     'enum RewindUnit: String {\n    case none = "None"\n}',
                     'enum Sort: String {\n    case dateAdded = "Date Added"\n}'):
            lit = self.assertClass(code, "rawtitle", "raw-value-title", "unlocalized")
            self.assertEqual(lit.findings, ("raw-title",))

    def test_a_marked_raw_title_is_left_out(self) -> None:
        # The conversion keeps the raw value as the stored id and marks it.
        lit = self.assertClass('enum Sort: String {\n    case dateAdded = "Date Added" // l10n: no (stored id)\n}',
                               "rawtitle", "raw-value-title", "marked")
        self.assertEqual(lit.findings, ())

    def test_token_an_identifier(self) -> None:
        # Parsers/DOCXParser+Sections.swift:22.
        self.assertClass('case "lowerRoman": self = .lowerRoman', "token", "identifier")

    def test_token_a_lowercase_word_outside_a_known_call(self) -> None:
        # Services/AudioEditing/FFmpeg.swift:113: command-line options, not words to say.
        found = scan_snippet('arguments += ["-f", "ffmetadata", "-i", file.path]')
        self.assertEqual([(l.text, l.bucket, l.rule) for l in found], [
            ("-f", "token", "lowercase-word"), ("ffmetadata", "token", "identifier"), ("-i", "token", "lowercase-word")])

    def test_log_by_the_call(self) -> None:
        # Services/Feeds/FeedItemPackage.swift:209 and Parsers/DAISYParser+Audio.swift:628.
        self.assertClass('DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_CACHE_LEFT: \\(row.title) could not be removed")',
                         "log", "log-call")
        self.assertClass('print("Warning: Failed to copy remaining audio file \\(path)")', "log", "log-call")

    def test_log_by_the_function_it_is_in(self) -> None:
        # Models/CloudStorageContract.swift:452: a log line's words, made by logReason.
        code = ('enum BookCloudWording {\n    static func logReason(_ doubt: CloudCopyDoubt) -> String {\n'
                '        switch doubt {\n        case .uploadNotReported: return "the sync service gave no upload state"\n'
                '        }\n    }\n}')
        self.assertClass(code, "log", "log-block", path=WORDING)

    def test_a_wording_type_about_the_logs_is_not_log_text(self) -> None:
        # Views/Settings/LogsSettingsSection.swift:5 and :14: the Logs settings' own words.
        code = 'enum LogsSettingsWording {\n    static func optionTitle() -> String {\n        return "Inside the data directory"\n    }\n}'
        self.assertClass(code, "wording", "wording-type")

    def test_log_by_a_tag_at_the_start_of_a_line_built_outside_a_log_call(self) -> None:
        # Services/TextMouthPaths.swift:79.
        self.assertClass('return "DATA_DIRECTORY_FOUND: \\(name) was missing; its bookmark "', "log", "log-tag")

    def test_diag_a_parsers_damage_reason(self) -> None:
        # Parsers/KFXSymbols.swift:62, a call in _DIAG_CALLS.
        self.assertClass('throw MOBIError.damaged("the symbol table is not a struct")', "diag", "diag-reason", path=PARSER)

    def test_other_text_in_a_parser_is_classified_like_text_anywhere(self) -> None:
        # Parsers/TextEncodingCatalog.swift:83: a pop-up title shown in Book Information.
        found = scan_snippet('row("iso-8859-7", "ISO 8859-7 (Greek)")', path=PARSER)
        self.assertEqual([(l.text, l.bucket, l.status) for l in found],
                         [("iso-8859-7", "token", ""), ("ISO 8859-7 (Greek)", "prose", "unlocalized")])
        # Parsers/XMLInputGuard.swift:79: a sentence the user reads when an import is refused.
        self.assertClass('return "TextMouth can\'t safely read the file \\(file) in \\(container)."',
                         "prose", "sentence", "unlocalized", path=PARSER)
        # Parsers/DOCXParser.swift:164: a reason that goes into the import failure's wording.
        self.assertClass('reportIncompleteContent(.malformedXML(file: notesPart, reason: "it could not be unpacked"))',
                         "prose", "sentence", "unlocalized", path=PARSER)

    def test_a_single_word_in_a_parser_follows_the_single_word_rules(self) -> None:
        # Parsers/PageImageArchive.swift:291 is a set of element names (capitalized names read as
        # labels, and the conversion can mark them `// l10n: no`).
        found = scan_snippet('private static let names: Set<String> = ["Title", "Series"]', path=PARSER)
        self.assertEqual([(l.bucket, l.rule) for l in found], [("word", "capitalized-word")] * 2)
        self.assertEqual([(l.bucket, l.rule) for l in scan_snippet('let ext = ".snd"', path=PARSER)], [("token", "lowercase-word")])

    def test_comment_the_translators_note(self) -> None:
        # Synthetic: the app uses no String(localized:) before the conversion starts.
        found = scan_snippet('String(localized: "Pause", comment: "The button that pauses speech")')
        self.assertEqual([(l.text, l.bucket, l.rule) for l in found], [
            ("Pause", "ui", "localized-key"),
            ("The button that pauses speech", "comment", "comment-label"),
        ])
        self.assertEqual(found[1].status, "")


class LocalizedStatusTests(ScanCase):
    """Which literals the compiler extracts, and which it shows as is. A literal it extracts is the key of a lookup into Apple's
    tables, which no app ships since FR39 phase 8: its rule stays `localized-key` so that it can be named, and its status is
    `apple-lookup`, which the lint refuses. Only the English of an InterfaceText.line call is `localized`."""

    def test_the_english_of_an_interface_text_call_is_localized_and_its_id_is_not_text(self) -> None:
        found = scan_snippet('InterfaceText.line("pause.title", "Pause the speech")')
        self.assertEqual([(l.text, l.rule, l.status) for l in found],
                         [("pause.title", "interface-text-argument", ""), ("Pause the speech", "localized-key", "localized")])

    def test_a_swiftui_literal_is_an_apple_lookup(self) -> None:
        # Views/Settings/SettingsView.swift:429 and App/MenuCommands.swift:314.
        self.assertClass('.accessibilityLabel("End of book behavior")', "ui", "localized-key", "apple-lookup")
        self.assertClass('Button("Next Heading") {\n    action()\n}', "ui", "localized-key", "apple-lookup")

    def test_other_swiftui_calls_with_a_title_are_apple_lookups(self) -> None:
        for call in ('Toggle("Read aloud", isOn: $on)', 'Picker("Speed", selection: $speed)',
                     'Label("Sort", systemImage: "arrow")', '.navigationTitle("Library")',
                     '.accessibilityHint("Opens the sheet")', '.help("Shows the list")',
                     'Section("Options")', 'TextField("Name", text: $name)'):
            self.assertEqual(scan_snippet(call)[0].status, "apple-lookup", call)

    def test_labeled_arguments_are_apple_lookups(self) -> None:
        self.assertEqual(only_status('.searchable(text: $q, prompt: "Search books")'), "apple-lookup")
        self.assertEqual(only_status('.accessibilityAction(named: "Delete") { }'), "apple-lookup")
        # The same label with a ternary of two literals extracts both, but with a variable as
        # the other branch neither: the String overload shows the text as is.
        found = scan_snippet('.searchable(text: $q, prompt: wide ? "Search all books" : "Search")')
        self.assertEqual([l.status for l in found], ["apple-lookup", "apple-lookup"])
        found = scan_snippet('.searchable(text: $q, prompt: wide ? hint : "Search")')
        self.assertEqual([(l.text, l.label, l.status) for l in found], [("Search", "prompt", "unlocalized")])

    def test_string_localized_is_an_apple_lookup_and_its_comment_is_not_counted(self) -> None:
        # Synthetic.
        self.assertEqual(only_status('let t = String(localized: "Sleep timer", comment: "Menu title")'), "apple-lookup")
        self.assertEqual(only_status('let t = AttributedString(localized: "Sleep timer")'), "apple-lookup")

    def test_localized_string_resource_and_key_and_value(self) -> None:
        # Synthetic.
        for code in ('let a = LocalizedStringResource("Pause", comment: "Button")', 'let b = LocalizedStringKey("Pause")',
                     'let c = String.LocalizationValue("Pause")'):
            self.assertEqual(scan_snippet(code)[0].status, "apple-lookup", code)

    def test_text_verbatim_is_unlocalized(self) -> None:
        # Synthetic: the compiler shows a verbatim string as it is.
        self.assertClass('Text(verbatim: "Library title")', "ui", "verbatim-text", "unlocalized")

    def test_a_ternary_of_two_literals_in_a_key_position_is_an_apple_lookup(self) -> None:
        # Views/Settings/SubstitutionsSettingsView.swift:215: Button(rule.isEnabled ? "Disable" : "Enable");
        # the compiler extracts both branches (checked against its stringsdata).
        found = scan_snippet('Button(rule.isEnabled ? "Disable" : "Enable") { toggle() }')
        self.assertEqual([(l.text, l.status) for l in found], [("Disable", "apple-lookup"), ("Enable", "apple-lookup")])

    def test_a_ternary_with_a_variable_branch_is_not_localized(self) -> None:
        # Synthetic: the compiler picks the String overload, so the literal is shown as is.
        found = scan_snippet('Text(isOn ? onTitle : "Off")\nText(isOn ? "On" : offTitle)\nText(name ?? "Untitled")')
        self.assertEqual([(l.text, l.status) for l in found],
                         [("Off", "unlocalized"), ("On", "unlocalized"), ("Untitled", "unlocalized")])

    def test_a_ternary_inside_a_larger_expression_is_not_localized(self) -> None:
        # Synthetic: a bare parenthesis, or a sum, makes a String.
        found = scan_snippet('Text("Mode: " + (fast ? "Fast mode" : "Slow mode"))')
        self.assertEqual([l.status for l in found], ["unlocalized"] * 3)

    def test_an_interpolation_only_or_empty_key_is_an_apple_lookup(self) -> None:
        # Synthetic, from the compiler's stringsdata of Text("\(a): \(b)") and Stepper("").
        self.assertClass('Text("\\(a): \\(b)")', "ui", "localized-key", "apple-lookup")
        self.assertClass('Stepper("", value: $n)', "ui", "localized-key", "apple-lookup")
        self.assertClass('Text("\\(count)")', "ui", "localized-key", "apple-lookup")
        # Outside a localizing call the same text has no letters and is code.
        self.assertClass('let x = ""', "code", "no-letters")

    def test_a_literal_in_an_interpolation_is_never_the_key(self) -> None:
        found = scan_snippet('Text("Now \\(paused ? "paused" : "playing")")')
        self.assertEqual([(l.text, l.status) for l in found], [("Now %@", "apple-lookup"), ("paused", ""), ("playing", "")])
        # A literal inside the key's interpolation is not the key even where its call takes a
        # bare literal: the call here is String(localized:), and "Item %@" is only a piece of it.
        found = scan_snippet('String(localized: "Items: \\(items.map { "Item \\($0)" }.count)")')
        self.assertEqual([(l.text, l.status) for l in found], [("Items: %@", "apple-lookup"), ("Item %@", "unlocalized")])

    def test_a_bare_parenthesis_around_a_ternary_is_not_a_labelled_argument(self) -> None:
        # Synthetic. The colon of a ternary after an identifier is no argument label (`name`
        # is a code label): the literal after it is still a sentence.
        found = scan_snippet('let t = (ready ? name : "Not ready to read yet")')
        self.assertEqual([(l.bucket, l.rule) for l in found], [("prose", "sentence")])

    def test_a_parameter_typed_localized_string_resource_makes_its_arguments_apple_lookups(self) -> None:
        # Synthetic: a helper whose parameter is a LocalizedStringResource.
        helper = 'func announce(_ message: LocalizedStringResource, priority: Int = 0) {}'
        code = 'announce("Sleep timer set")\nannounce("Sleep timer off", priority: 1)\nother("Not a resource")'
        found = scan_snippet(code, extra={"TextMouth/Services/Announcer.swift": helper})
        self.assertEqual([(l.text, l.status) for l in found],
                         [("Sleep timer set", "apple-lookup"), ("Sleep timer off", "apple-lookup"), ("Not a resource", "unlocalized")])

    def test_a_parameter_typed_localized_string_key_makes_its_arguments_apple_lookups(self) -> None:
        # Views/Reader/ReaderView.swift:170: toolbarButton(_ title: LocalizedStringKey, ..., spokenLabel: LocalizedStringKey).
        helper = ('func toolbarButton(_ title: LocalizedStringKey, systemImage: String, '
                  'spokenLabel: LocalizedStringKey) {}')
        found = scan_snippet('toolbarButton("Play", systemImage: "play", spokenLabel: "Play the book")',
                             extra={"TextMouth/Views/Toolbar.swift": helper})
        self.assertEqual([(l.text, l.status) for l in found],
                         [("Play", "apple-lookup"), ("play", ""), ("Play the book", "apple-lookup")])

    def test_a_labeled_resource_parameter_is_found_by_its_label(self) -> None:
        helper = 'func show(title: String.LocalizationValue, detail: String) {}'
        found = scan_snippet('show(title: "Done", detail: "All saved")', extra={"TextMouth/Services/Show.swift": helper})
        self.assertEqual([(l.text, l.status) for l in found], [("Done", "apple-lookup"), ("All saved", "unlocalized")])


class MarkerTests(ScanCase):
    """`// l10n: no` leaves a literal out of the count."""

    def test_the_marker_at_the_end_of_the_line(self) -> None:
        lit = only_literal('let label = "Pause button" // l10n: no')
        self.assertEqual((lit.bucket, lit.status), ("prose", "marked"))

    def test_the_marker_with_a_reason(self) -> None:
        for comment in ("// l10n: no (test hook)", "// l10n: no: shown only in tests", "// l10n: no - a name the system gives",
                        "// l10n: no, a test hook", "// l10n: no reason given", "//l10n:no", "// l10n: no."):
            self.assertEqual(only_literal(f'let label = "Pause button" {comment}').status, "marked", comment)

    def test_a_different_comment_does_not_mark(self) -> None:
        for comment in ("// l10n: nothing", "// l10n: nope", "// l10n yes", "// not l10n: no here", "// TODO l10n: no"):
            self.assertEqual(only_literal(f'let label = "Pause button" {comment}').status, "unlocalized", comment)

    def test_the_marker_covers_the_whole_line_and_a_multi_line_literal_by_its_last_line(self) -> None:
        found = scan_snippet('let a = "Pause the speech"; let b = "Resume the speech" // l10n: no')
        self.assertEqual([l.status for l in found], ["marked", "marked"])
        multi = only_literal('let a = """\n    Some long text here.\n    """ // l10n: no')
        self.assertEqual(multi.status, "marked")

    def test_an_apple_lookup_stays_one_under_the_marker(self) -> None:
        self.assertEqual(only_literal('Text("Pause the speech") // l10n: no').status, "apple-lookup")


def only_literal(code: str):
    """The snippet's one literal, classified."""
    found = scan_snippet(code)
    assert len(found) == 1, [l.text for l in found]
    return found[0]


def only_status(code: str) -> str:
    """The status of the first literal of a snippet."""
    return scan_snippet(code)[0].status


if __name__ == "__main__":
    unittest.main()
