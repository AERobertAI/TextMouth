"""Tests of ``stale``: cited paths that name nothing and backticked names the sources do not declare."""

from __future__ import annotations

import json

from doclib_case import DocLibCase

import cmd_stale
import docmodel
from cmd_stale import Allowlist, StaleItem, load_allowlist, parse_allowlist, stale_items
from repofiles import RepoFiles
from swiftindex import SwiftIndex

SWIFT = """\
struct Book {
    struct Storage {}
    init() {}
}
func startLibrary() {}
final class PlatformHelper {}
"""

# A page built one backticked name or path at a time, so each test names what it checks.
ALLOWLIST = """\
# What may go here.

.claude/worktrees/
NS*
SwiftSoup
UIAccessibilityConstants.h
   # an indented comment and a blank line follow

Sendable   # a trailing comment
"""


class StaleTestCase(DocLibCase):
    """A repository with a few Swift types and a ``write_page`` helper."""

    def setUp(self) -> None:
        super().setUp()
        self.write_tree({
            "TextMouth/Models/Book.swift": SWIFT,
            "TextMouth/Platform/PlatformTypes.swift": "enum Other {}\n",
            "Scripts/run.sh": "echo\n",
            "Info.plist": "x\n",
            ".claude/skills/doc-library/stale-allowlist.txt": ALLOWLIST,
        })

    def write_page(self, body: str, marker: str = "", heading: str = "Page") -> None:
        """Write ``docs/p.md`` with one section holding ``marker`` (a marker line) and ``body``."""
        self.write_tree({"docs/p.md": f"# {heading}\n\n{marker}\n{body}\n" if marker else f"# {heading}\n\n{body}\n"})

    def stale(self, *args: str):
        """Run ``stale``; return (status, hit lines, standard error)."""
        status, out, err = self.run_cli("stale", *args)
        return status, out.splitlines(), err

    def details(self, *args: str):
        """The (text) of each hit of ``stale``, to compare short lists."""
        _status, out, _err = self.run_cli("stale", "--json", "--max", "0", *args)
        return [json.loads(line)["text"] for line in out.splitlines()]


class PathTests(StaleTestCase):
    """Citations that resolve to nothing, and the exceptions."""

    def test_a_missing_path_is_reported_whatever_its_kind(self) -> None:
        self.write_page("Files: Models/Gone.swift.\n\nAlso `Models/Nope.swift`.",
                        "<!-- id: s; src: TextMouth/Models/Missing.swift -->")
        self.assertEqual(self.details(), [
            "missing path: TextMouth/Models/Missing.swift",
            "missing path: Models/Gone.swift",
            "missing path: Models/Nope.swift",
        ])

    def test_an_existing_path_is_not_reported(self) -> None:
        self.write_page("Files: Models/Book.swift, Platform/.\n`Models/Book.swift`",
                        "<!-- id: s; src: TextMouth/Models/Book.swift -->")
        self.assertEqual(self.details(), [])

    def test_a_token_without_a_dot_in_its_last_part_may_be_a_branch_and_is_not_reported(self) -> None:
        self.write_page("Files: docs/oct19, Models/Folder.\n`Scripts/branch`")
        self.assertEqual(self.details(), [])

    def test_a_src_entry_without_a_dot_is_still_a_path(self) -> None:
        self.write_page("text", "<!-- id: s; src: docs/oct19 -->")
        self.assertEqual(self.details(), ["missing path: docs/oct19"])

    def test_a_folder_with_a_trailing_slash_is_reported_when_it_is_missing(self) -> None:
        self.write_page("Files: Models/Gone/, Models/.")
        self.assertEqual(self.details(), ["missing path: Models/Gone/"])

    def test_a_path_prefix_of_the_allowlist_is_not_reported(self) -> None:
        # Under git, .claude/ is a top folder of the repository, so its paths are citations at all.
        self.git_repo({".claude/worktrees/keep.txt": "", ".claude/other/keep.txt": ""})
        self.write_page("`.claude/worktrees/agent-1/a.swift` and `.claude/other/b.swift`.")
        self.assertEqual(self.details(), ["missing path: .claude/other/b.swift"])

    def test_a_bare_file_name_is_reported_unless_the_allowlist_names_it_exactly(self) -> None:
        self.write_page("Files: UIAccessibilityConstants.h, OldParser.swift, UIAccessibilityConstants2.h.")
        # The allowlist names the first exactly; a near name, and a removed source file, are stale.
        self.assertEqual(self.details(), ["missing path: OldParser.swift", "missing path: UIAccessibilityConstants2.h"])

    def test_an_allowlisted_bare_name_is_no_excuse_for_a_path_with_a_folder(self) -> None:
        self.write_page("Files: Models/UIAccessibilityConstants.h.")
        self.assertEqual(self.details(), ["missing path: Models/UIAccessibilityConstants.h"])


