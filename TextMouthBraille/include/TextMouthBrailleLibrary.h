/*
 * TextMouthBrailleLibrary.h: the interface of the braille translation both
 * apps build (TextMouthBraille/TextMouthBrailleLibrary.c, DR34, November 16,
 * 2026).
 *
 * The translation is TextMouth's own code around liblouis. The Mac links it
 * into its braille helper program, TextMouthBraille, whose main.c is a thin
 * main around `tmb_translate_stream`, and runs the helper under its watchdog.
 * The iPhone, which may start no helper program, calls the same code in its
 * own process through `tmb_translate`, which takes the input and gives the
 * output in memory, within the limits of `tmb_limits`. Its Swift imports
 * this header as the Clang module TextMouthBrailleLibrary, whose map is
 * TextMouthBrailleLibrary/module.modulemap in the folder beside it.
 *
 * Both directions read and write the line protocol of
 * TextMouthBrailleProtocol.h: an input begins with the protocol's header line
 * and holds a record for each paragraph, its text on one line and its
 * emphasis codes on the next; the output holds the header and a record for
 * each of the input's, in the same order.
 *
 * liblouis is not thread-safe, and neither is this library: make one call at
 * a time, never two at once from two threads.
 */
#ifndef TEXTMOUTH_BRAILLE_LIBRARY_H
#define TEXTMOUTH_BRAILLE_LIBRARY_H

#include <stddef.h>
#include <stdio.h>

/*
 * How a translation ended. The helper exits with these statuses, and
 * `tmb_translate` reports them in `tmb_response.status`:
 * - 0 done;
 * - 1 the helper's arguments are wrong, or `tmb_translate_stream` was given
 *   a mode it does not translate in (check, which translates nothing);
 * - 2 the table cannot be loaded (no such table in the folder, or it does
 *   not compile);
 * - 3 the input cannot be read;
 * - 4 the input is not what the mode takes (not UTF-8, a NUL, a line longer
 *   than the most characters a record may hold, a record without its code
 *   line, codes that do not fit their text, or in `back` a character that is
 *   not a braille cell or any code at all);
 * - 5 liblouis could not translate a line;
 * - 6 the output cannot be written;
 * - 7 the input does not begin with this protocol's header, as an input
 *   written for another version would not;
 * - 8 the caller's `should_stop` asked the translation to stop (the iPhone's
 *   time limit, or an import's Cancel), never returned to the helper;
 * - 9 the output grew past the caller's `max_output_bytes`, never returned to
 *   the helper either.
 */
enum {
	TMB_EXIT_DONE = 0,
	TMB_EXIT_USAGE = 1,
	TMB_EXIT_TABLE = 2,
	TMB_EXIT_INPUT_UNREADABLE = 3,
	TMB_EXIT_INPUT_INVALID = 4,
	TMB_EXIT_TRANSLATION = 5,
	TMB_EXIT_OUTPUT = 6,
	TMB_EXIT_PROTOCOL = 7,
	TMB_EXIT_STOPPED = 8,
	TMB_EXIT_OUTPUT_CAP = 9,
};

/*
 * What a call does, as the helper's mode arguments name them:
 * - check: loads the table, with every table it includes, and translates
 *   nothing;
 * - forward: print to braille;
 * - back: braille to print, with TextMouth's reading passes;
 * - back-liblouis: braille to print by liblouis alone, without the reading
 *   passes, which only tests ask for.
 */
typedef enum {
	TMB_MODE_CHECK = 0,
	TMB_MODE_FORWARD = 1,
	TMB_MODE_BACK = 2,
	TMB_MODE_BACK_LIBLOUIS = 3,
} tmb_mode;

/*
 * What one translation is allowed. The helper sets none of them, since the
 * app's watchdog limits the whole program; the iPhone sets each, as near the
 * watchdog's limits as one process can come.
 */
typedef struct {
	/* The most characters one record's text may hold, at most the helper's
	   own limit of 1,000,000; 0 for that limit. A longer record is invalid
	   input (status 4). */
	size_t max_record_chars;
	/* The most bytes the output may hold, checked after each record; 0 for
	   no cap. An output past it ends the translation (status 9). */
	size_t max_output_bytes;
	/* Asked before each record, with `context`: an answer other than 0 ends
	   the translation (status 8). NULL never stops it. The signature is
	   FFmpeg's interrupt callback's, so one Swift function serves both. */
	int (*should_stop)(void *context);
	void *context;
} tmb_limits;

/*
 * Whether `name` is a bare file name that can only name a file inside a
 * tables folder: not empty, not starting with a dot, and holding no slash and
 * no comma (liblouis reads a comma as the start of another table). Returns 1
 * or 0.
 */
int tmb_is_bare_table_name(const char *name);

/*
 * Loads `table` as liblouis resolves it, with every table it includes, and
 * sets liblouis to log its errors alone. Returns 1 when the table compiles,
 * 0 when it cannot be loaded. The table stays loaded, by that very string,
 * until `tmb_unload_tables`.
 */
int tmb_load_table(const char *table);

/* Frees every table liblouis has loaded, and the rest of its memory. */
void tmb_unload_tables(void);

/*
 * Translates each record of `input` into `output` in `mode` (forward, back,
 * or back-liblouis) with `table`, already loaded by `tmb_load_table`, within
 * `limits` (NULL for none), and returns the status. The output is written
 * record by record, so a watchdog watching it sees it grow.
 */
int tmb_translate_stream(const char *table, tmb_mode mode, FILE *input, FILE *output, const tmb_limits *limits);

/* One call of `tmb_translate`: what to do, with what, within which limits. */
typedef struct {
	tmb_mode mode;
	/* The folder of tables: an absolute path that holds no comma. */
	const char *tables_folder;
	/* The table, a bare file name inside that folder, such as "en-ueb-g2.ctb". */
	const char *table;
	/* The input, in the protocol, `input_length` bytes; NULL for check.
	   Bytes, so that Swift hands them over as raw memory. */
	const void *input;
	size_t input_length;
	tmb_limits limits;
} tmb_request;

/* What `tmb_translate` gives back. */
typedef struct {
	/* How the call ended (TMB_EXIT_...). */
	int status;
	/* When it is done and the mode translates, the output in the protocol,
	   `output_length` bytes, which the caller frees with free(); otherwise
	   NULL and 0. */
	void *output;
	size_t output_length;
} tmb_response;

/*
 * Translates `request` in memory into `*response`, as one run of the helper
 * would: loads the table from the folder by its full path (never changing the
 * process's current folder or its environment), translates the input, and
 * frees every table liblouis loaded, however it ends. Nothing is kept from
 * one call to the next.
 */
void tmb_translate(const tmb_request *request, tmb_response *response);

#endif /* TEXTMOUTH_BRAILLE_LIBRARY_H */
