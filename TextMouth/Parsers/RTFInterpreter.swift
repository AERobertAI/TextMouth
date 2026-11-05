import Foundation

// MARK: - The Interpreter

/// Reads the tokens of a Rich Text Format document and says what the
/// document holds (FMT47): its paragraphs with their headings, emphasis,
/// lists, tables, and page breaks, and its title and author.
///
/// It is written from Microsoft's RTF 1.9.1 specification. The document is
/// untrusted input, so the group stack is the interpreter's own array (no
/// recursion on a depth the file controls), the depth is capped, the text
/// is held to a budget, and every number read from the file is checked.
/// A document that ends before its groups do still yields its text so far.
struct RTFInterpreter {

    // MARK: Limits

    /// The deepest nesting of groups read. A real document nests a few
    /// dozen; more is a hostile file.
    static let deepestNesting = 10_000

    /// The most fonts the font table keeps.
    private static let mostFonts = 100_000

    /// The longest list text or name kept (it is read only for its kind or
    /// its name).
    private static let longestName = 1_000

    // MARK: State

    /// The tokens being read.
    private var tokenizer: RTFTokenizer
    /// The state of the group being read, and of the groups around it.
    private var state = RTFGroupState()
    private var stack: [RTFGroupState] = []
    /// Whether the next token is the first of a new group (so a control
    /// word may name its destination), and whether `\*` came first.
    private var groupJustStarted = false
    private var starred = false
    /// Whether the document's outermost group has begun, and whether it has
    /// ended: nothing before the first brace or after the last is read.
    private var hasStarted = false
    private var isFinished = false

    /// The body being built.
    private var builder: RTFBlockBuilder
    /// The title and author read, and the text of the one being read.
    private var title = ""
    private var author = ""
    private var infoText = ""

    // MARK: Code pages and fonts

    /// The document's code page: `\ansi` (1252), `\mac`, `\pc`, `\pca`, or
    /// `\ansicpgN`, which wins over the first four.
    private var documentCodePage = RTFEncodings.windows1252
    private var hasExplicitCodePage = false
    /// The default font, `\deffN`.
    private var defaultFont = 0
    /// The code page of each font whose character set names one.
    private var fontCodePages: [Int: Int] = [:]
    /// The font whose entry the font table is reading.
    private var fontBeingRead: Int?
    /// Bytes of `\'hh` escapes and raw non-ASCII bytes waiting to be
    /// decoded together, so the two bytes of a double-byte character make
    /// one.
    private var byteRun: [UInt8] = []
    /// How many characters after a `\uN` are still to be skipped.
    private var pendingSkip = 0
    /// A high surrogate read as a `\uN` that waits for its low one.
    private var pendingHighSurrogate: UInt16?

    // MARK: Styles and lists

    private var styleSheet = RTFStyleSheet()
    private var listTable = RTFListTable()
    /// The style definition being read.
    private var styleNumber = 0
    private var styleIsParagraphStyle = true
    private var styleName = ""
    private var styleOutlineLevel: Int?
    private var styleBasedOn: Int?
    private var stylePageBreakBefore = false
    /// What the paragraph being read has shown as its list marker, if
    /// anything: the text of its `\listtext` or `\pntext`.
    private var listMarker: String?
    /// The text of the list marker being read.
    private var markerText = ""
    /// The paragraph properties at the last text, for the paragraph a
    /// document ends in the middle of.
    private var lastParagraphProperties = RTFParagraphProperties()
    /// Whether some paragraph is a heading by its style or outline level.
    private var hasNamedHeading = false

    // MARK: Entry point

    /// An interpreter for the document in `bytes`.
    /// - Parameters:
    ///   - includesPages: whether page breaks are placed.
    ///   - limit: the most text the document may make.
    init(bytes: [UInt8], includesPages: Bool, limit: Int64) {
        tokenizer = RTFTokenizer(bytes: bytes)
        builder = RTFBlockBuilder(includesPages: includesPages, limit: limit)
    }

    /// Reads the whole document.
    /// - Throws: `TextutilConverter.Failure.unreadable` for groups nested
    ///   past `deepestNesting`, and `DocumentTooLargeError` for text past
    ///   the limit.
    mutating func read() throws -> RTFDocument {
        while !isFinished, let token = tokenizer.next() {
            try handle(token)
        }
        flushBytes()
        flushLoneSurrogate()
        let kind = paragraphKind(of: lastParagraphProperties)
        if case .heading = kind { hasNamedHeading = true }
        var document = RTFDocument()
        document.blocks = try builder.finish(lastParagraph: kind, inTable: lastParagraphProperties.inTable)
        document.title = title
        document.author = author
        document.pageBreaks = builder.pageBreaks
        if !hasNamedHeading {
            // No heading is named by a style or an outline level: guess
            // them as textutil's reading does, from size and weight.
            document.blocks = RTFSizeHeadings.apply(to: document.blocks)
        }
        return document
    }

