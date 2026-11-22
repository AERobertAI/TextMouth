import Foundation
import os

// The probe of `Scripts/l10n/verify_packs.py` (TL16, TL18, FR39): reads two folders of language files the way the app
// does, and reports every lookup that differs between them. The first folder holds the files as Xcode compiled them,
// the second the same files after `compact_packs.py`. With `--pack` and `--ids` it also reads the interface-text pack
// (`pack.py`'s output) through the engine, and reports every lookup whose text differs from Xcode's `String(localized:)`.
//
// "The way the app does" means through `Bundle.main` with the person's languages set to one language, and with every
// language of the folder in the one bundle. A lookup that a language's table lacks then falls back to English's table
// exactly as it does in the app (a squeezed table that dropped an entry would show it), which a bundle made of one
// language's folder alone cannot. So for each folder and language the probe copies its own executable into the
// folder, which makes the folder `Bundle.main`, and runs that copy with `-AppleLanguages (language)` in the dump
// mode below; the parent then compares the two dumps line by line.
//
// The third reading (FR39) is the engine's. In the Xcode folder's process of each language the probe asks the engine
// (`InterfaceTextEngine`, over the pack) for every ID of every key at every asking of `InterfaceTextProof` (the 13
// counts, a key's second number three places on), and `String(localized:)` for the same call, built at run time from
// the key (a `String.LocalizationValue` with its literal segments and interpolations), in the same process, with the
// same `Locale.current`. Any difference, and any problem the engine reports, fails.
//
// Compiled together with TextMouthProductionTests/LanguagePackTests.swift and InterfaceTextShippedPackTests.swift as
// `-D PACK_PROBE`, which leaves those files' tests out and keeps their lookups, so the probe and the hosted tests read
// a bundle in one way, and with the engine's core files (`TextMouth/Localization/InterfaceText/`, less the files that
// read the app's state), so the engine under test is the app's own code.
//
// Usage:   probe XCODE_FOLDER COMPACT_FOLDER CATALOG.xcstrings [--pack STRINGS.pack --ids IDS.json] [LANGUAGE...]
// Prints one line per differing lookup (at most 20), then a summary; the exit status is 1 on any difference or
// when nothing was compared, and 2 for a usage error or a language the folder lacks.
// Dump mode (run by the parent, in the folder's copy):
//   probe --dump CATALOG.xcstrings LANGUAGE [--pack STRINGS.pack --ids IDS.json] -AppleLanguages (LANGUAGE)

/// Reports a usage error and stops.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("probe: \(message)\n".utf8))
    exit(2)
}

/// The catalog's keys, and for each the languages in which it is a plural string.
struct ProbeCatalog {
    let keys: [String]
    /// The keys that are a plural string in at least one language: each is asked for at every count.
    let pluralKeys: [String]

    /// Reads the catalog at `url`, or stops with a usage error.
    init(url: URL) {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let strings = root["strings"] as? [String: [String: Any]]
        else { fail("cannot read the catalog at \(url.path)") }
        keys = strings.keys.sorted()
        pluralKeys = keys.filter { key in
            let localizations = strings[key]?["localizations"] as? [String: [String: Any]] ?? [:]
            return localizations.values.contains { ($0["variations"] as? [String: Any])?["plural"] != nil }
        }
    }
}

// MARK: - Dump mode

/// One lookup of the dump: a table text (`count` nil) or a plural string's text at a count.
/// `text` is nil when the lookup cannot be formatted (a specifier the lookups cannot feed).
struct DumpedLookup: Equatable {
    let key: String
    let count: Int?
    let text: String?

