import Foundation
@testable import TextMouth

private extension FolderNavigationHistory {
    /// Simulate the full SwiftUI cycle: goBack → set currentFolderPath → onChange → recordVisit
    @discardableResult
    func simulateGoBack() -> String? {
        guard let path = goBack() else { return nil }
        recordVisit(to: path) // simulates onChange handler
        return path
    }

    /// Simulate the full SwiftUI cycle: goForward → set currentFolderPath → onChange → recordVisit
    @discardableResult
    func simulateGoForward() -> String? {
        guard let path = goForward() else { return nil }
        recordVisit(to: path) // simulates onChange handler
        return path
    }

    /// Simulate navigating up one level (Cmd+Up Arrow).
    /// Unlike back/forward, this creates a new history entry.
    func simulateUpOneLevel() {
        guard let parent = FolderNavigationHistory.parentPath(of: currentPath) else { return }
        recordVisit(to: parent)
    }
}

private typealias TestFolderNavigationHistory = FolderNavigationHistory

private func navigationBook(title: String, folderPath: String) -> Book {
    Book(
        title: title,
        format: .txt,
        filePath: "/tmp/\(title).txt",
        md5Hash: "navigation-\(title)",
        folderPath: folderPath
    )
}

func runFolderNavigationHistoryTests() {
    print("\n--- Folder Navigation History Tests ---")

    test("Initial state starts at root") {
        let nav = TestFolderNavigationHistory()
        try assertEqual(nav.currentPath, "", "Should start at root")
        try assertEqual(nav.history.count, 1)
        try assertTrue(!nav.canGoBack)
        try assertTrue(!nav.canGoForward)
    }

    test("Recording visits builds forward history") {
        let nav = TestFolderNavigationHistory()
        nav.recordVisit(to: "Fiction")
        nav.recordVisit(to: "Fiction/SciFi")
        nav.recordVisit(to: "Fiction/SciFi/Classics")

        try assertEqual(nav.history.count, 4)
        try assertEqual(nav.index, 3)
        try assertEqual(nav.currentPath, "Fiction/SciFi/Classics")
        try assertTrue(nav.canGoBack)
        try assertTrue(!nav.canGoForward)
    }

    test("Go back returns previous folder") {
        let nav = TestFolderNavigationHistory()
        nav.recordVisit(to: "Fiction")
        nav.recordVisit(to: "Fiction/SciFi")

        let path = nav.simulateGoBack()
        try assertEqual(path, "Fiction")
        try assertEqual(nav.currentPath, "Fiction")
        try assertTrue(nav.canGoBack, "Can still go back to root")
        try assertTrue(nav.canGoForward, "Can go forward to SciFi")
    }

    test("Go forward after back returns to where we were") {
        let nav = TestFolderNavigationHistory()
        nav.recordVisit(to: "Fiction")
        nav.recordVisit(to: "Fiction/SciFi")

        nav.simulateGoBack() // back to Fiction
        let path = nav.simulateGoForward()
        try assertEqual(path, "Fiction/SciFi")
        try assertEqual(nav.currentPath, "Fiction/SciFi")
        try assertTrue(!nav.canGoForward, "No more forward history")
    }

    test("Go back all the way to root") {
        let nav = TestFolderNavigationHistory()
        nav.recordVisit(to: "A")
        nav.recordVisit(to: "A/B")
        nav.recordVisit(to: "A/B/C")

        nav.simulateGoBack() // A/B
        nav.simulateGoBack() // A
        nav.simulateGoBack() // root
        try assertEqual(nav.currentPath, "")
        try assertTrue(!nav.canGoBack, "At root, can't go further back")

        // Going back again should return nil
        let result = nav.simulateGoBack()
        try assertTrue(result == nil)
    }

    test("New visit after going back trims forward history") {
        let nav = TestFolderNavigationHistory()
        nav.recordVisit(to: "Fiction")
        nav.recordVisit(to: "Fiction/SciFi")
        nav.recordVisit(to: "Fiction/SciFi/Classics")

        // Go back to Fiction
        nav.simulateGoBack() // SciFi
        nav.simulateGoBack() // Fiction

        // Visit a new folder — should erase SciFi and Classics from forward history
        nav.recordVisit(to: "Nonfiction")

        try assertEqual(nav.history, ["", "Fiction", "Nonfiction"])
        try assertEqual(nav.currentPath, "Nonfiction")
        try assertTrue(!nav.canGoForward, "Forward history was trimmed")
        try assertTrue(nav.canGoBack, "Can go back to Fiction")
    }

    test("Duplicate consecutive visit is not recorded") {
        let nav = TestFolderNavigationHistory()
        nav.recordVisit(to: "Fiction")
        nav.recordVisit(to: "Fiction") // same folder again

        try assertEqual(nav.history.count, 2, "Should only have root + Fiction")
        try assertEqual(nav.history, ["", "Fiction"])
    }

    test("GoBack sets isNavigating, recordVisit clears it") {
        let nav = TestFolderNavigationHistory()
        nav.recordVisit(to: "A")
        nav.recordVisit(to: "B")

        // goBack returns the path and leaves isNavigating = true
        let path = nav.goBack()
        try assertEqual(path, "A")
        try assertTrue(nav.isNavigating, "isNavigating should be true after goBack")

        // Simulate SwiftUI onChange calling recordVisit — should be suppressed
        nav.recordVisit(to: "A")
        try assertTrue(!nav.isNavigating, "isNavigating cleared by recordVisit")

        // History should be unchanged — the visit was suppressed
        try assertEqual(nav.history, ["", "A", "B"])
        try assertEqual(nav.index, 1)
    }

    test("parentPath of root returns nil") {
        let result = TestFolderNavigationHistory.parentPath(of: "")
        try assertTrue(result == nil, "Root has no parent")
    }

    test("parentPath of top-level folder returns root") {
        let result = TestFolderNavigationHistory.parentPath(of: "Fiction")
        try assertEqual(result, "")
    }

    test("parentPath of nested folder returns parent") {
        let result = TestFolderNavigationHistory.parentPath(of: "Fiction/SciFi/Classics")
        try assertEqual(result, "Fiction/SciFi")
    }

    test("Up one level records in history") {
        let nav = TestFolderNavigationHistory()
        nav.recordVisit(to: "Fiction")
        nav.recordVisit(to: "Fiction/SciFi")

        // Cmd+Up — goes to parent, which is a new visit (not back/forward)
        nav.simulateUpOneLevel()

        try assertEqual(nav.currentPath, "Fiction")
        try assertEqual(nav.history, ["", "Fiction", "Fiction/SciFi", "Fiction"])
        try assertTrue(nav.canGoBack, "Can go back to SciFi")
    }

    test("Back then up then forward works correctly") {
        let nav = TestFolderNavigationHistory()
        nav.recordVisit(to: "A")
        nav.recordVisit(to: "A/B")
        nav.recordVisit(to: "A/B/C")

        // Go back to A/B
        nav.simulateGoBack()
        try assertEqual(nav.currentPath, "A/B")

        // Up one level to A — this creates new history, trimming forward
        nav.simulateUpOneLevel()
        try assertEqual(nav.currentPath, "A")
        try assertEqual(nav.history, ["", "A", "A/B", "A"])
        try assertTrue(!nav.canGoForward, "Forward history was trimmed by Up")
    }

    test("Cross-branch navigation with back/forward") {
        // Simulate: root → Fiction → root → Nonfiction
        // Then back should go to root, back again to Fiction
        let nav = TestFolderNavigationHistory()
        nav.recordVisit(to: "Fiction")
        nav.recordVisit(to: "") // went back to root via breadcrumb
        nav.recordVisit(to: "Nonfiction")

        try assertEqual(nav.history, ["", "Fiction", "", "Nonfiction"])

        nav.simulateGoBack()
        try assertEqual(nav.currentPath, "", "Should be at root")

        nav.simulateGoBack()
        try assertEqual(nav.currentPath, "Fiction", "Should be at Fiction")

        nav.simulateGoForward()
        try assertEqual(nav.currentPath, "", "Back to root")

        nav.simulateGoForward()
        try assertEqual(nav.currentPath, "Nonfiction", "Forward to Nonfiction")
    }

    test("Many rapid navigations maintain correct state") {
        let nav = TestFolderNavigationHistory()
        // Drill down 4 levels
        nav.recordVisit(to: "A")
        nav.recordVisit(to: "A/B")
        nav.recordVisit(to: "A/B/C")
        nav.recordVisit(to: "A/B/C/D")

        // Go all the way back
        nav.simulateGoBack()
        nav.simulateGoBack()
        nav.simulateGoBack()
        nav.simulateGoBack()
        try assertEqual(nav.currentPath, "")
        try assertEqual(nav.index, 0)

        // Go all the way forward
        nav.simulateGoForward()
        nav.simulateGoForward()
        nav.simulateGoForward()
        nav.simulateGoForward()
        try assertEqual(nav.currentPath, "A/B/C/D")
        try assertEqual(nav.index, 4)
    }

    test("Up from root does nothing") {
        let nav = TestFolderNavigationHistory()
        nav.simulateUpOneLevel()
        try assertEqual(nav.currentPath, "")
        try assertEqual(nav.history.count, 1, "No history entry added")
    }

    // MARK: - VoiceOver Announcement Message Tests

    test("Folder announcement: root shows Library with total book count") {
        let library = Library(books: [
            navigationBook(title: "A", folderPath: ""),
            navigationBook(title: "B", folderPath: "Fiction"),
            navigationBook(title: "C", folderPath: "Fiction/SciFi"),
        ])
        let path = ""
        let message = FolderNavigationHistory.announcement(for: path, library: library)
        try assertEqual(message, "Library, 3 books")
    }

    test("Folder announcement: subfolder shows name and recursive count") {
        let library = Library(books: [
            navigationBook(title: "A", folderPath: "Fiction"),
            navigationBook(title: "B", folderPath: "Fiction/SciFi"),
            navigationBook(title: "C", folderPath: "Fiction/SciFi/Classics"),
            navigationBook(title: "D", folderPath: "Nonfiction"),
        ])
        let path = "Fiction"
        let message = FolderNavigationHistory.announcement(for: path, library: library)
        try assertEqual(message, "Fiction, 3 books")
    }

    test("Folder announcement: single book uses singular") {
        let library = Library(books: [
            navigationBook(title: "Alone", folderPath: "Solo"),
        ])
        let path = "Solo"
        let message = FolderNavigationHistory.announcement(for: path, library: library)
        try assertEqual(message, "Solo, 1 book")
    }

    test("Folder announcement: empty folder shows 0 books") {
        let library = Library(books: [], folders: [BookFolder(name: "Empty")])
        let path = "Empty"
        let message = FolderNavigationHistory.announcement(for: path, library: library)
        try assertEqual(message, "Empty, 0 books")
    }

    test("Folder announcement: nested path uses last component") {
        let path = "Fiction/SciFi/Classics"
        let library = Library()
        try assertEqual(
            FolderNavigationHistory.announcement(for: path, library: library),
            "Classics, 0 books"
        )
    }

    // MARK: - Navigation + History continued

    test("Back after navigating up returns to deeper folder") {
        let nav = TestFolderNavigationHistory()
        nav.recordVisit(to: "A")
        nav.recordVisit(to: "A/B")
        nav.recordVisit(to: "A/B/C")

        // Go up from A/B/C to A/B
        nav.simulateUpOneLevel()
        try assertEqual(nav.currentPath, "A/B")

        // Back should return to A/B/C (the folder we were in before pressing Up)
        nav.simulateGoBack()
        try assertEqual(nav.currentPath, "A/B/C")
    }
}
