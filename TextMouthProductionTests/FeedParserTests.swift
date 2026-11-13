import XCTest
@testable import TextMouth

/// Reading feeds (FR03): RSS 2.0, RSS 1.0, and Atom, with Apple's iTunes and
/// Podcasting 2.0 elements under any prefix, and JSON Feed; every fault the research found
/// in real feeds, read through the tidy fallback; dates and durations in
/// the forms seen in the wild; the feeds a web page names; and how a feed's
/// text is read. The fixtures are in TestData/feeds: LibriVox's feed as it
/// is, four real feeds trimmed with their text replaced, and hand-made
/// broken ones.
final class FeedParserTests: XCTestCase {

    // MARK: - Real Feeds

    /// LibriVox's feed, a serial audiobook: 57 chapters with no guid and no
    /// date, so each is known by its enclosure; durations wrapped in CDATA
    /// and whitespace; a length of 0, which counts as none; episode numbers.
    func testLibriVoxSerialFeed() throws {
        let feed = try Self.parse("librivox.xml", from: "https://librivox.org/rss/52")

        XCTAssertEqual(feed.format, .rss)
        XCTAssertNil(feed.repair)
        XCTAssertEqual(feed.title, "Letters of Two Brides by Honoré de Balzac (1799 - 1850)")
        XCTAssertEqual(feed.author, "LibriVox")
        XCTAssertTrue(feed.isSerial)
        XCTAssertEqual(feed.siteLink?.absoluteString, "https://librivox.org/letters-of-two-brides-by-honore-de-balzac/")
        XCTAssertEqual(feed.items.count, 57)
        let first = try XCTUnwrap(feed.items.first)
        XCTAssertEqual(first.title, "Letter 1")
        XCTAssertNil(first.guid)
        XCTAssertNil(first.published)
        XCTAssertEqual(first.duration, 29 * 60 + 24)
        XCTAssertEqual(first.episodeNumber, 1)
        XCTAssertEqual(first.enclosure?.mimeType, "audio/mpeg")
        XCTAssertNil(first.enclosure?.length, "a length of 0 counts as none")
        XCTAssertEqual(
            first.identity,
            "enclosure:https://www.archive.org/download/letters_brides_0709_librivox/letters_of_two_brides_01_debalzac_64kb.mp3"
        )
        XCTAssertEqual(Set(feed.items.map(\.identity)).count, 57, "every chapter is an item of its own")
        XCTAssertEqual(feed.items.last?.episodeNumber, 57)
        XCTAssertEqual(feed.items.map(\.position), Array(0..<57))
    }

    /// An Anchor podcast: HTML descriptions in CDATA, durations as
    /// "00:20:03", guids, an enclosure whose address carries another
    /// address, and `itunes:summary` left aside for the description.
    func testAnchorEpisodicFeed() throws {
        let feed = try Self.parse("anchor-episodic.xml")

        XCTAssertNil(feed.repair)
        XCTAssertEqual(feed.title, "Dots and Dashes: Braille at the Kitchen Table")
        XCTAssertEqual(feed.author, "Small Hours Audio")
        XCTAssertFalse(feed.isSerial)
        XCTAssertEqual(feed.items.count, 3)
        let first = try XCTUnwrap(feed.items.first)
        XCTAssertEqual(first.title, "Tactile graphics on a budget")
        XCTAssertEqual(first.guid, "80744121-c93d-4b74-ba0c-8edccb381992")
        XCTAssertEqual(first.identity, "guid:80744121-c93d-4b74-ba0c-8edccb381992")
        XCTAssertEqual(first.duration, 20 * 60 + 3)
        XCTAssertEqual(first.published, try Self.date("2026-09-26T19:19:33Z"))
        XCTAssertEqual(first.enclosure?.kind, .audio)
        XCTAssertEqual(first.enclosure?.length, 19_465_239)
        XCTAssertTrue(first.enclosure?.url.absoluteString.hasSuffix("a1da4dd136925.m4a") ?? false)
        XCTAssertEqual(first.author, "Small Hours Audio")
        XCTAssertEqual(first.link?.absoluteString, "https://podcasts.example/dots-and-dashes/episodes/tactile-graphics-on-a-budget")
        XCTAssertTrue(first.summary?.text.hasPrefix("<p>Swell paper") ?? false)
        XCTAssertNil(first.content)
    }

