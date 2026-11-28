import Foundation
import os

// The probe of `Scripts/l10n/verify_packs.py` (TL16, TL18, FR39). It has two jobs, each run in a copy of itself placed in
// a folder, which makes the folder `Bundle.main`, with `-AppleLanguages` giving the person's languages.
//
// 1. The engine's reading. The apps ship no table of Apple's since the switch (FR39 phase 8), so the harness compiles the
//    String Catalog into Apple's tables with `xcstringstool` (the compiler Xcode's build used to run), into a folder, and
//    this probe proves that the engine, reading the pack `pack.py` builds from the same catalog, says in every language
//    what Apple's lookup of those tables says. The catalog is keyed by ID, and each ID's English (its `en` text, or a
//    plural's `other` form: the code's English) is the call's format. In the folder's process of each language the probe
//    asks the engine (`InterfaceTextEngine`, over the pack) for every ID at every asking of `InterfaceTextProof` (the 13
//    counts, a second number three places on), and Apple's tables for the same ID (`Bundle.main`'s text, written by
//    `String(format:locale:arguments:)` with the same arguments), in the same process, with the same `Locale.current`. Any
//    difference, and any problem the engine reports, fails. Every language of the folder is in the one bundle, so a lookup
//    that a language's table lacks falls back to English's table exactly as it does in Apple's lookup. A catalog with no
//    `en` for an entry (a fixture of the tool tests, whose keys are English) takes its key for the English.
//
// 2. The system's choice of language. For each preference list given, the probe reports the language
//    `Bundle.main.preferredLocalizations.first` chooses in a folder laid out as the apps' bundles are now: an Info.plist
//    with `CFBundleLocalizations` and an `.lproj` folder with an `InfoPlist.strings` for each language, and no table
//    (the design's "Language choice"). The harness compares each with what the design measured.
//
// Compiled together with TextMouthProductionTests/LanguagePackTests.swift and InterfaceTextShippedPackTests.swift as
// `-D PACK_PROBE`, which leaves those files' tests out and keeps their lookups, so the probe and the hosted tests read
// a bundle in one way, and with the engine's core files (`TextMouth/Localization/InterfaceText/`, less the files that
// read the app's state), so the engine under test is the app's own code.
//
// Usage:
//   probe APPLE_FOLDER CATALOG.xcstrings --pack STRINGS.pack LANGUAGE...
//       prints one line per differing lookup (at most 20), then a summary; the exit status is 1 on any difference or when
//       nothing was compared, and 2 for a usage error or a language the folder lacks.
//   probe --preferences FOLDER LIST...
//       each LIST is comma-separated languages, such as `nb,sv`; prints `PREFERRED LIST -> LANGUAGE` for each.
// Child modes (run by the parent, in the folder's copy):
//   probe --dump CATALOG.xcstrings LANGUAGE --pack STRINGS.pack -AppleLanguages (LANGUAGE)
//   probe --preferred -AppleLanguages (LIST)

/// Reports a usage error and stops.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("probe: \(message)\n".utf8))
    exit(2)
}

/// The catalog's keys (IDs), and for each its English.
struct ProbeCatalog {
    let keys: [String]
    /// Each key's English, the format its lookups are fed from: its `en` text, or a plural's `other` form, else the key.
    let english: [String: String]

