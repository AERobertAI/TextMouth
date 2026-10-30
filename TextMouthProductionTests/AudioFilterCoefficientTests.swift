import XCTest
@testable import TextMouth

/// The biquad filters TextMouth runs itself (FR04), highpass, lowpass, and
/// equalizer, where ffmpeg's formulas break down. An equalizer written
/// without its frequency is refused, saying what to give, rather than run at
/// ffmpeg's default of 0 Hz, where it computes NaN; every shape and width
/// type, from the lowest frequency to the highest a biquad reaches and from
/// the narrowest width to the widest, gives five finite coefficients or is
/// refused naming its width, so no NaN or infinity is rendered into every
/// sample and saved over the book; a frequency at or above half the sample
/// rate is refused; and an equalizer renders a ramp into finite samples, or
/// is refused before it writes anything. No sound is played: every result is
/// read back as numbers.
final class AudioFilterCoefficientTests: XCTestCase {

    /// The sample rate of these tests, CD audio's: half of it, 22,050 Hz, is
    /// the highest frequency a biquad can reach.
    private static let sampleRate = 44_100.0

    /// What a biquad's frequency takes, as a refusal says it.
    private static let frequencyRange = "give a number from 0.0001 to 999999"

    // MARK: - An Equalizer Without a Frequency

    /// An equalizer written without its frequency is refused with a sentence
    /// saying what to give, whatever its width type: at ffmpeg's default of
    /// 0 Hz a width in hertz, kilohertz, or octaves computes NaN, and a Q,
    /// the default width type, makes a filter that changes nothing.
    func testAnEqualizerWithoutAFrequencyIsRefused() {
        let refusal = AudioFilterError.missingValue(filter: "equalizer", option: "frequency", expected: Self.frequencyRange)
        for chain in ["equalizer=t=h:w=200:g=6", "equalizer=t=k:w=200:g=6", "equalizer=t=o:w=200:g=6", "equalizer=w=200:g=6"] {
            XCTAssertThrowsError(try AudioFilterChain.parse(chain).builtInFilters(), chain) { error in
                XCTAssertEqual(error as? AudioFilterError, refusal, chain)
                // The sentence the editor shows and VoiceOver reads.
                XCTAssertEqual(error.localizedDescription, "The equalizer filter needs its frequency: give a number from 0.0001 to 999999.", chain)
            }
        }
    }

    /// A frequency that is given is taken by its name, its letter, or its
    /// place, and one outside its range is refused as a bad value, as before.
    func testAGivenFrequencyIsTakenOrRefusedAsBefore() {
        let band = AudioBuiltInFilter.biquad(.init(kind: .peaking, frequency: 1_000, width: 1, widthType: .q, poles: 2, gain: 6))
        for chain in ["equalizer=frequency=1000:g=6", "equalizer=f=1000:g=6", "equalizer=1000:g=6"] {
            XCTAssertEqual(try AudioFilterChain.parse(chain).builtInFilters(), [band], chain)
        }
        XCTAssertThrowsError(try AudioFilterChain.parse("equalizer=f=0:g=6").builtInFilters()) { error in
            XCTAssertEqual(error as? AudioFilterError, .badValue(filter: "equalizer", option: "frequency", value: "0", expected: Self.frequencyRange))
        }
    }

    // MARK: - Coefficients

    /// Every biquad shape: the filter's name in a chain, its kind, and its
    /// poles (an equalizer always has two).
    private static let shapes: [(name: String, kind: AudioBuiltInFilter.Biquad.Kind, poles: Int)] = [
        ("highpass", .highpass, 1), ("highpass", .highpass, 2), ("lowpass", .lowpass, 1), ("lowpass", .lowpass, 2),
        ("equalizer", .peaking, 2),
    ]

    /// The frequencies tried, each as a refusal writes it: the lowest the
    /// parse allows, a usual one, and the highest below half the sample rate.
    private static let frequencies: [(value: Double, written: String)] = [
        (0.000_1, "0.0001"), (1_000, "1000"), (sampleRate / 2 - 1, "22049"),
    ]

    /// The widths tried, each as a refusal writes it: the narrowest the
    /// parse allows, a usual one, and the widest.
    private static let widths: [(value: Double, written: String)] = [(0.000_1, "0.0001"), (1, "1"), (99_999, "99999")]

