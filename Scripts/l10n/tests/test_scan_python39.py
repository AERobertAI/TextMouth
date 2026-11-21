"""The scanner, the pack builder, and ids.py run under Xcode's Python 3.9, so their sources use nothing that
needs 3.10."""

from __future__ import annotations

import ast
import unittest

from scan_case import L10N


class PythonNineCompatibilityTests(unittest.TestCase):
    """Reads the sources instead of checking the running version, so that a run under a newer
    Python still catches a construct that 3.9 cannot take."""

    @staticmethod
    def sources() -> list:
        """The Python files Xcode's build phases run, the scanner (scan.py and the swiftscan package) and the pack
        builder (pack.py), and ids.py, which reads the sources through the scanner's lexer under the same Python."""
        return [L10N / "scan.py", L10N / "pack.py", L10N / "ids.py", *sorted((L10N / "swiftscan").glob("*.py"))]

    def test_no_dataclass_takes_slots_or_kw_only(self) -> None:
        # `@dataclass(slots=True)` was the one 3.10 construct in lexer.py (review of l10n/scan, finding 5).
        for path in self.sources():
            for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
                if isinstance(node, ast.keyword) and node.arg in ("slots", "kw_only"):
                    self.fail(f"{path.name} line {node.value.lineno}: {node.arg}= needs Python 3.10")

    def test_no_match_statement(self) -> None:
        for path in self.sources():
            for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
                self.assertNotEqual(type(node).__name__, "Match", f"{path.name}: match needs Python 3.10")


if __name__ == "__main__":
    unittest.main()
