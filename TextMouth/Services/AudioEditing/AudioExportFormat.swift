import Foundation

/// A format the audio editor exports edited audio in (FR04), as Export
/// lists them: those TextMouth writes itself, and MP3, which Core Audio
/// can't encode, only when an installed ffmpeg is found and the setting
/// allows it (`AudioFilterEngine`). The user's answer of October 4: M4A and
/// WAV are fine, and MP3 is welcome without bundling an encoder.
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
    /// MP3 through the installed ffmpeg, with chapter markers as ID3
    /// chapter frames.
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
        case .mp3: return "MP3 (needs ffmpeg)"
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

    /// Whether it needs an installed ffmpeg.
    var needsFFmpeg: Bool {
        self == .mp3
    }

    /// The formats Export offers when `ffmpeg` is the installed ffmpeg
    /// TextMouth may use, or nil: every one TextMouth writes itself, and MP3
    /// only with ffmpeg.
    static func available(ffmpeg: FFmpeg?) -> [AudioExportFormat] {
        allCases.filter { !$0.needsFFmpeg || ffmpeg != nil }
    }
}
