import Foundation

/// TextMouth's own lookup of the words the interface shows (FR39): the namespace of its call, `InterfaceText.line`
/// (in `InterfaceTextLine.swift`), and of the type a call's English is written in, `InterfaceText.Format`.
///
/// A caseless enum, shared by both apps. This file and the other core files of the system (the pack reader, the
/// plural rules, the specifier check, the lookup) use Foundation, the Compression framework, and `os` only, and no
/// type of the app, so that a command-line probe can compile them.
enum InterfaceText {
    /// The English of one line as the code writes it, with the arguments it was given: the call's side of a lookup.
    ///
    /// Written as a string literal, which is how a call site gives it, an interpolation takes one of two forms only:
    /// - `\(text)`, any string, adds `%@`;
    /// - `\(number: n)`, any integer, adds `%lld`.
    ///
    /// Nothing else compiles (a `Double`, an enum, an `Int` without `number:`), so the format equals, character for
    /// character, the key Xcode extracts from `String(localized:)` today. In a literal with interpolations, a `%` in a
    /// literal segment is doubled, so the format reads back as the text the code wrote; a literal with none is kept
    /// as written, since it has no arguments and never reaches the formatter.
    struct Format: ExpressibleByStringInterpolation, Sendable, Equatable {
        /// One argument of the call, in the order of its specifiers.
        enum Argument: Sendable, Equatable {
            /// A string, the value of a `%@`.
            case text(String)
            /// An integer, the value of a `%lld`.
            case number(Int64)
        }

        /// The format string in the form `String(format:locale:arguments:)` reads: `%@`, `%lld`, and `%%`.
        let format: String

        /// The arguments, in order.
        let arguments: [Argument]

        /// The first number among the arguments: the count that picks the form of a plural line.
        var firstNumber: Int64? {
            for argument in arguments {
                if case .number(let value) = argument { return value }
            }
            return nil
        }

        /// A format from its parts; the interpolation and the literal initializers use it.
        init(format: String, arguments: [Argument]) {
            self.format = format
            self.arguments = arguments
        }

        /// A plain literal, with no interpolation: the text exactly as written, `%` included, and no arguments. A line
        /// with no arguments is never given to Foundation's formatter, so nothing in it is a specifier; this is what
        /// `String.LocalizationValue(stringLiteral:)` does, and `String(localized:)` formats only with arguments.
        init(stringLiteral value: String) {
            self.init(format: value, arguments: [])
        }

        /// A literal with interpolations, collected by `StringInterpolation`.
        init(stringInterpolation: StringInterpolation) {
            self.init(format: stringInterpolation.format, arguments: stringInterpolation.arguments)
        }

        /// `value` with each `%` doubled, so Foundation's formatter reads it back as a `%`.
        static func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "%", with: "%%")
        }

        /// The arguments as Foundation's formatter takes them: a string as an `NSString` (the object a `%@` reads),
        /// an integer as an `Int64` (what a `%lld` reads).
        var formatterArguments: [CVarArg] {
            arguments.map { argument -> CVarArg in
                switch argument {
                case .text(let text): return text as NSString
                case .number(let number): return number
                }
            }
        }

        /// What a literal with interpolations is built from, one piece at a time.
        struct StringInterpolation: StringInterpolationProtocol {
            /// The format so far.
            fileprivate(set) var format = ""
            /// The arguments so far.
            fileprivate(set) var arguments: [Argument] = []

            // The four builders below are never inlined. Inlined, they put a copy of the string growth, the arguments
            // array, and its appends into every call site that interpolates. In a probe of 400 sites of each kind
            // compiled with -Osize, a line with `\(text)` fell from 213 to 92 bytes, one with `\(number:)` from 189
            // to 92, and one with two numbers from 252 to 100; the Release apps shrank by 526,000 bytes (Mac) and
            // 228,838 (iPhone). `Format.init(stringLiteral:)` stays inlined, which keeps a plain line at 32 bytes.

            /// Room for the literal text, and for the longest specifier (`%lld`) at each interpolation.
            @inline(never)
            init(literalCapacity: Int, interpolationCount: Int) {
                format.reserveCapacity(literalCapacity + 4 * interpolationCount)
            }

            /// A literal segment: its text with each `%` doubled.
            @inline(never) // See the note above the initializer.
            mutating func appendLiteral(_ literal: String) {
                format += Format.escaped(literal)
            }

            /// `\(text)`: a string, as `%@`.
            @inline(never) // See the note above the initializer.
            mutating func appendInterpolation(_ text: some StringProtocol) {
                format += "%@"
                arguments.append(.text(String(text)))
            }

            /// `\(number: n)`: an integer, as `%lld`. One too large for 64 bits is held at the largest, never trapped on.
            @inline(never) // See the note above the initializer.
            mutating func appendInterpolation(number: some BinaryInteger) {
                format += "%lld"
                arguments.append(.number(Int64(clamping: number)))
            }
        }
    }
}
