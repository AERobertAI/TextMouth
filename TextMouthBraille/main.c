/*
 * TextMouthBraille: the helper that runs liblouis for TextMouth (FMT21).
 *
 * liblouis is C that reads untrusted braille and text, it has had
 * memory-safety bugs, and it is not thread-safe, so TextMouth never calls it
 * in its own process. It runs this small program instead, one run per book,
 * under its watchdog (WatchedProcess, with a time limit, a memory limit, an
 * output cap, and Cancel): a hang or a crash in liblouis costs one run of
 * this helper, never the app or the import. `BrailleTranslator` in the app is
 * its only caller.
 *
 * Usage:
 *   TextMouthBraille check   <tables folder> <table>
 *   TextMouthBraille forward <tables folder> <table> <input file> <output file>
 *   TextMouthBraille back    <tables folder> <table> <input file> <output file>
 *   TextMouthBraille back-liblouis <tables folder> <table> <input file> <output file>
 *
 * - `check` compiles the table, with every table it includes, and exits 0
 *   when it compiles.
 * - `forward` translates print to braille, and `back` braille to print, in
 *   the line protocol that include/TextMouthBrailleProtocol.h defines, the
 *   one place the app reads it from too (protocol 2, October 21, 2026). In
 *   short: each file begins with the protocol's header line, then holds one
 *   record for each paragraph, in the same order in both files; a record is
 *   the paragraph's text on one line and its emphasis codes on the next, one
 *   code for each character, or an empty line for none. `forward` writes the
 *   emphasis it is given into the braille as the table's indicators, and
 *   `back` reports the emphasis it reads from the indicators: EBAE's signs
 *   and UEB's terminators it finds itself, before liblouis reads the braille
 *   (`read_braille`, October 24, 2026). `forward` carries only the classes
 *   liblouis reads back exactly with the table (`check_readable`), and
 *   `back` reports those and the EBAE signs it reads itself. Braille, in and
 *   out, is Unicode braille patterns (U+2800 to U+28FF), the blank cell
 *   U+2800 included; a space is never braille.
 * - `back-liblouis`, which only tests run, reads as `back` does, but by
 *   liblouis alone, without the reading passes, exactly as `back` read
 *   before them: the tests compare the passes' words with liblouis's own
 *   reading of the same braille.
 *
 * The table is a bare file name, such as en-ueb-g2.ctb, of a table in the
 * tables folder: the app bundle's own (Contents/Resources/liblouis/tables),
 * or, for one of this Mac's VoiceOver tables (October 20, 2026), the Mac's
 * own liblouis folder, which the app names (BrailleTableCatalog
 * .macTablesFolder) and reads in place. The folder, the input, and the
 * output are absolute paths. The helper changes into the folder, sets
 * LOUIS_TABLEPATH to "." and loads the table by its bare name, so liblouis
 * resolves every include there, no path it sees holds a comma (it splits
 * paths at commas), and it never reads a table installed elsewhere on the
 * Mac (see TABLESDIR in Vendor/liblouis/config.h). One run reads one folder,
 * never both, so a Mac table's includes come from the Mac's own liblouis
 * version. It then changes into /var/empty.
 *
 * Exit status: 0 done; 1 the arguments are wrong; 2 the table cannot be
 * loaded (no such table in the folder, or it does not compile); 3 the input
 * cannot be read; 4 the input is not what the mode takes (not UTF-8, a NUL,
 * a line longer than MAX_LINE characters, a record without its code line,
 * codes that do not fit their text, or in `back` a character that is not a
 * braille cell or any code at all); 5 liblouis could not translate a line;
 * 6 the output cannot be written; 7 the input does not begin with this
 * protocol's header, as an input written for another version would not.
 * The helper prints nothing to its standard output, and liblouis's own
 * errors go to standard error, which TextMouth discards.
 *
 * This file is TextMouth's own, under TextMouth's MIT License. It only calls
 * liblouis's public API (liblouis.h); no code of liblouis's tools/ folder,
 * which is GPL 3, is used.
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "liblouis.h"
#include "include/TextMouthBrailleProtocol.h"

/* The exit statuses, as the header comment lists them. */
enum {
	EXIT_DONE = 0,
	EXIT_USAGE = 1,
	EXIT_TABLE = 2,
	EXIT_INPUT_UNREADABLE = 3,
	EXIT_INPUT_INVALID = 4,
	EXIT_TRANSLATION = 5,
	EXIT_OUTPUT = 6,
	EXIT_PROTOCOL = 7,
};

/* The most characters one input line may hold. TextMouth sends paragraphs
   of about 4,000 characters at most (it splits longer ones at blank cells
   or spaces), so this only bounds a line that something else wrote. */
#define MAX_LINE 1000000

/* The first and last Unicode braille patterns. */
#define BRAILLE_FIRST 0x2800u
#define BRAILLE_LAST 0x28FFu

/* The output room tried first, as a multiple of the input's length, and the
   most it may grow to. Braille to print grows (one cell can be a whole word,
   "the"); print to braille grows less, but a character no table defines
   becomes liblouis's escape for it, several cells long. */
#define FIRST_ROOM 8
#define MOST_ROOM 64

/* The cells of output room that must be left over for a translation to be
   believed (see `translate`): more than the 10 cells of the longest escape
   liblouis writes for a character a table lacks. */
#define MIN_SPARE_ROOM 16

/* A braille cell by its dots: the Unicode braille pattern U+2800 plus a bit
   for each dot, dot 1 the lowest, so that CELL(D4 | D6), dots 4 and 6, is ⠨
   (U+2828). */
#define D1 0x01u
#define D2 0x02u
#define D3 0x04u
#define D4 0x08u
#define D5 0x10u
#define D6 0x20u
#define CELL(dots) ((widechar)(BRAILLE_FIRST | (dots)))

/* The cells the reading passes look for (`read_ebae`, `read_ueb`), named by
   their dots, with what each is in EBAE and UEB. */
#define CELL_BLANK CELL(0)
#define CELL_2 CELL(D2)                 /* ⠂ comma in EBAE; UEB's word indicator after a prefix */
#define CELL_3 CELL(D3)                 /* ⠄ apostrophe; UEB's terminator after a prefix */
#define CELL_4 CELL(D4)                 /* ⠈ UEB's script prefix */
#define CELL_5 CELL(D5)                 /* ⠐ UEB's fourth transcriber prefix */
#define CELL_6 CELL(D6)                 /* ⠠ capital sign */
#define CELL_34 CELL(D3 | D4)           /* ⠌ after ⠸, EBAE's slash */
#define CELL_35 CELL(D3 | D5)           /* ⠔ "in" in contracted EBAE, as in ⠔⠖ "into" */
#define CELL_36 CELL(D3 | D6)           /* ⠤ hyphen; two make EBAE's dash */
#define CELL_23 CELL(D2 | D3)           /* ⠆ "be", as in ⠆⠋ "before" */
#define CELL_124 CELL(D1 | D2 | D4)     /* ⠋ the letter f */
#define CELL_134 CELL(D1 | D3 | D4)     /* ⠍ the letter m; after ⠨, liblouis's "µ" */
#define CELL_256 CELL(D2 | D5 | D6)     /* ⠲ EBAE's period, and "dd" inside a word */
#define CELL_56 CELL(D5 | D6)           /* ⠰ the letter sign */
#define CELL_45 CELL(D4 | D5)           /* ⠘ UEB's bold prefix */
#define CELL_46 CELL(D4 | D6)           /* ⠨ EBAE's emphasis sign; UEB's italic prefix */
#define CELL_156 CELL(D1 | D5 | D6)     /* ⠱ after ⠸, the end of EBAE's computer braille */
#define CELL_235 CELL(D2 | D3 | D5)     /* ⠖ "to", joined to its word, in contracted EBAE */
#define CELL_236 CELL(D2 | D3 | D6)     /* ⠦ EBAE's opening quotation mark */
#define CELL_346 CELL(D3 | D4 | D6)     /* ⠬ after ⠸, the start of EBAE's computer braille */
#define CELL_356 CELL(D3 | D5 | D6)     /* ⠴ "by", joined to its word, in contracted EBAE */
#define CELL_456 CELL(D4 | D5 | D6)     /* ⠸ EBAE's bold prefix; UEB's underline prefix */
#define CELL_2356 CELL(D2 | D3 | D5 | D6) /* ⠶ EBAE's parenthesis; UEB's passage indicator */
#define CELL_3456 CELL(D3 | D4 | D5 | D6) /* ⠼ number sign; in UEB's transcriber prefixes */
/* The cells of contracted braille's wordsigns EBAE writes together (`fix_ebae_cells`). */
#define CELL_AND CELL(D1 | D2 | D3 | D4 | D6)      /* ⠯ "and" */
#define CELL_FOR CELL(D1 | D2 | D3 | D4 | D5 | D6) /* ⠿ "for" */
#define CELL_OF CELL(D1 | D2 | D3 | D5 | D6)       /* ⠷ "of" */
#define CELL_THE CELL(D2 | D3 | D4 | D6)           /* ⠮ "the" */
#define CELL_WITH CELL(D2 | D3 | D4 | D5 | D6)     /* ⠾ "with" */
#define CELL_A CELL(D1)                            /* ⠁ "a" */

/*
 * The braille codes whose emphasis signs the helper reads itself, before
 * liblouis reads a paragraph back (October 24, 2026; `read_braille`):
 * - EBAE, English Braille American Edition, as BANA writes it (the Library
 *   of Congress's Instruction Manual for Braille Transcribing, fifth
 *   edition, lesson 15): ⠨ before a word, ⠨⠨ before the first word of a
 *   passage of four words or more and ⠨ before its last, and the
 *   termination sign ⠠⠄ where emphasis ends inside a word; bold, where it
 *   is told apart, as ⠸⠨, ⠸⠨⠨, and ⠸⠨ (BANA's Braille Formats, 2011).
 *   liblouis 3.39.0 reads these signs wrongly (`read_ebae`).
 * - UEB, Unified English Braille: after each typeform's prefix (⠨ italic,
 *   ⠘ bold, ⠸ underline, ⠈ script, and five transcriber-defined ones), ⠂
 *   for a word, ⠆ for a symbol, ⠶ for a passage, and ⠄ for the terminator.
 *   liblouis reads them, but misreads the contraction just before a
 *   terminator (`read_ueb`).
 * Which code, if either, a table writes each class in is found by
 * translating (`detect_codes`), never by its name.
 */
enum { CODE_NONE = 0, CODE_EBAE, CODE_UEB };

/*
 * The emphasis classes the protocol carries, by the names liblouis's tables
 * give them, each with TextMouth's flag for it and its prefix in the two
 * codes' signs (none when the code has no sign of its own for the class).
 * liblouis numbers a table's classes in the order the table declares them,
 * so the same bit means "script" in one table and "transnote" in another;
 * names are the only thing tables share. The five transcriber-defined
 * typefaces share one flag, and a flag written forward goes to the first
 * readable class listed with it ("trans1" for TMB_EMPHASIS_TRANSCRIBER in
 * UEB). Classes not listed here, such as UEB's "transnote" (a transcriber's
 * note, no typeface of the print), are not carried: liblouis still reads
 * their indicators as indicators, and the text they mark comes back plain.
 */
static const struct {
	const char *name;
	unsigned flag;
	/* EBAE's sign for one word, which also comes before a passage's last
	   word; the passage's own sign is this and ⠨. */
	widechar ebae[2];
	int ebae_length;
	/* UEB's prefix, which ⠂, ⠆, ⠶, or ⠄ follows. */
	widechar ueb[2];
	int ueb_length;
} EMPHASIS_CLASSES[] = {
		{"italic", TMB_EMPHASIS_ITALIC, {CELL_46}, 1, {CELL_46}, 1},
		{"bold", TMB_EMPHASIS_BOLD, {CELL_456, CELL_46}, 2, {CELL_45}, 1},
		{"underline", TMB_EMPHASIS_UNDERLINE, {0}, 0, {CELL_456}, 1},
		{"script", TMB_EMPHASIS_SCRIPT, {0}, 0, {CELL_4}, 1},
		{"trans1", TMB_EMPHASIS_TRANSCRIBER, {0}, 0, {CELL_4, CELL_3456}, 2},
		{"trans2", TMB_EMPHASIS_TRANSCRIBER, {0}, 0, {CELL_45, CELL_3456}, 2},
		{"trans3", TMB_EMPHASIS_TRANSCRIBER, {0}, 0, {CELL_456, CELL_3456}, 2},
		{"trans4", TMB_EMPHASIS_TRANSCRIBER, {0}, 0, {CELL_5, CELL_3456}, 2},
		{"trans5", TMB_EMPHASIS_TRANSCRIBER, {0}, 0, {CELL_46, CELL_3456}, 2},
};
#define EMPHASIS_CLASS_COUNT (sizeof EMPHASIS_CLASSES / sizeof EMPHASIS_CLASSES[0])

