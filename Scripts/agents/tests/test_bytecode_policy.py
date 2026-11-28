"""Policy test: a script that imports a sibling module sets sys.dont_write_bytecode = True before it does.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

Python writes a module's __pycache__ file when it imports the module, before the module's own code runs, so a module's
own `sys.dont_write_bytecode = True` cannot keep its .pyc out of the repository: the IMPORTER must set it first. The
scripts run with `python3 -I`, which leaves their own folder out of sys.path, so each puts the folder in by hand
(`sys.path.insert(0, ...)`) and imports its siblings after that. A script that does so without setting the flag first
left Scripts/agents/__pycache__/repo_paths.cpython-311.pyc in the checkout (heavy_lock.py, agent-cost.py,
usage-watch-unscoped.py, wait-for-usage-reset.py and Scripts/test/testkit.py did, on November 16, 2026).
"""
import re
import unittest
from pathlib import Path

# The Scripts folder: this file is Scripts/agents/tests/test_bytecode_policy.py.
SCRIPTS = Path(__file__).resolve().parents[2]
# A top-level line that puts a folder on the import path, and the line that sets the flag.
PATH_LINE = re.compile(r"^sys\.path\.(insert|append)\(")
FLAG_LINE = re.compile(r"^sys\.dont_write_bytecode\s*=\s*True\b")


def scripts_that_extend_the_path(root):
    """Every .py file under `root` outside a folder named "tests" (those run with -B) that has a top-level line putting
    a folder on sys.path, as (the file, its first such line number, the line number of the flag or None), 1-based."""
    found = []
    for path in sorted(root.rglob("*.py")):
        if "tests" in path.relative_to(root).parts[:-1]:
            continue
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        insert = next((n for n, line in enumerate(lines, 1) if PATH_LINE.match(line)), None)
        if insert is None:
            continue
        flag = next((n for n, line in enumerate(lines, 1) if FLAG_LINE.match(line)), None)
        found.append((path, insert, flag))
    return found


class BytecodePolicyTests(unittest.TestCase):
    """Every script that extends sys.path sets the flag first."""

    def test_every_script_that_imports_a_sibling_sets_the_flag_before_it_extends_the_path(self):
        late = [f"{path.relative_to(SCRIPTS)}: sys.path line {insert}, flag "
                f"{'missing' if flag is None else f'on line {flag}'}"
                for path, insert, flag in scripts_that_extend_the_path(SCRIPTS) if flag is None or flag > insert]
        self.assertEqual(late, [], "set sys.dont_write_bytecode = True before the sys.path line, as repo_paths.py's "
                                   "docstring shows")

    def test_the_policy_finds_the_scripts_it_is_about(self):
        """The scan is not vacuous: it sees the scripts that extend the path, among them the ones fixed on November 16."""
        names = {path.name for path, _, _ in scripts_that_extend_the_path(SCRIPTS)}
        self.assertTrue({"heavy_lock.py", "agent-cost.py", "usage-watch-unscoped.py", "wait-for-usage-reset.py",
                         "testkit.py", "run-ios-build.py", "run-on-runner.py"} <= names, sorted(names))

    def test_a_script_that_sets_the_flag_late_or_never_is_caught(self):
        """The scan sees the four failures of the day: no flag, and a flag after the path line."""
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "never.py").write_text("import sys\nsys.path.insert(0, 'x')\nimport repo_paths\n")
            (root / "late.py").write_text("import sys\nsys.path.insert(0, 'x')\nsys.dont_write_bytecode = True\n")
            (root / "good.py").write_text("import sys\nsys.dont_write_bytecode = True\nsys.path.insert(0, 'x')\n")
            (root / "none.py").write_text("import sys\nprint(1)\n")
            found = {path.name: (insert, flag) for path, insert, flag in scripts_that_extend_the_path(root)}
        self.assertEqual(found, {"never.py": (2, None), "late.py": (2, 3), "good.py": (3, 2)})


if __name__ == "__main__":
    unittest.main()
