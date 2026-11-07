import Foundation

// MARK: - Reading Markup as SwiftSoup Reads It

/// One pass over markup's bytes that finds the same tags SwiftSoup's tokeniser
/// finds, in the same places, without building anything. `MarkupGuard` asks it
/// before SwiftSoup is handed the markup, so what the guard counts is what
/// SwiftSoup would go on to build.
///
/// It is a map of SwiftSoup 2.13.9's `TokeniserState` (MIT), and its fidelity
/// is the point: a tag the scanner cannot see is a level the guard cannot
/// count. So a text that looks like a tag but is not one (inside a comment, a
/// quoted attribute, or a style sheet) is passed over exactly where SwiftSoup
/// passes over it, and one that SwiftSoup reads oddly is read as oddly here:
/// a declaration ends at its first `>`, quoted or not, and `<!DOCTYPE >` does
/// not end at that `>`. `MarkupGuardFidelityTests` holds the two side by side.
///
/// Every byte is looked at a bounded number of times, so a pass is linear in
/// the size of the markup whatever the markup holds.
struct MarkupScanner {

    /// A start or end tag.
    struct Tag: Equatable {
        /// Where the name is in the bytes: as the markup spells it, in any letter case.
        var name: Range<Int>
        /// What follows the name, up to the tag's `>`: two start tags with the
        /// same bytes here have the same attributes.
        var attributes: Range<Int>
        /// How many attributes the tag names, a repeated one each time.
        var attributeCount: Int
        /// Whether the tag ends `/>`.
        var isSelfClosing: Bool
    }

    /// What the markup holds next.
    enum Token: Equatable {
        /// Words, or anything else that stands as text: a CDATA section, or a
        /// `<` that begins no tag.
        case text(Range<Int>)
        case startTag(Tag)
        case endTag(Tag)
        /// A comment, which SwiftSoup keeps as a node.
        case comment
        /// A document type declaration, which SwiftSoup's XML parser keeps as a node.
        case doctype
        /// What SwiftSoup calls a bogus comment: `<?…>`, `<!…>` that is not
        /// one of the three known forms, or `</…>` with no name. `data` is what
        /// SwiftSoup takes as the comment's text (it ends at the first `>`),
        /// and `whole` runs from its `<` through its `>`.
        case declaration(data: Range<Int>, whole: Range<Int>)
        /// The end of the markup.
        case finished
    }

    /// The states of SwiftSoup's tokeniser in which a tag cannot begin, which
    /// its tree builder turns on after certain start tags.
    enum RawText {
        /// `<title>`: text that an end tag ends, or the first thing that looks
        /// like a tag when no end tag follows at all (SwiftSoup's own departure from the
        /// HTML standard).
        case replaceable
        /// `<style>` and `<noframes>`: text that only their end tag ends.
        case plain
        /// `<script>`: as `plain`, but for the escapes `<!--` and `<script>` begin.
        case script
    }

    /// The markup.
    let bytes: [UInt8]
    /// How far the pass has come.
    private(set) var position = 0

    /// Where the last `</title` is (and `</TITLE`, since SwiftSoup looks for
    /// those two spellings alone), found once for the whole markup: a `<title>`
    /// asks whether an end tag still lies ahead at every `<` it holds.
    private lazy var lastTitleEnd: Int = lastOccurrence(of: "</title", or: "</TITLE")

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    // MARK: Data

    /// The next thing the markup holds, where tags may begin.
    mutating func next() -> Token {
        var textStart = position
        var cursor = position
        while true {
            let open = index(of: Ascii.lessThan, from: cursor)
            guard open < bytes.count else {
                position = bytes.count
                return textStart < bytes.count ? .text(textStart..<bytes.count) : .finished
            }
            switch markup(at: open) {
            case .none:
                // A "<" that stands as text.
                cursor = open + 1
            case .emptyEndTag:
                // "</>" is dropped: no token, and the text goes on after it.
                if open > textStart {
                    position = open + 3
                    return .text(textStart..<open)
                }
                textStart = open + 3
                cursor = textStart
                position = textStart
            case .some:
                if open > textStart {
                    position = open
                    return .text(textStart..<open)
                }
                position = open
                return readMarkup()
            }
        }
    }

