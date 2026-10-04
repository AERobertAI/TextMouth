import Foundation

/// A format the audio editor exports edited audio in (FR04), as Export
/// lists them: those Core Audio writes, and MP3, which it can't, written
/// with the LAME encoder built into TextMouth, or, should that somehow be
/// unavailable, through an installed ffmpeg the setting allows
/// (`MP3Route`). The user's answer of October 4: MP3 is wanted, whatever the
/// encoder adds to the app.
enum AudioExportFormat: String, CaseIterable, Sendable {
    /// AAC in an .m4a file, with chapter markers.
    case m4a
    /// AAC in an .m4b audiobook file, with chapter markers.
    case m4b
    /// Apple Lossless in an .m4a file, with chapter markers.
    case appleLossless
    /// Linear PCM in a WAVE file.
    case wav
    /// Linear PCM in an AIFF file.
    case aiff
    /// Linear PCM in a CAF file.
    case caf
    /// MP3, with chapter markers as ID3 chapter frames.
    case mp3

    /// The format's name as Export lists it and VoiceOver reads it.
    var title: String {
        switch self {
        case .m4a: return "M4A (AAC)"
        case .m4b: return "M4B Audiobook (AAC)"
        case .appleLossless: return "Apple Lossless (M4A)"
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .caf: return "CAF"
        case .mp3: return "MP3"
        }
    }

    /// The format the renderer writes for it.
    var renderFormat: AudioRenderFormat {
        switch self {
        case .m4a: return .aacM4A
        case .m4b: return .aacM4B
        case .appleLossless: return .alacM4A
        case .wav: return .pcmWAV
        case .aiff: return .pcmAIFF
        case .caf: return .pcmCAF
        case .mp3: return .mp3
        }
    }

    /// The extension of a file exported in it.
    var fileExtension: String {
        renderFormat.fileExtension
    }

    /// Whether it needs an installed ffmpeg: MP3, only should the LAME built
    /// into TextMouth be unavailable.
    var needsFFmpeg: Bool {
        self == .mp3 && !MP3Encoder.isAvailable
    }

    /// The formats Export offers when `ffmpeg` is the installed ffmpeg
    /// TextMouth may use, or nil: every one Core Audio writes, and MP3 when
    /// an encoder can write it (`MP3Route.preferred`), which the LAME built
    /// in always can, unless `builtInMP3` says it is unavailable.
    static func available(ffmpeg: FFmpeg?, builtInMP3: Bool = MP3Encoder.isAvailable) -> [AudioExportFormat] {
        let writesMP3 = MP3Route.preferred(ffmpeg: ffmpeg, builtInIsAvailable: builtInMP3) != nil
        return allCases.filter { $0 != .mp3 || writesMP3 }
    }
}
