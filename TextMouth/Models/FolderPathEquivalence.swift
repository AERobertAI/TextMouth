import Foundation

/// The one rule that decides whether two library folder paths name the same
/// directory on disk.
///
/// Library folders are stored as relative paths such as `Work/Reports`, but the
/// directories behind them live on a real volume. Two spellings the volume
/// treats as one name must never become two library rows, because both rows
/// would then share, and fight over, a single directory. The rule:
///
/// - Every comparison applies Unicode NFC normalization first, so a composed
///   `é` (U+00E9) and a decomposed `e` + U+0301 are the same name. Apple file
///   systems treat those spellings as one name on every volume format.
/// - When the library volume is case-insensitive (the macOS default), the
///   comparison also applies Unicode case folding, so `Reports` and `reports`
///   are the same name there. On a case-sensitive volume they stay distinct.
///
/// Stored names keep the user's chosen casing; only comparisons fold case.
struct FolderPathEquivalence: Equatable, Sendable {
    /// Whether the library volume distinguishes names that differ only by case.
    let isCaseSensitive: Bool

    /// The rule for a volume that keeps `Reports` and `reports` apart.
    static let caseSensitive = FolderPathEquivalence(isCaseSensitive: true)

    /// The rule for a volume that treats `Reports` and `reports` as one name.
    static let caseInsensitive = FolderPathEquivalence(isCaseSensitive: false)

    /// Creates the rule for a volume with known case behavior.
    init(isCaseSensitive: Bool) {
        self.isCaseSensitive = isCaseSensitive
    }

    /// Creates the rule from a volume's reported capability. An unknown answer
    /// counts as case-insensitive: that is the common macOS setup, and it is the
    /// safe assumption because it can only refuse a name, never let two rows
    /// share one directory.
    init(volumeSupportsCaseSensitiveNames: Bool?) {
        self.init(isCaseSensitive: volumeSupportsCaseSensitiveNames ?? false)
    }

    // MARK: - Comparison

    /// The form of `path` that every folder comparison uses: NFC-normalized,
    /// then case-folded when the volume ignores case.
    func comparisonKey(for path: String) -> String {
        let composed = path.precomposedStringWithCanonicalMapping
        guard !isCaseSensitive else { return composed }
        // Folding can emit decomposed sequences (İ folds to i + U+0307), so
        // compose again to keep every key in one canonical form.
        return composed
            .folding(options: .caseInsensitive, locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    /// Whether two folder paths name the same directory under this rule.
    func areEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        comparisonKey(for: lhs) == comparisonKey(for: rhs)
    }

    /// Whether `path` is `ancestor` itself or lies inside it under this rule.
    /// The empty ancestor, the library root, contains every path.
    func isPath(_ path: String, inSubtreeOf ancestor: String) -> Bool {
        FolderSubtree(rootPath: ancestor, equivalence: self).contains(path)
    }
}

// MARK: - Library Volume Detection

extension FolderPathEquivalence {
    /// The rule for the volume that holds the active library directory.
    static var library: FolderPathEquivalence {
        forVolume(containing: TextMouthPaths.libraryDir)
    }

    /// The rule for the volume holding `directory`. Detection runs once per
    /// directory and is cached; a test override, when installed, wins.
    static func forVolume(containing directory: URL) -> FolderPathEquivalence {
        let directoryPath = directory.standardizedFileURL.path
        let store = FolderPathEquivalenceStore.shared
        if let stored = store.storedRule(forDirectoryPath: directoryPath) {
            return stored
        }
        // Filesystem metadata calls can block, so detect outside the lock.
        guard let supportsCase = detectCaseSensitivity(ofVolumeContaining: directory) else {
            // Unknown: use the safe default without caching it, so a later
            // lookup can still learn the real answer.
            return FolderPathEquivalence(volumeSupportsCaseSensitiveNames: nil)
        }
        let rule = FolderPathEquivalence(volumeSupportsCaseSensitiveNames: supportsCase)
        store.cache(rule, forDirectoryPath: directoryPath)
        return rule
    }

    /// Reads `volumeSupportsCaseSensitiveNames` for the volume holding `url`.
    /// The library directory may not exist yet (first launch, or a new data
    /// location), so this walks up to the nearest ancestor that reports the
    /// capability. Returns nil when no ancestor does.
    static func detectCaseSensitivity(ofVolumeContaining url: URL) -> Bool? {
        var path = url.standardizedFileURL.path
        while true {
            let values = try? URL(fileURLWithPath: path)
                .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            if let supportsCase = values?.volumeSupportsCaseSensitiveNames {
                return supportsCase
            }
            let parent = (path as NSString).deletingLastPathComponent
            // "/" is its own parent, which ends the walk.
            guard !parent.isEmpty, parent != path else { return nil }
            path = parent
        }
    }