/*
 * The loaded table's emphasis: for each class of EMPHASIS_CLASSES, its
 * typeform bit in the table (0 when the table has no such class), the code
 * the table writes it in (`detect_codes`), and whether it is read back
 * exactly with this table (`check_readable`). Both directions carry only
 * the readable classes: `forward` writes no indicator `back` could not
 * read, and `back` reports no emphasis it may have misread.
 */
typedef struct {
	formtype bit[EMPHASIS_CLASS_COUNT];
	int code[EMPHASIS_CLASS_COUNT];
	int readable[EMPHASIS_CLASS_COUNT];
	/* For a table that writes EBAE's signs: for each of the four signs
	   (EBAE_ITALIC_WORD to EBAE_BOLD_PASSAGE) and each six-dot cell, whether
	   liblouis, reading as `back` read before the EBAE pass, writes nothing
	   for the sign before that cell (`find_strippable_signs`). */
	unsigned char strippable[4][64];
	/* For a table that writes EBAE's signs: whether it is contracted EBAE,
	   which reads the six word signs ⠯ ⠿ ⠷ ⠮ ⠾ ⠁ alone as "and", "for", "of",
	   "the", "with", and "a" (`reads_word_signs`), and so is given the
	   fixes of `fix_ebae_cells`. */
	int contracted;
} table_emphasis;

/* The EBAE signs, as indexes of `table_emphasis.strippable`: italic's word
   sign ⠨ and passage sign ⠨⠨, and bold's ⠸⠨ and ⠸⠨⠨. */
enum { EBAE_ITALIC_WORD = 0, EBAE_ITALIC_PASSAGE, EBAE_BOLD_WORD, EBAE_BOLD_PASSAGE };

/*
 * A translation liblouis made (`translate`), or a reading pass made with it
 * (`read_braille`), which `free_translation` frees.
 */
typedef struct {
	/* The output: braille forward, print back. */
	widechar *chars;
	/* How many characters `chars` holds. */
	int length;
	/* Back, when the emphasis is read: each output character's typeform, in
	   the table's bits; otherwise NULL. */
	formtype *typeform;
	/* Back: for each output character, the input cell where the rule that
	   wrote it began. */
	int *input_pos;
	/* Back: for each input cell, the first output character of the rule it
	   is in, or of the next rule when its own wrote none, at most the last
	   character (liblouis's outputPos). */
	int *output_pos;
} translation;

/*
 * Decodes the UTF-8 bytes `bytes[0..count)` into `out`, which holds at least
 * `count` widechars (a UTF-8 sequence is never shorter than the character it
 * encodes). Stores the number of characters in `*length`. Returns 0 for
 * well-formed UTF-8 with no NUL, -1 for anything else: a stray continuation
 * byte, a truncated or overlong sequence, a surrogate, a value past
 * U+10FFFF, or a NUL, at which liblouis would stop reading.
 */
static int
decode_utf8(const unsigned char *bytes, size_t count, widechar *out, size_t *length) {
	size_t i = 0, n = 0;
	while (i < count) {
		unsigned char lead = bytes[i];
		uint32_t value;
		size_t extra;
		if (lead == 0) return -1;
		if (lead < 0x80) {
			value = lead;
			extra = 0;
		} else if ((lead & 0xE0) == 0xC0) {
			value = lead & 0x1F;
			extra = 1;
		} else if ((lead & 0xF0) == 0xE0) {
			value = lead & 0x0F;
			extra = 2;
		} else if ((lead & 0xF8) == 0xF0) {
			value = lead & 0x07;
			extra = 3;
		} else {
			return -1;
		}
		/* The sequence's last byte must be inside the line. */
		if (i + extra >= count) return -1;
		for (size_t k = 1; k <= extra; k++) {
			unsigned char next = bytes[i + k];
			if ((next & 0xC0) != 0x80) return -1;
			value = (value << 6) | (next & 0x3F);
		}
		/* The shortest form only, no surrogates, nothing past U+10FFFF. */
		if ((extra == 1 && value < 0x80) || (extra == 2 && value < 0x800) ||
				(extra == 3 && value < 0x10000) || (value >= 0xD800 && value <= 0xDFFF) ||
				value > 0x10FFFF)
			return -1;
		out[n++] = (widechar)value;
		i += extra + 1;
	}
	*length = n;
	return 0;
}

/*
 * Writes the characters `chars[0..count)` to `file` as UTF-8, then a line
 * feed. Returns 0, or -1 when the file cannot take them. A character that
 * cannot be one (past U+10FFFF, or a surrogate) is written as U+FFFD, the
 * replacement character, so a line is never lost to one bad character.
 */
static int
write_line(FILE *file, const widechar *chars, size_t count) {
	for (size_t i = 0; i < count; i++) {
		uint32_t value = chars[i];
		unsigned char bytes[4];
		size_t size;
		if (value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) value = 0xFFFD;
		if (value < 0x80) {
			bytes[0] = (unsigned char)value;
			size = 1;
		} else if (value < 0x800) {
			bytes[0] = (unsigned char)(0xC0 | (value >> 6));
			bytes[1] = (unsigned char)(0x80 | (value & 0x3F));
			size = 2;
		} else if (value < 0x10000) {
			bytes[0] = (unsigned char)(0xE0 | (value >> 12));
			bytes[1] = (unsigned char)(0x80 | ((value >> 6) & 0x3F));
			bytes[2] = (unsigned char)(0x80 | (value & 0x3F));
			size = 3;
		} else {
			bytes[0] = (unsigned char)(0xF0 | (value >> 18));
			bytes[1] = (unsigned char)(0x80 | ((value >> 12) & 0x3F));
			bytes[2] = (unsigned char)(0x80 | ((value >> 6) & 0x3F));
			bytes[3] = (unsigned char)(0x80 | (value & 0x3F));
			size = 4;
		}
		if (fwrite(bytes, 1, size, file) != size) return -1;
	}
	return fputc('\n', file) == EOF ? -1 : 0;
}

/*
 * Writes the code line of a record to `file`: the code of each of
 * `flags[0..count)`, TextMouth's flags for each character, then a line
 * feed; or the line feed alone when every flag is 0 (or `flags` is NULL), as
 * the protocol writes a text with no emphasis. Returns 0, or -1 when the
 * file cannot take them.
 */
static int
write_codes(FILE *file, const unsigned char *flags, size_t count) {
	int any = 0;
	for (size_t i = 0; flags != NULL && i < count && !any; i++) any = flags[i] != 0;
	for (size_t i = 0; any && i < count; i++)
		if (fputc(TMB_EMPHASIS_CODE_PLAIN + flags[i], file) == EOF) return -1;
	return fputc('\n', file) == EOF ? -1 : 0;
}

/*
 * Whether the line `line[0..bytes)`, as `getline` read it, is the protocol's
 * header, with or without its line feed.
 */
static int
is_header(const char *line, size_t bytes) {
	size_t length = strlen(TMB_PROTOCOL_HEADER);
	if (bytes > 0 && line[bytes - 1] == '\n') bytes--;
	return bytes == length && memcmp(line, TMB_PROTOCOL_HEADER, length) == 0;
}

/*
 * Whether `name` is a bare file name that can only name a file inside the
 * tables folder: not empty, not starting with a dot, and holding no slash
 * and no comma (liblouis reads a comma as the start of another table).
 */
static int
is_bare_table_name(const char *name) {
	if (name[0] == '\0' || name[0] == '.') return 0;
	return strchr(name, '/') == NULL && strchr(name, ',') == NULL;
}

/*
 * Makes `folder` the only place liblouis reads tables from, and checks that
 * `name` is a regular file in it. Returns 0, or -1 when the name is not a bare
 * file name, the folder cannot be entered, or the name is no regular file
 * there.
 *
 * liblouis splits both a list of tables and LOUIS_TABLEPATH at commas, so a
 * path that holds one (TextMouth.app in a folder named "Apps, old") would
 * make every table unloadable. So the helper changes into the folder, sets
 * LOUIS_TABLEPATH to "." and lets liblouis resolve the bare table name, and
 * every table it includes, against it: no path liblouis sees holds a comma,
 * and it reads no table installed elsewhere on the Mac (see TABLESDIR in
 * Vendor/liblouis/config.h). `leave_tables_folder` changes out again.
 */
static int
enter_tables_folder(const char *folder, const char *name) {
	struct stat info;
	if (!is_bare_table_name(name)) return -1;
	if (chdir(folder) != 0 || setenv("LOUIS_TABLEPATH", ".", 1) != 0) return -1;
	if (stat(name, &info) != 0 || !S_ISREG(info.st_mode)) return -1;
	return 0;
}

/*
 * Changes into /var/empty, which macOS keeps empty and no one can write to.
 * Once `lou_checkTable` has loaded the table, liblouis keeps it by its name
 * and reads no file again, so the tables folder is no longer needed. This
 * keeps a helper built with code coverage (as the hosted tests' builds are)
 * from leaving the profile it writes on exit, default.profraw, in the app
 * bundle. The input and output paths are absolute (see `main`), so they are
 * still found.
 */
static void
leave_tables_folder(void) {
	(void)chdir("/var/empty");
}

/* Frees what `t` holds, and empties it. */
static void
free_translation(translation *t) {
	free(t->chars);
	free(t->typeform);
	free(t->input_pos);
	free(t->output_pos);
	memset(t, 0, sizeof *t);
}

/*
 * Translates `in[0..length)` with the table named `table` (already loaded by
 * `main`, which liblouis keeps by that name), forward (print to braille) or
 * back, into `*result`, which the caller frees with `free_translation`.
 * Returns 1, or 0 when liblouis fails, leaving `*result` empty. The braille
 * side is Unicode braille: dotsIO with ucBrl makes liblouis read each input
 * cell's dots from the low byte of U+28xx and write each output cell as
 * U+2800 plus its dots, with no display table in between.
 *
 * Emphasis travels in typeform arrays of the table's own bits:
 * - Forward, `in_typeform` holds each input character's emphasis, or is
 *   NULL for a paragraph with none, which then translates exactly as it did
 *   before protocol 2. liblouis writes the indicators the table's rules
 *   give, such as UEB's word, passage, and terminator indicators, and
 *   nothing from a table with no rules for the class (the bits it is given
 *   are only of readable classes: `typeform_for_flags`). liblouis also WRITES
 *   into the array it is given, a '0' or '8' for each output cell
 *   (lou_translateString.c), however long the output is, so the array
 *   passed is a fresh copy as long as the output's room, never the
 *   caller's.
 * - Back, when `reads_emphasis` is set, liblouis is given an array, one
 *   entry for each output character, which it fills with the emphasis it
 *   finds, and which is returned in `result->typeform`. liblouis takes an
 *   emphasis indicator, such as UEB's italic word indicator ⠨⠂, as an
 *   indicator only when there is such an array to record it in; without one
 *   it writes the cells as its notation for cells it cannot translate
 *   ("\46/,"), which a listener would hear mid-sentence. Every caller reads
 *   the emphasis.
 *
 * Back, liblouis also says where each output character came from
 * (`result->input_pos`) and where each input cell went
 * (`result->output_pos`), which the reading passes map emphasis through
 * (`give_cells_emphasis`). Asking for them changes nothing in the
 * translation (lou_backTranslateString is lou_backTranslate without them).
 *
 * liblouis answers an output that fills its room in one of three ways: it
 * stops early, using only part of the input; it fails; or, when the text
 * holds a character the table lacks, it CUTS the output at the room, and
 * still reports success with all of the input used. The reviewer saw the
 * third: 100 emoji at the first room of 864 cells gave ok=1, used=100,
 * written=864, where 1,664 cells of room gave all 900 cells; 20 CJK
 * characters at a room of 64 also reported used=20. So a translation counts
 * only when it succeeded, used all of the input, and left at least
 * MIN_SPARE_ROOM cells of the room unwritten: a cut output ends within one
 * escape of the room's end, and the longest escape liblouis writes for one
 * character is 10 cells, so 16 spare cells prove nothing was cut. Otherwise
 * the line is translated again with twice the room, from FIRST_ROOM to
 * MOST_ROOM times the input's length; a line that never leaves 16 cells over
 * is a failure (exit status 5). Back-translation is held to the same rule.
 */
