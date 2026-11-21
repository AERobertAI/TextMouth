"""Tests of ``affected``, on git repositories the tests write."""

from __future__ import annotations

import json
from typing import Dict, List, Tuple

from doclib_case import DocLibCase

import cmd_affected

# The files of the base commit, on ``main``.
BASE_FILES: Dict[str, str] = {
    "TextMouth/Models/Cited.swift": "struct Cited { var a = 1 }\n",
    "TextMouth/Models/Old.swift": "struct Old { var a = 1 }\n",
    "TextMouth/Models/Gone.swift": "struct Gone { var a = 1 }\n",
    "TextMouth/Models/Quiet.swift": "struct Quiet { var a = 1 }\n",
    "TextMouth/Parsers/EPUBParser.swift": "struct EPUBParser { var a = 1 }\n",
    "TextMouth/Services/Service.swift": "struct Service {}\n",
    "project.yml": "name: TextMouth\n",
    "docs/architecture/models.md": """\
# Architecture

## Cited

<!-- id: cited; keys: x; src: TextMouth/Models/Cited.swift -->
The `Cited` type.

## Renamed

- Files: Models/Old.swift

## Deleted

The `TextMouth/Models/Gone.swift` file is described here.

## Parsers

Everything is in `Parsers/`.
Also `Parsers/EPUBParser.swift` is named, and so is `project.yml`.

## Twice

<!-- id: twice; keys: x; src: TextMouth/Models/Cited.swift, TextMouth/Services/Service.swift -->
Two files are cited.
""",
}


class AffectedCase(DocLibCase):
    """A repository with a ``main`` and, on a branch, one change of each kind."""

    def setUp(self) -> None:
        """Commit the base on ``main``, then the branch's changes on ``feature``."""
        super().setUp()
        self.git_repo(BASE_FILES)
        self.git("switch", "-q", "-c", "feature")
        # Modified, and cited.
        self.write_tree({"TextMouth/Models/Cited.swift": "struct Cited { var a = 2 }\n"})
        # Modified, and cited only through the folder and a bare path.
        self.write_tree({"TextMouth/Parsers/EPUBParser.swift": "struct EPUBParser { var a = 2 }\n"})
        # Added, and cited by nothing.
        self.write_tree({"TextMouth/Models/Fresh.swift": "struct Fresh {}\n"})
        # A page, which is skipped.
        self.write_tree({"docs/user/new.md": "# New\n\nWords.\n"})
        # A cited file renamed: the doc still names the old path.
        self.git("mv", "TextMouth/Models/Old.swift", "TextMouth/Models/Newer.swift")
        # A cited file deleted.
        self.git("rm", "-q", "TextMouth/Models/Gone.swift")
        # A Swift file changed that nothing cites, and a non-Swift file that is.
        self.write_tree({"TextMouth/Models/Quiet.swift": "struct Quiet { var a = 2 }\n", "project.yml": "name: Other\n"})
        self.commit_all("branch changes")

    def affected(self, *argv: str) -> Tuple[int, List[Dict], str]:
        """Run ``affected ARGV --json --max 0``; return the status, the JSON lines, and stderr."""
        status, out, err = self.run_cli("affected", *argv, "--json", "--max", "0")
        return status, [json.loads(line) for line in out.splitlines()], err


class ParseTests(DocLibCase):
    """parse_name_status(): git's -z output as changes."""

    def test_each_status_and_a_rename_with_its_score(self) -> None:
        data = b"M\0a.swift\0A\0b.swift\0D\0c.swift\0R087\0old.swift\0new.swift\0T\0d.swift\0"
        found = [(c.status, c.path, c.old) for c in cmd_affected.parse_name_status(data)]
        self.assertEqual(found, [("M", "a.swift", ""), ("A", "b.swift", ""), ("D", "c.swift", ""),
                                 ("R", "new.swift", "old.swift"), ("T", "d.swift", "")])

    def test_no_output_is_no_changes(self) -> None:
        self.assertEqual(cmd_affected.parse_name_status(b""), [])


