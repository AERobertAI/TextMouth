#!/usr/bin/env python3
"""test_build.py: tests of Scripts/vendor/ffmpeg/build.py, the FFmpeg build TextMouth links.

They build nothing: they check the pin and that only a file of its size and SHA-256 is built
from, the configure line (all of it LGPL, every component the
import reads, no path of the building Mac), the key, the archive reader that merges FFmpeg's
libraries, the Mach-O platform check, the path scan, the refusal of a tarball member outside its
folder, the Xcode settings, and that the notices both apps ship are the release's own and the
README is what the script writes. make check-selftest runs them:

    python3 -I -B Scripts/vendor/ffmpeg/test_build.py

The few files they write go into build/test-ffmpeg-build/ (gitignored), overwritten each run;
nothing is deleted.
"""
import gzip
import importlib.util
import io
import lzma
import os
import shlex
import struct
import subprocess
import sys
import tarfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("ffmpeg_build", HERE / "build.py")
build = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(build)

# These tests never unpack into the main checkout's shared source folder: each test that unpacks
# keeps its source under its own scratch work folder, and the tests of the sharing (SharedSourceTests)
# set a scratch folder of their own.
build.SHARED_SOURCES = None

# Where these tests write: a fixed, gitignored folder, overwritten each run.
SCRATCH = build.REPOSITORY / "build" / "test-ffmpeg-build"

# The SHA-256 of FFmpeg 9.0.2's LICENSE.md and COPYING.LGPLv2.1, as the release holds them: the
# copies both apps ship must stay the release's own text.
RELEASE_NOTICE_DIGESTS = {
    "LICENSE.md": "2e1d16c72fd74e12063776371da757322f8b77589386532f4fd8634bde7de1af",
    "COPYING.LGPLv2.1": "246041b6ecf9bc32d718a62c57877c78b5eb397b6467e74ed7ae2626ab189c30",
}


def archive(members):
    """A BSD archive holding `members` ((name, bytes)), the first with a long name ("#1/<n>"), as
    Apple's libtool writes them, and a symbol table first, which the reader must skip."""
    def header(name, size):
        return (name.ljust(16) + "0".ljust(12) + "0".ljust(6) + "0".ljust(6) + "644".ljust(8)
                + str(size).ljust(10) + "`\n").encode("ascii")
    data = b"!<arch>\n" + header("__.SYMDEF SORTED", 4) + b"\0\0\0\0"
    for index, (name, body) in enumerate(members):
        if index == 0:
            encoded = name.encode("utf-8") + b"\0" * (8 - len(name) % 8)
            payload = encoded + body
            data += header(f"#1/{len(encoded)}", len(payload)) + payload
        else:
            data += header(name, len(body)) + body
        if len(data) % 2:
            data += b"\n"
    return data


def mach_o(platform_number, major, minor):
    """A 64-bit Mach-O header with one LC_BUILD_VERSION command for the platform and minimum."""
    command = struct.pack("<IIIIII", 0x32, 24, platform_number, (major << 16) | (minor << 8), 0, 0)
    return struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 1, 1, len(command), 0, 0) + command