    /// An NPR-shaped podcast: durations in seconds, content:encoded that
    /// repeats the description (dropped) or adds to it (kept), the channel's
    /// title rather than its image's, and an enclosure address whose query
    /// held escaped ampersands.
    func testNPREpisodicFeed() throws {
        let feed = try Self.parse("npr-episodic.xml")

        XCTAssertEqual(feed.title, "Ledger Lines")
        XCTAssertEqual(feed.siteLink?.absoluteString, "https://radio.example/podcasts/ledger-lines")
        XCTAssertEqual(feed.author, "Example Public Radio")
        XCTAssertEqual(feed.items.count, 3)
        let first = try XCTUnwrap(feed.items[safe: 0])
        let second = try XCTUnwrap(feed.items[safe: 1])
        XCTAssertEqual(first.duration, 1_780)
        XCTAssertNil(first.content, "content that repeats the description is dropped")
        XCTAssertNotNil(second.content, "content that adds to the description is kept")
        let enclosure = try XCTUnwrap(first.enclosure?.url.absoluteString)
        XCTAssertTrue(enclosure.contains("default.mp3?awCollectionId="))
        XCTAssertTrue(enclosure.contains("&t=podcast&"))
        XCTAssertEqual(first.enclosure?.url.pathExtension, "mp3")
    }

    /// WordPress News: articles with no enclosure, a summary, the whole
    /// article in content:encoded, and a guid that is an address but not a
    /// permalink.
    func testWordPressArticleFeed() throws {
        let feed = try Self.parse("wordpress-articles.xml")

        XCTAssertEqual(feed.title, "Corkboard Project News")
        XCTAssertEqual(feed.items.count, 2)
        let article = try XCTUnwrap(feed.items.first)
        XCTAssertNil(article.enclosure)
        XCTAssertEqual(article.author, "Odile Varga")
        XCTAssertEqual(article.guid, "https://news.corkboard.example/?p=21731")
        XCTAssertEqual(article.link?.absoluteString, "https://news.corkboard.example/2026/09/corkboard-7-1-2-security-release/")
        XCTAssertTrue(article.content?.text.contains("<h2 class=\"wp-block-heading\">What changed</h2>") ?? false)
        XCTAssertTrue(article.summary?.text.contains("[&#8230;]") ?? false)
    }

    /// swift.org's Atom feed: entries with several authors, an id for a
    /// guid, an unmarked link for the page, escaped HTML content, the date
    /// from `updated` when there is no `published`, and an empty alternate
    /// link at the feed's level, which names no site.
    func testAtomBlogFeed() throws {
        let feed = try Self.parse("swiftorg-atom.xml", from: "https://quill-lang.example/atom.xml")

        XCTAssertEqual(feed.format, .atom)
        XCTAssertEqual(feed.title, "Quill Language Blog")
        XCTAssertNil(feed.siteLink)
        XCTAssertEqual(feed.items.count, 2)
        let post = try XCTUnwrap(feed.items.first)
        XCTAssertEqual(post.title, "Quill 6.4 Released")
        XCTAssertEqual(post.author, "Tunde Bakare, Pilar Ezquerra")
        XCTAssertEqual(post.guid, "https://quill-lang.example/blog/quill-6.4-released/")
        XCTAssertEqual(post.link?.absoluteString, "https://quill-lang.example/blog/quill-6.4-released/")
        XCTAssertEqual(post.published, try Self.date("2026-09-15T07:30:00Z"))
        XCTAssertEqual(post.content?.kind, .html)
        XCTAssertTrue(post.content?.text.contains("<a href=\"/install/\">Install Quill</a>") ?? false)
    }

    // MARK: - Other Shapes

    /// An Atom podcast: an html title holding an escaped ampersand, a plain
    /// subtitle, enclosure links (audio is taken ahead of video, which is
    /// taken when it is all there is), a relative page address, xhtml
    /// content written back as markup with its text escaped, an xhtml title
    /// read as plain text, and the published date ahead of the updated one.
    func testAtomPodcastFeed() throws {
        let feed = try Self.parse("atom-podcast.xml", from: "https://atom.example/feed.atom")

        XCTAssertEqual(feed.title, "Field & Fork")
        XCTAssertEqual(feed.summary, FeedTextSource(text: "Recipes read aloud, one ingredient at a time.", kind: .plain))
        XCTAssertEqual(feed.siteLink?.absoluteString, "https://atom.example/")
        XCTAssertEqual(feed.author, "Dev Raghunathan")
        XCTAssertEqual(feed.items.count, 2)

        let bread = try XCTUnwrap(feed.items[safe: 0])
        XCTAssertEqual(bread.title, "Bread <without> yeast")
        XCTAssertEqual(bread.link?.absoluteString, "https://atom.example/episodes/bread")
        XCTAssertEqual(bread.enclosure?.url.absoluteString, "https://media.example/bread.mp3")
        XCTAssertEqual(bread.enclosure?.kind, .audio)
        XCTAssertEqual(bread.published, try Self.date("2026-10-02T11:30:00Z"))
        XCTAssertEqual(bread.duration, 842)
        XCTAssertEqual(bread.summary?.kind, .plain)
        let content = try XCTUnwrap(bread.content)
        XCTAssertEqual(content.kind, .html)
        XCTAssertTrue(content.text.contains("<p>Mix the <em>flour</em> &amp; soda.</p>"), content.text)
        XCTAssertTrue(content.text.contains("Bake at 200 &lt;degrees&gt;."), content.text)

        let soup = try XCTUnwrap(feed.items[safe: 1])
        XCTAssertEqual(soup.title, "Soup for one")
        XCTAssertEqual(soup.enclosure?.kind, .video)
        XCTAssertEqual(soup.published, try Self.date("2026-09-28T07:30:00Z"))
    }

