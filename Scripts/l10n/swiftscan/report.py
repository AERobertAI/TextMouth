"""Totals of the scan: by area or by file, with the findings, as text or as JSON.

Every number is of *literals* (a text found in two places counts twice), with its bytes in
UTF-8; the header also gives the unique texts, which is what the research counted and what a
catalog will hold (one entry per text).
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field
from typing import Callable, Dict, Iterable, List, Optional, Set, Tuple

from . import areas
from .classify import CERTAIN, COUNTED, FINDING_HELP, PROBABLE, RAW
from .lexer import Literal

# The findings, in the order a report lists them.
FINDING_KINDS = ("glued", "plural", "static-let", "raw-title")
# Each finding's name as a column heading in the text report.
FINDING_HEADINGS = {"glued": "glued", "plural": "plural", "static-let": "static", "raw-title": "raw"}
STATUSES = ("unlocalized", "localized", "marked")


@dataclass
class Group:
    """The totals of one area or one file."""

    name: str
    files: Set[str] = field(default_factory=set)
    counts: Counter = field(default_factory=Counter)     # status -> literals
    bytes: Counter = field(default_factory=Counter)      # status -> UTF-8 bytes
    findings: Counter = field(default_factory=Counter)   # kind -> sites
    sites: Set[Tuple[str, str, int]] = field(default_factory=set)  # (kind, file, line) counted

    def add(self, lit: Literal) -> None:
        """Adds one literal that is interface text (localized, unlocalized, or marked)."""
        self.files.add(lit.file)
        self.counts[lit.status] += 1
        self.bytes[lit.status] += len(lit.text.encode("utf-8"))
        for kind in lit.findings:
            # One site per line (for a static let, per declaration): a sentence glued from
            # three literals on three lines is three sites, but a pair on one line is one.
            site = (kind, lit.file, lit.static_let if kind == "static-let" else lit.line)
            if site not in self.sites:
                self.sites.add(site)
                self.findings[kind] += 1

    def as_dict(self) -> dict:
        """The group as JSON-ready data."""
        return {
            "name": self.name,
            "files": len(self.files),
            **{status: {"count": self.counts[status], "bytes": self.bytes[status]} for status in STATUSES},
            "findings": {kind: self.findings[kind] for kind in FINDING_KINDS},
        }


def interface_literals(literals: Iterable[Literal]) -> List[Literal]:
    """The literals that are interface text: localized, unlocalized, or marked."""
    return [lit for lit in literals if lit.status]


def group_by(literals: Iterable[Literal], key: Callable[[Literal], str]) -> Dict[str, Group]:
    """Totals the interface literals by the key function (an area name or a file path)."""
    groups: Dict[str, Group] = {}
    for lit in interface_literals(literals):
        name = key(lit)
        groups.setdefault(name, Group(name)).add(lit)
    return groups


def by_area(lit: Literal) -> str:
    """The area of a literal's file."""
    return areas.area_of(lit.file)


def by_file(lit: Literal) -> str:
    """A literal's file."""
    return lit.file


def sorted_groups(groups: Dict[str, Group]) -> List[Group]:
    """The groups, the one with the most unlocalized bytes first, then by name."""
    return sorted(groups.values(), key=lambda g: (-g.bytes["unlocalized"], g.name))


def bucket_totals(literals: Iterable[Literal]) -> Dict[str, Tuple[int, int, int, int]]:
    """For each bucket: literals, bytes, unique texts, and the bytes of the unique texts."""
    by_bucket: Dict[str, List[Literal]] = {}
    for lit in literals:
        by_bucket.setdefault(lit.bucket, []).append(lit)
    out = {}
    for bucket, items in by_bucket.items():
        unique = {lit.text for lit in items}
        out[bucket] = (len(items), sum(len(lit.text.encode("utf-8")) for lit in items),
                       len(unique), sum(len(t.encode("utf-8")) for t in unique))
    return out


def certain_probable(literals: Iterable[Literal]) -> Dict[str, Tuple[int, int]]:
    """The unique texts and their bytes of the certain buckets, then of the probable ones."""
    items = list(literals)
    out = {}
    for name, buckets in (("certain", CERTAIN), ("probable", PROBABLE), ("raw", RAW)):
        unique = {lit.text for lit in items if lit.bucket in buckets}
        out[name] = (len(unique), sum(len(t.encode("utf-8")) for t in unique))
    return out


def total_findings(literals: Iterable[Literal]) -> Dict[str, int]:
    """The findings of the whole scan, with the static lets in wording types counted apart."""
    group = Group("all")
    wording_static: Set[Tuple[str, int]] = set()
    for lit in interface_literals(literals):
        group.add(lit)
        if "static-let" in lit.findings and lit.wording:
            wording_static.add((lit.file, lit.static_let))
    result = {kind: group.findings[kind] for kind in FINDING_KINDS}
    result["static-let-in-wording"] = len(wording_static)
    return result


def _num(n: int) -> str:
    """A number with thousands separators."""
    return f"{n:,}"


