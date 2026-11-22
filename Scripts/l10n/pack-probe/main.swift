import Foundation
import os

// The probe of `Scripts/l10n/verify_packs.py` (TL16, TL18, FR39): reads two folders of language files the way the app
// does, and reports every lookup that differs between them. The first folder holds the files as Xcode compiled them,
// the second the same files after `compact_packs.py`. With `--pack` it also reads the interface-text pack
// (`pack.py`'s output) through the engine, and reports every lookup whose text differs from Xcode's table for the same ID.
//
// "The way the app does" means through `Bundle.main` with the person's languages set to one language, and with every
// language of the folder in the one bundle. A lookup that a language's table lacks then falls back to English's table
// exactly as it does in the app (a squeezed table that dropped an entry would show it), which a bundle made of one
// language's folder alone cannot. So for each folder and language the probe copies its own executable into the
// folder, which makes the folder `Bundle.main`, and runs that copy with `-AppleLanguages (language)` in the dump
// mode below; the parent then compares the two dumps line by line.
//
// The third reading (FR39) is the engine's. The catalog is keyed by ID, and each ID's English (its `en` text, or a
// plural's `other` form: the code's English) is the call's format. In the Xcode folder's process of each language the probe
// asks the engine (`InterfaceTextEngine`, over the pack) for every ID at every asking of `InterfaceTextProof` (the 13
// counts, a second number three places on), and Apple's tables for the same ID (`Bundle.main`'s text, written by
// `String(format:locale:arguments:)` with the same arguments), in the same process, with the same `Locale.current`. Any
// difference, and any problem the engine reports, fails. A catalog with no `en` for an entry (the squeeze fixtures of the
// tool tests, whose keys are English) takes its key for the English.
//
// Compiled together with TextMouthProductionTests/LanguagePackTests.swift and InterfaceTextShippedPackTests.swift as
// `-D PACK_PROBE`, which leaves those files' tests out and keeps their lookups, so the probe and the hosted tests read
// a bundle in one way, and with the engine's core files (`TextMouth/Localization/InterfaceText/`, less the files that
// read the app's state), so the engine under test is the app's own code.
//
// Usage:   probe XCODE_FOLDER COMPACT_FOLDER CATALOG.xcstrings [--pack STRINGS.pack] [LANGUAGE...]
// Prints one line per differing lookup (at most 20), then a summary; the exit status is 1 on any difference or
// when nothing was compared, and 2 for a usage error or a language the folder lacks.
// Dump mode (run by the parent, in the folder's copy):
//   probe --dump CATALOG.xcstrings LANGUAGE [--pack STRINGS.pack] -AppleLanguages (LANGUAGE)

/// Reports a usage error and stops.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("probe: \(message)\n".utf8))
    exit(2)
}