static int
translate(const char *table, int forward, const widechar *in, const formtype *in_typeform, int length,
		int reads_emphasis, translation *result) {
	const int mode = dotsIO | ucBrl;
	memset(result, 0, sizeof *result);
	for (int multiple = FIRST_ROOM; multiple <= MOST_ROOM; multiple *= 2) {
		/* MAX_LINE * MOST_ROOM + 64 is far below INT_MAX. */
		int room = length * multiple + 64;
		int wants_typeform = forward ? in_typeform != NULL : reads_emphasis;
		translation t = {0};
		int used = length;
		int written = room;
		int ok;
		t.chars = malloc((size_t)room * sizeof(widechar));
		/* calloc: the entries past the input's (forward) start plain. */
		t.typeform = wants_typeform ? calloc((size_t)room, sizeof(formtype)) : NULL;
		if (!forward) {
			t.input_pos = malloc((size_t)room * sizeof(int));
			t.output_pos = malloc(((size_t)length + 1) * sizeof(int));
		}
		if (t.chars == NULL || (wants_typeform && t.typeform == NULL) ||
				(!forward && (t.input_pos == NULL || t.output_pos == NULL))) {
			free_translation(&t);
			return 0;
		}
		if (forward && in_typeform != NULL)
			memcpy(t.typeform, in_typeform, (size_t)length * sizeof(formtype));
		ok = forward ? lou_translateString(table, in, &used, t.chars, &written, t.typeform, NULL, mode)
					 : lou_backTranslate(table, in, &used, t.chars, &written, t.typeform, NULL,
							   t.output_pos, t.input_pos, NULL, mode);
		if (ok && used >= length && room - written >= MIN_SPARE_ROOM) {
			t.length = written;
			/* Forward, the typeform array was only liblouis's to write in. */
			if (forward) {
				free(t.typeform);
				t.typeform = NULL;
			}
			*result = t;
			return 1;
		}
		free_translation(&t);
	}
	return 0;
}

/*
 * Whether every character of `chars[0..count)` is a Unicode braille cell,
 * which is all `back` takes: an ASCII space would be read as dot 6, since
 * dotsIO takes a cell's dots from its low byte.
 */
static int
all_braille(const widechar *chars, size_t count) {
	for (size_t i = 0; i < count; i++)
		if (chars[i] < BRAILLE_FIRST || chars[i] > BRAILLE_LAST) return 0;
	return 1;
}

/*
 * The table's typeform bits for TextMouth's flags `flags`: for each flag,
 * the bit of the first readable class EMPHASIS_CLASSES lists with it, and
 * nothing for a flag with no readable class, so a table liblouis cannot read
 * back, or that has no such class, writes plain braille (October 21, 2026,
 * review E2: EBAE's indicators, written, came back as stray periods and
 * ">" signs, and some of this Mac's tables' as ";", "_", or U+007F around a
 * word, so reading TextMouth's own export changed its words).
 */
static formtype
typeform_for_flags(const table_emphasis *emphasis, unsigned flags) {
	formtype typeform = 0;
	unsigned done = 0;
	for (size_t i = 0; i < EMPHASIS_CLASS_COUNT; i++) {
		unsigned flag = EMPHASIS_CLASSES[i].flag;
		if (!emphasis->readable[i]) continue;
		if ((flags & flag) && !(done & flag)) typeform |= emphasis->bit[i];
		done |= flag;
	}
	return typeform;
}

/*
 * TextMouth's flags for the table's typeform bits `typeform`, as `back`
 * reports them: the readable classes, and the classes the EBAE pass reads
 * (`read_ebae`), which are not readable, since liblouis's EBAE writes some
 * signs (⠨ before a to j) that the pass leaves to it, but whose signs the
 * pass reads only where they cannot be anything else.
 */
static unsigned
flags_for_typeform(const table_emphasis *emphasis, formtype typeform) {
	unsigned flags = 0;
	for (size_t i = 0; i < EMPHASIS_CLASS_COUNT; i++)
		if ((emphasis->readable[i] || emphasis->code[i] == CODE_EBAE) && (typeform & emphasis->bit[i]))
			flags |= EMPHASIS_CLASSES[i].flag;
	return flags;
}

/* Whether the table writes any class in `code` (`detect_codes`). */
static int
uses_code(const table_emphasis *emphasis, int code) {
	for (size_t i = 0; i < EMPHASIS_CLASS_COUNT; i++)
		if (emphasis->code[i] == code) return 1;
	return 0;
}

/*
 * Whether `cells[i..end)` begins with the `length` cells of `sign`.
 */
static int
has_cells(const widechar *cells, int i, int end, const widechar *sign, int length) {
	return length > 0 && i + length <= end &&
			memcmp(cells + i, sign, (size_t)length * sizeof(widechar)) == 0;
}

/*
 * Puts `length` cells of `cells` at `kept[count..]`, each with the typeform
 * `emphasis` at the same place in `bits`, and returns the new count.
 */
static int
keep(widechar *kept, formtype *bits, int count, const widechar *cells, int length, formtype emphasis) {
	for (int k = 0; k < length; k++) {
		kept[count] = cells[k];
		bits[count++] = emphasis;
	}
	return count;
}

/*
 * Splits the emphasis of the characters `t->chars[first..last)`, which one
 * rule wrote from the cells `cells[start..next)` read together, where the
 * cells' emphasis changes (`give_cells_emphasis`). At each cell b whose
 * emphasis differs from the cell's before it, the cells from the start of
 * their word to b are translated alone; when what they give begins the
 * word's characters and ends inside the rule's, the rule's characters from
 * there on take b's emphasis. Otherwise nothing is split there, and those
 * characters keep the emphasis before.
 *
 * A cell liblouis reads as an indicator, which writes nothing, begins the
 * rule after it (liblouis's inputPos names the first cell of all those
 * that wrote nothing before a rule), so an indicator's emphasis is never
 * taken for a change inside the rule before it.
 */
static void
split_rule(const char *table, const widechar *cells, const formtype *bits, const translation *t,
		formtype *typeform, int first, int last, int start, int next) {
	/* The word's first cell, and its first character. */
	int word = start;
	int word_first = first;
	while (word > 0 && cells[word - 1] != CELL_BLANK) word--;
	while (word_first > 0 && t->input_pos[word_first - 1] >= word) word_first--;
	for (int b = start + 1; b < next; b++) {
		translation prefix;
		int split;
		if (bits[b] == bits[b - 1]) continue;
		if (!translate(table, 0, cells + word, NULL, b - word, 1, &prefix)) continue;
		split = word_first + prefix.length;
		if (split > first && split < last &&
				memcmp(t->chars + word_first, prefix.chars, (size_t)prefix.length * sizeof(widechar)) == 0)
			for (int k = split; k < last; k++) typeform[k] = bits[b];
		free_translation(&prefix);
	}
}

/*
 * Gives each character of `t`, the translation back of `cells[0..n)` whose
 * cell k is in the emphasis `bits[k]` (the table's bits), the emphasis of
 * the cell where the rule that wrote it began (`t->input_pos`), and splits
 * a rule that read cells of different emphasis together where the emphasis
 * changes (`split_rule`): contracted UEB reads "can't" from ⠉⠄⠞ as one
 * rule, whose "can" may be italic and "'t" not. The typeform liblouis read
 * from the indicators is replaced, but for its bits in `from_liblouis`,
 * which are kept: the classes no pass reads, such as EBAE's underline,
 * which liblouis writes and reads back itself. Returns 0 when memory runs
 * out.
 */
static int
give_cells_emphasis(const char *table, const widechar *cells, const formtype *bits, int n,
		formtype from_liblouis, translation *t) {
	formtype *typeform = calloc((size_t)t->length + 1, sizeof *typeform);
	int first = 0;
	if (typeform == NULL) return 0;
	while (first < t->length) {
		int start = t->input_pos[first];
		int last = first;
		int next;
		while (last < t->length && t->input_pos[last] == start) last++;
		next = last < t->length ? t->input_pos[last] : n;
		for (int k = first; k < last; k++) typeform[k] = start >= 0 && start < n ? bits[start] : 0;
		if (start >= 0 && next <= n && next - start > 1)
			split_rule(table, cells, bits, t, typeform, first, last, start, next);
		first = last;
	}
	for (int k = 0; t->typeform != NULL && k < t->length; k++) typeform[k] |= t->typeform[k] & from_liblouis;
	free(t->typeform);
	t->typeform = typeform;
	return 1;
}

/*
 * Reads the cells a reading pass kept, `kept[0..count)`, cell k in the
 * emphasis `bits[k]`, back to print into `*result`, the end of both passes
 * (`read_ebae`, `read_ueb`): liblouis reads them with a typeform array, and
 * each character takes its cell's emphasis, keeping liblouis's own bits in
 * `from_liblouis` (`give_cells_emphasis`). Returns 1, or 0 when a
 * translation fails, leaving `*result` empty.
 */
static int
read_kept_cells(const char *table, const widechar *kept, const formtype *bits, int count,
		formtype from_liblouis, translation *result) {
	int ok = translate(table, 0, kept, NULL, count, 1, result) &&
			give_cells_emphasis(table, kept, bits, count, from_liblouis, result);
	if (!ok) free_translation(result);
	return ok;
}

/* MARK: - Which code a table writes */

/* The words `detect_codes` translates: lowercase words that every bundled
   table writes the same way alone and emphasized, with a blank cell between
   each two, the second word the one emphasized alone, and the second to the
   fifth the longest passage tried (EBAE's shortest, four words). */
static const char CODE_PROBE[] = "alpha bravo charlie delta echo foxtrot";
#define CODE_PROBE_WORDS 6

/*
 * Cells `matches_with_signs` expects in the emphasized braille that the plain
 * braille lacks: `length` cells of `cells`, before the plain cell at `at`
 * (the plain braille's length, for the end).
 */
typedef struct {
	int at;
	widechar cells[4];
	int length;
} added_sign;

/*
 * Whether `actual[0..actual_length)` is `plain[0..n)` with exactly the cells
 * of each of `signs[0..count)` added, and nothing else; `signs` are in the
 * order of their places.
 */
static int
matches_with_signs(const widechar *actual, int actual_length, const widechar *plain, int n,
		const added_sign *signs, int count) {
	int a = 0;
	int next = 0;
	for (int i = 0; i <= n; i++) {
		for (; next < count && signs[next].at == i; next++)
			for (int k = 0; k < signs[next].length; k++)
				if (a >= actual_length || actual[a++] != signs[next].cells[k]) return 0;
		if (i < n && (a >= actual_length || actual[a++] != plain[i])) return 0;
	}
	return a == actual_length;
}

/*
 * An added sign before the plain cell `at`: the `length` cells of `prefix`,
 * then `last` unless it is 0.
 */
static added_sign
sign_with(int at, const widechar *prefix, int length, widechar last) {
	added_sign sign = {at, {0}, 0};
	for (int k = 0; k < length && k < 3; k++) sign.cells[sign.length++] = prefix[k];
	if (last != 0) sign.cells[sign.length++] = last;
	return sign;
}

/*
 * The emphasized braille of the code probe, the class with the table's bit
 * `bit` on its words `first` to `last` and the spaces between them, into
 * `*result`. Returns 1, or 0 when liblouis fails.
 */
static int
translate_marked_probe(const char *table, formtype bit, int first, int last, translation *result) {
	widechar probe[sizeof CODE_PROBE];
	formtype marks[sizeof CODE_PROBE];
	int word = 0;
	int length = (int)strlen(CODE_PROBE);
	for (int i = 0; i < length; i++) {
		probe[i] = (widechar)(unsigned char)CODE_PROBE[i];
		if (CODE_PROBE[i] == ' ') word++;
		marks[i] = word >= first && word <= last && !(CODE_PROBE[i] == ' ' && word == first) ? bit : 0;
	}
	return translate(table, 1, probe, marks, length, 0, result);
}

/*
 * Whether `table` writes class `index` in `code`'s signs, given the code
 * probe's plain braille `plain[0..n)`, whose words begin at `starts` and end
 * before `ends`. The probe, translated with the class on its second word,
 * then on a passage beginning there, must be the plain braille with only the
 * code's signs added:
 * - EBAE: the word's sign before the word; the passage's sign (the word's
 *   sign and ⠨) before the first of four words, and the word's sign before
 *   the last.
 * - UEB: the word indicator (prefix and ⠂) before the word; the passage
 *   indicator (prefix and ⠶) before the first of three words, and the
 *   terminator (prefix and ⠄) after the last.
 */