    // MARK: Tokens

    /// Reads one token.
    private mutating func handle(_ token: RTFToken) throws {
        // Nothing before the document's first brace is part of it.
        if !hasStarted {
            guard case .groupStart = token else { return }
            hasStarted = true
        }
        // A group's first token may name its destination.
        let isFirstOfGroup = groupJustStarted
        groupJustStarted = false

        switch token {
        case .hexByte(let byte):
            handleHexByte(byte)
            return
        case .text(let range):
            try handleText(range)
            return
        default:
            // Anything else ends the run of bytes that waits.
            flushBytes()
        }

        switch token {
        case .groupStart:
            flushLoneSurrogate()
            pendingSkip = 0
            try startGroup()
        case .groupEnd:
            flushLoneSurrogate()
            pendingSkip = 0
            endGroup()
        case .controlSymbol(let symbol):
            if isFirstOfGroup, symbol == "*" {
                // The next word names an ignorable destination.
                groupJustStarted = true
                starred = true
                return
            }
            try handleSymbol(symbol)
        case .controlWord(let name, let parameter):
            if isFirstOfGroup, let destination = destination(named: name, starred: starred) {
                starred = false
                beginDestination(destination)
                return
            }
            starred = false
            try handleWord(name, parameter)
        case .hexByte, .text:
            break
        }
        if isFirstOfGroup { starred = false }
    }

    // MARK: Groups

    /// A group begins: the state is saved, and a group in the style sheet
    /// begins a style.
    private mutating func startGroup() throws {
        guard stack.count < Self.deepestNesting else {
            throw TextutilConverter.Failure.unreadable(.rtf)
        }
        stack.append(state)
        groupJustStarted = true
        starred = false
        switch state.destination {
        case .styleSheet:
            // Each group of the style sheet is one style.
            state.destination = .styleEntry
            groupJustStarted = false
            styleNumber = 0
            styleIsParagraphStyle = true
            styleName = ""
            styleOutlineLevel = nil
            styleBasedOn = nil
            stylePageBreakBefore = false
        case .styleEntry:
            // A group inside a style (such as `\*\keycode`) is not read.
            state.destination = .skipped
            groupJustStarted = false
        case .skipped, .attachment:
            groupJustStarted = false
        default:
            break
        }
    }

    /// A group ends: whatever it was reading is finished, and the state
    /// before it is restored. The document's outermost group ending ends
    /// the document.
    private mutating func endGroup() {
        guard let parent = stack.popLast() else {
            isFinished = true
            return
        }
        if state.destination != parent.destination {
            finishDestination(state.destination, parent: parent.destination)
        }
        state = parent
        if stack.isEmpty { isFinished = true }
    }

    /// The destination `name` starts at the beginning of a group, or nil
    /// when the word is not a destination there. After `\*`, a word that is
    /// not known starts a skipped destination.
    private func destination(named name: String, starred: Bool) -> RTFDestination? {
        if state.destination.isUnread { return nil }
        if state.destination == .info {
            // Only the title and the author are read of the info group.
            switch name {
            case "title": return .title
            case "author": return .author
            default: return .skipped
            }
        }
        if let known = RTFDestination.named(name) { return known }
        return starred ? .skipped : nil
    }

    /// The group just begun is a destination of this kind.
    private mutating func beginDestination(_ destination: RTFDestination) {
        state.destination = destination
        switch destination {
        case .title, .author:
            infoText = ""
        case .listText:
            markerText = ""
        default:
            break
        }
    }

    /// The group that began `destination` (inside `parent`) ends.
    private mutating func finishDestination(_ destination: RTFDestination, parent: RTFDestination) {
        switch destination {
        case .title:
            title = infoText.trimmingCharacters(in: .whitespacesAndNewlines)
        case .author:
            author = infoText.trimmingCharacters(in: .whitespacesAndNewlines)
        case .listText:
            listMarker = markerText
        case .listTable:
            listTable.finish()
        case .styleEntry:
            finishStyle()
        case .attachment:
            // The one character after an attachment stands for it.
            pendingSkip = 1
        default:
            break
        }
    }

