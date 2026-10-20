/*
 * config.h: how TextMouth builds liblouis 3.39.0 (FMT21).
 *
 * liblouis's configure script writes this file from config.h.in for the
 * machine it runs on. TextMouth builds the library from Xcode instead (the
 * liblouis target in project.yml), and never runs configure, so it says here
 * what the library's own sources in liblouis/ read. They read three settings
 * and nothing else (`grep` over liblouis/*.c and internal.h, October 19,
 * 2026): PACKAGE_VERSION, TABLESDIR, and ENABLE_MACROS. Every other line of
 * config.h.in serves gnulib, which the library's sources never include on
 * macOS, whose C library has every function they call.
 *
 * Wide characters are 32 bits (UCS-4), as `configure --enable-ucs4` makes
 * them. That choice is liblouis.h's `widechar` type (include/liblouis.h,
 * TextMouth's copy of liblouis.h.in), not a setting here: with it every
 * Unicode character, and every braille cell U+2800 to U+28FF, fits in one
 * widechar. configure also defines WIDECHARS_ARE_UCS4 for it, which no
 * source of the library reads; it is defined below all the same, so this
 * file says what configure would.
 *
 * Left undefined, on purpose:
 * - ENABLE_MACROS: configure's default (`--enable-macros` is off). The
 *   tables TextMouth bundles define no macro, and a table that did would
 *   be refused when it compiles, which the helper reports as a table that
 *   cannot be loaded.
 * - DEBUG: liblouis's debugging output. The target's preprocessor
 *   definitions leave out the DEBUG=1 Xcode's Debug configuration adds.
 */
#ifndef TEXTMOUTH_LIBLOUIS_CONFIG_H
#define TEXTMOUTH_LIBLOUIS_CONFIG_H

/* The release this copy is, which lou_version() returns. */
#define PACKAGE_VERSION "3.39.0"

/* What configure defines with --enable-ucs4 (read by no source). */
#define WIDECHARS_ARE_UCS4 1

/*
 * The folder liblouis searches last for a table, when the LOUIS_TABLEPATH
 * environment variable is empty; configure makes it the installed tables'
 * folder, $(datadir)/liblouis/tables. TextMouth's helper (TextMouthBraille)
 * always sets LOUIS_TABLEPATH to the app bundle's own tables, which keeps
 * liblouis from searching this folder at all, and names each table by its
 * full path. In case it ever were searched, it is /var/empty, a folder macOS
 * keeps empty, so that no table installed on the Mac (by Homebrew, say) is
 * ever read in place of the bundle's.
 */
#define TABLESDIR "/var/empty"

#endif /* TEXTMOUTH_LIBLOUIS_CONFIG_H */