static int
writes_code(const char *table, const table_emphasis *emphasis, size_t index, int code,
		const widechar *plain, int n, const int *starts, const int *ends) {
	int ebae = code == CODE_EBAE;
	const widechar *prefix = ebae ? EMPHASIS_CLASSES[index].ebae : EMPHASIS_CLASSES[index].ueb;
	int length = ebae ? EMPHASIS_CLASSES[index].ebae_length : EMPHASIS_CLASSES[index].ueb_length;
	int last = ebae ? 4 : 3;
	added_sign word[1];
	added_sign passage[2];
	translation marked;
	int matches;
	if (length == 0 || emphasis->bit[index] == 0) return 0;
	word[0] = sign_with(starts[1], prefix, length, ebae ? 0 : CELL_2);
	passage[0] = sign_with(starts[1], prefix, length, ebae ? CELL_46 : CELL_2356);
	passage[1] = ebae ? sign_with(starts[last], prefix, length, 0)
					  : sign_with(ends[last], prefix, length, CELL_3);
	if (!translate_marked_probe(table, emphasis->bit[index], 1, 1, &marked)) return 0;
	matches = matches_with_signs(marked.chars, marked.length, plain, n, word, 1);
	free_translation(&marked);
	if (!matches || !translate_marked_probe(table, emphasis->bit[index], 1, last, &marked)) return 0;
	matches = matches_with_signs(marked.chars, marked.length, plain, n, passage, 2);
	free_translation(&marked);
	return matches;
}

/*
 * Whether `table` reads the cell `cell` standing alone, with no emphasis
 * read, as one ASCII punctuation character, such as English EBAE's ⠨ as ".",
 * and not as a letter of its own.
 */
static int
reads_cell_as_punctuation(const char *table, widechar cell) {
	translation print;
	int punctuation;
	if (!translate(table, 0, &cell, NULL, 1, 0, &print)) return 0;
	punctuation = print.length == 1 && print.chars[0] > ' ' && print.chars[0] < 0x7F &&
			!(print.chars[0] >= '0' && print.chars[0] <= '9') &&
			!((print.chars[0] | 0x20) >= 'a' && (print.chars[0] | 0x20) <= 'z');
	free_translation(&print);
	return punctuation;
}

/*
 * Whether `table` reads each of the six cells that stand for the words "and"
 * ⠯, "for" ⠿, "of" ⠷, "the" ⠮, "with" ⠾, and "a" ⠁, alone, as that word:
 * the table is contracted (grade 2) braille, whose wordsigns EBAE writes
 * together, "ofthe" as ⠷⠮, with no space (`fix_ebae_cells`).
 */
static int
reads_word_signs(const char *table) {
	static const struct {
		widechar cell;
		const char *word;
	} signs[] = {{CELL_AND, "and"}, {CELL_FOR, "for"}, {CELL_OF, "of"}, {CELL_THE, "the"},
			{CELL_WITH, "with"}, {CELL_A, "a"}};
	for (size_t k = 0; k < sizeof signs / sizeof signs[0]; k++) {
		widechar cell = signs[k].cell;
		translation print;
		size_t length = strlen(signs[k].word);
		int same;
		if (!translate(table, 0, &cell, NULL, 1, 0, &print)) return 0;
		same = (size_t)print.length == length;
		for (size_t c = 0; same && c < length; c++) same = print.chars[c] == (widechar)signs[k].word[c];
		free_translation(&print);
		if (!same) return 0;
	}
	return 1;
}

/*
 * Fills `emphasis->strippable`: for each EBAE sign and each six-dot cell X,
 * whether liblouis, reading with a typeform array as `back` read before the
 * EBAE pass, reads the sign and X, standing alone, exactly as it reads X
 * alone, so that it drops the sign there and the pass may leave it out
 * without changing a word. Where liblouis reads the cells as a sign of
 * print ("=" for ⠨⠅, ">" for ⠨⠂, "µ" for ⠨⠍) or as a period before a word
 * (⠨ before a to j), the sign is not stripped (`ebae_signs_at`).
 */
static void
find_strippable_signs(const char *table, table_emphasis *emphasis) {
	static const widechar signs[4][3] = {
			{CELL_46}, {CELL_46, CELL_46}, {CELL_456, CELL_46}, {CELL_456, CELL_46, CELL_46}};
	static const int lengths[4] = {1, 2, 2, 3};
	memset(emphasis->strippable, 0, sizeof emphasis->strippable);
	for (int dots = 1; dots < 64; dots++) {
		widechar next = CELL((unsigned)dots);
		translation alone;
		if (!translate(table, 0, &next, NULL, 1, 1, &alone)) continue;
		for (int sign = 0; sign < 4; sign++) {
			widechar both[4];
			translation read;
			memcpy(both, signs[sign], (size_t)lengths[sign] * sizeof(widechar));
			both[lengths[sign]] = next;
			if (!translate(table, 0, both, NULL, lengths[sign] + 1, 1, &read)) continue;
			emphasis->strippable[sign][dots] = read.length == alone.length &&
					memcmp(read.chars, alone.chars, (size_t)read.length * sizeof(widechar)) == 0;
			free_translation(&read);
		}
		free_translation(&alone);
	}
}

/*
 * Sets `emphasis->code` for each class the table has: the code whose signs
 * liblouis writes it in (`writes_code`), or none. Found by translating, as
 * `check_readable` judges, so that one of this Mac's tables is judged by
 * what its own rules write: one that writes EBAE's or UEB's signs is read
 * with that code's pass, and any other as before.
 */
static void
detect_codes(const char *table, table_emphasis *emphasis) {
	widechar probe[sizeof CODE_PROBE];
	int length = (int)strlen(CODE_PROBE);
	int starts[CODE_PROBE_WORDS];
	int ends[CODE_PROBE_WORDS];
	int words = 0;
	translation plain;
	for (int i = 0; i < length; i++) probe[i] = (widechar)(unsigned char)CODE_PROBE[i];
	if (!translate(table, 1, probe, NULL, length, 0, &plain)) return;
	/* The plain braille's words: one blank cell between each two, as many
	   as the probe's, or the table is not judged. */
	for (int i = 0; i <= plain.length && words <= CODE_PROBE_WORDS; i++) {
		int blank = i == plain.length || plain.chars[i] == CELL_BLANK;
		int begins = i < plain.length && !blank && (i == 0 || plain.chars[i - 1] == CELL_BLANK);
		if (begins && words < CODE_PROBE_WORDS) starts[words] = i;
		if (begins) words++;
		if (blank && (i == 0 || plain.chars[i - 1] == CELL_BLANK)) words = CODE_PROBE_WORDS + 1;
		if (blank && words >= 1 && words <= CODE_PROBE_WORDS) ends[words - 1] = i;
	}
	for (size_t k = 0; words == CODE_PROBE_WORDS && k < EMPHASIS_CLASS_COUNT; k++) {
		if (writes_code(table, emphasis, k, CODE_EBAE, plain.chars, plain.length, starts, ends))
			emphasis->code[k] = CODE_EBAE;
		else if (writes_code(table, emphasis, k, CODE_UEB, plain.chars, plain.length, starts, ends))
			emphasis->code[k] = CODE_UEB;
	}
	free_translation(&plain);
	/* EBAE's signs mean emphasis only where ⠨ is no letter: English EBAE
	   reads ⠨ alone as a period, but the Bharati tables, which also write
	   italic as ⠨ before a word, read it as the letter "kh" (ख, ਖ), and a pass
	   there would drop the letter from every word it begins (review,
	   October 24, 2026). */
	if (uses_code(emphasis, CODE_EBAE) && !reads_cell_as_punctuation(table, CELL_46))
		for (size_t k = 0; k < EMPHASIS_CLASS_COUNT; k++)
			if (emphasis->code[k] == CODE_EBAE) emphasis->code[k] = CODE_NONE;
	if (uses_code(emphasis, CODE_EBAE)) {
		find_strippable_signs(table, emphasis);
		emphasis->contracted = reads_word_signs(table);
	}
}

/* MARK: - EBAE's cells */

/* Letter cells: a to z, by their dots. */
static const unsigned LETTER_DOTS[26] = {D1, D1 | D2, D1 | D4, D1 | D4 | D5, D1 | D5, D1 | D2 | D4,
		D1 | D2 | D4 | D5, D1 | D2 | D5, D2 | D4, D2 | D4 | D5, D1 | D3, D1 | D2 | D3, D1 | D3 | D4,
		D1 | D3 | D4 | D5, D1 | D3 | D5, D1 | D2 | D3 | D4, D1 | D2 | D3 | D4 | D5, D1 | D2 | D3 | D5,
		D2 | D3 | D4, D2 | D3 | D4 | D5, D1 | D3 | D6, D1 | D2 | D3 | D6, D2 | D4 | D5 | D6,
		D1 | D3 | D4 | D6, D1 | D3 | D4 | D5 | D6, D1 | D3 | D5 | D6};

/* The cell of the lowercase letter `letter` ('a' to 'z'). */
static widechar
letter_cell(char letter) {
	return CELL(LETTER_DOTS[letter - 'a']);
}

/* Whether `cell` is one of the letters a to z. */
static int
is_letter_cell(widechar cell) {
	for (size_t k = 0; k < sizeof LETTER_DOTS / sizeof LETTER_DOTS[0]; k++)
		if (cell == CELL(LETTER_DOTS[k])) return 1;
	return 0;
}

/* Whether `cell` is one of the six cells that stand for "and", "for", "of",
   "the", "with", and "a" (`reads_word_signs`). */
static int
is_word_sign_cell(widechar cell) {
	return cell == CELL_A || cell == CELL_THE || cell == CELL_WITH || cell == CELL_OF || cell == CELL_AND ||
			cell == CELL_FOR;
}

/*
 * Whether `cell` is a punctuation mark that may end a word in EBAE: a
 * comma ⠂, semicolon ⠆, colon ⠒, period ⠲, exclamation mark ⠖, question
 * mark or opening quotation mark ⠦, closing quotation mark ⠴, parenthesis
 * ⠶, apostrophe ⠄, or hyphen ⠤. None of them is a letter or a word sign.
 */
static int
is_trailing_mark(widechar cell) {
	return cell == CELL_2 || cell == CELL_23 || cell == CELL(D2 | D5) || cell == CELL_256 ||
			cell == CELL_235 || cell == CELL_236 || cell == CELL_356 || cell == CELL_2356 ||
			cell == CELL_3 || cell == CELL_36;
}

/* Whether `cell` may open a word before its first letter: an emphasis
   sign ⠨ or ⠸, an opening quotation mark ⠦, a parenthesis ⠶, or a dash ⠤. */
static int
is_leading_mark(widechar cell) {
	return cell == CELL_46 || cell == CELL_456 || cell == CELL_236 || cell == CELL_2356 || cell == CELL_36;
}

/* Whether `cells[i..end)` are all marks that may end a word. */
static int
only_trailing_marks(const widechar *cells, int i, int end) {
	for (; i < end; i++)
		if (!is_trailing_mark(cells[i])) return 0;
	return 1;
}

/* MARK: - Reading EBAE */

/*
 * The length of the opening punctuation at `cells[i..end)` that may stand
 * before an EBAE sign, with more of its word after it: an opening
 * parenthesis ⠶ or bracket ⠠⠶, an opening quotation mark ⠦ or ⠠⠦, or a
 * dash ⠤⠤, which come before the sign in that order (EBAE 15.1a(2), 15.7:
 * ⠦⠨⠠⠓⠑⠇⠏⠖⠴ for "Help!" emphasized in quotation marks); 0 for none.
 */
static int
opening_punctuation(const widechar *cells, int i, int end) {
	static const struct {
		widechar cells[2];
		int length;
	} marks[] = {
			{{CELL_2356}, 1},
			{{CELL_6, CELL_2356}, 2},
			{{CELL_236}, 1},
			{{CELL_6, CELL_236}, 2},
			{{CELL_36, CELL_36}, 2},
	};
	for (size_t k = 0; k < sizeof marks / sizeof marks[0]; k++)
		if (has_cells(cells, i, end, marks[k].cells, marks[k].length) && i + marks[k].length < end)
			return marks[k].length;
	return 0;
}

/*
 * The table's bit of the class with TextMouth's flag `flag` when the table
 * writes that class in EBAE; 0 otherwise.
 */
static formtype
ebae_bit(const table_emphasis *emphasis, unsigned flag) {
	for (size_t k = 0; k < EMPHASIS_CLASS_COUNT; k++)
		if (EMPHASIS_CLASSES[k].flag == flag && emphasis->code[k] == CODE_EBAE) return emphasis->bit[k];
	return 0;
}

/*
 * The length of contracted EBAE's "to" ⠖, "into" ⠔⠖, or "by" ⠴ at
 * `cells[i..end)`, with its capital sign, when it is joined to the word
 * after it, which may have a sign of its own (EBAE 15.1c(2): ⠨⠖⠠⠛⠑⠕⠗⠛⠑ is
 * "to" emphasized before George, and ⠖⠨⠞⠪⠝ "to" before town emphasized);
 * 0 otherwise. At a word's start these cells are nothing else: "ff" is only
 * inside a word, "was" (⠴) stands alone, and the punctuation they also are
 * never begins a word (in uncontracted EBAE, where they are only
 * punctuation, no word begins with them either). The word after it may be
 * another joined one ("into into mother", ⠔⠖⠔⠖⠐⠍), but never a comma or an
 * apostrophe.
 */
