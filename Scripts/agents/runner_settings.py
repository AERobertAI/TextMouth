"""runner_settings.py: the system settings a GitHub runner is given before its tests, so that fewer tests skip there.

A runner is a virtual machine nobody sits at, and its defaults differ from the development Mac's in ways that make
tests skip: Keyboard navigation (System Settings > Keyboard) is off, so the tests that press Tab through the hosted
windows (`NSApp.isFullKeyboardAccessEnabled`) skip. The setting is a user default (`AppleKeyboardUIMode`, whose bit 2
is "all controls"), and writing it is what turning the setting on does, so the test that runs after it tests the
same thing as on the Mac.

These writes change the user's own preferences, so `apply` does nothing unless it is told it is on a GitHub Actions
runner (GITHUB_ACTIONS is exactly "true" in every step there, and nothing on the development Mac sets it).

Python 3 standard library only, and importing it leaves no __pycache__ folder.
"""
import subprocess
import sys

# Importing this module must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True

# The settings written, as (domain, key, type flag for `defaults write`, value, what it is).
SETTINGS = (
    ("NSGlobalDomain", "AppleKeyboardUIMode", "-int", "2", "Keyboard navigation on (all controls)"),
)
# How long one `defaults` call may take, in seconds.
CALL_SECONDS = 30


def on_github_runner(environment):
    """Whether `environment` is a step of a GitHub Actions run: GITHUB_ACTIONS is exactly "true" there."""
    return environment.get("GITHUB_ACTIONS") == "true"


def apply(environment, run=subprocess.run, say=print):
    """Writes SETTINGS, on a GitHub runner only; returns how many were written (0 anywhere else, and nothing is
    touched). A write that fails is reported through `say` and the others still go on: the tests then skip as before."""
    if not on_github_runner(environment):
        return 0
    written = 0
    for domain, key, flag, value, meaning in SETTINGS:
        try:
            result = run(["defaults", "write", domain, key, flag, value], capture_output=True, text=True, timeout=CALL_SECONDS)
            ok = result.returncode == 0
            detail = (result.stderr or "").strip()
        except (OSError, subprocess.SubprocessError) as error:
            ok, detail = False, str(error)
        say(f"runner setting: {meaning}: {'written' if ok else 'NOT written (' + detail + ')'}")
        written += 1 if ok else 0
    return written
