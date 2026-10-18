#!/usr/bin/env python3
"""ogg-lint: find the lines a branch ADDS to the app that open an audio file
with one of Apple's readers, each of which must refuse every format the import
converts (Ogg first) before the reader sees it, and that guard with the
Ogg-only `isOgg`, which refuses too little.

On October 14, 2026 Apple's Vorbis decoder locked up inside AVPlayer, the app
reached 34 GB of memory, and the Mac had to be reset (AGENTS.md, B06). Since
then an Ogg file is never decoded inside TextMouth: the import converts it
with a separate tool (`ImportAudioConverter`, which converts every format in
its `convertedExtensions`), and every other path that opens an audio file has
to refuse such a file before AVFoundation or Core Audio sees it. A new call to
one of these readers is therefore always a place to review. This script finds
them in seconds, on exactly the lines a branch adds (no baseline needed), and
says what to do about each:

  * make sure the path refuses every format the import converts (see
    `AudioMediaProbe` and `ImportAudioConverter.isNeverDecodedInApp` for how
    the existing paths do), and then
  * excuse the line with a trailing `// lint-ok: <how this path refuses them>`.

A call of `isOgg(` is a finding of its own (`ogg-only-guard`): it refuses
Ogg alone, so a reader guarded by it lets every other converted format
through.

Usage (from anywhere inside the repository):
    python3 Scripts/test/ogg-lint.py                  # lines added since main
    python3 Scripts/test/ogg-lint.py --base team/testkit
    python3 Scripts/test/ogg-lint.py --all            # list every call site
    python3 Scripts/test/ogg-lint.py --selftest

Exit status: 0 no finding, 1 findings, 2 a usage or git problem. The engine is
Scripts/test/difflint.py; this file holds only the rules.
"""

import os
import sys

# The engine lives beside this script (and importing it must not leave a
# __pycache__ folder in the repository).
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import difflint  # noqa: E402
from difflint import ERROR, Rule  # noqa: E402

DEFAULT_PATHS = ["TextMouth"]

# Every line of advice ends the same way: say how the path refuses the formats.
ADVICE = ("make sure this path refuses every format the import converts "
          "(`ImportAudioConverter.isNeverDecodedInApp`, or `isConvertedAtImport` where an "
          "import's source arrives) before Apple's decoder sees it (Ogg once locked up "
          "the Mac), then add `// lint-ok: <how it refuses>`")

RULES = [
    Rule("av-url-asset", ERROR, r"(?<!\w)AVURLAsset\s*\(",
         "AVURLAsset opens a file with AVFoundation: " + ADVICE),
    Rule("av-asset-reader", ERROR, r"(?<!\w)AVAssetReader\s*\(",
         "AVAssetReader decodes a file with AVFoundation: " + ADVICE),
    Rule("av-audio-file", ERROR, r"(?<!\w)AVAudioFile\s*\(\s*forReading",
         "AVAudioFile(forReading:) decodes a file with Core Audio: " + ADVICE),
    Rule("av-player", ERROR,
         r"(?<!\w)(?:AVPlayer|AVPlayerItem|AVQueuePlayer)\s*\(\s*(?:url|asset)\b|"
         r"(?<!\w)AVAudioPlayer\s*\(\s*(?:contentsOf|data)\b",
         "this player plays a file with AVFoundation: " + ADVICE),
    Rule("audio-file-open", ERROR, r"(?<!\w)(?<!func )(?:Ext)?AudioFileOpen(?:URL|WithCallbacks)\s*\(",
         "AudioFileOpen... / ExtAudioFileOpen... decode a file with Core Audio: " + ADVICE),
    Rule("ogg-only-guard", ERROR, r"(?<!\w)(?<!func )isOgg\s*\(",
         "isOgg refuses Ogg alone, while a reader must refuse every format the import "
         "converts: guard with ImportAudioConverter.isNeverDecodedInApp (or "
         "isConvertedAtImport for an import's source), or, on a path about Ogg alone "
         "(the library's conversion of Ogg books), add `// lint-ok: <why Ogg alone>`"),
]

# (rule name, snippet that must hit, snippet that must not)
SELFTEST_CASES = [
    ("av-url-asset", "let asset = AVURLAsset(url: url)", 'let s = "AVURLAsset(url:" // AVURLAsset('),
    ("av-url-asset", "let a = try await AVURLAsset(url: base).load(.duration)", "let a = MyAVURLAsset(url: u)"),
    ("av-asset-reader", "reader = try AVAssetReader(asset: asset)", "// AVAssetReader(asset: a)"),
    ("av-audio-file", "let f = try AVAudioFile(forReading: url)", "let f = try AVAudioFile(forWriting: url, settings: s)"),
    ("av-audio-file", "let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)", "let f = FakeAVAudioFile(forReading: u)"),
    ("av-player", "let p = AVPlayer(url: u)", "let p = AVPlayer()"),
    ("av-player", "let p = try AVAudioPlayer(contentsOf: url)", "let p = AVAudioPlayerNode()"),
    ("audio-file-open", "AudioFileOpenURL(url as CFURL, .readPermission, 0, &file)", "func AudioFileOpenURLWrapper() {}\nfunc AudioFileOpenURL(_ u: URL) {}"),
    ("audio-file-open", "ExtAudioFileOpenURL(url as CFURL, &ref)", "let audioFileOpener = 1"),
    ("ogg-only-guard", "guard !ImportAudioConverter.isOgg(url) else { return }", "static func isOgg(_ url: URL) -> Bool {"),
]


def selftest():
    """Run every canned case; print failures; return True when all pass."""
    failures = []

    def rules_hit(snippet):
        hits = difflint.lint_file("snippet.swift", snippet, RULES)
        return {h.rule for h in hits if not h.suppressed}

    for rule, must_hit, must_not in SELFTEST_CASES:
        if rule not in rules_hit(must_hit):
            failures.append(f"{rule} should hit: {must_hit!r}")
        if rule in rules_hit(must_not):
            failures.append(f"{rule} should not hit: {must_not!r}")

    # Every rule has at least one case.
    covered = {case[0] for case in SELFTEST_CASES}
    for rule in RULES:
        if rule.name not in covered:
            failures.append(f"{rule.name} has no selftest case")

    # A reviewed line is excused with a reason, and only with one.
    hits = difflint.lint_file("s.swift", "let a = AVURLAsset(url: u) // lint-ok: refuses Ogg in AudioMediaProbe", RULES)
    if not (len(hits) == 1 and hits[0].suppressed):
        failures.append("lint-ok with a reason should suppress")
    hits = difflint.lint_file("s.swift", "let a = AVURLAsset(url: u) // lint-ok:", RULES)
    if not (len(hits) == 1 and not hits[0].suppressed):
        failures.append("lint-ok without a reason must not suppress")

    # Only the added lines are checked.
    hits = difflint.lint_file("s.swift", "let a = AVURLAsset(url: u)\nlet b = AVURLAsset(url: v)", RULES, only_lines={2})
    if [h.line for h in hits] != [2]:
        failures.append("only_lines should limit the check")

    for failure in failures:
        print(f"selftest FAILED: {failure}")
    if not failures:
        print(f"ogg-lint selftest: all {len(SELFTEST_CASES)} rule cases passed")
    return not failures


if __name__ == "__main__":
    sys.exit(difflint.main(
        RULES, DEFAULT_PATHS, sys.argv[1:], selftest=selftest,
        description="Find app code a branch adds that opens an audio file with an Apple "
                    "reader, each of which must refuse Ogg first."))