static int
joined_word(const widechar *cells, int i, int end) {
	int k = i;
	if (k < end && cells[k] == CELL_6) k++;
	if (k + 1 < end && cells[k] == CELL_35 && cells[k + 1] == CELL_235)
		k += 2;
	else if (k < end && (cells[k] == CELL_235 || cells[k] == CELL_356))
		k++;
	else
		return 0;
	if (k >= end || cells[k] == CELL_2 || cells[k] == CELL_3) return 0;
	return k - i;
}

/*
 * The EBAE signs found at one place (`ebae_signs_at`): how many cells they
 * take, 0 for none; the table's bits of the classes they mark the word
 * with (a word's sign, or the sign before a passage's last word); and those
 * of the passages they open.
 */
typedef struct {
	int length;
	formtype word;
	formtype opens;
	/* Whether the signs stand before ⠍, where liblouis reads them as "µ",
	   and are read as signs all the same (`is_sign_before_m_word`). */
	int mu;
} ebae_signs;

/*
 * Whether the word of `cells[0..end)` that holds the cell `at` follows a
 * number: the blank-delimited word before it begins with the number sign ⠼,
 * after any marks that open it ("5 µm").
 */
static int
follows_number(const widechar *cells, int at) {
	int start = at;
	int end;
	while (start > 0 && cells[start - 1] != CELL_BLANK) start--;
	end = start;
	while (end > 0 && cells[end - 1] == CELL_BLANK) end--;
	if (end == start) return 0;
	start = end;
	while (start > 0 && cells[start - 1] != CELL_BLANK) start--;
	while (start < end && is_leading_mark(cells[start])) start++;
	return start < end && cells[start] == CELL_3456;
}

/*
 * Whether the EBAE sign at `cells[sign..next)` is a sign, and not the "µ"
 * liblouis reads ⠨⠍ as: it begins its word, and ⠍ begins two cells or more
 * (before any mark that may end the word) that are no unit after a number.
 * A word of one letter, such as "m" alone, a word after a number ("5 µm",
 * "10 µmol"), and a sign inside a word ("km/µs") stay "µ". An emphasized word of two or more letters that
 * begins with m ("mama", "my") reads as emphasis, which is what it is far
 * more often (the Life of Pi braille read italic "mama" as "µama", November
 * 13, 2026); a micro unit that EBAE writes ⠨⠍ for, with no number before it,
 * reads as emphasis, as it cannot be told from it.
 */
static int
is_sign_before_m_word(const widechar *cells, int sign, int next, int end) {
	int start = sign;
	if (cells[next] != CELL_134 || next + 1 >= end || is_trailing_mark(cells[next + 1])) return 0;
	/* The sign begins the word, after the marks that open it. */
	while (start > 0 && cells[start - 1] != CELL_BLANK) start--;
	for (int k = start; k < sign; k++)
		if (!is_leading_mark(cells[k]) && cells[k] != CELL_6) return 0;
	return !follows_number(cells, next);
}

/*
 * Whether the pass may read the EBAE sign `sign` (EBAE_ITALIC_WORD to
 * EBAE_BOLD_PASSAGE) as a sign before the cell `next`: liblouis, reading as
 * `back` read before the pass, writes nothing for it there
 * (`find_strippable_signs`), so leaving it out keeps the words liblouis
 * reads, and only the emphasis is added.
 */
static int
may_strip(const table_emphasis *emphasis, int sign, widechar next) {
	return next >= BRAILLE_FIRST && next - BRAILLE_FIRST < 64 &&
			emphasis->strippable[sign][next - BRAILLE_FIRST];
}

/*
 * The EBAE signs at a place a sign may stand, `cells[i..end)` (the rest of
 * a word), while the passages `open` are open (`strip_ebae_word`):
 * italic's ⠨ and, for a passage, ⠨⠨; bold's ⠸⠨ and ⠸⠨⠨ (a bold passage
 * opens only where none is open). Signs must have a cell of their word after
 * them, and are read only where liblouis drops them anyway (`may_strip`):
 * liblouis's EBAE writes "=" as ⠨⠅, ">" as ⠨⠂, "µ" as ⠨⠍, and a period
 * before a word as ⠨, which it reads back as a period before the letters a
 * to j ("⠨⠉⠁⠞" is ".cat"), and such cells cannot be told from a sign and a
 * word (review, October 24, 2026). BANA's EBAE has no sign for bold italic,
 * so liblouis's (bold's sign, then italic's) is not read: more ⠨ after
 * bold's or italic's sign than a passage's is left to liblouis.
 *
 * A stated limit (verifier, October 24, 2026): liblouis writes a period
 * before a word as ⠨ wherever the word begins, and reads it back as nothing
 * before a capital or a letter past j, as it reads a sign there. So such a
 * period is read as a sign: ".NET" (⠨⠠⠠⠝⠑⠞) reads as "NET" in italic, and
 * ".the" as "the". The words are still liblouis's own, which lose the
 * period too; only the emphasis is wrong.
 */
static ebae_signs
ebae_signs_at(const table_emphasis *emphasis, const widechar *cells, int i, int end, formtype open) {
	const ebae_signs none = {0, 0, 0, 0};
	ebae_signs found = {0, 0, 0, 0};
	formtype italic = ebae_bit(emphasis, TMB_EMPHASIS_ITALIC);
	formtype bold = ebae_bit(emphasis, TMB_EMPHASIS_BOLD);
	int has_bold = bold != 0 && i + 1 < end && cells[i] == CELL_456 && cells[i + 1] == CELL_46;
	int first = has_bold ? i + 1 : i;
	int run = 0;
	int sign;
	while (first + run < end && cells[first + run] == CELL_46) run++;
	found.length = first - i + run;
	if (run == 0 || run > 2 || i + found.length >= end) return none;
	if (has_bold) {
		if (run == 2 && (open & bold)) return none;
		sign = run == 2 ? EBAE_BOLD_PASSAGE : EBAE_BOLD_WORD;
	} else {
		if (italic == 0) return none;
		sign = run == 2 ? EBAE_ITALIC_PASSAGE : EBAE_ITALIC_WORD;
	}
	if (!may_strip(emphasis, sign, cells[i + found.length])) {
		/* ⠨⠍ beginning a word of letters is a sign, not liblouis's "µ":
		   the sign is read, and the safety net reads it left out too
		   (`strip_ebae_word`, `read_ebae`). */
		if (is_sign_before_m_word(cells, i, i + found.length, end)) {
			found.mu = 1;
		} else {
			/* A word sign that cannot be told from a print sign, while its
			   class's passage is open, still closes the passage: it is left
			   for liblouis, as a sign of no length, and the passage ends
			   with the word, rather than running on to the paragraph's end. */
			found.length = 0;
			found.word = sign == EBAE_ITALIC_WORD ? italic & open : sign == EBAE_BOLD_WORD ? bold & open : 0;
			return found.word != 0 ? found : none;
		}
	}
	if (sign == EBAE_ITALIC_PASSAGE) found.opens = italic;
	if (sign == EBAE_ITALIC_WORD) found.word = italic;
	if (sign == EBAE_BOLD_PASSAGE) found.opens = bold;
	if (sign == EBAE_BOLD_WORD) found.word = bold;
	return found;
}

/*
 * The length of EBAE's dash ⠤⠤ or slash ⠸⠌ at `cells[i..end)`, either of
 * which ends a word's emphasis, a sign standing after it for the word that
 * follows (EBAE 15.1a); 0 for neither.
 */
static int
dash_or_slash(const widechar *cells, int i, int end) {
	if (i + 1 >= end) return 0;
	if ((cells[i] == CELL_36 && cells[i + 1] == CELL_36) ||
			(cells[i] == CELL_456 && cells[i + 1] == CELL_34))
		return 2;
	return 0;
}

/* Whether `cell` is one of the letters a to j, EBAE's digits after its
   number sign. */
static int
is_digit_cell(widechar cell) {
	static const unsigned digits[] = {D1, D1 | D2, D1 | D4, D1 | D4 | D5, D1 | D5, D1 | D2 | D4,
			D1 | D2 | D4 | D5, D1 | D2 | D5, D2 | D4, D2 | D4 | D5};
	for (size_t k = 0; k < sizeof digits / sizeof digits[0]; k++)
		if (cell == CELL(digits[k])) return 1;
	return 0;
}

/*
 * The length of liblouis's sign inside a passage's last word, at
 * `cells[i..end)`: the word's sign, again, of a class in `closing`, which
 * liblouis writes before whatever of the word is not emphasized (".FIVE.1"
 * for "*one two three four five*,", and ".FI.VE" when the passage ends with
 * the "fi" of "five"), where EBAE writes nothing or the termination sign.
 * It ends the emphasis.
 * 0 for none: ⠨ is no sign where it is a decimal point (in a number, before
 * a digit, EBAE 15.8d) or begins one of contracted EBAE's ⠨⠙ "ound", ⠨⠑
 * "ance", ⠨⠎ "less", ⠨⠝ "sion", and ⠨⠞ "ount", nor before a cell where
 * liblouis does not drop it (`may_strip`): before a comma ⠂ it reads ⠨ as
 * ">", which is left, as liblouis reads it.
 */
static int
extra_closing_sign(const table_emphasis *emphasis, formtype closing, const widechar *cells, int i,
		int end, int in_number) {
	static const unsigned contractions[] = {D1 | D4 | D5, D1 | D5, D2 | D3 | D4, D1 | D3 | D4 | D5,
			D2 | D3 | D4 | D5};
	for (size_t k = 0; k < EMPHASIS_CLASS_COUNT; k++) {
		int length = EMPHASIS_CLASSES[k].ebae_length;
		widechar next = i + length < end ? cells[i + length] : CELL_BLANK;
		int forms_sign = 0;
		if (emphasis->code[k] != CODE_EBAE || !(closing & emphasis->bit[k]) ||
				!has_cells(cells, i, end, EMPHASIS_CLASSES[k].ebae, length))
			continue;
		if (length == 1) {
			forms_sign = in_number && is_digit_cell(next);
			for (size_t c = 0; c < sizeof contractions / sizeof contractions[0]; c++)
				forms_sign = forms_sign || next == CELL(contractions[c]);
		}
		if (!forms_sign && may_strip(emphasis, length == 1 ? EBAE_ITALIC_WORD : EBAE_BOLD_WORD, next))
			return length;
	}
	return 0;
}

/*
 * Keeps the cells of one word, `cells[start..end)`, at `kept[count..]`, each
 * with the table's bits of the emphasis it is in at `bits[count..]`, leaving
 * out the EBAE signs it reads, and returns the new count (`read_ebae`).
 * `*passage` holds the classes whose passage is open, which a passage's sign
 * opens and the word after its closing sign ends (EBAE 15.1b; a passage of
 * several paragraphs opens again in each, 15.1i, so one left open ends with
 * its paragraph).
 *
 * A sign may stand at the word's start, after its opening punctuation; after
 * a dash or a slash; after a joined "to", "into", or "by"; and after a hyphen,
 * where liblouis writes one when the emphasis stopped before it. The word's
 * own signs mark it to its end, or to the first dash or slash (EBAE 15.1a),
 * or to the end signs: the termination sign ⠠⠄, which is kept for liblouis,
 * and liblouis's sign inside a passage's last word (`extra_closing_sign`),
 * which is left out, one for each class whose emphasis ends there. A
 * passage's emphasis goes on through every dash, slash, and punctuation
 * mark (15.1b), and past a termination sign to the next word. Whatever is
 * not a sign, such as ⠨ as a decimal point or a contraction inside a word,
 * is kept for liblouis.
 */
