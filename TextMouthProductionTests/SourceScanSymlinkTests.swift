import XCTest

/// The source scan (`AppSourceFile`) reads the app's Swift files by the path
/// these tests were built from. A checkout under /tmp, a symbolic link to
/// /private/tmp, once lost its folder from every file's path, so the scans
/// that look a file up by its path (`KeyboardReachabilityTests` finds
/// "App/MenuCommands.swift") found nothing (October 17, 2026).
final class SourceScanSymlinkTests: XCTestCase {

    /// A folder of two Swift files, one in a subfolder, and a text file the
    /// scan leaves out, with a symbolic link to the folder beside it.
    private func makeFolderAndLink() throws -> (folder: URL, link: URL) {
        let parent = try makeSandboxDirectory("Source Scan Symlink")
        let folder = parent.appendingPathComponent("Real", isDirectory: true)
        let subfolder = folder.appendingPathComponent("Services", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        try Data("struct A {}\n".utf8).write(to: folder.appendingPathComponent("A.swift"))
        try Data("struct B {}\n".utf8).write(to: subfolder.appendingPathComponent("B.swift"))
        try Data("not code\n".utf8).write(to: folder.appendingPathComponent("Notes.txt"))
        let link = parent.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        return (folder, link)
    }

    /// Scanning a folder through a symbolic link gives each file's path
    /// below the folder, as scanning the folder itself does, and reads each
    /// file's text.
    func testScanningThroughASymbolicLinkKeepsEachFilesPath() throws {
        let (folder, link) = try makeFolderAndLink()

        let direct = try AppSourceFile.all(in: folder, atLeast: 2)
        let linked = try AppSourceFile.all(in: link, atLeast: 2)

        XCTAssertEqual(linked.map(\.path), ["A.swift", "Services/B.swift"])
        XCTAssertEqual(linked.map(\.name), ["A.swift", "B.swift"])
        XCTAssertEqual(linked.map(\.text), ["struct A {}\n", "struct B {}\n"])
        XCTAssertEqual(linked.map(\.path), direct.map(\.path))
    }

    /// The path below a folder is the same whether the folder or the file
    /// is named through a link, and a file outside the folder keeps its
    /// name alone.
    func testRelativePathResolvesLinksOnBothSides() throws {
        let (folder, link) = try makeFolderAndLink()
        let file = folder.appendingPathComponent("Services/B.swift")
        let linkedFile = link.appendingPathComponent("Services/B.swift")
        let outside = folder.deletingLastPathComponent().appendingPathComponent("Elsewhere.swift")

        XCTAssertEqual(AppSourceFile.relativePath(of: file, in: link), "Services/B.swift")
        XCTAssertEqual(AppSourceFile.relativePath(of: linkedFile, in: folder), "Services/B.swift")
        XCTAssertEqual(AppSourceFile.relativePath(of: linkedFile, in: link), "Services/B.swift")
        XCTAssertEqual(AppSourceFile.relativePath(of: outside, in: link), "Elsewhere.swift")
    }

    /// The app's own scan still finds the files it is held to, by their
    /// paths below the app's folder, and the file a keyboard test looks up.
    func testTheAppsOwnScanFindsMenuCommandsByItsPath() throws {
        let sources = try AppSourceFile.all()

        XCTAssertNotNil(sources.first { $0.path == "App/MenuCommands.swift" })
    }
}
