import Foundation

// MARK: - A Password That Cannot Be Logged

/// A password, or a key made from one (FR41). Its description and its debug
/// description say only "redacted", so a password interpolated into a log
/// line, an error, or a test failure prints nothing of itself, and the
/// type has no `Codable` conformance, so none can be written to a file by
/// accident. (There is no rule in `LogContentPolicyTests` for it: a
/// `Secret` interpolates as "redacted", which is what keeps it out of a log.)
///
/// Held as UTF-8 bytes, which `wipe()` overwrites with `memset_s` (a plain
/// loop may be optimized away). A `String` made from it (`text`) lives only
/// as long as its caller keeps it, and Swift cannot wipe one, so nothing
/// keeps a password as a `String` longer than a sheet or an unlock needs.
struct Secret: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The password's UTF-8 bytes, as typed.
    private(set) var bytes: [UInt8]

    /// A secret holding `text`, as typed.
    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    /// A secret holding exactly `bytes`.
    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Whether the secret holds nothing (an empty password).
    var isEmpty: Bool { bytes.isEmpty }

    /// The password as text, for the schemes that take a string (PDFKit's
    /// `unlock(withPassword:)`). Keep it only for the call.
    var text: String { String(decoding: bytes, as: UTF8.self) }

    /// Overwrites this value's bytes with zero, and leaves it empty. The
    /// bytes are an array, which copies on write: a copy of the secret made
    /// earlier keeps its own bytes until it is wiped too, so wipe each one
    /// you make. (Swift cannot wipe the storage a copy shares.)
    mutating func wipe() {
        bytes.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress, buffer.count > 0 {
                // memset_s is the one call the compiler may not remove.
                _ = memset_s(base, buffer.count, 0, buffer.count)
            }
        }
        bytes.removeAll()
    }

    /// What every interpolation prints.
    var description: String { "redacted" }

    /// What a debugger and `dump` print.
    var debugDescription: String { "Secret(redacted)" }
}

// MARK: - The Bytes Each Scheme Takes

/// How a typed password becomes the bytes a scheme's key derivation takes.
/// The schemes disagree, and a person's typing may differ from the writer's
/// (an accent typed precomposed against decomposed), so a scheme that leaves
/// the encoding open is tried with each plausible one before the password is
/// called wrong (the design's "Passwords are bytes").
enum PasswordEncoding {
    /// The families of schemes.
    enum Scheme {
        /// WinZip AES, OpenDocument: UTF-8.
        case utf8
        /// ZipCrypto: the bytes of whatever encoding the writing tool used,
        /// UTF-8 or a legacy code page.
        case zipCrypto
        /// Office, 7z: UTF-16 little-endian.
        case utf16LittleEndian
    }

    /// The byte strings to try for `secret` under `scheme`, most likely
    /// first, without repeats.
    static func candidates(for secret: Secret, scheme: Scheme) -> [[UInt8]] {
        let typed = secret.text
        // The two Unicode normalizations: a Mac types precomposed, a file
        // name or another system may have written decomposed.
        let forms = [typed.precomposedStringWithCanonicalMapping, typed.decomposedStringWithCanonicalMapping]
        var found: [[UInt8]] = []
        func add(_ candidate: [UInt8]) {
            if !found.contains(candidate) { found.append(candidate) }
        }
        switch scheme {
        case .utf8:
            forms.forEach { add(Array($0.utf8)) }
        case .zipCrypto:
            forms.forEach { add(Array($0.utf8)) }
            // The legacy code pages ZipCrypto writers have used: Windows'
            // Latin-1 and DOS' CP437, where the characters fit.
            for form in forms {
                if let latin = form.data(using: .isoLatin1) { add([UInt8](latin)) }
                if let dos = form.data(using: dosLatinUS) { add([UInt8](dos)) }
            }
        case .utf16LittleEndian:
            forms.forEach { form in add(form.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }) }
        }
        return found
    }

    /// DOS Latin US (code page 437), as Foundation names it.
    private static let dosLatinUS = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))
    )
}