class PinAndConfigureTests(unittest.TestCase):
    """The pin, and the configure line of every platform."""

    def test_the_pin_names_one_release(self):
        self.assertEqual(build.FFMPEG_URL, f"https://ffmpeg.org/releases/ffmpeg-{build.FFMPEG_VERSION}.tar.xz")
        self.assertRegex(build.FFMPEG_SHA256, r"^[0-9a-f]{64}$")
        self.assertRegex(build.SIGNING_KEY_FINGERPRINT, r"^[0-9A-F]{40}$")
        self.assertGreater(build.FFMPEG_TARBALL_BYTES, 1_000_000)

    def test_every_configure_line_is_lgpl_and_holds_no_absolute_path(self):
        for platform in build.PLATFORMS:
            arguments = build.configure_arguments(platform)
            for forbidden in ("--enable-gpl", "--enable-nonfree", "--enable-version3", "--prefix"):
                self.assertFalse(any(argument.startswith(forbidden) for argument in arguments), (platform, forbidden))
            # No argument names a folder of any Mac: the compiler is the wrapper found on PATH.
            self.assertFalse([argument for argument in arguments if "/" in argument.split("=", 1)[-1]], platform)
            self.assertIn(f"--cc={build.COMPILER_WRAPPER} --target={build.PLATFORMS[platform]['target']}", arguments)

    def test_every_component_the_import_reads_is_asked_for(self):
        arguments = build.configure_arguments("macosx")
        for kind, names in (("demuxer", build.DEMUXERS), ("decoder", build.DECODERS), ("parser", build.PARSERS)):
            for name in names:
                self.assertIn(f"--enable-{kind}={name}", arguments)
        # The containers the import's own sniff names (FFmpegContainer.demuxer), each a demuxer here.
        for demuxer in ("asf", "matroska", "flv", "avi", "rm", "mpc", "mpc8", "ogg"):
            self.assertIn(demuxer, build.DEMUXERS)
        # The five WMA decoders, and Opus, which needs libswresample (not disabled).
        for decoder in ("wmav1", "wmav2", "wmapro", "wmalossless", "wmavoice", "opus"):
            self.assertIn(decoder, build.DECODERS)
        self.assertNotIn("--disable-swresample", arguments)

    def test_only_the_iphone_cross_compiles(self):
        self.assertNotIn("--enable-cross-compile", build.configure_arguments("macosx"))
        for platform in ("iphoneos", "iphonesimulator"):
            self.assertIn("--enable-cross-compile", build.configure_arguments(platform))

    def test_the_line_reads_back_as_it_was(self):
        for platform in build.PLATFORMS:
            arguments = build.configure_arguments(platform)
            self.assertEqual(shlex.split(build.shell_line(arguments)), arguments)

    def test_the_key_follows_what_decides_the_build(self):
        mac = build.build_key("macosx", "clang 1")
        self.assertEqual(mac, build.build_key("macosx", "clang 1"))
        self.assertNotEqual(mac, build.build_key("iphoneos", "clang 1"))
        self.assertNotEqual(mac, build.build_key("macosx", "clang 2"))
        # A change of the configure line (--enable-small, or one more decoder), of the pin, or
        # of the recipe gives another key, so the build is made again instead of skipped.
        changes = {"ENABLE_SMALL": not build.ENABLE_SMALL, "DECODERS": build.DECODERS + ["tmff_test_decoder"],
                   "FFMPEG_SHA256": "0" * 64, "RECIPE": build.RECIPE + 1}
        for name, value in changes.items():
            with mock.patch.object(build, name, value):
                self.assertNotEqual(mac, build.build_key("macosx", "clang 1"), name)
        self.assertEqual(mac, build.build_key("macosx", "clang 1"))

    def test_the_wrapper_maps_the_work_folder_and_the_source_folder_away(self):
        text = build.compiler_wrapper_text()
        self.assertIn('-ffile-prefix-map="$TMFF_BUILD_ROOT"=.', text)
        self.assertIn('-fdebug-prefix-map="$TMFF_BUILD_ROOT"=.', text)
        # The source's folder may be outside the work folder (the shared one), and is named the
        # same wherever it is, so what is built does not change with it.
        self.assertIn('-ffile-prefix-map="$TMFF_SOURCE_ROOT"=./source', text)
        self.assertIn('-fdebug-prefix-map="$TMFF_SOURCE_ROOT"=./source', text)
        self.assertTrue(text.startswith("#!/bin/sh\n"))


class ArchiveAndObjectTests(unittest.TestCase):
    """The archive reader the merge uses, and the platform check of each object."""

    def test_members_are_read_with_their_long_names_and_without_the_symbol_table(self):
        SCRATCH.mkdir(parents=True, exist_ok=True)
        path = SCRATCH / "libsample.a"
        path.write_bytes(archive([("a-long-member-name.o", b"abc"), ("utils.o", b"defg"), ("utils.o", b"h")]))
        self.assertEqual(build.archive_members(path),
                         [("a-long-member-name.o", b"abc"), ("utils.o", b"defg"), ("utils.o", b"h")])

    def test_a_file_that_is_no_archive_is_refused(self):
        SCRATCH.mkdir(parents=True, exist_ok=True)
        path = SCRATCH / "not-an-archive.a"
        path.write_bytes(b"not an archive")
        with self.assertRaises(build.BuildError):
            build.archive_members(path)

    def test_an_object_says_which_platform_it_was_built_for(self):
        self.assertEqual(build.built_for(mach_o(1, 14, 0)), "macOS 14.0")
        self.assertEqual(build.built_for(mach_o(2, 26, 0)), "iOS 26.0")
        self.assertEqual(build.built_for(mach_o(7, 26, 0)), "iOS simulator 26.0")
        self.assertIsNone(build.built_for(b"\x7fELF" + b"\0" * 60))
        self.assertIsNone(build.built_for(b""))
        for platform, number in (("macosx", 1), ("iphoneos", 2), ("iphonesimulator", 7)):
            major = 14 if platform == "macosx" else 26
            self.assertEqual(build.built_for(mach_o(number, major, 0)), build.PLATFORMS[platform]["built_for"])


class PathTests(unittest.TestCase):
    """The scan for folders of the building Mac."""

    def test_the_forbidden_paths_name_the_home_the_checkout_and_the_temporary_folder(self):
        forbidden = build.forbidden_paths(SCRATCH)
        self.assertIn(str(Path.home()), forbidden)
        self.assertIn(str(build.REPOSITORY), forbidden)
        self.assertIn("/Users/", forbidden)
        self.assertTrue(all(len(path) > 1 for path in forbidden), forbidden)

    def test_a_planted_path_is_found(self):
        forbidden = ["/Users/", "/private/var/folders/xy"]
        text = "ordinary\n--prefix=/Users/reader/install\nsrc/libavcodec/wmadec.c\n/private/var/folders/xy/T\n"
        self.assertEqual(build.paths_found(text, forbidden), ["--prefix=/Users/reader/install", "/private/var/folders/xy/T"])
        self.assertEqual(build.paths_found("src/libavformat/asfdec_f.c\n", forbidden), [])

    def test_a_build_holding_a_folder_of_this_mac_fails(self):
        # The build's own check, strings and all: a file naming the work folder fails it, by name.
        SCRATCH.mkdir(parents=True, exist_ok=True)
        work = SCRATCH / "work-paths"
        clean = SCRATCH / "clean.o"
        clean.write_bytes(b"\0\0src/libavcodec/wmadec.c\0\0")
        planted = SCRATCH / "planted.o"
        planted.write_bytes(b"\0\0ordinary text\0" + str(work.resolve() / "src" / "x.c").encode("utf-8") + b"\0\0")
        build.check_no_mac_paths([clean], work)
        with self.assertRaises(build.BuildError) as caught:
            build.check_no_mac_paths([clean, planted], work)
        self.assertIn("planted.o", str(caught.exception))
        self.assertNotIn("clean.o", str(caught.exception))


