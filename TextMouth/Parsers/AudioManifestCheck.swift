import Foundation

// MARK: - What Is Wrong

/// What is wrong with an audiobook archive's manifest.json, found as the
/// archive is imported (`AudioManifestCheck`). Each problem is said in a
/// sentence or two that begin with the file's name and say what is wrong
/// and where: a key's name, an entry's number in a list, a file's name, or,
/// for a file that is not JSON, the line and column. A person who wrote the
/// manifest by hand, with a screen reader, hears what to fix; the import's
/// alert reads "Could not import “Radio.zip”. Reading its manifest failed:
/// manifest.json …" (`ImportFailure`).
enum AudioManifestProblem: LocalizedError, Equatable {
    /// The file could not be read at all, for `reason`.
    case unreadable(reason: String)
    /// The file is rich text, as TextEdit saves a new document, not plain
    /// text.
    case richText
    /// The file is not valid JSON, for `reason`: Foundation's words, with
    /// the line and column where it stopped. `hasCurlyQuotes` when the file
    /// holds curly quotation marks, which TextEdit's Smart Quotes make.
    case invalidJSON(reason: String, hasCurlyQuotes: Bool)
    /// The file holds `found` ("a list", "text") where one object belongs.
    case notAnObject(found: String)
    /// `keys` TextMouth doesn't know, at the top level when `entry` is nil,
    /// otherwise in that entry of tracks, counted from 1.
    case unknownKeys([String], entry: Int?)
    /// The value at `place` ("pauseAfterMs in entry 3 of tracks") is
    /// `found` ("text") where `expected` belongs ("a number of
    /// milliseconds").
    case wrongKind(place: String, expected: String, found: String)
    /// The pause at `place` is `value` milliseconds, outside the pauses a
    /// manifest may give (`AudioManifest.pauseRangeMs`).
    case pauseOutOfRange(place: String, value: Double)
    /// Entry `entry` of tracks has both file and heading.
    case fileAndHeading(entry: Int)
    /// Entry `entry` of tracks has neither file nor heading.
    case neitherFileNorHeading(entry: Int)
    /// Entry `entry` of tracks, a group heading, also has `keys`, which
    /// belong to a track.
    case trackKeysOnHeading([String], entry: Int)
    /// Entry `entry` of tracks gives an empty `key` ("file" or "heading").
    case empty(key: String, entry: Int)
    /// tracks beside `keys`, the older ways of arranging a book.
    case tracksWithOlderKeys([String])
    /// `files`, named in `key`, that are not among the archive's audio
    /// files.
    case missingFiles([String], key: String)
    /// `files` that tracks lists more than once.
    case repeatedFiles([String])
    /// The group heading `heading`, entry `entry` of tracks, with no track
    /// listed after it before the next group heading, or, `atEnd`, before
    /// the end of the list.
    case headingWithoutTrack(heading: String, entry: Int, atEnd: Bool)
    /// What reading the manifest refused once every other check had passed,
    /// as a section's clips, which only TextMouth writes, can be: the
    /// place, and what is wrong there ("entry 2 of segments has no
    /// startTime").
    case unreadableValue(String)

    /// What an entry of tracks is, said after each problem with an entry's
    /// file and heading.
    private static let entryKinds = "An entry is a track, with file, or a group heading, with heading."

    /// How names are spelled, said after names that match no audio file.
    private static let spelling =
        "Names are written as seen from the manifest's own folder, exactly, with the letters' case and the extension."