    /// Reads the catalog at `url`, or stops with a usage error.
    init(url: URL) {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let strings = root["strings"] as? [String: [String: Any]]
        else { fail("cannot read the catalog at \(url.path)") }
        keys = strings.keys.sorted()
        english = Dictionary(uniqueKeysWithValues: keys.map { key -> (String, String) in
            let en = (strings[key]?["localizations"] as? [String: [String: Any]])?["en"]
            let plain = (en?["stringUnit"] as? [String: Any])?["value"] as? String
            let other = ((((en?["variations"] as? [String: Any])?["plural"] as? [String: Any])?["other"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            return (key, plain ?? other ?? key)
        })
    }
}

// MARK: - The engine's reading

/// The pack the engine reading needs, named on the command line.
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
/// every language in it, so a language that lacks the ID falls back to English's table as the app did), formatted by
/// `String(format:locale:arguments:)` in `Locale.current`, as `String(localized:)` formats a table's text; the text as it
/// is when the call has no arguments (Apple's lookup of a literal returns the table's text unprocessed). An ID that no
/// table holds (a language with no translation, and English's table silent too) comes back as the ID itself, which is no
/// text: the line then shows the call's English, as the engine does when it has no entry, so that is what is formatted.
func appleText(id: String, call: InterfaceText.Format) -> String {
    let found = LanguagePackLookups.effectiveText(Bundle.main, key: id)
    let pattern = found == id ? call.format : found
    return call.arguments.isEmpty ? pattern : String(format: pattern, locale: Locale.current, arguments: call.formatterArguments)
}

/// Compares the engine with Apple's tables for every ID of `catalog` in this process's language: the child's part of
/// the engine reading. Both sides are asked in the same process, in `Locale.current`.
func compareEngine(catalog: ProbeCatalog, language: String, options: EngineOptions) -> EngineSummary {
    // The bundle must have chosen this language, or every Apple lookup below would be English's and prove nothing.
    guard Bundle.main.preferredLocalizations.first == language else {
        fail("Bundle.main chose \(Bundle.main.preferredLocalizations), not \(language), in \(Bundle.main.bundlePath)")
    }
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
    summary.medianLookupMicroseconds = lookupNanoseconds.isEmpty ? 0 : Double(lookupNanoseconds.sorted()[lookupNanoseconds.count / 2]) / 1e3
    summary.problems = reported.withLock { $0 }
    return summary
}

// MARK: - Running a copy of the probe in a folder

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

/// How long a child may run before it is stopped: a dump takes about a second.
let childTimeLimit: TimeInterval = 120

/// Runs `copy` with `arguments` and `-AppleLanguages (preferences)` and returns its output's lines; stops with a usage
/// error when it fails. `-AppleLanguages` is read by Foundation's argument domain, so the bundle chooses by it.
func runChild(copy: URL, arguments: [String], preferences: String) -> [String] {
    let process = Process()
    process.executableURL = copy
    process.arguments = arguments + ["-AppleLanguages", "(\(preferences))"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    do { try process.run() } catch { fail("cannot run \(copy.path): \(error)") }
    // A child that outlives its limit is stopped, so a hung one cannot hold the build.
    DispatchQueue.global().asyncAfter(deadline: .now() + childTimeLimit) { if process.isRunning { process.terminate() } }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fail("the run of \(arguments.first ?? "") with \(preferences) in \(copy.deletingLastPathComponent().path) failed (\(process.terminationStatus))")
    }
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
}

// MARK: - The engine's reading, in every language

/// The languages `folder` holds an `.lproj` for, sorted.
func languagesHeld(in folder: URL) -> Set<String> {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return Set(names.filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(".lproj".count)) })
}

/// Compares the engine with Apple's tables in `appleFolder` for `languages` and prints the result; returns the exit status.
func compare(appleFolder: URL, catalogURL: URL, languages: [String], engine: EngineOptions) -> Int32 {
    // The folder must hold each language (it may hold more, such as one an earlier run left).
    let held = languagesHeld(in: appleFolder)
    guard held.isSuperset(of: languages) else { fail("\(appleFolder.path) lacks \(Set(languages).subtracting(held).sorted())") }
    let copy = installCopy(in: appleFolder)

    var total = EngineSummary()
    var answered = 0
    var idListTimes: [Double] = []
    var languageTimes: [Double] = []
    var lookupMedians: [Double] = []
    for language in languages.sorted() {
        // The engine's reading rides in the folder's process: the folder is that language's main bundle there.
        let lines = runChild(copy: copy, arguments: ["--dump", catalogURL.path, language, "--pack", engine.packURL.path], preferences: language)
        guard let summary = lines.lazy.compactMap({ EngineSummary(line: $0) }).first else { fail("the run for \(language) printed no result") }
        answered += 1
        total.compared += summary.compared
        total.different += summary.different
        total.unfed += summary.unfed
        total.seconds += summary.seconds
        idListTimes.append(summary.idListMilliseconds)
        languageTimes.append(summary.languageMilliseconds)
        lookupMedians.append(summary.medianLookupMicroseconds)
        total.problems += summary.problems.map { "\(language): \($0)" }
        total.differences += summary.differences
        print("probe: engine \(language): \(summary.compared) lookups in \(String(format: "%.2f", summary.seconds)) s with \(summary.locale): \(summary.different) different; decode of the ID list \(String(format: "%.2f", summary.idListMilliseconds)) ms, of this language \(String(format: "%.2f", summary.languageMilliseconds)) ms, median lookup \(String(format: "%.2f", summary.medianLookupMicroseconds)) us")
    }
    for line in total.differences.prefix(20) { print("ENGINE DIFFERENT: \(line)") }
    for line in total.problems.prefix(20) { print("ENGINE PROBLEM: \(line)") }
    print("probe: engine compared \(total.compared) lookups in \(answered) languages (\(String(format: "%.2f", total.seconds)) s): \(total.different) different, \(total.unfed) IDs the lookups cannot feed, \(total.problems.count) problems reported")
    if !languageTimes.isEmpty {
        // The medians of the per-language figures, so one slow language does not stand for all.
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        print("probe: engine timing (-O): ID list decode \(String(format: "%.2f", median(idListTimes))) ms (median of \(idListTimes.count) processes), a language's decode \(String(format: "%.2f", median(languageTimes))) ms (largest \(String(format: "%.2f", languageTimes.max() ?? 0)) ms), median lookup \(String(format: "%.2f", median(lookupMedians))) us")
    }
    // A comparison of nothing proves nothing.
    return answered == languages.count && total.compared > 0 && total.different == 0 && total.unfed == 0 && total.problems.isEmpty ? 0 : 1
}

// MARK: - The system's choice of language

/// Prints the language the system chooses in `folder` for each preference list (`nb,sv` is nb then sv), one line each:
/// `PREFERRED LIST -> LANGUAGE`. The folder is the main bundle of the run, so `Bundle.main.preferredLocalizations` is the
/// choice the app's own engine would take under System (`InterfaceLanguage`).
func reportPreferences(folder: URL, lists: [String]) -> Int32 {
    let copy = installCopy(in: folder)
    for list in lists {
        let lines = runChild(copy: copy, arguments: ["--preferred"], preferences: list.split(separator: ",").joined(separator: ", "))
        print("PREFERRED \(list) -> \(lines.first ?? "(none)")")
    }
    return 0
}

// MARK: - Entry point

let (engineOptions, arguments) = EngineOptions.extract(from: CommandLine.arguments)
if arguments.count >= 2, arguments[1] == "--preferred" {
    // The parent's run of the copy: print the first language the bundle prefers.
    print(Bundle.main.preferredLocalizations.first ?? "(none)")
    exit(0)
}
if arguments.count >= 4, arguments[1] == "--dump" {
    // The parent's run of the copy: the engine's reading of one language.
    guard let engineOptions else { fail("--dump needs --pack") }
    let catalog = ProbeCatalog(url: URL(fileURLWithPath: arguments[2]))
    print(compareEngine(catalog: catalog, language: arguments[3], options: engineOptions).line)
    exit(0)
}
if arguments.count >= 3, arguments[1] == "--preferences" {
    exit(reportPreferences(folder: URL(fileURLWithPath: arguments[2]), lists: Array(arguments.dropFirst(3))))
}
guard arguments.count >= 4, let engineOptions else {
    fail("usage: probe APPLE_FOLDER CATALOG.xcstrings --pack STRINGS.pack LANGUAGE...  |  probe --preferences FOLDER LIST...")
}
exit(compare(
    appleFolder: URL(fileURLWithPath: arguments[1]),
    catalogURL: URL(fileURLWithPath: arguments[2]),
    languages: Array(arguments.dropFirst(3)),
    engine: engineOptions))
