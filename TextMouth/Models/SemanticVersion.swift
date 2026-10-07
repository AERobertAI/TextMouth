import Foundation

/// The comparison of the semantic versions (`major.minor.patch`) TextMouth
/// stamps on what it derives from a book's file: the text cache's format
/// (`MarkdownCacheService.currentCacheVersion`) and the metadata reader's
/// (`ImportedFileMetadata.readerVersion`). A row stamped with an older
/// version than the code's is brought up to date; one stamped with a newer
/// version, as another Mac running a newer TextMouth can leave in a shared
/// library (FR02), is left as it is, so two versions never redo each
/// other's work.
enum SemanticVersion {
    /// Whether `stored` is older than `current`: nil or empty counts as
    /// older than anything, and a missing or unreadable component as 0, so
    /// "1" is "1.0.0".
    static func isOutdated(stored: String?, current: String) -> Bool {
        guard let stored, !stored.isEmpty else { return true }
        let storedParts = components(of: stored)
        let currentParts = components(of: current)
        for index in 0..<3 {
            if storedParts[index] < currentParts[index] { return true }
            if storedParts[index] > currentParts[index] { return false }
        }
        return false
    }

    /// The first three numbers of `version`, each 0 when missing.
    private static func components(of version: String) -> [Int] {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        return Array((parts + [0, 0, 0]).prefix(3))
    }
}
