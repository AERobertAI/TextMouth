import Foundation

/// The check of a text's format specifiers against the arguments a call gives, which every text passes before it can
/// reach Foundation's formatter (FR39). `String(format:)` crashes or reads memory it should not on a specifier it was
/// not given an argument for (`%s`, `%n`, `%5$@` with one argument, `%@` given a number), so a text from a pack or from
/// the person's own file is never trusted: only these five forms are allowed, and only for the arguments at hand.
///
/// The five specifiers: `%%`, `%@`, `%lld`, and the numbered `%n$@` and `%n$lld`.
///
/// Foundation only, no stored state.
enum FormatSpecifiers {
    /// What a specifier reads: a string or an integer.
    enum Kind: Sendable, Equatable {
        case text
        case number
    }

    /// One specifier of a text: its argument number (1-based) when it has one, and the kind of argument it reads.
    struct Slot: Sendable, Equatable {
        let position: Int?
        let kind: Kind
    }

    /// The largest argument number a numbered specifier may name: far above any call's, so the digits cannot overflow.
    private static let largestPosition = 99

    /// The specifiers of `text` in order, `%%` skipped; nil when the text holds anything else after a `%`: a lone `%`,
    /// another conversion (`%s`, `%d`, `%n`, `%f`), flags, a width, a precision, or a malformed number.
    static func slots(in text: String) -> [Slot]? {
        // The scan works on UTF-8 bytes: every character it looks for is ASCII, and an ASCII byte never occurs
        // inside another character's bytes.
        let bytes = Array(text.utf8)
        var found: [Slot] = []
        var index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "%") else { index += 1; continue }
            index += 1
            guard index < bytes.count else { return nil }  // a lone `%` at the end
            if bytes[index] == UInt8(ascii: "%") { index += 1; continue }
            // An optional argument number: one to two digits and a dollar sign.
            var position: Int?
            var digitsEnd = index
            while digitsEnd < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[digitsEnd]) { digitsEnd += 1 }
            if digitsEnd > index {
                guard digitsEnd - index <= 2, digitsEnd < bytes.count, bytes[digitsEnd] == UInt8(ascii: "$"),
                      let number = Int(String(decoding: bytes[index..<digitsEnd], as: UTF8.self)),
                      (1...largestPosition).contains(number)
                else { return nil }
                position = number
                index = digitsEnd + 1
            }
            // The conversion: `@` for a string, `lld` for an integer.
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: "@") {
                found.append(Slot(position: position, kind: .text))
                index += 1
            } else if index + 2 < bytes.count, bytes[index] == UInt8(ascii: "l"), bytes[index + 1] == UInt8(ascii: "l"),
                      bytes[index + 2] == UInt8(ascii: "d") {
                found.append(Slot(position: position, kind: .number))
                index += 3
            } else {
                return nil
            }
        }
        return found
    }

    /// Whether `text` may be handed to Foundation's formatter with arguments of these kinds:
    /// - only the five specifiers appear;
    /// - numbered and unnumbered specifiers are not mixed;
    /// - an unnumbered specifier reads the arguments in order, so the nth reads the nth;
    /// - a numbered specifier names an argument the call gives;
    /// - each specifier's kind is its argument's kind.
    ///
    /// A text may leave an argument unused (a plural's `one` form often drops its number: "un libro").
    static func accepts(_ text: String, arguments: [Kind]) -> Bool {
        guard let slots = slots(in: text) else { return false }
        let numbered = slots.filter { $0.position != nil }.count
        guard numbered == 0 || numbered == slots.count else { return false }
        for (order, slot) in slots.enumerated() {
            // The 0-based argument the specifier reads.
            let argument = (slot.position ?? (order + 1)) - 1
            guard arguments.indices.contains(argument), arguments[argument] == slot.kind else { return false }
        }
        return true
    }

    /// The kinds of a call's arguments, in order.
    static func kinds(of arguments: [InterfaceText.Format.Argument]) -> [Kind] {
        arguments.map { argument in
            switch argument {
            case .text: return .text
            case .number: return .number
            }
        }
    }
}