    /// RSS 1.0: items beside the channel in an RDF document, Dublin Core
    /// dates and creators, and descriptions of escaped markup or plain text.
    func testRSS1Feed() throws {
        let feed = try Self.parse("rss1-rdf.xml")

        XCTAssertEqual(feed.format, .rdf)
        XCTAssertEqual(feed.title, "Slow News, RSS 1.0")
        XCTAssertEqual(feed.items.map(\.title), ["First note", "Second note"])
        let first = try XCTUnwrap(feed.items[safe: 0])
        XCTAssertEqual(first.published, try Self.date("2026-10-01T09:00:00Z"))
        XCTAssertEqual(first.author, "Margit Huhta")
        XCTAssertEqual(first.summary?.text, "<p>Escaped <b>markup</b>.</p>")
        XCTAssertEqual(first.identity, "link:https://rdf.example/a\u{1F}First note")
    }

    /// Every namespace under a prefix of its own, Apple's in another letter
    /// case: each element is still found, with Podcasting 2.0's transcript
    /// and chapters, `itunes:new-feed-url`, and the serial type.
    func testElementsAreFoundUnderAnyPrefix() throws {
        let feed = try Self.parse("prefixes-unusual.xml")

        XCTAssertNil(feed.repair)
        XCTAssertEqual(feed.author, "Lucinda Ferraro")
        XCTAssertTrue(feed.isSerial)
        XCTAssertEqual(feed.newFeedURL?.absoluteString, "https://moved.example/odd-prefixes.xml")
        let item = try XCTUnwrap(feed.items.first)
        XCTAssertEqual(item.duration, 12 * 60 + 34)
        XCTAssertEqual(item.episodeNumber, 1)
        XCTAssertEqual(item.author, "Lucinda Ferraro")
        XCTAssertEqual(item.published, try Self.date("2026-09-30T06:15:00Z"))
        XCTAssertEqual(item.content?.text, "<p>Longer, with <em>emphasis</em>.</p>")
        XCTAssertEqual(item.transcripts.map(\.url.absoluteString), ["https://cdn.example/odd/1.vtt"])
        XCTAssertEqual(item.transcripts.first?.mimeType, "text/vtt")
        XCTAssertEqual(item.chapters?.url.absoluteString, "https://cdn.example/odd/1-chapters.json")
    }

    /// A feed that uses Apple's prefix without declaring it is read as if it
    /// had declared it.
    func testUndeclaredConventionalPrefixesAreRead() throws {
        let feed = try Self.parse("prefixes-undeclared.xml")

        XCTAssertEqual(feed.author, "Henrik Solvang")
        XCTAssertEqual(feed.items.first?.duration, 20 * 60 + 3)
        XCTAssertEqual(feed.items.first?.guid, "undeclared-1")
    }

    /// A video podcast's video enclosure plays; an item with no file is an
    /// article; an item offering a PDF is too, though it keeps the enclosure.
    func testVideoAndArticleItems() throws {
        let feed = try Self.parse("video-podcast.xml")

        XCTAssertEqual(feed.items.map { $0.enclosure?.kind }, [.video, nil, .other])
        XCTAssertTrue(FeedTransport.isInsecure(try XCTUnwrap(feed.items[safe: 0]?.enclosure?.url)))
    }

    // MARK: - Faults

    /// Each fault the research found stops the strict reading and is read by
    /// the tidy fallback, which records what it repaired: the items read, and
    /// their text, are what the feed meant.
    func testEveryFaultIsReadThroughTheTidyFallback() throws {
        let faults: [(file: String, firstTitle: String)] = [
            ("fault-html-entity.xml", "One two"),
            ("fault-bare-ampersand.xml", "Q&A night"),
            ("fault-blank-line-before-declaration.xml", "A plain title"),
            ("fault-control-character.xml", "A plain title"),
            ("fault-latin1-in-utf8.xml", "A plain title"),
        ]
        for fault in faults {
            let feed = try Self.parse(fault.file)
            XCTAssertNotNil(feed.repair, "\(fault.file) was not repaired")
            XCTAssertEqual(feed.items.count, 3, fault.file)
            XCTAssertEqual(feed.items.first?.title, fault.firstTitle, fault.file)
            XCTAssertEqual(feed.items.first?.duration, 3_723, fault.file)
            XCTAssertEqual(feed.items.map(\.guid), ["ep-1", "ep-2", "ep-3"], fault.file)
            XCTAssertEqual(feed.title, "Fault Lines", fault.file)
        }
        let latin1 = try Self.parse("fault-latin1-in-utf8.xml")
        XCTAssertTrue(latin1.items[safe: 0]?.summary?.text.hasPrefix("Caf") ?? false)
        let control = try Self.parse("fault-control-character.xml")
        XCTAssertTrue(control.items[safe: 0]?.summary?.text.hasPrefix("bad") ?? false)
    }