    /// The line the dump prints: a JSON array of the key, the count (or null), and the text (or null).
    var line: String {
        let countValue: Any = count.map { $0 as Any } ?? NSNull()
        let textValue: Any = text.map { $0 as Any } ?? NSNull()
        let value: [Any] = [key, countValue, textValue]
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads a line the dump printed, or nil when it is not one.
    init?(line: String) {
        guard let array = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [Any], array.count == 3,
              let key = array[0] as? String
        else { return nil }
        self.init(key: key, count: array[1] as? Int, text: array[2] as? String)
    }

    init(key: String, count: Int?, text: String?) {
        self.key = key
        self.count = count
        self.text = text
    }
}

/// Every lookup the app could make in `language`, through `Bundle.main`: each key's table text (the key itself
/// when no table holds it, as the app shows), and each plural key formatted at every count.
func dumpLookups(catalog: ProbeCatalog, language: String) -> [DumpedLookup] {
    // The bundle must have chosen this language, or every lookup below would be English's and prove nothing.
    guard Bundle.main.preferredLocalizations.first == language else {
        fail("Bundle.main chose \(Bundle.main.preferredLocalizations), not \(language), in \(Bundle.main.bundlePath)")
    }
    var lookups: [DumpedLookup] = []
    let plural = Set(catalog.pluralKeys)
    for key in catalog.keys {
        // A plural string's table text is a placeholder for the plural rules, or the plain text that replaced
        // them, so what is compared is the text at each count, below. A plural key whose specifiers the lookups
        // cannot feed has nothing to format, so its table text is compared after all.
        if plural.contains(key), LanguagePackLookups.arguments(forKey: key, count: 0) != nil { continue }
        lookups.append(DumpedLookup(key: key, count: nil, text: LanguagePackLookups.effectiveText(Bundle.main, key: key)))
    }
    for key in catalog.pluralKeys {
        for count in LanguagePackLookups.counts {
            lookups.append(DumpedLookup(
                key: key, count: count,
                text: LanguagePackLookups.pluralText(Bundle.main, key: key, language: language, count: count)))
        }
    }
    return lookups
}

// MARK: - The engine's reading

/// The pack and the ID table the engine reading needs: both named on the command line, or neither.
struct EngineOptions {
    let packURL: URL
    let idsURL: URL

    /// The options in `arguments` (`--pack PATH --ids PATH`, in any place), and the arguments without them; nil
    /// options when neither is given, a usage error when only one is.
    static func extract(from arguments: [String]) -> (options: EngineOptions?, rest: [String]) {
        var pack: String?
        var ids: String?
        var rest: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--pack", index + 1 < arguments.count { pack = arguments[index + 1]; index += 2; continue }
            if arguments[index] == "--ids", index + 1 < arguments.count { ids = arguments[index + 1]; index += 2; continue }
            rest.append(arguments[index])
            index += 1
        }
        guard let pack, let ids else {
            if pack != nil || ids != nil { fail("--pack and --ids go together") }
            return (nil, rest)
        }
        return (EngineOptions(packURL: URL(fileURLWithPath: pack), idsURL: URL(fileURLWithPath: ids)), rest)
    }
}

/// What the engine reading of one language found.
struct EngineSummary {
    /// Lookups compared: each ID of each key at each asking.
    var compared = 0
    /// Lookups whose text differs from `String(localized:)`'s, and the first 20 described.
    var different = 0
    var differences: [String] = []
    /// Keys the lookups could not feed (a specifier other than `%@` and `%lld`): none expected.
    var unfed = 0
    /// What the engine reported as a problem (once each): none expected.
    var problems: [String] = []
    /// The seconds the language's lookups took, both sides included, and the locale they were written with.
    var seconds = 0.0
    var locale = ""

