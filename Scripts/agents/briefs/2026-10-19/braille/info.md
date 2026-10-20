# Task `info`: Book Info and Speak Info name a braille book's code (FMT21)

- **Slug:** `braille-info`. **Branch:** `braille/info`, made with `git checkout -b braille/info team/braille`.
- Read `Scripts/agents/briefs/2026-10-19/braille/common.md` first.
- **Files:** `TextMouth/Views/Library/LibrarySheetViews.swift` (the Book Information sheet, lines 30 to 60); `TextMouth/Models/LibraryInfoWording.swift` (`BookInfoFacts`, lines 1 to 50, and `fullParts(of:now:calendar:locale:)`, lines 190 to 220); `TextMouth/Views/Library/LibraryInfoRow.swift` (where `BookInfoFacts` is made, about line 110); new `TextMouthProductionTests/BrailleBookInfoTests.swift`; the regenerated `project.pbxproj`.
- **Read first:** those lines; `BrailleTableCatalog.description(ofTableID:)` and `defaultTableID` in `TextMouth/Models/BrailleTableCatalog.swift`; `Book.brailleTable` in `TextMouth/Models/Book.swift`; one existing test of the Book Information sheet and one of Speak Info's full summary (`grep -ln "Book Information\|fullParts" TextMouthProductionTests`).
- **Not yours:** everything else.

## What to build
A braille book's code is the table it was imported with: `BrailleTableCatalog.description(ofTableID: book.brailleTable ?? BrailleTableCatalog.defaultTableID)`, such as `Unified English Braille, contracted (Grade 2)`. Write that expression once, as `var brailleCodeDescription: String?` in an extension of `Book` in `LibraryInfoWording.swift` (nil for a book that is not `.braille`), and use it in both places.
1. **Book Information:** after the `Format` row, for a braille book only, `LabeledContent("Braille Code") { Text(description) }`, which VoiceOver reads as "Braille Code, Unified English Braille, contracted (Grade 2)".
2. **Speak Info's full summary:** `BookInfoFacts` gets `var brailleCode: String? = nil` (documented as the others are), filled where the facts are made; `fullParts` adds `Braille code: Unified English Braille, contracted (Grade 2)` right after the bookmarks part when it is set. The brief summary is unchanged: it already says the format, `Braille`.

## Tests (`BrailleBookInfoTests`)
1. `brailleCodeDescription`: `en-ueb-g2.ctb` gives `Unified English Braille, contracted (Grade 2)`; `en-us-g1.ctb` gives `English Braille, American Edition, uncontracted (Grade 1)`; nil table gives the default's; a book that is not braille gives nil.
2. The full summary of a braille book holds `Braille code: Unified English Braille, contracted (Grade 2)` after its bookmarks; an EPUB's holds no braille part.
3. The Book Information sheet, hosted as the existing sheet tests host it, has a `Braille Code` row with the description for a braille book and none for an EPUB.

Run `BrailleBookInfoTests` and the existing classes that test the sheet and Speak Info (the `grep` above), and `make lint-a11y LINT_BASE=team/braille`.