    /// Records the style definition that was just read.
    private mutating func finishStyle() {
        guard styleIsParagraphStyle else { return }
        // The name ends at the first semicolon.
        let name = styleName.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        styleSheet.add(
            number: styleNumber,
            name: name,
            outlineLevel: styleOutlineLevel,
            basedOn: styleBasedOn,
            pageBreakBefore: stylePageBreakBefore
        )
    }

    // MARK: Text

    /// A run of text bytes. ASCII goes straight to the output; other bytes
    /// wait to be decoded together in the code page that applies.
    private mutating func handleText(_ range: Range<Int>) throws {
        guard !isIgnoringText else {
            flushBytes()
            return
        }
        var index = range.lowerBound
        // The fallback of a `\uN` is skipped.
        if pendingSkip > 0 {
            let skipped = min(pendingSkip, range.count)
            index += skipped
            pendingSkip -= skipped
        }
        var ascii = String.UnicodeScalarView()
        for position in index..<range.upperBound {
            let byte = tokenizer.bytes[position]
            if byte < 0x80 {
                if !byteRun.isEmpty {
                    try emit(String(ascii))
                    ascii = String.UnicodeScalarView()
                    flushBytes()
                }
                ascii.append(Unicode.Scalar(byte))
            } else {
                if !ascii.isEmpty {
                    try emit(String(ascii))
                    ascii = String.UnicodeScalarView()
                }
                flushLoneSurrogate()
                byteRun.append(byte)
            }
        }
        if !ascii.isEmpty {
            flushLoneSurrogate()
            try emit(String(ascii))
        }
        flushBytes()
    }

    /// `\'hh`: a byte that waits for the bytes around it.
    private mutating func handleHexByte(_ byte: UInt8?) {
        guard let byte, !isIgnoringText else { return }
        if pendingSkip > 0 {
            pendingSkip -= 1
            return
        }
        flushLoneSurrogate()
        byteRun.append(byte)
    }

    /// Whether the text of this group is read by nothing.
    private var isIgnoringText: Bool {
        switch state.destination {
        case .skipped, .attachment, .fontTable, .styleSheet, .listTable, .info: return true
        default: return false
        }
    }

    /// Decodes the bytes that wait, in the code page of the font in force,
    /// and writes the result as text.
    private mutating func flushBytes() {
        guard !byteRun.isEmpty else { return }
        let text = RTFEncodings.decode(byteRun, codePage: currentCodePage)
        byteRun.removeAll(keepingCapacity: true)
        // The text cannot be too large to write by itself; the budget is
        // enforced by the next text, so a failure here is not lost.
        _ = try? emit(text)
    }

    /// The code page that applies to the bytes now: the font's, when its
    /// character set names one, and otherwise the document's.
    private var currentCodePage: Int {
        fontCodePages[state.font ?? defaultFont] ?? documentCodePage
    }

    /// Writes `text` where this group's text goes.
    private mutating func emit(_ text: String) throws {
        guard !text.isEmpty else { return }
        switch state.destination {
        case .body:
            guard !state.isHidden else { return }
            lastParagraphProperties = state.paragraph
            try builder.appendText(
                RTFInterpreter.readable(text),
                bold: state.isBold,
                italic: state.isItalic,
                size: state.fontSize
            )
        case .listText:
            if markerText.count < Self.longestName { markerText += text }
        case .title, .author:
            if infoText.count < Self.longestName { infoText += text }
        case .styleEntry:
            if styleName.count < Self.longestName { styleName += text }
        default:
            break
        }
    }