    /// What a `<` at `open` begins.
    private enum Markup {
        case none, emptyEndTag, some
    }

    /// What the `<` at `open` begins, by the bytes after it.
    private func markup(at open: Int) -> Markup {
        guard open + 1 < bytes.count else { return .none }
        let next = bytes[open + 1]
        if Ascii.isLetter(next) || next == Ascii.bang || next == Ascii.question { return .some }
        guard next == Ascii.slash, open + 2 < bytes.count else { return .none }
        return bytes[open + 2] == Ascii.greaterThan ? .emptyEndTag : .some
    }

    /// Reads the markup whose `<` is at `position`, which `markup(at:)` found begins something.
    private mutating func readMarkup() -> Token {
        let open = position
        let next = bytes[open + 1]
        if Ascii.isLetter(next) {
            position = open + 1
            return readTag().map(Token.startTag) ?? .finished
        }
        if next == Ascii.question {
            // The "?" is the first of the comment's text.
            return readDeclaration(open: open, dataStart: open + 1)
        }
        if next == Ascii.bang {
            position = open + 2
            if consume("--") {
                skipComment()
                return .comment
            }
            if consumeIgnoringCase("doctype") {
                skipDoctype()
                return .doctype
            }
            if consume("[CDATA[") {
                let start = position
                let end = indexOf("]]>", from: start)
                position = min(end + 3, bytes.count)
                return .text(start..<end)
            }
            // After a "<!" that ends the markup, SwiftSoup steps back onto the "!".
            return readDeclaration(open: open, dataStart: open + 2 < bytes.count ? open + 2 : open + 1)
        }
        // "</", then a letter or something that begins no name.
        let afterSlash = bytes[open + 2]
        if Ascii.isLetter(afterSlash) {
            position = open + 2
            return readTag().map(Token.endTag) ?? .finished
        }
        return readDeclaration(open: open, dataStart: open + 2)
    }

    /// A bogus comment: its text runs from `dataStart` to the first `>`, and
    /// it ends there or with the markup.
    private mutating func readDeclaration(open: Int, dataStart: Int) -> Token {
        let close = index(of: Ascii.greaterThan, from: dataStart)
        position = min(close + 1, bytes.count)
        return .declaration(data: dataStart..<close, whole: open..<position)
    }

    // MARK: Comments and Doctypes

    /// Passes over a comment, from just after its `<!--`. It ends at `-->`,
    /// `--!>`, or the end of the markup, or at once at `>` or any run of dashes and `>`.
    private mutating func skipComment() {
        // Before any of the comment's text.
        while position < bytes.count, bytes[position] == Ascii.dash { position += 1 }
        guard position < bytes.count else { return }
        if bytes[position] == Ascii.greaterThan {
            position += 1
            return
        }
        while position < bytes.count {
            position = index(of: Ascii.dash, from: position)
            guard position < bytes.count else { return }
            position += 1
            // One dash: a second one begins the end.
            guard position < bytes.count, bytes[position] == Ascii.dash else { continue }
            position += 1
            // Two or more dashes: ">" ends the comment, and so does "!>".
            while position < bytes.count, bytes[position] == Ascii.dash { position += 1 }
            guard position < bytes.count else { return }
            if bytes[position] == Ascii.greaterThan {
                position += 1
                return
            }
            guard bytes[position] == Ascii.bang else { continue }
            position += 1
            guard position < bytes.count else { return }
            if bytes[position] == Ascii.greaterThan {
                position += 1
                return
            }
            // "--!-" goes back to having seen one dash; anything else is text.
            if bytes[position] == Ascii.dash {
                position += 1
                guard position < bytes.count, bytes[position] == Ascii.dash else { continue }
                // Having seen two dashes again: step back so the top of the loop finds them.
                position -= 1
            }
        }
    }