/// The catalog's keys (IDs), and for each its English and the languages in which it is a plural string.
struct ProbeCatalog {
    let keys: [String]
    /// The keys that are a plural string in at least one language: each is asked for at every count.
    let pluralKeys: [String]
    /// Each key's English, the format its lookups are fed from: its `en` text, or a plural's `other` form, else the key.
    let english: [String: String]

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
        english = Dictionary(uniqueKeysWithValues: keys.map { key -> (String, String) in
            let en = (strings[key]?["localizations"] as? [String: [String: Any]])?["en"]
            let plain = (en?["stringUnit"] as? [String: Any])?["value"] as? String
            let other = ((((en?["variations"] as? [String: Any])?["plural"] as? [String: Any])?["other"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            return (key, plain ?? other ?? key)
        })
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
        if plural.contains(key), LanguagePackLookups.arguments(forKey: catalog.english[key] ?? key, count: 0) != nil { continue }
        lookups.append(DumpedLookup(key: key, count: nil, text: LanguagePackLookups.effectiveText(Bundle.main, key: key)))
    }
    for key in catalog.pluralKeys {
        for count in LanguagePackLookups.counts {
            lookups.append(DumpedLookup(
                key: key, count: count,
                text: LanguagePackLookups.pluralText(Bundle.main, key: key, english: catalog.english[key] ?? key, language: language, count: count)))
        }
    }
    return lookups
}

// MARK: - The engine's reading

/// The pack the engine reading needs, named on the command line or not at all.
struct EngineOptions {
    let packURL: URL

    /// The options in `arguments` (`--pack PATH`, in any place), and the arguments without them; nil options when it is
    /// not given.
    static func extract(from arguments: [String]) -> (options: EngineOptions?, rest: [String]) {
        var pack: String?
        var rest: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--pack", index + 1 < arguments.count { pack = arguments[index + 1]; index += 2; continue }
            rest.append(arguments[index])
            index += 1
        }
        guard let pack else { return (nil, rest) }
        return (EngineOptions(packURL: URL(fileURLWithPath: pack)), rest)
    }
}

/// What the engine reading of one language found.
struct EngineSummary {
    /// Lookups compared: each ID at each asking.
    var compared = 0
    /// Lookups whose text differs from Apple's table's, and the first 20 described.
    var different = 0
    var differences: [String] = []
    /// IDs the lookups could not feed (a specifier other than `%@` and `%lld`): none expected.
    var unfed = 0
    /// What the engine reported as a problem (once each): none expected.
    var problems: [String] = []
    /// The seconds the language's lookups took, both sides included, and the locale they were written with.
    var seconds = 0.0
    var locale = ""
    /// What the engine's own work costs (the probe is compiled -O): milliseconds to decode the ID list and this
    /// language's entries, each on its own, and the median microseconds of one engine lookup (Apple's side excluded).
    var idListMilliseconds = 0.0
    var languageMilliseconds = 0.0
    var medianLookupMicroseconds = 0.0

