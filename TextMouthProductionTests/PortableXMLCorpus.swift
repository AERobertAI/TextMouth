import Foundation

/// An XML document, named, for `PortableXMLDifferentialTests`, which reads
/// each with Foundation's tree and with the portable one (PortableXML.swift)
/// and compares what they make of it.
struct PortableXMLSample {
    /// What the document shows, for a failure message.
    let name: String
    /// The document's bytes.
    let data: Data

    /// A sample whose bytes are the UTF-8 of `text`.
    init(_ name: String, _ text: String) {
        self.name = name
        self.data = Data(text.utf8)
    }

    /// A sample of exactly these bytes.
    init(_ name: String, bytes: [UInt8]) {
        self.name = name
        self.data = Data(bytes)
    }
}

/// Small documents that cover what the readers meet and what a crafted file
/// might hold: well-formed ones with the shapes the readers walk, and ones
/// that are not well-formed in each of the ways a strict reading fails.
enum PortableXMLCorpus {
    /// Every sample, well-formed first.
    static let samples: [PortableXMLSample] = wellFormed + malformed

    /// Documents that are well-formed.
    static let wellFormed: [PortableXMLSample] = [
        PortableXMLSample("plain", "<a><b>x</b><c/></a>"),
        PortableXMLSample("declaration, comments, and instructions around the root", """
            <?xml version="1.0" encoding="UTF-8"?>
            <!-- before -->
            <?pi some data?>
            <a/>
            <!-- after -->

            """),
        PortableXMLSample("namespaces", """
            <a xmlns="urn:default" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
              <dc:title opf:role="x" plain="1" xml:lang="en">T</dc:title>
              <inner xmlns="">undeclared default</inner>
              <other xmlns="urn:other"><dc:deep/></other>
              <dc:redeclared xmlns:dc="urn:changed"><dc:inside/></dc:redeclared>
            </a>
            """),
        PortableXMLSample("a prefixed and an unprefixed attribute with one local name", """
            <a xmlns:p="urn:p" p:role="prefixed" role="plain"/>
            """),
        PortableXMLSample("attribute values", "<a one=\"x &amp; y &lt; z &#65; &#x1F600;\" two='it\"s' three=\"line&#10;break\"/>"),
        PortableXMLSample("whitespace between elements", "<a>\n  <b>\n    <c>x</c>\n  </b>\n  <d/>\n</a>"),
        PortableXMLSample("mixed content", "<p>One <b>two</b> three <i>four</i>.</p>"),
        PortableXMLSample("whitespace only", "<a>  </a>"),
        PortableXMLSample("whitespace between a text and an element", "<a>t<b/> <c/> </a>"),
        PortableXMLSample("whitespace before a CDATA section", "<a>\n    <![CDATA[00:29:24]]>\n  </a>"),
        PortableXMLSample("whitespace before a CDATA section after an element", "<a><b/> <![CDATA[x]]></a>"),
        PortableXMLSample("whitespace before a CDATA section after a text", "<a>t<b/> <![CDATA[x]]></a>"),
        PortableXMLSample("a CDATA section of whitespace", "<a> <![CDATA[ ]]> </a>"),
        PortableXMLSample("text around a CDATA section", "<a>x<![CDATA[ <y> ]]>z</a>"),
        PortableXMLSample("references and whitespace", "<a>&amp; &amp; &#32;<b/> &#32;<c/>&#10;</a>"),
        PortableXMLSample("xml:space preserve", "<a xml:space=\"preserve\">  <b/>  </a>"),
        PortableXMLSample("no-break spaces are not whitespace", "<a>\u{A0}</a>"),
        PortableXMLSample("a comment and an instruction among the text", "<a>one<!-- c -->two<?p d?>three</a>"),
        PortableXMLSample("text with runs of whitespace", "<a>x   y\t\tz\r\nw\n\n\nv</a>"),
        PortableXMLSample("text with leading and trailing whitespace", "<a>\n  x  <b>  y  </b>  z  \n</a>"),
        PortableXMLSample("attribute value with whitespace", "<a b=\"  one\ttwo\n three  \"/>"),
        PortableXMLSample("unicode", "<a lang=\"日本語\">Zażółć gęślą jaźń \u{1F600} naïve café</a>"),
        PortableXMLSample("a DTD without entities", "<!DOCTYPE a [<!ELEMENT a (#PCDATA)><!ATTLIST a x CDATA #IMPLIED>]><a x=\"1\">t</a>"),
        PortableXMLSample("a DTD naming an external subset", "<!DOCTYPE a PUBLIC \"-//X//EN\" \"http://example.invalid/x.dtd\"><a>text</a>"),
        PortableXMLSample("a package document", """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id" xmlns:dc="http://purl.org/dc/elements/1.1/">
              <metadata xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:identifier id="id">urn:isbn:9781234567897</dc:identifier>
                <dc:title>  A  Title \n </dc:title>
                <dc:creator id="aut">Ada Marsh</dc:creator>
                <meta refines="#aut" property="role" scheme="marc:relators">aut</meta>
                <meta property="dcterms:creator">Someone Else</meta>
                <dc:creator opf:role="ill">An Illustrator</dc:creator>
              </metadata>
              <manifest>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml" properties="nav"/>
              </manifest>
              <spine toc="ncx"><itemref idref="c1"/></spine>
              <guide><reference type="toc" href="c1.xhtml#toc"/></guide>
            </package>
            """),
        PortableXMLSample("an NCX", """
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
              <navMap>
                <navPoint id="p1"><navLabel><text>One</text></navLabel><content src="a.html"/>
                  <navPoint id="p2"><navLabel><text>One.One</text></navLabel><content src="a.html#x"/></navPoint>
                </navPoint>
              </navMap>
              <pageList><pageTarget id="pg1" value="7"><navLabel><text/></navLabel><content src="a.html#p7"/></pageTarget></pageList>
            </ncx>
            """),
        PortableXMLSample("nesting 300 deep", String(repeating: "<a>", count: 300) + "x" + String(repeating: "</a>", count: 300)),
        PortableXMLSample("a long text", "<a>" + String(repeating: "word and another word, ", count: 20_000) + "</a>"),
        PortableXMLSample("many siblings", "<a>" + String(repeating: "<b n=\"1\"/>", count: 5_000) + "</a>"),
        PortableXMLSample("an encoding declaration the text does not follow", "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><a>caf\u{E9}</a>"),
        PortableXMLSample("a byte order mark", "\u{FEFF}<a>x</a>"),
        PortableXMLSample("leading whitespace before the root", "  \n<a/>"),
        PortableXMLSample("a UTF-16 document", bytes: [0xFF, 0xFE] + Array("<?xml version=\"1.0\" encoding=\"UTF-16\"?><a>hi</a>".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }),
        PortableXMLSample("a Latin-1 document", bytes: Array("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><a>caf".utf8) + [0xE9] + Array("</a>".utf8)),
    ]

