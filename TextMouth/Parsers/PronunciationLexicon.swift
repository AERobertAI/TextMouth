import Foundation

/// A W3C Pronunciation Lexicon (PLS 1.0) read as substitution rules, and
/// substitution rules written as one (FMT08).
///
/// A lexicon is a list of lexemes, each with one or more `grapheme`
/// spellings and either an `alias` (other words to say in its place) or a
/// `phoneme` (IPA or another phonetic alphabet). An alias is exactly what a
/// substitution rule does, so an alias lexeme becomes one rule per grapheme:
/// the grapheme is the pattern, the alias the replacement, matched as a
/// whole word and ignoring case. A phoneme has no text form, since Apple's
/// synthesizers take no lexicon file, so a lexeme with only phonemes is set
/// aside and counted.
struct PronunciationLexicon: Equatable {
    /// One lexeme: the spellings it covers, and what it says in their place.
    struct Lexeme: Equatable {
        /// Every `grapheme` of the lexeme, in the file's order.
        var graphemes: [String] = []
        /// Every `alias` of the lexeme, in the file's order; `usedAlias` is
        /// the one a rule says.
        var aliases: [String] = []
        /// The index in `aliases` of the first alias marked `prefer="true"`,
        /// nil when none is.
        var preferredAliasIndex: Int?

        /// The alias a rule uses, as PLS 1.0 says: the first alias marked
        /// `prefer="true"`, else the first alias.
        var usedAlias: String? {
            preferredAliasIndex.map { aliases[$0] } ?? aliases.first
        }
    }

    /// The most bytes of a lexicon read; a larger file is refused, so a
    /// hostile file cannot make the reader hold unbounded memory.
    static let byteLimit = 8 * 1024 * 1024

    /// The most rules one lexicon adds. Each whole-word rule is a pass over
    /// every chapter's text, so a lexicon of hundreds of thousands of
    /// spellings would slow every book; reading stops at the first lexeme
    /// that would pass this many, and the entries left are counted in
    /// `unreadCount`.
    static let ruleLimit = 5_000

    /// Why a file cannot be read as a lexicon.
    enum ReadError: Error, Equatable {
        /// The file is not XML, or is cut off or malformed.
        case notXML
        /// The file is XML, but its root is not a `lexicon`.
        case notALexicon
        /// The file is larger than `byteLimit`.
        case tooLarge
        /// The file declares XML entities, which a lexicon never needs and
        /// which would be read as nothing.
        case declaresEntities
    }

    /// The lexemes in the file's order, including those that only have
    /// phonemes (they have an empty `aliases`).
    var lexemes: [Lexeme] = []

    /// How many lexemes were not read, having come after `ruleLimit` rules
    /// were reached (or being the one that would pass it).
    var unreadCount = 0

    /// How many lexemes the file holds that no rule can be made from: no
    /// alias, so only phonemes (or nothing usable at all), or an alias with
    /// no grapheme to match.
    var setAsideCount: Int {
        lexemes.filter { $0.aliases.isEmpty || !$0.graphemes.contains { !$0.isEmpty } }.count
    }

    // MARK: - Reading

    /// Reads a lexicon from its XML bytes.
    /// - Throws: `ReadError` when the bytes are too many, are no XML, or
    ///   are XML whose root is not a `lexicon`.
    static func parse(_ data: Data) throws -> PronunciationLexicon {
        guard data.count <= byteLimit else { throw ReadError.tooLarge }
        let reader = LexiconXMLReader()
        let parser = XMLParser(data: data)
        // A lexicon never needs an external entity, and resolving one would
        // read a file or a web address a hostile lexicon names.
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let finished = parser.parse()
        // A declared entity would be read as nothing, silently: refuse it.
        if reader.declaresEntities { throw ReadError.declaresEntities }
        if reader.rootWasNotALexicon { throw ReadError.notALexicon }
        guard finished else { throw ReadError.notXML }
        return PronunciationLexicon(lexemes: reader.lexemes, unreadCount: reader.unreadCount)
    }

    /// Reads the lexicon file at `url`, checking its size before reading it.
    /// - Throws: `ReadError`, or the error of reading the file.
    static func read(from url: URL) throws -> PronunciationLexicon {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= byteLimit else { throw ReadError.tooLarge }
        return try parse(Data(contentsOf: url))
    }

    // MARK: - Rules From a Lexicon

    /// The rules the lexicon's alias lexemes make: one per grapheme, the
    /// grapheme as the pattern and the lexeme's `usedAlias` as the replacement,
    /// plain text, whole word, ignoring case, and enabled. Lexemes that
    /// make no rule are counted in `setAsideCount`. A grapheme repeated in
    /// the file makes one rule, the first.
    var substitutionRules: [SubstitutionRule] {
        var seen = Set<String>()
        var rules: [SubstitutionRule] = []
        for lexeme in lexemes {
            guard let alias = lexeme.usedAlias else { continue }
            for grapheme in lexeme.graphemes where !grapheme.isEmpty {
                // The same spelling, in any capitals, would make a rule
                // that can never differ from the first, as matching ignores case.
                guard seen.insert(grapheme.lowercased()).inserted else { continue }
                rules.append(SubstitutionRule(
                    pattern: grapheme,
                    replacement: alias,
                    isRegex: false,
                    isEnabled: true,
                    caseSensitive: false,
                    wholeWord: true
                ))
            }
        }
        return rules
    }

    // MARK: - A Lexicon From Rules

    /// What writing rules as a lexicon did.
    struct Export: Equatable {
        /// The lexicon holding the rules that could be written.
        var lexicon: PronunciationLexicon
        /// How many rules were written.
        var written: Int { lexicon.lexemes.count }
        /// How many rules were left out: a regular expression has no
        /// spelling a lexicon can hold, a disabled rule is not in use, and
        /// a rule with no pattern matches nothing.
        var leftOut: Int
    }

