import XCTest
@testable import TextMouth

/// Two small DAISY books kept as loose files, each with files beside it
/// that are not part of it, for the tests of package import (TODO I02).
///
/// Both spread their files over folders, as real books do, so a test can
/// tell a copy that keeps the book's layout from one that does not. Audio
/// and image files hold stand-in text: a text import copies them without
/// decoding them.
enum DAISYPackageFixtures {

    // MARK: - DAISY 2.02

    /// A DAISY 2.02 book whose navigation file leads, through two SMIL
    /// files, to one text file, two audio files, two style sheets, and an
    /// image whose name holds a space (written `%20` in the reference).
    static let navigationBook: [String: String] = [
        "ncc.html": """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head>
        <title>Notes on Rope Splicing</title>
        <meta name="dc:title" content="Notes on Rope Splicing"/>
        <meta name="dc:creator" content="Casimir Oyelaran"/>
        <meta name="dc:format" content="Daisy 2.02"/>
        <link rel="stylesheet" type="text/css" href="styles/ncc.css"/>
        </head><body>
        <h1 class="title" id="h1"><a href="smil/part1.smil#p1">Short Splice</a></h1>
        <span class="page-normal" id="pg1"><a href="smil/part1.smil#p2">1</a></span>
        <h1 id="h2"><a href="smil/part2.smil#p3">Eye Splice</a></h1>
        <p><a href="http://www.daisy.org/">DAISY Consortium</a></p>
        </body></html>
        """,
        "smil/part1.smil": """
        <?xml version="1.0" encoding="utf-8"?>
        <smil><body><seq>
        <par id="p1"><text src="../text/splices.html#t1"/>\
        <audio src="../audio/part1.mp3" clip-begin="npt=0.000s" clip-end="npt=4.000s"/></par>
        <par id="p2"><text src="../text/splices.html#t2"/>\
        <audio src="../audio/part1.mp3" clip-begin="npt=4.000s" clip-end="npt=9.500s"/></par>
        </seq></body></smil>
        """,
        "smil/part2.smil": """
        <?xml version="1.0" encoding="utf-8"?>
        <smil><body><seq>
        <par id="p3"><text src="../text/splices.html#t3"/>\
        <audio src="../audio/part2.mp3" clip-begin="npt=0.000s" clip-end="npt=3.500s"/></par>
        <par id="p4"><text src="../text/splices.html#t4"/>\
        <audio src="../audio/part2.mp3" clip-begin="npt=3.500s" clip-end="npt=11.000s"/></par>
        </seq></body></smil>
        """,
        "text/splices.html": """
        <html><head><link rel="stylesheet" type="text/css" href="../styles/text.css"/></head><body>
        <h1 id="t1">Short Splice</h1>
        <p id="t2">Unlay the strands for twelve turns before tucking them against the lay.</p>
        <p><img src="../images/eye%20splice.png" alt="An eye splice in three-strand rope"/></p>
        <h1 id="t3">Eye Splice</h1>
        <p id="t4">Form the eye first, then tuck the middle strand under the nearest standing strand.</p>
        </body></html>
        """,
        "audio/part1.mp3": "stand-in audio for the short splice",
        "audio/part2.mp3": "stand-in audio for the eye splice",
        "styles/ncc.css": "h1 { font-size: 1.4em; }",
        "styles/text.css": "p { margin: 0.5em 0; }",
        "images/eye splice.png": "stand-in image of an eye splice"
    ]

    /// The navigation book's files, as its inventory lists them.
    static let navigationBookFiles = navigationBook.keys.sorted()

    /// The sentences the navigation book reads, one from each of its
    /// sections, and the headings of those sections.
    static let navigationBookSentences = [
        "Unlay the strands for twelve turns before tucking them against the lay.",
        "Form the eye first, then tuck the middle strand under the nearest standing strand."
    ]
    static let navigationBookHeadings = ["Short Splice", "Eye Splice"]

    // MARK: - DAISY 3

