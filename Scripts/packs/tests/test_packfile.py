"""Tests of `packfile.py`, the container both of TextMouth's packs are written in (FR40).

Run with: python3 -I -B -m unittest discover -s Scripts/packs/tests

`Scripts/l10n/tests/test_pack.py` proves that `Strings.pack` still comes out as the container wrote it before it was
shared; these tests are of the container itself, with a magic of its own.
"""
import struct
import sys
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import packfile  # noqa: E402  (imported by path, after sys.path is set)

MAGIC = b"TEST"
VERSION = 7
DIGEST = bytes(range(32))


def two_blobs(methods=None):
    """A pack of two blobs, `first` and `second`, with the methods given (or the smaller of each)."""
    blobs = [("first", b"one\0two\0" * 50, 100), ("second", b"x\0", 1)]
    return packfile.assemble(MAGIC, VERSION, DIGEST, 101, blobs, methods=methods)


class ContainerTests(unittest.TestCase):
    """What assemble writes and read_directory and decode_raw read."""

    def test_a_pack_reads_back_what_was_written(self):
        data = two_blobs({"first": packfile.METHOD_LZMA, "second": packfile.METHOD_BZIP2})
        directory = packfile.read_directory(data, MAGIC, VERSION)
        self.assertEqual(DIGEST, directory.digest)
        self.assertEqual(101, directory.count)
        self.assertEqual(["first", "second"], [r.name for r in directory.records])
        self.assertEqual([packfile.METHOD_LZMA, packfile.METHOD_BZIP2], [r.method for r in directory.records])
        for record, raw in zip(directory.records, (b"one\0two\0" * 50, b"x\0")):
            compressed = data[record.offset:record.offset + record.compressed]
            self.assertEqual(raw, packfile.decode_raw(record.name, compressed, record.raw, record.method))

    def test_the_header_is_48_bytes_and_each_record_32(self):
        self.assertEqual(48, packfile.HEADER.size)
        self.assertEqual(32, packfile.DIRECTORY_RECORD.size)
        data = two_blobs()
        self.assertEqual(MAGIC, data[:4])
        self.assertEqual(VERSION, struct.unpack_from("<H", data, 4)[0])
        # The first blob starts straight after the two records.
        self.assertEqual(48 + 2 * 32, struct.unpack_from("<I", data, 48 + 12)[0])

    def test_a_wrong_magic_version_or_flag_is_refused(self):
        data = bytearray(two_blobs())
        for label, change in (("magic", lambda d: d.__setitem__(slice(0, 4), b"NOPE")),
                              ("version", lambda d: struct.pack_into("<H", d, 4, VERSION + 1)),
                              ("flags", lambda d: struct.pack_into("<H", d, 6, 1))):
            with self.subTest(label):
                damaged = bytearray(data)
                change(damaged)
                with self.assertRaises(packfile.PackError):
                    packfile.read_directory(bytes(damaged), MAGIC, VERSION)

    def test_a_cut_file_is_refused(self):
        data = two_blobs()
        for length in (10, 47, 48 + 32, len(data) - 1):
            with self.subTest(length), self.assertRaises(packfile.PackError):
                packfile.read_directory(data[:length], MAGIC, VERSION)

    def test_each_method_decodes_and_an_unknown_one_is_refused(self):
        raw = b"A line of text. " * 40
        for method in (packfile.METHOD_LZMA, packfile.METHOD_BZIP2):
            with self.subTest(method):
                compressed = packfile.compress_with(method, raw)
                self.assertEqual(raw, packfile.decode_raw("x", compressed, len(raw), method))
        with self.assertRaisesRegex(packfile.PackError, "method 9"):
            packfile.decode_raw("x", packfile.compress(raw), len(raw), 9)
        with self.assertRaises(packfile.PackError):
            packfile.compress_with(9, raw)

    def test_a_wrong_raw_size_or_a_damaged_stream_is_refused(self):
        raw = b"A line of text. " * 40
        for method in (packfile.METHOD_LZMA, packfile.METHOD_BZIP2):
            compressed = packfile.compress_with(method, raw)
            for label, size, data in (("too large", len(raw) + 1, compressed), ("too small", len(raw) - 1, compressed),
                                      ("cut", len(raw), compressed[:len(compressed) // 2]),
                                      ("garbage", len(raw), b"not a stream at all")):
                with self.subTest((method, label)), self.assertRaises(packfile.PackError):
                    packfile.decode_raw("x", data, size, method)

    def test_the_smaller_method_wins_and_a_tie_chooses_lzma(self):
        raw = ("A line of text, then another. " * 400).encode()
        method, data = packfile.compress_smallest(raw)
        other = {packfile.METHOD_LZMA: packfile.compress_bzip2, packfile.METHOD_BZIP2: packfile.compress}[method](raw)
        self.assertLessEqual(len(data), len(other))
        # A tie: both compressors replaced by ones that return equal-sized bytes.
        with mock.patch.object(packfile, "compress", return_value=b"aaaa"), \
                mock.patch.object(packfile, "compress_bzip2", return_value=b"bbbb"):
            self.assertEqual((packfile.METHOD_LZMA, b"aaaa"), packfile.compress_smallest(b"x"))

    def test_the_window_is_the_smallest_power_of_two_that_holds_the_blob(self):
        self.assertEqual(4096, packfile.window_size(0))
        self.assertEqual(4096, packfile.window_size(4096))
        self.assertEqual(8192, packfile.window_size(4097))
        self.assertEqual(1 << 20, packfile.window_size((1 << 20) - 5))

    def test_the_same_input_gives_the_same_bytes(self):
        self.assertEqual(two_blobs(), two_blobs())


if __name__ == "__main__":
    unittest.main()
