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
 *   `back` reports the emphasis liblouis reads from the indicators, both of
 *   only the classes liblouis reads back exactly with the table
 *   (`check_readable`). Braille, in and out, is Unicode braille patterns
 *   (U+2800 to U+28FF), the blank cell U+2800 included; a space is never
 *   braille.
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

/*
 * The emphasis classes the protocol carries, by the names liblouis's tables
 * give them, each with TextMouth's flag for it. liblouis numbers a table's
 * classes in the order the table declares them, so the same bit means
 * "script" in one table and "transnote" in another; names are the only
 * thing tables share. The five transcriber-defined typefaces share one
 * flag, and a flag written forward goes to the first readable class listed
 * with it ("trans1" for TMB_EMPHASIS_TRANSCRIBER in UEB). Classes not listed
 * here, such as UEB's "transnote" (a transcriber's note, no typeface of the
 * print), are not carried: liblouis still reads their indicators as
 * indicators, and the text they mark comes back plain.
 */
static const struct {
	const char *name;
	unsigned flag;
} EMPHASIS_CLASSES[] = {
		{"italic", TMB_EMPHASIS_ITALIC},
		{"bold", TMB_EMPHASIS_BOLD},
		{"underline", TMB_EMPHASIS_UNDERLINE},
		{"script", TMB_EMPHASIS_SCRIPT},
		{"trans1", TMB_EMPHASIS_TRANSCRIBER},
		{"trans2", TMB_EMPHASIS_TRANSCRIBER},
		{"trans3", TMB_EMPHASIS_TRANSCRIBER},
		{"trans4", TMB_EMPHASIS_TRANSCRIBER},
		{"trans5", TMB_EMPHASIS_TRANSCRIBER},
};
#define EMPHASIS_CLASS_COUNT (sizeof EMPHASIS_CLASSES / sizeof EMPHASIS_CLASSES[0])

/*
 * The loaded table's emphasis: for each class of EMPHASIS_CLASSES, its
 * typeform bit in the table (0 when the table has no such class), and
 * whether liblouis reads it back exactly with this table
 * (`check_readable`). Both directions carry only the readable classes:
 * `forward` writes no indicator `back` could not read, and `back` reports
 * no emphasis it may have misread.
 */
typedef struct {
	formtype bit[EMPHASIS_CLASS_COUNT];
	int readable[EMPHASIS_CLASS_COUNT];
} table_emphasis;

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

/*
 * Translates `in[0..length)` with the table named `table` (already loaded by
 * `main`, which liblouis keeps by that name), forward (print to
 * braille) or back, into a buffer it allocates and returns, with the
 * output's length in `*out_length`; NULL when liblouis fails. The braille
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
 * - Back, liblouis is always given an array, one entry for each output
 *   character, which it fills with the emphasis it finds; it is returned in
 *   `*out_typeform`, which the caller frees, unless that is NULL. liblouis
 *   takes an emphasis indicator, such as UEB's italic word indicator ⠨⠂, as
 *   an indicator only when there is such an array to record it in; without
 *   one it writes the cells as its notation for cells it cannot translate
 *   ("\46/,"), which a listener would hear mid-sentence.
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
static widechar *
translate(const char *table, int forward, const widechar *in, const formtype *in_typeform, int length,
		int *out_length, formtype **out_typeform) {
	const int mode = dotsIO | ucBrl;
	for (int multiple = FIRST_ROOM; multiple <= MOST_ROOM; multiple *= 2) {
		/* MAX_LINE * MOST_ROOM + 64 is far below INT_MAX. */
		int room = length * multiple + 64;
		int wants_typeform = !forward || in_typeform != NULL;
		widechar *out = malloc((size_t)room * sizeof(widechar));
		/* calloc: the entries past the input's (forward) start plain. */
		formtype *typeform = wants_typeform ? calloc((size_t)room, sizeof(formtype)) : NULL;
		int used = length;
		int written = room;
		int ok;
		if (out == NULL || (wants_typeform && typeform == NULL)) {
			free(out);
			free(typeform);
			return NULL;
		}
		if (forward && in_typeform != NULL)
			memcpy(typeform, in_typeform, (size_t)length * sizeof(formtype));
		ok = forward ? lou_translateString(table, in, &used, out, &written, typeform, NULL, mode)
					 : lou_backTranslateString(
							   table, in, &used, out, &written, typeform, NULL, mode);
		if (ok && used >= length && room - written >= MIN_SPARE_ROOM) {
			*out_length = written;
			if (out_typeform != NULL && !forward)
				*out_typeform = typeform;
			else
				free(typeform);
			return out;
		}
		free(typeform);
		free(out);
	}
	return NULL;
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
 * TextMouth's flags for the table's typeform bits `typeform`, counting only
 * the readable classes.
 */