class NameTests(StaleTestCase):
    """Backticked names the index does not know, and the exceptions."""

    def test_an_unknown_type_is_reported_and_a_known_one_is_not(self) -> None:
        self.write_page("`Book` and `Booke` and `PlatformHelper`.")
        self.assertEqual(self.details(), ["unknown name: Booke"])

    def test_a_dotted_name_with_one_unknown_part_names_that_part(self) -> None:
        self.write_page("`Book.Storage`, `Book.Gone`, `Gone.Storage`, `Book.Storage.Gone`.")
        self.assertEqual(self.details(), ["unknown name: Gone", "unknown name: Gone", "unknown name: Gone"])
        _status, out, _err = self.run_cli("stale", "--json", "--max", "0")
        self.assertEqual([json.loads(line)["token"] for line in out.splitlines()],
                         ["Book.Gone", "Gone.Storage", "Book.Storage.Gone"])

    def test_lowercase_parts_are_not_checked(self) -> None:
        self.write_page("`Book.shared`, `Book.Storage.value`, `.terminateCancel`, `true`, `anything`.")
        self.assertEqual(self.details(), [])

    def test_a_call_must_be_a_function_or_a_type(self) -> None:
        # startLibrary is a function, Book an initializer, goneCall nothing.
        self.write_page("`startLibrary()`, `Book()`, `goneCall()`, `Book.goneCall()`, `Book.Storage()`.")
        self.assertEqual(self.details(), ["unknown name: goneCall()", "unknown name: goneCall()"])

    def test_a_call_to_an_unknown_type_is_reported_as_the_call_and_a_dotted_one_by_its_part(self) -> None:
        self.write_page("`Gone()`, `Gone.make()`.")
        self.assertEqual(self.details(), ["unknown name: Gone()", "unknown name: Gone"])

    def test_a_file_name_in_backticks_is_not_a_name(self) -> None:
        self.write_page("`Info.plist`, `content.md`, `library.json`, `Settings.PLIST`, `Gone.html`.")
        self.assertEqual(self.details(), [])

    def test_a_dotted_name_that_does_not_end_in_an_extension_is_checked(self) -> None:
        self.write_page("`Gone.Plist.Value`, `Book.plist`.")
        self.assertEqual(self.details(), ["unknown name: Gone"])

    def test_the_allowlist_names_prefixes_and_exact_names(self) -> None:
        self.write_page("`NSApplication`, `NSApp.shared`, `SwiftSoup`, `Sendable`, `SwiftSoupX`, `UIKit`.")
        self.assertEqual(self.details(), ["unknown name: SwiftSoupX", "unknown name: UIKit"])

    def test_an_allowlisted_name_may_be_a_call_or_a_part(self) -> None:
        self.write_page("`NSLog()`, `NSApp.activate()`, `Sendable.Gone`.")
        self.assertEqual(self.details(), ["unknown name: Gone"])

    def test_a_single_name_that_is_a_file_or_folder_is_a_path_not_a_name(self) -> None:
        # Scripts is a folder, Info a root file's stem is not; PlatformTypes names PlatformTypes.swift.
        self.write_page("`Scripts`, `Models`, `PlatformTypes`, `Gone`.")
        self.assertEqual(self.details(), ["unknown name: Gone"])

    def test_names_without_an_uppercase_and_a_lowercase_letter_are_not_type_shaped(self) -> None:
        self.write_page("`EPUB`, `UTF8`, `A`, `x`, `ABC.DEF`.")
        self.assertEqual(self.details(), [])

    def test_each_mention_is_one_hit_at_its_line(self) -> None:
        self.write_page("one `Gone`\ntwo `Gone`", heading="Heads")
        status, lines, err = self.stale()
        self.assertEqual(status, 1)
        self.assertEqual(lines, ["docs/p.md:3-3  Heads  unknown name: Gone",
                                 "docs/p.md:4-4  Heads  unknown name: Gone"])
        self.assertEqual(err, "doclib: 2 stale references (0 paths, 2 names)\n")

    def test_a_bare_type_name_is_not_checked(self) -> None:
        self.write_page("Owner: GoneCenter.shared in prose.")
        self.assertEqual(self.details(), [])

    def test_a_code_block_is_not_prose(self) -> None:
        self.write_page("```\n`Gone` Models/Gone.swift\n```")
        self.assertEqual(self.details(), [])

    def test_a_call_naming_an_enum_case_is_known(self) -> None:
        # shared-helpers.md names MarkupRefusal's cases as calls: `nestedTooDeeply(limit:)`.
        self.write_tree({"TextMouth/Parsers/Refusal.swift": "enum MarkupRefusal {\n    case nestedTooDeeply(limit: Int)\n}\n"})
        self.write_page("`nestedTooDeeply(limit:)` and `MarkupRefusal.nestedTooDeeply` and `goneCase()`.")
        self.assertEqual(self.details(), ["unknown name: goneCase()"])


