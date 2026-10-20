# Review fixes, part 3: books added back, the setting's store, the licenses, and the weak tests (M3, M4, L4, L5, L6, L10)

- **Slug:** `braille-fixlibrary`. **Branch:** `braille/fix-library`, made with `git checkout -b braille/fix-library team/braille`.
- Read `Scripts/agents/briefs/2026-10-19/braille/common.md` first.
- **Files (yours alone):** `TextMouth/Models/RemovedFromLibraryMarker.swift`; `TextMouth/Services/FileImportService+Packages.swift` (`reconstructedBook`, about lines 380 to 430); `TextMouth/Models/BrailleTableCatalog.swift` (`importTable()`, about line 302); `TextMouth/Views/Settings/BrailleSettingsView.swift` and `TextMouth/Views/Library/LibrarySheetViews.swift` (only as items L5 and L10 say); `project.yml` (only item L6's lines); `TextMouthProductionTests/BrailleImportTests.swift`, `BrailleSettingsViewTests.swift`, `BrailleBookInfoTests.swift`, `LibraryOnlyRemovalTests.swift` (item M3's test only), and one new `TextMouthProductionTests/BundledLicenseTests.swift`; the regenerated `project.pbxproj`. Touch nothing else.
- **Read first:** those lines; `TextMouth/App/TextMouthRuntime.swift` lines 40 to 60 and 120 to 140; `TextMouthProductionTests/LibraryOnlyRemovalTests.swift` and `RetainedPackageImportTests.swift` (how a test removes a book from the library only and adds its package back).
- One commit per item, each with its tests.

## M3: a book added back after Remove from Library Only loses its table
That removal deletes bookInfo.json and writes `RemovedFromLibraryMarker` into the package; `reconstructedBook` rebuilds the book from the marker and the content file, with no `brailleTable`, so its text is read again with the default table. An EBAE book comes back reading "He went !the store "the river inffthe night …", and Book Information names UEB.
1. `RemovedFromLibraryMarker` gains `let brailleTable: String?`, documented, set from the book in `init(book:removedAt:)`, decoded leniently (a marker written before this has none).
2. `reconstructedBook` gives the rebuilt book `brailleTable: format == .braille ? marker.brailleTable : nil`, under a comment.
3. Test (in `LibraryOnlyRemovalTests`, beside its own tests and in their way): import the Grade 2 BRF with `BraillePreferences.$tableForImports.withValue("en_US.tbl")`, note its table and its text, remove it from the library only, add its package back with the import path those tests use: the book has `en_US.tbl` and the same text.

## M4: the test that a book keeps its table cannot fail (`BrailleImportTests.swift`, about line 183)
The Grade 1 sample reads the same with `en-ueb-g1.ctb` and `en-ueb-g2.ctb`.
1. Rewrite it on the Grade 2 sample: import with `en-ueb-g2.ctb` (its text is `grade2-short.txt`'s sentences), rebuild the cache inside `$tableForImports.withValue("en-ueb-g1.ctb")`: the text is unchanged. Show in the test that it could fail: `BrailleBookReader.markdown(of:table: "en-ueb-g1.ctb")` of the same file differs (it begins `∫ boy`).
2. A new test that a rebuild reads `book.brailleTable`: import with `en-ueb-g2.ctb`, set the book's `brailleTable` to `en-ueb-g1.ctb` (the row, as the library holds it), rebuild: the text is now the Grade 1 reading.

## L4: `importTable()` reads the user's real settings in tests (`BrailleTableCatalog.swift`, about line 302)
Every other runtime read uses `TextMouthRuntime.current.preferences`, the sandboxed store in hosted tests. `importTable()` becomes `tableForImports ?? table.read(from: TextMouthRuntime.current.preferences)`, and its comment says so. Test: with nothing bound, `importTable()` is the default table (the hosted tests' store has no `brailleTable`), and after writing `en-us-g1.ctb` into `TextMouthRuntime.current.preferences` (removed again at the test's end) it is `en-us-g1.ctb`.

## L5: the Braille tab's tests (`BrailleSettingsViewTests.swift`, about lines 100, 115 to 122, and 214)
1. `popUps(in:)` calls `XCTAssertEqual` inside a `waitUntil` closure, so one passing redraw records a failure instead of retrying: make the closure return whether the condition holds, and assert after the wait.
2. `testNoCodesDrawNoPopUps` passes even when nothing draws, and never checks the sentence. Hosted SwiftUI text is not exposed in this test run, so put the choice in a pure function the view uses, such as `BrailleSettingsView.Content.of(codes:)` giving `.choices` or `.noTables(BrailleSettingsWording.noTables)`, and test that; keep the hosted check that no pop-up is drawn.

## L6: the licenses do not ship with the app (`project.yml`)
No liblouis notice or `COPYING.LESSER` is in the bundle, and LAME's licence is not either (true on main too). Put both in one folder of the app's Resources, from their vendored files, never copied in the repository: `Contents/Resources/Licenses/liblouis/` gets `Vendor/liblouis/COPYING.LESSER` and `Vendor/liblouis/README`, and `Contents/Resources/Licenses/LAME/` gets `Vendor/lame/COPYING` and `Vendor/lame/LICENSE`, as copy-files phases in the TextMouth target's sources like the tables' (`buildPhase: copyFiles: destination: resources, subpath: Licenses/liblouis`), under one comment. Test (`BundledLicenseTests`): each of the four files is in the built app at that place, the liblouis licence's text begins with `GNU LESSER GENERAL PUBLIC LICENSE`, and LAME's `COPYING` names the GNU Library General Public License. (The docs pass updates `docs/developer/third-party-code.md`; edit no `*.md`.)

## L10: weak tests
1. `BrailleImportTests.swift` about line 120 checks `contains("#")`, which cannot catch a page number left in, since liblouis reads ⠼⠁ as `1`. The sample's print has no digit at all, so assert the book's text holds no decimal digit, with a comment saying why.
2. The only test of Book Information's "Braille Code" row (`BrailleBookInfoTests.swift` about line 134) always skips. Put the row's label in one constant beside `Book.brailleCodeDescription` (such as `BrailleCodeWording.bookInfoLabel = "Braille Code"`), used by `LibrarySheetViews.swift`, and add a test of the row's words that needs no hosted sheet: the label, and the value for a braille book and for an EPUB (none).

## Tests to run
`BrailleImportTests`, `BrailleSettingsViewTests`, `BrailleBookInfoTests`, `BrailleTableCatalogTests`, `LibraryOnlyRemovalTests`, `RetainedPackageImportTests`, `BundledLicenseTests`, `SettingsTabFitTests`, and the area `settings`; then `make lint-tests LINT_BASE=team/braille` and `make lint-a11y LINT_BASE=team/braille`.