class ReleaseTests(unittest.TestCase):
    """The release's unpacking, and the notices the apps ship."""

    def tarball(self, name, members, compressed="xz"):
        """A .tar.xz (or .tar.gz) in the scratch folder holding `members` ((name, bytes))."""
        SCRATCH.mkdir(parents=True, exist_ok=True)
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w") as archive_file:
            for member, body in members:
                info = tarfile.TarInfo(member)
                info.size = len(body)
                archive_file.addfile(info, io.BytesIO(body))
        path = SCRATCH / name
        path.write_bytes(lzma.compress(buffer.getvalue()) if compressed == "xz" else gzip.compress(buffer.getvalue()))
        return path

    def test_only_the_pinned_release_is_built_from(self):
        # A small file's size and SHA-256 stand in for the pin, so no 12 MB release is needed.
        SCRATCH.mkdir(parents=True, exist_ok=True)
        pinned = SCRATCH / "pinned.tar.xz"
        pinned.write_bytes(b"the pinned release")
        flipped = SCRATCH / "flipped.tar.xz"
        flipped.write_bytes(b"the pinned releasE")  # the same size, one byte changed: only the digest differs
        work = SCRATCH / "work-pin"
        wanted = work / "download" / build.tarball_name()
        with mock.patch.object(build, "FFMPEG_SHA256", build.digest_of(pinned)), \
                mock.patch.object(build, "FFMPEG_TARBALL_BYTES", pinned.stat().st_size), \
                mock.patch.object(build, "SHARED_DOWNLOADS", None):
            self.assertTrue(build.is_the_release(pinned))
            self.assertFalse(build.is_the_release(flipped))
            self.assertFalse(build.is_the_release(SCRATCH / "no-such.tar.xz"))
            # A file in the work folder that is not the release is not used; a file given that
            # is not the release is refused and never copied in; the release given is.
            wanted.parent.mkdir(parents=True, exist_ok=True)
            wanted.write_bytes(b"stale")
            with self.assertRaises(build.BuildError):
                build.release_tarball(work, given=flipped)
            self.assertEqual(wanted.read_bytes(), b"stale")
            found, source = build.release_tarball(work, given=pinned)
            self.assertEqual((found, source["name"]), (wanted, "ffmpeg.org"))
            self.assertEqual(wanted.read_bytes(), pinned.read_bytes())

    def test_a_member_outside_the_release_folder_is_refused(self):
        prefix = f"ffmpeg-{build.FFMPEG_VERSION}"
        for bad in (f"{prefix}/../escaped", "elsewhere/configure", "/absolute"):
            path = self.tarball("bad.tar.xz", [(f"{prefix}/configure", b"#!/bin/sh\n"), (bad, b"x")])
            work = SCRATCH / "work-bad"
            # A marker left by a run whose check was broken would skip the unpacking, and the
            # check with it, so a fixed check would still fail here: it is moved aside (over the
            # last one moved), never deleted.
            marker = build.unpacked_marker(work)
            if marker.exists():
                os.replace(marker, marker.with_name(marker.name + ".stale"))
            with self.assertRaises(build.BuildError, msg=bad):
                # The first source is named, as a release from it is: without it the archive
                # would be refused for not being the release, and the check would go untried.
                build.unpacked_release(work, path, build.sources()[0])

    def test_the_shipped_notices_are_the_releases_own(self):
        for name, digest in RELEASE_NOTICE_DIGESTS.items():
            path = build.NOTICES_FOLDER / name
            self.assertTrue(path.is_file(), path)
            self.assertEqual(build.digest_of(path), digest, name)

    def test_the_readme_is_what_the_script_writes(self):
        path = build.NOTICES_FOLDER / "README"
        self.assertEqual(path.read_text(encoding="utf-8"), build.readme_text())
        text = build.readme_text()
        self.assertIn("This software uses libraries from the FFmpeg project under the LGPLv2.1.", text)
        self.assertIn(build.FFMPEG_SHA256, text)
        self.assertIn(build.FFMPEG_URL, text)
        self.assertIn(build.GITHUB_URL, text)
        self.assertIn(build.GITHUB_SHA256, text)
        # The README says the release is changed, and how: each patch by its commit, CVE, and digest.
        self.assertNotIn("unmodified", text)
        self.assertIn(f"FFmpeg {build.FFMPEG_VERSION} with {len(build.PATCHES)} upstream patches", text)
        for commit, cve, digest in build.PATCHES:
            self.assertIn(f"{cve}: {commit}", text)
            self.assertIn(digest, text)

    def test_the_readme_of_no_patches_says_the_release_is_unchanged(self):
        with mock.patch.object(build, "PATCHES", []):
            text = build.readme_text()
        self.assertIn("TextMouth does not change the release", text)
        self.assertNotIn("upstream patches", text)


