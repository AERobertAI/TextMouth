import Foundation

/// All the fragments of a KFX book, indexed by type and name. A book is one
/// container or a set of them (the main file, a metadata file, resources);
/// their fragments are read together, which is why every local symbol in
/// them is already a name (`KFXContainer.Fragment`).
struct KFXFragments {

    /// The values, by fragment type and then fragment name.
    private var byType: [Int: [String: IonValue]] = [:]
    /// Whether any fragment has a struct field that is a local symbol named
    /// like a Scribe notebook's (`nmdl.` and a name).
    private(set) var holdsNotebookFields = false

    /// The prefix of the field names a Scribe notebook's sections carry.
    static let notebookFieldPrefix = "nmdl."

    /// Indexes `fragments`. When two fragments have the same type and name
    /// the first is kept, so a hostile duplicate cannot replace a real one.
    init(_ fragments: [KFXContainer.Fragment]) {
        for fragment in fragments {
            if byType[fragment.type, default: [:]][fragment.name] == nil {
                byType[fragment.type, default: [:]][fragment.name] = fragment.value
            }
            if fragment.localFieldNames.contains(where: { $0.hasPrefix(Self.notebookFieldPrefix) }) {
                holdsNotebookFields = true
            }
        }
    }

    /// The fragment of `type` called `name`, nil when the book has none.
    subscript(type: Int, name: String) -> IonValue? {
        byType[type]?[name]
    }

    /// The one fragment of `type` that has no name of its own (its entity
    /// id is `$348`), or the only fragment of that type.
    func singleton(_ type: Int) -> IonValue? {
        guard let named = byType[type] else { return nil }
        return named["$\(KFXContainer.unnamedEntityID)"] ?? (named.count == 1 ? named.values.first : nil)
    }

    /// Every fragment of `type`, by name.
    func all(_ type: Int) -> [String: IonValue] {
        byType[type] ?? [:]
    }

    /// Whether the book has any fragment of `type`.
    func holds(_ type: Int) -> Bool {
        !(byType[type]?.isEmpty ?? true)
    }
}