    var errorDescription: String? {
        switch self {
        case .unreadable(let reason):
            return "manifest.json could not be read: \(Self.sentence(reason))"
        case .richText:
            return "manifest.json is saved as rich text, and must be plain text. "
                + "In TextEdit, choose Format, Make Plain Text, then save it."
        case .invalidJSON(let reason, let hasCurlyQuotes):
            let quotes = hasCurlyQuotes
                ? " It holds curly quotation marks, which TextEdit's Smart Quotes make as you type; "
                    + "JSON needs straight ones. Turn off Smart Quotes under Edit, Substitutions, "
                    + "and type the quotation marks again."
                : ""
            return "manifest.json is not valid JSON: \(Self.sentence(reason))\(quotes)"
        case .notAnObject(let found):
            return "manifest.json must hold one object, in curly braces, but it holds \(found)."
        case .unknownKeys(let keys, nil):
            let known = CountWording.list(AudioManifest.CodingKeys.allCases.map(\.rawValue))
            return "manifest.json has \(Self.keys(keys)) TextMouth doesn't know: \(Self.quotedList(keys)). "
                + "The keys it knows are \(known)."
        case .unknownKeys(let keys, let entry?):
            return "manifest.json has \(Self.keys(keys)) TextMouth doesn't know in entry \(entry) of tracks: "
                + "\(Self.quotedList(keys)). \(Self.entryKeys)"
        case .wrongKind(let place, let expected, let found):
            return "manifest.json: \(place) must be \(expected), not \(found)."
        case .pauseOutOfRange(let place, let value):
            let range = AudioManifest.pauseRangeMs
            return "manifest.json: \(place) is \(Self.number(value)), but a pause is from "
                + "\(Self.number(range.lowerBound)) to \(Self.number(range.upperBound)) milliseconds."
        case .fileAndHeading(let entry):
            return "manifest.json: entry \(entry) of tracks has both file and heading. \(Self.entryKinds)"
        case .neitherFileNorHeading(let entry):
            return "manifest.json: entry \(entry) of tracks has neither file nor heading. \(Self.entryKinds)"
        case .trackKeysOnHeading(let keys, let entry):
            return "manifest.json: entry \(entry) of tracks is a group heading, which takes heading alone, "
                + "not \(CountWording.list(keys))."
        case .empty(let key, let entry):
            let need = key == AudioManifestEntry.CodingKeys.heading.rawValue
                ? "A group heading needs words."
                : "A track needs its file's name."
            return "manifest.json: the \(key) in entry \(entry) of tracks is empty. \(need)"
        case .tracksWithOlderKeys(let keys):
            return "manifest.json has tracks together with \(CountWording.list(keys)). "
                + "Use tracks alone: it gives the book's order and titles itself."
        case .missingFiles(let files, let key):
            let named = files.count == 1
                ? "a file in \(key) that isn't"
                : "\(files.count) files in \(key) that aren't"
            return "manifest.json names \(named) among the archive's audio files: \(Self.quotedList(files)). "
                + Self.spelling
        case .repeatedFiles(let files):
            let listed = files.count == 1 ? "a file" : "\(files.count) files"
            return "manifest.json lists \(listed) more than once in tracks: \(Self.quotedList(files))."
        case .headingWithoutTrack(let heading, let entry, let atEnd):
            let before = atEnd ? "the end of tracks" : "the next heading"
            return "manifest.json: the group heading “\(heading)”, entry \(entry) of tracks, "
                + "has no track after it before \(before)."
        case .unreadableValue(let description):
            return "manifest.json: \(description)."
        }
    }

    /// The keys of a tracks entry, said after a key TextMouth doesn't know
    /// in one.
    private static var entryKeys: String {
        let track = AudioManifestEntry.CodingKeys.allCases.filter { $0 != .heading }.map(\.rawValue)
        return "A track's keys are \(CountWording.list(track)); a group heading's is "
            + "\(AudioManifestEntry.CodingKeys.heading.rawValue)."
    }

    /// "a key" or "keys", as many as `keys` holds.
    private static func keys(_ keys: [String]) -> String {
        keys.count == 1 ? "a key" : "keys"
    }

    /// `names` in quotation marks, as a sentence lists them, the first five
    /// and then how many more: "“a.ogg”, “b.ogg”, and 3 more".
    static func quotedList(_ names: [String]) -> String {
        let shown = names.prefix(5).map { "“\($0)”" }
        let more = names.count - shown.count
        return CountWording.list(more > 0 ? shown + ["\(more) more"] : Array(shown))
    }