class SecondSourceTests(unittest.TestCase):
    """The release's second place to download from: FFmpeg's mirror on GitHub."""

    def pinned_files(self):
        """Two small files standing in for the two pinned archives, and the patches of the pins
        to use them: (first, second, mock context managers)."""
        SCRATCH.mkdir(parents=True, exist_ok=True)
        first = SCRATCH / "source-first.tar.xz"
        first.write_bytes(b"the first source's release")
        second = SCRATCH / "source-second.tar.gz"
        second.write_bytes(b"the second source's archive!")
        pins = [
            mock.patch.object(build, "FFMPEG_SHA256", build.digest_of(first)),
            mock.patch.object(build, "FFMPEG_TARBALL_BYTES", first.stat().st_size),
            mock.patch.object(build, "GITHUB_SHA256", build.digest_of(second)),
            mock.patch.object(build, "GITHUB_TARBALL_BYTES", second.stat().st_size),
            mock.patch.object(build, "SHARED_DOWNLOADS", None),
        ]
        return first, second, pins

    def fresh_work(self, name):
        """A work folder whose download folder holds only stale files (overwritten, never
        deleted, so a run is the same after any earlier one), and its path."""
        work = SCRATCH / name
        (work / "download").mkdir(parents=True, exist_ok=True)
        for source in build.sources():
            (work / "download" / source["file"]).write_bytes(b"stale")
        return work

    def test_the_github_archive_is_pinned_and_tried_second(self):
        self.assertEqual(build.GITHUB_URL, f"https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n{build.FFMPEG_VERSION}.tar.gz")
        self.assertRegex(build.GITHUB_SHA256, r"^[0-9a-f]{64}$")
        self.assertNotEqual(build.GITHUB_SHA256, build.FFMPEG_SHA256)
        self.assertGreater(build.GITHUB_TARBALL_BYTES, 1_000_000)
        names = [source["name"] for source in build.sources()]
        self.assertEqual(names, ["ffmpeg.org", "github.com"])
        self.assertEqual([source["url"] for source in build.sources()], [build.FFMPEG_URL, build.GITHUB_URL])
        self.assertEqual(len({source["file"] for source in build.sources()}), 2, "each is kept under a name of its own")

    def test_the_second_source_is_tried_when_the_first_fails_or_gives_the_wrong_file(self):
        first, second, pins = self.pinned_files()
        for first_gives in (None, b"not the release at all"):
            calls = []

            def download(url, destination, first_gives=first_gives, calls=calls):
                calls.append(url)
                if url == build.FFMPEG_URL:
                    if first_gives is None:
                        raise build.BuildError("curl: could not connect")
                    destination.write_bytes(first_gives)
                else:
                    destination.write_bytes(second.read_bytes())

            work = self.fresh_work(f"work-second-{len(first_gives or b'')}")
            with pins[0], pins[1], pins[2], pins[3], pins[4], mock.patch.object(build, "download", download):
                found, source = build.release_tarball(work)
            self.assertEqual(calls, [build.FFMPEG_URL, build.GITHUB_URL], first_gives)
            self.assertEqual((found.name, source["name"]), ("ffmpeg-9.0.2-github.tar.gz", "github.com"))
            self.assertEqual(found.read_bytes(), second.read_bytes())

    def test_the_second_source_is_not_asked_when_the_first_gives_the_release(self):
        first, second, pins = self.pinned_files()
        calls = []

        def download(url, destination):
            calls.append(url)
            destination.write_bytes(first.read_bytes())

        with pins[0], pins[1], pins[2], pins[3], pins[4], mock.patch.object(build, "download", download):
            found, source = build.release_tarball(self.fresh_work("work-first"))
        self.assertEqual((calls, source["name"]), ([build.FFMPEG_URL], "ffmpeg.org"))

    def test_a_release_no_source_gives_is_refused_naming_each_source(self):
        first, second, pins = self.pinned_files()

        def download(url, destination):
            destination.write_bytes(b"neither of the pinned files")

        with pins[0], pins[1], pins[2], pins[3], pins[4], mock.patch.object(build, "download", download):
            with self.assertRaises(build.BuildError) as caught:
                build.release_tarball(self.fresh_work("work-neither"))
        for name in ("ffmpeg.org", "github.com"):
            self.assertIn(name, str(caught.exception))

    def test_the_github_archive_unpacks_to_the_same_folder_as_the_release(self):
        # Its one top folder is named for the tag; it is renamed, so both sources give the same
        # paths (and the same __FILE__ strings in what is built).
        members = [(f"{build.GITHUB_TOP_FOLDER}/configure", b"#!/bin/sh\n"), (f"{build.GITHUB_TOP_FOLDER}/libavcodec/x.c", b"int x;\n")]
        path = ReleaseTests.tarball(self, "github-shaped.tar.gz", members, compressed="gz")
        work = SCRATCH / "work-github"
        marker = build.unpacked_marker(work)
        if marker.exists():
            os.replace(marker, marker.with_name(marker.name + ".stale"))
        github = next(source for source in build.sources() if source["name"] == "github.com")
        with mock.patch.object(build, "PATCHES", []):
            folder = build.unpacked_release(work, path, github)
        self.assertEqual(folder.name, f"ffmpeg-{build.FFMPEG_VERSION}")
        self.assertEqual((folder / "libavcodec" / "x.c").read_bytes(), b"int x;\n")
        self.assertTrue((folder / "configure").is_file())
        # A member of the other source's folder is outside this source's.
        wrong = ReleaseTests.tarball(self, "github-wrong.tar.gz", [(f"ffmpeg-{build.FFMPEG_VERSION}/configure", b"x")], compressed="gz")
        with mock.patch.object(build, "PATCHES", []), self.assertRaises(build.BuildError):
            build.unpacked_release(SCRATCH / "work-github-wrong", wrong, github)