    /// Passes over a document type declaration, from just after `<!DOCTYPE`.
    /// It ends at its first `>` from its name on, quoted or not; the one thing
    /// that can pass over a `>` is the place a name should begin.
    private mutating func skipDoctype() {
        guard position < bytes.count else { return }
        // The character after the keyword is taken whatever it is, except that ">" ends the declaration.
        if bytes[position] == Ascii.greaterThan {
            position += 1
            return
        }
        advanceOneCharacter()
        // Where the name should begin: spaces are passed over, and the next
        // character begins the name, even a ">".
        while position < bytes.count, Ascii.isTagSpace(bytes[position]) { position += 1 }
        guard position < bytes.count else { return }
        if !Ascii.isLetter(bytes[position]) { advanceOneCharacter() }
        position = min(index(of: Ascii.greaterThan, from: position) + 1, bytes.count)
    }

    // MARK: Tags

    /// Reads a tag from its name at `position` through its `>`, or nil when
    /// the markup ends first, since SwiftSoup then emits no tag at all. A
    /// value that has begun but not ended at the end of the markup is the one
    /// way a tag is emitted without a `>`.
    private mutating func readTag() -> Tag? {
        let nameStart = position
        moveToTagNameEnd()
        let firstStretchEnd = position
        guard position < bytes.count else { return nil }
        // SwiftSoup looks ahead here, past spaces, for ">" or "/>", with spaces
        // between "/" and ">": the one place "/ >" closes a tag.
        var ahead = position
        while ahead < bytes.count, Ascii.isTagSpace(bytes[ahead]) { ahead += 1 }
        if ahead < bytes.count, bytes[ahead] == Ascii.greaterThan {
            position = ahead + 1
            return Tag(name: nameStart..<firstStretchEnd, attributes: firstStretchEnd..<ahead, attributeCount: 0, isSelfClosing: false)
        }
        if ahead < bytes.count, bytes[ahead] == Ascii.slash {
            var afterSlash = ahead + 1
            while afterSlash < bytes.count, Ascii.isTagSpace(bytes[afterSlash]) { afterSlash += 1 }
            if afterSlash < bytes.count, bytes[afterSlash] == Ascii.greaterThan {
                position = afterSlash + 1
                return Tag(name: nameStart..<firstStretchEnd, attributes: firstStretchEnd..<ahead, attributeCount: 0, isSelfClosing: true)
            }
        }
        // A NUL does not end a name, however it looks to the search above.
        while position < bytes.count, bytes[position] == 0 {
            position += 1
            moveToTagNameEnd()
        }
        let nameEnd = position
        var reader = TagReader()
        guard let end = reader.read(&self, state: .afterName) else { return nil }
        return Tag(
            name: nameStart..<nameEnd,
            attributes: nameEnd..<end.attributesEnd,
            attributeCount: reader.attributeCount,
            isSelfClosing: end.isSelfClosing
        )
    }

    /// Moves to the first byte that ends a tag's name: a space, `/`, `>`, a
    /// NUL, or the end of the markup.
    private mutating func moveToTagNameEnd() {
        while position < bytes.count {
            let byte = bytes[position]
            if Ascii.isTagSpace(byte) || byte == Ascii.slash || byte == Ascii.greaterThan || byte == 0 { return }
            position += 1
        }
    }

    /// Whether the character at `position` is one SwiftSoup keeps in an
    /// attribute's name: not a space, `/`, `=`, `>`, a NUL, or a quotation mark or `<`.
    private func isAttributeNameByte(_ byte: UInt8) -> Bool {
        !(Ascii.isTagSpace(byte) || byte == Ascii.slash || byte == Ascii.equals || byte == Ascii.greaterThan
            || byte == 0 || byte == Ascii.doubleQuote || byte == Ascii.singleQuote || byte == Ascii.lessThan)
    }

    /// Whether the byte ends a stretch of an unquoted value.
    private func endsUnquotedStretch(_ byte: UInt8) -> Bool {
        Ascii.isTagSpace(byte) || byte == Ascii.ampersand || byte == Ascii.greaterThan || byte == 0
            || byte == Ascii.doubleQuote || byte == Ascii.singleQuote || byte == Ascii.lessThan
            || byte == Ascii.equals || byte == Ascii.backtick
    }

