#!/bin/zsh
# Builds one of REV15's reproduction programs (repro/*.swift) as a standalone
# binary, compiled with the relocator's engine files: FineWords, TextAnchor,
# TextAnchorFinder, PatienceDiff, and PlaceRelocator, plus the stubs the
# T06 harnesses use in place of the app's other types.
#
# Usage: build-probe.sh <repro.swift> <output-binary>
#
# MODELS names the folder of engine files to compile (by default, this
# checkout's TextMouth/Models, so a worktree builds its own changed files).
# PLACE_STUBS names the place types' stubs (by default the placediff
# harness's copy); point it at a changed copy when the place types change.
# EXTRA names any further Swift files to compile, separated by spaces (a new
# pure file the relocator comes to depend on).
set -eu
here=${0:A:h}
investigate=/Users/roberteggleston/programming/ai/claude/investigate/text-anchors-2026-10-10
models=${MODELS:-$(git -C $here rev-parse --show-toplevel)/TextMouth/Models}
place_stubs=${PLACE_STUBS:-$investigate/placediff-harness/PlaceStubs.swift}
out=$2
# Swift runs top-level code only from a file named main.swift, so the
# program is compiled from a copy by that name.
work=$(mktemp -d)
trap 'rm -rf $work' EXIT
cp "$1" $work/main.swift
# Low priority: other agents may be building on this Mac.
nice -n 10 swiftc -Onone -swift-version 6 \
  $models/FineWords.swift $models/TextAnchor.swift $models/TextAnchorFinder.swift \
  $models/PatienceDiff.swift $models/PlaceRelocator.swift ${=EXTRA:-} \
  $investigate/engine-harness/Stubs.swift $place_stubs $work/main.swift -o "$out"
echo "built $out"
