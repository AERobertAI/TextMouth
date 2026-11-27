#!/usr/bin/env python3
"""install-on-device.py: builds the iPhone app, signed, and installs it on the user's own iPhone, with no Xcode window.

The command is `make install-ios`, which runs this under the heavy-work lock. The steps, each of which says what it
does and, when it cannot, the words that fix it:

  1. the team       --team, else TEXTMOUTH_TEAM, else the one team in Xcode's preferences (the user adds an Apple ID
                    once: Xcode > Settings > Accounts); with none or several it stops, exit status 2
  2. the device     --device, else the one paired iPhone or iPad `xcrun devicectl list devices` shows; with none or
                    several it stops, exit status 2
  3. the build      xcodebuild, scheme TextMouthiOS, Release, for that device, signed automatically for the team, with
                    the size settings of --profile; its output goes to build/ios-device/install.log
  4. the install    `xcrun devicectl device install app`, then (with --launch) `devicectl device process launch`

Usage (Python 3 standard library only):
    python3 -I -B Scripts/ios/install-on-device.py [--profile light|full|auto] [--team ID] [--device NAME|UDID]
                                                    [--launch] [--dry-run]

--dry-run prints each command and runs none: it reads no preferences and lists no device either, so a team or device
not given on the command line shows as a <placeholder>. The default profile is light: full link-time optimization's
link takes several GB of memory, and the iPhone's size is not what matters yet. Exit status: 0 on success; 2 for a
missing step, with the words to fix it; otherwise the status of the tool that failed, with the log's path.
"""
import argparse
import json
import os
import plistlib
import re
import shlex
import subprocess
import sys
import time
from xml.parsers.expat import ExpatError
from collections import namedtuple
from pathlib import Path

# Importing this module must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True

# The repository's root: this file is in Scripts/ios.
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Scripts"))
sys.path.insert(0, str(ROOT / "Scripts" / "ios"))
import iphone_release  # noqa: E402  (the target, product names, and build settings app-size.py shares)
import size_settings  # noqa: E402

# Where the build, its log, and the device list go, relative to the repository's root.
WORK_FOLDER = Path("build") / "ios-device"
# The environment variable that names the team when --team is not given.
TEAM_ENVIRONMENT = "TEXTMOUTH_TEAM"
# The exit status of a missing step (a team or a device), as opposed to a tool's own failure.
MISSING_STEP = 2
# How often a long build says it is still going, in seconds.
HEARTBEAT_SECONDS = 60
# The kinds of device an app may be installed on.
INSTALLABLE_DEVICE_TYPES = ("iPhone", "iPad")
# The hardwareProperties.reality of a real device (a simulator's is "simulated").
PHYSICAL_REALITY = "physical"

# A team Xcode knows: its identifier, its name, and whether it is a free personal team (whose profile lasts a week).
Team = namedtuple("Team", "team_id name free")
# A device devicectl lists: its CoreDevice identifier, its UDID (what xcodebuild's destination takes), and its name.
Device = namedtuple("Device", "identifier udid name")


class MissingStep(Exception):
    """A step the user must do first (add an Apple ID, connect the iPhone): its message is the words to say, and the
    script exits with MISSING_STEP."""


class UnknownDeviceList(Exception):
    """devicectl's JSON was not in a form this script knows, so the device cannot be chosen from it."""


# ---------------------------------------------------------------------------
# The team
# ---------------------------------------------------------------------------

ADD_APPLE_ID_STEPS = """Xcode has no team yet. Add your Apple ID to Xcode once:
  1. Open Xcode, then choose Xcode > Settings > Accounts.
  2. Choose the plus button, Apple ID, and sign in. A free Apple ID is enough.
  3. Run this command again.
Or give the team's 10-character identifier yourself with TEAM=<identifier> (make) or --team (the script)."""

