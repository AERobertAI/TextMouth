import XCTest
@testable import TextMouth

/// Filter chains in ffmpeg's syntax (FR04): split into filters and options,
/// with quotes, escapes, instance names, and values given by their place in
/// ffmpeg's order; every filter TextMouth runs itself read with its options
/// checked and turned into numbers; and everything else refused with a
/// sentence that names what is supported.
final class AudioFilterChainTests: XCTestCase {

    // MARK: - Syntax

    /// A chain splits into filters at commas and a filter's options at
    /// colons, each a key=value or a value alone.
    func testAChainIsSplitIntoFiltersAndOptions() throws {
        let chain = try AudioFilterChain.parse(" highpass=f=80, equalizer=f=3000:t=q:w=1:g=3,areverse ")
        XCTAssertEqual(chain.text, "highpass=f=80, equalizer=f=3000:t=q:w=1:g=3,areverse")
        XCTAssertEqual(chain.filters.map(\.name), ["highpass", "equalizer", "areverse"])
        XCTAssertEqual(chain.filters[checked: 1]?.options, [
            AudioFilterChain.Option(key: "f", value: "3000"),
            AudioFilterChain.Option(key: "t", value: "q"),
            AudioFilterChain.Option(key: "w", value: "1"),
            AudioFilterChain.Option(key: "g", value: "3"),
        ])
        XCTAssertEqual(chain.filters[checked: 2]?.options, [])
    }

    /// Quotes keep a value's colons and commas, a backslash escapes one
    /// character, and an instance name after "@" is not part of the name.
    func testQuotesEscapesAndInstanceNames() throws {
        let chain = try AudioFilterChain.parse(#"afade=t=out:st='0:01:30':d=2,volume@quiet=volume=0\,5"#)
        XCTAssertEqual(chain.filters.first?.options[checked: 1], AudioFilterChain.Option(key: "st", value: "0:01:30"))
        XCTAssertEqual(chain.filters[checked: 1]?.name, "volume")
        XCTAssertEqual(chain.filters[checked: 1]?.options, [AudioFilterChain.Option(key: "volume", value: "0,5")])
    }

    /// What isn't ffmpeg's syntax, or is a filtergraph only ffmpeg runs, is
    /// refused with a sentence.
    func testMalformedChainsAreRefused() {
        let refusals: [(String, AudioFilterError)] = [
            ("   ", .empty),
            ("volume='2", .syntax("A quote isn't closed in “volume='2”.")),
            ("volume=2,,areverse", .syntax("There's an empty filter between two commas.")),
            ("vol ume=2", .syntax("“vol ume” isn't a filter's name.")),
            ("volume=:=2", .syntax("An option of the volume filter has a value but no name.")),
            ("[in]volume=2[out]", .needsFFmpeg),
            ("volume=2;areverse", .needsFFmpeg),
        ]
        for (text, expected) in refusals {
            XCTAssertThrowsError(try AudioFilterChain.parse(text), text) { error in
                XCTAssertEqual(error as? AudioFilterError, expected, text)
            }
        }
    }

    // MARK: - TextMouth's Own Filters

    /// Every filter TextMouth runs itself reads its options into numbers:
    /// decibels become linear amplitudes, times take ffmpeg's forms, and
    /// what isn't given takes ffmpeg's default.
    func testEverySupportedFilterIsRead() throws {
        func filter(_ text: String) throws -> AudioBuiltInFilter {
            try XCTUnwrap(try AudioFilterChain.parse(text).builtInFilters().first)
        }
        XCTAssertEqual(try filter("volume=0.5"), .volume(gain: 0.5))
        guard case .volume(let decibels) = try filter("volume=-6dB") else { return XCTFail("volume") }
        XCTAssertEqual(decibels, 0.501, accuracy: 0.001)
        XCTAssertEqual(try filter("highpass=f=80"), .biquad(.init(kind: .highpass, frequency: 80, width: 0.707, widthType: .q, poles: 2, gain: 0)))
        XCTAssertEqual(try filter("lowpass=3000:t=h:w=200:p=1"), .biquad(.init(kind: .lowpass, frequency: 3_000, width: 200, widthType: .hertz, poles: 1, gain: 0)))
        XCTAssertEqual(try filter("equalizer=1000:o:1:-3"), .biquad(.init(kind: .peaking, frequency: 1_000, width: 1, widthType: .octave, poles: 2, gain: -3)))
        XCTAssertEqual(try filter("afade=t=out:st=2:d=1.5:curve=qsin"), .fade(.init(
            fadesIn: false, startSample: 0, startTime: 2, sampleCount: 44_100, duration: 1.5, curve: .qsin, silence: 0, unity: 1
        )))
        XCTAssertEqual(try filter("afade"), .fade(.init(
            fadesIn: true, startSample: 0, startTime: nil, sampleCount: 44_100, duration: nil, curve: .tri, silence: 0, unity: 1
        )))
        XCTAssertEqual(try filter("atempo=1.25"), .tempo(factor: 1.25))
        XCTAssertEqual(try filter("loudnorm=I=-16:TP=-1.5:LRA=11"), .loudness(target: -16, truePeak: -1.5))
        XCTAssertEqual(try filter("loudnorm"), .loudness(target: -24, truePeak: -2))
        guard case .silenceRemoval(let removal) = try filter("silenceremove=stop_periods=-1:stop_duration=0.5:stop_threshold=-40dB") else {
            return XCTFail("silenceremove")
        }
        XCTAssertEqual(removal.startPeriods, 0)
        XCTAssertEqual(removal.stopPeriods, -1)
        XCTAssertEqual(removal.stopDuration, 0.5)
        XCTAssertEqual(removal.stopThreshold, 0.01, accuracy: 0.000_1)
        XCTAssertEqual(removal.detection, .rms)
        XCTAssertEqual(removal.window, 0.02)
        guard case .compressor(let compressor) = try filter("acompressor=threshold=-20dB:ratio=4:attack=5:release=100:makeup=2") else {
            return XCTFail("acompressor")
        }
        XCTAssertEqual(compressor.threshold, 0.1, accuracy: 0.000_1)
        XCTAssertEqual(compressor.ratio, 4)
        XCTAssertEqual(compressor.attack, 5)
        XCTAssertEqual(compressor.release, 100)
        XCTAssertEqual(compressor.makeup, 2)
        XCTAssertEqual(compressor.knee, 2.828_43)
        XCTAssertEqual(try filter("areverse"), .reverse)
    }

    /// Times take ffmpeg's duration forms: seconds, with a unit or not, and
    /// minutes and hours with colons.
    func testTimesTakeFFmpegsForms() throws {
        func start(_ text: String) throws -> TimeInterval? {
            guard case .fade(let fade) = try XCTUnwrap(try AudioFilterChain.parse("afade=st=\(text)").builtInFilters().first) else {
                return nil
            }
            return fade.startTime
        }
        XCTAssertEqual(try start("2.5"), 2.5)
        XCTAssertEqual(try start("2s"), 2)
        XCTAssertEqual(try start("250ms"), 0.25)
        XCTAssertEqual(try start("'1:30'"), 90)
        XCTAssertEqual(try start("'0:01:30.5'"), 90.5)
    }

    /// A filter TextMouth doesn't run is refused with a sentence naming the
    /// ones it does, and that with ffmpeg every filter works.
    func testAnUnknownFilterIsRefusedNamingTheSupportedOnes() {
        XCTAssertThrowsError(try AudioFilterChain.parse("highpass=f=80,aecho=0.8:0.9:1000:0.3").builtInFilters()) { error in
            XCTAssertEqual(error as? AudioFilterError, .unknownFilter("aecho"))
            XCTAssertEqual(
                error.localizedDescription,
                "TextMouth's own filters don't include “aecho”. They are acompressor, afade, areverse, atempo, equalizer, "
                    + "highpass, loudnorm, lowpass, silenceremove, and volume; with ffmpeg installed, every filter it has works."
            )
        }
    }

    /// An option ffmpeg's filter has and TextMouth's doesn't, or one neither
    /// has, is refused with a sentence naming the options TextMouth's takes.
    func testAnUnknownOptionIsRefusedNamingTheSupportedOnes() {
        XCTAssertThrowsError(try AudioFilterChain.parse("highpass=f=80:mix=0.5").builtInFilters()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The highpass filter has no option “mix” here. Its options are frequency (f), width_type (t), width (w), and poles (p)."
            )
        }
        XCTAssertThrowsError(try AudioFilterChain.parse("volume=1:precision=float").builtInFilters()) { error in
            XCTAssertEqual(error as? AudioFilterError, .unknownOption(filter: "volume", option: "precision", supported: ["volume"]))
        }
        // A value given by its place lands on ffmpeg's next option, here
        // volume's precision, which TextMouth's volume doesn't take.
        XCTAssertThrowsError(try AudioFilterChain.parse("volume=1:float").builtInFilters()) { error in
            XCTAssertEqual(error as? AudioFilterError, .unknownOption(filter: "volume", option: "precision", supported: ["volume"]))
        }
    }

