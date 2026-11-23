import Foundation

/// The one writer of the person's file of own lines (FR39), for both commands that write it: Edit Interface Text… fills
/// `interface_text.json` with the lines of the interface language as they read now, and Export Interface Text… writes the
/// lines of the interface language as they read now, the person's own lines included, to a file the person chooses. Both
/// write the shape `InterfaceTextOverridesFile` reads, one language's `lines`; they differ in two fields of each line:
///
/// - the fill writes `base`, the pack's text when the file was written (or `basePlural`), so that a line the person
///   leaves alone keeps taking each update's better wording;
/// - the export writes no `base`, and `"changed": true` on the lines that are the person's own, so that what someone else
///   imports applies in full.
///
/// Nothing else writes the file: no launch, sync, or move of the data folder does. Foundation only.
enum InterfaceTextOverridesWriter {
    // MARK: - Edit Interface Text…

    /// The bytes of `interface_text.json` with the interface language added, or nil when the file is to be left as it is.
    ///
    /// - A missing (or empty) file is made, holding the interface language alone.
    /// - A file that lacks the interface language gets it; every other language is kept as it was.
    /// - A file that already has the language is left alone, whatever its lines: the person's edits are theirs. So is a
    ///   file that is not JSON or not the file's shape, which the person is mending.
    ///
    /// - Parameters:
    ///   - existing: The file's bytes now, nil when there is no file.
    ///   - reference: The pack's lines for the interface language (`reference.language`).
    static func filled(existing: Data?, reference: InterfaceTextReference) -> Data? {
        var root: [String: Any]
        if let existing, !isBlank(existing) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else { return nil }
            root = parsed
            guard var languages = root["languages"] as? [String: Any] else { return nil }
            guard languages[reference.language] == nil else { return nil }
            languages[reference.language] = ["lines": lines(of: reference, own: [:], forExport: false)]
            root["languages"] = languages
        } else {
            root = [
                "version": InterfaceTextOverridesFile.version,
                "languages": [reference.language: ["lines": lines(of: reference, own: [:], forExport: false)]],
            ]
        }
        return serialized(root)
    }

    // MARK: - Export Interface Text…

    /// The bytes an Export writes: every line of the interface language as it reads now, each with its English and its
    /// note, the person's own lines (`own`, by ID) in place of the pack's and marked `"changed": true`, and no `base`.
    static func export(reference: InterfaceTextReference, own: [String: InterfaceTextEntry]) -> Data {
        let root: [String: Any] = [
            "version": InterfaceTextOverridesFile.version,
            "languages": [reference.language: ["lines": lines(of: reference, own: own, forExport: true)]],
        ]
        return serialized(root) ?? Data()
    }

    // MARK: - The lines

    /// One object for each line of the pack, by ID.
    private static func lines(of reference: InterfaceTextReference, own: [String: InterfaceTextEntry], forExport: Bool) -> [String: Any] {
        var lines: [String: Any] = [:]
        for index in 0..<reference.ids.count {
            let id = reference.ids.id(at: index)
            guard let english = reference.englishWording(at: index) else { continue }
            let ownWording = own[id].flatMap { InterfaceTextWording(entry: $0, language: reference.language) }
            // The person's own line where one applies (the export only: the fill is made where there is none).
            guard let wording = ownWording ?? reference.wording(at: index) else { continue }

            var line: [String: Any] = [:]
            switch wording {
            case .text(let text):
                line["text"] = text
                if !forExport { line["base"] = text }
            case .plural(let forms):
                line["plural"] = forms
                if !forExport { line["basePlural"] = forms }
            }
            line["english"] = english.json
            let note = reference.note(at: index)
            if !note.isEmpty { line["note"] = note }
            if forExport && ownWording != nil { line["changed"] = true }
            lines[id] = line
        }
        return lines
    }

    // MARK: - Bytes

    /// `root` as JSON a person can read in an editor: indented, keys sorted (so two writes of the same lines are the same
    /// bytes), and slashes and non-ASCII letters as they are.
    private static func serialized(_ root: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Whether `data` holds only whitespace (a file the person made empty).
    private static func isBlank(_ data: Data) -> Bool {
        data.allSatisfy { [0x20, 0x09, 0x0A, 0x0D].contains($0) }
    }
}