# Said when Xcode's preferences hold an Apple ID but no team: the sign-in was begun and not finished.
FINISH_SIGN_IN_STEPS = """Xcode has your Apple ID, but its sign-in is not finished, so it has no team.
  1. Open Xcode, then choose Xcode > Settings > Accounts.
  2. Sign in to your Apple ID again there.
  3. Run this command again.
Or give the team's 10-character identifier yourself with TEAM=<identifier> (make) or --team (the script)."""
# The preferences key under which Xcode lists the Apple IDs it has been given.
APPLE_ID_LISTS_KEY = "DVTDeveloperAccountManagerAppleIDLists"


def read_xcode_preferences(run=subprocess.run):
    """Xcode's preferences as a dict, from `defaults export com.apple.dt.Xcode -` (an XML plist on standard output).
    Returns {} when the command fails or prints something that is not a plist, so that the caller says how to add an
    Apple ID rather than showing a traceback. `run` is subprocess.run, replaced by tests."""
    try:
        done = run(["defaults", "export", "com.apple.dt.Xcode", "-"], capture_output=True, check=False)
        found = plistlib.loads(done.stdout)
    except (OSError, ValueError, ExpatError):
        return {}
    return found if isinstance(found, dict) else {}


def teams_in_preferences(preferences):
    """`(teams, recognized)` from Xcode's preferences. Under IDEProvisioningTeamByIdentifier each account maps to a list
    of teams, each a dict with teamID, teamName, and isFreeProvisioningTeam. `teams` is a list of Team, without
    repeats (the same team can sit under two accounts). `recognized` is False only when that key holds something but
    nothing in it looks like a team: a form this script does not know, which it must not guess at."""
    by_account = preferences.get("IDEProvisioningTeamByIdentifier") if isinstance(preferences, dict) else None
    if not by_account:
        return [], True
    teams, seen = [], set()
    values = list(by_account.values()) if isinstance(by_account, dict) else [by_account]
    for value in values:
        for entry in (value if isinstance(value, list) else []):
            team_id = entry.get("teamID") if isinstance(entry, dict) else None
            if not isinstance(team_id, str) or not team_id or team_id in seen:
                continue
            seen.add(team_id)
            name = entry.get("teamName")
            teams.append(Team(team_id, name if isinstance(name, str) and name else team_id,
                              entry.get("isFreeProvisioningTeam") is True))
    # Accounts that hold no teams at all are just "none"; content that yields no team is a form not known.
    return teams, bool(teams) or not any(values)


def has_apple_id(preferences):
    """True when Xcode's preferences hold at least one account identifier under APPLE_ID_LISTS_KEY. The form of the value
    is not relied on: any non-empty text found anywhere inside it (in a list, or a dict's keys or values) counts. Only
    the fact is used; the identifier itself is never shown."""
    def holds_text(value):
        if isinstance(value, str):
            return bool(value.strip())
        if isinstance(value, dict):
            return any(holds_text(key) or holds_text(item) for key, item in value.items())
        if isinstance(value, (list, tuple)):
            return any(holds_text(item) for item in value)
        return False
    return isinstance(preferences, dict) and holds_text(preferences.get(APPLE_ID_LISTS_KEY))


def choose_team(flag, environ, read_preferences):
    """The Team to sign for. The flag wins, then the environment's TEXTMOUTH_TEAM (each gives only an identifier, so
    its name is not known), then the one team in Xcode's preferences, which `read_preferences()` gives. Raises
    MissingStep, with the steps to take, when there is none, several, or a form it does not recognize."""
    given = flag or environ.get(TEAM_ENVIRONMENT)
    if given:
        return Team(given, "", False)
    preferences = read_preferences()
    teams, recognized = teams_in_preferences(preferences)
    if len(teams) == 1:
        return teams[0]
    if len(teams) > 1:
        names = "\n".join(f"  {team.name}" for team in teams)
        raise MissingStep("Xcode knows more than one team:\n" + names +
                          "\nSay which one to sign for with TEAM=<identifier> (make) or --team (the script). "
                          "A team's identifier is the 10-character code Xcode shows under Signing & Capabilities.")
    if not recognized:
        raise MissingStep("Xcode's preferences name teams in a form this script does not know, so it cannot choose one.\n"
                          "Give the team's 10-character identifier with TEAM=<identifier> (make) or --team (the script). "
                          "Xcode shows it under Signing & Capabilities, in the TextMouthiOS target.")
    raise MissingStep(FINISH_SIGN_IN_STEPS if has_apple_id(preferences) else ADD_APPLE_ID_STEPS)