class PatchTests(unittest.TestCase):
    """The five upstream patches applied to the release."""

    # The fixes of FFmpeg's development branch that NVD cites for the CVEs open in 9.0.2.
    EXPECTED = [
        ("968e9e948ed8c9ba90dbc875e60b843c755cf4ba", "CVE-2026-125104"),
        ("5d59b7c45d7142bddd13ddc8891e72c5c7dc991b", "CVE-2026-125171"),
        ("7145d13201c9f9c5253f40295714faa4f4ada1a0", "CVE-2026-125182"),
        ("972fe1ccd326538fe9a6b5d5094b7880b5443429", "CVE-2026-125221"),
        ("90f5e61a1da2dcc0050169af8ca593530f26071b", "CVE-2026-125224"),
    ]

    # A one-line patch of a made-up file, in the form GitHub gives (git's unified diff).
    TINY_PATCH = (
        "From 0123456789abcdef0123456789abcdef01234567 Mon Sep 17 00:00:00 2001\n"
        "Subject: [PATCH] a test\n\n---\n a.c | 2 +-\n 1 file changed, 1 insertion(+), 1 deletion(-)\n\n"
        "diff --git a/a.c b/a.c\n--- a/a.c\n+++ b/a.c\n@@ -1,3 +1,3 @@\n line one\n-line two\n+line two, patched\n line three\n"
    )

    def patch_folder(self, name, patches):
        """A scratch folder of patch files ((file name, text)) and the pins naming them: (folder, pins)."""
        folder = SCRATCH / name
        folder.mkdir(parents=True, exist_ok=True)
        pins = []
        for commit, text in patches:
            (folder / f"{commit}.patch").write_text(text, encoding="utf-8")
            pins.append((commit, "CVE-0000-0", build.digest_of(folder / f"{commit}.patch")))
        return folder, pins

    def tree(self, name):
        """A scratch tree holding a.c, the file TINY_PATCH changes."""
        folder = SCRATCH / name
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "a.c").write_text("line one\nline two\nline three\n", encoding="utf-8")
        return folder

    def test_the_five_fixes_are_pinned_in_order_by_their_digests(self):
        self.assertEqual([(commit, cve) for commit, cve, _ in build.PATCHES], self.EXPECTED)
        for commit, cve, digest in build.PATCHES:
            path = build.PATCHES_FOLDER / f"{commit}.patch"
            self.assertTrue(path.is_file(), path)
            self.assertRegex(digest, r"^[0-9a-f]{64}$")
            self.assertEqual(build.digest_of(path), digest, f"{commit} ({cve}) is not the pinned file")

    def test_the_patches_are_applied_in_order_and_are_part_of_the_key(self):
        folder, pins = self.patch_folder("patches-ok", [("a" * 40, self.TINY_PATCH)])
        tree = self.tree("tree-ok")
        with mock.patch.object(build, "PATCHES", pins), mock.patch.object(build, "PATCHES_FOLDER", folder):
            self.assertEqual(build.apply_patches(tree), ["a" * 40])
            with_patch = build.build_key("macosx", "clang 1")
        self.assertEqual((tree / "a.c").read_text(encoding="utf-8"), "line one\nline two, patched\nline three\n")
        # Another list of patches, or none, is another build, and another unpacked folder.
        with mock.patch.object(build, "PATCHES", []):
            none = build.build_key("macosx", "clang 1")
            none_folder = build.unpacked_parent(SCRATCH / "work-keys")
        with mock.patch.object(build, "PATCHES", pins):
            self.assertEqual(build.build_key("macosx", "clang 1"), with_patch)
            self.assertNotEqual(build.unpacked_parent(SCRATCH / "work-keys"), none_folder)
        self.assertNotEqual(with_patch, none)
        self.assertNotEqual(build.patches_digest(), "none")

    def test_the_order_of_the_patches_changes_the_key(self):
        forward = build.build_key("macosx", "clang 1")
        with mock.patch.object(build, "PATCHES", list(reversed(build.PATCHES))):
            self.assertNotEqual(build.build_key("macosx", "clang 1"), forward)

    def test_a_patch_that_does_not_apply_fails_the_build(self):
        folder, pins = self.patch_folder("patches-bad", [("b" * 40, self.TINY_PATCH)])
        tree = self.tree("tree-bad")
        (tree / "a.c").write_text("another file\nentirely\nwith no match\n", encoding="utf-8")
        with mock.patch.object(build, "PATCHES", pins), mock.patch.object(build, "PATCHES_FOLDER", folder):
            with self.assertRaises(build.BuildError) as caught:
                build.apply_patches(tree)
        self.assertIn("does not apply cleanly", str(caught.exception))
        self.assertIn("b" * 40, str(caught.exception))

    def test_a_patch_that_is_not_the_pinned_file_is_refused_before_it_is_applied(self):
        folder, pins = self.patch_folder("patches-changed", [("c" * 40, self.TINY_PATCH)])
        (folder / f"{'c' * 40}.patch").write_text(self.TINY_PATCH.replace("patched", "pwned"), encoding="utf-8")
        tree = self.tree("tree-changed")
        with mock.patch.object(build, "PATCHES", pins), mock.patch.object(build, "PATCHES_FOLDER", folder):
            with self.assertRaises(build.BuildError) as caught:
                build.apply_patches(tree)
        self.assertIn("not the pinned patch", str(caught.exception))
        self.assertEqual((tree / "a.c").read_text(encoding="utf-8"), "line one\nline two\nline three\n")

    def test_a_missing_patch_file_is_refused(self):
        folder, pins = self.patch_folder("patches-missing", [])
        with mock.patch.object(build, "PATCHES", [("d" * 40, "CVE-0000-0", "0" * 64)]), \
                mock.patch.object(build, "PATCHES_FOLDER", folder):
            with self.assertRaises(build.BuildError):
                build.apply_patches(self.tree("tree-missing"))

    def test_the_patches_apply_cleanly_to_the_release_in_a_scratch_copy_when_it_is_at_hand(self):
        # The real proof, when the release is in the shared download folder: unpack it and patch
        # it (in WORK-sized scratch), every one of the five applying with no fuzz.
        shared = build.SHARED_DOWNLOADS
        release = shared / build.tarball_name() if shared is not None else None
        if release is None or not build.is_the_release(release):
            self.skipTest("FFmpeg's release is not in the shared download folder")
        work = SCRATCH / "work-real-patches"
        folder = build.unpacked_release(work, release, build.sources()[0])
        self.assertTrue(build.unpacked_marker(work).is_file())
        marker = build.unpacked_marker(work).read_text(encoding="utf-8").split()
        self.assertEqual(marker[2:], [commit for commit, _, _ in build.PATCHES])
        self.assertTrue((folder / "libavcodec" / "cook.c").is_file())


