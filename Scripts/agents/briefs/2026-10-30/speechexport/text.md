# speechexport/text: the reading text of a range of headings (FMT43, step 1)

Slug `speechexport-text`; branch `speechexport/text`, made with `git checkout -b speechexport/text team/speechexport`. Team `speechexport`, lead `speechexport-lead`. Follow "The worker's part" of `Scripts/agents/briefs/2026-10-30/teams-common.md`, and the build section at the end of this brief, which overrides its build-folder rules.

## Goal

FMT43 exports a text book, or a range of its headings, as spoken audio with a chapter marker per heading. This task gives the exact text the reader would speak for such a range, split into the chapters the audio file will have, made with the reader's own speech preparation (`ChapterSpeechInputs.prepare()`), never a copy of it. Pure Swift, no audio. Later tasks render it (`render`), encode it (`encode`), and run the export (`job`).

## Read first (only these, by line range)

- `TextMouth/ViewModels/ChapterSpeechCache.swift` 1-120: `ChapterSpeechInputs` and `prepare()`.
- `TextMouth/ViewModels/ReaderViewModel+Playback.swift` 1418-1475 (`ChapterSpeech`, `speechInputs(forChapterAt:)`, which you mirror) and 1700-1715 (`hasSpeakableText`).
- `TextMouth/Models/DocumentContent.swift` 140-170 and 201-300 (`allHeadings`, `Chapter`, `Chapter.wordCount(of:)`, `Heading`, `String.nonBlank`).
- `TextMouth/Services/OffsetMap.swift` 1-25 and 112-135 (`utf16Length`, `index(atUTF16Offset:)`, `ComposedOffsetMap.toModified`).
- `TextMouth/Services/BookExportService.swift` 1060-1090 (`plainText(fromMarkdown:at:title:)`).
- `TextMouth/Models/SettingsPolicy.swift` 365-395 and 40-80 (`punctuationPauseLevel`, `storedValue(in:)`); `TextMouth/ViewModels/SettingsViewModel.swift` 385-390.
- `TextMouth/Services/TextSubstitutionService.swift` 350-357 (`repeatedSymbolRule`), 615-625 (`substitutionPass`), 486-505 (`init(rules:isEnabled:preferences:)`).
- `TextMouthProductionTests/SpeechPreparationCacheTests.swift` 1019-1067 and 1085-1143: how a test builds chapters with headings, and a `ReaderViewModel` holding that content.

## What to make

### 1. `TextMouth/Services/SpeechExport/SpeechExportText.swift` (new; the folder is new too)

