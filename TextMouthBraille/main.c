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
 * - `forward` translates print to braille, and `back` braille to print. The
 *   input file holds one paragraph per line, in UTF-8, each line ending in a
 *   line feed. The output file gets one line for each input line, in the
 *   same order, so line N of the output is the translation of line N of the
 *   input. Braille, in and out, is Unicode braille patterns (U+2800 to
 *   U+28FF), the blank cell U+2800 included; a space is never braille.
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
 * a line longer than MAX_LINE characters, or in `back` a character that is
 * not a braille cell); 5 liblouis could not translate a line; 6 the output
 * cannot be written. The helper prints nothing to its standard output, and
 * liblouis's own errors go to standard error, which TextMouth discards.
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

/* The exit statuses, as the header comment lists them. */
enum {
	EXIT_DONE = 0,
	EXIT_USAGE = 1,
	EXIT_TABLE = 2,
	EXIT_INPUT_UNREADABLE = 3,
	EXIT_INPUT_INVALID = 4,
	EXIT_TRANSLATION = 5,
	EXIT_OUTPUT = 6,
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
 * Back-translation is given a typeform buffer, one entry for each output
 * character, which it fills with the emphasis it finds. liblouis takes an
 * emphasis indicator, such as UEB's italic word indicator ⠨⠂, as an
 * indicator only when there is such a buffer to record it in; without one
 * it writes the cells as its notation for cells it cannot translate
 * ("\46/,"), which a listener would hear mid-sentence. The emphasis itself
 * is not kept: TextMouth reads the words aloud.
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
translate(const char *table, int forward, const widechar *in, int length, int *out_length) {
	const int mode = dotsIO | ucBrl;
	for (int multiple = FIRST_ROOM; multiple <= MOST_ROOM; multiple *= 2) {
		/* MAX_LINE * MOST_ROOM + 64 is far below INT_MAX. */
		int room = length * multiple + 64;
		widechar *out = malloc((size_t)room * sizeof(widechar));
		formtype *emphasis = forward ? NULL : malloc((size_t)room * sizeof(formtype));
		int used = length;
		int written = room;
		int ok;
		if (out == NULL || (!forward && emphasis == NULL)) {
			free(out);
			free(emphasis);
			return NULL;
		}
		ok = forward ? lou_translateString(table, in, &used, out, &written, NULL, NULL, mode)
					 : lou_backTranslateString(
							   table, in, &used, out, &written, emphasis, NULL, mode);
		free(emphasis);
		if (ok && used >= length && room - written >= MIN_SPARE_ROOM) {
			*out_length = written;
			return out;
		}
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
 * Translates each line of the file at `input_path` into the file at
 * `output_path`, as the header comment says, and returns the exit status.
 * The output is written line by line, so the watchdog sees it grow while a
 * long book is translated.
 */
static int
translate_file(const char *table, int forward, const char *input_path, const char *output_path) {
	FILE *input = fopen(input_path, "rb");
	FILE *output;
	char *line = NULL;
	size_t capacity = 0;
	ssize_t got;
	int status = EXIT_DONE;
	if (input == NULL) return EXIT_INPUT_UNREADABLE;
	output = fopen(output_path, "wb");
	if (output == NULL) {
		fclose(input);
		return EXIT_OUTPUT;
	}
	while ((got = getline(&line, &capacity, input)) != -1) {
		size_t bytes = (size_t)got;
		size_t count = 0;
		widechar *chars;
		widechar *out;
		int out_length = 0;
		/* The line feed ends the line; it is not part of the paragraph. */
		if (bytes > 0 && line[bytes - 1] == '\n') bytes--;
		if (bytes > (size_t)MAX_LINE * 4) {
			status = EXIT_INPUT_INVALID;
			break;
		}
		/* An empty paragraph translates to an empty line, without liblouis. */
		if (bytes == 0) {
			if (fputc('\n', output) == EOF) {
				status = EXIT_OUTPUT;
				break;
			}
			continue;
		}
		chars = malloc(bytes * sizeof(widechar));
		if (chars == NULL) {
			status = EXIT_TRANSLATION;
			break;
		}
		if (decode_utf8((const unsigned char *)line, bytes, chars, &count) != 0 ||
				count > MAX_LINE || (!forward && !all_braille(chars, count))) {
			free(chars);
			status = EXIT_INPUT_INVALID;
			break;
		}
		out = translate(table, forward, chars, (int)count, &out_length);
		free(chars);
		if (out == NULL) {
			status = EXIT_TRANSLATION;
			break;
		}
		if (write_line(output, out, (size_t)out_length) != 0) {
			free(out);
			status = EXIT_OUTPUT;
			break;
		}
		free(out);
	}
	/* A read error ends the loop as the end of the file does. */
	if (status == EXIT_DONE && ferror(input)) status = EXIT_INPUT_UNREADABLE;
	free(line);
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
	status = is_check ? EXIT_DONE : translate_file(table, is_forward, argv[4], argv[5]);
	lou_free();
	return status;
}