def describe_team(team):
    """The line that says which team signs the build: its name, never an Apple ID, and a note on a free team."""
    if not team.name:
        return "Team: the one you gave."
    return f"Team: {team.name}" + (" (a free personal team)" if team.free else ".")


# ---------------------------------------------------------------------------
# The device
# ---------------------------------------------------------------------------

CONNECT_STEPS = """No iPhone is ready. Do this once, then run the command again:
  1. Connect the iPhone to this Mac with a USB cable, and unlock it.
  2. If it asks "Trust This Computer?", tap Trust and enter the passcode.
  3. Turn on Developer Mode on the iPhone: Settings > Privacy & Security > Developer Mode. It appears after the
     iPhone has been connected to Xcode once; the iPhone restarts when you turn it on.
Once it is paired, it can be reached over the network too."""


def devices_in_listing(listing):
    """`(usable, others)` from devicectl's JSON (`list devices --json-output`): `usable` is a list of Device, the
    iPhones and iPads that are paired and not unavailable (devicectl calls a paired iPhone that is not plugged in, but
    is on the network, "available (paired)": its tunnel is disconnected and it still installs); `others` is a list of
    `(name, why not)` for the rest. Raises UnknownDeviceList when the JSON is not in the form this script knows."""
    try:
        listed = listing["result"]["devices"]
    except (KeyError, TypeError):
        raise UnknownDeviceList("no result.devices in devicectl's JSON") from None
    if not isinstance(listed, list):
        raise UnknownDeviceList("result.devices is not a list")
    usable, others = [], []
    for entry in listed:
        if not isinstance(entry, dict):
            raise UnknownDeviceList("a device entry is not an object")
        connection = entry.get("connectionProperties") or {}
        hardware = entry.get("hardwareProperties") or {}
        properties = entry.get("deviceProperties") or {}
        identifier = entry.get("identifier")
        if not isinstance(identifier, str) or not isinstance(connection, dict) \
                or not isinstance(hardware, dict) or not isinstance(properties, dict):
            raise UnknownDeviceList("a device entry lacks its identifier or properties")
        name = properties.get("name") if isinstance(properties.get("name"), str) else identifier
        if hardware.get("deviceType") not in INSTALLABLE_DEVICE_TYPES:
            continue  # a watch, a TV, or a Mac: not somewhere this app installs
        # Xcode 27 lists simulators too, with reality "simulated": never a phone to install on. An entry with no
        # reality (an older devicectl) is taken as physical.
        if hardware.get("reality", PHYSICAL_REALITY) != PHYSICAL_REALITY:
            continue
        if connection.get("pairingState") != "paired":
            others.append((name, "not paired: connect it by USB, unlock it, and tap Trust"))
        elif connection.get("tunnelState") == "unavailable":
            others.append((name, "not reachable: connect it by USB and unlock it"))
        else:
            udid = hardware.get("udid") if isinstance(hardware.get("udid"), str) else identifier
            usable.append(Device(identifier, udid, name))
    return usable, others


def comparable(text):
    """`text` as match_device compares it: with the curly apostrophe (U+2019, which iOS puts in a phone's name) made
    straight, and without regard to case."""
    return text.replace("\u2019", "'").casefold()


def match_device(selector, usable):
    """The devices of `usable` that `selector` names: by name, identifier, or UDID, in any case, and with a curly or a
    straight apostrophe alike."""
    wanted = comparable(selector)
    return [device for device in usable
            if wanted in (comparable(device.name), comparable(device.identifier), comparable(device.udid))]


def ready_names(devices):
    """The names of `devices`, one to a line, indented, for a message."""
    return "\n".join(f"  {device.name}" for device in devices)