    /// `value` as a person writes it: a whole number without a decimal
    /// point, any other as Swift writes it.
    static func number(_ value: Double) -> String {
        guard value.isFinite, value == value.rounded(), abs(value) < 1e15 else { return "\(value)" }
        return String(Int64(value))
    }

    /// `text` ending with a full stop, as a sentence does.
    private static func sentence(_ text: String) -> String {
        text.hasSuffix(".") ? text : text + "."
    }
}

// MARK: - The Checks

/// The checks an import makes of an audiobook archive's manifest.json
/// before it reads the book by it (October 13, 2026). A manifest that
/// cannot be read was once passed over without a word, and the book
/// imported in Finder's order, which a person writing JSON by hand, with a
/// screen reader, cannot tell from success; now its first problem stops
/// the import, said as `AudioManifestProblem` says it.
///
/// The checks run in the order a person fixes things: the file itself, its
/// JSON, the keys, the kind of each value and each pause, how the book is
/// arranged, each entry of tracks, then the files the manifest names and
/// the group headings' tracks. Only the import checks: a book that has
/// imported reads its manifest leniently ever after
/// (`AudioManifest.read(inAudioFolder:)`), so a book that opens today still
/// opens.
enum AudioManifestCheck {
    /// The manifest at `location` in the audiobook folder `folder`, checked
    /// and read.
    ///
    /// - Parameter scan: which tracks the manifest may name: the import's
    ///   checks, before the conversion, take every format the import
    ///   accepts (the default, as before); a manifest edit on a book takes
    ///   the package's (`AudioBookParser.TrackScan`). The edit passes it
    ///   explicitly.
    /// - Throws: `AudioManifestProblem` for the first problem found.
    static func checkedManifest(
        at location: AudioManifestLocation,
        audioFolder folder: URL,
        scan: AudioBookParser.TrackScan = .importing
    ) throws -> AudioManifest {
        let data: Data
        do {
            data = try Data(contentsOf: location.url)
        } catch {
            throw AudioManifestProblem.unreadable(reason: error.localizedDescription)
        }
        let object = try topLevelObject(of: data)
        try checkTopLevel(object)
        try checkTracksEntries(object)
        let manifest = try decodedAfterChecks(data)
        try checkFilesNamed(by: manifest, at: location, audioFolder: folder, scan: scan)
        try checkGroupHeadings(of: manifest)
        return manifest
    }

    // MARK: The File and Its JSON

    /// The one object `data` holds, past a UTF-8 byte order mark.
    ///
    /// - Throws: `.richText` for a file TextEdit saved as rich text,
    ///   `.invalidJSON` for any other file that is not JSON, and
    ///   `.notAnObject` for JSON that is not one object.
    private static func topLevelObject(of data: Data) throws -> [String: Any] {
        let text = AudioManifest.withoutByteOrderMark(data)
        if text.starts(with: Data(#"{\rtf"#.utf8)) {
            throw AudioManifestProblem.richText
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: text, options: [.fragmentsAllowed])
        } catch {
            throw AudioManifestProblem.invalidJSON(
                reason: foundationReason(for: error, in: text),
                hasCurlyQuotes: String(decoding: text, as: UTF8.self).contains { $0 == "\u{201C}" || $0 == "\u{201D}" }
            )
        }
        guard let object = parsed as? [String: Any] else {
            throw AudioManifestProblem.notAnObject(found: kind(of: parsed))
        }
        return object
    }

