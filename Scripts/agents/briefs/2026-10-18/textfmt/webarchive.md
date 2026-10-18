# textfmt-webarchive: the main page of a Safari web archive (FMT03, part 1)

Slug `textfmt-webarchive`, branch `textfmt/webarchive` from `team/textfmt`. Read `Scripts/agents/briefs/2026-10-18/textfmt/shared.md` first.

## Why

A Safari web archive (.webarchive) is a property list whose `WebMainResource` holds the page's bytes (`WebResourceData`), their type (`WebResourceMIMEType`), and their text encoding (`WebResourceTextEncodingName`), beside `WebSubresources` (images, scripts, style sheets) and `WebSubframeArchives` (frames). TextMouth reads only the main page and hands its HTML to the HTML path, so headings, lists, and tables arrive as in an HTML book. WebKit is never used (it would load the page's resources, and its HTML import must run on the main thread), and nothing is fetched: the archive's URLs are never followed. This task writes the reader; another task wires `.webarchive` into the import.

The sample's plist (verified with `plutil -p`): `WebMainResource` = { `WebResourceData` (3,447 bytes of HTML with h1, h2, ul, and a table), `WebResourceFrameName` "", `WebResourceMIMEType` "text/html", `WebResourceTextEncodingName` "utf-8", `WebResourceURL` "file:///index.html" }, with no subresources.

## Read first (by line range)

- `TextMouth/Parsers/DocumentByteLimit.swift` (whole file).
- `TextMouth/Parsers/TextFileDecoder.swift` lines 123-165 (`decode(_:fileName:format:)`, which reads an HTML file's own declarations and falls back to Windows-1252) and 350-360 (`encoding(forLabel:)`, private today).

## What to build

A new file `TextMouth/Parsers/WebArchiveReader.swift`, `enum WebArchiveReader`:

1. `struct MainPage: Equatable { let text: String; let isHTML: Bool }`.
2. `enum Failure: LocalizedError, Equatable`:
   - `case notAWebArchive`: "This file is not a web archive TextMouth can read. It may be damaged, or another kind of file."
   - `case notAPage(mimeType: String)`: "This web archive holds a file of the type “<type>”, not a web page or text, so it has nothing to read."
3. `static func mainPage(of url: URL) throws -> MainPage`: the bytes through `DocumentByteLimit.contents(of:)` (so an empty file has no text to read, and one past 64 MB is refused before it is read), then `mainPage(in:fileName:)`.
4. `static func mainPage(in data: Data, fileName: String) throws -> MainPage`:
   - `PropertyListSerialization.propertyList(from:options:format:)` (binary or XML property lists alike); anything that is not a dictionary with a dictionary `WebMainResource` holding `WebResourceData` as data is `.notAWebArchive`.
   - The type: `WebResourceMIMEType`, lowercased, without parameters after ";", trimmed. "text/html" and "application/xhtml+xml" are HTML; "text/plain" is text; a missing or empty type is read as HTML (Safari always writes one; an archive written by other tools may not); any other type is `.notAPage(mimeType:)` with the type as the archive wrote it, trimmed.
   - Empty `WebResourceData` throws `FileImportError.noTextToRead`.
   - The text: when `WebResourceTextEncodingName` names an encoding Core Foundation knows and the bytes decode in it, that text (a leading byte-order mark dropped, line endings normalized as `TextFileDecoder` does); otherwise `TextFileDecoder.decode(_:fileName:format:)` with format `.html` for a page and `.txt` for text. Make `TextFileDecoder.encoding(forLabel:)` internal (drop `private`), and `droppingLeadingByteOrderMarks(_:)` too if you need it, and reuse them rather than writing second copies; each one's comment says the web archive reader uses it too.
   - `WebSubresources`, `WebSubframeArchives`, and every URL in the archive are never read, decoded, or fetched; say so in the type's comment.

About 70 lines with comments, plus the access changes to `TextFileDecoder.swift`. No other app file changes.

## Tests

A new file `TextMouthProductionTests/WebArchiveReaderTests.swift`, class `WebArchiveReaderTests` (run `xcodegen generate`). Synthetic archives are built in the test with `PropertyListSerialization.data(fromPropertyList:format:options:)` from dictionaries, through one helper taking the main resource's fields.

1. The sample (a copy): an HTML page whose text holds "<h1" and "Harbour Notes" and the table's "Departs".
2. A Windows-1252 page named "windows-1252" by `WebResourceTextEncodingName`, holding "café" as the byte 0xE9, reads "café"; the same bytes with no encoding name and a `<meta charset="windows-1252">` read "café" through the decoder's own declaration rule.
3. A "text/plain; charset=utf-8" main resource reads as text (`isHTML` false).
4. An "image/png" main resource is refused with its sentence, pinned word for word with the type; so is `.notAWebArchive`'s sentence.
5. Not a property list (bytes of a ZIP header), a property list that is an array, a dictionary without `WebMainResource`, and a main resource without data are each `.notAWebArchive`.
6. An archive with a large `WebSubresources` entry and a `WebSubframeArchives` entry holding other HTML gives exactly the main page's text.
7. An XML property list reads as a binary one does.
8. An empty file and an empty main resource have no text to read; a file past a bound limit (`DocumentByteLimit.$current.withValue`) is refused with `DocumentTooLargeError`.

Run `WebArchiveReaderTests` and the text decoder's tests (`grep -l "TextFileDecoder" TextMouthProductionTests/*.swift`, by class name).

## Not yours

No `BookFormat` case, no import or cache wiring, no `Info.plist`: another task adds those. Never import WebKit.