def choose_device(selector, usable, others):
    """The Device to install on: the one in `usable` that `selector` names, or the only one when no selector is given.
    Raises MissingStep, with the steps to take, when there is none, several, or none that the selector names."""
    say_which = "\nSay which with DEVICE=<name> (make) or --device (the script); two with one name need the UDID."
    if selector:
        found = match_device(selector, usable)
        if len(found) == 1:
            return found[0]
        if len(found) > 1:
            raise MissingStep(f"{len(found)} ready devices answer to {selector!r}:\n{ready_names(found)}{say_which}")
        if usable:
            raise MissingStep(f"No ready iPhone is named {selector!r}. The ready ones are:\n{ready_names(usable)}{say_which}")
    elif len(usable) == 1:
        return usable[0]
    elif len(usable) > 1:
        raise MissingStep(f"More than one iPhone is ready:\n{ready_names(usable)}{say_which}")
    problems = "".join(f"\n  {name}: {why}" for name, why in others)
    raise MissingStep(CONNECT_STEPS + (("\nSeen but not ready:" + problems) if problems else ""))


# ---------------------------------------------------------------------------
# The commands
# ---------------------------------------------------------------------------

def xcodebuild_command(root, derived_data, team_id, udid, profile):
    """The argv of the signed device build: the scheme TextMouthiOS in Release for the device `udid` (a destination, so
    that the device can be registered), automatically signed for `team_id`, allowed to make or update profiles and to
    register the device, into `derived_data`, with the size settings of `profile` (Scripts/ios/iphone_release.py)."""
    return ["xcodebuild", "build", "-project", str(Path(root) / "TextMouth.xcodeproj"),
            "-scheme", iphone_release.TARGET, "-configuration", "Release",
            "-destination", f"id={udid}", "-derivedDataPath", str(derived_data),
            f"DEVELOPMENT_TEAM={team_id}", "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
            *iphone_release.release_settings(profile)]


def install_command(device_id, app):
    """The argv that installs the built app on the device."""
    return ["xcrun", "devicectl", "device", "install", "app", "--device", device_id, str(app)]


def launch_command(device_id, bundle_id):
    """The argv that starts the installed app."""
    return ["xcrun", "devicectl", "device", "process", "launch", "--device", device_id, bundle_id]


def list_command(json_path):
    """The argv that lists the devices, writing JSON to `json_path`."""
    return ["xcrun", "devicectl", "list", "devices", "--json-output", str(json_path)]


def shown(argv):
    """An argv as one shell-quoted line, for --dry-run and the log."""
    return shlex.join(str(word) for word in argv)


# ---------------------------------------------------------------------------
# What went wrong, and the words that fix it
# ---------------------------------------------------------------------------

# Patterns in a tool's output, each with the fix a person can do. Matched without regard to case; each fix is
# said at most once.
FAILURE_HINTS = (
    (r"developer mode.{0,40}(disabled|not enabled|is off|turned off)|(enable|turn on|disabled).{0,30}developer mode",
     "Developer Mode is off on your iPhone. Turn it on in Settings > Privacy & Security > Developer Mode, "
     "let the iPhone restart, then run this again."),
    (r"has not been explicitly trusted|untrusted developer|profile has not been trusted|invalid code signature, inadequate",
     "Your iPhone does not trust this developer yet. On the iPhone, open Settings > General > VPN & Device Management, "
     "choose the developer, tap Trust, then open the app."),
    (r"profile.{0,60}(has )?expired|(certificate|identity).{0,40}(expired|revoked)|expired.{0,30}profile",
     "The provisioning profile has expired (a free team's lasts a week). Run this command again: it makes a new one."),
    (r"cannot be registered to your development team|failed to register bundle identifier|"
     r"bundle identifier.{0,60}(not available|already|in use)|identifier.{0,40}already in use",
     "Another team already holds this app's bundle identifier, so your team cannot sign it. "
     "Use the team that holds it (TEAM=...), or sign out the other Apple ID in Xcode > Settings > Accounts."),
    (r"no account for team|no accounts? with|requires a development team|no team found|add an account",
     "Xcode has no Apple ID for this team. Add it in Xcode > Settings > Accounts, then run this again."),
    (r"device is locked|locked device|please unlock|unlock (the|your) (device|iphone)",
     "The iPhone is locked. Unlock it, keep it awake, and run this again."),
    (r"is not installed\. please download|platform.{0,40}not installed|iOS .{0,20}(not installed|must be installed)",
     "Xcode has not downloaded the iOS platform. Open Xcode > Settings > Components, download iOS, then run this again."),
    (r"unable to find a destination|ineligible destinations|newer version of xcode|may be too old|"
     r"xcode.{0,60}(doesn't|does not) support|(doesn't|does not) support.{0,40}ios",
     "Xcode could not use this iPhone as a destination. It may be newer than this Xcode supports (update Xcode), "
     "unlocked and trusted, or not yet prepared by Xcode (connect it by USB and wait for Xcode to finish setting it up)."),
)