static int
strip_ebae_word(const table_emphasis *emphasis, const widechar *cells, int start, int end,
		formtype *passage, widechar *kept, formtype *bits, int count, unsigned char *mu_signs) {
	/* The classes this word's own signs mark, and of those, the classes
	   whose passage it closes. */
	formtype word = 0;
	formtype closing = 0;
	/* Whether end signs ended the emphasis of the rest of the word, and
	   where the last of them ended, which another may follow. */
	int ended = 0;
	int ended_at = -1;
	/* Whether a sign may stand at `i`. */
	int sign_may_follow = 1;
	/* Whether double capitals, which ⠠⠄ ends too, have begun in the part
	   of the word since its last sign. */
	int capitals = 0;
	/* Whether `i` is in a number, after its number sign. */
	int in_number = 0;
	/* Whether `i` is in computer braille, between ⠸⠬ and ⠸⠱ (EBAE's
	   computer braille code indicators, liblouis's begcomp and endcomp),
	   where ⠨ is a period and no emphasis sign stands. */
	int in_computer = 0;
	int i = start;
	while (i < end) {
		int length;
		ebae_signs signs;
		/* Computer braille, with its indicators, is kept as it is. */
		length = in_computer ? 1 : 0;
		if (i + 1 < end && cells[i] == CELL_456 && cells[i + 1] == (in_computer ? CELL_156 : CELL_346)) {
			in_computer = !in_computer;
			length = 2;
		}
		if (length > 0) {
			count = keep(kept, bits, count, cells + i, length, ended ? 0 : word | *passage);
			i += length;
			sign_may_follow = 0;
			continue;
		}
		if (sign_may_follow) {
			sign_may_follow = 0;
			while ((length = opening_punctuation(cells, i, end)) > 0) {
				count = keep(kept, bits, count, cells + i, length, *passage);
				i += length;
			}
			signs = ebae_signs_at(emphasis, cells, i, end, *passage);
			*passage |= signs.opens;
			word |= signs.word;
			closing |= signs.word & *passage;
			if (signs.mu) memset(mu_signs + i, 1, (size_t)signs.length);
			i += signs.length;
			capitals = 0;
			/* "to", "into", or "by" joined to the next word takes these
			   signs alone, and the next word may have its own. */
			if ((length = joined_word(cells, i, end)) > 0) {
				count = keep(kept, bits, count, cells + i, length, word | *passage);
				i += length;
				*passage &= ~closing;
				word = closing = 0;
				sign_may_follow = 1;
			}
			continue;
		}
		/* Double capitals may begin inside a word, as in "McDONALDs" and
		   "X-RAYs" (verifier, October 24, 2026). */
		if (i + 1 < end && cells[i] == CELL_6 && cells[i + 1] == CELL_6) capitals = 1;
		/* The termination sign (EBAE 15.6), kept for liblouis, which reads
		   it as nothing and the word's parts apart, as main read them: left
		   out, "*per*haps" joined into ⠏⠻⠓, "perhaps", and came back
		   "perhapsaps" (verifier, October 24, 2026). After double capitals
		   it ends them only: liblouis writes "*ABCs*" as ⠨⠠⠠⠁⠃⠉⠠⠄⠎, the
		   emphasis going on (review, October 24, 2026). */
		if ((!ended || i == ended_at) && (word | *passage) != 0 && i + 1 < end && cells[i] == CELL_6 &&
				cells[i + 1] == CELL_3) {
			ended = !capitals;
			count = keep(kept, bits, count, cells + i, 2, capitals ? word | *passage : 0);
			i += 2;
			ended_at = ended ? i : -1;
			capitals = 0;
			continue;
		}
		if ((!ended || i == ended_at) && closing != 0 &&
				(length = extra_closing_sign(emphasis, closing, cells, i, end, in_number)) > 0) {
			ended = 1;
			i += length;
			ended_at = i;
			continue;
		}
		/* A dash or a slash ends the word's own emphasis, and a passage's
		   if this is its last word. */
		if ((length = dash_or_slash(cells, i, end)) > 0) {
			*passage &= ~closing;
			count = keep(kept, bits, count, cells + i, length, *passage);
			i += length;
			word = closing = 0;
			ended = in_number = 0;
			sign_may_follow = 1;
			continue;
		}
		/* A hyphen, after which liblouis begins emphasis again with a sign. */
		if (cells[i] == CELL_36) {
			count = keep(kept, bits, count, cells + i, 1, ended ? 0 : word | *passage);
			i++;
			in_number = 0;
			signs = ebae_signs_at(emphasis, cells, i, end, *passage);
			if (signs.length > 0 && signs.opens == 0) {
				word |= signs.word;
				closing |= signs.word & *passage;
				ended = 0;
				if (signs.mu) memset(mu_signs + i, 1, (size_t)signs.length);
				i += signs.length;
			}
			continue;
		}
		if (cells[i] == CELL_3456)
			in_number = 1;
		else if (!is_digit_cell(cells[i]) && cells[i] != CELL_46 && cells[i] != CELL_2)
			in_number = 0;
		count = keep(kept, bits, count, cells + i, 1, ended ? 0 : word | *passage);
		i++;
	}
	*passage &= ~closing;
	return count;
}

/*
 * Reads EBAE's emphasis signs out of `cells[0..n)`, a paragraph or a piece
 * of one (`strip_ebae_word`): keeps every other cell in `kept`, which holds
 * n, each with the table's bits of the emphasis it is in at the same place
 * in `bits`, and returns how many it kept. A blank cell takes the emphasis
 * the words on both sides of it share, so that a passage, or words
 * emphasized one by one, reads as one stretch, as liblouis gives a passage
 * in UEB. `mu_signs`, which holds n bytes of zero, is set to 1 at each cell
 * of a sign read before ⠍, which liblouis alone reads as "µ"
 * (`is_sign_before_m_word`).
 */
static int
strip_ebae_signs(const table_emphasis *emphasis, const widechar *cells, int n, widechar *kept,
		formtype *bits, unsigned char *mu_signs) {
	formtype passage = 0;
	formtype beside = 0;
	int have_beside = 0;
	int count = 0;
	int i = 0;
	while (i < n) {
		int end = i;
		if (cells[i] == CELL_BLANK) {
			count = keep(kept, bits, count, cells + i, 1, 0);
			i++;
			continue;
		}
		while (end < n && cells[end] != CELL_BLANK) end++;
		count = strip_ebae_word(emphasis, cells, i, end, &passage, kept, bits, count, mu_signs);
		i = end;
	}
	/* Each blank takes the emphasis of the last cell before it that is not
	   blank, then keeps only what the first such cell after it shares. */
	for (int k = 0; k < count; k++) {
		if (kept[k] != CELL_BLANK) {
			beside = bits[k];
			have_beside = 1;
		} else {
			bits[k] = have_beside ? beside : 0;
		}
	}
	have_beside = 0;
	for (int k = count - 1; k >= 0; k--) {
		if (kept[k] != CELL_BLANK) {
			beside = bits[k];
			have_beside = 1;
		} else {
			bits[k] = have_beside ? (formtype)(bits[k] & beside) : 0;
		}
	}
	return count;
}

/* MARK: - Fixing EBAE's known misreadings */

/*
 * What contracted EBAE's table (liblouis's en-us-g2.ctb) misreads in a book
 * set in it, as the Life of Pi braille showed on November 13, 2026 (a 2003
 * transcription in the old code, 4 volumes, read with the default UEB table
 * and then with EBAE): each is fixed here, in TextMouth's own pass over the
 * cells before liblouis reads them, so that it holds for any table that
 * reads EBAE, the bundled or this Mac's, which TextMouth never edits. The
 * pass only rewrites the cells into cells that liblouis reads right: spaced
 * apart, or spelled out in letters (which liblouis reads exactly as it reads
 * the contraction's letters in print), so the emphasis pass and its safety
 * net (`read_ebae`) read the very same cells.
 * - Wordsigns written together, ⠷⠮ "of the", ⠯⠮ "and the", ⠷⠁ "of a", ⠾⠁
 *   "with a", ⠿⠮ "for the", ⠾⠮ "with the": EBAE joins them into one unit,
 *   and the table has no rule for it, so they came back "ofthe". A run of
 *   two or more of these cells, with nothing else, is spaced into words.
 * - "ing" before a hyphen or dash, ⠬⠤: the table reads the two cells as
 *   "±", so "moving-in" came back "mov±in". The "ing" is spelled out.
 * - EBAE's period ⠲ between single letters, ⠏⠲⠃⠲⠥⠲⠓⠲ "p.b.u.h.": the table
 *   reads it as "dd" inside a word. Each letter with its period becomes a
 *   word of its own (a letter sign first, so that ⠏ is "p" and not "people"),
 *   so the print reads "p. b. u. h.".
 * - ⠠⠌⠲, "Still." or "St.": the table reads "St." always. It is read "St."
 *   only with a capital sign and a capitalized word after it ("St. Paul");
 *   any other ⠌⠲ is "still." (the capital sign aside), spelled out.
 */

/* The cells `cells_to_write` is writing (`fix_ebae_cells`), with room for all of them. */
typedef struct {
	widechar *cells;
	int count;
} cell_list;

/* Appends `cell` to `out`. */
static void
put_cell(cell_list *out, widechar cell) {
	out->cells[out->count++] = cell;
}

/* Appends the cells `cells[from..to)` to `out`. */
static void
put_cells(cell_list *out, const widechar *cells, int from, int to) {
	for (int k = from; k < to; k++) put_cell(out, cells[k]);
}

/* Appends the letters of `letters`, lowercase a to z, as cells. */
static void
put_letters(cell_list *out, const char *letters) {
	for (; *letters != '\0'; letters++) put_cell(out, letter_cell(*letters));
}

/*
 * Reads the word signs in `cells[i..end)`, each with the capital sign it may
 * have, into `*after`, the cell after the last of them, and returns how
 * many there are. `*not_a` counts those that are not "a".
 */
static int
scan_word_signs(const widechar *cells, int i, int end, int *after, int *not_a) {
	int count = 0;
	*not_a = 0;
	for (;;) {
		int at = i;
		if (at < end && cells[at] == CELL_6) at++;
		if (at >= end || !is_word_sign_cell(cells[at])) break;
		if (cells[at] != CELL_A) (*not_a)++;
		count++;
		i = at + 1;
	}
	*after = i;
	return count;
}

/*
 * Writes the word signs run in `cells[lead..end)` as words, each parted
 * from the next by a blank, with the word's leading marks and the marks
 * after the run (`fix_ebae_cells`), when the whole of it is two or more
 * word signs, one of them not "a", and the marks that may end a word. Returns 1
 * when it wrote the word, 0 when it did not.
 */
static int
split_word_signs(const widechar *cells, int start, int lead, int end, cell_list *out) {
	int after;
	int not_a;
	int count = scan_word_signs(cells, lead, end, &after, &not_a);
	if (count < 2 || not_a == 0 || !only_trailing_marks(cells, after, end)) return 0;
	put_cells(out, cells, start, lead);
	for (int i = lead; i < after;) {
		int sign = cells[i] == CELL_6 ? i + 2 : i + 1;
		put_cells(out, cells, i, sign);
		if (sign < after) put_cell(out, CELL_BLANK);
		i = sign;
	}
	put_cells(out, cells, after, end);
	return 1;
}

/*
 * Writes `cells[lead..end)` as initials, when the whole of it is single
 * letters each with its period, at least two periods, the last letter's
 * period perhaps left out, ⠏⠲⠃⠲⠥⠲⠓⠲ for "p.b.u.h.", a capital letter with
 * its capital sign (`fix_ebae_cells`): each as a word of a letter sign, the
 * letter, and its period. A word of one letter, then ⠲, then more than one
 * letter ("address", ⠁⠲⠗⠑⠎⠎) is no initials. Returns 1 when it wrote the
 * word, 0 when it did not.
 */
static int
split_initials(const widechar *cells, int start, int lead, int end, cell_list *out) {
	int groups = 0;
	int periods = 0;
	int i = lead;
	int dotted = 1;
	while (dotted) {
		int at = i;
		if (at < end && cells[at] == CELL_6) at++;
		if (at >= end || !is_letter_cell(cells[at])) break;
		at++;
		dotted = at < end && cells[at] == CELL_256;
		if (dotted) {
			at++;
			periods++;
		}
		groups++;
		i = at;
	}
	/* At least two periods: "Addy" (⠠⠁⠲⠽) is one letter, "dd", and one letter. */
	if (periods < 2 || !only_trailing_marks(cells, i, end)) return 0;
	put_cells(out, cells, start, lead);
	for (int k = lead, written = 0; written < groups; written++) {
		int at = k;
		put_cell(out, CELL_56);
		if (cells[at] == CELL_6) put_cell(out, cells[at++]);
		put_cell(out, cells[at++]);
		if (at < end && cells[at] == CELL_256) put_cell(out, cells[at++]);
		if (written + 1 < groups) put_cell(out, CELL_BLANK);
		k = at;
	}
	put_cells(out, cells, i, end);
	return 1;
}

/* Whether the word that follows the one ending at `cells[end]` in
   `cells[0..n)` begins with a capital sign, after any marks that open it. */
static int
next_word_is_capitalized(const widechar *cells, int end, int n) {
	int i = end;
	while (i < n && cells[i] == CELL_BLANK) i++;
	while (i < n && is_leading_mark(cells[i])) i++;
	return i < n && cells[i] == CELL_6;
}

/*
 * Writes `cells[lead..end)` as "still" and its period, when it is ⠌⠲ and the
 * marks that may end a word, with a capital sign or without, unless it can
 * be "St." (a capital sign, and the next word capitalized: `next_capital`).
 * "St." is only that: "Still." ends a sentence, whatever follows it, but
 * the cells are the same, and a capitalized word after the period is most
 * often a name ("St. Paul"). Returns 1 when it wrote the word, 0 when it
 * did not.
 */
