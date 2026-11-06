import Foundation

/// What a KFX book says about itself: its title, author, and language, and
/// the marks that tell a book with no flowing text (KFX-FORMAT-NOTES-2026-11-05.md,
/// parts 6.1 and 10). The marks are read to refuse, never to guess.
struct KFXMetadata {

    /// The named entries of the book's metadata, by category and key. A key
    /// can repeat (a book with two authors), so each holds a list.
    private var entries: [String: [String: [IonValue]]] = [:]
    /// The flat metadata fragment of older books.
    private var flat: IonStruct?
    /// Whether the document data marks comic panel mode.
    private var hasComicPanels = false

    // MARK: Category and key names

    private static let titleCategory = "kindle_title_metadata"
    private static let capabilityCategory = "kindle_capability_metadata"
    /// The keys of the capability category whose presence, with a value that
    /// is not 0 or false, means the book is not flowing text.
    private static let noFlowingTextCapabilities = [
        "yj_fixed_layout", "yj_textbook", "yj_publisher_panels", "yj_facing_page",
        "yj_double_page_spread", "continuous_popup_progression", "yj_has_text_popups",
        "is_dictionary", "dictionary_lookup",
    ]
    /// The content type of a magazine.
    private static let magazineContentType = "MAGZ"
    /// The key of a periodical's generation.
    private static let periodicalKey = "periodicals_generation_V2"

    // MARK: Reading

    /// The metadata of the book whose fragments are `fragments`.
    init(_ fragments: KFXFragments) {
        let categories = fragments.singleton(KFXSymbol.bookMetadata)?.structValue?[KFXSymbol.metadataCategories]?.listValue ?? []
        for category in categories {
            guard let members = category.structValue, let name = members[KFXSymbol.categoryName]?.stringValue else { continue }
            for entry in members[KFXSymbol.categoryEntries]?.listValue ?? [] {
                guard let pair = entry.structValue, let key = pair[KFXSymbol.entryKey]?.stringValue,
                      let value = pair[KFXSymbol.entryValue] else { continue }
                entries[name, default: [:]][key, default: []].append(value)
            }
        }
        flat = fragments.singleton(KFXSymbol.flatMetadata)?.structValue
        hasComicPanels = fragments.singleton(KFXSymbol.documentData)?.structValue?[KFXSymbol.comicPanels] != nil
    }

    /// The text of the first entry called `key` in the title category.
    private func text(_ key: String) -> String? {
        entries[Self.titleCategory]?[key]?.compactMap(\.stringValue).first
    }

    /// The title, authors, and language, as the Kindle reader reports them.
    /// The authors are as the book spells them, joined with commas.
    var metadata: MOBIBook.Metadata {
        let authors = entries[Self.titleCategory]?["author"]?.compactMap(\.stringValue) ?? []
        return MOBIBook.Metadata(
            title: Self.cleaned(text("title") ?? flat?[KFXSymbol.flatTitle]?.stringValue ?? ""),
            author: Self.cleaned(authors.isEmpty ? (flat?[KFXSymbol.flatAuthor]?.stringValue ?? "") : authors.joined(separator: ", ")),
            language: Self.cleaned(text("language") ?? flat?[KFXSymbol.flatLanguage]?.stringValue ?? "").nonEmpty
        )
    }

    /// `text` with its white space made single spaces and trimmed.
    private static func cleaned(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Books to refuse

    /// Whether the marks say the book has no flowing text to read: a fixed
    /// layout, a print replica, a comic, a magazine, a children's book with
    /// panels, a dictionary, or a notebook.
    /// - Parameter fragments: The book's fragments, for the notebook mark.
    func hasNoFlowingText(in fragments: KFXFragments) -> Bool {
        if fragments.holdsNotebookFields || hasComicPanels { return true }
        for key in Self.noFlowingTextCapabilities {
            if let values = entries[Self.capabilityCategory]?[key], values.contains(where: Self.isSet) { return true }
        }
        if text("cde_content_type") == Self.magazineContentType { return true }
        return entries.values.contains { $0[Self.periodicalKey] != nil }
    }

    /// Whether a capability's value is set: anything but 0, false, an empty
    /// string, or the strings "0" and "false".
    private static func isSet(_ value: IonValue) -> Bool {
        switch value.unannotated {
        case .int(let number): return number != 0
        case .bool(let flag): return flag
        case .string(let text): return !["", "0", "false"].contains(text.lowercased())
        case .null: return false
        default: return true
        }
    }
}

private extension String {
    /// The string, or nil when it is empty.
    var nonEmpty: String? { isEmpty ? nil : self }
}