static unsigned
flags_for_typeform(const table_emphasis *emphasis, formtype typeform) {
	unsigned flags = 0;
	for (size_t i = 0; i < EMPHASIS_CLASS_COUNT; i++)
		if (emphasis->readable[i] && (typeform & emphasis->bit[i])) flags |= EMPHASIS_CLASSES[i].flag;
	return flags;
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
 * indicator `back` would misread and `back` never reports emphasis it may
 * have misread. For each class the table has, the probe is translated
 * forward with the class on its marked stretches, then back, and the class
 * passes when the text comes back as the probe, punctuation included, and
 * the class's bit (and no other carried class's) lies on exactly the marked
 * letters; spaces and punctuation are not looked at for emphasis, since
 * liblouis gives a word's following space its emphasis.
 *
 * liblouis 3.39.0 reads UEB's emphasis back exactly, but not EBAE's or that
 * of most of this Mac's tables that have emphasis rules. EBAE, like ten of
 * this Mac's tables, ends a passage with an indicator BEFORE its last word
 * (`endemphphrase ... before`), as UEB never does: liblouis reads EBAE's
 * italic word indicator (dots 4-6) as a period, its bold one (dots 4-5-6,
 * 4-6) as the end of a bold passage, which drops it, lets a passage run to
 * the end of the paragraph, and writes a stray sign before punctuation that
 * follows a passage. Written or reported, that would change the words of a
 * book TextMouth exported and read again, or put emphasis it never had into
 * its Markdown. Measured on each run rather than listed by name, so that a
 * table liblouis learns to read passes without a change here, and one of
 * this Mac's tables is judged by what its own rules do.
 */
static void
check_readable(const char *table, table_emphasis *emphasis) {
	size_t length = strlen(PROBE);
	widechar probe[sizeof PROBE];
	formtype marked[sizeof PROBE];
	formtype carried = 0;
	widechar *braille, *print;
	formtype *read = NULL;
	int braille_length = 0, print_length = 0;
	for (size_t i = 0; i < length; i++) probe[i] = (widechar)(unsigned char)PROBE[i];
	for (size_t i = 0; i < EMPHASIS_CLASS_COUNT; i++) carried |= emphasis->bit[i];

	/* The probe must come back as itself when plain, or nothing can be judged. */
	braille = translate(table, 1, probe, NULL, (int)length, &braille_length, NULL);
	print = braille == NULL ? NULL : translate(table, 0, braille, NULL, braille_length, &print_length, NULL);
	int plain_reads_back = print != NULL && print_length == (int)length &&
			memcmp(print, probe, length * sizeof(widechar)) == 0;
	free(braille);
	free(print);
	if (!plain_reads_back) return;

	for (size_t i = 0; i < EMPHASIS_CLASS_COUNT; i++) {
		formtype bit = emphasis->bit[i];
		int passes;
		if (bit == 0) continue;
		for (size_t k = 0; k < length; k++) marked[k] = is_probe_marked(k) ? bit : 0;
		braille = translate(table, 1, probe, marked, (int)length, &braille_length, NULL);
		print = braille == NULL ? NULL
								: translate(table, 0, braille, NULL, braille_length, &print_length, &read);
		passes = print != NULL && print_length == (int)length &&
				memcmp(print, probe, length * sizeof(widechar)) == 0;
		for (size_t k = 0; passes && k < length; k++)
			if (PROBE[k] >= 'a' && PROBE[k] <= 'z') passes = (read[k] & carried) == marked[k];
		emphasis->readable[i] = passes;
		free(braille);
		free(print);
		free(read);
		read = NULL;
	}
}

/*
 * Reads the table's bit for each class of EMPHASIS_CLASSES into `emphasis`,
 * and which classes liblouis reads back exactly (`check_readable`), the
 * only ones either direction carries.
 */
static void
look_up_emphasis(const char *table, table_emphasis *emphasis) {
	memset(emphasis, 0, sizeof *emphasis);
	for (size_t i = 0; i < EMPHASIS_CLASS_COUNT; i++)
		emphasis->bit[i] = lou_getTypeformForEmphClass(table, EMPHASIS_CLASSES[i].name);
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
	widechar *out;
	formtype *typeform = NULL;
	formtype *read = NULL;
	unsigned char *flags = NULL;
	int out_length = 0;
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
	out = translate(table, forward, chars, typeform, (int)count, &out_length, forward ? NULL : &read);
	free(chars);
	free(typeform);
	if (out == NULL) return EXIT_TRANSLATION;
	/* Back: the flags of the emphasis liblouis read, for each character. */
	if (!forward && read != NULL) {
		flags = malloc((size_t)out_length + 1);
		if (flags == NULL) status = EXIT_TRANSLATION;
		for (int i = 0; flags != NULL && i < out_length; i++)
			flags[i] = (unsigned char)flags_for_typeform(emphasis, read[i]);
	}
	if (status == EXIT_DONE &&
			(write_line(output, out, (size_t)out_length) != 0 ||
					write_codes(output, flags, (size_t)out_length) != 0))
		status = EXIT_OUTPUT;
	free(out);
	free(read);
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
			!((is_check && argc == 4) || ((is_forward || is_back) && argc == 6))) {
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
		status = translate_file(table, is_forward, &emphasis, argv[4], argv[5]);
	}
	lou_free();
	return status;
}