static int
spell_still(const widechar *cells, int start, int lead, int end, int next_capital, cell_list *out) {
	int i = lead;
	int capital = i < end && cells[i] == CELL_6;
	if (capital) i++;
	if (i + 1 >= end || cells[i] != CELL_34 || cells[i + 1] != CELL_256 ||
			!only_trailing_marks(cells, i + 1, end) || (capital && next_capital))
		return 0;
	put_cells(out, cells, start, i);
	put_letters(out, "still");
	put_cells(out, cells, i + 1, end);
	return 1;
}


/*
 * Writes `cells[lead..end)`, a word that no other fix took, with the rest of
 * the fixes: "before" ⠆⠋ at its start, with a capital sign or without, when
 * more of the word follows and is no compound of it, spelled "bef"; and each
 * "ing" ⠬ after the word's first cell and before a hyphen ⠤, spelled out.
 */
static void
spell_inside_word(const widechar *cells, int start, int lead, int end, cell_list *out) {
	int i = lead;
	put_cells(out, cells, start, lead);
	if (i < end && cells[i] == CELL_6) put_cell(out, cells[i++]);
	for (; i < end; i++) {
		if (cells[i] == CELL_346 && i > lead && cells[i - 1] != CELL_6 && i + 1 < end &&
				cells[i + 1] == CELL_36)
			put_letters(out, "ing");
		else
			put_cell(out, cells[i]);
	}
}

/*
 * Rewrites the cells of one word, `cells[start..end)` of `cells[0..n)`, with
 * the first fix that fits it (the header comment above).
 */
static void
fix_ebae_word(const widechar *cells, int start, int end, int n, cell_list *out) {
	int lead = start;
	while (lead < end && is_leading_mark(cells[lead])) lead++;
	if (split_word_signs(cells, start, lead, end, out)) return;
	if (split_initials(cells, start, lead, end, out)) return;
	if (spell_still(cells, start, lead, end, next_word_is_capitalized(cells, end, n), out)) return;
	spell_inside_word(cells, start, lead, end, out);
}

/*
 * Fixes what contracted EBAE's table misreads (the comment above) in
 * `cells[0..n)`: returns the new cells, which the caller frees, and sets
 * `*count` to how many there are. Words are the cells between blanks. The
 * most a word grows is five times (a lone "still" sign and its period
 * become seven cells from two), so `6 * n + 16` cells is room for any
 * input. Returns NULL when there is no memory, and the caller reads the
 * cells unfixed.
 */
static widechar *
fix_ebae_cells(const widechar *cells, int n, int *count) {
	cell_list out = {malloc(((size_t)n * 6 + 16) * sizeof(widechar)), 0};
	int i = 0;
	if (out.cells == NULL) return NULL;
	while (i < n) {
		int end = i;
		if (cells[i] == CELL_BLANK) {
			put_cell(&out, cells[i++]);
			continue;
		}
		while (end < n && cells[end] != CELL_BLANK) end++;
		fix_ebae_word(cells, i, end, n, &out);
		i = end;
	}
	*count = out.count;
	return out.cells;
}

/*
 * The EBAE pass's safety net (`read_ebae`): reads `cells[0..n)` by liblouis
 * alone, exactly as `back` read them before the pass, and when that
 * reading's text differs from `*result`'s, the pass's reading of the same
 * cells, in any character (case included), puts liblouis's reading in
 * `*result` in its place, without the pass's emphasis: only liblouis's own
 * bits in `from_liblouis` are kept. Returns 1, or 0 when the translation
 * fails, leaving `*result` empty.
 */
static int
keep_liblouis_words(const char *table, const widechar *cells, int n, formtype from_liblouis,
		translation *result) {
	translation alone;
	if (!translate(table, 0, cells, NULL, n, 1, &alone)) {
		free_translation(result);
		return 0;
	}
	if (alone.length == result->length &&
			memcmp(alone.chars, result->chars, (size_t)alone.length * sizeof(widechar)) == 0) {
		free_translation(&alone);
		return 1;
	}
	for (int k = 0; k < alone.length; k++) alone.typeform[k] &= from_liblouis;
	free_translation(result);
	*result = alone;
	return 1;
}

/*
 * Reads `cells[0..n)` back to print into `*result` with a table that writes
 * its emphasis in EBAE's signs (`read_braille`), whose emphasis liblouis
 * 3.39.0 reads wrongly: it takes ⠨ before a letter a to j for a decimal
 * point (".cat"), ⠨⠅ for "=", ⠨⠍ for "µ", and ⠨⠂ for ">", and elsewhere
 * drops the sign with its emphasis, and lets a passage run to the end of the
 * paragraph. Its own EBAE writes a period before a word, "=", "µ", and ">"
 * with those cells, so the braille cannot tell them from a sign. The pass
 * (`strip_ebae_signs`) therefore leaves out only the signs liblouis drops
 * anyway (`may_strip`), and gives liblouis the rest: the words are those
 * liblouis read before the pass, and each character takes the emphasis of
 * the cell it was read from (`give_cells_emphasis`). liblouis is still given
 * a typeform array, as every reading is, so that a sign the pass leaves is
 * read as liblouis read it; the emphasis liblouis reports is replaced.
 *
 * Leaving a sign out can still change how liblouis reads the cells around
 * it, which no test of the sign and the cell after it alone shows
 * (verifier, October 24, 2026): with the sign gone, contracted EBAE reads
 * "(" ⠶ and "be" ⠆ together as "}", so "(before" came back "}from", and
 * uncontracted EBAE read "25 -- before" as "25–before" once the bold sign
 * after its dash was gone. So a record the pass left a cell out of is
 * also read by liblouis alone (`keep_liblouis_words`), and wherever the two
 * readings differ in any character, liblouis's is the record's: the words
 * are always those liblouis reads alone, by construction. Returns 1, or 0
 * when a translation fails.
 */
static int
read_ebae(const char *table, const table_emphasis *emphasis, const widechar *cells, int n,
		translation *result) {
	widechar *kept = malloc(((size_t)n + 1) * sizeof *kept);
	formtype *bits = malloc(((size_t)n + 1) * sizeof *bits);
	/* The cells read as signs before ⠍ (`is_sign_before_m_word`), which
	   the safety net's reading leaves out too. */
	unsigned char *mu_signs = calloc((size_t)n + 1, 1);
	formtype from_liblouis = 0;
	int count = n;
	int ok = 0;
	memset(result, 0, sizeof *result);
	/* liblouis's own reading of the classes the pass does not read. */
	for (size_t k = 0; k < EMPHASIS_CLASS_COUNT; k++)
		if (emphasis->code[k] != CODE_EBAE) from_liblouis |= emphasis->bit[k];
	if (kept != NULL && bits != NULL && mu_signs != NULL) {
		count = strip_ebae_signs(emphasis, cells, n, kept, bits, mu_signs);
		ok = read_kept_cells(table, kept, bits, count, from_liblouis, result);
	}
	/* With no cell left out, liblouis read the very cells it reads alone.
	   Otherwise it reads them again alone, without the signs before ⠍,
	   which it would read as µ and the pass reads as signs. */
	if (ok && count < n) {
		int alone = 0;
		for (int i = 0; i < n; i++)
			if (!mu_signs[i]) kept[alone++] = cells[i];
		ok = keep_liblouis_words(table, kept, alone, from_liblouis, result);
	}
	free(kept);
	free(bits);
	free(mu_signs);
	return ok;
}

/* MARK: - Reading UEB */

/*
 * The length of the UEB terminator at `cells[i..n)` of a class the table
 * writes in UEB, its prefix and ⠄ (⠨⠄ for italic), when it ends the cells
 * before it: the cell before it is not blank. 0 for none.
 */
static int
ueb_terminator_at(const table_emphasis *emphasis, const widechar *cells, int i, int n) {
	int found = 0;
	if (i == 0 || cells[i - 1] == CELL_BLANK) return 0;
	for (size_t k = 0; k < EMPHASIS_CLASS_COUNT; k++) {
		int length = EMPHASIS_CLASSES[k].ueb_length;
		if (emphasis->code[k] == CODE_UEB && has_cells(cells, i, n, EMPHASIS_CLASSES[k].ueb, length) &&
				i + length < n && cells[i + length] == CELL_3 && length + 1 > found)
			found = length + 1;
	}
	return found;
}

/*
 * Reads `cells[0..n)` back to print into `*result` with a table that writes
 * its emphasis in UEB's indicators (`read_braille`). liblouis reads them,
 * and its emphasis is kept, but it reads the cells just before a terminator
 * as if they could not end a word, the terminator being no space, so a
 * contraction that stands for a whole word there comes back as the letter
 * or part-word sign its cell also is: "people" (⠏) as "p", "Knowledge"
 * (⠠⠅) as "K", "can" (⠉) as "c", "his" (⠦) as a double quote, "were" (⠶)
 * as a prime, and "enough" (⠢) as "en" (review E1, October 21, 2026).
 *
 * So braille with a terminator is read twice: as it is, for the emphasis
 * liblouis reads, which each cell takes from the first character of its
 * rule (liblouis's outputPos); and without its terminators, for the words,
 * which the terminators no longer part from what follows them, and which
 * take their cells' emphasis (`give_cells_emphasis`). The indicators that
 * begin emphasis stay for the second reading, which takes them as
 * indicators as the first did. A terminator's place stays known through
 * the cells' emphasis: "people's" (⠏⠄⠎), one rule, is split where its
 * italic ends. Braille with no terminator reads exactly as before, from the
 * first reading alone. Returns 1, or 0 when a translation fails.
 */
static int
read_ueb(const char *table, const table_emphasis *emphasis, const widechar *cells, int n,
		translation *result) {
	translation first;
	widechar *kept;
	formtype *bits;
	int found = 0;
	int count = 0;
	int ok;
	memset(result, 0, sizeof *result);
	if (!translate(table, 0, cells, NULL, n, 1, &first)) return 0;
	for (int i = 1; i < n && !found; i++) found = ueb_terminator_at(emphasis, cells, i, n) > 0;
	if (!found || first.length == 0) {
		*result = first;
		return 1;
	}
	kept = malloc(((size_t)n + 1) * sizeof *kept);
	bits = malloc(((size_t)n + 1) * sizeof *bits);
	ok = kept != NULL && bits != NULL;
	/* Every cell but the terminators, each with the emphasis of the first
	   character of its rule in the first reading. */
	for (int i = 0; ok && i < n;) {
		int length = ueb_terminator_at(emphasis, cells, i, n);
		int at = first.output_pos[i];
		if (length > 0) {
			i += length;
			continue;
		}
		kept[count] = cells[i];
		bits[count++] = at >= 0 && at < first.length ? first.typeform[at] : 0;
		i++;
	}
	ok = ok && read_kept_cells(table, kept, bits, count, 0, result);
	free_translation(&first);
	free(kept);
	free(bits);
	return ok;
}

/*
 * Translates the braille `cells[0..n)` back to print into `*result`, as
 * `back` reads each record, reading its emphasis: through the pass of the
 * code the table writes its emphasis in (`read_ebae`, `read_ueb`), or
 * through liblouis alone. `result->typeform` holds the table's bits of
 * every class; the caller keeps those of the readable ones. Returns 1, or
 * 0 when a translation fails.
 */
static int
read_braille(const char *table, const table_emphasis *emphasis, const widechar *cells, int n,
		translation *result) {
	if (uses_code(emphasis, CODE_EBAE)) {
		/* Contracted EBAE's known misreadings are fixed in the cells first
		   (`fix_ebae_cells`); with no memory they are read unfixed. */
		int count = 0;
		widechar *fixed = emphasis->contracted ? fix_ebae_cells(cells, n, &count) : NULL;
		int ok = fixed != NULL ? read_ebae(table, emphasis, fixed, count, result)
							   : read_ebae(table, emphasis, cells, n, result);
		free(fixed);
		return ok;
	}
	if (uses_code(emphasis, CODE_UEB)) return read_ueb(table, emphasis, cells, n, result);
	return translate(table, 0, cells, NULL, n, 1, result);
}

/* The probe of `check_readable`: plain lowercase words, which every bundled
   table reads back letter for letter, contracted or not, with punctuation
   where its emphasized words end. */
static const char PROBE[] =
		"alpha bravo, charlie delta echo foxtrot golf hotel. india juliett; kilo lima: mike "
		"november! oscar's papa? quebec";

