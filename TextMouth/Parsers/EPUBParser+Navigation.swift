import Foundation
import SwiftSoup
import ZIPFoundation

extension EPUBParser {
    /// Both the direct reader and cache writer consume this same extraction.
    struct PreparedChapter {
        var markdown: String
        var chapter: Chapter
    }

    /// An archive-relative destination retains its fragment and hierarchy so
    /// several logical sections in one XHTML file remain independently usable.
    private struct NavigationTarget {
        var path: String
        var fragment: String
        var heading: MarkdownHeadingAnnotation
    }

    /// Keep source strings in spine order while inspecting navigation. DOMs
    /// are short lived, avoiding retained SwiftSoup selector caches per book.
    private struct SpineDocument {
        var path: String
        var html: String
        var title: String
        var number: Int
    }

    /// Recover semantic and TOC headings, then give every retained spine
    /// document a start destination without inserting words into its speech.
    static func preparedChapters(
        archive: Archive,
        opfPath: String,
        opfData: OPFData
    ) throws -> [PreparedChapter] {
        var navigation = readNavigation(archive: archive, opfPath: opfPath, opfData: opfData)
        var documents: [SpineDocument] = []

        for (index, itemRef) in opfData.spineItemRefs.enumerated() {
            guard let item = opfData.manifest[itemRef],
                  item.mediaType.contains("html") || item.mediaType.contains("xml") else { continue }
            let path = ParserUtilities.resolvedPackagePath(item.href, relativeTo: opfPath, preserveFragment: false)
            guard let html = try? extractString(archive: archive, path: path) else { continue }
            let doc = try SwiftSoup.parse(html)
            documents.append(SpineDocument(path: path, html: html, title: try doc.title(), number: index + 1))

            // Some converted EPUBs have an incomplete machine TOC but a full
            // linked contents section in the reading order (including Helliconia).
            // Only explicitly identified TOCs contribute labels, never prose links.
            let body = doc.body() ?? doc
            for element in elements(in: body) where isContentsContainer(element) {
                navigation += linkedTargets(in: element, relativeTo: path)
            }
        }

        // Prefer EPUB 3 navigation, then the declared NCX, then visible contents.
        // Deduplicate destinations, not filenames: nested fragment links matter.
        var targetsByPath: [String: [NavigationTarget]] = [:]
        var seenFragmentsByPath: [String: Set<String>] = [:]
        for target in navigation {
            guard seenFragmentsByPath[target.path, default: []].insert(target.fragment).inserted else { continue }
            targetsByPath[target.path, default: []].append(target)
        }

        return try documents.compactMap { document in
            let targets = targetsByPath[document.path] ?? []
            let headingTargets = Dictionary(uniqueKeysWithValues: targets.filter { !$0.fragment.isEmpty }.map {
                ($0.fragment, $0.heading)
            })
            var markdown = try HTMLToMarkdownConverter.convert(
                document.html, stripDuplicateNavigation: true, headingTargets: headingTargets
            )
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            let documentTitle = normalizedLabel(document.title)
            let fallbackTitle = targets.first(where: { $0.fragment.isEmpty })?.heading.text
                ?? (!documentTitle.isEmpty && documentTitle != normalizedLabel(opfData.title)
                    ? documentTitle : "Chapter \(document.number)")
            var chapter = try MarkdownDocParser.parseChapter(
                markdown: markdown, title: fallbackTitle, includeNavigationHeadings: true
            )
            if chapter.headings.first?.characterOffset != 0 {
                // An untitled chapter (or one with only a later subheading)
                // still needs a start entry. Persist it as metadata, never # text.
                // A broken fragment can still supply a title when no heading
                // survived. A real later section must not be relabeled as the
                // start of the chapter as well as keeping its actual target.
                let title = chapter.headings.isEmpty ? (targets.first?.heading.text ?? fallbackTitle) : fallbackTitle
                let heading = MarkdownHeadingAnnotation(level: 1, text: title)
                markdown = heading.markdown + "\n\n" + markdown
                chapter.headings.insert(Heading(level: heading.level, text: heading.text), at: 0)
            }
            chapter.title = chapter.headings.first?.text ?? fallbackTitle
            return PreparedChapter(markdown: markdown, chapter: chapter)
        }
    }