def format_table(groups: List[Group], heading: str, name_width: int, limit: int = 0) -> List[str]:
    """The groups as text lines: a heading row, one row each, and a total row."""
    shown = groups[:limit] if limit else groups
    columns = f"{'name':<{name_width}} {'files':>5} {'unloc':>6} {'bytes':>8} {'loc':>6} {'bytes':>8} {'marked':>6}" + \
        "".join(f" {FINDING_HEADINGS[kind]:>6}" for kind in FINDING_KINDS)
    lines = [heading, columns]

    def row(name: str, g: Group, files: int) -> str:
        return (f"{name:<{name_width}} {files:>5} {_num(g.counts['unlocalized']):>6} {_num(g.bytes['unlocalized']):>8}"
                f" {_num(g.counts['localized']):>6} {_num(g.bytes['localized']):>8} {_num(g.counts['marked']):>6}"
                + "".join(f" {_num(g.findings[kind]):>6}" for kind in FINDING_KINDS))

    for g in shown:
        lines.append(row(g.name.removeprefix("TextMouth/")[:name_width], g, len(g.files)))
    total = Group("total")
    for g in groups:
        total.files |= g.files
        total.counts.update(g.counts)
        total.bytes.update(g.bytes)
        total.findings.update(g.findings)
    lines.append(row("total" if not limit or len(groups) <= limit else f"total ({len(groups)} rows)", total, len(total.files)))
    return lines


def restrict_to_area(literals: List[Literal], files: List[str],
                     area: Optional[str]) -> Tuple[List[Literal], List[str]]:
    """The literals and the files of one area, or all of them when no area is named."""
    if area is None:
        return literals, files
    return [lit for lit in literals if areas.area_of(lit.file) == area], areas.files_in(area, files)


def other_files_line(files: List[str]) -> str:
    """How many files are in the last area, ``other``, which takes every file no earlier area covers."""
    return (f"{_num(len(areas.files_in(areas.OTHER, files)))} files are in {areas.OTHER} (shared helpers, and any file "
            "no earlier area covers): give a feature's files an area in Scripts/l10n/swiftscan/areas.py")


def text_report(literals: List[Literal], files: List[str], seconds: float, by: str = "area",
                area: Optional[str] = None, top: int = 0) -> str:
    """The whole text report: the header, the buckets, and the table by area or by file. With an
    area, the header and the table hold that area's own totals, not the whole app's."""
    all_files = files
    literals, files = restrict_to_area(literals, files, area)
    interface = interface_literals(literals)
    unloc = [lit for lit in interface if lit.status == "unlocalized"]
    loc = [lit for lit in interface if lit.status == "localized"]
    marked = [lit for lit in interface if lit.status == "marked"]
    size = lambda items: sum(len(lit.text.encode("utf-8")) for lit in items)  # noqa: E731
    cp = certain_probable(literals)
    lines = [
        f"Interface text of {f'the {area} area, ' if area else ''}{_num(len(files))} Swift files: "
        f"{_num(len(literals))} string literals, scanned in {seconds:.1f} s.",
        f"  certain (ui, wording, error): {_num(cp['certain'][0])} unique texts, {_num(cp['certain'][1])} bytes.",
        f"  probable (prose, word): {_num(cp['probable'][0])} unique texts, {_num(cp['probable'][1])} bytes.",
        f"  raw values shown as titles (rawtitle): {_num(cp['raw'][0])} unique texts, {_num(cp['raw'][1])} bytes.",
        f"  unlocalized: {_num(len(unloc))} literals, {_num(size(unloc))} bytes.",
        f"  localized: {_num(len(loc))} literals, {_num(size(loc))} bytes.",
        f"  marked `// l10n: no`: {_num(len(marked))} literals.",
        "  by bucket (literals, bytes; * counted as interface text):",
    ]
    totals = bucket_totals(literals)
    for bucket, (count, nbytes, ucount, ubytes) in sorted(totals.items(), key=lambda kv: -kv[1][1]):
        mark = "*" if bucket in COUNTED else " "
        lines.append(f"   {mark}{bucket:<8} {_num(count):>7} {_num(nbytes):>9}   unique {_num(ucount):>6} {_num(ubytes):>9}")
    findings = total_findings(literals)
    lines.append(f"  findings: {findings['glued']} glued sentences, {findings['plural']} hand-built plurals,")
    lines.append(f"    {findings['static-let']} static lets holding text ({findings['static-let-in-wording']} in wording types),")
    lines.append(f"    {findings['raw-title']} raw values shown as titles ({FINDING_HELP['raw-title']}).")
    lines.append("")
    if by == "file":
        groups = sorted_groups(group_by(literals, by_file))
        lines += format_table(groups, f"By file{f' of area {area}' if area else ''}, the most unlocalized bytes first:", 56, top)
    else:
        groups = sorted_groups(group_by(literals, by_area))
        lines += format_table(groups, "By area, the most unlocalized bytes first:", 16, top)
    lines.append(f"  {other_files_line(all_files)}")
    return "\n".join(lines)


def json_report(literals: List[Literal], files: List[str], seconds: float, by: str = "area",
                area: Optional[str] = None) -> dict:
    """The same report as JSON-ready data."""
    all_files = files
    literals, files = restrict_to_area(literals, files, area)
    groups = sorted_groups(group_by(literals, by_file if by == "file" else by_area))
    totals = bucket_totals(literals)
    return {
        "area": area,
        "files": len(files),
        "files_in_other": len(areas.files_in(areas.OTHER, all_files)),
        "literals": len(literals),
        "seconds": round(seconds, 2),
        "certain_probable": {k: {"unique_texts": v[0], "bytes": v[1]} for k, v in certain_probable(literals).items()},
        "buckets": {b: {"literals": v[0], "bytes": v[1], "unique_texts": v[2], "unique_bytes": v[3]}
                    for b, v in totals.items()},
        "findings": total_findings(literals),
        "by": by,
        "groups": [g.as_dict() for g in groups],
    }