    /// A feed cut short keeps the items it holds whole, and the repair says
    /// how many the strict reading had read before the fault.
    func testATruncatedFeedKeepsItsCompleteItems() throws {
        let feed = try Self.parse("fault-truncated.xml")

        let repair = try XCTUnwrap(feed.repair)
        XCTAssertEqual(repair.itemsBeforeFault, 2)
        XCTAssertGreaterThan(repair.line, 0)
        XCTAssertEqual(Array(feed.items.prefix(2).map(\.guid)), ["ep-1", "ep-2"])
        XCTAssertEqual(feed.items[safe: 1]?.enclosure?.url.absoluteString, "https://cdn.example/2.mp3")
    }

    /// A DOCTYPE naming a file on this Mac as an entity never brings the
    /// file into the feed, however the feed is read.
    func testAnExternalEntityIsNeverLoaded() throws {
        let feed = try Self.parse("fault-external-entity.xml")
        let summary = feed.items.first?.summary?.text ?? ""

        XCTAssertFalse(summary.contains("localhost"), summary)
        XCTAssertFalse(summary.contains("broadcasthost"), summary)
        XCTAssertEqual(feed.items.count, 3)
    }

    /// The old Netscape DOCTYPE, a byte order mark, and feeds declared in
    /// Latin-1 or windows-1252 are read as they are meant, without repair.
    func testDeclaredEncodingsAndDoctypesAreRead() throws {
        let netscape = try Self.parse("fault-netscape-doctype.xml")
        XCTAssertEqual(netscape.items.count, 3)
        XCTAssertFalse(netscape.items[safe: 0]?.summary?.text.contains("&nbsp;") ?? true)

        let bom = try Self.parse("encoding-utf8-bom.xml")
        XCTAssertNil(bom.repair)
        XCTAssertEqual(bom.items.first?.title, "Café with a byte order mark")

        let latin1 = try Self.parse("encoding-iso-8859-1.xml")
        XCTAssertNil(latin1.repair)
        XCTAssertEqual(latin1.items.first?.summary?.text, "Café au lait")

        let windows = try Self.parse("encoding-windows-1252.xml")
        XCTAssertNil(windows.repair)
        XCTAssertEqual(windows.items.first?.summary?.text, "\u{201C}quoted\u{201D} \u{2014} dashes")
    }

    /// An empty document, one larger than TextMouth reads, a web page, and
    /// a JSON document that is no JSON Feed, such as an API's error, are
    /// each refused for what they are.
    func testDocumentsThatAreNoFeedAreRefused() throws {
        XCTAssertThrowsError(try Self.parse("fault-empty.xml")) { error in
            XCTAssertEqual(error as? FeedParseError, .empty)
        }
        XCTAssertThrowsError(try FeedParser.parse(Data("  \n\t ".utf8), baseURL: nil)) { error in
            XCTAssertEqual(error as? FeedParseError, .empty)
        }
        XCTAssertThrowsError(try FeedParser.parse(Data(count: FeedParser.maximumBytes + 1), baseURL: nil)) { error in
            XCTAssertEqual(error as? FeedParseError, .tooLarge)
        }
        XCTAssertThrowsError(try Self.parse("page-with-feeds.html")) { error in
            XCTAssertEqual(error as? FeedParseError, .notAFeed)
        }
        XCTAssertThrowsError(try Self.parse("not-a-feed.json")) { error in
            XCTAssertEqual(error as? FeedParseError, .notAFeed)
        }
    }

    /// A feed listing more items than the limit gives the first ones, and
    /// says it stopped; the limit is 2,000.
    func testItemsPastTheLimitAreLeftOut() throws {
        let items = (1...7).map { "<item><title>Item \($0)</title><guid>g\($0)</guid></item>" }.joined()
        let markup = "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>Many</title>\(items)</channel></rss>"

        let feed = try FeedParser.parse(Data(markup.utf8), baseURL: nil, maximumItems: 5)

        XCTAssertEqual(feed.items.map(\.title), ["Item 1", "Item 2", "Item 3", "Item 4", "Item 5"])
        XCTAssertTrue(feed.reachedItemLimit)
        XCTAssertNil(feed.repair)
        XCTAssertEqual(FeedParser.maximumItems, 2_000)
        XCTAssertEqual(FeedParser.maximumBytes, 25 * 1_024 * 1_024)
    }

