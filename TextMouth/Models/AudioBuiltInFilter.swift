import Foundation

/// A filter TextMouth runs itself (FR04), its options checked and turned into
/// numbers, under ffmpeg's name and with ffmpeg's options, so one chain
/// means the same through TextMouth's engine and through ffmpeg
/// (`AudioFilterRunner` runs them). Each takes the options listed in its
/// spec, in ffmpeg's order, so a value given by its place goes where ffmpeg
/// would put it; an option ffmpeg has and TextMouth's filter doesn't is
/// refused, naming the ones it takes.
enum AudioBuiltInFilter: Equatable, Sendable {
    /// volume: multiplies every sample by `gain`.
    case volume(gain: Double)
    /// highpass, lowpass, and equalizer: a biquad filter, as ffmpeg's.
    case biquad(Biquad)
    /// afade: a fade in or out.
    case fade(Fade)
    /// atempo: plays `factor` times as fast without changing the pitch.
    case tempo(factor: Double)
    /// loudnorm: one gain bringing the integrated loudness to `target`
    /// LUFS, kept below `truePeak` dBFS.
    case loudness(target: Double, truePeak: Double)
    /// silenceremove: trims silence at the start, and stops at, or shortens,
    /// the silences after it, as ffmpeg 7 does.
    case silenceRemoval(SilenceRemoval)
    /// acompressor: evens out the level above a threshold.
    case compressor(Compressor)
    /// areverse: plays the sound backwards.
    case reverse

    /// The names of the filters TextMouth runs itself, in order.
    static let names = [
        "acompressor", "afade", "areverse", "atempo", "equalizer", "highpass", "loudnorm", "lowpass", "silenceremove",
        "volume",
    ]

    /// `value` as a refusal writes it: without a trailing ".0", so a
    /// frequency of 1000 reads "1000", as it was most likely typed. The
    /// options' refusals here and the runner's (`AudioFilterRunner`) write
    /// their numbers through it.
    static func written(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }

    // MARK: Parameters

    /// A biquad filter's parameters, as ffmpeg's af_biquads takes them.
    struct Biquad: Equatable, Sendable {
        /// Which response.
        enum Kind: Equatable, Sendable {
            case highpass, lowpass, peaking
        }
        /// How `width` is measured (ffmpeg's width_type).
        enum WidthType: String, Equatable, Sendable, CaseIterable {
            /// In hertz.
            case hertz = "h"
            /// As a Q factor.
            case q = "q"
            /// In octaves.
            case octave = "o"
            /// In kilohertz.
            case kilohertz = "k"
        }
        let kind: Kind
        /// The corner or centre frequency, in hertz.
        let frequency: Double
        /// The width, measured as `widthType` says.
        let width: Double
        let widthType: WidthType
        /// One or two poles (highpass and lowpass).
        let poles: Int
        /// The gain at the centre, in decibels (equalizer).
        let gain: Double
    }

    /// A fade's parameters, as ffmpeg's afade takes them.
    struct Fade: Equatable, Sendable {
        /// The fade's curve (ffmpeg's curve names).
        enum Curve: String, Equatable, Sendable, CaseIterable {
            case tri, qsin, iqsin, hsin, ihsin, esin, log, ipar, qua, cub, squ, cbr, par, exp, dese, desi, nofade
        }
        /// Whether it fades in, rather than out.
        let fadesIn: Bool
        /// Where it starts: a sample count, or a time in seconds, which wins.
        let startSample: Int64
        let startTime: TimeInterval?
        /// How long it lasts: a sample count, or a time in seconds, which wins.
        let sampleCount: Int64
        let duration: TimeInterval?
        let curve: Curve
        /// The gain at the quiet end, and at the full end.
        let silence: Double
        let unity: Double
    }