    /// A DAISY 3 book whose package file lists its DTBook, navigation, and
    /// SMIL files in a folder of their own, a style sheet in a folder whose
    /// name holds a space, and an image (both written with `%20`).
    static let packageBook: [String: String] = [
        "book.opf": """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://openebook.org/namespaces/oeb-package/1.0/" unique-identifier="uid">
        <metadata><dc-metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:Title>Ferry Timetables of the Outer Sound</dc:Title>
        <dc:Creator>Ottilie Vandermeer</dc:Creator>
        <dc:Format>ANSI/NISO Z39.86-2005</dc:Format>
        </dc-metadata></metadata>
        <manifest>
        <item id="opf" href="book.opf" media-type="text/xml"/>
        <item id="text" href="content/timetables.xml" media-type="application/x-dtbook+xml"/>
        <item id="ncx" href="navigation.ncx" media-type="application/x-dtbncx+xml"/>
        <item id="smil" href="content/timetables.smil" media-type="application/smil"/>
        <item id="css" href="style%20sheets/dtbook.css" media-type="text/css"/>
        <item id="map" href="images/harbor%20map.png" media-type="image/png"/>
        </manifest>
        <spine><itemref idref="smil"/></spine>
        </package>
        """,
        "content/timetables.xml": """
        <?xml version="1.0" encoding="UTF-8"?>
        <dtbook xmlns="http://www.daisy.org/z3986/2005/dtbook/" version="2005-3">
        <head><meta name="dc:Title" content="Ferry Timetables of the Outer Sound"/></head>
        <book><bodymatter>
        <level1><h1>The Morning Crossing</h1><p>The first ferry leaves the north pier at ten past six.</p></level1>
        <level1><h1>The Evening Return</h1><p>The last boat back waits for the mail van until nine.</p></level1>
        </bodymatter></book></dtbook>
        """,
        "navigation.ncx": """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
        <navPoint id="n1"><navLabel><text>The Morning Crossing</text></navLabel>\
        <content src="content/timetables.smil#s1"/></navPoint>
        <navPoint id="n2"><navLabel><text>The Evening Return</text></navLabel>\
        <content src="content/timetables.smil#s2"/></navPoint>
        </navMap></ncx>
        """,
        "content/timetables.smil": """
        <?xml version="1.0" encoding="UTF-8"?>
        <smil xmlns="http://www.w3.org/2001/SMIL20/"><body><seq>
        <par id="s1"><text src="timetables.xml#c1"/></par>
        <par id="s2"><text src="timetables.xml#c2"/></par>
        </seq></body></smil>
        """,
        "style sheets/dtbook.css": "level1 { display: block; }",
        "images/harbor map.png": "stand-in image of the harbor"
    ]

    /// The package book's files, as its inventory lists them.
    static let packageBookFiles = packageBook.keys.sorted()

    /// The sentences the package book reads, one from each of its sections,
    /// and the headings of those sections.
    static let packageBookSentences = [
        "The first ferry leaves the north pier at ten past six.",
        "The last boat back waits for the mail van until nine."
    ]
    static let packageBookHeadings = ["The Morning Crossing", "The Evening Return"]

    // MARK: - Files Beside a Book

    /// Files a book's folder holds that are not part of the book: notes,
    /// a hidden Finder file, audio and a DTD that nothing refers to.
    static let unrelatedFiles: [String: String] = [
        "notes.txt": "Borrowed from the harbor library; return by Friday.",
        ".DS_Store": "Finder's view settings",
        "audio/unused.mp3": "stand-in audio nothing refers to",
        "dtbook-2005-3.dtd": "<!ELEMENT dtbook ANY>"
    ]

    // MARK: - Writing Fixtures

    /// `files` with each path moved into the folder `folder`, as an archive
    /// that holds the book in a folder of its own lists them.
    static func entries(_ files: [String: String], inFolder folder: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: files.map { ("\(folder)/\($0.key)", $0.value) })
    }

    /// Writes `files` (path inside the folder → text) into a new folder
    /// named `name` inside `parent`, creating the folders they are in, and
    /// returns the folder.
    @discardableResult
    static func writeFolder(_ files: [String: String], named name: String, in parent: URL) throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, text) in files {
            let file = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: file)
        }
        return folder
    }

    /// The words a reader hears for `markdown`: the plain text the Markdown
    /// parser extracts for speech and display (a DAISY book is one chapter
    /// whose headings mark its sections).
    static func spokenText(of markdown: String) throws -> String {
        try MarkdownDocParser.parse(markdown: markdown).chapters.map(\.text).joined(separator: "\n\n")
    }
}
