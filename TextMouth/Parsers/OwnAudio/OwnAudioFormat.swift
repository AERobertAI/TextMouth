import Foundation

/// The audio formats TextMouth reads with readers of its own, because
/// neither macOS nor iOS decodes them: each is decoded in the app and
/// written as Apple Lossless when it is imported (`OwnAudioConverter`).
enum OwnAudioFormat: String, CaseIterable, Equatable, Sendable {
    /// True Audio, in .tta files.
    case trueAudio
    /// WavPack, in .wv files, a hybrid one perhaps with its correction
    /// file (.wvc) beside it.
    case wavPack

    /// The name a listener hears for the format.
    var displayName: String {
        switch self {
        case .trueAudio: return "True Audio"
        case .wavPack: return "WavPack"
        }
    }

    /// The format's file extensions, in lowercase.
    var fileExtensions: [String] {
        switch self {
        case .trueAudio: return ["tta"]
        case .wavPack: return ["wv"]
        }
    }

    /// The extension, in lowercase, of the file that may lie beside a file
    /// of the format and complete it: a hybrid WavPack file's correction
    /// file, which makes it lossless. Nil for a format with none.
    var companionExtension: String? {
        switch self {
        case .trueAudio: return nil
        case .wavPack: return "wvc"
        }
    }

    /// The four bytes a file of the format starts with, after any ID3v2 tag.
    var signature: String {
        switch self {
        case .trueAudio: return TTADecoder.signature
        case .wavPack: return WavPackDecoder.signature
        }
    }

    /// The codec's name in `ImportAudioConverter.SourceInfo.formatID`, four
    /// characters as afinfo's are.
    var formatID: String {
        switch self {
        case .trueAudio: return "tta1"
        case .wavPack: return "wvpk"
        }
    }

    /// Every extension of every format, in lowercase.
    static let allFileExtensions: Set<String> = Set(allCases.flatMap(\.fileExtensions))

    /// How many bytes at a file's start are enough to tell a format: an
    /// ID3v2 header, or a signature.
    static let signatureWindow = 10

    /// The format whose signature starts `head`, a file's first bytes (or
    /// the bytes after its ID3v2 tag), or nil for none.
    static func starting(_ head: [UInt8]) -> OwnAudioFormat? {
        allCases.first { OwnAudioLittleEndian.holds(head, $0.signature, at: 0) }
    }

    /// The format of `bytes`, told from its signature, which may follow an
    /// ID3v2 tag; nil when it is none of them.
    static func of(_ bytes: OwnAudioBytes) -> OwnAudioFormat? {
        let head = bytes.readUpTo(at: 0, count: signatureWindow)
        if let format = starting(head) { return format }
        let tagLength = OwnAudioLeadingTag.id3v2Length(in: head)
        guard tagLength > 0 else { return nil }
        return starting(bytes.readUpTo(at: tagLength, count: signatureWindow))
    }

    /// A decoder of `bytes`, a file of this format.
    /// - Parameters:
    ///   - companion: the bytes of the file's companion
    ///     (`companionExtension`), when one lies beside it.
    ///   - verifiesChecksums: false only in a fuzzer, so changed bytes
    ///     reach the decoder itself.
    /// - Throws: `OwnAudioError`.
    func decoder(
        of bytes: OwnAudioBytes,
        companion: OwnAudioBytes? = nil,
        verifiesChecksums: Bool = true
    ) throws -> any OwnAudioDecoder {
        switch self {
        case .trueAudio: return try TTADecoder(bytes, verifiesChecksums: verifiesChecksums)
        case .wavPack: return try WavPackDecoder(bytes, correction: companion, verifiesChecksums: verifiesChecksums)
        }
    }
}
