"""The lexer: string literals of every form, comments, regex literals, and the context of each."""

from __future__ import annotations

import unittest

from scan_case import lex, texts_of


class LiteralFormsTests(unittest.TestCase):
    """Plain, multi-line, and raw literals, their escapes, and their interpolations."""

    def test_a_plain_literal(self) -> None:
        found = lex('let a = "Hello, world"')
        self.assertEqual(texts_of(found), ["Hello, world"])
        self.assertEqual((found[0].line, found[0].multiline, found[0].has_interp), (1, False, False))

    def test_an_empty_literal_and_two_on_a_line(self) -> None:
        self.assertEqual(texts_of(lex('f("", "x")')), ["", "x"])

    def test_a_multi_line_literal_loses_its_indentation_and_its_outer_newlines(self) -> None:
        code = 'let a = """\n    First line\n      indented more\n    Last line\n    """\nlet b = "after"'
        found = lex(code)
        self.assertEqual(texts_of(found), ["First line\n  indented more\nLast line", "after"])
        self.assertTrue(found[0].multiline)
        self.assertEqual((found[0].line, found[0].end_line, found[1].line), (1, 5, 6))

    def test_a_multi_line_literal_may_hold_quotes_and_a_continued_line(self) -> None:
        code = 'let a = """\n    She said "hi" and \\\n    left.\n    """'
        self.assertEqual(texts_of(lex(code)), ['She said "hi" and left.'])

    def test_a_raw_literal_with_one_hash_has_no_escapes_but_its_own(self) -> None:
        # In #"..."# a backslash is plain and \n is two characters; \#n is the escape.
        found = lex('let a = #"C:\\temp "quoted" \\#n done"#')
        self.assertEqual(texts_of(found), ['C:\\temp "quoted" \n done'])

    def test_a_raw_literal_with_two_hashes_ends_only_at_quote_and_two_hashes(self) -> None:
        found = lex('let a = ##"one "# still ## inside"## + "next"')
        self.assertEqual(texts_of(found), ['one "# still ## inside', "next"])

    def test_a_raw_literal_interpolates_with_backslash_hash_parenthesis(self) -> None:
        found = lex('let a = #"value \\#(count) and \\(not)"#')
        self.assertEqual(texts_of(found), ["value %@ and \\(not)"])
        self.assertTrue(found[0].has_interp)

    def test_a_raw_multi_line_literal(self) -> None:
        code = 'let a = #"""\n  line "one"\n  line \\two\n  """#'
        self.assertEqual(texts_of(lex(code)), ['line "one"\nline \\two'])

    def test_escapes_become_their_characters(self) -> None:
        found = lex('let a = "tab\\there\\nnext \\"quoted\\" back\\\\slash \\u{E9}\\u{1F600}"')
        self.assertEqual(texts_of(found), ['tab\there\nnext "quoted" back\\slash \u00e9\U0001F600'])

    def test_an_escaped_quote_does_not_end_the_literal_and_a_double_backslash_does_not_hide_the_end(self) -> None:
        self.assertEqual(texts_of(lex('f("a\\"b", "c\\\\")')), ['a"b', "c\\"])

    def test_an_interpolation_counts_as_a_placeholder(self) -> None:
        found = lex('let a = "\\(count) books by \\(author.name)"')
        self.assertEqual(texts_of(found), ["%@ books by %@"])
        self.assertTrue(found[0].has_interp)

    def test_an_unterminated_single_line_literal_ends_at_its_line(self) -> None:
        self.assertEqual(texts_of(lex('let a = "oops\nlet b = "fine"')), ["oops", "fine"])


class NestedLiteralTests(unittest.TestCase):
    """Interpolations that hold strings and closures."""

    def test_an_interpolation_holding_a_ternary_of_strings(self) -> None:
        found = lex('Text("\\(x ? "a" : "b")")')
        # The nested literals come first in the source of the outer one's text, but the lexer
        # returns them in source order: the outer literal starts first.
        self.assertEqual(texts_of(found), ["%@", "a", "b"])
        self.assertEqual([lit.in_interp for lit in found], [False, True, True])

    def test_an_interpolation_holding_a_closure_with_its_own_interpolation(self) -> None:
        found = lex('let s = "items: \\(items.map { "<\\($0)>" }.joined())"')
        self.assertEqual(texts_of(found), ["items: %@", "<%@>"])
        self.assertEqual([lit.in_interp for lit in found], [False, True])

    def test_an_interpolation_holding_brackets_and_a_call(self) -> None:
        found = lex('let s = "\\(lookup(["k": "v"]))!" + "tail"')
        self.assertEqual(texts_of(found), ["%@!", "k", "v", "tail"])

    def test_code_after_a_nested_literal_is_still_lexed(self) -> None:
        found = lex('a("\\(b("c"))", "d")')
        self.assertEqual(texts_of(found), ["%@", "c", "d"])


