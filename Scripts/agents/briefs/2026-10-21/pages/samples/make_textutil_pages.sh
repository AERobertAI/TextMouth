#!/bin/bash
# Makes the three page-break samples of PG11 (task `textutil`):
#   rtf/page-breaks.rtf         written here, by hand, as RTF
#   doc/page-breaks.doc         /usr/bin/textutil -convert doc    from the RTF
#   wordml/page-breaks.wordml   /usr/bin/textutil -convert wordml from the RTF
#
# The RTF holds five paragraphs:
#   1. "First page paragraph one."
#   2. "First page paragraph two runs on and" \page "continues here."
#      (a real page break in mid-paragraph: textutil's HTML joins the words)
#   3. a paragraph that begins with \pagebb (page break before): textutil
#      loses it when it reads, so it is no page
#   4. text, a \sect section break, and more text: lost the same way
#
# Usage: make_textutil_pages.sh OUTPUT_FOLDER
# OUTPUT_FOLDER receives rtf/, doc/, and wordml/ folders. Nothing else is
# touched; textutil is Apple's, at /usr/bin/textutil.
set -euo pipefail

out="${1:?usage: make_textutil_pages.sh OUTPUT_FOLDER}"
mkdir -p "$out/rtf" "$out/doc" "$out/wordml"

# The RTF, written with printf so each control word stays on its line.
{
  printf '%s\n' '{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fswiss Helvetica;}}'
  printf '%s\n' '\f0\fs24'
  printf '%s\n' 'First page paragraph one.\par'
  printf '%s\n' 'First page paragraph two runs on and\page continues here.\par'
  printf '%s\n' '\pagebb Third paragraph begins with a page break before.\par'
  printf '%s\n' 'Fourth paragraph before a section break.\sect Fifth paragraph after it.\par'
  printf '%s\n' '}'
} > "$out/rtf/page-breaks.rtf"

/usr/bin/textutil -convert doc    -output "$out/doc/page-breaks.doc"       -- "$out/rtf/page-breaks.rtf"
/usr/bin/textutil -convert wordml -output "$out/wordml/page-breaks.wordml" -- "$out/rtf/page-breaks.rtf"