    /// silenceremove's parameters, with the meaning ffmpeg 7 gives them
    /// (`AudioFilterRunner.silencesToRemove` says how they are applied).
    struct SilenceRemoval: Equatable, Sendable {
        /// How a window's level is measured.
        enum Detection: String, Equatable, Sendable, CaseIterable {
            case peak, rms
        }
        /// How many times sound must be found before trimming at the start
        /// ends (start_periods); 0 trims nothing there.
        let startPeriods: Int
        /// How much sound, in seconds, counted over the start, is each of
        /// those times; the sound counted is trimmed with the silence.
        let startDuration: TimeInterval
        /// The level, as a linear amplitude, above which the start has sound.
        let startThreshold: Double
        /// How much of what was trimmed at the start is kept, seconds.
        let startSilence: TimeInterval
        /// How many silences longer than `stopDuration` stop the copying
        /// (stop_periods): when positive, everything after is removed; when
        /// negative, copying starts again with the next sound, so every long
        /// silence is shortened; 0 removes nothing after the start.
        let stopPeriods: Int
        /// How long a silence lasts before it counts, seconds: that much of
        /// it is kept.
        let stopDuration: TimeInterval
        /// The level at or below which the sound counts as silent.
        let stopThreshold: Double
        /// How much more of a silence is kept once copying stops, seconds.
        let stopSilence: TimeInterval
        let detection: Detection
        /// The window levels are measured over, seconds.
        let window: TimeInterval
    }

    /// acompressor's parameters.
    struct Compressor: Equatable, Sendable {
        /// How the level is measured.
        enum Detection: String, Equatable, Sendable, CaseIterable {
            case peak, rms
        }
        /// Gain applied before the compressor, linear.
        let levelIn: Double
        /// The level above which it compresses, linear.
        let threshold: Double
        /// How much it compresses: 2 halves every decibel over.
        let ratio: Double
        /// How fast it reacts to a rise, and to a fall, in milliseconds.
        let attack: Double
        let release: Double
        /// Gain applied after it, linear.
        let makeup: Double
        /// The soft knee's width, as ffmpeg's factor (2.82843: 9 dB).
        let knee: Double
        let detection: Detection
        /// How much of the compressed sound is mixed with the dry, 0 to 1.
        let mix: Double
    }

    // MARK: Reading a Filter

    /// The filter `filter` describes, with its options checked.
    /// - Throws: `AudioFilterError.unknownFilter`, `.unknownOption`,
    ///   `.tooManyValues`, `.badValue`, or `.missingValue` for an option it
    ///   needs (the equalizer's frequency).
    init(_ filter: AudioFilterChain.Filter) throws {
        guard let spec = Self.specs[filter.name] else { throw AudioFilterError.unknownFilter(filter.name) }
        let values = try Self.resolve(filter, spec)
        let reader = ValueReader(filter: filter.name, values: values)
        switch filter.name {
        case "volume":
            self = .volume(gain: try reader.amplitude("volume", default: 1, range: 0...1_000_000))
        case "atempo":
            self = .tempo(factor: try reader.number("tempo", default: 1, range: 0.5...32))
        case "highpass", "lowpass":
            self = .biquad(Biquad(
                kind: filter.name == "highpass" ? .highpass : .lowpass,
                frequency: try reader.number("frequency", default: filter.name == "highpass" ? 3_000 : 500, range: 0.000_1...999_999),
                width: try reader.number("width", default: 0.707, range: 0.000_1...99_999),
                widthType: try reader.choice("width_type", default: .q),
                poles: Int(try reader.number("poles", default: 2, range: 1...2, whole: true)),
                gain: 0
            ))
        case "equalizer":
            self = .biquad(Biquad(
                kind: .peaking,
                // ffmpeg's default frequency, 0 Hz, makes no usable filter
                // (with a width in hertz, kilohertz, or octaves it computes
                // NaN), so it must be given.
                frequency: try reader.requiredNumber("frequency", range: 0.000_1...999_999),
                width: try reader.number("width", default: 1, range: 0.000_1...99_999),
                widthType: try reader.choice("width_type", default: .q),
                poles: 2,
                gain: try reader.number("gain", default: 0, range: -900...900)
            ))
        case "afade":
            let type = try reader.choice("type", default: FadeDirection.fadeIn)
            self = .fade(Fade(
                fadesIn: type == .fadeIn,
                startSample: Int64(try reader.number("start_sample", default: 0, range: 0...9.0e15, whole: true)),
                startTime: try reader.optionalSeconds("start_time"),
                sampleCount: Int64(try reader.number("nb_samples", default: 44_100, range: 1...9.0e15, whole: true)),
                duration: try reader.optionalSeconds("duration"),
                curve: try reader.choice("curve", default: .tri),
                silence: try reader.number("silence", default: 0, range: 0...1),
                unity: try reader.number("unity", default: 1, range: 0...1)
            ))
        case "loudnorm":
            guard try reader.flag("linear", default: true) else {
                throw AudioFilterError.badValue(
                    filter: "loudnorm", option: "linear", value: values["linear"] ?? "false",
                    expected: "TextMouth's own loudnorm normalizes with one gain, so it takes only true"
                )
            }
            // LRA is taken as ffmpeg takes it, and has nothing to do in
            // linear normalization, which keeps the loudness range as it is.
            _ = try reader.number("LRA", default: 7, range: 1...50)
            self = .loudness(
                target: try reader.number("I", default: -24, range: -70 ... -5),
                truePeak: try reader.number("TP", default: -2, range: -9...0)
            )
        case "silenceremove":
            self = .silenceRemoval(SilenceRemoval(
                startPeriods: Int(try reader.number("start_periods", default: 0, range: 0...9_000, whole: true)),
                startDuration: try reader.seconds("start_duration", default: 0),
                startThreshold: try reader.amplitude("start_threshold", default: 0, range: 0...1),
                startSilence: try reader.seconds("start_silence", default: 0),
                stopPeriods: Int(try reader.number("stop_periods", default: 0, range: -9_000...9_000, whole: true)),
                stopDuration: try reader.seconds("stop_duration", default: 0),
                stopThreshold: try reader.amplitude("stop_threshold", default: 0, range: 0...1),
                stopSilence: try reader.seconds("stop_silence", default: 0),
                detection: try reader.choice("detection", default: .rms),
                window: try reader.seconds("window", default: 0.02, range: 0.000_1...10)
            ))
        case "acompressor":
            self = .compressor(Compressor(
                levelIn: try reader.amplitude("level_in", default: 1, range: 0.015_625...64),
                threshold: try reader.amplitude("threshold", default: 0.125, range: 0.000_976_563...1),
                ratio: try reader.number("ratio", default: 2, range: 1...20),
                attack: try reader.number("attack", default: 20, range: 0.01...2_000),
                release: try reader.number("release", default: 250, range: 0.01...9_000),
                makeup: try reader.amplitude("makeup", default: 1, range: 1...64),
                knee: try reader.number("knee", default: 2.828_43, range: 1...8),
                detection: try reader.choice("detection", default: .rms),
                mix: try reader.number("mix", default: 1, range: 0...1)
            ))
        case "areverse":
            self = .reverse
        default:
            // Every name with a spec has a case above.
            throw AudioFilterError.unknownFilter(filter.name)
        }
    }

