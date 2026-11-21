import Foundation

// MARK: - Link Inputs for the EPUB Writer (B5)

/// 45 inputs of links, in Markdown, that the review of the EPUB export found 24 of which fail
/// EPUBCheck when written as they stand: spaces, bars, brackets, braces, a second "#", a bad
/// port, no host, an empty mail address, and letters beyond ASCII. Each is a book of one
/// paragraph. The test checks every address the writer writes, and, where `epubcheck` is
/// installed, that the whole set passes it.
enum EPUBLinkCases {
    /// The name of each case and its Markdown.
    static let all: [(name: String, markdown: String)] = [
        ("link_angle", "<https://example.com/a?b=1&c=2>"),
        ("link_backslash", "[x](<http://exam\\ple.com>)"),
        ("link_bad_percent", "[x](http://example.com/a%zz)"),
        ("link_bad_port", "[x](http://example.com:port/)"),
        ("link_bracket", "[x](<http://[::1>)"),
        ("link_caret", "[x](https://example.com/^`{})"),
        ("link_control", "[x](http://example.com/&#1;b)"),
        ("link_data", "[x](data:text/html,<script>alert(1)</script>)"),
        ("link_double_hash", "[x](https://example.com/a#b#c)"),
        ("link_empty_text", "[](https://example.com/)"),
        ("link_file", "[x](file:///etc/passwd)"),
        ("link_fragment", "[x](#a)"),
        ("link_fullwidth", "[x](http://\u{FF45}xample.com/)"),
        ("link_gt", "[x](<http://example.com/a\\>b>)"),
        ("link_http_bare", "[x](http:)"),
        ("link_http_js", "[x](http:javascript:alert(1))"),
        ("link_http_nohost", "[x](http:///path)"),
        ("link_https_empty", "[x](https://)"),
        ("link_image_in_link", "[![alt](i.png)](https://example.com/)"),
        ("link_in_heading", "# [x](https://example.com/)\n\nWords."),
        ("link_javascript", "[x](javascript:alert(1))"),
        ("link_javascript_case", "[x](JaVaScRiPt:alert(1))"),
        ("link_javascript_space", "[x](<java script:alert(1)>)"),
        ("link_long", "[x](https://example.com/" + String(repeating: "a", count: 5000) + ")"),
        ("link_mailto", "[x](mailto:a@example.com)"),
        ("link_mailto_empty", "[x](mailto:)"),
        ("link_nested_em", "[*a* **b** `c`](https://example.com/)"),
        ("link_pipe", "[x](https://example.com/a|b)"),
        ("link_quote", "[x](https://example.com/\"y\")"),
        ("link_relative", "[x](other.xhtml#a)"),
        ("link_space", "[x](<http://exa mple.com/a b>)"),
        ("link_unicode", "[x](https://\u{E9}.example/\u{FC})"),
        ("link_entity_amp", "[x](https://example.com/?a=1&amp;b=2)"),
        ("link_ffff", "[x](https://example.com/&#xFFFF;a)"),
        ("link_mailto_params", "[x](mailto:a@example.com?subject=Hi%20there&body=x)"),
        ("link_mailto_space", "[x](<mailto:a b@example.com>)"),
        ("link_real_backslash", "[w](http://example.com\\path)"),
        ("link_real_brackets", "[q](https://example.com/?a[]=1&a[]=2)"),
        ("link_real_curly", "[t](https://example.com/{id}/x)"),
        ("link_real_hash", "[app](https://example.com/#/page#section)"),
        ("link_real_pipe", "[fonts](https://fonts.googleapis.com/css?family=Open+Sans|Roboto)"),
        ("link_real_space_pdf", "[The Report](<https://example.com/My Report 2024.pdf>)"),
        ("link_uppercase_scheme", "[x](HTTP://EXAMPLE.COM/)"),
        ("link_with_nbsp", "[x](<https://example.com/a\u{A0}b>)"),
        ("link_with_tab", "[x](<https://example.com/a\u{9}b>)"),
    ]
}
