# Task `settings`: the Braille tab in Settings (FMT21)

- **Slug:** `braille-settings`. **Branch:** `braille/settings`, made with `git checkout -b braille/settings team/braille`.
- Read `Scripts/agents/briefs/2026-10-19/braille/common.md` first.
- **Files:** new `TextMouth/Views/Settings/BrailleSettingsView.swift`; new `TextMouthProductionTests/BrailleSettingsViewTests.swift`; in `TextMouth/Views/Settings/SettingsView.swift` only the window's size and its comment (lines 5 to 11), the `SettingsTab` enum (lines 26 to 90), and `SettingsTabContent` (lines 92 to 111); in `TextMouthProductionTests/SettingsTabFitTests.swift` only the test named in item 6; the regenerated `project.pbxproj`.
- **Read first:** `TextMouth/Models/BrailleTableCatalog.swift` (all: the tables, the codes, their words, and `BraillePreferences`); `TextMouth/ViewModels/SettingsViewModel.swift`'s `brailleTable` property; `TextMouth/Views/Transcription/TranscriptionSettingsSection.swift` lines 100 to 153 (a settings picker bound to the settings model, with its label and hint); `TextMouth/Views/Settings/SettingsView.swift` lines 1 to 111; `TextMouthProductionTests/SettingsTabFitTests.swift` lines 1 to 60.
- **Not yours:** the catalog and the setting (done), the import, and everything else.

## What to build
1. **The tab:** a `SettingsTab` case `braille`, after `text`, titled `Braille`, with the SF Symbol `hand.point.up.braille`, that scrolls as a whole (the `scrollsAsAWhole` rule already gives every tab but Text that), drawn by `BrailleSettingsView()` in `SettingsTabContent`.
2. **The window** holds ten tabs now: make `SettingsView.windowSize` 780 points wide (adding the ninth tab took it from 600 to 700), and say so in its comment: "Wide enough for the ten tabs' toolbar to show every one, so none hides in the toolbar's overflow menu (each tab added has needed about 80 points)."
3. **`BrailleSettingsView`:** a `Form` with one `Section` headed `Braille`, holding:
   1. **"Braille code"**: a `Picker` of `BrailleTableCatalog.bundledCodes`, each shown by its `name`, its selection the code of the chosen table (`settingsViewModel.brailleTable`). When the codes have more than one language, the picker's items are grouped under each language's name (`BrailleTableCatalog.languageName`), as `Section`s inside the picker; with one language (tonight), no grouping. Choosing a code chooses its table of the same contraction as the current one when it has one, else its `full` table, else its first.
   2. **"Contraction"**: a `Picker` of the chosen code's tables, each shown by its `contractionLabel` (`Uncontracted (Grade 1)`, `Contracted (Grade 2)`, `Partly contracted`), so it offers only what that code's tables have; choosing one sets `settingsViewModel.brailleTable` to its ID.
   3. **The caption** below them (`.font(.caption)`, `.foregroundStyle(.secondary)`, `.fixedSize(horizontal: false, vertical: true)`, as `FeedSettingsView`'s note is drawn): `TextMouth reads braille files (BRF, BRL, and PEF) with this code, and exports braille with it unless you choose another in the Export dialog. A book keeps the code it was imported with.`
4. **Every control is labelled and hinted,** through `.accessibilityLabel` and `.accessibilityHint`, and its value is the shown choice (a `Picker` speaks its selection itself; add nothing that repeats it):
   - Braille code: label `Braille code`; hint `The braille code TextMouth reads braille files with and writes braille in.`
   - Contraction: label `Contraction`; hint `Whether that code's braille is contracted. Contracted braille writes common words and letter groups in fewer cells.`
   Keep every one of these strings, and the caption and the section header, in one `enum BrailleSettingsWording` in `BrailleSettingsView.swift`, as `TranscriptionWording` does, and use them from there.
5. **No catalog, no crash:** if `bundledCodes` is empty (a broken bundle), the section shows only the caption and the sentence `TextMouth found no braille tables in its bundle.`, from the wording enum.
6. **`SettingsTabFitTests.testTheWindowOffersItsNineTabsInTheirOrder`** describes the window's tabs, which this task changes on purpose; this is the only existing test you change: rename it `testTheWindowOffersItsTenTabsInTheirOrder`, make its comment say ten, and put `"Braille"` after `"Text"` in its list. Every other test of that class must pass unchanged.

## Tests (`BrailleSettingsViewTests`)
Host the view as `SettingsTabFitTests` and the other settings tests host theirs, with a `SettingsViewModel` on an isolated store (`isolatedDefaults()`), and read what VoiceOver would through the accessibility tree, as the other hosted settings tests do (find one with `grep -ln "accessibilityLabel()" TextMouthProductionTests | head`).
1. The tab: `SettingsTab.braille` comes right after `.text`, titled `Braille`, its symbol exists, and it scrolls as a whole.
2. The two pickers are found by their labels, with their hints exactly; the caption's text is exactly item 3.3's.
3. With the default store, the code shown is `Unified English Braille` and the contraction `Contracted (Grade 2)`.
4. The contraction picker offers exactly `Uncontracted (Grade 1)` and `Contracted (Grade 2)` for both codes.
5. Choosing `English Braille, American Edition` while contracted chooses `en_US.tbl`; then choosing `Uncontracted (Grade 1)` chooses `en-us-g1.ctb`; each is stored (`BraillePreferences.table` reads it back).
6. Each wording constant is pinned exactly.

Run `BrailleSettingsViewTests`, `SettingsTabFitTests`, `KeyboardReachabilityTests`, and `BrailleTableCatalogTests`, and `make lint-a11y LINT_BASE=team/braille` (the diff adds controls).
