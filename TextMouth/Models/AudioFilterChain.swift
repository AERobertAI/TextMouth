import Foundation

// MARK: - A Filter Chain

/// A chain of audio filters in ffmpeg's filtergraph syntax (FR04):
/// `name=key=value:key=value,name2=value`, filters separated by commas, a
/// filter's options by colons, each option either `key=value` or a value
/// alone, taken in the order ffmpeg lists the filter's options. A value may
/// be quoted with single quotes or have a character escaped with a
/// backslash, so `afade=t=out:st='0:01:30'` keeps its time whole.
///
/// The same text serves both engines (`AudioFilterEngine`): the installed
/// ffmpeg takes it as it is, with every filter ffmpeg has, and TextMouth's
/// own engine runs the filters it implements (`AudioBuiltInFilter`), refusing
/// anything else with a sentence naming what it supports.
struct AudioFilterChain: Equatable, Sendable {
    /// One filter as written.
    struct Filter: Equatable, Sendable {
        /// Its name, as ffmpeg names it ("highpass"), without any "@id"
        /// instance name.
        let name: String
        /// Its options in the order written.
        let options: [Option]
    }

    /// One option as written: a key and a value, or a value alone.
    struct Option: Equatable, Sendable {
        /// The option's name, or nil for a value given by its place.
        let key: String?
        /// The value, unquoted and unescaped.
        let value: String
    }

    /// The chain as written.
    let text: String
    /// Its filters, in order.
    let filters: [Filter]

    /// The chain `text` holds.
    /// - Throws: `AudioFilterError.empty`, `.syntax` with a sentence saying
    ///   what is wrong, or `.needsFFmpeg` for a filtergraph with labels or
    ///   several chains, which only ffmpeg runs.
    static func parse(_ text: String) throws -> AudioFilterChain {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AudioFilterError.empty }
        let filters = try split(trimmed, on: ",").map(parseFilter)
        return AudioFilterChain(text: trimmed, filters: filters)
    }

    /// The filters TextMouth runs itself, each with its options checked.
    /// - Throws: `AudioFilterError` naming the first filter or option it
    ///   doesn't support, a value it can't use, or one it needs that isn't
    ///   given.
    func builtInFilters() throws -> [AudioBuiltInFilter] {
        try filters.map(AudioBuiltInFilter.init)
    }

    /// The filter `description` describes: its name, then, after "=", its
    /// options separated by colons.
    private static func parseFilter(_ description: String) throws -> Filter {
        let text = description.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            // Translators: Problem found in a typed filter chain (the audio editor's Apply Filter and the filter presets): two commas in a row leave a filter with nothing in it.
            throw AudioFilterError.syntax(InterfaceText.line("audioFilterChain.parseFilter.between", "There's an empty filter between two commas."))
        }
        if text.hasPrefix("[") || text.hasSuffix("]") || containsUnquoted(";", in: text) {
            throw AudioFilterError.needsFFmpeg
        }
        let parts = try split(text, on: "=", limit: 1)
        var name = unescape(parts[0]).trimmingCharacters(in: .whitespaces)
        // "volume@loud" names one instance of the filter: the filter is "volume".
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            // Translators: Problem found in a typed filter chain: the text before an equals sign is not a filter's name. %@ is that text.
            throw AudioFilterError.syntax(InterfaceText.line("audioFilterChain.parseFilter.isnt", "“\(parts[0])” isn't a filter's name."))
        }
        guard parts.count > 1 else { return Filter(name: name, options: []) }
        let options = try split(parts[1], on: ":").map { argument -> Option in
            let pieces = try split(argument, on: "=", limit: 1)
            if pieces.count == 2 {
                let key = unescape(pieces[0]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else {
                    // Translators: Problem found in a typed filter chain: an equals sign with nothing before it, in one filter's options. %@ is the filter's name, such as volume.
                    throw AudioFilterError.syntax(InterfaceText.line("audioFilterChain.parseFilter.option", "An option of the \(name) filter has a value but no name."))
                }
                return Option(key: key, value: unescape(pieces[1]))
            }
            return Option(key: nil, value: unescape(pieces[0]))
        }
        return Filter(name: name, options: options)
    }

    /// `text` split at each `separator` outside single quotes and not
    /// escaped by a backslash, at most `limit` times when given; quotes and
    /// escapes stay in the pieces, for `unescape(_:)`.
    /// - Throws: `AudioFilterError.syntax` for a quote left open.
    private static func split(_ text: String, on separator: Character, limit: Int? = nil) throws -> [String] {
        var pieces: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "'" {
                current.append(character)
                quoted.toggle()
            } else if character == separator, !quoted, limit.map({ pieces.count < $0 }) ?? true {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        // Translators: Problem found in a typed filter chain: a single quote is opened and never closed. %@ is the text of the part holding it.
        guard !quoted else { throw AudioFilterError.syntax(InterfaceText.line("audioFilterChain.split", "A quote isn't closed in “\(text)”.")) }
        pieces.append(current)
        return pieces
    }

    /// Whether `character` appears in `text` outside quotes and escapes.
    private static func containsUnquoted(_ character: Character, in text: String) -> Bool {
        ((try? split(text, on: character)) ?? []).count > 1
    }

    /// `text` with its quotes removed and its escapes resolved: the value it
    /// stands for.
    private static func unescape(_ text: String) -> String {
        var value = ""
        var quoted = false
        var escaped = false
        for character in text {
            if escaped {
                value.append(character)
                escaped = false
            } else if character == "\\" && !quoted {
                escaped = true
            } else if character == "'" {
                quoted.toggle()
            } else {
                value.append(character)
            }
        }
        return value
    }
}