    /// The states of a tag after its name, which SwiftSoup's fast paths and
    /// its plain states walk between; they differ on small things (whether a
    /// NUL is taken, whether `=` begins a value), and each is kept as it is.
    private enum TagState {
        /// Just after the tag's name, where SwiftSoup has not yet passed over anything.
        case afterName
        /// `BeforeAttributeName`: a new attribute may begin.
        case beforeAttribute
        /// `AfterAttributeName`: `=` would begin the value of the one just named.
        case afterAttribute
        /// `AttributeName`: within a name.
        case attributeName
        /// `BeforeAttributeValue`, after `=`.
        case beforeValue
        /// `SelfClosingStartTag`, after `/`.
        case selfClosing
    }

    /// Where a tag ended.
    private struct TagEnd {
        var attributesEnd: Int
        var isSelfClosing: Bool
    }

    /// The walk through a tag's states, counting what it names.
    private struct TagReader {
        /// The attributes named so far.
        var attributeCount = 0

        /// Walks from `state` until the tag ends, or nil when the markup ends first.
        mutating func read(_ scanner: inout MarkupScanner, state start: TagState) -> TagEnd? {
            var state = start
            let count = scanner.bytes.count
            while true {
                switch state {
                case .afterName:
                    guard scanner.position < count else { return nil }
                    let byte = scanner.bytes[scanner.position]
                    if Ascii.isTagSpace(byte) {
                        scanner.skipAdvancingSpaces()
                        state = .beforeAttribute
                    } else if byte == Ascii.slash {
                        scanner.position += 1
                        state = .selfClosing
                    } else if byte == Ascii.greaterThan {
                        scanner.position += 1
                        return TagEnd(attributesEnd: scanner.position - 1, isSelfClosing: false)
                    } else {
                        // Reached only past a NUL's name stretch, at a space, "/", or ">".
                        scanner.position += 1
                    }
                case .beforeAttribute, .afterAttribute:
                    // `consumeAttributesFast`: "=" begins a value only right
                    // after a name.
                    guard scanner.position < count else { return nil }
                    if Ascii.isTagSpace(scanner.bytes[scanner.position]) {
                        scanner.skipAdvancingSpaces()
                        guard scanner.position < count else { return nil }
                    }
                    let byte = scanner.bytes[scanner.position]
                    if state == .afterAttribute, byte == Ascii.equals {
                        scanner.position += 1
                        state = .beforeValue
                    } else if byte == Ascii.slash {
                        scanner.position += 1
                        state = .selfClosing
                    } else if byte == Ascii.greaterThan {
                        scanner.position += 1
                        return TagEnd(attributesEnd: scanner.position - 1, isSelfClosing: false)
                    } else if byte == 0 {
                        // Taken into a name, at once after a name, or by the name's own state.
                        if state == .afterAttribute { scanner.position += 1 }
                        attributeCount += 1
                        state = .attributeName
                    } else if byte == Ascii.doubleQuote || byte == Ascii.singleQuote
                        || byte == Ascii.lessThan || byte == Ascii.equals {
                        scanner.position += 1
                        attributeCount += 1
                        state = .attributeName
                    } else {
                        // `consumeAttributeNameAndValueFast`.
                        attributeCount += 1
                        while scanner.position < count, scanner.isAttributeNameByte(scanner.bytes[scanner.position]) {
                            scanner.position += 1
                        }
                        guard scanner.position < count else { return nil }
                        if Ascii.isTagSpace(scanner.bytes[scanner.position]) {
                            scanner.skipAdvancingSpaces()
                            guard scanner.position < count else { return nil }
                        }
                        let after = scanner.bytes[scanner.position]
                        if after == Ascii.equals {
                            scanner.position += 1
                            state = .beforeValue
                        } else if after == Ascii.slash {
                            scanner.position += 1
                            state = .selfClosing
                        } else if after == Ascii.greaterThan {
                            scanner.position += 1
                            return TagEnd(attributesEnd: scanner.position - 1, isSelfClosing: false)
                        } else if after == 0 || after == Ascii.doubleQuote || after == Ascii.singleQuote || after == Ascii.lessThan {
                            scanner.position += 1
                            state = .attributeName
                        } else {
                            state = .beforeAttribute
                        }
                    }
                case .attributeName:
                    // `readAttributeName`.
                    while scanner.position < count, scanner.isAttributeNameByte(scanner.bytes[scanner.position]) {
                        scanner.position += 1
                    }
                    guard scanner.position < count else { return nil }
                    let byte = scanner.bytes[scanner.position]
                    if Ascii.isTagSpace(byte) {
                        scanner.skipAdvancingSpaces()
                        state = .afterAttribute
                    } else if byte == Ascii.slash {
                        scanner.position += 1
                        state = .selfClosing
                    } else if byte == Ascii.equals {
                        scanner.position += 1
                        state = .beforeValue
                    } else if byte == Ascii.greaterThan {
                        scanner.position += 1
                        return TagEnd(attributesEnd: scanner.position - 1, isSelfClosing: false)
                    } else {
                        // A NUL, a quotation mark, or "<" stays in the name.
                        scanner.position += 1
                    }
                case .beforeValue:
                    // `consumeAttributeValueFast`. The markup's ending here is
                    // the one place SwiftSoup still emits the tag.
                    guard scanner.position < count else {
                        return TagEnd(attributesEnd: count, isSelfClosing: false)
                    }
                    if Ascii.isTagSpace(scanner.bytes[scanner.position]) {
                        scanner.skipAdvancingSpaces()
                        guard scanner.position < count else {
                            return TagEnd(attributesEnd: count, isSelfClosing: false)
                        }
                    }
                    let byte = scanner.bytes[scanner.position]
                    if byte == Ascii.doubleQuote || byte == Ascii.singleQuote {
                        // A quoted value runs to its own quotation mark; no
                        // reference to a character can run past one.
                        let close = scanner.index(of: byte, from: scanner.position + 1)
                        guard close < count else {
                            scanner.position = count
                            return nil
                        }
                        scanner.position = close + 1
                        // `handleAfterQuotedValueFast`.
                        guard scanner.position < count else { return nil }
                        let after = scanner.bytes[scanner.position]
                        if Ascii.isTagSpace(after) {
                            scanner.skipAdvancingSpaces()
                            state = .beforeAttribute
                        } else if after == Ascii.slash {
                            scanner.position += 1
                            state = .selfClosing
                        } else if after == Ascii.greaterThan {
                            scanner.position += 1
                            return TagEnd(attributesEnd: scanner.position - 1, isSelfClosing: false)
                        } else {
                            state = .beforeAttribute
                        }
                    } else if byte == Ascii.greaterThan {
                        scanner.position += 1
                        return TagEnd(attributesEnd: scanner.position - 1, isSelfClosing: false)
                    } else {
                        // `consumeUnquotedAttributeValueFast`. A NUL, "<", "=", and "`"
                        // are taken into the value; so is anything before its end.
                        if byte == 0 || byte == Ascii.lessThan || byte == Ascii.equals || byte == Ascii.backtick {
                            scanner.position += 1
                        }
                        unquoted: while true {
                            while scanner.position < count, !scanner.endsUnquotedStretch(scanner.bytes[scanner.position]) {
                                scanner.position += 1
                            }
                            guard scanner.position < count else { return nil }
                            let stop = scanner.bytes[scanner.position]
                            if Ascii.isTagSpace(stop) {
                                scanner.skipAdvancingSpaces()
                                state = .beforeAttribute
                                break unquoted
                            }
                            if stop == Ascii.greaterThan {
                                scanner.position += 1
                                return TagEnd(attributesEnd: scanner.position - 1, isSelfClosing: false)
                            }
                            // "&", a NUL, a quotation mark, "<", "=", or "`".
                            scanner.position += 1
                        }
                    }
                case .selfClosing:
                    guard scanner.position < count else { return nil }
                    if scanner.bytes[scanner.position] == Ascii.greaterThan {
                        scanner.position += 1
                        return TagEnd(attributesEnd: scanner.position - 2, isSelfClosing: true)
                    }
                    state = .beforeAttribute
                }
            }
        }
    }

