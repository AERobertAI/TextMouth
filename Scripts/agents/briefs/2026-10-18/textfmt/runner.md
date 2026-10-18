# textfmt-runner: textutil in a watched child process (FMT13, part 1)

Slug `textfmt-runner`, branch `textfmt/runner` from `team/textfmt`. Read `Scripts/agents/briefs/2026-10-18/textfmt/shared.md` first.

## Why

The user asked for RTF, .doc, and .dot. Apple's `/usr/bin/textutil` reads RTF, RTFD, Word 97-2003 .doc (and its template .dot, by content), OpenDocument (.odt and .ott), and Word 2003 XML, and writes HTML that the existing HTML-to-Markdown path reads. Apple's readers can hang or crash, so TextMouth never runs them in its own process: it runs textutil as a child under `WatchedProcess.run`, as `OggAudioConverter` runs afconvert, so a hang costs a child and never the app or the import. This task builds that runner and nothing else: later tasks restore headings from textutil's HTML and wire the formats into the import.

## Read first (by line range)

- `TextMouth/Services/WatchedProcess.swift` lines 26-90 (`Limits`, `KillReason.words`, `Outcome`) and 230-262 (`run`). Use it as it is; never edit it (team audiofmt owns it).
- `TextMouth/Services/OggAudioConverter.swift` lines 230-258 (`Tool`) and 314-340 (`run(_:from:to:info:target:)`): the pattern to follow, a `Tool` with a command, limits, and a memory reader that tests replace.
- `TextMouth/Services/AsyncBridge.swift` lines 1-50: how synchronous code waits for async work.
- `TextMouth/Parsers/DocumentByteLimit.swift` (the whole file, 60 lines).
- `TextMouthProductionTests/OggAfconvertTests.swift` lines 234-272: stand-in tools (`/bin/sleep`, `/usr/bin/false`) with tight limits.

## Facts measured on this Mac (October 18)

- Every sample converts in 0.02 to 0.05 s, peaking at 12 to 18 MB; the research measured a 3.3 MB RTF at 1.1 s and 59 MB.
- **textutil exits 0 when it cannot read a file**: it prints "Error reading …" and writes no output file. An empty file, plain text named .rtf, and an RTF read with `-format doc` all end this way. So a missing output file after exit 0 means the file could not be read.
- Without `-format`, textutil reads random bytes named .doc as plain text and garbage comes back; with `-format doc` it refuses them. Always pass `-format`.
- Without `-nostore`, converting `rtfd/with-image.rtfd` writes `Attachment.png` beside the output. With it, nothing but the HTML is written.
- textutil writes its output file only at the end, so the watchdog's no-progress rule must not fire while it reads: give it a stall allowance equal to the time allowance.
- `-format rtfd` reads an .rtfd folder; `-format odt` reads an .ott; `-format doc` reads a .dot; `-format wordml` reads WordML under any name (all verified).

## What to build

A new file `TextMouth/Services/TextutilConverter.swift`:

1. `enum TextutilInputFormat: String, CaseIterable, Sendable` with the cases `rtf`, `rtfd`, `doc`, `odt`, `wordml`, whose raw values are textutil's `-format` names. `var documentName: String`, the words a refusal uses: "rich text document", "rich text document with attachments", "Word 97-2003 document", "OpenDocument text document", "Word 2003 XML document".
2. `enum TextutilConverter` with:
   - `enum Failure: LocalizedError, Equatable`:
     - `case unreadable(TextutilInputFormat)`: "This file could not be read as a <documentName>. It may be damaged, or another kind of file." (with "an" before "OpenDocument": write a small `article` helper, or store the article with the name; test both articles).
     - `case stopped(reason: String)`: "TextMouth stopped reading this document because <reason>." where reason is `WatchedProcess.KillReason.words` ("it ran longer than 31 seconds").
   - `struct Tool: Sendable` like `OggAudioConverter.Tool`: `command: @Sendable (_ input: URL, _ format: TextutilInputFormat, _ output: URL) -> (executable: URL, arguments: [String])`, `limits: @Sendable (_ bytes: Int64) -> WatchedProcess.Limits`, `residentMemory: @Sendable (pid_t) -> Int64?`, and `static let textutil`, running `/usr/bin/textutil` with `arguments(input:format:output:)` and `limits(forBytes:)`.
   - `static func arguments(input: URL, format: TextutilInputFormat, output: URL) -> [String]`, exactly `["-convert", "html", "-noload", "-nostore", "-format", format.rawValue, "-encoding", "UTF-8", "-output", output.path, "--", input.path]`. Comment each option's reason (no subsidiary resources and no network; no attachments written; the format never guessed; UTF-8 output; `--` so a file name starting with "-" is never an option).
   - `static func limits(forBytes bytes: Int64) -> WatchedProcess.Limits`: `maximumSeconds` 30 plus one second per million bytes; `maximumResidentBytes` 1,073,741,824 (1 GiB, as afconvert's); `maximumStalledSeconds` equal to `maximumSeconds`; the CPU allowance left at its default (four times the wall clock). Comment the measurements above as the reason.
   - `static func documentSize(of url: URL) throws -> Int64`: a file's size; for a folder (an RTFD), the sum of the sizes of the regular files anywhere inside it, never following a symbolic link.
   - `static func html(of source: URL, as format: TextutilInputFormat, workingIn folder: URL, using tool: Tool = .textutil) throws -> String`, synchronous, for the import and the Markdown cache, which run off the main thread:
     1. Size the source with `documentSize(of:)`. Zero bytes throws `FileImportError.noTextToRead` before anything runs; past the limit, `DocumentByteLimit.check(byteCount:)` throws `DocumentTooLargeError` before anything runs. Read `DocumentByteLimit.current` here, on the caller's thread, and keep it for step 5.
     2. The output is `folder/.<UUID>.textutil.html` (hidden; a constant suffix `".textutil.html"` named once). It is removed with `defer` however this function ends.
     3. Run the tool's command through `WatchedProcess.run(_:arguments:watching:limits:residentMemory:)`, waiting with `AsyncBridge.waitForResult`.
     4. The outcome: `.exited(0)` with an output file is success; `.exited(0)` with none, any other status, and `.couldNotStart` throw `.unreadable(format)`; `.killed(reason)` throws `.stopped(reason: reason.words)`. Log each failure as one import event, `DiagnosticLog.event(.import, ...)`, naming the file by `source.lastPathComponent` only: `TEXTUTIL_KILLED: <name>: <reason words>` for a kill, `TEXTUTIL_FAILED: <name>: <what happened>` ("exited with status 1", "wrote nothing", "could not start") otherwise. Find how `OGG_CONVERSION_KILLED` is logged and how `LogContentPolicyTests` checks tags, and follow both.
     5. The output's size must pass the limit kept in step 1 (`DocumentTooLargeError(limit:)` otherwise); read it and decode it as UTF-8, replacing any invalid byte rather than failing.
   - A `CancellationError` from the run passes through unchanged.

About 150 lines with comments. No other app file changes.

## Tests

A new file `TextMouthProductionTests/TextutilConverterTests.swift`, class `TextutilConverterTests` (run `xcodegen generate`). Each test works in `makeSandboxDirectory(_:)` and copies samples with `copyOfFormatSample(_:named:)`; the working folder is a sandbox folder of its own, and each test that runs a conversion ends by asserting that folder is empty.

1. Real textutil, one test per format, on copies: `rtf/headings.rtf` (the HTML holds "Harbour Notes" and `<meta name="Author" content="A. Sample">`), `rtfd/with-image.rtfd` as `.rtfd` (holds "After the picture"; no Attachment.png anywhere in the working folder), `doc/headings.doc`, `dot/headings-synthetic.dot` and `dot/libreoffice-tdf120761_zOrder.dot` as `.doc` ("Blah blah blah"), `odt/handwritten.odt` and `ott/handwritten.ott` as `.odt` (`<title>Harbour Notes</title>`), and `wordml/headings.wordml` as `.wordml`.
2. `rtf/headings.rtf` read as `.doc` throws `.unreadable(.doc)`; the sentence is pinned word for word, and so is each format's sentence (both articles).
3. An empty file throws `FileImportError.noTextToRead` and runs nothing: use a stand-in tool whose command would leave a marker file if it ran, and assert no marker.
4. A source past a bound limit (`DocumentByteLimit.$current.withValue(4)`) throws `DocumentTooLargeError(limit: 4)` and runs nothing.
5. An output past the bound limit: a stand-in `/bin/sh -c` script writing more bytes than the limit to its output, with a source within it, throws `DocumentTooLargeError` and leaves the folder empty.
6. A hang: `/bin/sleep 60` with limits of 1 second (stall allowance 5) throws `.stopped(reason: "it ran longer than 1 second")`, leaves the folder empty, and `WatchedProcess.runningChildCount` is 0 afterwards.
7. `/usr/bin/false` throws `.unreadable(format)`; a stand-in that exits 0 writing nothing throws `.unreadable(format)`; a stand-in that writes "<p>ok</p>" and exits 0 returns exactly that text.
8. `arguments(input:format:output:)` is pinned for one input, and `limits(forBytes:)` for 0 and 3,300,000 bytes (30 and 33.3 seconds, 1 GiB, stall equal to time).
9. `documentSize(of:)` of the `rtfd/with-image.rtfd` copy is the sum of its two files' sizes, and a symbolic link inside a copied folder is not followed (make one in the copy to a large file outside it).

Stand-in tools are `Tool` values built in the test with tight limits, as `OggAfconvertTests.tool(_:_:stalled:)` builds them. No test may hang: every stand-in has a limit of a few seconds.

Run `TextutilConverterTests`, `DocumentByteLimitTests`, `LogContentPolicyTests`, and `UncheckedConcurrencyPolicyTests`.

## Not yours

Headings, the import, `BookFormat`, `FileImportService`, `MarkdownCacheService`, and `BookParser` are later tasks. Do not add an RTF sniff or a password check (another task does). Do not touch `WatchedProcess.swift`.