    /// `text` with the characters a reading should not hold made safe: each
    /// control character is a space (a tab, a form feed), so the words
    /// around it stay apart, and NUL, DEL, and the character that stands for
    /// a picture (U+FFFC) are nothing.
    private static func readable(_ text: String) -> String {
        let objectReplacement: UInt32 = 0xFFFC
        guard text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0.value == objectReplacement }) else {
            return text
        }
        var cleaned = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            // NUL, DEL, and the character that stands for a picture are not words.
            if scalar.value == 0 || scalar.value == 0x7F || scalar.value == objectReplacement {
                continue
            } else if scalar.value < 0x20 {
                cleaned.append(" ")
            } else {
                cleaned.append(scalar)
            }
        }
        return String(cleaned)
    }

    // MARK: Unicode

    /// `\uN` (a signed 16-bit number, with 65536 added when negative): a
    /// character, whose fallback the next `\ucN` characters are. Two in a
    /// row make a surrogate pair. A number out of range is the replacement
    /// character.
    private mutating func handleUnicode(_ parameter: Int?) throws {
        pendingSkip = state.unicodeSkip
        guard let parameter else { return }
        let value = parameter < 0 ? parameter + 65_536 : parameter
        guard (0...0xFFFF).contains(value) else {
            flushLoneSurrogate()
            try emit("\u{FFFD}")
            return
        }
        let unit = UInt16(value)
        switch unit {
        case 0xD800...0xDBFF:
            flushLoneSurrogate()
            pendingHighSurrogate = unit
        case 0xDC00...0xDFFF:
            if let high = pendingHighSurrogate {
                pendingHighSurrogate = nil
                let combined = 0x10000 + (UInt32(high) - 0xD800) * 0x400 + (UInt32(unit) - 0xDC00)
                try emit(Unicode.Scalar(combined).map { String($0) } ?? "\u{FFFD}")
            } else {
                try emit("\u{FFFD}")
            }
        case 0:
            flushLoneSurrogate()
        default:
            flushLoneSurrogate()
            try emit(Unicode.Scalar(unit).map { String($0) } ?? "\u{FFFD}")
        }
    }

    /// A high surrogate that no low one followed is the replacement
    /// character.
    private mutating func flushLoneSurrogate() {
        guard pendingHighSurrogate != nil else { return }
        pendingHighSurrogate = nil
        _ = try? emit("\u{FFFD}")
    }

    // MARK: Control symbols

    /// A control symbol: the characters it stands for.
    private mutating func handleSymbol(_ symbol: Character) throws {
        switch symbol {
        case "~": try emit(" ")        // a non-breaking space, read as a space
        case "_": try emit("-")        // a non-breaking hyphen
        case "\\", "{", "}": try emit(String(symbol))
        default: break                 // `\-`, `\|`, `\:`, `\*` and the rest read nothing
        }
    }

    // MARK: Control words

    /// The characters the control words for typographic characters stand for.
    private static let characters: [String: String] = [
        "emdash": "\u{2014}", "endash": "\u{2013}", "emspace": " ", "enspace": " ",
        "qmspace": " ", "bullet": "\u{2022}", "lquote": "\u{2018}", "rquote": "\u{2019}",
        "ldblquote": "\u{201C}", "rdblquote": "\u{201D}", "zwj": "\u{200D}", "zwnj": "\u{200C}",
        "tab": " "
    ]

    /// A control word, by where it stands.
    private mutating func handleWord(_ name: String, _ parameter: Int?) throws {
        switch state.destination {
        case .skipped, .attachment, .styleSheet, .info:
            return
        case .fontTable:
            readFontWord(name, parameter)
        case .styleEntry:
            readStyleWord(name, parameter)
        case .listTable:
            readListWord(name, parameter)
        case .body, .listText, .title, .author:
            if name == "tab", state.destination == .body,
               let bullet = builder.takeBulletMark(from: TextutilHTMLStructure.bulletCharacters) {
                // A bullet and a tab begin a list item, as writers without
                // lists write one (and as textutil's reading finds them).
                listMarker = bullet
            } else if let text = Self.characters[name] {
                try emit(text)
            } else if name == "u" {
                try handleUnicode(parameter)
            } else if state.destination == .body {
                try readBodyWord(name, parameter)
            }
        }
    }

    /// Words of the font table: a font's number and its character set.
    private mutating func readFontWord(_ name: String, _ parameter: Int?) {
        guard let parameter else { return }
        switch name {
        case "f":
            fontBeingRead = parameter
        case "fcharset":
            if let font = fontBeingRead, let codePage = RTFEncodings.codePage(forCharset: parameter),
               fontCodePages.count < Self.mostFonts {
                fontCodePages[font] = codePage
            }
        case "cpg":
            if let font = fontBeingRead, fontCodePages.count < Self.mostFonts {
                fontCodePages[font] = parameter
            }
        default:
            break
        }
    }

    /// Words of a style definition.
    private mutating func readStyleWord(_ name: String, _ parameter: Int?) {
        switch name {
        case "s":
            styleNumber = parameter ?? 0
        case "cs", "ts", "ds":
            // A character, table, or section style.
            styleIsParagraphStyle = false
        case "outlinelevel":
            styleOutlineLevel = parameter
        case "sbasedon":
            styleBasedOn = parameter
        case "pagebb":
            stylePageBreakBefore = true
        default:
            break
        }
    }

    /// Words of the list table and the list override table.
    private mutating func readListWord(_ name: String, _ parameter: Int?) {
        switch name {
        case "list": listTable.beginList()
        case "listlevel": listTable.beginLevel()
        case "listoverride": listTable.beginOverride()
        case "levelnfc": if let parameter { listTable.setLevelFormat(parameter) }
        case "listid": if let parameter { listTable.setListID(parameter) }
        case "ls": if let parameter { listTable.setOverrideNumber(parameter) }
        default: break
        }
    }

    /// Words of the body: formatting, paragraphs, tables, and pages.
    private mutating func readBodyWord(_ name: String, _ parameter: Int?) throws {
        switch name {
        // Code pages
        case "ansi", "mac", "pc", "pca":
            if !hasExplicitCodePage, let codePage = RTFEncodings.codePage(forDocumentWord: name) {
                documentCodePage = codePage
            }
        case "ansicpg":
            if let parameter {
                documentCodePage = parameter
                hasExplicitCodePage = true
            }
        case "deff":
            defaultFont = parameter ?? 0

        // Character formatting
        case "plain": state.resetCharacterFormatting()
        case "b": state.isBold = parameter != 0
        case "i": state.isItalic = parameter != 0
        case "v": state.isHidden = parameter != 0
        case "f": state.font = parameter
        case "fs": state.fontSize = max(parameter ?? RTFGroupState.defaultFontSize, 1)
        case "uc": state.unicodeSkip = max(parameter ?? 1, 0)

        // Line and paragraph structure
        case "line", "lbr": builder.appendLineBreak()
        case "par": try endParagraph()
        case "pard": state.paragraph = RTFParagraphProperties()
        case "s": setStyle(parameter)
        case "outlinelevel": state.paragraph.outlineLevel = parameter
        case "ls": state.paragraph.listOverride = parameter
        case "ilvl": state.paragraph.listLevel = min(max(parameter ?? 0, 0), 8)
        case "intbl": state.paragraph.inTable = true
        case "itap": state.paragraph.inTable = (parameter ?? 1) > 0

        // Tables. A nested cell ends a paragraph of the cell it is in, and a
        // nested row ends nothing: the words of a nested table stay in the
        // cell around it.
        case "cell": endCell()
        case "row": endRow()
        case "nestcell": try endParagraph(inTable: true)

        // Pages and sections
        case "page":
            builder.addPageBreak()
            try emit(" ")
        case "pagebb": builder.addParagraphPageBreak()
        case "sect":
            try endParagraph()
            builder.beginSectionBreak()
        case "sectd", "sbkpage", "sbkeven", "sbkodd": builder.setSectionStartsPage(true)
        case "sbknone", "sbkcol": builder.setSectionStartsPage(false)
        default:
            break
        }
    }

    // MARK: Paragraphs

    /// `\sN`: the paragraph's style, which may begin a page.
    private mutating func setStyle(_ parameter: Int?) {
        state.paragraph.style = parameter
        if let parameter, styleSheet.beginsPage(ofStyle: parameter) {
            builder.addParagraphPageBreak()
        }
    }

    /// What the paragraph with these properties is: a heading by its outline
    /// level, or else its style; a list item when it has a list marker or a
    /// list; and otherwise body text.
    private mutating func paragraphKind(of properties: RTFParagraphProperties) -> RTFBlockBuilder.Kind {
        let headingLevel: Int?
        if let outline = properties.outlineLevel {
            headingLevel = RTFStyleSheet.headingLevel(forOutlineLevel: outline)
        } else if let style = properties.style {
            headingLevel = styleSheet.headingLevel(ofStyle: style)
        } else {
            headingLevel = nil
        }
        if let headingLevel { return .heading(headingLevel) }

        let list = properties.listOverride ?? 0
        guard listMarker != nil || list > 0 else { return .body }
        let numbered: Bool
        if list > 0, let known = listTable.isNumbered(ls: list, level: properties.listLevel) {
            numbered = known
        } else if let marker = listMarker {
            // The table does not say: a marker with a letter or digit is a
            // number, and any other (a bullet) is not.
            numbered = marker.unicodeScalars.contains(where: TextutilPageBreaks.isCounted)
        } else {
            numbered = false
        }
        return .listItem(level: properties.listLevel, numbered: numbered)
    }

    /// `\par`: the paragraph ends.
    private mutating func endParagraph(inTable forcedInTable: Bool = false) throws {
        let properties = state.paragraph
        let kind = paragraphKind(of: properties)
        if case .heading = kind { hasNamedHeading = true }
        try builder.finishParagraph(kind, inTable: forcedInTable || properties.inTable)
        listMarker = nil
    }

    /// `\cell`: the cell ends.
    private mutating func endCell() {
        // The cell's last paragraph is a paragraph of the table whatever
        // its properties say.
        builder.endCell()
        listMarker = nil
    }

    /// `\row`: the row ends.
    private mutating func endRow() {
        builder.endRow()
        listMarker = nil
    }
}