    /// Passes over the run of spaces SwiftSoup's `advanceAsciiWhitespace` takes,
    /// which, unlike the test that sends it there, includes a vertical tab.
    private mutating func skipAdvancingSpaces() {
        while position < bytes.count, Ascii.isTagSpace(bytes[position]) || bytes[position] == Ascii.verticalTab {
            position += 1
        }
    }

    // MARK: Raw Text

    /// Passes over the text of the element whose start tag `name` (in lower
    /// case) has just been read, up to and including its end tag.
    /// - Returns: the end tag, or `.finished` when the markup ends first.
    mutating func skipRawText(_ kind: RawText, name: String) -> Token {
        let endName = Array(name.utf8)
        switch kind {
        case .replaceable: return skipReplaceableText(endName: endName)
        case .plain: return skipPlainText(endName: endName)
        case .script: return skipScript(endName: endName)
        }
    }

    /// `Rcdata` and its neighbors.
    private mutating func skipReplaceableText(endName: [UInt8]) -> Token {
        while true {
            position = index(of: Ascii.lessThan, from: position)
            guard position < bytes.count else { return .finished }
            position += 1
            guard position < bytes.count else { return .finished }
            let byte = bytes[position]
            if byte == Ascii.slash {
                position += 1
                guard position < bytes.count, Ascii.isLetter(bytes[position]) else { continue }
                let nameStart = position
                position += 1
                moveOverEndTagLetters()
                let isAppropriate = namesMatch(nameStart..<position, endName)
                guard isAppropriate, position < bytes.count else { continue }
                let after = bytes[position]
                if Ascii.isTagSpace(after) || after == Ascii.slash || after == Ascii.greaterThan {
                    return readRawEndTag(name: nameStart..<position)
                }
                // Anything else after the name is text, and is read as text.
            } else if Ascii.isLetter(byte), position > lastTitleEnd {
                // No end tag lies ahead: SwiftSoup makes one up, and the "<" is read again as a tag's.
                position -= 1
                return .endTag(Tag(name: position..<position, attributes: position..<position, attributeCount: 0, isSelfClosing: false))
            }
        }
    }

