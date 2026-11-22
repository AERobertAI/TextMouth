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
/// but is named only after a decode has failed (`AudioMediaProbe`, the
/// converter): a Mac that decodes a form the table below refuses is never
/// refused by it, and a damaged file, whose decode fails for any form, is told
/// as damaged unless its description names a form the table refuses.
///
/// The table was decided by test, with a file of each, on macOS 26: Core
/// Audio's `AVAssetReader` and `afconvert` both refuse (the converter fails
/// with `'fmt?'`) every integer form deeper than 32 bits (33, 40, 48, and 64
/// bits, in the WAVE, AIFF, and CAF files tried) and every floating-point form
/// but 32 and 64 bits (a 16-bit and a 24-bit float), and both read the others:
/// 8, 12, 16, 20, 24, and 32-bit integers (an odd depth is stored at the next
/// one up, `AudioRenderSettings.readableDepth(bits:isFloat:)`), and 32 and
/// 64-bit floats. A 128-bit or an 8-bit float CAF file does not open as audio
/// at all, so it is refused by the opening, not by its form. Integers of fewer
/// than 8 bits were not tried, and are not in the table.
struct AudioSampleForm: Equatable, Sendable {
    /// The bits in one sample, as the file's description gives them.
    let bits: Int
    /// Whether the samples are floating-point numbers, not integers.
    let isFloat: Bool

    /// The depths of integer samples the decoders read.
    static let decodableIntegerBits = 8...32
    /// The depths of floating-point samples the decoders read.
    static let decodableFloatBits: Set<Int> = [32, 64]
    /// The deepest sample any file's description is believed to give; a
    /// larger depth is a damaged description, not a form.
    static let deepestBelievedBits = 64

    /// The form of `bits`-bit samples, floating-point or integer, as a test
    /// or a caller that has checked the depth already states it.
    init(bits: Int, isFloat: Bool) {
        self.bits = bits
        self.isFloat = isFloat
    }

    /// The form a file's description gives, or nil when the description is
    /// not one to name a form from, so that the file is left to the damage
    /// checks: a depth that is not above zero or is above
    /// `deepestBelievedBits`, or a frame of `bytesPerFrame` bytes that cannot
    /// hold `channels` samples of `bits` bits (one channel's, when the
    /// channels are not `interleaved`). A nil `bytesPerFrame` is one the
    /// description does not give, which is believed.
    init?(bits: Int, isFloat: Bool, bytesPerFrame: Int?, channels: Int, interleaved: Bool = true) {
        guard bits > 0, bits <= Self.deepestBelievedBits else { return nil }
        if let bytesPerFrame {
            let bytesPerSample = (bits + 7) / 8
            guard bytesPerFrame >= bytesPerSample * (interleaved ? max(channels, 1) : 1) else { return nil }
        }
        self.init(bits: bits, isFloat: isFloat)
    }

    /// The form a stream description gives; nil for anything but linear PCM
    /// (coded audio has no sample depth of its own) and for a description
    /// that names no form (`init(bits:isFloat:bytesPerFrame:channels:interleaved:)`).
    init?(_ description: AudioStreamBasicDescription) {
        guard description.mFormatID == kAudioFormatLinearPCM else { return nil }
        self.init(
            bits: Int(description.mBitsPerChannel),
            isFloat: description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            bytesPerFrame: Int(description.mBytesPerFrame),
            channels: Int(description.mChannelsPerFrame),
            interleaved: description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        )
    }

    /// Whether the decoders read samples of this form.
    var isDecodable: Bool {
        isFloat ? Self.decodableFloatBits.contains(bits) : Self.decodableIntegerBits.contains(bits)
    }
}

/// The words said of a file whose samples are in a form TextMouth cannot
/// decode (B15). They live here, with the form that is named, so the tests can
/// name them; the import's sentences for a book's files, a single file, and a
/// file it converts all come from `refusal(fileName:form:)`.
enum AudioSampleFormWording {
    /// What a listener can do about it: the sentence that ends every refusal.
    static var advice: String {
        // Translators: Ends every refusal of an audio file whose samples TextMouth can't decode: what the listener can do about it.
        InterfaceText.line("audioSampleForm.advice", "Convert it to 16-bit or 24-bit integer samples, then import it again.")
    }

    /// The form in words a listener knows, as an adjective of "samples":
    /// "64-bit integer", "16-bit floating-point".
    static func phrase(for form: AudioSampleForm) -> String {
        // The bit depth names a form, as an identifier does, so it is
        // written without digit grouping.
        let bits = String(form.bits)
        return form.isFloat
            // Translators: An audio file's sample form, an adjective of "samples" in a refusal such as "uses 16-bit floating-point samples". %@ is the number of bits, an identifier written without digit grouping.
            ? InterfaceText.line("audioSampleForm.phrase.floating", "\(bits)-bit floating-point")
            // Translators: An audio file's sample form, an adjective of "samples" in a refusal such as "uses 64-bit integer samples". %@ is the number of bits, an identifier written without digit grouping.
            : InterfaceText.line("audioSampleForm.phrase.integer", "\(bits)-bit integer")
    }

    /// What is wrong with a form no decoder reads, as a clause for a log or a
    /// message that names the problem (`AudioMediaProblem.reason`): never said
    /// to a listener, who hears `refusal(fileName:form:)`.
    static func clause(for form: AudioSampleForm) -> String {
        // English like a parser's damage reason: the clause goes into the
        // import's log and a bug report, so it never takes the interface's
        // language from `phrase(for:)`.
        let english = "\(form.bits)-bit \(form.isFloat ? "floating-point" : "integer")" // l10n: no (the log's English twin of phrase(for:))
        return "its samples are \(english) numbers, which TextMouth cannot decode" // l10n: no (a damage reason, English like a parser's; log only)
    }

    /// The sentence that refuses the file `fileName`, which is not damaged:
    /// "“Talk.wav” uses 64-bit integer samples, which TextMouth can't play.
    /// Convert it to 16-bit or 24-bit integer samples, then import it again."
    static func refusal(fileName: String, form: AudioSampleForm) -> String {
        // Translators: Refuses an audio file whose samples TextMouth can't decode, which is not damaged. %1$@ is the file's name and %2$@ its sample form, such as "64-bit integer".
        let problem = InterfaceText.line("audioSampleForm.refusal", "“\(fileName)” uses \(phrase(for: form)) samples, which TextMouth can't play.")
        return SentenceWording.joined([problem, advice])
    }
}
