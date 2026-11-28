"""runner_audio_probe.py: can audio be decoded on this GitHub runner, and what makes it work? Prints to the job's log.

A request sent by hand with "audio_probe": true makes run-on-runner.py call `probe` before its tests. 86 of the tests
runner-skips.conf leaves out read audio through AVAssetReader, whose copyNextSampleBuffer never returns on the runner
(run 42856695469). This builds a small Swift program that makes that call under a time limit
(probes/avassetreader-decode-probe.swift), makes a WAVE file and an AAC one, and runs the program on each: first as the
job is, then after each remedy in turn, so that the log says which remedy (if any) lets the decode return. Every command
has a time limit. Python 3 standard library only, and importing it leaves no __pycache__ folder.
"""
import math
import os
import struct
import subprocess
import sys
import time
import wave
from pathlib import Path

# Importing this module must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True

# The Swift program, beside the other probes.
PROBE_SOURCE = Path(__file__).resolve().parent / "probes" / "avassetreader-decode-probe.swift"
# How long the program waits for a decode, in seconds, and how long any other command may run.
DECODE_SECONDS = 20
COMMAND_SECONDS = 60


def say(text):
    """Prints a line of the report."""
    print("AUDIOPROBE " + text, flush=True)


def run(command, seconds=COMMAND_SECONDS):
    """Runs `command`; returns (exit status, or None when it timed out or could not start; its output). Never raises."""
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=seconds)
        return result.returncode, (result.stdout + result.stderr).strip()
    except subprocess.TimeoutExpired:
        return None, "(timed out)"
    except OSError as error:
        return None, f"(could not run: {error})"


def write_wave(path, seconds=3.0, rate=22050):
    """A mono 16-bit WAVE file of a 440 Hz tone, `seconds` long."""
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        frames = (struct.pack("<h", int(8000 * math.sin(2 * math.pi * 440 * n / rate))) for n in range(int(seconds * rate)))
        handle.writeframes(b"".join(frames))


def decode(binary, files, label):
    """Runs the decode program on each file and prints what each said, under `label`."""
    for name, path in files.items():
        status, output = run([str(binary), str(path), str(DECODE_SECONDS)], DECODE_SECONDS + 30)
        say(f"[{label}] {name}: {output or '(no output)'} (exit {status})")


def listing(label, command):
    """Prints a command's output, a line at a time, under `label`."""
    status, output = run(command)
    say(f"{label}: (exit {status})")
    for line in output.splitlines()[:40]:
        say("   " + line[:200])


def remedies(user_id):
    """The things tried in turn, as (name, argv): each might start an audio service a headless session lacks. One
    that fails is only reported."""
    return [
        ("kickstart the audio component registrar", ["launchctl", "kickstart", "-k", f"gui/{user_id}/com.apple.audio.AudioComponentRegistrar"]),
        ("bootstrap the audio agents", ["sh", "-c", f"for p in /System/Library/LaunchAgents/com.apple.audio*.plist; do launchctl bootstrap gui/{user_id} \"$p\"; done"]),
        ("kill coreaudiod", ["sudo", "killall", "-9", "coreaudiod"]),
    ]


def probe(scratch):
    """The whole probe: system facts, the program built, a baseline decode, then a decode after each remedy."""
    scratch = Path(scratch)
    scratch.mkdir(parents=True, exist_ok=True)
    user_id = os.getuid()
    listing("who", ["who"])
    listing("audio processes", ["sh", "-c", "ps -axo pid,user,comm | grep -i 'audio\\|coremedia' | grep -v grep"])
    listing("audio launch services", ["sh", "-c", f"launchctl list | grep -i audio; launchctl print gui/{user_id} 2>&1 | grep -i audio | head -20"])
    listing("session", ["sh", "-c", "stat -f '%Su' /dev/console; launchctl managername"])
    binary = scratch / "decode-probe"
    status, output = run(["swiftc", "-O", str(PROBE_SOURCE), "-o", str(binary)], 300)
    say(f"swiftc: exit {status} {output[:300]}")
    if status != 0:
        return
    files = {"wav": scratch / "tone.wav", "m4a": scratch / "tone.m4a"}
    write_wave(files["wav"])
    status, output = run(["afconvert", "-f", "m4af", "-d", "aac", str(files["wav"]), str(files["m4a"])])
    say(f"afconvert to m4a: exit {status} {output[:200]}")
    if status != 0:
        del files["m4a"]
    decode(binary, files, "as the job is")
    for name, command in remedies(user_id):
        status, output = run(command)
        say(f"remedy {name}: exit {status} {output[:200]}")
        time.sleep(5)
        decode(binary, files, f"after {name}")