    /// Why Foundation found `data` not to be JSON, in its own words, with
    /// the place it stopped given as an editor counts it: the line and the
    /// column, each from 1, the column in characters, of the byte Foundation
    /// stopped at (`NSJSONSerializationErrorIndex`). Foundation's own
    /// sentence ("Badly formed object around line 3, column 2.") counts
    /// columns from 0 and in bytes, which puts a reader one place early, and
    /// further on a line with letters outside ASCII; it is kept whole when
    /// it gives no place to replace.
    static func foundationReason(for error: any Error, in data: Data) -> String {
        let info = (error as NSError).userInfo
        let words = info[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
        guard let index = info["NSJSONSerializationErrorIndex"] as? Int, (0...data.count).contains(index),
              let place = words.range(of: #"\s+around line \d+, column \d+\.?$"#, options: .regularExpression)
        else { return words }
        // The lines before the place, split as NSString splits them, so a
        // carriage return before a line feed ends a line too.
        let lines = String(decoding: data.prefix(index), as: UTF8.self).components(separatedBy: "\n")
        let column = (lines.last ?? "").count + 1
        return "\(words[..<place.lowerBound]) around line \(lines.count), column \(column)."
    }

    // MARK: The Keys and Their Values

    /// What a value must be, as a problem says it.
    private enum Expected: String {
        case text = "text in quotation marks"
        case fileName = "a file's name in quotation marks"
        case milliseconds = "a number of milliseconds"
        case list = "a list, in square brackets"
        case object = "an object, in curly braces"
        case entry = "a file's name in quotation marks, or an object in curly braces"

        /// Whether `value`, as JSONSerialization reads it, is of this kind.
        func admits(_ value: Any) -> Bool {
            switch self {
            case .text, .fileName: return value is String
            case .milliseconds: return AudioManifestCheck.isNumber(value)
            case .list: return value is [Any]
            case .object: return value is [String: Any]
            case .entry: return value is String || value is [String: Any]
            }
        }
    }

    /// The top level's keys, the kind of each value, the pause between
    /// tracks, and the way the book is arranged. A key holding null is
    /// absent, as the manifest's reading takes it.
    ///
    /// - Throws: `.unknownKeys`, `.wrongKind`, `.pauseOutOfRange`, or
    ///   `.tracksWithOlderKeys`.
    private static func checkTopLevel(_ object: [String: Any]) throws {
        let known = Set(AudioManifest.CodingKeys.allCases.map(\.rawValue))
        let unknown = object.keys.filter { !known.contains($0) }.sortedStably()
        guard unknown.isEmpty else {
            throw AudioManifestProblem.unknownKeys(unknown, entry: nil)
        }
        for key in AudioManifest.CodingKeys.allCases {
            guard let value = present(object[key.rawValue]) else { continue }
            let name = key.rawValue
            switch key {
            case .title, .author:
                try require(value, .text, at: name)
            case .pauseBetweenTracksMs:
                try requirePause(value, at: name)
            case .tracks, .segments:
                try require(value, .list, at: name)
            case .order:
                try require(value, .list, at: name)
                for (number, entry) in ((value as? [Any]) ?? []).enumerated() {
                    try require(entry, .fileName, at: "entry \(number + 1) of order")
                }
            case .chapters:
                try require(value, .object, at: name)
                let titles = (value as? [String: Any]) ?? [:]
                for file in titles.keys.sortedStably() {
                    try require(titles[file] ?? NSNull(), .text, at: "the title for “\(file)” in chapters")
                }
            }
        }
        if present(object[AudioManifest.CodingKeys.tracks.rawValue]) != nil {
            let older: [AudioManifest.CodingKeys] = [.order, .chapters, .segments]
            let beside = older.filter { present(object[$0.rawValue]) != nil }.map(\.rawValue)
            guard beside.isEmpty else {
                throw AudioManifestProblem.tracksWithOlderKeys(beside)
            }
        }
    }

    /// Each entry of tracks: its kind; an object's keys, the kind of each
    /// value, and its pause; whether it is a track or a group heading; and
    /// whether its file or heading is empty.
    ///
    /// - Throws: the problem of the first entry that has one.
    private static func checkTracksEntries(_ object: [String: Any]) throws {
        typealias Key = AudioManifestEntry.CodingKeys
        let entries = (present(object[AudioManifest.CodingKeys.tracks.rawValue]) as? [Any]) ?? []
        let known = Set(Key.allCases.map(\.rawValue))
        for (offset, entry) in entries.enumerated() {
            let number = offset + 1
            let place = "entry \(number) of tracks"
            try require(entry, .entry, at: place)
            guard let fields = entry as? [String: Any] else {
                // A track given by its file's name alone.
                if let file = entry as? String, file.nonBlank == nil {
                    throw AudioManifestProblem.empty(key: Key.file.rawValue, entry: number)
                }
                continue
            }
            let unknown = fields.keys.filter { !known.contains($0) }.sortedStably()
            guard unknown.isEmpty else {
                throw AudioManifestProblem.unknownKeys(unknown, entry: number)
            }
            for key in Key.allCases {
                guard let value = present(fields[key.rawValue]) else { continue }
                if key == .pauseAfterMs {
                    try requirePause(value, at: "\(key.rawValue) in \(place)")
                } else {
                    try require(value, key == .file ? .fileName : .text, at: "\(key.rawValue) in \(place)")
                }
            }
            let file = present(fields[Key.file.rawValue]) as? String
            let heading = present(fields[Key.heading.rawValue]) as? String
            switch (file, heading) {
            case (_?, _?):
                throw AudioManifestProblem.fileAndHeading(entry: number)
            case (nil, nil):
                throw AudioManifestProblem.neitherFileNorHeading(entry: number)
            case (let file?, nil):
                if file.nonBlank == nil {
                    throw AudioManifestProblem.empty(key: Key.file.rawValue, entry: number)
                }
            case (nil, let heading?):
                let trackKeys = [Key.title, Key.pauseAfterMs].map(\.rawValue).filter { present(fields[$0]) != nil }
                guard trackKeys.isEmpty else {
                    throw AudioManifestProblem.trackKeysOnHeading(trackKeys, entry: number)
                }
                if heading.nonBlank == nil {
                    throw AudioManifestProblem.empty(key: Key.heading.rawValue, entry: number)
                }
            }
        }
    }

    /// `value`, or nil when it is absent or JSON's null, which the
    /// manifest's reading takes for absent.
    private static func present(_ value: Any?) -> Any? {
        guard let value, !(value is NSNull) else { return nil }
        return value
    }

    /// Throws `.wrongKind` at `place` unless `value` is what `expected`
    /// names.
    private static func require(_ value: Any, _ expected: Expected, at place: String) throws {
        guard expected.admits(value) else {
            throw AudioManifestProblem.wrongKind(place: place, expected: expected.rawValue, found: kind(of: value))
        }
    }

    /// Throws `.wrongKind` at `place` unless `value` is a number, and
    /// `.pauseOutOfRange` unless it is a pause a manifest may give.
    private static func requirePause(_ value: Any, at place: String) throws {
        try require(value, .milliseconds, at: place)
        let milliseconds = (value as? NSNumber)?.doubleValue ?? 0
        guard AudioManifest.pauseRangeMs.contains(milliseconds) else {
            throw AudioManifestProblem.pauseOutOfRange(place: place, value: milliseconds)
        }
    }

    /// Whether `value`, as JSONSerialization reads it, is a number: true and
    /// false come as numbers too, and are not.
    fileprivate static func isNumber(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID()
    }

    /// What `value`, as JSONSerialization reads it, is, as a problem names
    /// what it found: "text", "a number", "true", "false", "a list", "an
    /// object", or "null".
    static func kind(of value: Any) -> String {
        if value is String {
            return "text"
        }
        if let number = value as? NSNumber {
            guard isNumber(number) else { return number.boolValue ? "true" : "false" }
            return "a number"
        }
        if value is [Any] {
            return "a list"
        }
        if value is [String: Any] {
            return "an object"
        }
        return "null"
    }

    // MARK: Reading It

    /// The manifest `data` holds, read as every read of the book reads it,
    /// once every check of its JSON has passed. What the reading still
    /// refuses, which only the sections TextMouth writes for a DAISY book
    /// can hold, is said by its place.
    ///
    /// - Throws: `.unreadableValue`.
    private static func decodedAfterChecks(_ data: Data) throws -> AudioManifest {
        do {
            return try AudioManifest.decoded(from: data)
        } catch let DecodingError.keyNotFound(key, context) {
            throw AudioManifestProblem.unreadableValue("\(place(of: context.codingPath)) has no \(key.stringValue)")
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            throw AudioManifestProblem.unreadableValue("\(place(of: context.codingPath)) holds a value of the wrong kind")
        } catch let DecodingError.dataCorrupted(context) {
            throw AudioManifestProblem.unreadableValue("\(place(of: context.codingPath)) can't be read")
        } catch {
            throw AudioManifestProblem.unreadableValue("its contents can't be read (\(error.localizedDescription))")
        }
    }

    /// The place `path`, a coding path into the manifest, names, as a
    /// problem says it: "startTime in entry 2 of segments"; "its top level"
    /// for the manifest itself.
    static func place(of path: [any CodingKey]) -> String {
        var places: [String] = []
        var position = 0
        while position < path.count {
            let key = path[position]
            if position + 1 < path.count, let index = path[position + 1].intValue {
                places.append("entry \(index + 1) of \(key.stringValue)")
                position += 2
            } else {
                places.append(key.stringValue)
                position += 1
            }
        }
        return places.isEmpty ? "its top level" : places.reversed().joined(separator: " in ")
    }

    // MARK: The Files and the Headings

    /// Every file `manifest` names in tracks, order, and chapters is among
    /// the archive's audio files, as the manifest spells them (from its own
    /// folder, `location`), and tracks lists none twice. A folder whose
    /// tracks cannot be listed is left to the reading of the book, which
    /// says why.
    ///
    /// - Parameter scan: which files count as the folder's tracks.
    /// - Throws: `.missingFiles` naming the first key whose files are not
    ///   all there, or `.repeatedFiles`.
    private static func checkFilesNamed(
        by manifest: AudioManifest,
        at location: AudioManifestLocation,
        audioFolder folder: URL,
        scan: AudioBookParser.TrackScan
    ) throws {
        guard let paths = try? AudioBookParser.trackPaths(in: folder, scan: scan) else { return }
        let available = Set(paths.map(location.name(ofTrackAt:)))
        let listed = (manifest.tracks ?? []).compactMap { entry -> String? in
            guard case .track(let track) = entry else { return nil }
            return track.file
        }
        let named: [(key: AudioManifest.CodingKeys, files: [String])] = [
            (.tracks, listed),
            (.order, manifest.order ?? []),
            (.chapters, (manifest.chapters ?? [:]).keys.sortedStably())
        ]
        for (key, files) in named {
            let missing = uniqued(files.filter { !available.contains($0) })
            guard missing.isEmpty else {
                throw AudioManifestProblem.missingFiles(missing, key: key.rawValue)
            }
        }
        var seen = Set<String>()
        let repeated = uniqued(listed.filter { !seen.insert($0).inserted })
        guard repeated.isEmpty else {
            throw AudioManifestProblem.repeatedFiles(repeated)
        }
    }

    /// Every group heading in tracks has a track listed after it before the
    /// next group heading or the end of the list.
    ///
    /// - Throws: `.headingWithoutTrack` for the first that has none.
    private static func checkGroupHeadings(of manifest: AudioManifest) throws {
        let entries = manifest.tracks ?? []
        for (offset, entry) in entries.enumerated() {
            guard case .heading(let heading) = entry else { continue }
            let following = entries[(offset + 1)...]
            let nextHeading = following.firstIndex {
                if case .heading = $0 { return true }
                return false
            }
            let group = following[..<(nextHeading ?? entries.endIndex)]
            let hasTrack = group.contains {
                if case .track = $0 { return true }
                return false
            }
            guard hasTrack else {
                throw AudioManifestProblem.headingWithoutTrack(heading: heading, entry: offset + 1, atEnd: nextHeading == nil)
            }
        }
    }

    /// `names` with each name kept once, where it first comes.
    private static func uniqued(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}