    /// Discover the EPUB 3 navigation document via its manifest properties and
    /// the EPUB 2 NCX via the spine's toc attribute. All URLs use their own base.
    private static func readNavigation(archive: Archive, opfPath: String, opfData: OPFData) -> [NavigationTarget] {
        var result: [NavigationTarget] = []
        let manifest = opfData.manifest.sorted { $0.key < $1.key }
        for (_, item) in manifest where item.properties.split(whereSeparator: \.isWhitespace).contains("nav") {
            let path = ParserUtilities.resolvedPackagePath(item.href, relativeTo: opfPath, preserveFragment: false)
            guard let html = try? extractString(archive: archive, path: path),
                  let doc = try? SwiftSoup.parse(html) else { continue }
            for element in elements(in: doc) where element.tagName() == "nav" && hasSemanticType("toc", element: element) {
                result += linkedTargets(in: element, relativeTo: path)
            }
        }

        let ncx = opfData.spineTOCID.flatMap { opfData.manifest[$0] }
            ?? manifest.first(where: { $0.value.mediaType.contains("ncx") })?.value
        if let ncx {
            let path = ParserUtilities.resolvedPackagePath(ncx.href, relativeTo: opfPath, preserveFragment: false)
            if let xml = try? extractString(archive: archive, path: path),
               let doc = try? XMLDocument(xmlString: xml),
               let maps = try? doc.nodes(forXPath: "//*[local-name()='navMap']") {
                for map in maps {
                    result += ncxTargets(in: map, relativeTo: path, level: 1)
                }
            }
        }

        // Legacy guides can refer to a visible TOC that is not itself in the
        // reading order. Honor its fragment so unrelated page links stay out.
        for href in opfData.guideTOCHrefs {
            let path = ParserUtilities.resolvedPackagePath(href, relativeTo: opfPath, preserveFragment: false)
            guard let html = try? extractString(archive: archive, path: path),
                  let doc = try? SwiftSoup.parse(html) else { continue }
            let fragment = ParserUtilities.splitFragment(href).fragment
            let target = fragment.isEmpty ? nil : elements(in: doc).first { (try? $0.attr("id")) == fragment }
            result += linkedTargets(in: target ?? doc.body() ?? doc, relativeTo: path)
        }
        return result
    }

    /// Traverse NCX children directly so labels stay with their own parent and
    /// nested sections keep their source order instead of being flattened.
    private static func ncxTargets(in node: XMLNode, relativeTo path: String, level: Int) -> [NavigationTarget] {
        var result: [NavigationTarget] = []
        for element in (node.children ?? []).compactMap({ $0 as? XMLElement }) where element.localName == "navPoint" {
            let label = (try? element.nodes(forXPath: "*[local-name()='navLabel']/*[local-name()='text']"))?.first?.stringValue ?? ""
            let content = (try? element.nodes(forXPath: "*[local-name()='content']"))?.first as? XMLElement
            if let href = content?.attribute(forName: "src")?.stringValue,
               let target = navigationTarget(href: href, label: label, level: level, relativeTo: path) {
                result.append(target)
            }
            result += ncxTargets(in: element, relativeTo: path, level: level + 1)
        }
        return result
    }

    /// Follow a TOC's linked labels in DOM order, retaining nested list levels.
    private static func linkedTargets(in node: Node, relativeTo path: String, level: Int = 0) -> [NavigationTarget] {
        var result: [NavigationTarget] = []
        for element in node.getChildNodes().compactMap({ $0 as? Element }) {
            let tag = element.tagName()
            if tag == "a", let href = try? element.attr("href"),
               let label = try? element.text(),
               let target = navigationTarget(href: href, label: label, level: max(1, level), relativeTo: path) {
                result.append(target)
            }
            result += linkedTargets(in: element, relativeTo: path, level: level + (tag == "ol" || tag == "ul" ? 1 : 0))
        }
        return result
    }

    /// Resolve one local URL while excluding web/mail links and keeping encoded
    /// filename delimiters distinct from the URL's query and fragment syntax.
    private static func navigationTarget(href: String, label: String, level: Int, relativeTo path: String) -> NavigationTarget? {
        let label = normalizedLabel(label)
        let href = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !href.isEmpty, !href.hasPrefix("//"),
              URLComponents(string: href)?.scheme == nil else { return nil }
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let file = String(parts[0]).components(separatedBy: "?")[0]
        let fragment = parts.count > 1 ? String(parts[1]) : ""
        return NavigationTarget(
            path: file.isEmpty ? path : ParserUtilities.resolvedPackagePath(file, relativeTo: path, preserveFragment: false),
            fragment: fragment.removingPercentEncoding ?? fragment,
            heading: MarkdownHeadingAnnotation(level: min(6, max(1, level)), text: label)
        )
    }

    /// Recognize semantic TOCs and conventional converted-book containers,
    /// without treating arbitrary lists or links in the prose as navigation.
    private static func isContentsContainer(_ element: Element) -> Bool {
        guard ["nav", "section", "div", "article"].contains(element.tagName()) else { return false }
        if hasSemanticType("toc", element: element) { return true }
        let role = (try? element.attr("role")) ?? ""
        if role.split(whereSeparator: \.isWhitespace).contains("doc-toc") { return true }
        let id = ((try? element.attr("id")) ?? "").lowercased()
        return ["toc", "contents", "table-of-contents"].contains(id) || id.hasSuffix("-toc")
    }

    /// EPUB permits namespace aliases for epub:type; check the local attribute
    /// name and whitespace-separated tokens instead of assuming one prefix.
    private static func hasSemanticType(_ type: String, element: Element) -> Bool {
        (element.getAttributes()?.asList() ?? []).contains {
            $0.getKey().hasSuffix(":type") && $0.getValue().split(whereSeparator: \.isWhitespace).contains(Substring(type))
        }
    }

    /// Walk without selector caches, releasing each temporary document after
    /// its metadata is collected. Reversing children preserves source order.
    private static func elements(in node: Node) -> [Element] {
        var pending: [Node] = [node]
        var result: [Element] = []
        while let current = pending.popLast() {
            if let element = current as? Element { result.append(element) }
            pending.append(contentsOf: current.getChildNodes().reversed())
        }
        return result
    }

    /// Navigation labels are single lines even when their source is formatted.
    private static func normalizedLabel(_ label: String) -> String {
        label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
