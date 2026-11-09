#!/usr/bin/env python3
"""build-reader.py OUTPUT [WORKFOLDER]: builds the reader program `fuzz.py` runs, from this repository's sources.

    python3 -I Scripts/test/kf8-fuzz/build-reader.py /path/to/reader /path/to/work

It compiles the Kindle reader, the shared HTML converter, the Markdown chapter parser, and the EPUB reader's
chapter type with `swiftc` (optimized, Swift 5 mode), linked against the packages an earlier Release build left in
`build/DerivedData/Build/Products/Release` (or under `$KF8_FUZZ_BUILD`; SwiftSoup, swift-markdown, ZIPFoundation), with `Stubs.swift` for the app
types around them. It is heavy: run it under the heavy-work lock, as every build of this Mac is:

    python3 -I build/orchestrator/followups1105/run_locked.py kf8-reader python3 -I Scripts/test/kf8-fuzz/build-reader.py ...

WORKFOLDER (default: next to OUTPUT) holds the module cache and a copy of the chapter types; its files are
overwritten by every build. Nothing is deleted.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
# The folder holding DerivedData: this repository's build folder, or another checkout's when an agent's worktree
# has none of its own (set KF8_FUZZ_BUILD to that checkout's `build` folder).
BUILD = os.environ.get("KF8_FUZZ_BUILD", ROOT + "/build")
PRODUCTS = BUILD + "/DerivedData/Build/Products/Release"
CHECKOUTS = BUILD + "/DerivedData/SourcePackages/checkouts"

PARSERS = """MOBIBook MOBIError MOBIHeaders MOBIHuffman MOBIIndex MOBIMarkup MOBIPalmDatabase MOBIParser MOBIText KF8Book KF8Layout
KFXSignature MarkupGuard MarkupScanner MarkupNesting HTMLToMarkdownConverter HTMLReadingText MarkdownParser MarkdownEmphasis MarkdownHeadingAnnotation MarkdownLiteral
MarkdownMarker MarkdownMarkerWriter MarkdownPageMarker PublicationSemantics ParserUtilities DocumentByteLimit ArchiveEntryReader
XMLInputGuard EPUBParser EPUBParser+Navigation ExtractionReport PackageSAXParser PDFExtractionDiagnostics""".split()
MODELS = ["BookPages", "EPUBMetadata"]


def main():
    output = os.path.abspath(sys.argv[1])
    work = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else os.path.dirname(output)
    os.makedirs(work + "/modcache", exist_ok=True)
    # Chapter and Heading are in DocumentContent.swift beside types that pull in the whole app: copy just them.
    text = open(ROOT + "/TextMouth/Models/DocumentContent.swift").read()
    chapters = work + "/Chapters.swift"
    with open(chapters, "w") as handle:
        handle.write("import Foundation\n" + text[text.index("struct Chapter {"):text.index("extension String {")])
    files = [f"{ROOT}/TextMouth/Parsers/{name}.swift" for name in PARSERS]
    files += [f"{ROOT}/TextMouth/Models/{name}.swift" for name in MODELS]
    files += [ROOT + "/TextMouth/Services/OffsetMap.swift", chapters, HERE + "/Main.swift", HERE + "/Stubs.swift"]
    objects = [f"{PRODUCTS}/{name}.o" for name in ("SwiftSoup", "Markdown", "cmark-gfm", "cmark-gfm-extensions", "CAtomic", "ZIPFoundation")]
    command = [
        "swiftc", "-swift-version", "5", "-I", PRODUCTS,
        "-I", CHECKOUTS + "/swift-markdown/Sources/CAtomic/include",
        "-I", CHECKOUTS + "/swift-cmark/src/include",
        "-I", CHECKOUTS + "/swift-cmark/extensions/include",
        "-I", CHECKOUTS + "/ZIPFoundation/Sources/CZLib",
        "-module-cache-path", work + "/modcache", "-parse-as-library", "-lz", "-lc++",
        "-O", "-o", output,
    ] + files + objects
    sys.exit(subprocess.run(command, check=False).returncode)


if __name__ == "__main__":
    main()