    /// afade's directions, as ffmpeg names them.
    private enum FadeDirection: String, CaseIterable {
        case fadeIn = "in"
        case fadeOut = "out"
    }

    // MARK: Options

    /// One option of a filter as ffmpeg lists it: its names, the long one
    /// first, and whether TextMouth's own filter takes it.
    private struct OptionSpec {
        let names: [String]
        let isSupported: Bool

        init(_ names: String..., supported: Bool = true) {
            self.names = names
            isSupported = supported
        }

        /// The option as an error lists it: "frequency (f)".
        var listed: String {
            names.count > 1 ? "\(names[0]) (\(names.dropFirst().joined(separator: ", ")))" : names[0]
        }
    }

    /// Each filter's options in ffmpeg's order, the ones TextMouth's filter
    /// doesn't take included, so a value given by its place lands where
    /// ffmpeg would put it.
    private static let specs: [String: [OptionSpec]] = {
        let biquad = [
            OptionSpec("frequency", "f"), OptionSpec("width_type", "t"), OptionSpec("width", "w"),
            OptionSpec("poles", "p"), OptionSpec("mix", "m", supported: false),
            OptionSpec("channels", "c", supported: false), OptionSpec("normalize", "n", supported: false),
            OptionSpec("transform", "a", supported: false), OptionSpec("precision", "r", supported: false),
            OptionSpec("blocksize", "b", supported: false),
        ]
        return [
            "volume": [
                OptionSpec("volume"), OptionSpec("precision", supported: false), OptionSpec("eval", supported: false),
                OptionSpec("replaygain", supported: false), OptionSpec("replaygain_preamp", supported: false),
                OptionSpec("replaygain_noclip", supported: false),
            ],
            "atempo": [OptionSpec("tempo")],
            "highpass": biquad,
            "lowpass": biquad,
            "equalizer": [
                OptionSpec("frequency", "f"), OptionSpec("width_type", "t"), OptionSpec("width", "w"),
                OptionSpec("gain", "g"), OptionSpec("mix", "m", supported: false),
                OptionSpec("channels", "c", supported: false), OptionSpec("normalize", "n", supported: false),
                OptionSpec("transform", "a", supported: false), OptionSpec("precision", "r", supported: false),
                OptionSpec("blocksize", "b", supported: false),
            ],
            "afade": [
                OptionSpec("type", "t"), OptionSpec("start_sample", "ss"), OptionSpec("nb_samples", "ns"),
                OptionSpec("start_time", "st"), OptionSpec("duration", "d"), OptionSpec("curve", "c"),
                OptionSpec("silence"), OptionSpec("unity"),
            ],
            "loudnorm": [
                OptionSpec("I", "i"), OptionSpec("LRA", "lra"), OptionSpec("TP", "tp"),
                OptionSpec("measured_I", "measured_i", supported: false),
                OptionSpec("measured_LRA", "measured_lra", supported: false),
                OptionSpec("measured_TP", "measured_tp", supported: false),
                OptionSpec("measured_thresh", supported: false), OptionSpec("offset", supported: false),
                OptionSpec("linear"), OptionSpec("dual_mono", supported: false),
                OptionSpec("print_format", supported: false),
            ],
            "silenceremove": [
                OptionSpec("start_periods"), OptionSpec("start_duration"), OptionSpec("start_threshold"),
                OptionSpec("start_silence"), OptionSpec("start_mode", supported: false), OptionSpec("stop_periods"),
                OptionSpec("stop_duration"), OptionSpec("stop_threshold"), OptionSpec("stop_silence"),
                OptionSpec("stop_mode", supported: false), OptionSpec("detection"), OptionSpec("window"),
                OptionSpec("timestamp", supported: false),
            ],
            "acompressor": [
                OptionSpec("level_in"), OptionSpec("mode", supported: false), OptionSpec("threshold"),
                OptionSpec("ratio"), OptionSpec("attack"), OptionSpec("release"), OptionSpec("makeup"),
                OptionSpec("knee"), OptionSpec("link", supported: false), OptionSpec("detection"),
                OptionSpec("level_sc", supported: false), OptionSpec("mix"),
            ],
            "areverse": [],
        ]
    }()