/*
 * Whether the probe's character at `index` lies in its marked stretches:
 * the passage "delta echo foxtrot golf hotel", five words with the spaces
 * between them, longer than every bundled table's shortest passage (UEB's
 * three words, EBAE's four), and the words "bravo", "juliett", "lima",
 * "november", "oscar", and "papa" alone. The punctuation after each, a
 * comma, a period, a semicolon, a colon, an exclamation mark, a possessive,
 * and a question mark, is not marked: emphasis that ends at punctuation is
 * where EBAE and several of this Mac's tables write signs liblouis reads as
 * punctuation of their own (Thai Grade 2 read "word;" back as "wordbb").
 */
static int
is_probe_marked(size_t index) {
	static const char *marked[] = {
			"bravo", "delta echo foxtrot golf hotel", "juliett", "lima", "november", "oscar", "papa"};
	for (size_t k = 0; k < sizeof marked / sizeof marked[0]; k++) {
		size_t start = (size_t)(strstr(PROBE, marked[k]) - PROBE);
		if (index >= start && index < start + strlen(marked[k])) return 1;
	}
	return 0;
}

/*
 * Marks in `emphasis->readable` each class that liblouis reads back exactly
 * as it writes it with this table, so that `forward` never writes an
 * indicator liblouis would misread. For each class the table has, the probe
 * is translated forward with the class on its marked stretches, then back by
 * liblouis alone, and the class passes when the text comes back as the
 * probe, punctuation included, and the class's bit (and no other carried
 * class's) lies on exactly the marked letters; spaces and punctuation are
 * not looked at for emphasis, since liblouis gives a word's following space
 * its emphasis. `back` reports the readable classes, and the classes the
 * EBAE pass reads (`flags_for_typeform`).
 *
 * liblouis 3.39.0 reads UEB's emphasis back exactly, but not EBAE's italic
 * and bold, or that of most of this Mac's tables that have emphasis rules.
 * EBAE, like ten of this Mac's tables, ends a passage with an indicator
 * BEFORE its last word (`endemphphrase ... before`), as UEB never does:
 * liblouis reads EBAE's italic word indicator (dots 4-6) as a period, its
 * bold one (dots 4-5-6, 4-6) as the end of a bold passage, which drops it,
 * lets a passage run to the end of the paragraph, and writes a stray sign
 * before punctuation that follows a passage, which other braille readers
 * read too. Written, that would change the words of a book TextMouth
 * exported (review E2, October 21, 2026), so export writes EBAE's italic and
 * bold plain; the EBAE pass, which reads BANA's signs in books, does not
 * judge them (review, October 24, 2026). liblouis's own EBAE underline
 * passes, and is written and read as liblouis has it. Measured on each run
 * rather than listed by name, so that a table liblouis learns to read passes
 * without a change here, and one of this Mac's tables is judged by what its
 * own rules do.
 */
static void
check_readable(const char *table, table_emphasis *emphasis) {
	size_t length = strlen(PROBE);
	widechar probe[sizeof PROBE];
	formtype marked[sizeof PROBE];
	formtype carried = 0;
	translation braille = {0};
	translation print = {0};
	int plain_reads_back;
	for (size_t i = 0; i < length; i++) probe[i] = (widechar)(unsigned char)PROBE[i];
	for (size_t i = 0; i < EMPHASIS_CLASS_COUNT; i++) carried |= emphasis->bit[i];

	/* The probe must come back as itself when plain, or nothing can be judged. */
	plain_reads_back = translate(table, 1, probe, NULL, (int)length, 0, &braille) &&
			translate(table, 0, braille.chars, NULL, braille.length, 1, &print) &&
			print.length == (int)length && memcmp(print.chars, probe, length * sizeof(widechar)) == 0;
	free_translation(&braille);
	free_translation(&print);
	if (!plain_reads_back) return;

	for (size_t i = 0; i < EMPHASIS_CLASS_COUNT; i++) {
		formtype bit = emphasis->bit[i];
		int passes;
		if (bit == 0) continue;
		for (size_t k = 0; k < length; k++) marked[k] = is_probe_marked(k) ? bit : 0;
		passes = translate(table, 1, probe, marked, (int)length, 0, &braille) &&
				translate(table, 0, braille.chars, NULL, braille.length, 1, &print) &&
				print.length == (int)length && memcmp(print.chars, probe, length * sizeof(widechar)) == 0;
		for (size_t k = 0; passes && k < length; k++)
			if (PROBE[k] >= 'a' && PROBE[k] <= 'z') passes = (print.typeform[k] & carried) == marked[k];
		emphasis->readable[i] = passes;
		free_translation(&braille);
		free_translation(&print);
	}
}

/*
 * Reads the table's bit for each class of EMPHASIS_CLASSES into `emphasis`,
 * the code it writes each in (`detect_codes`), and which classes liblouis
 * reads back exactly (`check_readable`), the only ones either direction
 * carries.
 */
static void
look_up_emphasis(const char *table, table_emphasis *emphasis) {
	memset(emphasis, 0, sizeof *emphasis);
	for (size_t i = 0; i < EMPHASIS_CLASS_COUNT; i++)
		emphasis->bit[i] = lou_getTypeformForEmphClass(table, EMPHASIS_CLASSES[i].name);
	detect_codes(table, emphasis);
	check_readable(table, emphasis);
}

/*
 * Translates one record, the text `line[0..bytes)` and its codes
 * `codes[0..code_bytes)`, each as `getline` read it, and writes its record
 * to `output`. Returns the exit status.
 */
static int
translate_record(const char *table, int forward, const table_emphasis *emphasis, const char *line,
		size_t bytes, const char *codes, size_t code_bytes, FILE *output) {
	size_t count = 0;
	widechar *chars;
	translation out;
	formtype *typeform = NULL;
	unsigned char *flags = NULL;
	int translated;
	int status = EXIT_DONE;
	/* Each line feed ends its line; it is not part of the record. */
	if (bytes > 0 && line[bytes - 1] == '\n') bytes--;
	if (code_bytes > 0 && codes[code_bytes - 1] == '\n') code_bytes--;
	if (bytes > (size_t)MAX_LINE * 4 || code_bytes > MAX_LINE) return EXIT_INPUT_INVALID;
	/* Braille holds its emphasis in its cells, so it brings no codes. */
	if (!forward && code_bytes > 0) return EXIT_INPUT_INVALID;
	/* An empty paragraph translates to an empty record, without liblouis. */
	if (bytes == 0) {
		if (code_bytes > 0) return EXIT_INPUT_INVALID;
		return fputs("\n\n", output) == EOF ? EXIT_OUTPUT : EXIT_DONE;
	}
	chars = malloc(bytes * sizeof(widechar));
	if (chars == NULL) return EXIT_TRANSLATION;
	if (decode_utf8((const unsigned char *)line, bytes, chars, &count) != 0 || count > MAX_LINE ||
			(!forward && !all_braille(chars, count)) || (code_bytes > 0 && code_bytes != count)) {
		free(chars);
		return EXIT_INPUT_INVALID;
	}
	/* Forward: each character's codes as the table's bits, or no array at
	   all when every character is plain. */
	if (code_bytes > 0) {
		int any = 0;
		typeform = malloc(count * sizeof(formtype));
		if (typeform == NULL) {
			free(chars);
			return EXIT_TRANSLATION;
		}
		for (size_t i = 0; i < count && status == EXIT_DONE; i++) {
			unsigned char code = (unsigned char)codes[i];
			if (code < TMB_EMPHASIS_CODE_PLAIN || code > TMB_EMPHASIS_CODE_PLAIN + TMB_EMPHASIS_ALL) {
				status = EXIT_INPUT_INVALID;
				break;
			}
			typeform[i] = typeform_for_flags(emphasis, code - TMB_EMPHASIS_CODE_PLAIN);
			any = any || typeform[i] != 0;
		}
		if (status != EXIT_DONE || !any) {
			free(typeform);
			typeform = NULL;
		}
		if (status != EXIT_DONE) {
			free(chars);
			return status;
		}
	}
	translated = forward ? translate(table, 1, chars, typeform, (int)count, 0, &out)
						 : read_braille(table, emphasis, chars, (int)count, &out);
	free(chars);
	free(typeform);
	if (!translated) return EXIT_TRANSLATION;
	/* Back: the flags of the emphasis read, for each character. */
	if (!forward && out.typeform != NULL) {
		flags = malloc((size_t)out.length + 1);
		if (flags == NULL) status = EXIT_TRANSLATION;
		for (int i = 0; flags != NULL && i < out.length; i++)
			flags[i] = (unsigned char)flags_for_typeform(emphasis, out.typeform[i]);
	}
	if (status == EXIT_DONE &&
			(write_line(output, out.chars, (size_t)out.length) != 0 ||
					write_codes(output, flags, (size_t)out.length) != 0))
		status = EXIT_OUTPUT;
	free_translation(&out);
	free(flags);
	return status;
}

/*
 * Translates each record of the file at `input_path` into the file at
 * `output_path`, as the header comment says, and returns the exit status.
 * The output is written record by record, so the watchdog sees it grow
 * while a long book is translated.
 */
static int
translate_file(const char *table, int forward, const table_emphasis *emphasis, const char *input_path,
		const char *output_path) {
	FILE *input = fopen(input_path, "rb");
	FILE *output;
	char *line = NULL;
	char *codes = NULL;
	size_t line_capacity = 0;
	size_t codes_capacity = 0;
	ssize_t got;
	int status = EXIT_DONE;
	if (input == NULL) return EXIT_INPUT_UNREADABLE;
	output = fopen(output_path, "wb");
	if (output == NULL) {
		fclose(input);
		return EXIT_OUTPUT;
	}
	/* The header: an input of another protocol is not read at all. */
	got = getline(&line, &line_capacity, input);
	if (got == -1 || !is_header(line, (size_t)got))
		status = ferror(input) ? EXIT_INPUT_UNREADABLE : EXIT_PROTOCOL;
	else if (fputs(TMB_PROTOCOL_HEADER "\n", output) == EOF)
		status = EXIT_OUTPUT;
	while (status == EXIT_DONE && (got = getline(&line, &line_capacity, input)) != -1) {
		/* Every text line has its code line; an input that ends between
		   them was cut short. */
		ssize_t code_bytes = getline(&codes, &codes_capacity, input);
		if (code_bytes == -1) {
			status = ferror(input) ? EXIT_INPUT_UNREADABLE : EXIT_INPUT_INVALID;
			break;
		}
		status = translate_record(
				table, forward, emphasis, line, (size_t)got, codes, (size_t)code_bytes, output);
	}
	/* A read error ends the loop as the end of the file does. */
	if (status == EXIT_DONE && ferror(input)) status = EXIT_INPUT_UNREADABLE;
	free(line);
	free(codes);
	fclose(input);
	if (fclose(output) != 0 && status == EXIT_DONE) status = EXIT_OUTPUT;
	return status;
}

/*
 * Reads the mode and its arguments, loads the table, and runs the mode.
 * Returns the exit status.
 */
int
main(int argc, char **argv) {
	const char *mode = argc > 1 ? argv[1] : "";
	int is_check = strcmp(mode, "check") == 0;
	int is_forward = strcmp(mode, "forward") == 0;
	int is_back = strcmp(mode, "back") == 0;
	int is_liblouis_back = strcmp(mode, "back-liblouis") == 0;
	const char *table = argc > 3 ? argv[3] : "";
	int table_loaded;
	int status;
	int paths_absolute = 1;
	table_emphasis emphasis;
	/* Every path is absolute: the helper changes its current directory
	   (see table_path) before it opens the input and the output. */
	for (int i = 2; i < argc; i++)
		if (i != 3 && argv[i][0] != '/') paths_absolute = 0;
	if (!paths_absolute ||
			!((is_check && argc == 4) || ((is_forward || is_back || is_liblouis_back) && argc == 6))) {
		fprintf(stderr,
				"usage: TextMouthBraille check <tables folder> <table>\n"
				"       TextMouthBraille forward|back <tables folder> <table> <input> "
				"<output>\n");
		return EXIT_USAGE;
	}
	/* liblouis's warnings would only slow a long book down; errors stay. */
	lou_setLogLevel(LOU_LOG_ERROR);
	/* The table is loaded, with every table it includes, from the tables
	   folder; then the helper leaves the folder, whether it loaded or not. */
	table_loaded = enter_tables_folder(argv[2], table) == 0 && lou_checkTable(table);
	leave_tables_folder();
	if (!table_loaded) {
		lou_free();
		return EXIT_TABLE;
	}
	if (is_check) {
		status = EXIT_DONE;
	} else {
		look_up_emphasis(table, &emphasis);
		/* With no code known, `read_braille` reads by liblouis alone, and
		   `back` reports only the readable classes, as before the passes. */
		for (size_t k = 0; is_liblouis_back && k < EMPHASIS_CLASS_COUNT; k++) emphasis.code[k] = CODE_NONE;
		status = translate_file(table, is_forward, &emphasis, argv[4], argv[5]);
	}
	lou_free();
	return status;
}
