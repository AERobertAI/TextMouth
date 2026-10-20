# Task `tables`: the braille tables offered, from their own metadata, and the setting that chooses one (FMT21)

- **Slug:** `braille-tables`. **Branch:** `braille/tables`, made with `git checkout -b braille/tables team/braille`.
- Read `Scripts/agents/briefs/2026-10-19/braille/common.md` first.
- **Files:** new `TextMouth/Models/BrailleTableCatalog.swift`; new `TextMouthProductionTests/BrailleTableCatalogTests.swift`; and, for the setting, only the lines named in commit 2 of `TextMouth/ViewModels/SettingsViewModel.swift`, `TextMouth/Services/ConfigService.swift`, `TextMouthProductionTests/ConfigTestSupport.swift`, `TextMouthProductionTests/ConfigSyncTests.swift`, and `TextMouthProductionTests/HostedTestIsolationSupport.swift`; the regenerated `project.pbxproj`.
- **Read first:**
  - The bundled tables' headers: `Vendor/liblouis/tables/en-ueb-g1.ctb`, `en-ueb-g2.ctb`, `en-us-g1.ctb`, and `en_US.tbl`, each to its first line that is neither blank nor a comment (the first 30 lines are enough), and `en-ueb-chardefs.uti` lines 1 to 30 (an included file, with no metadata).
  - `TextMouth/Services/BrailleTranslator.swift`: its `Tool.helper.tablesFolder` (the bundle's tables folder) and `check(table:workingIn:)`.
  - `TextMouth/Models/TranscriptionLanguage.swift` lines 1 to 25 and `TextMouth/Models/StoredPreference.swift`: the setting's model.
  - `TextMouth/ViewModels/SettingsViewModel.swift` lines 838 to 875, 975 to 990, and 1055 to 1075; `TextMouth/Services/ConfigService.swift` lines 400 to 420, 530 to 545, and 600 to 630: how `transcriptionLocale` is kept, mirrored in config.json, and read back. Follow it exactly.
- **Not yours:** the Settings tab that shows the setting is the next task; the import that stores a book's table is another. Touch nothing else.
- Two commits: the catalog with its tests, then the setting with its tests.

## Commit 1: the catalog (`BrailleTableCatalog.swift`)
The list of tables comes from the tables' own metadata, read here in Swift from the bundled files, so adding a table is only adding a resource.

1. **Metadata, as liblouis reads it** (`analyzeTable` in `Vendor/liblouis/liblouis/metadata.c`, lines 758 to 960): `static func metadata(fromHeader text: String) -> [String: String]` reads lines from the top; a blank line is skipped; a line starting with `#` is a comment, and a comment starting `#+` or `#-`, but not `#--`, is a field `key: value` (the colon may have no space after it); the first line that is neither blank nor a comment ends the header. Keys are lowercased. Values are trimmed, and runs of white space in them made one space. The first value of a key wins. `static func metadata(ofTableAt url: URL) -> [String: String]` reads at most the file's first 65,536 bytes (as UTF-8, invalid bytes replaced) and calls the first; a file that cannot be read gives `[:]`.
2. **A table:**
   ```swift
   /// A braille table TextMouth offers (FMT21), as its own metadata says.
   struct BrailleTable: Equatable, Hashable, Sendable, Identifiable {
       /// The file name in the tables folder, such as "en-ueb-g2.ctb": what a
       /// book's record keeps, and what the braille helper is given.
       let id: String
       let displayName: String   // #-display-name
       let indexName: String?    // #-index-name
       let language: String      // #+language, such as "en"
       let system: String        // #+system, such as "ueb"
       let contraction: Contraction
       let grade: String?        // #+grade, such as "2"
   }
   enum Contraction: String, Sendable { case no, partial, full }
   ```
3. **Which files are offered:** every regular file in the folder whose metadata has `type` `literary`, a `display-name`, a `language`, a `system`, and a `contraction` of `no`, `partial`, or `full`, and whose `direction` is `both` or absent (TextMouth reads braille as well as writing it, so a forward-only table is not offered). Anything else in the folder (included files, a stray file) is left out. Sorted by language, then system, then contraction in the order no, partial, full, then file name.
   - `static func tables(in folder: URL) -> [BrailleTable]`.
   - `static let bundled: [BrailleTable]`: the tables of `BrailleTranslator.Tool.helper.tablesFolder` (empty when there is none), read once.
   - `static func table(withID id: String) -> BrailleTable?`, among `bundled`.
   - `static let defaultTableID = "en-ueb-g2.ctb"`: Unified English Braille, contracted (the user's choice, October 17).
4. **Codes** (the Settings tab's "Braille code" choice):
   ```swift
   /// A braille code (FMT21): a system in a language, such as Unified
   /// English Braille, with the tables of each contraction it has.
   struct BrailleCode: Equatable, Hashable, Sendable, Identifiable {
       let id: String          // "<language>/<system>", such as "en/ueb"
       let language: String
       let system: String
       let name: String
       let tables: [BrailleTable]  // in the order no, partial, full
   }
   ```
   `static func codes(of tables: [BrailleTable]) -> [BrailleCode]` groups by language and system, in the tables' order. A code's `name`: `Unified English Braille` for system `ueb`, `English Braille, American Edition` for `ebae`; for any other system, its first table's display name with its first ` uncontracted`, ` partially contracted`, or ` contracted` removed, and its first letter capitalized (so a table added later gets a name with no code change). `static let bundledCodes = codes(of: bundled)`.
   - `static func code(of table: BrailleTable) -> BrailleCode?`, among `bundledCodes`.
   - **The language's name** for grouping: `static func languageName(_ language: String) -> String`, `Locale.current.localizedString(forLanguageCode:)` or the code itself.
5. **Words** (the listener hears them):
   - `BrailleTable.contractionLabel`: `Uncontracted (Grade 1)` for `no` (the grade from the metadata, `Uncontracted` with none), `Contracted (Grade 2)` for `full` (likewise, `Contracted` with none), `Partly contracted` for `partial`.
   - `static func description(ofTableID id: String) -> String`: the code's name, a comma, and the contraction label with its first letter lowercased, such as `Unified English Braille, contracted (Grade 2)`; for an ID no bundled table has, the ID itself. (Book Info and Speak Info use it.)

## Commit 2: the setting
1. **`enum BraillePreferences`** (in `BrailleTableCatalog.swift`) with `static let table = StoredPreference<String>(key: "brailleTable", …)`: read gives the stored ID when it names a bundled table, else `BrailleTableCatalog.defaultTableID`; write stores the ID.
   - **The table an import uses:** `@TaskLocal static var tableForImports: String? = nil` and `static func importTable() -> String`, which is `tableForImports` when a test binds one, else `table.read(from: .standard)`. The import calls it, so a hosted test chooses a book's table with `BraillePreferences.$tableForImports.withValue("en-ueb-g1.ctb") { … }` and never writes the real preferences store, which tests must not touch. Like `DocumentByteLimit.current`, it is read on the caller's thread.
2. **`SettingsViewModel`:** a `var brailleTable: String` beside `transcriptionLanguage` (lines 866 to 875), the same shape: set does nothing for an ID no bundled table has, or for the current one; else `objectWillChange.send()` and write. Add `BraillePreferences.table.key` to `servicePreferenceKeys` (line 847, in a line of its own after the transcription keys) and to `shownServicePreferenceKeys` (after `TranscriptionPreferences.offerAfterImport.key`). In the function at about line 988 add `config.brailleTable = BraillePreferences.table.read(from: preferences)` after `config.offerTranscriptionAfterImport…`; at about line 1068 add `adopt(BrailleTableCatalog.table(withID: config.brailleTable)?.id, into: BraillePreferences.table)` after the transcription lines, so an empty or unknown ID changes nothing.
3. **`ConfigService.AppConfig`:** `var brailleTable: String = ""` after `offerTranscriptionAfterImport`, documented as the others are ("The braille table TextMouth reads and writes braille with (`BraillePreferences`), by its file name, such as "en-ueb-g2.ctb". Empty keeps the current choice, as does a name no bundled table has."); decoded after `offerTranscriptionAfterImport` with `fields.value(.brailleTable, default: fallback.brailleTable) { BrailleTableCatalog.table(withID: $0)?.id ?? "" }`; and `mirrored += sameNames(["brailleTable"])`, after the transcription line, under a comment `// Braille (FMT21): the table braille files are read and written with.`
4. **The fixtures that list every setting** (these additions are the only change to existing tests that this task may make, and they make them describe the new setting): in `ConfigTestSupport.swift` after `config.offerTranscriptionAfterImport = true`, `config.brailleTable = "en-us-g1.ctb"`; in `ConfigSyncTests.swift` after `"offerTranscriptionAfterImport": true,`, `// Braille: the table braille files are read and written with.` and `"brailleTable": "en-us-g1.ctb",`; in `HostedTestIsolationSupport.swift`'s `textMouthKeys`, `"brailleTable"` after `"offerTranscriptionAfterImport"`. If another existing test fails, stop and ask.

## Tests (`BrailleTableCatalogTests`)
1. **The bundled catalog** offers exactly four tables, in this order (system `ebae` sorts before `ueb`): `en-us-g1.ctb` (English uncontracted braille as used in the U.S.; en, ebae, no, grade 1), `en_US.tbl` (English contracted braille as used in the U.S.; ebae, full, 2), `en-ueb-g1.ctb` (Unified English uncontracted braille; ueb, no, 1), `en-ueb-g2.ctb` (Unified English contracted braille; ueb, full, 2); every one passes `BrailleTranslator.check(table:workingIn:)`.
2. **Codes:** two, `English Braille, American Edition` (en/ebae) and `Unified English Braille` (en/ueb), each with an uncontracted and a contracted table; the labels are `Uncontracted (Grade 1)` and `Contracted (Grade 2)`; `description(ofTableID: "en-ueb-g2.ctb")` is `Unified English Braille, contracted (Grade 2)`, `en-us-g1.ctb` gives `English Braille, American Edition, uncontracted (Grade 1)`, and `en-xx.ctb` gives `en-xx.ctb`.
3. **Header rules,** from strings: a field after the first rule line is not read; `#--` lines and plain comments are not fields; `#+grade:2` (no space) reads; keys are lowercased; a value's inner spaces are made one; the first of two values wins.
4. **Which files are offered,** in a sandbox folder of written files: a forward-only table, a non-literary one, one with no display name, and one with an unknown contraction are left out; a partial table is offered, labelled `Partly contracted`, ordered between `no` and `full`; a table of an unknown system `xyz` whose display name is `Klingon partially contracted braille` makes a code named `Klingon braille`.
5. **The setting:** in an isolated store (`isolatedDefaults()`, as `TranscriptionSettingsTests` uses), the default is `en-ueb-g2.ctb`; a stored `en-us-g1.ctb` reads back; a stored `nonsense.ctb` reads as the default. `importTable()` inside `$tableForImports.withValue("en-us-g1.ctb")` is `en-us-g1.ctb`. Through a `SettingsViewModel` made as `TranscriptionSettingsTests.testTheLanguageFollowsSettingsAndConfigJSON` makes one: setting `brailleTable` to `en-us-g1.ctb` saves it in the store and config.json and announces; setting it to `nonsense.ctb` changes nothing; an edit of config.json to `en_US.tbl` reaches it, and one to `nonsense.ctb` leaves it.

Run `BrailleTableCatalogTests`, `ConfigSyncTests`, `TranscriptionSettingsTests`, `SettingsViewModelTests` (if it exists: `ls TextMouthProductionTests | grep -i settingsviewmodel`), and the area `settings` if `Scripts/test/areas.conf` has one (`python3 Scripts/test/run-area.py --list`).