class HitTests(AffectedCase):
    """The hits: which sections a changed file leads to."""

    def hit_pairs(self, hits: List[Dict]) -> List[Tuple[str, str, str]]:
        """``(changed, status, id or heading)`` of each hit, leaving out the uncited lines."""
        return [(hit["changed"], hit["status"], hit["id"] or hit["heading"]) for hit in hits if "changed" in hit]

    def test_every_kind_of_change_and_its_sections_in_path_order(self) -> None:
        status, hits, _ = self.affected()
        self.assertEqual(status, 0)
        self.assertEqual(self.hit_pairs(hits), [
            # The renamed file is found under its old name, and listed by the new path's order.
            ("TextMouth/Models/Cited.swift", "M", "cited"),
            ("TextMouth/Models/Cited.swift", "M", "twice"),
            ("TextMouth/Models/Gone.swift", "D", "Deleted"),
            ("TextMouth/Models/Old.swift", "R", "Renamed"),
            ("TextMouth/Parsers/EPUBParser.swift", "M", "Parsers"),
            ("project.yml", "M", "Parsers"),
        ])

    def test_the_text_names_the_status_the_file_and_the_citing_line(self) -> None:
        status, out, _ = self.run_cli("affected", "--max", "0")
        self.assertEqual(status, 0)
        lines = out.splitlines()
        self.assertTrue(
            lines[0].startswith("docs/architecture/models.md:5-5  Cited  M TextMouth/Models/Cited.swift: <!-- id: cited;"),
            lines[0])
        deleted = [line for line in lines if " D TextMouth/Models/Gone.swift: " in line]
        self.assertEqual(len(deleted), 1)
        self.assertTrue(deleted[0].startswith("docs/architecture/models.md:14-14  Deleted  "), deleted[0])

    def test_a_folder_citation_covers_the_changed_file_at_the_citing_line(self) -> None:
        _, hits, _ = self.affected()
        parsers = [hit for hit in hits if hit.get("changed") == "TextMouth/Parsers/EPUBParser.swift"]
        self.assertEqual(len(parsers), 1)
        # One hit for the section, at its first citation: the folder, on the first line.
        self.assertEqual((parsers[0]["kind"], parsers[0]["token"]), ("text", "Parsers/"))

    def test_a_bare_non_swift_path_is_found(self) -> None:
        _, hits, _ = self.affected()
        project = [hit for hit in hits if hit.get("changed") == "project.yml"]
        self.assertEqual([(hit["kind"], hit["token"]) for hit in project], [("text", "project.yml")])

    def test_a_section_is_listed_once_for_each_changed_file(self) -> None:
        _, hits, _ = self.affected()
        twice = [hit for hit in hits if hit.get("id") == "twice"]
        # The section cites Cited.swift (changed) and Service.swift (not changed).
        self.assertEqual([hit["changed"] for hit in twice], ["TextMouth/Models/Cited.swift"])

    def test_json_fields(self) -> None:
        _, hits, _ = self.affected()
        self.assertEqual(
            sorted(hits[0]),
            ["changed", "end", "heading", "id", "kind", "path", "section_end", "section_start", "start",
             "status", "text", "token"])

    def test_markdown_files_are_skipped(self) -> None:
        _, hits, err = self.affected()
        self.assertNotIn("docs/user/new.md", json.dumps(hits))
        self.assertIn("7 files changed", err)

    def test_the_cap_applies_to_the_hits_only(self) -> None:
        status, out, err = self.run_cli("affected", "--max", "2")
        self.assertEqual(status, 0)
        lines = out.splitlines()
        self.assertEqual(len([line for line in lines if not line.startswith("uncited: ")]), 2)
        self.assertIn("2 of 6 hits shown", err)
        # Every uncited Swift file is still listed.
        self.assertIn("uncited: TextMouth/Models/Fresh.swift", lines)
        self.assertIn("uncited: TextMouth/Models/Quiet.swift", lines)

    def test_no_hits_exits_1(self) -> None:
        self.git("switch", "-q", "main")
        self.git("switch", "-q", "-c", "lonely")
        self.write_tree({"TextMouth/Services/Brand.swift": "struct Brand {}\n"})
        self.commit_all("lonely")
        status, out, err = self.run_cli("affected")
        self.assertEqual(status, 1)
        self.assertEqual(out, "uncited: TextMouth/Services/Brand.swift\n")
        self.assertIn("1 files changed; 1 Swift, 0 of them cited (0%); 1 uncited", err)