    /// An enclosure at an address other than http or https, such as a file
    /// on this Mac, is never taken; an item with nothing at all is skipped,
    /// and one with only a description takes its title from it.
    func testOnlyWebEnclosuresAndListableItemsAreRead() throws {
        let markup = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>Odd</title>
        <item><title>Local</title><guid>local</guid><enclosure url="file:///etc/hosts" type="audio/mpeg" length="5"/></item>
        <item></item>
        <item><description>&lt;p&gt;Only a description, which names the item when the title is missing.&lt;/p&gt;</description></item>
        </channel></rss>
        """
        let feed = try FeedParser.parse(Data(markup.utf8), baseURL: nil)

        XCTAssertEqual(feed.items.count, 2)
        let local = try XCTUnwrap(feed.items[safe: 0])
        let described = try XCTUnwrap(feed.items[safe: 1])
        XCTAssertNil(local.enclosure)
        XCTAssertEqual(described.title, "Only a description, which names the item when the title is missing.")
        XCTAssertTrue(described.identity.hasPrefix("link:"))
    }

    // MARK: - JSON Feed

    /// A JSON Feed 1.1 podcast: the feed's own fields; each item's id, page,
    /// title, summary, and content (kept beside a summary it adds to); a
    /// date with an offset, or the date modified when none was published;
    /// its authors; its attachments as enclosures, audio chosen over a
    /// video listed first, with sizes (one written as a string still
    /// counts, 0 counts as none) and durations; an attachment that is no web
    /// address never taken; and a numeric id, as JSON Feed 1.0 allowed,
    /// read as its digits.
    func testJSONFeedPodcast() throws {
        let feed = try Self.parse("jsonfeed-podcast.json", from: "https://shows.example/kitchen-table-braille/feed.json")

        XCTAssertEqual(feed.format, .json)
        XCTAssertNil(feed.repair)
        XCTAssertFalse(feed.reachedItemLimit)
        XCTAssertEqual(feed.title, "Kitchen Table Braille")
        XCTAssertEqual(feed.siteLink?.absoluteString, "https://shows.example/kitchen-table-braille/")
        XCTAssertEqual(feed.summary, FeedTextSource(text: "Short episodes about reading braille at home.", kind: .plain))
        XCTAssertEqual(feed.author, "Small Hours Audio")
        XCTAssertFalse(feed.isSerial)
        XCTAssertNil(feed.newFeedURL, "a JSON feed's own feed_url is no move")
        XCTAssertEqual(feed.items.map(\.position), [0, 1, 2])

        let first = try XCTUnwrap(feed.items[safe: 0])
        XCTAssertEqual(first.guid, "kitchen-table-3")
        XCTAssertEqual(first.identity, "guid:kitchen-table-3")
        XCTAssertEqual(first.title, "Labelling the spice rack")
        XCTAssertEqual(first.link?.absoluteString, "https://shows.example/kitchen-table-braille/3")
        XCTAssertEqual(first.summary, FeedTextSource(text: "Dymo tape, clear dots, and which jars to label first.", kind: .plain))
        XCTAssertEqual(first.content?.kind, .html)
        XCTAssertTrue(first.content?.text.contains("<em>contracted</em>") ?? false)
        XCTAssertEqual(first.published, try Self.date("2026-09-30T12:00:00Z"))
        XCTAssertEqual(first.author, "Ines Okafor, Dov Halloran")
        XCTAssertEqual(first.enclosure, FeedEnclosure(
            url: try XCTUnwrap(URL(string: "https://media.example/ktb/3.m4a")),
            mimeType: "audio/x-m4a",
            length: 19_465_239
        ))
        XCTAssertEqual(first.duration, 1_203)

        let second = try XCTUnwrap(feed.items[safe: 1])
        XCTAssertNil(second.summary)
        XCTAssertEqual(second.content, FeedTextSource(
            text: "Thermoform or paper?\n\nWe compare both after a month in a busy kitchen.",
            kind: .plain
        ))
        XCTAssertEqual(second.enclosure?.length, 12_000_000)
        XCTAssertEqual(second.duration, 905.5)
        XCTAssertNil(second.author)

        let third = try XCTUnwrap(feed.items[safe: 2])
        XCTAssertEqual(third.guid, "1")
        XCTAssertEqual(third.published, try Self.date("2026-09-16T08:00:00Z"))
        XCTAssertEqual(third.enclosure?.url.absoluteString, "https://media.example/ktb/1.mp3")
        XCTAssertNil(third.enclosure?.length, "a size of 0 counts as none")
        XCTAssertNil(third.duration)
    }

    /// A JSON Feed 1.0 of articles: its single author; an item without a
    /// title, listed by the start of its text; an item whose page is
    /// another site's (external_url); and entries that are no item skipped.
    func testJSONFeedArticles() throws {
        let feed = try Self.parse("jsonfeed-articles.json", from: "https://quill-lang.example/feed.json")

        XCTAssertEqual(feed.format, .json)
        XCTAssertEqual(feed.title, "Quill Notes")
        XCTAssertEqual(feed.author, "The Quill Team")
        XCTAssertEqual(feed.items.count, 2)
        let note = try XCTUnwrap(feed.items[safe: 0])
        XCTAssertEqual(note.title, "Quill 3.2 reads .qnb notebooks aloud, cell by cell, and says which cell failed.")
        XCTAssertEqual(note.guid, "https://quill-lang.example/notes/2026/10/02/")
        XCTAssertEqual(note.link?.absoluteString, "https://quill-lang.example/notes/2026/10/02/")
        XCTAssertEqual(note.published, try Self.date("2026-10-02T10:30:00Z"))
        XCTAssertNil(note.enclosure)
        let review = try XCTUnwrap(feed.items[safe: 1])
        XCTAssertEqual(review.title, "A review worth reading")
        XCTAssertEqual(review.link?.absoluteString, "https://other.example/review-of-quill")
        XCTAssertEqual(review.content?.kind, .plain)
    }

    /// JSON that is no JSON Feed is refused: without a version, with
    /// another's version address, or cut short. A byte order mark before a
    /// feed is read past, and items past the limit are left out.
    func testJSONThatIsNoJSONFeedIsRefused() throws {
        let refused = [
            #"{"title": "No version", "items": []}"#,
            #"{"version": "https://feeds.example/version/1", "items": []}"#,
            #"{"version": "https://jsonfeed.org/version/1.1", "title": "Cut"#,
        ]
        for json in refused {
            XCTAssertThrowsError(try FeedParser.parse(Data(json.utf8), baseURL: nil), json) { error in
                XCTAssertEqual(error as? FeedParseError, .notAFeed, json)
            }
        }

        let items = (1...4).map { #"{"id": "n\#($0)", "title": "Note \#($0)"}"# }.joined(separator: ",")
        let document = #"{"version": "https://jsonfeed.org/version/1.1", "title": "Notes", "items": [\#(items)]}"#
        let marked = Data([0xEF, 0xBB, 0xBF]) + Data(("\n " + document).utf8)
        let feed = try FeedParser.parse(marked, baseURL: nil, maximumItems: 3)
        XCTAssertEqual(feed.items.map(\.title), ["Note 1", "Note 2", "Note 3"])
        XCTAssertTrue(feed.reachedItemLimit)
    }

    /// A page naming a JSON Feed (application/feed+json) offers it; a link
    /// to plain JSON, such as WordPress's REST API, is no feed.
    func testAPageNamingAJSONFeedOffersIt() throws {
        let page = """
        <html><head>
        <link rel="alternate" type="application/json" href="/wp-json/wp/v2/pages/12">
        <link rel="alternate" type="application/feed+json" title="Notes as JSON" href="/feed.json">
        </head><body></body></html>
        """
        let links = FeedDiscovery.feedLinks(inPage: page, pageURL: try XCTUnwrap(URL(string: "https://quill-lang.example/")))

        XCTAssertEqual(links, [FeedLink(
            url: try XCTUnwrap(URL(string: "https://quill-lang.example/feed.json")),
            title: "Notes as JSON",
            mimeType: "application/feed+json"
        )])
    }

    // MARK: - Dates and Durations

    /// RFC 822 dates in every variant the research met, RFC 3339 dates read
    /// leniently, and forms that name no date.
    func testDatesInTheFormsFeedsWrite() throws {
        let expected = try Self.date("2002-10-02T13:00:00Z")
        let sameMoment = [
            "Wed, 02 Oct 2002 13:00:00 GMT", "Wed, 02 Oct 2002 15:00:00 +0200", "Wed, 02 Oct 2002 08:00:00 EST",
            "Wed, 02 Oct 2002 06:00:00 PDT", "Sun, 02 Oct 2002 13:00:00 GMT", "02 Oct 2002 13:00:00 GMT",
            "Wed, 02 Oct 02 13:00:00 GMT", "Wed, 02 Oct 2002 13:00:00 UT", "Wed, 02 Oct 2002 13:00:00 Z",
            "Wed, 02 Oct 2002 13:00:00", "Wednesday, 2 October 2002 13:00:00 +00:00", "wed, 02 oct 2002 13:00:00 gmt",
            "Wed,02 Oct 2002 13:00:00 GMT", "Wed, 02 Oct 2002 13:00:00 +0000 (UTC)", "2002-10-02T13:00:00Z",
            "2002-10-02T15:00:00+02:00", "2002-10-02T13:00:00", "2002-10-02 13:00:00 +0000", "2002-10-02T08:00:00-0500",
        ]
        for text in sameMoment {
            XCTAssertEqual(FeedDates.date(from: text), expected, text)
        }
        XCTAssertEqual(FeedDates.date(from: "Wed, 02 Oct 2002 13:00 GMT"), expected)
        XCTAssertEqual(FeedDates.date(from: "02 Sept 2002 13:00:00 GMT"), try Self.date("2002-09-02T13:00:00Z"))
        XCTAssertEqual(FeedDates.date(from: "Thu, 01 Jan 70 00:00:00 GMT"), Date(timeIntervalSince1970: 0))
        XCTAssertEqual(
            FeedDates.date(from: "2003-12-13T18:30:02.25Z")?.timeIntervalSince1970 ?? 0,
            try Self.date("2003-12-13T18:30:02Z").timeIntervalSince1970 + 0.25,
            accuracy: 0.0001
        )
        XCTAssertEqual(FeedDates.date(from: "2026-10-01"), try Self.date("2026-10-01T00:00:00Z"))
        for nonsense in ["", "Mittwoch, 02 Okt 2002 13:00:00 GMT", "31 Feb 2026 10:00:00 GMT", "2026-13-01",
                         "02 Oct 202 13:00:00 GMT", "Wed, 02 Oct 2002 25:00:00 GMT", "yesterday", "2026-10-01T10:00:00+99:00"] {
            XCTAssertNil(FeedDates.date(from: nonsense), nonsense)
        }
    }

    /// Durations as hours, minutes, and seconds, or as seconds alone.
    func testDurationsInTheFormsFeedsWrite() {
        XCTAssertEqual(FeedDates.duration(from: "1:02:03"), 3_723)
        XCTAssertEqual(FeedDates.duration(from: " 00:20:03\n"), 1_203)
        XCTAssertEqual(FeedDates.duration(from: "12:34"), 754)
        XCTAssertEqual(FeedDates.duration(from: "1780"), 1_780)
        XCTAssertEqual(FeedDates.duration(from: "1780.5"), 1_780.5)
        for nonsense in ["", "0", "00:00:00", "1:60:00", "abc", "1::2", "-5", "1:2:3:4", "12:3a"] {
            XCTAssertNil(FeedDates.duration(from: nonsense), nonsense)
        }
    }

    // MARK: - Web Pages and Addresses

    /// A web page's feeds are its alternate links of a feed's type, in its
    /// order, each once, resolved from its address, with their titles; a
    /// page's other links, and a link to a file, are not feeds.
    func testAPagesFeedsAreFoundInOrder() throws {
        let page = String(decoding: try Data(contentsOf: try requireFile("feeds/page-with-feeds.html")), as: UTF8.self)
        let links = FeedDiscovery.feedLinks(inPage: page, pageURL: try XCTUnwrap(URL(string: "https://news.corkboard.example/news/")))

        XCTAssertEqual(links.map(\.url.absoluteString), [
            "https://news.corkboard.example/news/feed/",
            "https://news.corkboard.example/news/comments/feed/",
            "https://news.corkboard.example/news/atom.xml",
        ])
        XCTAssertEqual(links.map(\.title), ["Corkboard Project News » Feed", "Corkboard Project News » Comments Feed", nil])
        XCTAssertEqual(links.map(\.mimeType), ["application/rss+xml", "application/rss+xml", "application/atom+xml"])

        let none = String(decoding: try Data(contentsOf: try requireFile("feeds/page-without-feeds.html")), as: UTF8.self)
        XCTAssertEqual(FeedDiscovery.feedLinks(inPage: none, pageURL: try XCTUnwrap(URL(string: "https://quill-lang.example/"))), [])
    }

    /// An address a listener types becomes an http or https address: the
    /// feed, pcast, and itpc schemes and a bare host become https, and
    /// anything else is refused.
    func testTypedAddressesAreNormalized() {
        XCTAssertEqual(FeedAddress.normalized(" https://feeds.example/show.xml ")?.absoluteString, "https://feeds.example/show.xml")
        XCTAssertEqual(FeedAddress.normalized("http://feeds.example/show.xml")?.absoluteString, "http://feeds.example/show.xml")
        XCTAssertEqual(FeedAddress.normalized("feed://feeds.example/show.xml")?.absoluteString, "https://feeds.example/show.xml")
        XCTAssertEqual(FeedAddress.normalized("feed:https://feeds.example/show.xml")?.absoluteString, "https://feeds.example/show.xml")
        XCTAssertEqual(FeedAddress.normalized("pcast://feeds.example/show.xml")?.absoluteString, "https://feeds.example/show.xml")
        XCTAssertEqual(FeedAddress.normalized("ITPC://feeds.example/show.xml")?.absoluteString, "https://feeds.example/show.xml")
        XCTAssertEqual(FeedAddress.normalized("feeds.example/show.xml")?.absoluteString, "https://feeds.example/show.xml")
        for nonsense in ["", "   ", "ftp://feeds.example/show.xml", "file:///etc/hosts", "two words.example", "https://"] {
            XCTAssertNil(FeedAddress.normalized(nonsense), nonsense)
        }
    }

    // MARK: - Reading a Feed's Text

    /// HTML is read through the app's converter: Markdown keeps emphasis,
    /// lists, and links, and the plain text is what a listener hears, an
    /// image's alt text included and a script's code left out.
    func testHTMLIsReadAsMarkdownAndPlainText() throws {
        let html = "<p>One <em>two</em> <a href=\"https://x.example/\">three</a>.</p><ul><li>Four</li></ul>"
            + "<p><img src=\"https://x.example/a.png\" alt=\"A diagram\"></p><script>alert(1)</script>"
        let text = try XCTUnwrap(FeedTextConverter.read(FeedTextSource(text: html, kind: .unknown)))

        XCTAssertEqual(text.html, html)
        XCTAssertTrue(text.markdown.contains("*two*") || text.markdown.contains("_two_"), text.markdown)
        XCTAssertTrue(text.markdown.contains("[three]("), text.markdown)
        XCTAssertTrue(text.markdown.contains("https://x.example/"), text.markdown)
        XCTAssertTrue(text.plainText.contains("One two three."), text.plainText)
        XCTAssertTrue(text.plainText.contains("Four"), text.plainText)
        XCTAssertTrue(text.plainText.contains("A diagram"), text.plainText)
        XCTAssertFalse(text.plainText.contains("alert"), text.plainText)
    }

    /// Plain text keeps its paragraphs and line breaks, and characters HTML
    /// gives meaning to are text; a text of nothing but whitespace or markup
    /// without words reads as nothing.
    func testPlainTextKeepsItsParagraphs() throws {
        let text = try XCTUnwrap(FeedTextConverter.read(FeedTextSource(text: "Line one\nline two\n\nA <second> & last", kind: .unknown)))

        XCTAssertEqual(text.html, "<p>Line one<br>line two</p>\n<p>A &lt;second&gt; &amp; last</p>")
        XCTAssertTrue(text.plainText.contains("A <second> & last"), text.plainText)
        XCTAssertTrue(text.plainText.contains("\n"), "paragraphs were run together: \(text.plainText)")
        XCTAssertNil(FeedTextConverter.read(FeedTextSource(text: " \n ", kind: .plain)))
        XCTAssertNil(FeedTextConverter.read(FeedTextSource(text: "<p><img src=\"x.png\"></p>", kind: .html)))
    }

    /// Titles become one line of plain text, with markup removed and
    /// references undone.
    func testTitlesBecomeOneLineOfPlainText() {
        XCTAssertEqual(FeedTextConverter.plainLine("Field &amp; Fork", isHTML: true), "Field & Fork")
        XCTAssertEqual(FeedTextConverter.plainLine("Soup <b>for</b>\n one", isHTML: true), "Soup for one")
        XCTAssertEqual(FeedTextConverter.plainLine("Q&A  night"), "Q&A night")
        XCTAssertEqual(FeedTextConverter.plainLine("Tips <3 & tricks"), "Tips <3 & tricks")
    }

    /// Text is escaped for HTML by the shared XML writer (`XMLEscaping`): the
    /// four markup characters as entities, a markup character with a combining
    /// accent after it escaped too (it is one Character in Swift, one scalar
    /// of markup to a parser), and what XML forbids left out, but for a form
    /// feed or a vertical tab, which keep two words apart as a space.
    func testEscapingTextForHTMLIsTheSharedWriters() {
        XCTAssertEqual(FeedTextConverter.escaped("Q&A <b> \"x\""), "Q&amp;A &lt;b&gt; &quot;x&quot;")
        XCTAssertEqual(FeedTextConverter.escaped("tab\tline\nbreak"), "tab\tline\nbreak")
        XCTAssertEqual(FeedTextConverter.escaped("Fish &\u{301} <\u{301} chips"), "Fish &amp;\u{301} &lt;\u{301} chips")
        XCTAssertEqual(FeedTextConverter.escaped("one\u{0C}two\u{0B}three\u{01}four"), "one two threefour")
        // Plain text becomes paragraphs of escaped lines.
        XCTAssertEqual(FeedTextConverter.htmlFromPlainText("a < b\nc & d"), "<p>a &lt; b<br>c &amp; d</p>")
    }

    /// A text the feed does not type is HTML when it holds a tag of an HTML
    /// element, a comment, or a character reference; a "<" in plain text,
    /// before a number, a space, an address, or a word HTML has no element
    /// for, is not markup.
    func testMarkupIsToldFromPlainText() {
        for html in ["a <p>b", "Caf&eacute;", "one<br/>two", "</EM> after", "<!-- note --> text", "&#8217;", "<img src=\"a.png\">"] {
            XCTAssertTrue(FeedTextConverter.looksLikeHTML(html), html)
        }
        for plain in ["1 < 2 & 3 > 2", "Tips <3", "Write to <mail@show.example>", "See <https://show.example>", "A <second> look", "<"] {
            XCTAssertFalse(FeedTextConverter.looksLikeHTML(plain), plain)
        }
    }

    // MARK: - Helpers

    /// The fixture `name` in TestData/feeds, parsed as fetched from
    /// `address`.
    static func parse(_ name: String, from address: String = "https://feeds.example/feed.xml") throws -> ParsedFeed {
        let data = try Data(contentsOf: try requireFile("feeds/\(name)"))
        return try FeedParser.parse(data, baseURL: URL(string: address))
    }

    /// The moment an RFC 3339 date in UTC names.
    static func date(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text), text)
    }
}
