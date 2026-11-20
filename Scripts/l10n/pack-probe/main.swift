import Foundation

// The probe of `Scripts/l10n/verify_packs.py` (TL16): reads two folders of language files through `Bundle`, the
// way the app reads them, and reports every lookup that differs between them. The first folder holds the files as
// Xcode compiled them, the second the same files after `compact_packs.py`.
//
// Compiled together with TextMouthProductionTests/LanguagePackTests.swift as `-D PACK_PROBE`, which leaves that
// file's tests out and keeps its lookups, so the probe and the hosted test read a bundle in one way.
//
// Usage: probe XCODE_FOLDER COMPACT_FOLDER CATALOG.xcstrings [LANGUAGE...]
// Prints one line per differing lookup (at most 20), then a summary; the exit status is 1 on any difference or
// when nothing was compared.

/// Reports a usage error and stops.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("probe: \(message)\n".utf8))
    exit(2)
}

guard CommandLine.arguments.count >= 4 else { fail("usage: probe XCODE_FOLDER COMPACT_FOLDER CATALOG.xcstrings [LANGUAGE...]") }
let xcodeFolder = URL(fileURLWithPath: CommandLine.arguments[1])
let compactFolder = URL(fileURLWithPath: CommandLine.arguments[2])
let catalogURL = URL(fileURLWithPath: CommandLine.arguments[3])

// The catalog's keys, and for each the languages in which it is a plural string.
guard let data = try? Data(contentsOf: catalogURL),
      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let strings = root["strings"] as? [String: [String: Any]]
else { fail("cannot read the catalog at \(catalogURL.path)") }
var pluralLanguages: [String: Set<String>] = [:]
for (key, entry) in strings {
    for (language, localization) in entry["localizations"] as? [String: [String: Any]] ?? [:]
    where (localization["variations"] as? [String: Any])?["plural"] != nil {
        pluralLanguages[key, default: []].insert(language)
    }
}

// The languages to compare: the ones named after the catalog, or else every one the first folder holds. Both
// folders must hold each of them (a folder may hold more, such as one an earlier run left).
let languages = CommandLine.arguments.count > 4
    ? Array(CommandLine.arguments[4...]).sorted()
    : LanguagePackLookups.languages(in: xcodeFolder)
for folder in [xcodeFolder, compactFolder] {
    let held = Set(LanguagePackLookups.languages(in: folder))
    guard held.isSuperset(of: languages) else { fail("\(folder.path) lacks \(Set(languages).subtracting(held).sorted())") }
}

var compared = 0
var found = 0
var differences: [String] = []
/// Records a lookup that differs between the two folders.
func record(_ language: String, _ key: String, _ detail: String, _ one: String?, _ two: String?) {
    differences.append("\(language) \(key.debugDescription) \(detail): Xcode's \(String(describing: one)), compact \(String(describing: two))")
}

for language in languages {
    guard let xcode = LanguagePackLookups.bundle(language: language, in: xcodeFolder),
          let compact = LanguagePackLookups.bundle(language: language, in: compactFolder)
    else { fail("no bundle for \(language)") }
    for key in strings.keys.sorted() {
        // Every key's raw table text (a plural key's is the placeholder for its rules), or its absence.
        let one = LanguagePackLookups.simpleText(xcode, key: key)
        let two = LanguagePackLookups.simpleText(compact, key: key)
        compared += 1
        if one != nil { found += 1 }
        if one != two { record(language, key, "table text", one, two) }
        // Each plural key, formatted by the table's plural rules at every count.
        guard pluralLanguages[key]?.contains(language) == true else { continue }
        for count in LanguagePackLookups.counts {
            let first = LanguagePackLookups.pluralText(xcode, key: key, language: language, count: count)
            let second = LanguagePackLookups.pluralText(compact, key: key, language: language, count: count)
            compared += 1
            if first != nil { found += 1 }
            if first != second { record(language, key, "at \(count)", first, second) }
        }
    }
}

for line in differences.prefix(20) { print("DIFFERENT: \(line)") }
print("probe: compared \(compared) lookups in \(languages.count) languages (\(languages.joined(separator: ", "))): \(found) found, \(differences.count) different")
// A comparison of nothing, or of lookups that were all absent, proves nothing.
exit(differences.isEmpty && compared > 0 && found > 0 ? 0 : 1)