class UncitedTests(AffectedCase):
    """The changed Swift files no section cites, and the summary."""

    def test_the_uncited_lines_follow_the_hits_in_path_order(self) -> None:
        status, out, _ = self.run_cli("affected", "--max", "0")
        lines = out.splitlines()
        self.assertEqual(lines[-2:], ["uncited: TextMouth/Models/Fresh.swift", "uncited: TextMouth/Models/Quiet.swift"])
        self.assertEqual(len([line for line in lines if line.startswith("uncited: ")]), 2)

    def test_json_uncited_lines(self) -> None:
        _, hits, _ = self.affected()
        self.assertEqual(hits[-2:], [{"uncited": "TextMouth/Models/Fresh.swift"},
                                     {"uncited": "TextMouth/Models/Quiet.swift"}])

    def test_the_summary_numbers(self) -> None:
        # Changed (Markdown left out): Cited, Gone (D), Fresh (A), Old->Newer (R), Quiet,
        # EPUBParser, project.yml = 7 changes. Swift and not deleted: Cited, Fresh, Newer,
        # Quiet, EPUBParser = 5; cited: Cited, Newer (through its old name), EPUBParser = 3.
        _, _, err = self.affected()
        self.assertEqual(err.strip(), "doclib: 7 files changed; 5 Swift, 3 of them cited (60%); 2 uncited")

    def test_a_renamed_cited_file_is_not_uncited(self) -> None:
        _, hits, _ = self.affected()
        uncited = [hit["uncited"] for hit in hits if "uncited" in hit]
        self.assertNotIn("TextMouth/Models/Newer.swift", uncited)
        self.assertNotIn("TextMouth/Models/Gone.swift", uncited)

    def test_the_percentage_rounds_to_a_whole_number(self) -> None:
        self.assertEqual(cmd_affected.summary_line([], {}), "doclib: 0 files changed; 0 Swift, 0 of them cited (-%); 0 uncited")
        changes = [cmd_affected.Change("M", f"{name}.swift") for name in "abc"]
        line = cmd_affected.summary_line(changes, {"a.swift": True, "b.swift": True, "c.swift": False})
        self.assertIn("(67%)", line)
        line = cmd_affected.summary_line(changes, {"a.swift": True, "b.swift": False, "c.swift": False})
        self.assertIn("(33%)", line)

    def test_with_no_swift_the_percentage_is_a_dash(self) -> None:
        self.git("switch", "-q", "main")
        self.git("switch", "-q", "-c", "yml")
        self.write_tree({"project.yml": "name: Y\n"})
        self.commit_all("yml")
        status, _, err = self.run_cli("affected")
        self.assertEqual(status, 0)
        self.assertIn("1 files changed; 0 Swift, 0 of them cited (-%); 0 uncited", err)


class RefTests(AffectedCase):
    """REF, --base, and the errors."""

    def test_a_merge_commit_measured_against_its_first_parent(self) -> None:
        self.git("switch", "-q", "main")
        # A change on main after the branch began, which the merge does not bring.
        self.write_tree({"TextMouth/Services/Service.swift": "struct Service { var a = 3 }\n"})
        self.commit_all("main moves on")
        self.git("merge", "-q", "--no-ff", "-m", "merge feature", "feature")
        merged = self.git("rev-parse", "HEAD").strip()
        status, hits, err = self.affected(merged, "--base", merged + "^1")
        self.assertEqual(status, 0)
        changed = sorted({hit["changed"] for hit in hits if "changed" in hit})
        self.assertIn("TextMouth/Models/Cited.swift", changed)
        self.assertIn("TextMouth/Models/Gone.swift", changed)
        # What main did meanwhile is not the merge's: the three dots measure from where the two met.
        self.assertNotIn("TextMouth/Services/Service.swift", changed)
        self.assertIn("7 files changed", err)

    def test_ref_names_a_branch_whatever_is_checked_out(self) -> None:
        self.git("switch", "-q", "main")
        status, hits, _ = self.affected("feature")
        self.assertEqual(status, 0)
        self.assertIn("TextMouth/Models/Cited.swift", [hit.get("changed") for hit in hits])

    def test_head_against_itself_changes_nothing(self) -> None:
        status, out, err = self.run_cli("affected", "HEAD", "--base", "HEAD")
        self.assertEqual((status, out), (1, ""))
        self.assertIn("0 files changed; 0 Swift, 0 of them cited (-%); 0 uncited", err)

    def test_an_unknown_ref_is_a_usage_error_with_gits_message(self) -> None:
        status, out, err = self.run_cli("affected", "no-such-branch")
        self.assertEqual((status, out), (2, ""))
        self.assertIn("doclib: fatal: ", err)
        self.assertIn("no-such-branch", err)

    def test_an_unknown_base_is_a_usage_error(self) -> None:
        status, _, err = self.run_cli("affected", "--base", "nowhere")
        self.assertEqual(status, 2)
        self.assertIn("nowhere", err)

    def test_a_ref_that_looks_like_an_option_is_refused(self) -> None:
        status, _, err = self.run_cli("affected", "--base=--output=x")
        self.assertEqual(status, 2)
        self.assertIn("is not a git ref", err)

    def test_a_folder_that_is_not_a_git_repository_is_a_usage_error(self) -> None:
        other = self.root / "plain"
        other.mkdir()
        status, _, err = self.run_cli("affected", root=other)
        self.assertEqual(status, 2)
        self.assertIn("is not a git repository", err)

    def test_the_docs_read_are_the_working_trees(self) -> None:
        # Edit the page without committing: the new citation is found for an old change.
        self.write_tree({"docs/architecture/models.md": BASE_FILES["docs/architecture/models.md"]
                         + "\n## Fresh\n\nSee `TextMouth/Models/Fresh.swift`.\n"})
        _, hits, _ = self.affected()
        fresh = [hit for hit in hits if hit.get("changed") == "TextMouth/Models/Fresh.swift"]
        self.assertEqual([hit["heading"] for hit in fresh], ["Fresh"])
        self.assertNotIn({"uncited": "TextMouth/Models/Fresh.swift"}, hits)