    /// Every shape, with every width type, at each frequency and width tried,
    /// gives five finite coefficients, or is refused naming its width with a
    /// sentence saying what to do: never a NaN or an infinity. Only widths in
    /// octaves are refused, and only where ffmpeg's formula,
    /// sin(w0) × sinh(ln 2 / 2 × width × w0 / sin(w0)), overflows: at 99,999
    /// octaves at any frequency, and at 1 octave at 22,049 Hz, where
    /// w0 / sin(w0) is about 22,049. A one-pole filter uses no width.
    func testEveryWidthGivesFiniteCoefficientsOrIsRefusedNamingIt() {
        for shape in Self.shapes {
            for widthType in AudioBuiltInFilter.Biquad.WidthType.allCases {
                for frequency in Self.frequencies {
                    for width in Self.widths {
                        let biquad = AudioBuiltInFilter.Biquad(
                            kind: shape.kind, frequency: frequency.value, width: width.value, widthType: widthType,
                            poles: shape.poles, gain: shape.kind == .peaking ? 6 : 0
                        )
                        let label = "\(shape.name), \(shape.poles) poles, t=\(widthType.rawValue), f=\(frequency.written), w=\(width.written)"
                        let overflows = widthType == .octave && shape.poles == 2
                            && (width.value == 99_999 || (width.value == 1 && frequency.value == Self.sampleRate / 2 - 1))
                        do {
                            let c = try AudioFilterRunner.coefficients(biquad, sampleRate: Self.sampleRate)
                            let values = [c.b0, c.b1, c.b2, c.a1, c.a2]
                            XCTAssertTrue(values.allSatisfy(\.isFinite), "\(label): coefficients \(values)")
                            XCTAssertFalse(overflows, "\(label): computed \(values) where the width makes no usable filter")
                        } catch {
                            XCTAssertEqual(error as? AudioFilterError, .badValue(
                                filter: shape.name, option: "width", value: width.written,
                                expected: "give a narrower width, since this one makes no usable filter at \(frequency.written) Hz"
                            ), label)
                            XCTAssertTrue(overflows, "\(label): refused a usable filter: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    /// A frequency at or above half the sample rate, which no biquad can
    /// reach, is refused for every shape, the sentence ending with the
    /// highest it can be.
    func testAFrequencyAtOrAboveHalfTheSampleRateIsRefused() {
        let ending = "give a frequency below half the audio's sample rate, 22050 Hz"
        for shape in Self.shapes {
            for frequency in [Self.sampleRate / 2, Self.sampleRate] {
                let biquad = AudioBuiltInFilter.Biquad(
                    kind: shape.kind, frequency: frequency, width: 1, widthType: .q, poles: shape.poles, gain: 0
                )
                let label = "\(shape.name), \(shape.poles) poles, f=\(frequency)"
                XCTAssertThrowsError(try AudioFilterRunner.coefficients(biquad, sampleRate: Self.sampleRate), label) { error in
                    guard case .badValue(let filter, let option, _, let expected) = error as? AudioFilterError else {
                        return XCTFail("\(label): \(error)")
                    }
                    XCTAssertEqual(filter, shape.name, label)
                    XCTAssertEqual(option, "frequency", label)
                    XCTAssertEqual(expected, ending, label)
                    XCTAssertTrue(error.localizedDescription.hasSuffix(ending + "."), error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Rendering

    /// An equalizer renders a one-second ramp into a second of samples,
    /// every one of them a finite number.
    func testAnEqualizerRendersARampIntoFiniteSamples() throws {
        let folder = try makeFolder()
        let rendered = folder.appendingPathComponent("rendered.caf")

        try render("equalizer=f=1000:g=6", in: folder, to: rendered)

        let samples = try AudioTestFixtures.floatSamples(of: rendered)
        XCTAssertEqual(samples.count, Int(Self.sampleRate), "the render isn't the ramp's one second")
        XCTAssertEqual(samples.filter { !$0.isFinite }.count, 0, "the render holds samples that aren't finite numbers")
    }

    /// An equalizer whose octave width makes no usable filter at its
    /// frequency renders nothing: it is refused, naming the width, before
    /// its output file is made, so no NaN can be saved over the book.
    func testAWidthThatMakesNoFilterRendersNothing() throws {
        let folder = try makeFolder()
        let rendered = folder.appendingPathComponent("rendered.caf")

        XCTAssertThrowsError(try render("equalizer=f=1000:t=o:w=5000:g=6", in: folder, to: rendered)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The equalizer filter's width can't be “5000”: give a narrower width, since this one makes no usable filter at 1000 Hz."
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rendered.path), "a refused render left its output file")
    }

    // MARK: - Helpers

    /// A new, empty folder for this test's files, removed when it ends.
    private func makeFolder() throws -> URL {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// Runs `chain` on TextMouth's own engine, as the audio editor does,
    /// over a one-second identity ramp written in `folder`, writing the
    /// result to `output`.
    private func render(_ chain: String, in folder: URL, to output: URL) throws {
        let ramp = folder.appendingPathComponent("ramp.caf")
        try AudioTestFixtures.writeIdentityRamp(to: ramp, frames: Int(Self.sampleRate), sampleRate: Self.sampleRate)
        try AudioFilterRunner.run(try AudioFilterChain.parse(chain).builtInFilters(), input: ramp, output: output, scratch: folder)
    }
}