    /// Documents that are not well-formed, or that a strict reading refuses
    /// for another reason.
    static let malformed: [PortableXMLSample] = [
        PortableXMLSample("empty", ""),
        PortableXMLSample("only whitespace", "  \n "),
        PortableXMLSample("text only", "hello"),
        PortableXMLSample("a comment only", "<!-- nothing -->"),
        PortableXMLSample("two roots", "<a/><b/>"),
        PortableXMLSample("a mismatched end tag", "<a><b>x</a>"),
        PortableXMLSample("truncated", "<rss><channel><title>T</title><item><title>I"),
        PortableXMLSample("a bare ampersand", "<a>Q&A night</a>"),
        PortableXMLSample("a control character", "<a>bad\u{0B}char</a>"),
        PortableXMLSample("an undefined entity", "<a>&nbsp;x</a>"),
        PortableXMLSample("an undefined entity beside a DTD naming an external subset", "<!DOCTYPE a PUBLIC \"-//X//EN\" \"http://example.invalid/x.dtd\"><a>One&nbsp;two</a>"),
        PortableXMLSample("an unbound element prefix", "<a><dc:b>t</dc:b></a>"),
        PortableXMLSample("an unbound attribute prefix", "<a><b opf:role=\"x\" id=\"1\">t</b></a>"),
        PortableXMLSample("a qualified name with two colons", "<a><b:c:d/></a>"),
        PortableXMLSample("a qualified name starting with a colon", "<a><:b/></a>"),
        PortableXMLSample("a qualified name ending with a colon", "<a><b:/></a>"),
        PortableXMLSample("a prefix bound to nothing", "<a xmlns:p=\"\"><p:b/></a>"),
        PortableXMLSample("a duplicate attribute", "<a x=\"1\" x=\"2\"/>"),
        PortableXMLSample("an attribute without a value", "<a b/>"),
        PortableXMLSample("an unquoted attribute value", "<a b=c/>"),
        PortableXMLSample("an unterminated comment", "<a><!-- oops</a>"),
        PortableXMLSample("a less-than sign in the text", "<a>1 < 2 <b>x</b></a>"),
        PortableXMLSample("HTML with a void element", "<html><body><p>one<br>two</body></html>"),
        PortableXMLSample("markup after the root", "<a/>junk"),
        PortableXMLSample("an internal entity", "<!DOCTYPE a [<!ENTITY x \"hello\">]><a>&x; there</a>"),
        PortableXMLSample("an external entity", "<!DOCTYPE a [<!ENTITY x SYSTEM \"file:///etc/hosts\">]><a>Start&x;End</a>"),
        PortableXMLSample("invalid UTF-8", bytes: Array("<a>caf".utf8) + [0xE9] + Array("</a>".utf8)),
    ]
}
