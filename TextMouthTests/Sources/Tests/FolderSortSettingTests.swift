import Foundation

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