// MARK: - Errors

/// Why a filter chain can't be run (FR04), as a sentence the editor shows
/// and VoiceOver reads as it stands.
enum AudioFilterError: LocalizedError, Equatable, Sendable {
    /// The chain is empty.
    case empty
    /// The chain isn't written in ffmpeg's syntax, as the sentence says.
    case syntax(String)
    /// A filtergraph with labels or several chains, which only ffmpeg runs.
    case needsFFmpeg
    /// A filter TextMouth's own engine doesn't have.
    case unknownFilter(String)
    /// An option a filter doesn't take: the filter, the option, and the
    /// options it takes, each as "f (frequency)".
    case unknownOption(filter: String, option: String, supported: [String])
    /// More values given by their place than the filter has options.
    case tooManyValues(filter: String)
    /// A value an option can't take: the filter, the option, the value, and
    /// what it takes.
    case badValue(filter: String, option: String, value: String, expected: String)
    /// An option a filter needs that wasn't given: the filter, the option, and what it takes.
    case missingValue(filter: String, option: String, expected: String)
    /// ffmpeg ran and refused the chain or the audio, as its own words say.
    case ffmpegFailed(String)
    /// ffmpeg couldn't be started at all.
    case ffmpegMissing

    var errorDescription: String? {
        switch self {
        case .empty:
            // Translators: Problem said when a filter chain is typed as nothing at all, in the audio editor's Apply Filter and the filter presets.
            return InterfaceText.line("audioFilterError.empty", "The filter chain is empty.")
        case .syntax(let sentence):
            return sentence
        case .needsFFmpeg:
            // Translators: Problem said of a filter graph with labels or semicolons, which only the ffmpeg program runs: TextMouth's own filters take a chain separated by commas.
            return InterfaceText.line("audioFilterError.needsFFmpeg", "Labels and semicolons need ffmpeg. TextMouth's own filters take one comma-separated chain.")
        case .unknownFilter(let name):
            // Translators: Problem said of a filter TextMouth doesn't run itself. %1$@ is the filter's name as typed, and %2$@ the list of the filters TextMouth does run, such as "a, b, and c".
            return InterfaceText.line("audioFilterError.unknownFilter", "TextMouth's own filters don't include “\(name)”. They are \(Self.list(AudioBuiltInFilter.names)); with ffmpeg installed, every filter it has works.")
        case .unknownOption(let filter, let option, let supported):
            // Translators: Problem said of an option a filter doesn't take. %1$@ is the filter's name, %2$@ the option as typed, and %3$@ the list of the options it takes.
            return InterfaceText.line("audioFilterError.unknownOption", "The \(filter) filter has no option “\(option)” here. Its options are \(Self.list(supported)).")
        case .tooManyValues(let filter):
            // Translators: Problem said when a filter is given more values than it has options. %@ is the filter's name. "key=value" is filter syntax and stays as it is.
            return InterfaceText.line("audioFilterError.tooManyValues", "The \(filter) filter was given more values than it has options; give them as key=value.")
        case .badValue(let filter, let option, let value, let expected):
            // Translators: Problem said of a value a filter's option can't take. %1$@ is the filter's name, %2$@ the option's name, %3$@ the value as typed, and %4$@ what the option takes, a clause such as "give a number from 0 to 1", written without its full stop.
            return InterfaceText.line("audioFilterError.badValue", "The \(filter) filter's \(option) can't be “\(value)”: \(expected).")
        case .missingValue(let filter, let option, let expected):
            // Translators: Problem said when a filter lacks an option it needs. %1$@ is the filter's name, %2$@ the option's name, and %3$@ what the option takes, a clause such as "give a time such as 2.5", written without its full stop.
            return InterfaceText.line("audioFilterError.missingValue", "The \(filter) filter needs its \(option): \(expected).")
        case .ffmpegFailed(let words):
            // Translators: Problem said when the ffmpeg program refused a filter chain or the audio. %@ is ffmpeg's own words, in English.
            return InterfaceText.line("audioFilterError.ffmpegFailed", "ffmpeg couldn't run the filters: \(words)")
        case .ffmpegMissing:
            // Translators: Problem said when the ffmpeg program can't be started. "Use ffmpeg" is the name of a switch in the Storage settings.
            return InterfaceText.line("audioFilterError.ffmpegMissing", "ffmpeg couldn't be started. Check it is installed, or turn off Use ffmpeg in Storage settings.")
        }
    }

    /// `items` as a list in words ("a, b, and c") through the one joiner,
    /// `CountWording.list`; "none" for an empty list, the filter messages' own word.
    private static func list(_ items: [String]) -> String {
        items.isEmpty
            // Translators: Said in place of a list of filters or options when there are none, inside a filter message such as "Its options are none."
            ? InterfaceText.line("audioFilterError.list", "none")
            : CountWording.list(items)
    }
}
