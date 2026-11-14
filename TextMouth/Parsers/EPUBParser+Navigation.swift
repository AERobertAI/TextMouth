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

    /// The book's navigation destinations, by the document each lies in,
    /// gathered as the book is read: the navigation documents' first, then
    /// each contents section's in reading order. Each destination (a
    /// fragment of a document, or the document itself) is named once, by
    /// the first name it is given; deduplicating destinations rather than
    /// filenames keeps nested fragment links.
    private struct NavigationTargets {
        private var targetsByPath: [String: [NavigationTarget]] = [:]
        private var seenFragmentsByPath: [String: Set<String>] = [:]

        /// The destinations `targets` names.
        init(_ targets: [NavigationTarget]) {
            add(targets)
        }

        /// Add the destinations `targets` names that are not named already.
        mutating func add(_ targets: [NavigationTarget]) {
            for target in targets {
                guard seenFragmentsByPath[target.path, default: []].insert(target.fragment).inserted else { continue }
                targetsByPath[target.path, default: []].append(target)
            }
        }

        /// The destinations in the document at `path`, in the order named.
        func targets(in path: String) -> [NavigationTarget] {
            targetsByPath[path] ?? []
        }
    }

    /// One entry of the book's page list (PG05): the page's marker and the
    /// place it names, an archive-relative document and the id of an element
    /// in it (empty for the document's start).
    private struct PageTarget {
        var path: String
        var fragment: String
        var marker: MarkdownPageMarker
        /// The label the entry gave its page, as the list spelled it, before
        /// the marker's normalization took a leading "Page" off it; nil when
        /// the entry gave none (`givenPageLabel`) and the marker has its
        /// ordinal.
        var sourceLabel: String?

        /// Whether the entry gave its page a label, rather than leaving the
        /// marker its ordinal.
        var isLabelled: Bool { sourceLabel != nil }
    }

    /// The page list's entries grouped by the document each names (PG05), and
    /// whether the book has a page list at all, which decides if its
    /// page-break elements are pages.
    private struct PageTargets {
        private var targetsByPath: [String: [PageTarget]]
        let hasPageList: Bool

        /// The page list `targets`, in the publisher's order.
        init(_ targets: [PageTarget]) {
            targetsByPath = Dictionary(grouping: targets, by: \.path)
            hasPageList = !targets.isEmpty
        }

        /// What the converter needs to know of the document at `path`: the
        /// pages named at its elements (the first entry for an id takes it),
        /// with their labels as the list spelled them, and whether its
        /// page-break elements are pages.
        func htmlTargets(in path: String) -> HTMLPageTargets {
            var markers: [String: MarkdownPageMarker] = [:]
            var sourceLabels: [String: String] = [:]
            for target in targetsByPath[path] ?? [] where !target.fragment.isEmpty {
                guard markers[target.fragment] == nil else { continue }
                markers[target.fragment] = target.marker
                sourceLabels[target.fragment] = target.sourceLabel
            }
            return HTMLPageTargets(markers: markers, sourceLabels: sourceLabels, pageBreaksArePages: !hasPageList)
        }

        /// The pages that begin the document at `path` itself, in list order.
        func documentMarkers(in path: String) -> [MarkdownPageMarker] {
            (targetsByPath[path] ?? []).filter { $0.fragment.isEmpty }.map(\.marker)
        }
    }

    /// One spine document as it was read, in spine order. Its DOM is gone:
    /// the document was converted to Markdown from the DOM its contents scan
    /// read, so it was parsed once (PERF19). DOMs stay short lived, so no
    /// SwiftSoup selector caches pile up across a book.
    private struct SpineDocument {
        var path: String
        var title: String
        var number: Int
        /// The Markdown converted while the document was read, with the
        /// destinations named in it by then, or the conversion's error.
        var conversion: Result<String, Error>
        /// How many fragment destinations the conversion knew in it.
        var convertedFragmentCount: Int
    }

    /// What reading one spine document produced: the document, or why it
    /// was left out.
    private enum SpineRead {
        case document(SpineDocument)
        case omitted(ExtractionOmission.Reason)
    }

    /// What a spine item is to a reader, judged by its declared media type.
    private enum SpineItemRole {
        /// An HTML or XML document, read as a chapter.
        case document
        /// A resource the book uses, such as an image or a stylesheet, which
        /// is not a chapter: it is neither counted nor reported.
        case resource
        /// A document of a type that cannot be read as text, such as plain
        /// text or PDF: a chapter that is left out and reported.
        case unsupportedDocument
    }

    /// Recover semantic and TOC headings, then give every retained spine
    /// document a start destination without inserting words into its speech.
    ///
    /// Reading is tolerant, but nothing is left out silently. A spine entry
    /// with no manifest file, a document of a type that cannot be read as
    /// text, a document missing from the archive or unable to be decoded,
    /// and markup that cannot be read are each recorded in the report while
    /// the other chapters are still read. A document that converts to no
    /// text at all, such as a cover page whose image comes from its
    /// stylesheet, is counted as blank and is not a problem. Resources in
    /// the spine, such as images, are not chapters.
    ///
    /// With `includesPages` the book's pages are written as page markers
    /// (PG05): those its page list names, or else its page-break elements,
    /// whose own text is then not read. Without it the chapters are exactly
    /// what cache format 3.0.7 made.
    /// - Throws: `EPUBParserError.noReadableChapters` with the report when
    ///   no chapter holds text, since an empty book is not a reading.
    static func preparedChapters(
        archive: IndexedArchive,
        opfPath: String,
        opfData: OPFData,
        includesPages: Bool
    ) throws -> (chapters: [PreparedChapter], report: ExtractionReport) {
        // Prefer EPUB 3 navigation, then the declared NCX, then visible contents.
        var navigation = NavigationTargets(readNavigation(archive: archive, opfPath: opfPath, opfData: opfData))
        // The page list is read only when pages are wanted.
        let pageTargets = PageTargets(
            includesPages ? readPageList(archive: archive, opfPath: opfPath, opfData: opfData) : []
        )
        var documents: [SpineDocument] = []
        var report = ExtractionReport(container: bookNameInMessages)

        for (index, itemRef) in opfData.spineItemRefs.enumerated() {
            let number = index + 1
            guard let item = opfData.manifest[itemRef] else {
                // The reading order names an item the manifest does not list
                // with a file: a chapter that exists only as a name.
                report.chapterCount += 1
                report.omissions.append(ExtractionOmission(chapterNumber: number, member: itemRef, reason: .unlistedItem))
                continue
            }
            let role = spineRole(ofMediaType: item.mediaType)
            guard role != .resource else { continue }
            report.chapterCount += 1

            let path = ParserUtilities.resolvedPackagePath(item.href, relativeTo: opfPath, preserveFragment: false)
            guard role == .document else {
                let type = item.mediaType.trimmingCharacters(in: .whitespaces)
                report.omissions.append(
                    ExtractionOmission(chapterNumber: number, member: path, reason: .unsupportedMediaType(type))
                )
                continue
            }
            switch readSpineDocument(
                archive: archive, path: path, number: number, navigation: &navigation,
                pages: pageTargets.htmlTargets(in: path), includesPages: includesPages
            ) {
            case .document(let document):
                documents.append(document)
            case .omitted(let reason):
                report.omissions.append(ExtractionOmission(chapterNumber: number, member: path, reason: reason))
            }
        }

        var chapters: [PreparedChapter] = []
        for document in documents {
            do {
                let targets = navigation.targets(in: document.path)
                let markdown = try finishedMarkdown(
                    of: document, targets: targets, archive: archive,
                    pages: pageTargets.htmlTargets(in: document.path), includesPages: includesPages
                )
                guard let chapter = try preparedChapter(
                    from: document, markdown: markdown, targets: targets, bookTitle: opfData.title,
                    startPages: pageTargets.documentMarkers(in: document.path)
                ) else {
                    report.blankChapterCount += 1
                    continue
                }
                chapters.append(chapter)
            } catch {
                report.omissions.append(
                    ExtractionOmission(chapterNumber: document.number, member: document.path, reason: .malformedMarkup)
                )
            }
        }

        // Conversion failures are found after every reading failure, so put
        // the omissions back into reading order.
        report.omissions.sortStably { $0.chapterNumber < $1.chapterNumber }
        guard !chapters.isEmpty else { throw EPUBParserError.noReadableChapters(report) }
        return (chapters, report)
    }

    /// The role of a spine item whose declared media type is `mediaType`.
    /// Media types ignore case, and parameters after ";" (such as a charset)
    /// do not change the role. HTML and XML types are documents, as they
    /// always were; images, sound, video, fonts, stylesheets, and scripts
    /// are resources; anything else is a document that cannot be read.
    private static func spineRole(ofMediaType mediaType: String) -> SpineItemRole {
        let essence = (mediaType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        if essence.contains("html") || essence.contains("xml") { return .document }

        let resourceFamilies = ["image/", "audio/", "video/", "font/", "application/font-", "application/x-font"]
        let resourceTypes: Set<String> = [
            "text/css", "text/javascript", "application/javascript", "application/ecmascript",
            "application/vnd.ms-opentype"
        ]
        if resourceFamilies.contains(where: essence.hasPrefix) || resourceTypes.contains(essence) {
            return .resource
        }
        return .unsupportedDocument
    }

    /// Read the spine document at `path`, the `number`th in reading order,
    /// adding the destinations of any contents section inside it to
    /// `navigation`, and convert it with every destination `navigation`
    /// then names in it; or say why it cannot be read: it is missing from
    /// the archive, its data cannot be decoded, or its markup cannot be
    /// parsed. `pages` names the pages that begin at its elements.
    ///
    /// The conversion reads the DOM the contents scan read, so each document
    /// is parsed once (PERF19); only a contents section later in the reading
    /// order can name a destination in it that the conversion did not know,
    /// and `finishedMarkdown` converts such a document again.
    private static func readSpineDocument(
        archive: IndexedArchive,
        path: String,
        number: Int,
        navigation: inout NavigationTargets,
        pages: HTMLPageTargets,
        includesPages: Bool
    ) -> SpineRead {
        guard let entry = archive.file(at: path) else { return .omitted(.missingMember) }
        guard let html = try? text(of: entry, in: archive.archive) else { return .omitted(.unreadableMember) }
        let readingFlow = PublicationSemantics.ReadingFlow(source: html)
        let doc: Document
        let title: String
        do {
            doc = try MarkupGuard.parse(html)
            title = try doc.title()

            // Some converted EPUBs have an incomplete machine TOC but a full
            // linked contents section in the reading order (including Helliconia).
            // Only explicitly identified TOCs contribute labels, never prose links.
            // A contents section must also be rendered: page lists, landmarks,
            // and hidden subtrees are never searched for one. The scan comes
            // first because conversion removes duplicate navigation.
            let body = doc.body() ?? doc
            navigation.add(
                elements(in: body, pruning: readingFlow.excludes)
                    .filter(isContentsContainer)
                    .flatMap { tocTargets(in: $0, relativeTo: path, readingFlow: readingFlow) }
            )
        } catch {
            return .omitted(.malformedMarkup)
        }
        let targets = navigation.targets(in: path)
        let conversion = Result {
            try HTMLToMarkdownConverter.convert(
                document: doc, readingFlow: readingFlow,
                stripDuplicateNavigation: true, headingTargets: headingTargets(among: targets),
                pages: pages, includesPages: includesPages
            )
        }
        return .document(SpineDocument(
            path: path, title: title, number: number,
            conversion: conversion, convertedFragmentCount: fragmentCount(of: targets)
        ))
    }

    /// The Markdown of `document` converted with all of `targets`, every
    /// destination the book names in it: the conversion made as it was read
    /// when that already knew each fragment destination, or else a new one.
    /// A fragment destination named later only adds to the ones known, so
    /// knowing as many means knowing the same. Should the document fail to
    /// read again, the first conversion stands, without those destinations.
    /// - Throws: the conversion's error, when the markup cannot be converted.
    private static func finishedMarkdown(
        of document: SpineDocument,
        targets: [NavigationTarget],
        archive: IndexedArchive,
        pages: HTMLPageTargets,
        includesPages: Bool
    ) throws -> String {
        guard fragmentCount(of: targets) > document.convertedFragmentCount,
              let entry = archive.file(at: document.path),
              let html = try? text(of: entry, in: archive.archive) else {
            return try document.conversion.get()
        }
        return try HTMLToMarkdownConverter.convert(
            html, stripDuplicateNavigation: true, headingTargets: headingTargets(among: targets),
            pages: pages, includesPages: includesPages
        )
    }

    /// The destinations among `targets` that name a fragment of their
    /// document, keyed by fragment, as conversion looks them up.
    private static func headingTargets(among targets: [NavigationTarget]) -> [String: MarkdownHeadingAnnotation] {
        Dictionary(uniqueKeysWithValues: targets.filter { !$0.fragment.isEmpty }.map { ($0.fragment, $0.heading) })
    }

    /// How many of `targets` name a fragment of their document.
    private static func fragmentCount(of targets: [NavigationTarget]) -> Int {
        targets.reduce(0) { $0 + ($1.fragment.isEmpty ? 0 : 1) }
    }

    /// Make one converted spine document a chapter whose headings keep their
    /// navigation labels and targets, or nil when it holds no text at all.
    /// `markdown` is the document converted with `targets`; `bookTitle` is
    /// the package title, which never names a chapter. `startPages` are the
    /// pages the book's page list begins at the document itself (PG05),
    /// written first in its Markdown; a document that holds no text is blank
    /// whatever page markers it holds, and its pages go with it.
    private static func preparedChapter(
        from document: SpineDocument,
        markdown converted: String,
        targets: [NavigationTarget],
        bookTitle: String,
        startPages: [MarkdownPageMarker]
    ) throws -> PreparedChapter? {
        guard !withoutPageMarkers(converted).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Each start page is a block of its own at the very start, which names
        // the same place as the block after it (MarkdownMarkerWriter).
        var markdown = ""
        for marker in startPages {
            MarkdownMarkerWriter.write(marker.markdown, inline: false, into: &markdown)
        }
        markdown += converted

        let documentTitle = normalizedLabel(document.title)
        let fallbackTitle = targets.first(where: { $0.fragment.isEmpty })?.heading.text
            ?? (!documentTitle.isEmpty && documentTitle != normalizedLabel(bookTitle)
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

    /// Discover the EPUB 3 navigation document via its manifest properties and
    /// the EPUB 2 NCX via the spine's toc attribute. All URLs use their own base.
    /// Only table-of-contents semantics are chapter navigation: the EPUB 3 TOC
    /// nav, the NCX navMap, and the legacy guide's TOC. Page lists (including
    /// the NCX pageList) and landmarks are never read.
    private static func readNavigation(archive: IndexedArchive, opfPath: String, opfData: OPFData) -> [NavigationTarget] {
        var result: [NavigationTarget] = []
        // A guide reference to a navigation document read here would only find
        // the same TOC again, next to that document's page list and landmarks.
        var navigationDocumentPaths: Set<String> = []
        let manifest = opfData.manifest.sortedStably { $0.key < $1.key }
        for (_, item) in manifest where item.properties.split(whereSeparator: \.isWhitespace).contains("nav") {
            let path = ParserUtilities.resolvedPackagePath(item.href, relativeTo: opfPath, preserveFragment: false)
            guard let html = try? extractString(archive: archive, path: path),
                  let doc = try? MarkupGuard.parse(html) else { continue }
            navigationDocumentPaths.insert(path)
            let readingFlow = PublicationSemantics.ReadingFlow(source: html)
            for toc in tableOfContentsNavigations(in: doc) {
                result += tocTargets(in: toc, relativeTo: path, readingFlow: readingFlow)
            }
        }

        result += withNCX(archive: archive, opfPath: opfPath, opfData: opfData) { (path, doc) -> [NavigationTarget] in
            let maps = (try? doc.nodes(forXPath: "//*[local-name()='navMap']")) ?? []
            return maps.flatMap { ncxTargets(in: $0, relativeTo: path, level: 1) }
        } ?? []

        // Legacy guides can refer to a visible TOC that is not itself in the
        // reading order. Honor its fragment so unrelated page links stay out.
        // The EPUB 3 navigation document was already read above.
        for href in opfData.guideTOCHrefs {
            let path = ParserUtilities.resolvedPackagePath(href, relativeTo: opfPath, preserveFragment: false)
            guard !navigationDocumentPaths.contains(path),
                  let html = try? extractString(archive: archive, path: path),
                  let doc = try? MarkupGuard.parse(html) else { continue }
            let fragment = ParserUtilities.splitFragment(href).fragment
            let readingFlow = PublicationSemantics.ReadingFlow(source: html)
            for container in guideTOCContainers(in: doc.body() ?? doc, fragment: fragment, readingFlow: readingFlow) {
                result += tocTargets(in: container, relativeTo: path, readingFlow: readingFlow)
            }
        }
        return result
    }

    /// What `body` makes of the EPUB 2 NCX the package declares through the
    /// spine's `toc` attribute, or else of its first manifest item of an NCX
    /// media type, given its path inside the archive and its document, read
    /// as every XML file of the book is (`readingXML(_:file:_:)`); nil when there
    /// is none or it cannot be read.
    private static func withNCX<Result>(
        archive: IndexedArchive,
        opfPath: String,
        opfData: OPFData,
        _ body: (_ path: String, _ document: XMLDocument) -> Result
    ) -> Result? {
        let ncx = opfData.spineTOCID.flatMap { opfData.manifest[$0] }
            ?? opfData.manifest.sortedStably { $0.key < $1.key }.first(where: { $0.value.mediaType.contains("ncx") })?.value
        guard let ncx else { return nil }
        let path = ParserUtilities.resolvedPackagePath(ncx.href, relativeTo: opfPath, preserveFragment: false)
        guard let xml = try? extractString(archive: archive, path: path) else { return nil }
        return try? readingXML(xml, file: path) { body(path, $0) }
    }

    // MARK: - Page Lists

    /// The book's page list (PG05), in the publisher's order: the EPUB 3
    /// navigation document's `page-list` navigation, else the EPUB 2 NCX's
    /// `pageList`. Empty when the book has none, or when none of its entries
    /// names a place (a web link, or an entry with no `href`).
    ///
    /// A list that labels none of its pages (`givenPageLabel`) names no pages
    /// either: a generator with no page numbers can write a list whose one
    /// entry is the id it links to ("pagenum_000000"), and such a list is
    /// passed over, for the NCX's when the navigation document's is the one,
    /// and else for the book's page-break elements, as in a book with no list.
    private static func readPageList(archive: IndexedArchive, opfPath: String, opfData: OPFData) -> [PageTarget] {
        var targets: [PageTarget] = []
        // The entries read so far, which numbers an entry that has no label.
        var entryCount = 0
        let manifest = opfData.manifest.sortedStably { $0.key < $1.key }
        for (_, item) in manifest where item.properties.split(whereSeparator: \.isWhitespace).contains("nav") {
            let path = ParserUtilities.resolvedPackagePath(item.href, relativeTo: opfPath, preserveFragment: false)
            guard let html = try? extractString(archive: archive, path: path),
                  let doc = try? MarkupGuard.parse(html) else { continue }
            for list in pageListContainers(in: doc) {
                for link in elements(in: list, pruning: { _ in false }) where link.tagName() == "a" {
                    guard link.hasAttr("href") else { continue }
                    entryCount += 1
                    let href = (try? link.attr("href")) ?? ""
                    let text = (try? link.text()) ?? ""
                    if let target = pageTarget(
                        href: href, labels: [text], entryID: link.id(), ordinal: entryCount, relativeTo: path
                    ) {
                        targets.append(target)
                    }
                }
            }
        }
        if targets.contains(where: \.isLabelled) { return targets }

        // No EPUB 3 page list that labels a page: the NCX's pageList, each
        // pageTarget labelled by its navLabel, else its value, and numbered
        // from 1 in list order.
        return withNCX(archive: archive, opfPath: opfPath, opfData: opfData) { (path, doc) -> [PageTarget] in
            let entries = (try? doc.nodes(
                forXPath: "//*[local-name()='pageList']/*[local-name()='pageTarget']"
            )) ?? []
            var listed: [PageTarget] = []
            for (index, entry) in entries.compactMap({ $0 as? XMLElement }).enumerated() {
                let text = (try? entry.nodes(forXPath: "*[local-name()='navLabel']/*[local-name()='text']"))?.first?.stringValue ?? ""
                let value = entry.attribute(forName: "value")?.stringValue ?? ""
                let content = (try? entry.nodes(forXPath: "*[local-name()='content']"))?.first as? XMLElement
                if let href = content?.attribute(forName: "src")?.stringValue,
                   let target = pageTarget(
                       href: href, labels: [text, value], entryID: entry.attribute(forName: "id")?.stringValue ?? "",
                       ordinal: index + 1, relativeTo: path
                   ) {
                    listed.append(target)
                }
            }
            return listed.contains(where: \.isLabelled) ? listed : []
        } ?? []
    }

    /// The page lists inside `node`, outermost only: a navigation typed
    /// `page-list` is collected whole, so a list nested inside another is
    /// not read twice.
    ///
    /// The walk keeps its own stack of the elements still to visit rather
    /// than calling itself for every element: SwiftSoup reads markup nested
    /// thousands deep, and imports run on a worker thread's 512 KiB stack,
    /// which such a call chain overflowed. Children are pushed last first,
    /// so the lists come out in document order.
    private static func pageListContainers(in node: Node) -> [Element] {
        var lists: [Element] = []
        var stack = childElementsLastFirst(of: node)
        while let element = stack.popLast() {
            if PublicationSemantics.isPageList(element) {
                lists.append(element)
            } else {
                stack += childElementsLastFirst(of: element)
            }
        }
        return lists
    }

    /// One page list entry: the place `href` names (resolved as a TOC entry's
    /// is) and a marker labelled by the first of `labels` that labels the
    /// page (`givenPageLabel`), or by the entry's `ordinal`, its 1-based
    /// position in the list, when none does. `entryID` is the id the entry's
    /// own element carries, empty when it has none.
    private static func pageTarget(
        href: String,
        labels: [String],
        entryID: String,
        ordinal: Int,
        relativeTo path: String
    ) -> PageTarget? {
        guard let destination = resolvedDestination(href: href, relativeTo: path) else { return nil }
        let ids = [destination.fragment, entryID].filter { !$0.isEmpty }
        let label = labels.lazy.compactMap { givenPageLabel($0, ids: ids) }.first
        return PageTarget(
            path: destination.path,
            fragment: destination.fragment,
            marker: MarkdownPageMarker(label: label ?? "", ordinal: ordinal),
            sourceLabel: label
        )
    }

    /// The label a page list entry's `text` gives its page (PG05), or nil
    /// when the text labels no page. That is when it is blank or only the
    /// word "Page" (`MarkdownPageMarker.namesNoPage`), or when it is no more
    /// than one of `ids`, the id the entry links to or carries, and no page
    /// number: a generator with no number for a page can write the id in its
    /// place ("pagenum_000000" linking to `#pagenum_000000`). An id that is a
    /// page number itself ("12" linking to `#12`) is the page's label.
    private static func givenPageLabel(_ text: String, ids: [String]) -> String? {
        guard !MarkdownPageMarker.namesNoPage(text) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ids.contains(trimmed), !MarkdownPageMarker.isPageNumber(trimmed) { return nil }
        return text
    }

    /// `markdown` without its page markers, for judging whether a document
    /// holds any text.
    private static func withoutPageMarkers(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "<!-- page: [^<>]+ -->", with: "", options: .regularExpression)
    }

    // MARK: - Tables of Contents

    /// EPUB 3 TOCs are `nav` elements typed `toc` (or given the `doc-toc` role).
    /// They remain navigation data even when hidden from the rendered page
    /// (EPUB 3.3 §7.5), so only page lists and landmarks are pruned here.
    private static func tableOfContentsNavigations(in node: Node) -> [Element] {
        elements(in: node, pruning: PublicationSemantics.isSupplementaryNavigation).filter {
            $0.tagName() == "nav" && PublicationSemantics.isTableOfContents($0)
        }
    }

    /// Choose what a guide TOC reference names: the element its fragment
    /// identifies when that element is rendered; otherwise the document's
    /// semantic TOCs; and only for an older contents page that has neither,
    /// its body. `linkedTargets` still filters whichever container is chosen.
    /// `readingFlow` holds the rules of the document `body` belongs to.
    private static func guideTOCContainers(
        in body: Element,
        fragment: String,
        readingFlow: PublicationSemantics.ReadingFlow
    ) -> [Element] {
        if !fragment.isEmpty,
           let target = elements(in: body, pruning: readingFlow.excludes)
            .first(where: { (try? $0.attr("id")) == fragment }) {
            return [target]
        }
        let tocs = tableOfContentsNavigations(in: body)
        return tocs.isEmpty ? [body] : tocs
    }

    /// Collect one TOC container's destinations. A semantic TOC keeps its hidden
    /// branches: EPUB 3.3 (§7.5, example 54) hides them only from the rendered
    /// content flow, never from navigation interfaces such as the headings list.
    /// `readingFlow` holds the rules of the document `container` belongs to.
    private static func tocTargets(
        in container: Element,
        relativeTo path: String,
        readingFlow: PublicationSemantics.ReadingFlow
    ) -> [NavigationTarget] {
        linkedTargets(
            in: container, relativeTo: path,
            insideTOC: PublicationSemantics.isTableOfContents(container), readingFlow: readingFlow
        )
    }

    /// Traverse NCX children directly so labels stay with their own parent and
    /// nested sections keep their source order instead of being flattened:
    /// the `navPoint`s directly inside `node` are at `level`, and each nested
    /// `navPoint` a level below its parent.
    ///
    /// The walk keeps its own stack of the `navPoint`s still to visit, each
    /// with its level, rather than calling itself for every level: XMLDocument
    /// reads an NCX nested thousands deep, and imports run on a worker
    /// thread's 512 KiB stack, which such a call chain overflowed. Children
    /// are pushed last first, so they are visited in document order.
    private static func ncxTargets(in node: XMLNode, relativeTo path: String, level: Int) -> [NavigationTarget] {
        /// The `navPoint` elements among `parent`'s children, last first,
        /// each with `level`, the level they are at.
        func pending(under parent: XMLNode, level: Int) -> [(navPoint: XMLElement, level: Int)] {
            (parent.children ?? []).reversed().compactMap { child in
                guard let element = child as? XMLElement, element.localName == "navPoint" else { return nil }
                return (element, level)
            }
        }
        var result: [NavigationTarget] = []
        var stack = pending(under: node, level: level)
        while let (navPoint, navPointLevel) = stack.popLast() {
            let label = (try? navPoint.nodes(forXPath: "*[local-name()='navLabel']/*[local-name()='text']"))?.first?.stringValue ?? ""
            let content = (try? navPoint.nodes(forXPath: "*[local-name()='content']"))?.first as? XMLElement
            if let href = content?.attribute(forName: "src")?.stringValue,
               let target = navigationTarget(href: href, label: label, level: navPointLevel, relativeTo: path) {
                result.append(target)
            }
            stack += pending(under: navPoint, level: navPointLevel + 1)
        }
        return result
    }

    /// Follow a TOC's linked labels in DOM order, retaining nested list levels.
    /// Page lists and landmarks are never entered. Hidden subtrees are skipped
    /// unless they belong to a semantic TOC (see `tocTargets`).
    ///
    /// The walk keeps its own stack of the elements still to visit, each with
    /// the list level and TOC membership its parent passes down, rather than
    /// calling itself for every element: SwiftSoup reads markup nested
    /// thousands deep, and imports run on a worker thread's 512 KiB stack,
    /// which such a call chain overflowed. Children are pushed last first, so
    /// they are visited in document order.
    private static func linkedTargets(
        in node: Node,
        relativeTo path: String,
        level: Int = 0,
        insideTOC: Bool,
        readingFlow: PublicationSemantics.ReadingFlow
    ) -> [NavigationTarget] {
        /// The elements among `parent`'s children, last first, each with the
        /// list level and TOC membership `parent` passes down.
        func pending(under parent: Node, level: Int, insideTOC: Bool) -> [(element: Element, level: Int, insideTOC: Bool)] {
            childElementsLastFirst(of: parent).map { ($0, level, insideTOC) }
        }
        var result: [NavigationTarget] = []
        var stack = pending(under: node, level: level, insideTOC: insideTOC)
        while let (element, listLevel, parentInsideTOC) = stack.popLast() {
            let withinTOC = parentInsideTOC || PublicationSemantics.isTableOfContents(element)
            // A skipped element is skipped together with everything inside it.
            guard !PublicationSemantics.isSupplementaryNavigation(element),
                  withinTOC || !readingFlow.isHidden(element) else { continue }
            let tag = element.tagName()
            if tag == "a", let href = try? element.attr("href"),
               let label = try? element.text(),
               let target = navigationTarget(href: href, label: label, level: max(1, listLevel), relativeTo: path) {
                result.append(target)
            }
            stack += pending(
                under: element,
                level: listLevel + (tag == "ol" || tag == "ul" ? 1 : 0),
                insideTOC: withinTOC
            )
        }
        return result
    }

    /// Resolve one local URL while excluding web/mail links and keeping encoded
    /// filename delimiters distinct from the URL's query and fragment syntax.
    private static func navigationTarget(href: String, label: String, level: Int, relativeTo path: String) -> NavigationTarget? {
        let label = normalizedLabel(label)
        guard !label.isEmpty, let destination = resolvedDestination(href: href, relativeTo: path) else { return nil }
        return NavigationTarget(
            path: destination.path,
            fragment: destination.fragment,
            heading: MarkdownHeadingAnnotation(level: min(6, max(1, level)), text: label)
        )
    }

    /// The archive path and fragment (percent-decoded) a local `href` names,
    /// relative to the document at `path`; nil for an empty `href` or a web or
    /// mail link. Shared by TOC entries and page list entries (PG05).
    private static func resolvedDestination(href: String, relativeTo path: String) -> (path: String, fragment: String)? {
        let href = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !href.isEmpty, !href.hasPrefix("//"), URLComponents(string: href)?.scheme == nil else { return nil }
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let file = String(parts[0]).components(separatedBy: "?")[0]
        let fragment = parts.count > 1 ? String(parts[1]) : ""
        return (
            file.isEmpty ? path : ParserUtilities.resolvedPackagePath(file, relativeTo: path, preserveFragment: false),
            fragment.removingPercentEncoding ?? fragment
        )
    }

    /// Recognize semantic TOCs and conventional converted-book containers,
    /// without treating arbitrary lists or links in the prose as navigation.
    /// A page list or landmarks nav is never a contents section, whatever its id.
    private static func isContentsContainer(_ element: Element) -> Bool {
        guard PublicationSemantics.isNavigationContainer(element),
              !PublicationSemantics.isSupplementaryNavigation(element) else { return false }
        if PublicationSemantics.isTableOfContents(element) { return true }
        let id = ((try? element.attr("id")) ?? "").lowercased()
        return ["toc", "contents", "table-of-contents"].contains(id) || id.hasSuffix("-toc")
    }

    /// The elements among `node`'s children, last first: pushed onto a
    /// walk's stack of the elements still to visit, they are visited in
    /// document order.
    private static func childElementsLastFirst(of node: Node) -> [Element] {
        node.getChildNodes().reversed().compactMap { $0 as? Element }
    }

    /// Walk without selector caches, releasing each temporary document after
    /// its metadata is collected. Reversing children preserves source order.
    /// A pruned element is skipped together with everything inside it.
    private static func elements(in node: Node, pruning isPruned: (Element) -> Bool) -> [Element] {
        var pending: [Node] = [node]
        var result: [Element] = []
        while let current = pending.popLast() {
            if let element = current as? Element {
                guard !isPruned(element) else { continue }
                result.append(element)
            }
            pending.append(contentsOf: current.getChildNodes().reversed())
        }
        return result
    }

    /// Navigation labels are single lines even when their source is formatted.
    private static func normalizedLabel(_ label: String) -> String {
        label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