    /// The line the child prints: a JSON object under "engine".
    var line: String {
        let value: [String: Any] = [
            "compared": compared, "different": different, "differences": differences, "unfed": unfed,
            "problems": problems, "seconds": seconds, "locale": locale, "idListMilliseconds": idListMilliseconds,
            "languageMilliseconds": languageMilliseconds, "medianLookupMicroseconds": medianLookupMicroseconds,
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
        idListMilliseconds = value["idListMilliseconds"] as? Double ?? 0
        languageMilliseconds = value["languageMilliseconds"] as? Double ?? 0
        medianLookupMicroseconds = value["medianLookupMicroseconds"] as? Double ?? 0
    }

    init() {}
}

/// What Apple's tables say for the ID `id` written with `call`'s arguments: the bundle's text for the ID (`Bundle.main`,
/// every language in it, so a language that lacks the ID falls back to English's table as the app does), formatted by
/// `String(format:locale:arguments:)` in `Locale.current`, as `String(localized:)` formats a table's text; the text as it
/// is when the call has no arguments (Apple's lookup of a literal returns the table's text unprocessed). An ID that no
/// table holds (a language with no translation, and English's table silent too) comes back as the ID itself, which is no
/// text: the line then shows the call's English, as the app does when it has no entry, so that is what is formatted.
func appleText(id: String, call: InterfaceText.Format) -> String {
    let found = LanguagePackLookups.effectiveText(Bundle.main, key: id)
    let pattern = found == id ? call.format : found
    return call.arguments.isEmpty ? pattern : String(format: pattern, locale: Locale.current, arguments: call.formatterArguments)
}

/// Compares the engine with Apple's tables for every ID of `catalog` in this process's language: the child's part of
/// the engine reading. Both sides are asked in the same process, in `Locale.current`.
func compareEngine(catalog: ProbeCatalog, language: String, options: EngineOptions) -> EngineSummary {
    let pack: InterfaceTextPack
    do {
        pack = try InterfaceTextPack(contentsOf: options.packURL)
    } catch {
        fail("cannot open the pack: \(error)")
    }
    // The engine reports a problem once each; the log is Sendable, as the engine's report closure must be.
    let reported = OSAllocatedUnfairLock<[String]>(initialState: [])
    let engine = InterfaceTextEngine(tables: pack, report: { problem in reported.withLock { $0.append(problem) } })
    let locale = Locale.current
    var summary = EngineSummary()
    summary.locale = locale.identifier
    // The engine's decoding on its own, timed apart from the lookups: the ID list, then this language's entries.
    let idsStarted = DispatchTime.now().uptimeNanoseconds
    guard (try? pack.idList()) != nil else { fail("the ID list cannot be decoded") }
    summary.idListMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - idsStarted) / 1e6
    let languageStarted = DispatchTime.now().uptimeNanoseconds
    guard (try? pack.entries(language: language)) != nil else { fail("the \(language) entries cannot be decoded") }
    summary.languageMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - languageStarted) / 1e6
    var lookupNanoseconds: [UInt64] = []
    let started = Date()
    for id in catalog.keys {
        let english = catalog.english[id] ?? id
        for asking in 0..<InterfaceTextProof.askings(ofEnglish: english) {
            guard let call = InterfaceTextProof.call(forEnglish: english, asking: asking) else {
                summary.unfed += 1
                break
            }
            let want = appleText(id: id, call: call)
            let began = DispatchTime.now().uptimeNanoseconds
            let got = engine.text(runtimeID: id, english: call, language: language, locale: locale)
            lookupNanoseconds.append(DispatchTime.now().uptimeNanoseconds - began)
            summary.compared += 1
            guard got != want else { continue }
            summary.different += 1
            if summary.differences.count < 20 {
                summary.differences.append("\(language) \(id) (\(english.debugDescription)) asking \(asking): engine \(got.debugDescription), Apple's table \(want.debugDescription)")
            }
        }
    }
    summary.seconds = Date().timeIntervalSince(started)
    summary.medianLookupMicroseconds = Double(lookupNanoseconds.sorted()[lookupNanoseconds.count / 2]) / 1e3
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
    let engineArguments = engine.map { ["--pack", $0.packURL.path] } ?? []
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
    var idListTimes: [Double] = []
    var languageTimes: [Double] = []
    var lookupMedians: [Double] = []
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
            idListTimes.append(summary.idListMilliseconds)
            languageTimes.append(summary.languageMilliseconds)
            lookupMedians.append(summary.medianLookupMicroseconds)
            engineTotal.problems += summary.problems.map { "\(language): \($0)" }
            engineTotal.differences += summary.differences
            print("probe: engine \(language): \(summary.compared) lookups in \(String(format: "%.2f", summary.seconds)) s with \(summary.locale): \(summary.different) different; decode of the ID list \(String(format: "%.2f", summary.idListMilliseconds)) ms, of this language \(String(format: "%.2f", summary.languageMilliseconds)) ms, median lookup \(String(format: "%.2f", summary.medianLookupMicroseconds)) us")
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
        print("probe: engine compared \(engineTotal.compared) lookups in \(engineFound) languages (\(String(format: "%.2f", engineTotal.seconds)) s): \(engineTotal.different) different, \(engineTotal.unfed) IDs the lookups cannot feed, \(engineTotal.problems.count) problems reported")
        if !languageTimes.isEmpty {
            // The medians of the per-language figures, so one slow language does not stand for all.
            func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            print("probe: engine timing (-O): ID list decode \(String(format: "%.2f", median(idListTimes))) ms (median of \(idListTimes.count) processes), a language's decode \(String(format: "%.2f", median(languageTimes))) ms (largest \(String(format: "%.2f", languageTimes.max() ?? 0)) ms), median lookup \(String(format: "%.2f", median(lookupMedians))) us")
        }
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
    fail("usage: probe XCODE_FOLDER COMPACT_FOLDER CATALOG.xcstrings [--pack STRINGS.pack] [LANGUAGE...]")
}
exit(compare(
    xcodeFolder: URL(fileURLWithPath: arguments[1]),
    compactFolder: URL(fileURLWithPath: arguments[2]),
    catalogURL: URL(fileURLWithPath: arguments[3]),
    requested: Array(arguments.dropFirst(4)),
    engine: engineOptions))
