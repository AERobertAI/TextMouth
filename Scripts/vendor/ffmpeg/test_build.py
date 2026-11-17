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
import sys
import tarfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("ffmpeg_build", HERE / "build.py")
build = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(build)

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

    def test_the_wrapper_maps_the_work_folder_away(self):
        text = build.compiler_wrapper_text()
        self.assertIn('-ffile-prefix-map="$TMFF_BUILD_ROOT"=.', text)
        self.assertIn('-fdebug-prefix-map="$TMFF_BUILD_ROOT"=.', text)
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
        self.assertIn("unmodified", text)


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
        folder = build.unpacked_release(work, path, github)
        self.assertEqual(folder.name, f"ffmpeg-{build.FFMPEG_VERSION}")
        self.assertEqual((folder / "libavcodec" / "x.c").read_bytes(), b"int x;\n")
        self.assertTrue((folder / "configure").is_file())
        # A member of the other source's folder is outside this source's.
        wrong = ReleaseTests.tarball(self, "github-wrong.tar.gz", [(f"ffmpeg-{build.FFMPEG_VERSION}/configure", b"x")], compressed="gz")
        with self.assertRaises(build.BuildError):
            build.unpacked_release(SCRATCH / "work-github-wrong", wrong, github)


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