class CommentAndRegexTests(unittest.TestCase):
    """Quotes inside comments and regex literals start nothing."""

    def test_a_quote_in_a_line_comment_starts_no_literal(self) -> None:
        found = lex('let a = "kept" // she said "no\nlet b = "also kept"')
        self.assertEqual(texts_of(found), ["kept", "also kept"])

    def test_a_doc_comment_with_a_quote(self) -> None:
        self.assertEqual(texts_of(lex('/// Returns "x" for a.\nlet a = "y"')), ["y"])

    def test_nested_block_comments(self) -> None:
        code = 'let a = "one" /* outer "q" /* inner "q2" */ still "q3" outer */ + "two"'
        self.assertEqual(texts_of(lex(code)), ["one", "two"])

    def test_a_block_comment_marker_inside_a_literal_is_text(self) -> None:
        self.assertEqual(texts_of(lex('let a = "see /* not a comment */ here" // real')), ["see /* not a comment */ here"])

    def test_a_double_slash_inside_a_literal_is_text(self) -> None:
        self.assertEqual(texts_of(lex('let u = "https://example.com/x"')), ["https://example.com/x"])

    def test_an_extended_regex_literal_holds_quotes_without_starting_a_string(self) -> None:
        found = lex('let r = #/"[^"]+"/#\nlet s = "after"')
        self.assertEqual(texts_of(found), ["after"])
        self.assertEqual(found[0].line, 2)


class ContextTests(unittest.TestCase):
    """What each literal records about the code around it."""

    def test_call_label_and_argument_position(self) -> None:
        found = lex('Label("Sort", systemImage: "arrow.up")')
        self.assertEqual([(l.call, l.label, l.arg_index) for l in found],
                         [("Label", None, 0), ("Label", "systemImage", 1)])

    def test_the_receiver_of_a_call(self) -> None:
        found = lex('DiagnosticLog.event(.storage, "TAG: text")')
        self.assertEqual((found[0].call, found[0].receiver, found[0].arg_index), ("event", "DiagnosticLog", 1))

    def test_a_bare_parenthesis_belongs_to_the_call_around_it(self) -> None:
        found = lex('Text(a + (flag ? "x" : "y"))')
        self.assertEqual([l.call for l in found], ["Text", "Text"])

    def test_a_ternary_colon_in_a_bare_parenthesis_is_no_argument_label(self) -> None:
        # With no call around it, a literal has no call and no label, whatever precedes the colon.
        found = lex('let t = (ready ? name : "Not ready yet")')
        self.assertEqual((found[0].call, found[0].label), (None, None))

    def test_the_colon_of_a_ternary_is_no_argument_label(self) -> None:
        # Text(isOn ? onTitle : "Off") must not give "Off" the label onTitle.
        found = lex('Text(isOn ? onTitle : "Off")\nf(a: c ? 1 : 2, b: "B")\ng(p: c ? "x" : "y")')
        self.assertEqual([(l.text, l.label) for l in found], [("Off", None), ("B", "b"), ("x", "p"), ("y", "p")])

    def test_a_colon_or_comma_in_an_interpolation_keeps_the_calls_label_and_index(self) -> None:
        # Views/Library/MetadataEditorView.swift:152 and Views/Reader/ReadingStatsView.swift:89:
        # a : or , inside \(...) rewrote the label and the index of the call around the literal.
        found = lex('f(title: "\\(c ? 1 : 2) \\(h(a, b))", "next")')
        self.assertEqual([(l.text, l.label, l.arg_index) for l in found], [("%@ %@", "title", 0), ("next", None, 1)])
        found = lex('f("\\(c ? "x" : "y") and \\(d)", "next")')
        self.assertEqual([(l.text, l.label, l.arg_index, l.in_interp) for l in found],
                         [("%@ and %@", None, 0, False), ("x", None, 0, True), ("y", None, 0, True), ("next", None, 1, False)])

    def test_a_generic_call_keeps_its_name(self) -> None:
        self.assertEqual(lex('let a = Array<String>(arrayLiteral: "x")')[0].call, "Array")

    def test_the_declarations_a_literal_is_in(self) -> None:
        code = 'enum SleepWording {\n    static func title() -> String {\n        "Sleep timer"\n    }\n}'
        found = lex(code)
        self.assertEqual(found[0].blocks, ["SleepWording", "title"])
        self.assertEqual(found[0].decl, None)

    def test_a_raw_value_is_marked(self) -> None:
        found = lex('enum Mode {\n    case none = "None"\n}')
        self.assertTrue(found[0].raw_value)

    def test_line_numbers_count_every_newline(self) -> None:
        found = lex('a\n\nb("x")\n/* two\nlines */ c("y")')
        self.assertEqual([l.line for l in found], [3, 5])

    def test_a_whole_argument_is_not_part_of_an_expression(self) -> None:
        found = lex('Text("a")\nText(flag ? "b" : "c")\nText("d" + name)\nText(verbatim: "e")\nText(name + "f")\nf(x, "g", y)')
        self.assertEqual(texts_of(found), ["a", "b", "c", "d", "e", "f", "g"])
        # The two branches of a ternary of literals are whole arguments together.
        self.assertEqual([l.whole_arg for l in found], [True, True, True, False, True, False, True])

    def test_a_ternary_branch_is_whole_only_when_the_other_branch_is_a_literal(self) -> None:
        code = 'a(x ? "b" : c)\na(x ? c : "d")\na(x ?? "e")\na(p + (x ? "f" : "g"))\na(l: x ? "h" : "i", 1)\na(x ? "j" : "k" + m)'
        self.assertEqual([(l.text, l.whole_arg) for l in lex(code)], [
            ("b", False), ("d", False), ("e", False), ("f", False), ("g", False),
            ("h", True), ("i", True), ("j", False), ("k", False)])


