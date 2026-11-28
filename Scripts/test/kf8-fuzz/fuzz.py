#!/usr/bin/env python3
"""fuzz.py: damages Kindle books at random, with a seed, and reads each through a reader program in a child process.

This is a script, not part of the test suite: thousands of rounds take minutes, and a trap in a child is a crash
report on the Mac. Run it on a quiet Mac, after `build-reader.py` has built the reader.

    python3 -I Scripts/test/kf8-fuzz/fuzz.py --reader PATH/TO/reader --work FOLDER --seed 1 --rounds 5000 BOOK...

Each round copies one BOOK (a .azw3, or a .mobi hybrid) to FOLDER/round.bin (the same file, overwritten every
round: this script deletes nothing), changes between one and four bytes (half the rounds in the first 6 KB of
the file or in the last 40 KB, where the headers and the tables are, half anywhere), and runs the reader on it
with a time limit. The reader reads the book as an import does, through the whole of the shared converter, and
prints OK or ERR and exits 0 or 1 for a book it read or refused. Anything else is a failure:
  - a signal (a trap, or a stack overflow): the round's file is kept as FOLDER/trap-<round>.bin, named in the report;
  - a time over the limit, or a peak memory over the limit.
The report ends with the counts, and the exit status is 0 only if no round failed.

First runs (November 9, 2026, the reader built by build-reader.py from the sources of that day, each round in a
reader process of its own; a book of these reads in a few tens of milliseconds), no round failing in any:
  - seed 1, 2,000 rounds, se-the-time-machine.azw3:        read 1736, refused 264 (and 1736 / 264 for main's reader)
  - seed 1, 2,000 rounds, mobi/quay-almanac-hybrid.mobi:    read 1863, refused 137
  - seed 1, 2,000 rounds, mobi/pg1952-yellow-wallpaper-kf8.mobi: read 1830, refused 170
  - seed 2, 2,000 rounds over those three books and mobi/pg1080-modest-proposal-kf8.mobi: read 1820, refused 180
"""
import argparse
import random
import resource
import shutil
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--reader", required=True, help="the reader program built by build-reader.py")
    parser.add_argument("--work", required=True, help="a folder for the damaged copy and for the files of rounds that failed")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--rounds", type=int, default=2000)
    parser.add_argument("--seconds", type=float, default=5.0, help="the time one round may take")
    parser.add_argument("--megabytes", type=int, default=1024, help="the peak memory one round may use")
    parser.add_argument("books", nargs="+")
    args = parser.parse_args()

    generator = random.Random(args.seed)
    sources = [open(path, "rb").read() for path in args.books]
    copy = args.work.rstrip("/") + "/round.bin"
    counts = {"read": 0, "refused": 0, "trap": 0, "slow": 0, "big": 0, "other": 0}
    failures = []
    for number in range(args.rounds):
        index = generator.randrange(len(sources))
        data = bytearray(sources[index])
        for _ in range(generator.randint(1, 4)):
            if number % 2 == 0:
                place = generator.randrange(len(data))
            elif generator.random() < 0.5:
                place = generator.randrange(min(len(data), 6_000))
            else:
                place = len(data) - 1 - generator.randrange(min(len(data), 40_000))
            data[place] = generator.randrange(256)
        with open(copy, "wb") as handle:
            handle.write(data)
        before = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
        started = time.time()
        try:
            done = subprocess.run([args.reader, "kf8", copy], capture_output=True, text=True, timeout=args.seconds)
            seconds = time.time() - started
        except subprocess.TimeoutExpired:
            counts["slow"] += 1
            failures.append((number, args.books[index], "slower than %s s" % args.seconds))
            continue
        peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
        if done.returncode < 0:
            counts["trap"] += 1
            kept = "%s/trap-%d.bin" % (args.work.rstrip("/"), number)
            shutil.copyfile(copy, kept)
            failures.append((number, args.books[index], "signal %d, file kept as %s" % (-done.returncode, kept)))
        elif done.returncode == 0:
            counts["read"] += 1
        elif done.returncode == 1:
            counts["refused"] += 1
        else:
            counts["other"] += 1
            failures.append((number, args.books[index], "exit status %d" % done.returncode))
        # ru_maxrss is the largest of all the children so far, in bytes on macOS: a new high above the limit is a failure.
        if peak > before and peak > args.megabytes * 1024 * 1024:
            counts["big"] += 1
            failures.append((number, args.books[index], "peak memory %d MB" % (peak // (1024 * 1024))))
    for number, book, why in failures:
        print("round %d (%s): %s" % (number, book, why))
    print("rounds %d, seed %d:" % (args.rounds, args.seed), ", ".join("%s %d" % item for item in counts.items()))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
