import Foundation

// The probe of `Scripts/l10n/verify_packs.py` (TL16, TL18): reads two folders of language files the way the app does,
// and reports every lookup that differs between them. The first folder holds the files as Xcode compiled them, the
// second the same files after `compact_packs.py`.
//
// "The way the app does" means through `Bundle.main` with the person's languages set to one language, and with every
// language of the folder in the one bundle. A lookup that a language's table lacks then falls back to English's table
// exactly as it does in the app (a squeezed table that dropped an entry would show it), which a bundle made of one
// language's folder alone cannot. So for each folder and language the probe copies its own executable into the
// folder, which makes the folder `Bundle.main`, and runs that copy with `-AppleLanguages (language)` in the dump
// mode below; the parent then compares the two dumps line by line.
//
// Compiled together with TextMouthProductionTests/LanguagePackTests.swift as `-D PACK_PROBE`, which leaves that
// file's tests out and keeps its lookups, so the probe and the hosted test read a bundle in one way.
//
// Usage:   probe XCODE_FOLDER COMPACT_FOLDER CATALOG.xcstrings [LANGUAGE...]
// Prints one line per differing lookup (at most 20), then a summary; the exit status is 1 on any difference or
// when nothing was compared, and 2 for a usage error or a language the folder lacks.
// Dump mode (run by the parent, in the folder's copy): probe --dump CATALOG.xcstrings LANGUAGE -AppleLanguages (LANGUAGE)

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

/// Runs `copy` in dump mode for `language` and returns its lookups; stops with a usage error when it fails.
func runDump(copy: URL, catalogURL: URL, language: String) -> [DumpedLookup] {
    let process = Process()
    process.executableURL = copy
    // `-AppleLanguages` is read by Foundation's argument domain, so the bundle chooses this one language.
    process.arguments = ["--dump", catalogURL.path, language, "-AppleLanguages", "(\(language))"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    do { try process.run() } catch { fail("cannot run \(copy.path): \(error)") }
    // A dump that outlives its limit is stopped, so a hung one cannot hold the build.
    DispatchQueue.global().asyncAfter(deadline: .now() + dumpTimeLimit) { if process.isRunning { process.terminate() } }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("the dump of \(language) in \(copy.deletingLastPathComponent().path) failed (\(process.terminationStatus))") }
    return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { DumpedLookup(line: String($0)) }
}

/// Compares the two folders for `languages` and prints the result; returns the exit status.
func compare(xcodeFolder: URL, compactFolder: URL, catalogURL: URL, requested: [String]) -> Int32 {
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
    for language in languages {
        let one = runDump(copy: xcodeCopy, catalogURL: catalogURL, language: language)
        let two = runDump(copy: compactCopy, catalogURL: catalogURL, language: language)
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
    // A comparison of nothing, or of lookups that were all absent, proves nothing.
    return differences.isEmpty && compared > 0 && found > 0 ? 0 : 1
}

// MARK: - Entry point

let arguments = CommandLine.arguments
if arguments.count >= 4, arguments[1] == "--dump" {
    // The parent's run of the copy: print every lookup of one language.
    let catalog = ProbeCatalog(url: URL(fileURLWithPath: arguments[2]))
    for lookup in dumpLookups(catalog: catalog, language: arguments[3]) { print(lookup.line) }
    exit(0)
}
guard arguments.count >= 4 else { fail("usage: probe XCODE_FOLDER COMPACT_FOLDER CATALOG.xcstrings [LANGUAGE...]") }
exit(compare(
    xcodeFolder: URL(fileURLWithPath: arguments[1]),
    compactFolder: URL(fileURLWithPath: arguments[2]),
    catalogURL: URL(fileURLWithPath: arguments[3]),
    requested: Array(arguments.dropFirst(4))))
