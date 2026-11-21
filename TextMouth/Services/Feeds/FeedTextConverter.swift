import Foundation
import SwiftSoup

// MARK: - A Text as a Feed Gives It (FR03)

/// A summary, content, or description as a feed gives it, before it is read
/// (FR03).
struct FeedTextSource: Equatable, Sendable {
    /// What kind of text it is.
    enum Kind: Equatable, Sendable {
        /// HTML: an Atom text construct of type html or xhtml.
        case html
        /// Plain text: an Atom text construct of type text.
        case plain
        /// Either: an RSS description, which may hold HTML or plain text,
        /// told apart by looking for markup (`FeedTextConverter.looksLikeHTML`).
        case unknown
    }

    /// The text, as the document holds it once its own escaping is undone.
    var text: String
    /// What kind of text it is.
    var kind: Kind
}

// MARK: - Reading a Feed's Text

/// Reads a feed's texts through the app's own HTML readers (FR03), so an
/// item's summary reads exactly as its article's book would.
///
/// Every text becomes HTML first: the feed's own markup, or its plain text
/// with each blank line a new paragraph and each line break a break. The
/// HTML converter (`HTMLToMarkdownConverter`) then writes it as Markdown,
/// which keeps headings, emphasis, lists, and links, and the Markdown
/// reader (`MarkdownDocParser`) reads that as the plain text a listener
/// hears, paragraph by paragraph. Images are read as their alt text and
/// never fetched; scripts and styles are never read.
enum FeedTextConverter {
    /// The HTML `source` amounts to, or nil when it holds nothing but
    /// whitespace.
    static func html(for source: FeedTextSource) -> String? {
        let trimmed = source.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch source.kind {
        case .html:
            return trimmed
        case .plain:
            return htmlFromPlainText(trimmed)
        case .unknown:
            return looksLikeHTML(trimmed) ? trimmed : htmlFromPlainText(trimmed)
        }
    }

    /// `source` read as plain text and Markdown, or nil when it holds
    /// nothing worth reading.
    static func read(_ source: FeedTextSource) -> FeedText? {
        html(for: source).flatMap(read(html:))
    }

    /// `html` read as plain text and Markdown, or nil when it reads as
    /// nothing, as markup holding only an image without alt text does.
    static func read(html: String) -> FeedText? {
        let markdown = (try? HTMLToMarkdownConverter.convert(html)) ?? ""
        let plainText = ((try? MarkdownDocParser.parseChapter(markdown: markdown))?.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plainText.isEmpty else { return nil }
        return FeedText(html: html, plainText: plainText, markdown: markdown)
    }

    /// `text` as a single line of plain text, as a title is read, with every
    /// run of whitespace one space. HTML (an Atom title of type html or
    /// xhtml) loses its markup; any title has its character references
    /// undone, for the RSS titles publishers escape twice ("Q&amp;amp;A"),
    /// while a "<" in plain text stays a character.
    static func plainLine(_ text: String, isHTML: Bool = false) -> String {
        var line = text
        if isHTML {
            // SwiftSoup reads a fragment's text with references undone.
            line = (try? MarkupGuard.parseBodyFragment(text).text()) ?? text
        } else if text.contains("&") {
            // Escaping every "<" first keeps plain text from being read as
            // tags, so only the references are undone.
            let escapedTags = text.replacingOccurrences(of: "<", with: "&lt;")
            line = (try? MarkupGuard.parseBodyFragment(escapedTags).text()) ?? text
        }
        return line
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Whether `text` holds HTML markup: a tag of an HTML element, a
    /// comment or doctype, or a character reference such as "&amp;", rather
    /// than plain text that happens to hold a "<": "a < b", "<3", or an
    /// address in angle brackets, "<mail@show.example>", which a reading as
    /// HTML would drop.
    static func looksLikeHTML(_ text: String) -> Bool {
        if text.range(of: "<!--") != nil || text.range(of: "<!doctype", options: .caseInsensitive) != nil {
            return true
        }
        // A tag: "<" or "</", a name, then whitespace, "/", or ">".
        let tag = #"</?[a-zA-Z][a-zA-Z0-9]*(?=[\s/>])"#
        var searchStart = text.startIndex
        while let match = text.range(of: tag, options: .regularExpression, range: searchStart..<text.endIndex) {
            let name = text[match].drop(while: { $0 == "<" || $0 == "/" }).lowercased()
            if htmlElementNames.contains(name) {
                return true
            }
            searchStart = match.upperBound
        }
        return text.range(of: #"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);"#, options: .regularExpression) != nil
    }

    /// The names of HTML's elements, current and obsolete (the HTML Living
    /// Standard's elements and its list of obsolete ones), one of which a
    /// tag in a feed's text must name to make the text HTML.
    private static let htmlElementNames: Set<String> = [
        "a", "abbr", "acronym", "address", "area", "article", "aside", "audio", "b", "base", "bdi", "bdo",
        "big", "blockquote", "body", "br", "button", "canvas", "caption", "center", "cite", "code", "col",
        "colgroup", "data", "datalist", "dd", "del", "details", "dfn", "dialog", "div", "dl", "dt", "em",
        "embed", "fieldset", "figcaption", "figure", "font", "footer", "form", "h1", "h2", "h3", "h4", "h5",
        "h6", "head", "header", "hgroup", "hr", "html", "i", "iframe", "img", "input", "ins", "kbd", "label",
        "legend", "li", "link", "main", "map", "mark", "menu", "meta", "meter", "nav", "noscript", "object",
        "ol", "optgroup", "option", "output", "p", "param", "picture", "pre", "progress", "q", "rp", "rt",
        "ruby", "s", "samp", "script", "search", "section", "select", "slot", "small", "source", "span",
        "strike", "strong", "style", "sub", "summary", "sup", "svg", "table", "tbody", "td", "template",
        "textarea", "tfoot", "th", "thead", "time", "title", "tr", "track", "tt", "u", "ul", "var", "video",
        "wbr",
    ]

    /// Plain `text` as HTML: its characters escaped, each run of blank lines
    /// a new paragraph, and each other line break a break.
    static func htmlFromPlainText(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let paragraphs = normalized
            .components(separatedBy: "\n")
            .split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        return paragraphs.map { lines in
            "<p>" + lines.map { escaped($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: "<br>") + "</p>"
        }.joined(separator: "\n")
    }

    /// `text` with the characters HTML gives meaning to escaped, by the shared
    /// writer (`XMLEscaping.markup(_:)`): it walks scalars, as a parser reads,
    /// so an "&" or "<" with a combining accent after it is escaped too, and
    /// leaves out what XML forbids (a form feed or vertical tab becomes a space).
    static func escaped(_ text: String) -> String {
        XMLEscaping.markup(text)
    }
}
