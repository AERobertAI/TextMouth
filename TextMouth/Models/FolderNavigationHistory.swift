import Foundation

/// Tracks folder navigation history for a library window, providing
/// Finder-style back/forward navigation (Cmd+[ / Cmd+]).
/// The history records every folder the user visits. "Back" returns to
/// the previously visited folder (regardless of depth), while "Up" always
/// moves to the parent folder in the hierarchy.
class FolderNavigationHistory: ObservableObject {
    /// Ordered list of visited folder paths
    @Published private(set) var history: [String]
    /// Current position within the history stack
    @Published private(set) var index: Int

    /// True when a back/forward navigation is in progress,
    /// used to suppress recording the path change as a new history entry
    private(set) var isNavigating = false

    init(startingAt path: String = "") {
        self.history = [path]
        self.index = 0
    }

    /// Whether back navigation is available
    var canGoBack: Bool { index > 0 }

    /// Whether forward navigation is available
    var canGoForward: Bool { index < history.count - 1 }

    /// The current folder path at the head of history
    var currentPath: String { history[index] }

    /// Record a new folder visit. Trims any forward history beyond the
    /// current position, then appends the new path.
    /// Called from onChange(of: currentFolderPath). If the change was caused
    /// by goBack/goForward, the isNavigating flag suppresses recording and
    /// is then automatically cleared.
    func recordVisit(to path: String) {
        if isNavigating {
            isNavigating = false
            return
        }
        // Don't record duplicate consecutive entries
        guard history[index] != path else { return }
        // Trim forward history
        if index < history.count - 1 {
            history.removeSubrange((index + 1)...)
        }
        history.append(path)
        index = history.count - 1
    }

    /// Navigate back in history. Returns the folder path to navigate to,
    /// or nil if already at the beginning.
    /// Sets isNavigating so the subsequent onChange → recordVisit is suppressed.
    @discardableResult
    func goBack() -> String? {
        guard canGoBack else { return nil }
        isNavigating = true
        index -= 1
        return history[index]
    }

    /// Navigate forward in history. Returns the folder path to navigate to,
    /// or nil if already at the end.
    /// Sets isNavigating so the subsequent onChange → recordVisit is suppressed.
    @discardableResult
    func goForward() -> String? {
        guard canGoForward else { return nil }
        isNavigating = true
        index += 1
        return history[index]
    }

    /// Compute the parent path for a given folder path (used by "Up One Level").
    /// Returns empty string for root or top-level folders.
    static func parentPath(of path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let parts = path.components(separatedBy: "/")
        if parts.count > 1 {
            return parts.dropLast().joined(separator: "/")
        }
        return ""
    }

    /// VoiceOver announcement used after folder navigation. Keeping this
    /// formatter beside the navigation model prevents view-only string copies
    /// from drifting away from the behavior covered by hosted tests.
    static func announcement(for path: String, library: Library) -> String {
        let folderName = path.isEmpty
            ? "Library"
            : (path.components(separatedBy: "/").last ?? "Library")
        let bookCount = path.isEmpty
            ? library.books.count
            : library.totalBooksInFolderTree(path)
        return "\(folderName), \(bookCount) \(bookCount == 1 ? "book" : "books")"
    }
}