    /// The line the child prints: a JSON object under "engine".
    var line: String {
        let value: [String: Any] = [
            "compared": compared, "different": different, "differences": differences, "unfed": unfed,
            "problems": problems, "seconds": seconds, "locale": locale,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: ["engine": value], options: [.withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads a line the child printed, or nil when it is not one.
    init?(line: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let value = object["engine"] as? [String: Any]
        else { return nil }
        compared = value["compared"] as? Int ?? 0
        different = value["different"] as? Int ?? 0
        differences = value["differences"] as? [String] ?? []
        unfed = value["unfed"] as? Int ?? 0
        problems = value["problems"] as? [String] ?? []
        seconds = value["seconds"] as? Double ?? 0
        locale = value["locale"] as? String ?? ""
    }

    init() {}
}

/// What `String(localized:)` returns for `call`, whose format is `key`: the call built at run time as a
/// `String.LocalizationValue` (a literal segment for the key's text, `%%` as a percent sign, `%@` as a string, `%lld` as
/// an integer) and looked up in `Bundle.main` with `Locale.current`, as a call site `String(localized: "…\(name)…")`
/// is. A key with no argument is a literal. Nil when the key holds a specifier the proof cannot feed.
func appleText(key: String, call: InterfaceText.Format) -> String? {
    if call.arguments.isEmpty { return String(localized: String.LocalizationValue(stringLiteral: key)) }
    var interpolation = String.LocalizationValue.StringInterpolation(literalCapacity: key.utf8.count, interpolationCount: call.arguments.count)
    var literal = ""
    var arguments = call.arguments.makeIterator()
    let characters = Array(key)
    var index = 0
    /// Hands the literal segment so far to the interpolation.
    func flush() {
        if !literal.isEmpty { interpolation.appendLiteral(literal); literal = "" }
    }
    while index < characters.count {
        guard characters[index] == "%", index + 1 < characters.count else { literal.append(characters[index]); index += 1; continue }
        if characters[index + 1] == "%" { literal.append("%"); index += 2; continue }
        flush()
        if characters[index + 1] == "@", case .text(let text)? = arguments.next() {
            interpolation.appendInterpolation(text)
            index += 2
        } else if characters[(index + 1)...].starts(with: "lld"), case .number(let number)? = arguments.next() {
            interpolation.appendInterpolation(Int(number))
            index += 4
        } else {
            return nil
        }
    }
    flush()
    return String(localized: String.LocalizationValue(stringInterpolation: interpolation))
}

/// Compares the engine with `String(localized:)` for every key of `catalog` in this process's language: the child's
/// part of the engine reading. Both sides are asked in the same process, in `Locale.current`.
func compareEngine(catalog: ProbeCatalog, language: String, options: EngineOptions) -> EngineSummary {
    let table: InterfaceTextProof.IDTable
    let pack: InterfaceTextPack
    do {
        table = try InterfaceTextProof.IDTable(contentsOf: options.idsURL)
        pack = try InterfaceTextPack(contentsOf: options.packURL)
    } catch {
        fail("cannot open the pack or the ID table: \(error)")
    }
    // The engine reports a problem once each; the log is Sendable, as the engine's report closure must be.
    let reported = OSAllocatedUnfairLock<[String]>(initialState: [])
    let engine = InterfaceTextEngine(tables: pack, report: { problem in reported.withLock { $0.append(problem) } })
    let locale = Locale.current
    var summary = EngineSummary()
    summary.locale = locale.identifier
    let started = Date()
    for key in catalog.keys {
        guard let ids = table.idsByKey[key] else {
            summary.different += 1
            if summary.differences.count < 20 { summary.differences.append("\(language) \(key.debugDescription): no ID in the table") }
            continue
        }
        for asking in 0..<InterfaceTextProof.askings(ofKey: key) {
            guard let call = InterfaceTextProof.call(forKey: key, asking: asking), let want = appleText(key: key, call: call) else {
                summary.unfed += 1
                break
            }
            for id in ids {
                let got = engine.text(runtimeID: id, english: call, language: language, locale: locale)
                summary.compared += 1
                guard got != want else { continue }
                summary.different += 1
                if summary.differences.count < 20 {
                    summary.differences.append("\(language) \(id) (\(key.debugDescription)) asking \(asking): engine \(got.debugDescription), String(localized:) \(want.debugDescription)")
                }
            }
        }
    }
    summary.seconds = Date().timeIntervalSince(started)
    summary.problems = reported.withLock { $0 }
    return summary
}

// MARK: - Compare mode

/// Copies this program into `folder`, so that a run of the copy has `folder` as its main bundle; returns the copy.
/// The copy is written over any earlier one (nothing is deleted).
func installCopy(in folder: URL) -> URL {
    guard let executable = Bundle.main.executableURL, let bytes = try? Data(contentsOf: executable) else {
        fail("cannot read this program's own executable")
    }
    let copy = folder.appendingPathComponent("pack-probe-copy")
    do {
        try bytes.write(to: copy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
    } catch {
        fail("cannot write \(copy.path): \(error)")
    }
    return copy
}

/// How long a dump may run before it is stopped: a dump takes about a second.
let dumpTimeLimit: TimeInterval = 120

/// Runs `copy` in dump mode for `language` and returns its lookups, and the engine's summary when `engine` names a
/// pack; stops with a usage error when it fails.
func runDump(copy: URL, catalogURL: URL, language: String, engine: EngineOptions? = nil) -> (lookups: [DumpedLookup], engine: EngineSummary?) {
    let process = Process()
    process.executableURL = copy
    // `-AppleLanguages` is read by Foundation's argument domain, so the bundle chooses this one language.
    let engineArguments = engine.map { ["--pack", $0.packURL.path, "--ids", $0.idsURL.path] } ?? []
    process.arguments = ["--dump", catalogURL.path, language] + engineArguments + ["-AppleLanguages", "(\(language))"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    do { try process.run() } catch { fail("cannot run \(copy.path): \(error)") }
    // A dump that outlives its limit is stopped, so a hung one cannot hold the build.
    DispatchQueue.global().asyncAfter(deadline: .now() + dumpTimeLimit) { if process.isRunning { process.terminate() } }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("the dump of \(language) in \(copy.deletingLastPathComponent().path) failed (\(process.terminationStatus))") }
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    return (lines.compactMap { DumpedLookup(line: $0) }, lines.lazy.compactMap { EngineSummary(line: $0) }.first)
}

/// Compares the two folders for `languages` and prints the result; returns the exit status.
func compare(xcodeFolder: URL, compactFolder: URL, catalogURL: URL, requested: [String], engine: EngineOptions?) -> Int32 {
    // The languages to compare: the ones named after the catalog, or else every one the first folder holds. Both
    // folders must hold each of them (a folder may hold more, such as one an earlier run left).
    let languages = requested.isEmpty ? LanguagePackLookups.languages(in: xcodeFolder) : requested.sorted()
    for folder in [xcodeFolder, compactFolder] {
        let held = Set(LanguagePackLookups.languages(in: folder))
        guard held.isSuperset(of: languages) else { fail("\(folder.path) lacks \(Set(languages).subtracting(held).sorted())") }
    }
    let xcodeCopy = installCopy(in: xcodeFolder)
    let compactCopy = installCopy(in: compactFolder)

    var compared = 0
    var found = 0
    var differences: [String] = []
    var engineTotal = EngineSummary()
    var engineFound = 0
    for language in languages {
        // The engine's reading rides in the Xcode folder's process: the folder is that language's main bundle there.
        let (one, summary) = runDump(copy: xcodeCopy, catalogURL: catalogURL, language: language, engine: engine)
        let (two, _) = runDump(copy: compactCopy, catalogURL: catalogURL, language: language)
        if let summary {
            engineFound += 1
            engineTotal.compared += summary.compared
            engineTotal.different += summary.different
            engineTotal.unfed += summary.unfed
            engineTotal.seconds += summary.seconds
            engineTotal.problems += summary.problems.map { "\(language): \($0)" }
            engineTotal.differences += summary.differences
            print("probe: engine \(language): \(summary.compared) lookups in \(String(format: "%.2f", summary.seconds)) s with \(summary.locale): \(summary.different) different")
        }
        guard one.count == two.count else { fail("the two dumps of \(language) hold \(one.count) and \(two.count) lookups") }
        for (first, second) in zip(one, two) {
            compared += 1
            // A found lookup is one that a table answered: a text other than the key, or a plural string.
            if first.text != nil && (first.count != nil || first.text != first.key) { found += 1 }
            guard first != second else { continue }
            let detail = first.count.map { "at \($0)" } ?? "table text"
            differences.append("\(language) \(first.key.debugDescription) \(detail): Xcode's \(String(describing: first.text)), compact \(String(describing: second.text))")
        }
    }
    for line in differences.prefix(20) { print("DIFFERENT: \(line)") }
    print("probe: compared \(compared) lookups in \(languages.count) languages (\(languages.joined(separator: ", "))): \(found) found, \(differences.count) different")
    // The engine's reading: every language's process answered, and nothing differs, goes unfed, or is reported.
    var engineOK = true
    if engine != nil {
        for line in engineTotal.differences.prefix(20) { print("ENGINE DIFFERENT: \(line)") }
        for line in engineTotal.problems.prefix(20) { print("ENGINE PROBLEM: \(line)") }
        print("probe: engine compared \(engineTotal.compared) lookups in \(engineFound) languages (\(String(format: "%.2f", engineTotal.seconds)) s): \(engineTotal.different) different, \(engineTotal.unfed) keys the lookups cannot feed, \(engineTotal.problems.count) problems reported")
        engineOK = engineFound == languages.count && engineTotal.compared > 0 && engineTotal.different == 0
            && engineTotal.unfed == 0 && engineTotal.problems.isEmpty
    }
    // A comparison of nothing, or of lookups that were all absent, proves nothing.
    return differences.isEmpty && compared > 0 && found > 0 && engineOK ? 0 : 1
}

// MARK: - Entry point

let (engineOptions, arguments) = EngineOptions.extract(from: CommandLine.arguments)
if arguments.count >= 4, arguments[1] == "--dump" {
    // The parent's run of the copy: print every lookup of one language, then the engine's reading when asked.
    let catalog = ProbeCatalog(url: URL(fileURLWithPath: arguments[2]))
    for lookup in dumpLookups(catalog: catalog, language: arguments[3]) { print(lookup.line) }
    if let engineOptions { print(compareEngine(catalog: catalog, language: arguments[3], options: engineOptions).line) }
    exit(0)
}
guard arguments.count >= 4 else {
    fail("usage: probe XCODE_FOLDER COMPACT_FOLDER CATALOG.xcstrings [--pack STRINGS.pack --ids IDS.json] [LANGUAGE...]")
}
exit(compare(
    xcodeFolder: URL(fileURLWithPath: arguments[1]),
    compactFolder: URL(fileURLWithPath: arguments[2]),
    catalogURL: URL(fileURLWithPath: arguments[3]),
    requested: Array(arguments.dropFirst(4)),
    engine: engineOptions))