class OutputTests(StaleTestCase):
    """The summary line, the exit status, JSON, the cap, scopes, and the allowlist's parts."""

    def test_nothing_stale_exits_0_and_still_prints_the_summary(self) -> None:
        self.write_page("`Book`")
        status, lines, err = self.stale()
        self.assertEqual((status, lines), (0, []))
        self.assertEqual(err, "doclib: 0 stale references (0 paths, 0 names)\n")

    def test_the_summary_counts_every_reference_even_past_the_cap(self) -> None:
        self.write_page("`Gone1` `Gone2` `Gone3` `Models/G.swift`")
        status, lines, err = self.stale("--max", "2")
        self.assertEqual((status, len(lines)), (1, 2))
        self.assertIn("2 of 4 stale references shown", err)
        self.assertTrue(err.endswith("doclib: 4 stale references (1 paths, 3 names)\n"))

    def test_the_default_cap_is_twenty(self) -> None:
        self.write_page(" ".join(f"`Gone{n}x`" for n in range(25)))
        _status, lines, err = self.stale()
        self.assertEqual(len(lines), 20)
        self.assertIn("doclib: 25 stale references (0 paths, 25 names)", err)

    def test_json_fields_for_a_name_and_a_path(self) -> None:
        self.write_page("`Gone`\n\n- Files: Models/Gone.swift", "<!-- id: the-id; src: TextMouth/Models/Book.swift -->")
        _status, out, _err = self.run_cli("stale", "--json")
        name_hit, path_hit = [json.loads(line) for line in out.splitlines()]
        self.assertEqual(name_hit, {
            "path": "docs/p.md", "start": 4, "end": 4, "heading": "Page", "text": "unknown name: Gone",
            "kind": "name", "token": "Gone", "citation_kind": None, "id": "the-id"})
        self.assertEqual(path_hit, {
            "path": "docs/p.md", "start": 6, "end": 6, "heading": "Page", "text": "missing path: Models/Gone.swift",
            "kind": "path", "token": "Models/Gone.swift", "citation_kind": "files", "id": "the-id"})

    def test_the_scope_option_reaches_the_memory_pages(self) -> None:
        self.write_tree({"AGENTS.md": "# Agents\n\nSee `Gone` and `Book`.\n", "docs/p.md": "# P\n\n`Book`\n"})
        self.assertEqual(self.stale()[0], 0)
        status, lines, _err = self.stale("--scope", "all")
        self.assertEqual((status, lines), (1, ["AGENTS.md:3-3  Agents  unknown name: Gone"]))

    def test_stale_items_gives_the_data_the_lint_counts(self) -> None:
        self.write_page("`Gone` and `Models/Gone.swift`.", "<!-- id: s; src: TextMouth/Models/Book.swift -->")
        repo = RepoFiles.load(self.root)
        pages = docmodel.load_pages(self.root, ["docs/p.md"])
        items = stale_items(pages, repo, SwiftIndex.load(repo), load_allowlist(self.root))
        # On one line, the path comes before the name.
        self.assertEqual(items, [
            StaleItem("docs/p.md", 4, "Page", "path", "Models/Gone.swift", "text", "missing path: Models/Gone.swift", "s"),
            StaleItem("docs/p.md", 4, "Page", "name", "Gone", None, "unknown name: Gone", "s"),
        ])


class AllowlistTests(DocLibCase):
    """parse_allowlist and load_allowlist."""

    def test_entries_by_shape(self) -> None:
        allow = parse_allowlist(ALLOWLIST)
        self.assertEqual(allow.paths, (".claude/worktrees/",))
        self.assertEqual(allow.name_prefixes, ("NS",))
        self.assertEqual(allow.names, frozenset({"SwiftSoup", "UIAccessibilityConstants.h", "Sendable"}))

    def test_what_each_kind_of_entry_allows(self) -> None:
        allow = parse_allowlist(ALLOWLIST)
        self.assertTrue(allow.allows_path(".claude/worktrees/x/y.swift"))
        self.assertFalse(allow.allows_path("x/.claude/worktrees/"))
        self.assertTrue(allow.allows_name("NSEvent"))
        self.assertTrue(allow.allows_name("NS"))
        self.assertFalse(allow.allows_name("MyNS"))
        self.assertTrue(allow.allows_name("SwiftSoup"))
        self.assertFalse(allow.allows_name("SwiftSoupX"))
        self.assertTrue(allow.allows_file("UIAccessibilityConstants.h"))
        self.assertFalse(allow.allows_file("Other.h"))

    def test_a_missing_file_is_an_empty_allowlist(self) -> None:
        self.assertEqual(load_allowlist(self.root), Allowlist())

    def test_the_file_is_read_from_the_repository(self) -> None:
        self.write_tree({cmd_stale.ALLOWLIST_PATH: "Alpha\nBeta*\n"})
        allow = load_allowlist(self.root)
        self.assertEqual((allow.names, allow.name_prefixes), (frozenset({"Alpha"}), ("Beta",)))