    /// Writes `rules` as lexemes, in their order. A rule that is a regular
    /// expression, is disabled, or has an empty pattern is left out and
    /// counted. Case sensitivity and whole-word matching are not part of a
    /// lexicon, so they are not kept.
    static func export(_ rules: [SubstitutionRule]) -> Export {
        var lexemes: [Lexeme] = []
        var leftOut = 0
        for rule in rules {
            if rule.isRegex || !rule.isEnabled || rule.pattern.isEmpty {
                leftOut += 1
            } else {
                lexemes.append(Lexeme(graphemes: [rule.pattern], aliases: [rule.replacement]))
            }
        }
        return Export(lexicon: PronunciationLexicon(lexemes: lexemes), leftOut: leftOut)
    }

    /// The lexicon's XML, as UTF-8 bytes, with `language` as its
    /// `xml:lang`, which PLS requires.
    func xmlData(language: String = "en") -> Data {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" // l10n: no (generated markup, not interface text)
        xml += "<lexicon version=\"1.0\" xmlns=\"http://www.w3.org/2005/01/pronunciation-lexicon\" "
        xml += "alphabet=\"ipa\" xml:lang=\"\(Self.escaped(language))\">\n"
        for lexeme in lexemes {
            xml += "  <lexeme>\n"
            for grapheme in lexeme.graphemes {
                xml += "    <grapheme>\(Self.escaped(grapheme))</grapheme>\n"
            }
            for alias in lexeme.aliases {
                xml += "    <alias>\(Self.escaped(alias))</alias>\n"
            }
            xml += "  </lexeme>\n"
        }
        xml += "</lexicon>\n"
        return Data(xml.utf8)
    }

    /// `text` safe inside XML text or an attribute: the five markup
    /// characters escaped, and the control characters XML 1.0 forbids dropped.
    static func escaped(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
            default:
                // XML 1.0 allows U+0020 up to U+D7FF, U+E000 to U+FFFD, and
                // the planes above U+FFFF; a Swift scalar is never a surrogate.
                if scalar.value >= 0x20, scalar.value != 0xFFFE, scalar.value != 0xFFFF {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}

/// Reads a lexicon's lexemes off an `XMLParser`, ignoring namespaces'
/// prefixes and every element it does not know (`phoneme`, `example`).
private final class LexiconXMLReader: EntityRefusingXMLReader {
    /// The lexemes read so far.
    private(set) var lexemes: [PronunciationLexicon.Lexeme] = []
    /// Whether the document's root element is not a `lexicon`.
    private(set) var rootWasNotALexicon = false
    /// The lexemes left unread once the rule limit was reached.
    private(set) var unreadCount = 0
    /// How many rules the lexemes kept so far make.
    private var ruleCount = 0
    /// Whether the rule limit has been reached: every later lexeme is only counted.
    private var limitReached = false
    /// Whether the lexeme being read has more spellings than the limit allows,
    /// so its spellings are no longer kept (the lexeme will be left unread).
    private var currentOverflowed = false

    /// The lexeme being read, if the parser is inside one.
    private var current: PronunciationLexicon.Lexeme?
    /// The element whose text is being collected (`grapheme` or `alias`).
    private var collecting: String?
    /// The text collected for it so far.
    private var text = ""
    /// Whether the alias being collected is marked `prefer="true"`.
    private var collectingPreferred = false
    /// How deep in elements the parser is; the root is at depth 1.
    private var depth = 0

    /// An element's name without a namespace prefix, in lowercase.
    private func local(_ name: String) -> String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        depth += 1
        let name = local(elementName)
        if depth == 1 {
            // Only a lexicon is read; any other root stops the parse.
            if name != "lexicon" {
                rootWasNotALexicon = true
                parser.abortParsing()
            }
            return
        }
        switch name {
        case "lexeme" where depth == 2:
            current = PronunciationLexicon.Lexeme()
            currentOverflowed = false
        case "grapheme", "alias":
            guard current != nil else { return }
            collecting = name
            text = ""
            // PLS 1.0: the first alias marked prefer="true" is the one used.
            collectingPreferred = name == "alias" && attributeDict["prefer"]?.lowercased() == "true"
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting != nil { text += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer { depth -= 1 }
        let name = local(elementName)
        if name == collecting {
            // Runs of white space (a line break and its indent inside an
            // alias) say a single space.
            let words = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if name == "grapheme" {
                // A lexeme with more spellings than the limit is never kept,
                // so keeping no more of its spellings bounds the memory it takes.
                if (current?.graphemes.count ?? 0) >= PronunciationLexicon.ruleLimit {
                    currentOverflowed = true
                } else {
                    current?.graphemes.append(words)
                }
            } else if var lexeme = current {
                if collectingPreferred, lexeme.preferredAliasIndex == nil {
                    lexeme.preferredAliasIndex = lexeme.aliases.count
                }
                lexeme.aliases.append(words)
                current = lexeme
            }
            collecting = nil
        } else if name == "lexeme", depth == 2, let lexeme = current {
            current = nil
            // The rules the lexeme makes: one per spelling, if it has an alias.
            let made = lexeme.aliases.isEmpty ? 0 : lexeme.graphemes.filter { !$0.isEmpty }.count
            if limitReached || currentOverflowed || ruleCount + made > PronunciationLexicon.ruleLimit {
                // From the first lexeme that does not fit, nothing more is kept.
                limitReached = true
                unreadCount += 1
            } else {
                ruleCount += made
                lexemes.append(lexeme)
            }
        }
    }
}