    /// `filter`'s options by their long names, after checking each against
    /// `spec`. As ffmpeg does, values given by their place come first, in
    /// the filter's order; after the first key=value, every option needs its
    /// key.
    private static func resolve(_ filter: AudioFilterChain.Filter, _ spec: [OptionSpec]) throws -> [String: String] {
        let supported = spec.filter(\.isSupported).map(\.listed)
        var values: [String: String] = [:]
        var position = 0
        var keyed = false
        for option in filter.options {
            let found: OptionSpec
            if let key = option.key {
                keyed = true
                guard let match = spec.first(where: { $0.names.contains(key) }), match.isSupported else {
                    throw AudioFilterError.unknownOption(filter: filter.name, option: key, supported: supported)
                }
                found = match
            } else {
                guard !keyed, position < spec.count else { throw AudioFilterError.tooManyValues(filter: filter.name) }
                found = spec[position]
                position += 1
                guard found.isSupported else {
                    throw AudioFilterError.unknownOption(filter: filter.name, option: found.names[0], supported: supported)
                }
            }
            values[found.names[0]] = option.value
        }
        return values
    }

    /// Reads one filter's option values, each by its long name, checking it.
    private struct ValueReader {
        let filter: String
        let values: [String: String]

        /// The option `name` as a number within `range`, or `fallback` when
        /// it isn't given; with `whole`, a whole number.
        func number(_ name: String, default fallback: Double, range: ClosedRange<Double>, whole: Bool = false) throws -> Double {
            guard let text = values[name] else { return fallback }
            return try checkedNumber(text, for: name, range: range, whole: whole)
        }

        /// The option `name` as a number within `range`, for an option that
        /// must be given, since no default would make a usable filter.
        /// - Throws: `AudioFilterError.missingValue` when it isn't given, or
        ///   `.badValue` for a value `number` would refuse.
        func requiredNumber(_ name: String, range: ClosedRange<Double>) throws -> Double {
            guard let text = values[name] else {
                throw AudioFilterError.missingValue(filter: filter, option: name, expected: Self.expectedNumber(in: range, whole: false))
            }
            return try checkedNumber(text, for: name, range: range, whole: false)
        }