    /// Runs `body` while every rule lookup returns `rule`, then restores the
    /// previous state. Hosted tests use this to drive real library code under
    /// both volume policies on whatever volume the test root happens to use.
    static func withLibraryRule<Value>(
        _ rule: FolderPathEquivalence,
        _ body: () throws -> Value
    ) rethrows -> Value {
        let store = FolderPathEquivalenceStore.shared
        let previous = store.replaceOverride(with: rule)
        defer { _ = store.replaceOverride(with: previous) }
        return try body()
    }

    /// `withLibraryRule(_:_:)` for work that awaits, such as a folder edit
    /// whose packages move off the main actor (PERF14): every rule lookup
    /// made while `body` runs, on any thread, returns `rule`. `body` runs in
    /// the caller's isolation (`isolation`), so it can use what the caller
    /// holds, such as a main-actor library model, without sending it away.
    static func withLibraryRule<Value>(
        _ rule: FolderPathEquivalence,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> Value
    ) async rethrows -> Value {
        let store = FolderPathEquivalenceStore.shared
        let previous = store.replaceOverride(with: rule)
        defer { _ = store.replaceOverride(with: previous) }
        return try await body()
    }
}

/// Detected rules cached per directory, plus the optional test override.
/// Folder edits run on the main actor, but library maintenance helpers can
/// run elsewhere, so every access goes through one lock.
private final class FolderPathEquivalenceStore: @unchecked Sendable {
    static let shared = FolderPathEquivalenceStore()

    private let lock = NSLock()
    private var rulesByDirectory: [String: FolderPathEquivalence] = [:]
    private var override: FolderPathEquivalence?

    /// The override when one is installed, otherwise the cached rule, if any.
    func storedRule(forDirectoryPath directoryPath: String) -> FolderPathEquivalence? {
        lock.lock()
        defer { lock.unlock() }
        return override ?? rulesByDirectory[directoryPath]
    }

    /// Remembers the detected rule for a directory.
    func cache(_ rule: FolderPathEquivalence, forDirectoryPath directoryPath: String) {
        lock.lock()
        defer { lock.unlock() }
        rulesByDirectory[directoryPath] = rule
    }

    /// Installs `rule` as the override (nil removes it) and returns the
    /// override it replaced, so nested scopes restore correctly.
    func replaceOverride(with rule: FolderPathEquivalence?) -> FolderPathEquivalence? {
        lock.lock()
        defer { lock.unlock() }
        let previous = override
        override = rule
        return previous
    }
}

// MARK: - Subtrees

/// A folder and everything inside it, matched with one equivalence rule.
///
/// Renaming, moving, or removing a folder rewrites every stored path in its
/// subtree: descendant folders, books, and per-folder sort settings. Matching
/// goes component by component, so `Reports2` is never inside `Reports`, and a
/// folded spelling of a different length (`STRASSE` for `Straße`) still maps
/// onto the right tail. The root's keys are computed once, which keeps checks
/// against thousands of book paths cheap.
struct FolderSubtree: Sendable {
    /// The subtree's root folder path; the empty path is the library root.
    let rootPath: String
    /// The rule used to compare path components.
    let equivalence: FolderPathEquivalence
    /// Comparison keys of the root's components, in order.
    private let rootKeys: [String]

    /// Creates a matcher for the subtree rooted at `rootPath`.
    init(rootPath: String, equivalence: FolderPathEquivalence) {
        self.rootPath = rootPath
        self.equivalence = equivalence
        rootKeys = Self.components(of: rootPath).map(equivalence.comparisonKey(for:))
    }

    /// The components of `path` below the root, or nil when `path` lies
    /// outside the subtree. The root itself yields an empty array.
    func relativeComponents(of path: String) -> [String]? {
        let components = Self.components(of: path)
        guard components.count >= rootKeys.count else { return nil }
        for (component, rootKey) in zip(components, rootKeys)
        where equivalence.comparisonKey(for: component) != rootKey {
            return nil
        }
        return Array(components.dropFirst(rootKeys.count))
    }

    /// Whether `path` is the root or lies inside it.
    func contains(_ path: String) -> Bool {
        relativeComponents(of: path) != nil
    }

    /// `path` rewritten so the subtree root becomes `newRootPath`, or nil when
    /// `path` lies outside the subtree.
    func relocating(_ path: String, to newRootPath: String) -> String? {
        guard let tail = relativeComponents(of: path) else { return nil }
        return Self.path(from: Self.components(of: newRootPath) + tail)
    }

    /// Splits a library path into its folder names; the root has none.
    static func components(of path: String) -> [String] {
        path.isEmpty ? [] : path.components(separatedBy: "/")
    }

    /// Joins folder names back into a library path.
    static func path(from components: [String]) -> String {
        components.joined(separator: "/")
    }
}