def failure_hints(text):
    """The fixes, in order, for the problems `text` (a tool's output) shows, without repeats."""
    return [fix for pattern, fix in FAILURE_HINTS if re.search(pattern, text, re.IGNORECASE)]


def say_failure(label, status, log_path, text, out=None):
    """Prints (to standard error, unless `out` says otherwise) that `label` failed with `status`, the fixes its output
    suggests, and where the full log is."""
    out = sys.stderr if out is None else out  # looked up now, not when the function was defined
    print(f"{label} failed (exit status {status}).", file=out)
    for fix in failure_hints(text):
        print(f"  {fix}", file=out)
    print(f"The full log is {log_path}", file=out)


# ---------------------------------------------------------------------------
# Running the tools
# ---------------------------------------------------------------------------

# The lines of xcodebuild's output worth showing as they come: an error, and the verdict.
SHOWN_LINE = re.compile(r"\berror:|^\*\* BUILD (SUCCEEDED|FAILED) \*\*")


def run_build(argv, log_path, cwd, out=sys.stdout, clock=time.monotonic):
    """Runs the build, writes all its output to `log_path`, prints its error lines (each once) and its verdict, and a
    line saying it is still going every HEARTBEAT_SECONDS. Returns the exit status."""
    started = last_said = clock()
    seen = set()
    with open(log_path, "w", encoding="utf-8") as log, \
            subprocess.Popen(argv, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, errors="replace") as process:
        for line in process.stdout:
            log.write(line)
            text = line.rstrip("\n")
            if SHOWN_LINE.search(text) and text not in seen:
                seen.add(text)
                print(text, file=out, flush=True)
            if clock() - last_said >= HEARTBEAT_SECONDS:
                last_said = clock()
                print(f"Still building: {int((last_said - started) // 60)} minutes in.", file=out, flush=True)
        return process.wait()


def run_logged(argv, log_path, cwd):
    """Runs a short tool, writes its output to `log_path`, and returns `(status, its output)`."""
    done = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, errors="replace", check=False)
    text = done.stdout + done.stderr
    Path(log_path).write_text(text, encoding="utf-8")
    return done.returncode, text


def list_devices(work, cwd):
    """The `(usable, others)` devices from `xcrun devicectl list devices`, its JSON written into `work`. When the tool
    fails or its JSON is not in a form this script knows, prints the tool's own table and raises MissingStep asking for
    DEVICE=, since a person can still read the table."""
    json_path = Path(work) / "devices.json"
    status, text = run_logged(list_command(json_path), Path(work) / "devices.log", cwd)
    try:
        if status != 0:
            raise UnknownDeviceList(f"devicectl exited with status {status}")
        return devices_in_listing(json.loads(json_path.read_text(encoding="utf-8")))
    except (UnknownDeviceList, OSError, ValueError) as reason:
        table = subprocess.run(["xcrun", "devicectl", "list", "devices"], capture_output=True, text=True,
                               errors="replace", check=False)
        raise MissingStep(f"Could not read the list of devices ({reason}). The tool's own table is:\n"
                          f"{(table.stdout + table.stderr).rstrip()}\n"
                          "Give the iPhone's name or UDID with DEVICE=<name> (make) or --device (the script).") from None


