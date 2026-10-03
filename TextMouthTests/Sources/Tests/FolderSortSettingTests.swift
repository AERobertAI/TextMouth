import Foundation
@testable import TextMouth

func runFolderSortSettingTests() {
    print("\n--- Folder Sort Setting Tests ---")

    test("Default sort setting is title ascending") {
        let setting = FolderSortSetting.defaultSort
        try assertEqual(setting.sortField, .title)
        try assertTrue(setting.sortAscending)
    }

    test("Sort setting for unknown folder returns default") {
        let library = Library()
        let result = library.sortSetting(for: "Nonexistent")
        try assertEqual(result, .defaultSort)
    }

    test("Sort setting stored and retrieved per folder") {
        var library = Library()
        let authorDesc = FolderSortSetting(sortField: .author, sortAscending: false)
        let dateAsc = FolderSortSetting(sortField: .dateAdded, sortAscending: true)

        library.setSortSetting(authorDesc, for: "Fiction")
        library.setSortSetting(dateAsc, for: "Nonfiction")

        let fictionSort = library.sortSetting(for: "Fiction")
        try assertEqual(fictionSort.sortField, .author)
        try assertTrue(!fictionSort.sortAscending)

        let nonfictionSort = library.sortSetting(for: "Nonfiction")
        try assertEqual(nonfictionSort.sortField, .dateAdded)
        try assertTrue(nonfictionSort.sortAscending)

        // Root still gets default
        let rootSort = library.sortSetting(for: "")
        try assertEqual(rootSort.sortField, .title)
        try assertTrue(rootSort.sortAscending)
    }

    test("Root folder can have custom sort") {
        var library = Library()
        let manual = FolderSortSetting(sortField: .manual, sortAscending: true)
        library.setSortSetting(manual, for: "")

        let rootSort = library.sortSetting(for: "")
        try assertEqual(rootSort.sortField, .manual)
    }

    test("Apply sort to subfolders sets all descendants") {
        var library = Library(folders: [
            BookFolder(name: "Fiction"),
            BookFolder(name: "SciFi", parentPath: "Fiction"),
            BookFolder(name: "Classics", parentPath: "Fiction/SciFi"),
            BookFolder(name: "Nonfiction"),
        ])

        let setting = FolderSortSetting(sortField: .fileSize, sortAscending: false)
        library.applySortToSubfolders(setting, from: "Fiction")

        // Fiction and its descendants should have the setting
        try assertEqual(library.sortSetting(for: "Fiction").sortField, .fileSize)
        try assertEqual(library.sortSetting(for: "Fiction/SciFi").sortField, .fileSize)
        try assertEqual(library.sortSetting(for: "Fiction/SciFi/Classics").sortField, .fileSize)

        // Nonfiction should still be default
        try assertEqual(library.sortSetting(for: "Nonfiction").sortField, .title)
    }

    test("Apply sort from root applies to all folders") {
        var library = Library(folders: [
            BookFolder(name: "A"),
            BookFolder(name: "B"),
            BookFolder(name: "C", parentPath: "A"),
        ])

        let setting = FolderSortSetting(sortField: .lastOpened, sortAscending: false)
        library.applySortToSubfolders(setting, from: "")

        try assertEqual(library.sortSetting(for: "").sortField, .lastOpened)
        try assertEqual(library.sortSetting(for: "A").sortField, .lastOpened)
        try assertEqual(library.sortSetting(for: "B").sortField, .lastOpened)
        try assertEqual(library.sortSetting(for: "A/C").sortField, .lastOpened)
    }

    test("Backward-compatible decode: missing folderSortSettings") {
        // Simulate a library.json from before per-folder sort was added
        let json = """
        {
            "books": [],
            "folders": []
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let library = try decoder.decode(Library.self, from: json)
        try assertTrue(library.folderSortSettings.isEmpty, "Should default to empty dict")
        try assertEqual(library.sortSetting(for: "").sortField, .title, "Default sort should be title")
    }

    test("Sort settings round-trip through JSON encode/decode") {
        var library = Library(folders: [BookFolder(name: "Test")])
        library.setSortSetting(
            FolderSortSetting(sortField: .author, sortAscending: false),
            for: "Test"
        )
        library.setSortSetting(
            FolderSortSetting(sortField: .manual, sortAscending: true),
            for: ""
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(library)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Library.self, from: data)

        try assertEqual(decoded.sortSetting(for: "Test").sortField, .author)
        try assertTrue(!decoded.sortSetting(for: "Test").sortAscending)
        try assertEqual(decoded.sortSetting(for: "").sortField, .manual)
        try assertTrue(decoded.sortSetting(for: "").sortAscending)
    }

    test("Changing sort for one folder does not affect others") {
        var library = Library(folders: [
            BookFolder(name: "A"),
            BookFolder(name: "B"),
        ])
        library.setSortSetting(FolderSortSetting(sortField: .author, sortAscending: true), for: "A")
        library.setSortSetting(FolderSortSetting(sortField: .fileSize, sortAscending: false), for: "B")

        // Change A's sort
        library.setSortSetting(FolderSortSetting(sortField: .dateAdded, sortAscending: true), for: "A")

        // B should be unchanged
        try assertEqual(library.sortSetting(for: "B").sortField, .fileSize)
        try assertTrue(!library.sortSetting(for: "B").sortAscending)
    }

    // MARK: - Sort setting cleanup on folder operations

    test("Delete folder removes its sort setting") {
        let folderID = UUID()
        var library = Library(folders: [
            BookFolder(id: folderID, name: "Fiction"),
        ])
        library.setSortSetting(FolderSortSetting(sortField: .author, sortAscending: false), for: "Fiction")
        try assertEqual(library.sortSetting(for: "Fiction").sortField, .author)

        // The folder holds no books, so no package is left to delete.
        _ = library.removeFolderAndContents(id: folderID)
        // Should fall back to default now
        try assertEqual(library.sortSetting(for: "Fiction").sortField, .title)
        try assertTrue(library.folderSortSettings["Fiction"] == nil, "Entry should be removed")
    }

    test("Delete folder and contents removes descendant sort settings") {
        let parentID = UUID()
        var library = Library(folders: [
            BookFolder(id: parentID, name: "Fiction"),
            BookFolder(name: "SciFi", parentPath: "Fiction"),
        ])
        library.setSortSetting(FolderSortSetting(sortField: .author, sortAscending: false), for: "Fiction")
        library.setSortSetting(FolderSortSetting(sortField: .fileSize, sortAscending: true), for: "Fiction/SciFi")

        // The folder holds no books, so no package is left to delete.
        _ = library.removeFolderAndContents(id: parentID)
        try assertTrue(library.folderSortSettings["Fiction"] == nil)
        try assertTrue(library.folderSortSettings["Fiction/SciFi"] == nil)
    }

    test("Rename folder remaps sort setting to new path") {
        let folderID = UUID()
        var library = Library(folders: [
            BookFolder(id: folderID, name: "Fiction"),
            BookFolder(name: "SciFi", parentPath: "Fiction"),
        ])
        library.setSortSetting(FolderSortSetting(sortField: .dateAdded, sortAscending: false), for: "Fiction")
        library.setSortSetting(FolderSortSetting(sortField: .manual, sortAscending: true), for: "Fiction/SciFi")

        library.renameFolder(id: folderID, to: "Novels")

        // Old paths should be gone
        try assertTrue(library.folderSortSettings["Fiction"] == nil)
        try assertTrue(library.folderSortSettings["Fiction/SciFi"] == nil)
        // New paths should have the settings
        try assertEqual(library.sortSetting(for: "Novels").sortField, .dateAdded)
        try assertEqual(library.sortSetting(for: "Novels/SciFi").sortField, .manual)
    }

    test("Move folder remaps sort setting to new path") {
        let folderID = UUID()
        var library = Library(folders: [
            BookFolder(id: folderID, name: "SciFi", parentPath: "Fiction"),
            BookFolder(name: "Fiction"),
            BookFolder(name: "Nonfiction"),
        ])
        library.setSortSetting(FolderSortSetting(sortField: .fileSize, sortAscending: false), for: "Fiction/SciFi")

        library.moveFolder(id: folderID, toParentPath: "Nonfiction")

        try assertTrue(library.folderSortSettings["Fiction/SciFi"] == nil, "Old path should be gone")
        try assertEqual(library.sortSetting(for: "Nonfiction/SciFi").sortField, .fileSize)
    }

    test("Remove folder reparenting preserves child sort settings with updated paths") {
        let parentID = UUID()
        var library = Library(folders: [
            BookFolder(id: parentID, name: "Fiction"),
            BookFolder(name: "SciFi", parentPath: "Fiction"),
        ])
        library.setSortSetting(FolderSortSetting(sortField: .author, sortAscending: true), for: "Fiction")
        library.setSortSetting(FolderSortSetting(sortField: .manual, sortAscending: false), for: "Fiction/SciFi")

        // Remove Fiction, reparenting contents to root
        library.removeFolder(id: parentID, movingContentsTo: "")

        // Fiction's own setting should be gone
        try assertTrue(library.folderSortSettings["Fiction"] == nil)
        // SciFi should now be at root level with its setting preserved
        try assertEqual(library.sortSetting(for: "SciFi").sortField, .manual)
        try assertTrue(!library.sortSetting(for: "SciFi").sortAscending)
    }

    // MARK: - Category sort settings

    test("Recent category default sort is lastOpened descending") {
        let setting = FolderSortSetting.recentDefault
        try assertEqual(setting.sortField, .lastOpened)
        try assertTrue(!setting.sortAscending, "Recent default should be descending (newest first)")
    }

    test("Recent category sort key is __recent__") {
        try assertEqual(LibraryCategory.recent.sortSettingsKey, "__recent__")
    }

    test("Folders category has no sort key (uses folder path)") {
        try assertTrue(LibraryCategory.folders.sortSettingsKey == nil)
    }

    test("All categories except folders have reserved sort keys") {
        try assertEqual(LibraryCategory.allItems.sortSettingsKey, "__allItems__")
        try assertEqual(LibraryCategory.noFolder.sortSettingsKey, "__noFolder__")
        try assertEqual(LibraryCategory.recent.sortSettingsKey, "__recent__")
    }

    test("Category sort keys cannot collide with folder paths") {
        // Reserved keys start and end with __ which is not valid in folder names
        for cat in LibraryCategory.allCases {
            if let key = cat.sortSettingsKey {
                try assertTrue(key.hasPrefix("__"), "Category key should start with __")
                try assertTrue(key.hasSuffix("__"), "Category key should end with __")
            }
        }
    }

    test("Library returns recent default when no preference stored") {
        let library = Library()
        let setting = library.sortSetting(for: "__recent__", default: .recentDefault)
        try assertEqual(setting.sortField, .lastOpened)
        try assertTrue(!setting.sortAscending)
    }

    test("Library returns user preference for recent when stored") {
        var library = Library()
        let userPref = FolderSortSetting(sortField: .title, sortAscending: true)
        library.setSortSetting(userPref, for: "__recent__")

        let setting = library.sortSetting(for: "__recent__", default: .recentDefault)
        try assertEqual(setting.sortField, .title, "User preference should override default")
        try assertTrue(setting.sortAscending, "User preference should override default")
    }

    test("Category sort settings don't interfere with folder settings") {
        var library = Library(folders: [BookFolder(name: "Recent")])
        // Set a sort for the folder literally named "Recent"
        library.setSortSetting(FolderSortSetting(sortField: .author, sortAscending: true), for: "Recent")
        // Set a sort for the Recent category
        library.setSortSetting(FolderSortSetting(sortField: .dateAdded, sortAscending: false), for: "__recent__")

        // They should be independent
        try assertEqual(library.sortSetting(for: "Recent").sortField, .author)
        try assertEqual(library.sortSetting(for: "__recent__").sortField, .dateAdded)
    }

    test("Category sort settings survive JSON round-trip") {
        var library = Library()
        library.setSortSetting(FolderSortSetting(sortField: .author, sortAscending: false), for: "__recent__")
        library.setSortSetting(FolderSortSetting(sortField: .fileSize, sortAscending: true), for: "__allItems__")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(library)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Library.self, from: data)

        try assertEqual(decoded.sortSetting(for: "__recent__").sortField, .author)
        try assertTrue(!decoded.sortSetting(for: "__recent__").sortAscending)
        try assertEqual(decoded.sortSetting(for: "__allItems__").sortField, .fileSize)
        try assertTrue(decoded.sortSetting(for: "__allItems__").sortAscending)
    }

    test("Folder operations don't affect category sort keys") {
        let folderID = UUID()
        var library = Library(folders: [BookFolder(id: folderID, name: "Fiction")])
        library.setSortSetting(FolderSortSetting(sortField: .dateAdded, sortAscending: false), for: "__recent__")
        library.setSortSetting(FolderSortSetting(sortField: .author, sortAscending: true), for: "Fiction")

        // Delete the folder
        // The folder holds no books, so no package is left to delete.
        _ = library.removeFolderAndContents(id: folderID)

        // Category sort setting should be unaffected
        try assertEqual(library.sortSetting(for: "__recent__").sortField, .dateAdded)
        try assertTrue(library.folderSortSettings["__recent__"] != nil)
    }

    test("Non-folder categories use their own default when no preference set") {
        try assertEqual(LibraryCategory.recent.defaultSortSetting, .recentDefault)
        try assertEqual(LibraryCategory.folders.defaultSortSetting, .defaultSort)
        try assertEqual(LibraryCategory.allItems.defaultSortSetting, .defaultSort)
        try assertEqual(LibraryCategory.noFolder.defaultSortSetting, .defaultSort)
    }

    // MARK: - Category switch round-trip (each location keeps its own key)

    test("Round-trip: folder → recent → folder does not pollute folder sort") {
        // A window moving from a folder to Recent and back reads each
        // location's setting under its own key. Showing a sort never saves it
        // (TODO A06), and a change made in Recent is saved under the
        // category's key, never the folder's.
        var library = Library()
        let folderPath = "Fiction"

        // Step 1: in folder with no custom sort → should use default
        let folderSetting = library.sortSetting(for: folderPath, default: LibraryCategory.folders.defaultSortSetting)
        try assertEqual(folderSetting.sortField, .title)
        try assertTrue(folderSetting.sortAscending)

        // Step 2: switch to recent → load recent default
        let recentKey = LibraryCategory.recent.sortSettingsKey!
        let recentSetting = library.sortSetting(for: recentKey, default: LibraryCategory.recent.defaultSortSetting)
        try assertEqual(recentSetting.sortField, .lastOpened)
        try assertTrue(!recentSetting.sortAscending)

        // Step 3: a change made in Recent is saved under the category key, NOT the folder's
        library.setSortSetting(recentSetting, for: recentKey)

        // Step 4: switch back to folder → folder should still have no stored setting
        try assertTrue(library.folderSortSettings[folderPath] == nil,
                       "Folder should have no stored sort setting — it was never explicitly set")
        let restoredFolderSetting = library.sortSetting(for: folderPath, default: LibraryCategory.folders.defaultSortSetting)
        try assertEqual(restoredFolderSetting.sortField, .title, "Folder should revert to title sort")
        try assertTrue(restoredFolderSetting.sortAscending, "Folder should revert to ascending")
    }

    test("Round-trip: folder with custom sort → recent → folder preserves custom sort") {
        var library = Library()
        let folderPath = "Nonfiction"

        // Set a custom sort for this folder
        let customSort = FolderSortSetting(sortField: .author, sortAscending: false)
        library.setSortSetting(customSort, for: folderPath)

        // Switch to recent
        let recentKey = LibraryCategory.recent.sortSettingsKey!
        let recentSetting = library.sortSetting(for: recentKey, default: LibraryCategory.recent.defaultSortSetting)
        library.setSortSetting(recentSetting, for: recentKey)

        // Switch back to folder — custom sort should be preserved
        let restored = library.sortSetting(for: folderPath, default: LibraryCategory.folders.defaultSortSetting)
        try assertEqual(restored.sortField, .author, "Custom folder sort should be preserved")
        try assertTrue(!restored.sortAscending, "Custom folder ascending should be preserved")
    }

    test("Apply sort preserves non-descendant folder settings") {
        var library = Library(folders: [
            BookFolder(name: "Fiction"),
            BookFolder(name: "SciFi", parentPath: "Fiction"),
            BookFolder(name: "Nonfiction"),
        ])

        // Set Nonfiction to a custom sort
        library.setSortSetting(FolderSortSetting(sortField: .dateAdded, sortAscending: false), for: "Nonfiction")

        // Apply different sort to Fiction tree
        library.applySortToSubfolders(FolderSortSetting(sortField: .author, sortAscending: true), from: "Fiction")

        // Nonfiction should be untouched
        try assertEqual(library.sortSetting(for: "Nonfiction").sortField, .dateAdded)
        try assertTrue(!library.sortSetting(for: "Nonfiction").sortAscending)
    }
}
