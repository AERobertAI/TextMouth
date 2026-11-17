import AudioToolbox
import Foundation

/// How the samples of linear PCM audio are stored, and whether TextMouth can
/// decode that form (B15).
///
/// A file can be valid, with a header that says exactly what its samples are,
/// and still hold them in a form no decoder of the Mac or the iPhone reads: a
/// WAVE or CAF file of 64-bit integers, for one. Such a file is not damaged,
/// so the import must not say it is. The form comes from the file's own
/// description (`AudioStreamBasicDescription`, or what `afinfo` prints of it),
/// before any sample is decoded, so a truly damaged file, which has no
/// readable description or whose samples fail, is still told as damaged.
///
/// The forms were decided by test, with a file of each, on macOS 26: Core
/// Audio's `AVAssetReader` and `afconvert` both refuse (the converter fails
/// with `'fmt?'`) every integer form deeper than 32 bits (33, 40, 48, and 64
/// bits, in the WAVE, AIFF, and CAF files tried) and every floating-point form but
/// 32 and 64 bits (a 16-bit and a 24-bit float), and both read the others: 8,
/// 12, 16, 20, 24, and 32-bit integers (an odd depth is stored at the next
/// one up, `AudioRenderSettings.readableDepth(bits:isFloat:)`), and 32 and
/// 64-bit floats. A 128-bit or an 8-bit float CAF file does not open as audio
/// at all, so it is refused by the opening, not by its form.
struct AudioSampleForm: Equatable, Sendable {
    /// The bits in one sample, as the file's description gives them: above zero.
    let bits: Int
    /// Whether the samples are floating-point numbers, not integers.
    let isFloat: Bool

    /// The deepest integer samples the decoders read.
    static let deepestDecodableIntegerBits = 32
    /// The depths of floating-point samples the decoders read.
    static let decodableFloatBits: Set<Int> = [32, 64]

    /// The form of `bits`-bit samples, floating-point or integer; nil when
    /// the depth is not above zero, which no file's description means.
    init?(bits: Int, isFloat: Bool) {
        guard bits > 0 else { return nil }
        self.bits = bits
        self.isFloat = isFloat
    }

    /// The form a stream description gives; nil for anything but linear PCM
    /// (coded audio has no sample depth of its own) or a description with
    /// no depth.
    init?(_ description: AudioStreamBasicDescription) {
        guard description.mFormatID == kAudioFormatLinearPCM else { return nil }
        self.init(bits: Int(description.mBitsPerChannel), isFloat: description.mFormatFlags & kAudioFormatFlagIsFloat != 0)
    }

    /// Whether the decoders read samples of this form.
    var isDecodable: Bool {
        isFloat ? Self.decodableFloatBits.contains(bits) : bits <= Self.deepestDecodableIntegerBits
    }
}

/// The words said of a file whose samples are in a form TextMouth cannot
/// decode (B15). They live here, with the form that is named, so the tests can
/// name them; the import's sentences for a book's files, a single file, and a
/// file it converts all come from `refusal(fileName:form:)`.
enum AudioSampleFormWording {
    /// What a listener can do about it: the sentence that ends every refusal.
    static let advice = "Convert it to 16-bit or 24-bit, then add it again."

    /// The form in words a listener knows, as an adjective of "samples":
    /// "64-bit integer", "16-bit floating-point".
    static func phrase(for form: AudioSampleForm) -> String {
        "\(form.bits)-bit \(form.isFloat ? "floating-point" : "integer")"
    }

    /// The sentence that refuses the file `fileName`, which is not damaged:
    /// "“Talk.wav” uses 64-bit integer samples, which TextMouth can't play.
    /// Convert it to 16-bit or 24-bit, then add it again."
    static func refusal(fileName: String, form: AudioSampleForm) -> String {
        "“\(fileName)” uses \(phrase(for: form)) samples, which TextMouth can't play. \(advice)"
    }
}