class SharedSourceTests(unittest.TestCase):
    """One copy of FFmpeg's release and its unpacked source, shared by every build folder of a Mac
    (FU-FFMPEG2): a second build in another DerivedData unpacks and copies nothing."""

    def release(self, name):
        """A tiny archive of a release with the one folder `ffmpeg-<version>` holding a configure
        script, and the source that names it, with the pins made to stand for it: (path, source, pins)."""
        # A member that differs each run makes each run's archive another pin, so a folder an
        # earlier run left in the scratch folder is never taken for this run's.
        path = ReleaseTests.tarball(self, name, [(f"ffmpeg-{build.FFMPEG_VERSION}/configure", b"#!/bin/sh\n"),
                                                  (f"ffmpeg-{build.FFMPEG_VERSION}/libavutil/x.c", b"int x;\n"),
                                                  (f"ffmpeg-{build.FFMPEG_VERSION}/RUN", os.urandom(8).hex().encode("ascii"))])
        pins = [
            mock.patch.object(build, "FFMPEG_SHA256", build.digest_of(path)),
            mock.patch.object(build, "FFMPEG_TARBALL_BYTES", path.stat().st_size),
            mock.patch.object(build, "PATCHES", []),
        ]
        return path, build.sources()[0], pins

    def shared(self, name):
        """A scratch folder standing for build/ffmpeg of the main checkout, and the patches that put
        it in the module's place (download and source folders in it)."""
        root = SCRATCH / name
        return root, [
            mock.patch.object(build, "SHARED_ROOT", root),
            mock.patch.object(build, "SHARED_DOWNLOADS", root / "download"),
            mock.patch.object(build, "SHARED_SOURCES", root / "source"),
        ]

    def test_the_shared_folders_are_the_main_checkouts_build_ffmpeg(self):
        # Unpatched, as the module found them: the archives and the unpacked sources are siblings
        # in one folder, which is the main checkout's (test_repo_paths.py holds it to git's).
        original = importlib.util.module_from_spec(_spec)
        _spec.loader.exec_module(original)
        if original.SHARED_ROOT is None:
            self.skipTest("not in a git checkout")
        self.assertEqual(original.SHARED_DOWNLOADS, original.SHARED_ROOT / "download")
        self.assertEqual(original.SHARED_SOURCES, original.SHARED_ROOT / "source")
        self.assertEqual(original.SHARED_ROOT.parts[-2:], ("build", "ffmpeg"))

    def test_a_second_build_folder_unpacks_nothing_and_keeps_no_copy(self):
        path, source, pins = self.release("shared-release.tar.xz")
        root, shared = self.shared("shared-one")
        first, second = SCRATCH / "work-shared-first", SCRATCH / "work-shared-second"
        with pins[0], pins[1], pins[2], shared[0], shared[1], shared[2]:
            marker = build.unpacked_marker(first)
            # The marker of an earlier run, if there was one, is moved aside (never deleted), so
            # the first build below really unpacks.
            if marker.exists():
                os.replace(marker, marker.with_name(marker.name + ".earlier"))
            folder = build.unpacked_release(first, path, source)
            self.assertEqual(folder.parent.parent, root / "source", "the source is in the shared folder")
            self.assertEqual((folder / "libavutil" / "x.c").read_bytes(), b"int x;\n")
            # The second build folder, another DerivedData, is handed the same folder, and the
            # archive is not even opened: nothing is unpacked, so nothing is written.
            with mock.patch.object(build.tarfile, "open", side_effect=AssertionError("unpacked again")):
                again = build.unpacked_release(second, path, source)
            self.assertEqual(again, folder)
            # Neither work folder holds a copy of the source.
            self.assertFalse((first / "source").exists())
            self.assertFalse((second / "source").exists())
            # The archive is kept in the shared download folder, and a second build uses it where
            # it is: nothing is copied into its work folder.
            kept, kept_source = build.release_tarball(first, given=path)
            self.assertEqual(kept.parent, root / "download")
            with mock.patch.object(build, "copy_replacing", side_effect=AssertionError("copied")), \
                    mock.patch.object(build, "download", side_effect=AssertionError("downloaded")):
                found, found_source = build.release_tarball(second)
            self.assertEqual((found, found_source["name"]), (kept, kept_source["name"]))
            self.assertFalse((second / "download").exists())

    def test_the_source_folder_is_keyed_by_the_release_and_the_patches(self):
        path, source, pins = self.release("shared-keyed.tar.xz")
        root, shared = self.shared("shared-keyed")
        with pins[0], pins[1], pins[2], shared[0], shared[1], shared[2]:
            plain = build.unpacked_parent(SCRATCH / "work-keyed-a")
            self.assertEqual(plain, build.unpacked_parent(SCRATCH / "work-keyed-b"), "any build folder, one source")
            with mock.patch.object(build, "PATCHES", [("e" * 40, "CVE-0000-0", "0" * 64)]):
                patched = build.unpacked_parent(SCRATCH / "work-keyed-a")
        # Another list of patches unpacks beside it, never over it.
        self.assertNotEqual(plain, patched)
        self.assertEqual(plain.parent, patched.parent)

    def test_the_unpacking_holds_a_lock_so_two_checkouts_never_unpack_over_each_other(self):
        path, source, pins = self.release("shared-locked.tar.xz")
        root, shared = self.shared("shared-locked")
        work = SCRATCH / "work-shared-locked"
        held = []

        @build.contextlib.contextmanager
        def watching(lock_path):
            """Stands in for the lock: notes that it was held while the archive was read."""
            held.append(str(lock_path))
            yield
            held.append("released")

        with pins[0], pins[1], pins[2], shared[0], shared[1], shared[2]:
            marker = build.unpacked_marker(work)
            if marker.exists():
                os.replace(marker, marker.with_name(marker.name + ".earlier"))
            real_open = build.tarfile.open

            def opening(*arguments, **keywords):
                held.append("opened")
                return real_open(*arguments, **keywords)

            with mock.patch.object(build, "exclusive", watching), mock.patch.object(build.tarfile, "open", opening):
                build.unpacked_release(work, path, source)
        self.assertEqual(held[1:], ["opened", "released"])
        # The lock is a file beside the key's folder in the shared folder, shared by every checkout.
        self.assertEqual(Path(held[0]).parent, root / "source")

    # What the process that unpacks does in test_a_second_process_waits_for_the_first_and_never_opens_the_archive:
    # it loads build.py, unpacks the archive with the shared folders in `root`, and takes its time inside the lock
    # (apply_patches is slow), after writing a file that says it holds it. Arguments: build.py, root, archive,
    # the work folder, the signal file, and the SHA-256 and size of the archive, as the pin.
    UNPACKER = """
import importlib.util, sys, time
from pathlib import Path
from unittest import mock
path, root, archive, work, signal, digest, size = sys.argv[1:8]
spec = importlib.util.spec_from_file_location("ffmpeg_build", path)
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
build.SHARED_ROOT, build.SHARED_DOWNLOADS, build.SHARED_SOURCES = Path(root), Path(root) / "download", Path(root) / "source"
build.FFMPEG_SHA256, build.FFMPEG_TARBALL_BYTES, build.PATCHES = digest, int(size), []
real = build.apply_patches
def slow(folder):
    Path(signal).write_text("holding")
    time.sleep(2.0)
    return real(folder)
build.apply_patches = slow
build.unpacked_release(Path(work), Path(archive), build.sources()[0])
"""

    def test_a_second_process_waits_for_the_first_and_never_opens_the_archive(self):
        # Two processes at once, as two checkouts building together are: one unpacks (slowly, in the
        # lock), and the other asks for the same release meanwhile. It must wait for the lock, find
        # the marker the first wrote, and return the folder without opening the archive: a second
        # unpacking over a tree the first (or a build of it) is using would break it. A marker
        # written after the lock was let go, or no second look inside the lock, fails this.
        path, source, pins = self.release("shared-two-processes.tar.xz")
        root = SCRATCH / "shared-two-processes"
        # A signal file of a name no earlier run used, so that one left behind is never mistaken for this run's.
        signal = SCRATCH / f"shared-two-processes-signal-{os.urandom(6).hex()}"
        with pins[0], pins[1], pins[2]:
            digest, size = build.FFMPEG_SHA256, build.FFMPEG_TARBALL_BYTES
            first = subprocess.Popen([sys.executable, "-I", "-B", "-c", self.UNPACKER, str(HERE / "build.py"), str(root), str(path),
                                      str(SCRATCH / "work-two-first"), str(signal), digest, str(size)],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 60
                while not signal.exists():
                    if first.poll() is not None:  # (not an f-string in assertIsNone: communicate() would wait for it to end)
                        self.fail(f"the first process ended early: {first.communicate()}")
                    self.assertLess(time.monotonic(), deadline, "the first process never took the lock")
                    time.sleep(0.05)
                # The first holds the lock now, and is slow. The second, here, asks for the same release.
                with mock.patch.object(build, "SHARED_ROOT", root), mock.patch.object(build, "SHARED_DOWNLOADS", root / "download"), \
                        mock.patch.object(build, "SHARED_SOURCES", root / "source"), \
                        mock.patch.object(build.tarfile, "open", side_effect=AssertionError("the second process unpacked too")):
                    started = time.monotonic()
                    folder = build.unpacked_release(SCRATCH / "work-two-second", path, source)
                    waited = time.monotonic() - started
            finally:
                output = first.communicate(timeout=60)
            self.assertEqual(first.returncode, 0, output)
            self.assertGreater(waited, 0.5, "the second process did not wait for the lock")
            self.assertTrue((folder / "configure").is_file())
            self.assertTrue((folder.parent / ".unpacked").is_file(), "the first process wrote its marker")
            self.assertEqual(folder.parent.parent, root / "source")

    def test_an_unwritable_shared_download_folder_falls_back_to_the_work_folder(self):
        # A shared folder that cannot be made (here, under a file) is not a failure: this build keeps its own.
        SCRATCH.mkdir(parents=True, exist_ok=True)
        blocker = SCRATCH / "blocks-a-folder"
        blocker.write_text("a file", encoding="utf-8")
        work = SCRATCH / "work-unwritable"
        with mock.patch.object(build, "SHARED_DOWNLOADS", blocker / "download"), mock.patch.object(build, "SHARED_SOURCES", blocker / "source"):
            self.assertEqual(build.download_folder(work), work / "download")
            self.assertEqual(build.sources_folder(work), work / "source")

    def test_the_archive_already_in_the_download_folder_is_hashed_once(self):
        path, source, pins = self.release("shared-hashed-once.tar.xz")
        root, shared = self.shared("shared-hashed-once")
        work = SCRATCH / "work-hashed-once"
        with pins[0], pins[1], pins[2], shared[0], shared[1], shared[2]:
            build.release_tarball(work, given=path)
            with mock.patch.object(build, "digest_of", wraps=build.digest_of) as hashing:
                found, _ = build.release_tarball(work)
            self.assertEqual(found.parent, root / "download")
            self.assertEqual(hashing.call_count, 1, "the 12 MB archive is read once to be checked")

    def test_without_a_shared_folder_the_source_and_the_archive_are_kept_in_the_work_folder(self):
        path, source, pins = self.release("shared-none.tar.xz")
        work = SCRATCH / "work-shared-none"
        with pins[0], pins[1], pins[2], mock.patch.object(build, "SHARED_DOWNLOADS", None), \
                mock.patch.object(build, "SHARED_SOURCES", None):
            marker = build.unpacked_marker(work)
            if marker.exists():
                os.replace(marker, marker.with_name(marker.name + ".earlier"))
            kept, _ = build.release_tarball(work, given=path)
            folder = build.unpacked_release(work, kept, source)
        self.assertEqual(kept.parent, work / "download")
        self.assertEqual(folder.parent.parent, work / "source")

    def test_an_archive_an_earlier_build_kept_in_its_work_folder_is_taken_over(self):
        # A DerivedData from before the folder was shared holds the archive; it is copied into the
        # shared folder once, and not downloaded again.
        path, source, pins = self.release("shared-older.tar.xz")
        root, shared = self.shared("shared-older")
        work = SCRATCH / "work-shared-older"
        with pins[0], pins[1], pins[2], shared[0], shared[1], shared[2]:
            (work / "download").mkdir(parents=True, exist_ok=True)
            (work / "download" / source["file"]).write_bytes(path.read_bytes())
            # Anything else in the work folder's download folder that is not the release is passed over.
            (work / "download" / build.sources()[1]["file"]).write_bytes(b"stale")
            with mock.patch.object(build, "download", side_effect=AssertionError("downloaded")):
                found, found_source = build.release_tarball(work)
            self.assertEqual(found.parent, root / "download")
            self.assertEqual(found.read_bytes(), path.read_bytes())


class XcodeTests(unittest.TestCase):
    """What an Xcode build phase hands the script."""

    def test_the_platform_and_work_folder_come_from_xcode(self):
        platform, work = build.xcode_settings({"PLATFORM_NAME": "macosx", "ARCHS": "arm64", "OBJROOT": "/Users/reader/DD"})
        self.assertEqual((platform, work), ("macosx", Path("/Users/reader/DD/FFmpeg")))

    def test_another_architecture_or_platform_is_refused(self):
        for settings in ({"PLATFORM_NAME": "macosx", "ARCHS": "arm64 x86_64", "OBJROOT": "/x"},
                         {"PLATFORM_NAME": "watchos", "ARCHS": "arm64", "OBJROOT": "/x"},
                         {"PLATFORM_NAME": "macosx", "ARCHS": "arm64"}):
            with self.assertRaises(build.BuildError, msg=str(settings)):
                build.xcode_settings(settings)


if __name__ == "__main__":
    unittest.main(verbosity=1)
