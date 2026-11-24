/*
 * TextMouthBraille: the helper that runs liblouis for TextMouth (FMT21).
 *
 * liblouis is C that reads untrusted braille and text, it has had
 * memory-safety bugs, and it is not thread-safe, so the Mac app never calls
 * it in its own process. It runs this small program instead, one run per
 * book, under its watchdog (WatchedProcess, with a time limit, a memory
 * limit, an output cap, and Cancel): a hang or a crash in liblouis costs one
 * run of this helper, never the app or the import. `BrailleTranslator` in the
 * app is its only caller.
 *
 * This file is a thin main around the translation, which is a library both
 * apps build (TextMouthBrailleLibrary.c, whose interface is
 * include/TextMouthBrailleLibrary.h; DR34, November 16, 2026): the iPhone,
 * which may start no helper program, calls the same code in its own process.
 *
 * Usage:
 *   TextMouthBraille check   <tables folder> <table>
 *   TextMouthBraille forward <tables folder> <table> <input file> <output file>
 *   TextMouthBraille back    <tables folder> <table> <input file> <output file>
 *   TextMouthBraille back-liblouis <tables folder> <table> <input file> <output file>
 *
 * - `check` compiles the table, with every table it includes, and exits 0
 *   when it compiles.
 * - `forward` translates print to braille, `back` braille to print, and
 *   `back-liblouis`, which only tests run, braille to print by liblouis alone,
 *   in the line protocol of include/TextMouthBrailleProtocol.h (see
 *   TextMouthBrailleLibrary.c for what each does).
 *
 * The table is a bare file name, such as en-ueb-g2.ctb, of a table in the
 * tables folder: the one the app unpacks the table and every file it
 * includes into (from BrailleTables.pack, into its Caches folder, at first
 * use: FR40), or, for one of this Mac's VoiceOver tables (October 20, 2026),
 * the Mac's own liblouis folder, which the app names (BrailleTableCatalog
 * .macTablesFolder) and reads in place. The folder, the input, and the
 * output are absolute paths. The helper changes into the folder, sets
 * LOUIS_TABLEPATH to "." and loads the table by its bare name, so liblouis
 * resolves every include there, no path it sees holds a comma (it splits
 * paths at commas), and it never reads a table installed elsewhere on the
 * Mac (see TABLESDIR in Vendor/liblouis/config.h). One run reads one folder,
 * never both, so a Mac table's includes come from the Mac's own liblouis
 * version. It then changes into /var/empty.
 *
 * Exit status: the library's statuses, 0 to 7, which
 * include/TextMouthBrailleLibrary.h lists (TMB_EXIT_DONE and the rest); the
 * helper sets no limit of its own, so it never ends with 8 or 9. It prints
 * nothing to its standard output, and liblouis's own errors go to standard
 * error, which TextMouth discards.
 *
 * This file is TextMouth's own, under TextMouth's MIT License. It only calls
 * TextMouth's braille library, and through it liblouis's public API.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "include/TextMouthBrailleLibrary.h"

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
	if (!tmb_is_bare_table_name(name)) return -1;
	if (chdir(folder) != 0 || setenv("LOUIS_TABLEPATH", ".", 1) != 0) return -1;
	if (stat(name, &info) != 0 || !S_ISREG(info.st_mode)) return -1;
	return 0;
}

/*
 * Changes into /var/empty, which macOS keeps empty and no one can write to.
 * Once `tmb_load_table` has loaded the table, liblouis keeps it by its name
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
 * Translates each record of the file at `input_path` into the file at
 * `output_path` in `mode`, with the loaded `table` (`tmb_translate_stream`),
 * and returns the exit status. The output is written record by record, so
 * the watchdog sees it grow while a long book is translated.
 */
static int
translate_files(const char *table, tmb_mode mode, const char *input_path, const char *output_path) {
	FILE *input = fopen(input_path, "rb");
	FILE *output;
	int status;
	if (input == NULL) return TMB_EXIT_INPUT_UNREADABLE;
	output = fopen(output_path, "wb");
	if (output == NULL) {
		fclose(input);
		return TMB_EXIT_OUTPUT;
	}
	/* The watchdog limits the whole helper, so the translation has no
	   limits of its own. */
	status = tmb_translate_stream(table, mode, input, output, NULL);
	fclose(input);
	if (fclose(output) != 0 && status == TMB_EXIT_DONE) status = TMB_EXIT_OUTPUT;
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
	/* Every path is absolute: the helper changes its current directory
	   (see enter_tables_folder) before it opens the input and the output. */
	for (int i = 2; i < argc; i++)
		if (i != 3 && argv[i][0] != '/') paths_absolute = 0;
	if (!paths_absolute ||
			!((is_check && argc == 4) || ((is_forward || is_back || is_liblouis_back) && argc == 6))) {
		fprintf(stderr,
				"usage: TextMouthBraille check <tables folder> <table>\n"
				"       TextMouthBraille forward|back <tables folder> <table> <input> "
				"<output>\n");
		return TMB_EXIT_USAGE;
	}
	/* The table is loaded, with every table it includes, from the tables
	   folder; then the helper leaves the folder, whether it loaded or not. */
	table_loaded = enter_tables_folder(argv[2], table) == 0 && tmb_load_table(table);
	leave_tables_folder();
	if (!table_loaded) {
		tmb_unload_tables();
		return TMB_EXIT_TABLE;
	}
	if (is_check)
		status = TMB_EXIT_DONE;
	else
		status = translate_files(table,
				is_forward ? TMB_MODE_FORWARD : is_back ? TMB_MODE_BACK : TMB_MODE_BACK_LIBLOUIS, argv[4],
				argv[5]);
	tmb_unload_tables();
	return status;
}