# ---------------------------------------------------------------------------
# The command line
# ---------------------------------------------------------------------------

def build_parser():
    """The command line's parser."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--profile", default=size_settings.LIGHT, choices=size_settings.PROFILES,
                        help="the size settings: light (the default: its link needs little memory), full, or auto")
    parser.add_argument("--team", help=f"the team's 10-character identifier (else {TEAM_ENVIRONMENT}, else Xcode's one team)")
    parser.add_argument("--device", help="the iPhone's name, UDID, or identifier (else the one ready iPhone)")
    parser.add_argument("--launch", action="store_true", help="start the app on the iPhone after installing it")
    parser.add_argument("--dry-run", action="store_true",
                        help="print each command and run none (reads no preferences, lists no device)")
    return parser


def dry_run(args, root, derived_data, environ):
    """Prints the commands a real run would make, with a <placeholder> for a team or device not given, and runs none."""
    team = args.team or environ.get(TEAM_ENVIRONMENT) or "<team identifier from Xcode's preferences>"
    udid = args.device or "<UDID of the one ready iPhone>"
    device_id = args.device or "<identifier of the one ready iPhone>"
    print(f"Dry run: nothing is run. Profile: {size_settings.resolved(args.profile)}.")
    print("List the devices:  " + shown(list_command(Path(root) / WORK_FOLDER / "devices.json")))
    print("Build:             " + shown(xcodebuild_command(root, derived_data, team, udid, args.profile)))
    print("Install:           " + shown(install_command(device_id, iphone_release.app_path(derived_data))))
    if args.launch:
        print("Launch:            " + shown(launch_command(device_id, "<bundle-identifier>")))
    return 0


def bundle_identifier(app):
    """The built app's CFBundleIdentifier, read from its Info.plist, so that no copy of it is kept here."""
    with open(Path(app) / "Info.plist", "rb") as handle:
        return plistlib.load(handle)["CFBundleIdentifier"]


def install(args, root, environ):
    """The real run: team, device, build, install, and launch. Returns the exit status."""
    work = Path(root) / WORK_FOLDER
    work.mkdir(parents=True, exist_ok=True)
    derived_data = work.resolve()
    team = choose_team(args.team, environ, read_xcode_preferences)
    print(describe_team(team))
    usable, others = list_devices(work, root)
    device = choose_device(args.device, usable, others)
    print(f"Device: {device.name}.")
    log_path = work / "install.log"
    print(f"Building the iPhone app ({size_settings.resolved(args.profile)} profile). The full log is {log_path}")
    status = run_build(xcodebuild_command(root, derived_data, team.team_id, device.udid, args.profile), log_path, root)
    if status != 0:
        say_failure("The build", status, log_path, log_path.read_text(encoding="utf-8", errors="replace"))
        return status
    app = iphone_release.app_path(derived_data)
    device_log = work / "devicectl.log"
    status, text = run_logged(install_command(device.identifier, app), device_log, root)
    if status != 0:
        say_failure("Installing on the iPhone", status, device_log, text)
        return status
    print("Installed. Open TextMouth on your iPhone.")
    if team.free:
        print("A free team's app stops opening after a week: run this command again then.")
    if args.launch:
        status, text = run_logged(launch_command(device.identifier, bundle_identifier(app)), device_log, root)
        if status != 0:
            say_failure("Launching the app", status, device_log, text)
            return status
        print("Launched.")
    return 0


def main(argv=None, root=ROOT, environ=None):
    """The command line. Returns the exit status: 0, MISSING_STEP (2) for a step the user must do first, or a failed
    tool's own status."""
    environ = os.environ if environ is None else environ
    args = build_parser().parse_args(argv)
    try:
        if args.dry_run:
            return dry_run(args, root, Path(root) / WORK_FOLDER, environ)
        return install(args, root, environ)
    except MissingStep as step:
        print(str(step), file=sys.stderr)
        return MISSING_STEP


if __name__ == "__main__":
    sys.exit(main())
