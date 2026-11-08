# speechexport/options: the spoken audio options of the Export dialog (FMT43, step 5a)

Slug `speechexport-options`; branch `speechexport/options`, made with `git checkout -b speechexport/options team/speechexport`. Team `speechexport`, lead `speechexport-lead`. Follow "The worker's part" of `Scripts/agents/briefs/2026-10-30/teams-common.md`, and the build section at the end of this brief, which overrides its build-folder rules.

## Goal

The Export dialog will gain a "Text as spoken audio" checkbox for a text book (FMT43). While it is checked, its options show under it: the format, the range (from a heading to a heading), a Rate slider and a Pitch slider starting at the book's own speed and pitch (the user: "put the rate and pitch in the dialog as sliders set to the current rate"; one slider each, never a stepper beside it), the voice, and one plain line about Apple's licence (the user: "yes", question 20). This task makes the options' state, their view, and every word of them, standing alone; the `dialog` task puts them in the dialog. The user is blind and uses VoiceOver and a braille display: every control has a label, a value, and a hint, and nothing is said by sight alone.

## Read first (only these, by line range)

- `TextMouth/Services/SpeechExport/SpeechExportText.swift` (`SpeechExportRange`), `SpeechExportEncoder.swift` (`SpeechExportFormat`), `SpeechExportVoice.swift` (`SpeechExportVoiceSettings`, `SpeechExportVoiceInfo`), `SpeechExportError.swift`: all on the team branch, short.
- `TextMouth/Views/Export/BookExportSheet.swift` (all, 217 lines): the dialog this view sits in, under its checkbox, indented 24 points, in a sheet at least 460 points wide.
- `TextMouth/Views/Export/BrailleExportOptionsView.swift` 1-80: how another options view of this dialog draws its pop-ups and words.
- `TextMouth/Views/Reader/ReaderView.swift` 931-990: the reader's speed and pitch sliders (the TODO A10 pattern: a visible value hidden from VoiceOver, which hears it once, as the slider's value).
- `TextMouth/Views/Reader/HeadingNavigatorView.swift` 126-141 (`accessibilityDescription(text:level:isSkipped:...)`, the headings panel's words for a heading).
- `TextMouth/Services/SpeechService.swift` 2202-2210 (`clampedPitch`, `pitchLabel`); `TextMouth/Models/SettingsPolicy.swift` 370-378; `TextMouth/ViewModels/ReaderViewModel+VoiceAndSpeed.swift` 10-12 (`speechSpeedStep`).
- `TextMouth/Services/BookExportService.swift`: `safeFileName(_:fallback:)` and `fileNameStem(for:)` (search for them).
- `TextMouthProductionTests/AccessibilityTestSupport.swift` 38-100 (`withHostedView`, `descendants(of:as:)`).

## What to make

### 1. `TextMouth/Models/SpeechExportWording.swift` (new): every word, defined once

- `formatLabel` "Format"; `formatHint` "The kind of audio file. M4B is an audiobook; M4A and MP3 play in more apps. Each has a chapter for each heading." (The format names are `SpeechExportFormat.title`.)
- `fromLabel` "From"; `fromHint` "Where the spoken audio begins: the beginning of the book, or a heading."; `beginningOfBook` "Beginning of the book".
- `throughLabel` "To"; `throughHint` "The heading whose section ends the spoken audio, with any headings under it, or the end of the book."; `endOfBook` "End of the book".
- `func headingItem(_ heading: Heading, isSkipped: Bool) -> String`: `HeadingNavigatorView.accessibilityDescription(text: <the heading's text on one line>, level: heading.level, isSkipped: isSkipped)`, as the headings panel says it ("Chapter 3 - level 1", "Skipped, Notes - level 2"). "On one line": each run of white space made one space, trimmed.
- `noHeadings` "This book has no headings, so all of it is exported."
- `rateLabel` "Rate"; `func rateValue(_ wordsPerMinute: Double) -> String` "\(Int(wordsPerMinute.rounded())) words per minute"; `rateHint` "How fast the voice speaks in the audio file. It starts at this book's speed."
- `pitchLabel` "Pitch"; `func pitchValue(_ pitch: Double) -> String` = `SpeechService.pitchLabel(pitch)`; `pitchHint` "How high the voice sounds in the audio file. It starts at this book's pitch."
- `func voiceLine(_ voice: SpeechExportVoiceInfo?) -> String`: nil gives `SpeechExportError.noVoice`'s description; a Personal Voice gives `SpeechExportError.personalVoice(name:)`'s; any other "Voice: \(name)".
- `licence` "Speech made with the Mac's voices is for your personal, non-commercial use, under Apple's licence."
- `optionsLabel` "Spoken audio options" (the options group's accessibility label).
- `wholeBookName` "Audio", `beginningName` "Beginning", `endName` "End" (the words of a file's name, below).

### 2. `TextMouth/ViewModels/SpeechExportOptionsState.swift` (new): `@MainActor final class SpeechExportOptionsState: ObservableObject`

1. `struct Choices: Equatable, Sendable { var format: SpeechExportFormat; var range: SpeechExportRange; var wordsPerMinute: Double; var pitch: Double }`.
2. `struct Item: Identifiable, Equatable { let tag: String; let title: String; var id: String { tag } }`: one pop-up item; the tag "" is the beginning in From and the end in To (no heading ID is empty).
3. `let headings: [Heading]` (the book's, `content.allHeadings`), `let skippedHeadingIDs: Set<String>`, `let voice: SpeechExportVoiceInfo?`, `let formats: [SpeechExportFormat]`.
4. `@Published var format: SpeechExportFormat` (first of `formats`, M4B); `@Published private(set) var fromHeadingID: String?` and `throughHeadingID: String?` (nil, nil: the whole book); `@Published var wordsPerMinute: Double` and `pitch: Double`, started from the given `SpeechExportVoiceSettings` and held to `SettingsPolicy.wordsPerMinute.range` and `SettingsPolicy.pitchMultiplier.range` whenever set.
5. `init(headings: [Heading], skippedHeadingIDs: Set<String>, voice: SpeechExportVoiceInfo?, settings: SpeechExportVoiceSettings, formats: [SpeechExportFormat] = SpeechExportFormat.available)`.
6. `func setFrom(_ tag: String)`: "" is the beginning (nil); an unknown tag changes nothing; a From after the To moves the To to it (a range of one heading).
7. `func setThrough(_ tag: String)`: "" is the end (nil); unknown changes nothing; a To before the From moves the From to it.
8. `var hasHeadings: Bool`; `var fromItems: [Item]`: the beginning, then every heading (`headingItem(_:isSkipped:)`, tag its `id`); `var throughItems: [Item]`: every heading, then the end; `var fromTag: String` and `throughTag: String` (the current tags).
9. `var choices: Choices`.
10. `func fileTitle(bookTitle: String) -> String`, the exported file's name without its extension: the whole book "<stem> - Audio"; one heading (From is To) "<stem> - <heading>"; otherwise "<stem> - <from heading, or Beginning> to <to heading, or End>"; `<stem>` is `BookExportService.fileNameStem(for: bookTitle)`, a heading its text on one line, and the whole name passed through `BookExportService.safeFileName(_:fallback:)` with the stem as the fallback (which also cuts it to 180 bytes).

### 3. `TextMouth/Views/Export/SpeechExportOptionsView.swift` (new): `struct SpeechExportOptionsView: View` over `@ObservedObject var state: SpeechExportOptionsState`

A `VStack(alignment: .leading, spacing: 8)`, its group `.accessibilityElement(children: .contain)` with `.accessibilityLabel(optionsLabel)`, holding in order:
1. The Format pop-up: `Picker(formatLabel, selection: $state.format)` of `state.formats` by `title`, `.pickerStyle(.menu)`, `.fixedSize()`, `.accessibilityHint(formatHint)`.
2. With headings, the From and To pop-ups (`Picker(fromLabel, selection: <a binding of fromTag through setFrom>)` of `fromItems` by `title`, tagged by `tag`; the same for To), `.pickerStyle(.menu)`, each `.frame(maxWidth: 400, alignment: .leading)` so a long heading never widens the dialog (the pop-up shortens its title; the menu shows it whole), `.accessibilityValue(<the chosen item's title>)` and its hint. Without headings, `Text(noHeadings)` in their place.
3. The Rate slider: an `HStack` of `Slider(value: $state.wordsPerMinute, in: SettingsPolicy.wordsPerMinute.range, step: ReaderViewModel.speechSpeedStep) { Text(rateLabel) }` with `.accessibilityLabel(rateLabel)`, `.accessibilityValue(rateValue(...))`, `.accessibilityHint(rateHint)`, and then `Text(rateValue(...))` with `.monospacedDigit()` and `.accessibilityHidden(true)` (sighted readers see the value; VoiceOver hears it once).
4. The Pitch slider, the same with `SettingsPolicy.pitchMultiplier.range`, step 0.1, and the pitch words.
5. `Text(voiceLine(state.voice))` and `Text(licence)`, each `.fixedSize(horizontal: false, vertical: true)`; the licence line also `.foregroundColor(.secondary)`, its words being the same for everyone. Nothing to tick.

No stepper anywhere. Comment every type, property, and function, and each non-obvious block.

## Tests: `TextMouthProductionTests/SpeechExportOptionsTests.swift` (new, `@MainActor`)

1. Every word above, exactly, including `headingItem` for a skipped level-2 heading and a two-line heading, and `voiceLine` for no voice, a Personal Voice, and a voice.
2. The state starts at M4B, the whole book, and the given speed and pitch; a speed of 900 is held to 650 and a pitch of 0.1 to 0.5; `formats` defaults to `SpeechExportFormat.available`.
3. `setFrom` past the To moves the To; `setThrough` before the From moves the From; "" means the beginning and the end; an unknown tag changes nothing; `choices` carries it all.
4. `fromItems` and `throughItems`: the beginning first, the end last, each heading's words between, tags the heading IDs.
5. `fileTitle`: whole book, one heading, a range, from the beginning, to the end, and a 300-character heading cut to 180 bytes.
6. Drawn (`withHostedView` with a state of three headings): three `NSPopUpButton`s whose items are the format titles, `fromItems`' titles, and `throughItems`' titles; two `NSSlider`s whose minimum, maximum, and value are the speed's and the pitch's. Without headings: one pop-up.
7. A heading of 300 characters leaves the view no wider than 440 points (`NSHostingView(rootView:).fittingSize.width`).
8. `make lint-a11y LINT_BASE=team/speechexport` is clean (say so in your report).

## Run

`SpeechExportOptionsTests BookExportSheetTests export sheets`. Report the exact `Executed N tests, with S tests skipped and F failures` line.

## Do not

- Touch `BookExportSheet.swift`, `BookExportModel.swift`, `BookExportService.swift`, or the SpeechExport services (the `dialog` task wires the view in).
- Add a stepper, or say anything by colour or position alone.
- Read or write anything under `~/.TextMouth`. Play any sound. Edit any `*.md` file, or any file not named here.

## Build and test (this team's rules; they override teams-common.md's build folder rules)

- The team shares ONE build folder, used by one teammate at a time: `/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-speechexport`. Never make another and never delete it: the lead deletes it at the end.
- Disk: before each build, `df -g /System/Volumes/Data` must show at least 2 GB available when that folder exists, 5 GB when it does not. Otherwise post to `speechexport-lead` and wait (`python3 .claude/skills/agent-bbs/scripts/bbs.py watch <slug> --timeout 600`), then check again.
- Build in the background, through the team's lock, which queues you behind a teammate's build (waiting is normal):
  `BBS_AGENT=<slug> /usr/bin/lockf -k /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-speechexport-build.lock python3 Scripts/test/run-area.py --derived-data /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-speechexport --log <your scratchpad>/<slug>-run.log <names>`
  Check on it no more often than every 4 minutes, with one short command.
- New files need `/opt/homebrew/bin/xcodegen generate`; commit the regenerated `TextMouth.xcodeproj/project.pbxproj` with them.
- Before reporting, `make lint-tests LINT_BASE=team/speechexport` must be clean, and the build must add no Swift warning.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
