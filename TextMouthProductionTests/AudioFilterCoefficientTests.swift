import XCTest
@testable import TextMouth

/// The biquad filters TextMouth runs itself (FR04), highpass, lowpass, and
/// equalizer, where ffmpeg's formulas break down. An equalizer written
/// without its frequency is refused, saying what to give, rather than run at
/// ffmpeg's default of 0 Hz, where it computes NaN.
final class AudioFilterCoefficientTests: XCTestCase {

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
}
