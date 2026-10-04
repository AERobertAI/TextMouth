/*
 * config.h: how TextMouth builds LAME 3.100's MP3 encoder.
 *
 * LAME's configure script writes this file for the machine it runs on.
 * TextMouth builds the encoder from Xcode instead (the LAME target in
 * project.yml), for both kinds of Mac it supports, Apple silicon and Intel,
 * so it says here once what configure finds on either: a C library with
 * every standard header, 64-bit and little-endian. These are all the
 * settings the encoder's sources in libmp3lame/ read, each with the value
 * configure gave it on an Apple silicon Mac running macOS 26.
 *
 * Left undefined, on purpose:
 * - HAVE_MPGLIB and DECODE_ON_THE_FLY: no MP3 decoder is built. AVFoundation
 *   decodes MP3; TextMouth needs LAME only to encode.
 * - HAVE_NASM, HAVE_XMMINTRIN_H, and MMX_choose_table: no x86 assembly or
 *   SSE routines, so one portable C build serves both kinds of Mac.
 * - TAKEHIRO_IEEE754_HACK and USE_FAST_LOG: shortcuts configure turns on
 *   only for Intel processors; left off, as configure leaves them on Apple
 *   silicon, where TextMouth's release builds run.
 * - NDEBUG: LAME keeps its assertions in release builds, as its configure
 *   script does ("they check for issues"), and so does TextMouth.
 */
#ifndef LAME_CONFIG_H
#define LAME_CONFIG_H

/* The standard C headers, which macOS has: stdlib.h and string.h, then
   errno.h, fcntl.h, and inttypes.h (which brings stdint.h). */
#define STDC_HEADERS 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDINT_H 1

/* The IEEE 754 types LAME names its single- and double-precision floats
   by, which configure declares when the system does not. */
typedef float ieee754_float32_t;
typedef double ieee754_float64_t;

#endif /* LAME_CONFIG_H */
