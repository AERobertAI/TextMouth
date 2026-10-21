/*
 * TextMouthBrailleProtocol.h: the line protocol between TextMouth and its
 * braille helper, TextMouthBraille, in the one place both sides read it.
 *
 * The helper's main.c includes this file, and the app imports it as the
 * Clang module TextMouthBrailleProtocol (module.modulemap beside it), so the
 * app's BrailleTranslator and the helper cannot disagree about the
 * protocol's version, its emphasis flags, or how they are written. A change
 * to the protocol is made here, with a new version in TMB_PROTOCOL_HEADER.
 *
 * Protocol 2 (October 21, 2026): every paragraph travels with the emphasis
 * of each of its characters, so that emphasis survives braille both ways
 * (the user, asked whether exported braille should mark italics and bold:
 * "it should try keeping all text formatting extractable from the braille
 * converted to the intermediate format").
 *
 * - The input file and the output file are UTF-8, every line ending in a
 *   line feed. Each begins with TMB_PROTOCOL_HEADER on a line of its own.
 * - Then come records, one for each paragraph, in the same order in both
 *   files. A record is two lines: the paragraph's text, then its emphasis
 *   codes, one code for each Unicode scalar of the text in order, or an
 *   empty line when no scalar has any emphasis.
 * - `forward` (print to braille) reads each print paragraph's codes and
 *   writes braille whose cells hold the emphasis indicators, with an empty
 *   code line. `back` (braille to print) reads braille with an empty code
 *   line (braille holds its emphasis in its cells) and writes the print
 *   with the codes of the emphasis liblouis reported.
 * - Both carry only the emphasis liblouis reads back exactly with the
 *   table, which the helper checks on each run: a table whose indicators it
 *   cannot read back, such as EBAE's, writes and reads plain braille.
 *
 * Protocol 1 (October 19, 2026) was one line for each paragraph, with no
 * header and no emphasis.
 */
#ifndef TEXTMOUTH_BRAILLE_PROTOCOL_H
#define TEXTMOUTH_BRAILLE_PROTOCOL_H

/* The first line of every input and output file: the protocol and its
   version. The helper refuses an input that does not begin with it (exit
   status 7), and the app refuses an output that does not, so a helper and
   an app built from different sources fail by name, never by misreading. */
#define TMB_PROTOCOL_HEADER "TextMouthBraille 2"

/* TextMouth's own emphasis flags, the same for every table. liblouis gives
   each table's emphasis classes bits of their own (bit 0x8 is "script" in
   the UEB tables and "transnote" in the EBAE ones), so the helper turns a
   table's bits into these by the classes' names: "italic", "bold",
   "underline", "script", and "trans1" to "trans5" (the transcriber-defined
   typefaces, one flag for all five). Any other class is not carried. */
#define TMB_EMPHASIS_ITALIC 0x01
#define TMB_EMPHASIS_BOLD 0x02
#define TMB_EMPHASIS_UNDERLINE 0x04
#define TMB_EMPHASIS_SCRIPT 0x08
#define TMB_EMPHASIS_TRANSCRIBER 0x10

/* Every flag at once: the most one code holds. */
#define TMB_EMPHASIS_ALL 0x1F

/* A character's flags are written as one ASCII character, this one plus the
   flags: "@" for none, "A" for italic, "B" for bold, "C" for both, and so on
   up to "_" for every flag. Every code is printable, and none is a line
   feed. */
#define TMB_EMPHASIS_CODE_PLAIN 0x40

#endif /* TEXTMOUTH_BRAILLE_PROTOCOL_H */
