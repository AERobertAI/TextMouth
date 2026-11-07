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
            throw AudioFilterError.syntax("There's an empty filter between two commas.")
        }
        if text.hasPrefix("[") || text.hasSuffix("]") || containsUnquoted(";", in: text) {
            throw AudioFilterError.needsFFmpeg
        }
        let parts = try split(text, on: "=", limit: 1)
        var name = unescape(parts[0]).trimmingCharacters(in: .whitespaces)
        // "volume@loud" names one instance of the filter: the filter is "volume".
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            throw AudioFilterError.syntax("“\(parts[0])” isn't a filter's name.")
        }
        guard parts.count > 1 else { return Filter(name: name, options: []) }
        let options = try split(parts[1], on: ":").map { argument -> Option in
            let pieces = try split(argument, on: "=", limit: 1)
            if pieces.count == 2 {
                let key = unescape(pieces[0]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else {
                    throw AudioFilterError.syntax("An option of the \(name) filter has a value but no name.")
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
        guard !quoted else { throw AudioFilterError.syntax("A quote isn't closed in “\(text)”.") }
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
            return "The filter chain is empty."
        case .syntax(let sentence):
            return sentence
        case .needsFFmpeg:
            return "Labels and semicolons in a filter graph need ffmpeg. TextMouth's own filters take one chain of "
                + "filters separated by commas."
        case .unknownFilter(let name):
            return "TextMouth's own filters don't include “\(name)”. They are "
                + Self.list(AudioBuiltInFilter.names) + "; with ffmpeg installed, every filter it has works."
        case .unknownOption(let filter, let option, let supported):
            return "The \(filter) filter has no option “\(option)” here. Its options are \(Self.list(supported))."
        case .tooManyValues(let filter):
            return "The \(filter) filter was given more values than it has options; give them as key=value."
        case .badValue(let filter, let option, let value, let expected):
            return "The \(filter) filter's \(option) can't be “\(value)”: \(expected)."
        case .missingValue(let filter, let option, let expected):
            return "The \(filter) filter needs its \(option): \(expected)."
        case .ffmpegFailed(let words):
            return "ffmpeg couldn't run the filters: \(words)"
        case .ffmpegMissing:
            return "ffmpeg couldn't be started. Check that it is still installed, or turn off Use ffmpeg in Storage settings."
        }
    }

    /// `items` as a list in words ("a, b, and c") through the one joiner,
    /// `CountWording.list`; "none" for an empty list, the filter messages' own word.
    private static func list(_ items: [String]) -> String {
        items.isEmpty ? "none" : CountWording.list(items)
    }
}
