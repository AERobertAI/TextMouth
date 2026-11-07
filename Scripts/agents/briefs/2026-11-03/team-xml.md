# Team xml: an XML tree for iOS, with the Mac's parsers unchanged

Read `ios0-common.md` beside this file first: it is the pattern, and its rules override this charter. This team is one agent, `xml`, on branch `team/xml`, reporting to the orchestrator: plan, build, and test it yourself, launching a worker only if the work clearly splits (at most one). Your files are listed in `files-xml.md` beside this file. They are the EPUB parser's two files and the feed and OPML parsers, which read XML with Foundation's tree, `XMLDocument`, `XMLElement`, and `XMLNode`, with XPath. iOS's Foundation has only the streaming `XMLParser`.

## Decisions already made

- **The four parser files do not change at all,** and the Mac goes on using Foundation's own tree.
- **Write a portable XML tree** in shared code, `TextMouth/Parsers/PortableXML.swift` (split it if it passes about 600 lines). Its classes are `PortableXMLNode`, `PortableXMLElement`, and `PortableXMLDocument`, with exactly the subset of Foundation's API the four files use. Find the subset with the census and by reading the four files. It includes:
  - the initializers `init(xmlString:options:)` and `init(data:options:)`, with an `Options` option set holding the options the files pass;
  - `rootElement()`, `children`, `name`, `localName`, `prefix`, `uri`, `kind` (with a `Kind` enum), `level`, `stringValue`, `attributes`, `attribute(forName:)`, and `elements(forName:)`;
  - `nodes(forXPath:)`, for the expressions the files pass, all of the form `//*[local-name()='X']`, `//*[local-name()='A']/*[local-name()='B']`, `*[local-name()='X']`, and `*[local-name()='A']/*[local-name()='B']`;
  - `setChildren(_:)`, used by the deep-tree teardown;
  - whatever else the census names.

  Unsupported XPath throws, never silently matches nothing. `stringValue` means what it means in Foundation: for an element, the concatenated text of its descendants.
- **On iOS only**, `TextMouth/Platform/iOS/Parsers/XMLTree+iOS.swift` declares `typealias XMLDocument = PortableXMLDocument`, and the same for `XMLElement` and `XMLNode`, so the four files compile on iOS unchanged.
- **Parse with Foundation's XMLParser:**
  - `shouldResolveExternalEntities = false`, so no external entity is ever loaded, which matches `.nodeLoadExternalEntitiesNever`;
  - `shouldProcessNamespaces` set as the names require;
  - the tree built without recursion;
  - a depth bound (refuse a document nested deeper than 512 levels, with an error), and a deinit that cannot overflow the stack on a deep tree.

  Where a caller passes `.documentTidyXML` (the feed and OPML parsers) and the strict parse fails, fall back to SwiftSoup's XML parser (`Parser.xmlParser()`), which is lenient, and build the same tree from its result. SwiftSoup is already a dependency.
- **The EPUB metadata writer** (`updateOPFMetadata` in EPUBParser.swift, which changes the package's XML and writes it back with `xmlString(options: [.nodePrettyPrint])`) writes into the user's books. Keep its Mac behavior exactly.
  - If supporting `XMLElement(name:)`, `addChild`, the `stringValue` setter, and `xmlString(options:)` in the portable tree is small, do it.
  - Otherwise wrap the writer in `#if os(macOS)` (the Mac branch unchanged), and give iOS a version that throws `IOSUnavailable.feature("Saving a book's details into its EPUB file")`.

  Say in your report which you chose, and why.
- **Prove it on the Mac with differential tests.** A new test class, `PortableXMLDifferentialTests` in `TextMouthProductionTests`, runs only on the Mac, where both trees exist. For every EPUB package document and navigation document in `TestData` (copy each into the test's own temporary folder first; the files are untrusted), and for the feed and OPML fixtures the feed tests use:
  - parse each with Foundation's `XMLDocument`, using the options the parsers pass, and with `PortableXMLDocument`;
  - run every XPath expression and element walk the four files use;
  - assert the same results: the count, and each node's name, local name, attributes, and string value, in order.

  Add unit tests for the XPath subset, a malformed document (strict: an error; tidy: the fallback's tree), the depth bound, and no external entity loaded. Report the fixtures' count and any difference you had to accept, with its reason.
  - Run `/opt/homebrew/bin/xcodegen generate` for the new test file.
  - Place the class in `Scripts/test/areas.conf`: the `import` area, and `feeds` for the feed parts.

## Tests to request from the train

`PortableXMLDifferentialTests` and the other new classes, plus the areas `import` and `feeds`.

## Finish

As a lead does in ios0-common.md: the census shows none of your four files, `make typecheck-mac` is clean, and the projection shows the four parser files unchanged. Report to the orchestrator, writing your report to `build/orchestrator/ios0/xml-lead-report.md`.
