import Foundation

// MARK: - A Link's Address in an EPUB (B5)

/// Makes the address of a link in a book's text an address EPUB's validator
/// accepts, or says it cannot.
///
/// A link in content.md may hold any characters (a space, a bar, brackets, a
/// second "#", letters beyond ASCII), and one address that is not a URL fails
/// the whole EPUB (EPUBCheck RSC-020). The EPUB writer is the only one asked
/// to be a valid package, so the others write addresses as they always did.
/// `url(from:)` percent-encodes everything that can be encoded; where the
/// address still is not a URL (no host, a port that is no number, a host that
/// is not made of letters, digits, dots, and hyphens), the writer leaves the
/// link's words without the link, as it does for a `javascript:` address.
enum EPUBLinkAddress {
    /// The characters RFC 3986 lets stand anywhere in a path, query, or
    /// fragment: unreserved characters and sub-delimiters, ":", "@", "/", and "?".
    private static let allowedInTail = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/?")
    /// What may stand in the user information: the above without "@", "/", and "?".
    private static let allowedInUserInfo = allowedInTail.subtracting(["@", "/", "?"])
    /// What may stand in an address's host.
    private static let allowedInHost = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// `address` as a URL with a web or mail scheme, or nil when it cannot be
    /// made one. White space at either end is ignored.
    static func url(from address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let scheme = trimmed[..<colon].lowercased()
        let rest = trimmed[trimmed.index(after: colon)...]
        switch scheme {
        case "http", "https":
            return webURL(scheme: scheme, rest: rest)
        case "mailto":
            // The address may not be empty; what follows "?" is the query.
            let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            guard let mailbox = parts.first, !mailbox.isEmpty else { return nil }
            let query = parts.count > 1 ? "?" + encoded(parts[1], allowing: allowedInTail, keepsOneHash: true) : ""
            return "mailto:" + encoded(mailbox, allowing: allowedInTail, keepsOneHash: false) + query
        default:
            return nil
        }
    }

    /// An http or https URL of `scheme` and `rest` (what follows the colon):
    /// "//", an authority, and a path, query, and fragment.
    private static func webURL(scheme: String, rest: Substring) -> String? {
        guard rest.hasPrefix("//") else { return nil }
        let afterSlashes = rest.dropFirst(2)
        let authorityEnd = afterSlashes.firstIndex(where: { "/?#".contains($0) }) ?? afterSlashes.endIndex
        let authority = afterSlashes[..<authorityEnd]
        let tail = afterSlashes[authorityEnd...]

        // User information ends at the last "@"; a host and a port follow.
        var hostAndPort = authority
        var userInfo = ""
        if let at = authority.lastIndex(of: "@") {
            userInfo = encoded(authority[..<at], allowing: allowedInUserInfo, keepsOneHash: false) + "@"
            hostAndPort = authority[authority.index(after: at)...]
        }
        guard let (host, port) = hostAndPortParts(hostAndPort) else { return nil }
        return "\(scheme)://\(userInfo)\(host)\(port)" + encoded(tail, allowing: allowedInTail, keepsOneHash: true)
    }

    /// The host and the ":port" of `text`, or nil when the host is empty or
    /// holds anything but letters, digits, dots, hyphens, underscores, and
    /// tildes (or an IPv6 address in brackets), or the port is no number.
    private static func hostAndPortParts(_ text: Substring) -> (host: String, port: String)? {
        var host = text
        var port = ""
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let literal = text[text.index(after: text.startIndex)..<close]
            guard !literal.isEmpty, literal.allSatisfy({ ($0.isASCII && $0.isHexDigit) || $0 == ":" || $0 == "." }) else { return nil }
            host = text[...close]
            let after = text[text.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { return nil }
                port = String(after)
            }
        } else {
            if let colon = text.lastIndex(of: ":") {
                host = text[..<colon]
                port = String(text[colon...])
            }
            guard !host.isEmpty, host.allSatisfy({ allowedInHost.contains($0) }) else { return nil }
        }
        // ":" and a number of at most 65535, or nothing.
        let digits = port.dropFirst()
        guard port.isEmpty || ((1...5).contains(digits.count)
            && digits.allSatisfy({ $0.isASCII && $0.isNumber })
            && (Int(digits) ?? Int.max) <= 65_535) else {
            return nil
        }
        return (String(host), port)
    }

    /// Whether `character` is an ASCII hexadecimal digit (`isHexDigit` also
    /// takes the fullwidth forms, which no URL allows).
    private static func isASCIIHexDigit(_ character: Character) -> Bool {
        character.isASCII && character.isHexDigit
    }

    /// `text` with every character not in `allowed` written as the percent
    /// escapes of its UTF-8 bytes, and every "%" that does not begin an escape
    /// of two hexadecimal digits written as "%25". The first "#" stays when
    /// `keepsOneHash` (the fragment begins there); any other is escaped, as
    /// is a "[" or "]" (valid only around an IPv6 host).
    private static func encoded(_ text: Substring, allowing allowed: Set<Character>, keepsOneHash: Bool) -> String {
        var result = ""
        var hasHash = false
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if allowed.contains(character) {
                result.append(character)
            } else if character == "#", keepsOneHash, !hasHash {
                hasHash = true
                result.append(character)
            } else if character == "%", index + 2 < characters.count,
                      Self.isASCIIHexDigit(characters[index + 1]), Self.isASCIIHexDigit(characters[index + 2]) {
                result.append(character)
            } else {
                for byte in String(character).utf8 {
                    result += "%" + (byte < 16 ? "0" : "") + String(byte, radix: 16, uppercase: true)
                }
            }
        }
        return result
    }
}