    /// Reads an end tag whose name, just read, was the one the text awaits,
    /// from the space, `/`, or `>` after it.
    private mutating func readRawEndTag(name: Range<Int>) -> Token {
        let after = bytes[position]
        position += 1
        var reader = TagReader()
        let state: TagState = after == Ascii.slash ? .selfClosing : .beforeAttribute
        let ending = after == Ascii.greaterThan
            ? TagEnd(attributesEnd: position - 1, isSelfClosing: false)
            : reader.read(&self, state: state)
        guard let end = ending else {
            position = bytes.count
            return .finished
        }
        return .endTag(Tag(
            name: name, attributes: name.upperBound..<end.attributesEnd,
            attributeCount: reader.attributeCount, isSelfClosing: end.isSelfClosing
        ))
    }

    /// `Rawtext` and its neighbors.
    private mutating func skipPlainText(endName: [UInt8]) -> Token {
        while true {
            position = index(of: Ascii.lessThan, from: position)
            guard position < bytes.count else { return .finished }
            position += 1
            guard position < bytes.count, bytes[position] == Ascii.slash else { continue }
            position += 1
            if let token = endTagInRawText(endName: endName) { return token }
        }
    }

    /// `handleDataEndTag`, from just after `</`: the end tag the text awaits,
    /// or nil to go on reading text. SwiftSoup takes the character after
    /// a matching name into the text when it is neither a space, `/`, nor `>`,
    /// so `</style</style>` holds no end tag.
    private mutating func endTagInRawText(endName: [UInt8]) -> Token? {
        guard position < bytes.count, Ascii.isLetter(bytes[position]) else { return nil }
        let nameStart = position
        moveOverEndTagLetters()
        guard namesMatch(nameStart..<position, endName), position < bytes.count else { return nil }
        let after = bytes[position]
        if Ascii.isTagSpace(after) || after == Ascii.slash || after == Ascii.greaterThan {
            return readRawEndTag(name: nameStart..<position)
        }
        advanceOneCharacter()
        return nil
    }