class StaticLetTests(unittest.TestCase):
    """Which literals belong to the initializer of a static let."""

    def test_a_static_let_holds_its_literal_and_a_static_func_does_not(self) -> None:
        code = 'enum W {\n    static let a = "one"\n    static func b() -> String { "two" }\n    static var c: String { "three" }\n}'
        found = lex(code)
        self.assertEqual([l.static_let for l in found], [2, 0, 0])

    def test_a_static_let_array_and_a_continued_string_belong_to_the_declaration(self) -> None:
        code = 'enum W {\n    static let all = [\n        "a",\n        "b",\n    ]\n    static let long = "c "\n        + "d"\n}'
        self.assertEqual([l.static_let for l in lex(code)], [2, 2, 6, 6])

    def test_a_modifier_between_static_and_let_still_counts(self) -> None:
        self.assertEqual(lex('struct S {\n    private static let a = "x"\n}')[0].static_let, 2)
        self.assertEqual(lex('struct S {\n    static nonisolated let a = "x"\n}')[0].static_let, 2)

    def test_an_instance_let_and_a_local_let_are_not_static(self) -> None:
        code = 'struct S {\n    let a = "x"\n    func f() { let b = "y" }\n}'
        self.assertEqual([l.static_let for l in lex(code)], [0, 0])

    def test_a_local_let_inside_a_static_let_closure_stays_in_the_static_let(self) -> None:
        code = 'enum W {\n    static let a: String = {\n        let b = "x"\n        return b\n    }()\n}'
        self.assertEqual(lex(code)[0].static_let, 2)

    def test_the_next_declaration_ends_the_static_let(self) -> None:
        code = 'enum W {\n    static let a = "x"\n    case b = "y"\n    static var c: String { "z" }\n}'
        self.assertEqual([l.static_let for l in lex(code)], [2, 0, 0])


class GlueTests(unittest.TestCase):
    """Sentences built from pieces."""

    def test_a_literal_plus_a_variable_is_glued_on_either_side(self) -> None:
        found = lex('let a = "Reading " + title\nlet b = name + " is done"')
        self.assertEqual([l.glue for l in found], ["plus", "plus"])

    def test_a_plus_between_two_plain_literals_only_wraps_a_line(self) -> None:
        found = lex('let a = "A long sentence, "\n    + "continued here."')
        self.assertEqual([l.glue for l in found], [None, None])

    def test_a_plus_between_a_plain_literal_and_an_interpolating_one_is_glued(self) -> None:
        found = lex('let a = "Moved: "\n    + "\\(title) to \\(folder)"')
        self.assertEqual([l.glue for l in found], ["plus", "plus"])

    def test_plus_equals_appends_to_a_variable(self) -> None:
        self.assertEqual(lex('text += "more words"')[0].glue, "plus")

    def test_joined_literals_are_glued(self) -> None:
        found = lex('let a = ["one", "two", extra].joined(separator: " ")\nlet b = ["x", "y"]')
        # one, two, the separator " ", then x and y.
        self.assertEqual([l.glue for l in found], ["joined", "joined", None, None, None])

    def test_a_literal_alone_in_a_call_is_not_glued(self) -> None:
        self.assertEqual(lex('let a = f("x")')[0].glue, None)


if __name__ == "__main__":
    unittest.main()