    /// A value an option can't take is refused with what it takes, and a
    /// value by its place after a key=value is refused, as ffmpeg refuses it.
    func testBadValuesAreRefused() {
        let refusals: [(String, String)] = [
            ("volume=loud", "The volume filter's volume can't be “loud”: give a number, such as 0.5, or decibels, such as -6dB."),
            ("atempo=0.1", "The atempo filter's tempo can't be “0.1”: give a number from 0.5 to 32."),
            ("afade=t=sideways", "The afade filter's type can't be “sideways”: give one of in, out."),
            ("highpass=p=3", "The highpass filter's poles can't be “3”: give a whole number from 1 to 2."),
            ("afade=st=soon", "The afade filter's start_time can't be “soon”: give a time such as 2.5, 250ms, or 0:01:30."),
            ("loudnorm=linear=false", "The loudnorm filter's linear can't be “false”: TextMouth's own loudnorm normalizes with one gain, so it takes only true."),
            ("afade=t=in:1", "The afade filter was given more values than it has options; give them as key=value."),
        ]
        for (text, sentence) in refusals {
            XCTAssertThrowsError(try AudioFilterChain.parse(text).builtInFilters(), text) { error in
                XCTAssertEqual(error.localizedDescription, sentence, text)
            }
        }
    }

    /// Every premade preset runs on TextMouth's own filters, so each works
    /// without ffmpeg.
    @MainActor
    func testEveryPremadePresetRunsOnTextMouthsOwnFilters() throws {
        for preset in AudioFilterPresetLibrary.standard {
            XCTAssertNoThrow(try AudioFilterChain.parse(preset.chain).builtInFilters(), preset.name)
        }
        XCTAssertEqual(Set(AudioFilterPresetLibrary.standard.map(\.id)).count, AudioFilterPresetLibrary.standard.count)
    }
}