1. `struct SpeechPreparationSettings: Equatable, Sendable`, the three settings a chapter's speech is prepared with besides the chapter itself, as `ChapterSpeechInputs` takes them: `var repeatedSymbolRule: RepeatedSymbolRule`, `var punctuationPauseLevel: Double`, `var substitutions: SubstitutionPass`.
   - `@MainActor static func current(substitutions service: TextSubstitutionService = .shared, defaults: UserDefaults = .standard) -> SpeechPreparationSettings`: `service.repeatedSymbolRule`, `SettingsPolicy.punctuationPauseLevel.storedValue(in: defaults)`, and `service.substitutionPass`: the values `ReaderViewModel.speechInputs(forChapterAt:)` reads (the reader's pause level is the same stored value, validated the same way).
   - `func inputs(forChapterAt index: Int, of content: DocumentContent, headings: [Heading], skippedHeadingIDs: Set<String>) -> ChapterSpeechInputs`: exactly what `speechInputs(forChapterAt:)` builds: the chapter's text, and the chapter's headings (`headings.filter { $0.chapterIndex == index }`, `headings` being `content.allHeadings`) only when `skippedHeadingIDs` is not empty, else `[]`. The caller guarantees the index is valid.
2. `struct SpeechExportRange: Equatable, Sendable`: `var fromHeadingID: String?` (nil: the book's beginning, with any text before its first heading) and `var throughHeadingID: String?` (nil: the book's end); `static let wholeBook`; `var isWholeBook: Bool` (both nil).
3. `struct SpeechExportSection: Equatable, Sendable`, one chapter of the audio file:
   - `let title: String`: its heading's text on one line (each run of white space, line breaks included, made one space; trimmed), or the book's title when that leaves nothing; the book's title for the text before the first heading.
   - `let headingID: String?`: its heading's `id`; nil for the text before the first heading.
   - `let pieces: [Piece]`, with `struct Piece: Equatable, Sendable { let chapterIndex: Int; let text: String }`: one piece for each of the book's chapters (content units) the section spans, in order, each an exact slice of that chapter's prepared speech.
   - `var texts: [String]` (the pieces' texts), `var utf16Length: Int` (their total), `var wordCount: Int` (their total by `Chapter.wordCount(of:)`).
4. `enum SpeechExportText` with `enum Failure: Error, Equatable { case headingNotFound(String) }` and:
   - `static func allSections(of content: DocumentContent, range: SpeechExportRange, skippedHeadingIDs: Set<String>, settings: SpeechPreparationSettings, bookTitle: String) throws -> [SpeechExportSection]`: every section, every piece kept, even an empty one (the tests compare them with the reader's text).
   - `static func sections(...)`, the same parameters: `allSections` with each piece that holds nothing speakable (`ReaderViewModel.hasSpeakableText`) removed, then each section left with no piece removed. What an export speaks.
5. The sections, settled (`H` = `content.allHeadings`, in reading order; a heading's place is `(chapterIndex, characterOffset)`; the book's end is `(last chapter, its text's UTF-16 length)`):
   1. No chapters: `[]`.
   2. Start: `fromHeadingID == nil` gives a leading section, from `(0, 0)` to `H.first`'s place, or to the book's end when `H` is empty, titled `bookTitle`, `headingID` nil; the heading sections then start at index `s = 0`. Otherwise `s` is the index of the heading whose `id` is `fromHeadingID` (none: throw `.headingNotFound(id)`), and there is no leading section.
   3. End (exclusive) `e`: `throughHeadingID == nil` gives `H.count`. Otherwise `t` is that heading's index (none: throw), and `e` is the first index `j > t` with `H[j].level <= H[t].level`, or `H.count`: the "To" heading's section takes its subheadings with it, so a range from "Chapter 3" to "Chapter 3" is the whole chapter.
   4. Both IDs given and `s > t`: `[]` (the dialog never asks for it).
   5. For `k` in `s..<e`: a section from `H[k]`'s place to `H[k + 1]`'s place (any level), or the book's end after the last heading.
   6. A section from place `(ca, oa)` to `(cb, ob)` has a piece for each chapter `c` in `ca...cb`. Its prepared speech `p` (`settings.inputs(...).prepare()`); its start `c == ca ? p.offsetMap.toModified(oa) : 0`, its end `c == cb ? p.offsetMap.toModified(ob) : p.text.utf16Length`, both clamped to `0...p.text.utf16Length`, the end no less than the start; heading offsets are clamped to their chapter's length first. The slice is cut at UTF-16 offsets with `index(atUTF16Offset:)`.
   7. Each chapter is prepared at most once per call (sections come in reading order: keep the prepared speech of the chapters the current section spans, and drop those before it).

### 2. `TextMouth/Services/BookExportService.swift` (a small, separate commit)

Add `static func readingContent(fromMarkdown bytes: Data, at url: URL, title: String) throws -> DocumentContent`, the first two lines of `plainText(fromMarkdown:at:title:)` (`MarkdownCacheService.cacheText` then `parseMultiChapterMarkdown(_, bookTitle: title, bookAuthor: "")`), with a doc comment saying a speech export reads the book through it too, and make `plainText(fromMarkdown:at:title:)` call it. Nothing else in that file changes; `BookExportServiceTests` must pass as before.

Comment every type, property, and function, and each non-obvious block.

## Tests: `TextMouthProductionTests/SpeechExportTextTests.swift` (new, `@MainActor final class SpeechExportTextTests: XCTestCase`)

Build content with your own private helpers (copy the shapes of `SpeechPreparationCacheTests`' `chapter(sections:)` and `withReader`, never edit that file): `DocumentContent(title:author:chapters:)` from `Chapter`s whose `Heading`s have `level`, `text`, and `characterOffset` (chapterIndex 0 inside a chapter; `allHeadings` gives the book's). Pin at least:

1. `testTheWholeBookIsWhatTheReaderSpeaks`: three chapters with text before the first heading, a level-2 heading, a heading whose text spans two lines, one skipped heading, a substitution rule (`TextSubstitutionService(rules:)`), a repeated-symbol run, and pause level 2 in sandboxed preferences (`makeSandboxedPreferences`). Build the reader as `withReader` does with that defaults, rules, and skipped headings; take `settings = SpeechPreparationSettings.current(substitutions: reader.substitutionService, defaults: <that defaults>)` and `skipped = Set(book.skippedHeadingIDs ?? [])`. For each chapter `c`, the texts of `allSections(of: content, range: .wholeBook, ...)`'s pieces with `chapterIndex == c`, joined in order, equal `reader.preparedSpeech(forChapterAt: c)?.text` exactly. Close the reader in a `defer`; start no speech.
2. The sections' titles and heading IDs for the whole book: the book's title first (leading text), then each heading's.
3. A range through a level-1 heading takes its level-2 subheadings; a range through a level-2 heading stops at the next heading of level 1 or 2.
4. A range of one heading; a range from a heading leaves out the text before it; a range from the beginning through a heading has the leading section.
5. A section spanning chapters has a piece per chapter in `allSections`, and only the speakable ones in `sections`.
6. A skipped heading's section is absent from `sections`, and present with no speakable piece in `allSections`.
7. An unknown heading ID throws `.headingNotFound(id)` (for from and for through); a reversed range is `[]`; a book with no headings is one section named after the book; a book with no chapters is `[]`.
8. Titles are one line; a blank heading text takes the book's title.
9. `utf16Length`, `wordCount`, and `texts`.
10. `current(substitutions:defaults:)` reads a stored pause level (1, and 99 clamped to 3) and the service's rules (the pass of a service with substitutions off is `.none`).

## Run

`SpeechExportTextTests BookExportServiceTests export speech` (the class, the class whose file you touched, and the export and speech areas). Report the exact `Executed N tests, with S tests skipped and F failures` line.

## Do not

- Touch `ChapterSpeechCache.swift`, any `ReaderViewModel*.swift`, `SpeechService.swift`, or `AudioEngineService.swift`: you read the reader's functions and call them.
- Read or write anything under `~/.TextMouth`. Play any sound.
- Edit any `*.md` file, or any file not named here.

## Build and test (this team's rules; they override teams-common.md's build folder rules)

- The team shares ONE build folder, used by one teammate at a time: `/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-speechexport`. Never make another and never delete it: the lead deletes it at the end.
- Disk: before each build, `df -g /System/Volumes/Data` must show at least 2 GB available when that folder exists, 5 GB when it does not. Otherwise post to `speechexport-lead` and wait (`python3 .claude/skills/agent-bbs/scripts/bbs.py watch <slug> --timeout 600`), then check again.
- Build in the background, through the team's lock, which queues you behind a teammate's build (waiting is normal):
  `BBS_AGENT=<slug> /usr/bin/lockf -k /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-speechexport-build.lock python3 Scripts/test/run-area.py --derived-data /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-speechexport --log <your scratchpad>/<slug>-run.log <names>`
  Check on it no more often than every 4 minutes, with one short command.
- New files need `/opt/homebrew/bin/xcodegen generate`; commit the regenerated `TextMouth.xcodeproj/project.pbxproj` with them.
- Before reporting, `make lint-tests LINT_BASE=team/speechexport` must be clean, and the build must add no Swift warning.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