        /// `text`, given for the option `name`, as a number within `range`;
        /// with `whole`, a whole number.
        private func checkedNumber(_ text: String, for name: String, range: ClosedRange<Double>, whole: Bool) throws -> Double {
            guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite,
                  range.contains(value), !whole || value == value.rounded() else {
                throw bad(name, text, expected: Self.expectedNumber(in: range, whole: whole))
            }
            return value
        }

        /// What a number option within `range` takes, as its refusals say
        /// it: "give a number from 0.0001 to 999999".
        private static func expectedNumber(in range: ClosedRange<Double>, whole: Bool) -> String {
            "give \(whole ? "a whole number" : "a number") from "
                + "\(AudioBuiltInFilter.written(range.lowerBound)) to \(AudioBuiltInFilter.written(range.upperBound))"
        }

        /// The option `name` as a linear amplitude within `range`: a plain
        /// number, or decibels such as "-6dB", as ffmpeg reads them.
        func amplitude(_ name: String, default fallback: Double, range: ClosedRange<Double>) throws -> Double {
            guard let text = values[name] else { return fallback }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            var value: Double?
            if trimmed.lowercased().hasSuffix("db") {
                value = Double(trimmed.dropLast(2)).map { pow(10, $0 / 20) }
            } else {
                value = Double(trimmed)
            }
            guard let value, value.isFinite, range.contains(value) else {
                throw bad(name, text, expected: "give a number, such as 0.5, or decibels, such as -6dB")
            }
            return value
        }

        /// The option `name` as a length of time in seconds, or `fallback`.
        func seconds(_ name: String, default fallback: TimeInterval, range: ClosedRange<Double> = 0...86_400) throws -> TimeInterval {
            try optionalSeconds(name, range: range) ?? fallback
        }

        /// The option `name` as a length of time in seconds, or nil when it
        /// isn't given. ffmpeg's forms: "2.5", "250ms", "1:30", "0:01:30.5".
        func optionalSeconds(_ name: String, range: ClosedRange<Double> = 0...86_400) throws -> TimeInterval? {
            guard let text = values[name] else { return nil }
            guard let seconds = Self.duration(text.trimmingCharacters(in: .whitespaces)), range.contains(seconds) else {
                throw bad(name, text, expected: "give a time such as 2.5, 250ms, or 0:01:30")
            }
            return seconds
        }

        /// The option `name` as one of `Choice`'s values, or `fallback`.
        func choice<Choice: RawRepresentable & CaseIterable>(_ name: String, default fallback: Choice) throws -> Choice
            where Choice.RawValue == String {
            guard let text = values[name] else { return fallback }
            guard let choice = Choice(rawValue: text.trimmingCharacters(in: .whitespaces)) else {
                throw bad(name, text, expected: "give one of " + Choice.allCases.map(\.rawValue).joined(separator: ", "))
            }
            return choice
        }

        /// The option `name` as true or false, or `fallback`.
        func flag(_ name: String, default fallback: Bool) throws -> Bool {
            guard let text = values[name] else { return fallback }
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: throw bad(name, text, expected: "give true or false")
            }
        }

        /// The error refusing `text` for the option `name`.
        private func bad(_ name: String, _ text: String, expected: String) -> AudioFilterError {
            .badValue(filter: filter, option: name, value: text, expected: expected)
        }

        /// `text` as ffmpeg's duration syntax reads it, in seconds: "[-][HH:]MM:SS[.m]"
        /// or "S[.m][s|ms|us]"; nil for anything else.
        static func duration(_ text: String) -> Double? {
            if text.contains(":") {
                let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
                let parts = pieces.compactMap { Double($0) }
                guard parts.count == pieces.count, (2...3).contains(parts.count), parts.allSatisfy({ $0 >= 0 }) else {
                    return nil
                }
                return parts.reduce(0) { $0 * 60 + $1 }
            }
            let units: [(suffix: String, scale: Double)] = [("ms", 0.001), ("us", 0.000_001), ("s", 1)]
            for unit in units where text.hasSuffix(unit.suffix) {
                return Double(text.dropLast(unit.suffix.count)).map { $0 * unit.scale }
            }
            return Double(text)
        }
    }
}