    /// `ScriptData` and its neighbors: `<!--` escapes the text, within which
    /// `<script` escapes it twice and hides an end tag, until `</script` undoes that.
    private mutating func skipScript(endName: [UInt8]) -> Token {
        /// The script states, without the ones a dash or `<` is halfway through.
        enum State { case data, escaped, doubleEscaped }
        var state = State.data
        var dashes = 0
        while position < bytes.count {
            let byte = bytes[position]
            switch state {
            case .data:
                position = index(of: Ascii.lessThan, from: position)
                guard position < bytes.count else { return .finished }
                position += 1
                guard position < bytes.count else { return .finished }
                if bytes[position] == Ascii.slash {
                    position += 1
                    if let token = endTagInRawText(endName: endName) { return token }
                } else if bytes[position] == Ascii.bang {
                    position += 1
                    // "<!--" begins an escape; one dash or none does not.
                    guard position < bytes.count, bytes[position] == Ascii.dash else { continue }
                    position += 1
                    guard position < bytes.count, bytes[position] == Ascii.dash else { continue }
                    position += 1
                    state = .escaped
                    dashes = 2
                }
            case .escaped, .doubleEscaped:
                if byte == Ascii.dash {
                    dashes += 1
                    position += 1
                } else if byte == Ascii.greaterThan, dashes >= 2 {
                    // "-->" ends the escape.
                    position += 1
                    state = .data
                    dashes = 0
                } else if byte == Ascii.lessThan {
                    dashes = 0
                    position += 1
                    guard position < bytes.count else { return .finished }
                    if state == .escaped {
                        if bytes[position] == Ascii.slash {
                            position += 1
                            if let token = endTagInRawText(endName: endName) { return token }
                        } else if Ascii.isLetter(bytes[position]) {
                            if isScriptWordHere() { state = .doubleEscaped }
                        }
                    } else if bytes[position] == Ascii.slash {
                        position += 1
                        if isScriptWordHere() { state = .escaped }
                    }
                } else {
                    dashes = 0
                    advanceOneCharacter()
                }
            }
        }
        return .finished
    }

    /// `handleDataDoubleEscapeTag`: passes over a word, and over the space,
    /// `/`, or `>` after it; whether the word was exactly `script`.
    private mutating func isScriptWordHere() -> Bool {
        let start = position
        moveOverEndTagLetters()
        guard position < bytes.count else { return false }
        let after = bytes[position]
        guard Ascii.isTagSpace(after) || after == Ascii.slash || after == Ascii.greaterThan else { return false }
        position += 1
        return bytes[start..<(position - 1)].elementsEqual("script".utf8)
    }

    /// Passes over the letters of a name in raw text as SwiftSoup's
    /// `consumeLetterSequence` does: it runs on from an ASCII letter through
    /// any letter at all, but no letter past ASCII can begin a run.
    private mutating func moveOverEndTagLetters() {
        while position < bytes.count, Ascii.isLetter(bytes[position]) {
            while position < bytes.count {
                if Ascii.isLetter(bytes[position]) {
                    position += 1
                    continue
                }
                guard bytes[position] >= 0x80, let scalarEnd = endOfLetterAtPosition() else { break }
                position = scalarEnd
            }
        }
    }

    /// Where the letter past ASCII at `position` ends, or nil when the character is no letter.
    private func endOfLetterAtPosition() -> Int? {
        var decoder = UTF8()
        var iterator = bytes[position...].makeIterator()
        guard case let .scalarValue(scalar) = decoder.decode(&iterator), CharacterSet.letters.contains(scalar) else { return nil }
        return position + UTF8.width(scalar)
    }

    /// Whether the name at `range` is `name`, in any ASCII letter case.
    private func namesMatch(_ range: Range<Int>, _ name: [UInt8]) -> Bool {
        guard range.count == name.count else { return false }
        return zip(bytes[range], name).allSatisfy { Ascii.lowercased($0) == $1 }
    }

    // MARK: Searching

    /// Whether the bytes of `text` are at `position`; if so, passes over them.
    private mutating func consume(_ text: StaticString) -> Bool {
        let length = text.utf8CodeUnitCount
        guard position + length <= bytes.count else { return false }
        let matched = text.withUTF8Buffer { word in
            (0..<length).allSatisfy { bytes[position + $0] == word[$0] }
        }
        if matched { position += length }
        return matched
    }

    /// As `consume(_:)`, in any ASCII letter case; `text` is in lower case.
    private mutating func consumeIgnoringCase(_ text: StaticString) -> Bool {
        let length = text.utf8CodeUnitCount
        guard position + length <= bytes.count else { return false }
        let matched = text.withUTF8Buffer { word in
            (0..<length).allSatisfy { Ascii.lowercased(bytes[position + $0]) == word[$0] }
        }
        if matched { position += length }
        return matched
    }

