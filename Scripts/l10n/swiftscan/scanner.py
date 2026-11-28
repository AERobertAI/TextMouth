"""Scans a tree of Swift files: lexes each, classifies every literal, and records the findings.

``scan_texts`` works on source texts held in a dict (what the tests use); ``scan_tree`` reads
the ``TextMouth/`` folder of a checkout. Both return the literals, each with its bucket, the
rule that chose it, its status (localized, unlocalized, marked, or none), and its findings.
"""

from __future__ import annotations

import re
import time
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Dict, Iterable, List, Mapping, Optional, Tuple

from . import classify
from .lexer import Literal, lex

# The folder, relative to the repository root, whose Swift files are scanned: the app's sources.
SOURCE_DIR = "TextMouth"

# A declaration of a function, up to its opening parenthesis.
_FUNC = re.compile(r"\bfunc\s+([A-Za-z_]\w*)\s*(?:<[^>(]*>)?\s*\(")
# A parameter typed as a localized string (a resource, a value, or a key): the part after its colon.
_RESOURCE_TYPE = re.compile(r"\s*(?:@\w+\s+)*(?:String\.)?(?:LocalizedStringResource|LocalizationValue|LocalizedStringKey)\b")
# A parameter's names: an external label and an internal name, or one name for both.
_PARAM_NAMES = re.compile(r"\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:([A-Za-z_]\w*)\s+)?([A-Za-z_]\w*)\s*:(.*)", re.S)

ResourceParams = Dict[str, List[Tuple[Optional[str], int]]]


@dataclass
class Scan:
    """The result of scanning a tree."""

    literals: List[Literal]
    files: List[str]         # every file scanned, relative to the root, in order
    seconds: float


def _split_top_level(text: str) -> List[str]:
    """Splits a parameter list at the commas that are not inside brackets or generics."""
    parts, depth, start = [], 0, 0
    for i, ch in enumerate(text):
        if ch in "([{<":
            depth += 1
        elif ch in ")]}" or (ch == ">" and text[i - 1:i] != "-"):
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append(text[start:i])
            start = i + 1
    parts.append(text[start:])
    return parts


def _parameter_list(text: str, open_paren: int) -> str:
    """The text between the parenthesis at open_paren and the one that closes it."""
    depth = 0
    for i in range(open_paren, min(len(text), open_paren + 3000)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren + 1:i]
    return ""


def collect_resource_params(texts: Iterable[str]) -> ResourceParams:
    """Finds the functions with a parameter typed LocalizedStringResource,
    String.LocalizationValue, or LocalizedStringKey, as {name: [(external label or None, position)]}.

    The compiler extracts a literal passed to such a parameter, so the scanner calls it
    localized. A function name shared by overloads is taken as one: that can only make the
    scanner trust a literal it should not, never fail a build.
    """
    found: ResourceParams = {}
    for text in texts:
        if "Localized" not in text and "LocalizationValue" not in text:
            continue
        for match in _FUNC.finditer(text):
            params = _parameter_list(text, match.end() - 1)
            if "Localiz" not in params:
                continue
            for index, param in enumerate(_split_top_level(params)):
                names = _PARAM_NAMES.match(param)
                if not names or not _RESOURCE_TYPE.match(names.group(3)):
                    continue
                label = names.group(1) or names.group(2)
                found.setdefault(match.group(1), []).append((None if label == "_" else label, index))
    return found


def scan_texts(texts: Mapping[str, str]) -> List[Literal]:
    """Scans source texts given as {path: text} and returns every literal, classified.

    Paths are relative to the repository root and use forward slashes.
    """
    localizer = classify.Localizer(collect_resource_params(texts.values()))
    literals: List[Literal] = []
    for path, text in texts.items():
        lines = text.split("\n")
        wording_file = classify.is_wording_name(PurePosixPath(path).name)
        for lit in lex(text, path):
            lit.wording = classify.in_wording_type(lit, wording_file)
            lit.bucket, lit.rule = classify.classify(lit, wording_file, localizer)
            lit.status = classify.status_of(lit)
            lit.findings = tuple(classify.findings_of(lit))
            lit.needs_comment = classify.needs_comment(lit, text, lines)
            lit.note_problem = classify.note_problem(lit, lines)
            literals.append(lit)
    # A line that holds two keys cannot carry a note for each.
    for lit in classify.shared_lines(literals):
        lit.note_problem = lit.note_problem or "shared-line"
    return literals


def swift_files(repo_root: Path, source_dir: str = SOURCE_DIR) -> List[Path]:
    """The Swift files of the source folder, sorted, as paths relative to the repository root."""
    base = repo_root / source_dir
    return sorted(p.relative_to(repo_root) for p in base.rglob("*.swift") if p.is_file())


def scan_tree(repo_root: Path, source_dir: str = SOURCE_DIR) -> Scan:
    """Scans every Swift file under the source folder of a checkout."""
    started = time.monotonic()
    files = swift_files(repo_root, source_dir)
    texts = {p.as_posix(): (repo_root / p).read_text(encoding="utf-8", errors="replace") for p in files}
    literals = scan_texts(texts)
    return Scan(literals, [p.as_posix() for p in files], time.monotonic() - started)
