"""runner_ax_probe.py: does a GitHub runner let a process be an accessibility client, and does that make hosted controls exposed?

A request sent by hand with "ax_probe": true makes run-on-runner.py call `probe` before its tests. 50 of the hosted tests skip on
the runner with "This session exposes no accessibility elements for the AppKit controls in a hosted window". This builds
probes/accessibility-client-probe.swift, which hosts a slider and a stepper and counts the accessibility children of the hosting
view before and after it has asked the accessibility server about its own windows, and prints what the runner's accessibility
settings are. Everything is read-only, has a time limit, and is printed to the job's log (lines begin AXPROBE).
Python 3 standard library only, and importing it leaves no __pycache__ folder.
"""
import os
import sys
import time
from pathlib import Path

# Importing this module must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import runner_audio_probe as common  # noqa: E402

# The Swift program, beside the other probes.
PROBE_SOURCE = Path(__file__).resolve().parent / "probes" / "accessibility-client-probe.swift"
# How long the program may run, in seconds.
RUN_SECONDS = 60


def say(text):
    """Prints a line of the report."""
    print("AXPROBE " + text, flush=True)


def show(label, command):
    """Prints a command's output (at most 30 lines) under `label`."""
    status, output = common.run(command)
    say(f"{label}: (exit {status})")
    for line in output.splitlines()[:30]:
        say("   " + line[:200])


def probe(scratch):
    """The whole probe: the accessibility settings, the user's TCC grants (a read of the runner's own database), then the program."""
    scratch = Path(scratch)
    scratch.mkdir(parents=True, exist_ok=True)
    show("universalaccess", ["defaults", "read", "com.apple.universalaccess"])
    show("global keyboard and accessibility keys", ["sh", "-c", "defaults read NSGlobalDomain | grep -i 'AppleKeyboardUIMode\\|accessib\\|AXEnabled'"])
    tcc = Path.home() / "Library" / "Application Support" / "com.apple.TCC" / "TCC.db"
    show("accessibility grants in the runner's TCC database",
         ["sqlite3", str(tcc), "select service, client, auth_value from access where service like '%Accessibility%' or service like '%PostEvent%' or service like '%ListenEvent%'"])
    show("system TCC grants", ["sqlite3", "/Library/Application Support/com.apple.TCC/TCC.db",
                               "select service, client, auth_value from access where service like '%Accessibility%'"])
    binary = scratch / "ax-probe"
    status, output = common.run(["swiftc", "-O", str(PROBE_SOURCE), "-o", str(binary)], 300)
    say(f"swiftc: exit {status} {output[:300]}")
    if status != 0:
        return
    say(f"the program is {'there' if os.access(binary, os.X_OK) else 'NOT there or not executable'}: {binary}")
    show("the probe program", [str(binary)])
    show("the probe program through the session's own launchd domain", ["launchctl", "asuser", str(os.getuid()), str(binary)])
    # What the development Mac has that the runner lacks is probably VoiceOver (or another client that keeps accessibility on).
    show("start VoiceOver", ["open", "-g", "-a", "VoiceOver"])
    time.sleep(15)
    show("VoiceOver processes", ["sh", "-c", "ps -axo pid,comm | grep -i voiceover | grep -v grep"])
    show("the probe program with VoiceOver started", [str(binary)])
