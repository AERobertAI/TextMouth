import Foundation

/// An audio session's error code in the form its header gives it
/// (`AudioSessionTypes.h:82-98`), for the log: `AVAudioSession`'s codes are four
/// characters read as one number, so `!int` reaches the app as 560557684.
enum PhoneAudioErrorCode {
    /// The code as its four characters and its number, such as
    /// `'!int' (560557684)`; a code that isn't four printable characters, such
    /// as -50, as its number alone.
    static func description(of code: Int) -> String {
        guard let characters = fourCharacters(of: code) else { return String(code) }
        return "'\(characters)' (\(code))"
    }

    /// The four printable characters `code` stands for, or nil when it stands
    /// for none.
    static func fourCharacters(of code: Int) -> String? {
        guard let bits = UInt32(exactly: code) else { return nil }
        let bytes = [24, 16, 8, 0].map { UInt8((bits >> UInt32($0)) & 0xFF) }
        // Printable ASCII: a smaller number, such as a Cocoa error's, leaves
        // zeros here and is no four-character code.
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