    /// Passes over one character, however many bytes it takes.
    private mutating func advanceOneCharacter() {
        guard position < bytes.count else { return }
        let lead = bytes[position]
        let width = lead < 0x80 ? 1 : lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        position = min(position + width, bytes.count)
    }

    /// The index of the next `byte` at or after `start`, or the end of the markup.
    private func index(of byte: UInt8, from start: Int) -> Int {
        guard start < bytes.count else { return bytes.count }
        return bytes.withUnsafeBufferPointer { buffer -> Int in
            // The search stays inside the buffer: `start` is checked above.
            guard let base = buffer.baseAddress,
                  let found = memchr(base + start, Int32(byte), buffer.count - start) else { return buffer.count }
            return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
        }
    }

    /// The index of the next `text` at or after `start`, or the end of the markup.
    private func indexOf(_ text: StaticString, from start: Int) -> Int {
        let length = text.utf8CodeUnitCount
        return text.withUTF8Buffer { word -> Int in
            var cursor = start
            while cursor + length <= bytes.count {
                cursor = index(of: word[0], from: cursor)
                guard cursor + length <= bytes.count else { break }
                if (0..<length).allSatisfy({ bytes[cursor + $0] == word[$0] }) { return cursor }
                cursor += 1
            }
            return bytes.count
        }
    }

    /// Where the last of the two spellings is, or -1 when neither is there.
    private func lastOccurrence(of lower: StaticString, or upper: StaticString) -> Int {
        let length = lower.utf8CodeUnitCount
        var cursor = bytes.count - length
        return lower.withUTF8Buffer { lowerWord in
            upper.withUTF8Buffer { upperWord in
                while cursor >= 0 {
                    if bytes[cursor] == Ascii.lessThan,
                       (0..<length).allSatisfy({ bytes[cursor + $0] == lowerWord[$0] })
                        || (0..<length).allSatisfy({ bytes[cursor + $0] == upperWord[$0] }) {
                        return cursor
                    }
                    cursor -= 1
                }
                return -1
            }
        }
    }

    /// What the rest of the markup could possibly hold, whatever state it is
    /// read in: how many times `<` and a letter come (a start tag at each, at
    /// most), and how many times `<`, or `</`, and a letter do (a tag at each).
    func tagsPossiblyAhead() -> (starts: Int, tags: Int) {
        var starts = 0, tags = 0
        var cursor = position
        while cursor < bytes.count {
            cursor = index(of: Ascii.lessThan, from: cursor)
            guard cursor + 1 < bytes.count else { break }
            if Ascii.isLetter(bytes[cursor + 1]) {
                starts += 1
                tags += 1
            } else if bytes[cursor + 1] == Ascii.slash {
                tags += 1
            }
            cursor += 1
        }
        return (starts, tags)
    }

    /// Whether the name at `range` reads as text in lower case, with ASCII
    /// letters alone changed, as SwiftSoup's HTML parser normalizes a name.
    func lowercasedName(_ range: Range<Int>) -> String {
        String(decoding: bytes[range].map(Ascii.lowercased), as: UTF8.self)
    }

    /// Passes over everything left, once the rest of the markup can hold no tag.
    mutating func skipToEnd() {
        position = bytes.count
    }
}

// MARK: - ASCII

/// The bytes markup is made of.
enum Ascii {
    static let lessThan = UInt8(ascii: "<")
    static let greaterThan = UInt8(ascii: ">")
    static let slash = UInt8(ascii: "/")
    static let bang = UInt8(ascii: "!")
    static let question = UInt8(ascii: "?")
    static let dash = UInt8(ascii: "-")
    static let equals = UInt8(ascii: "=")
    static let ampersand = UInt8(ascii: "&")
    static let doubleQuote = UInt8(ascii: "\"")
    static let singleQuote = UInt8(ascii: "'")
    static let backtick = UInt8(ascii: "`")
    static let verticalTab: UInt8 = 0x0B

    /// Whether `byte` is an ASCII letter.
    static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    /// Whether `byte` is one of the five characters that separate things in a tag.
    static func isTagSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    /// `byte` with an ASCII capital in lower case.
    static func lowercased(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
    }
}
