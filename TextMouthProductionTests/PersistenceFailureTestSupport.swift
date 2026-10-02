import XCTest
@testable import TextMouth

// Fixtures shared by the tests of failed writes and cleanups (TODO S09).

/// A write failure with a fixed reason, so sentences compare word for word.
struct WriteRefused: LocalizedError {
    var errorDescription: String? { "The volume is read-only." }
}

/// Records each call a test hands to the code under test, such as a retry
/// or a file operation. Main-actor isolated, so `@Sendable` closures may
/// capture it.
@MainActor
final class CallLog<Value> {
    /// Every value recorded so far, in order.
    private(set) var calls: [Value] = []

    /// Records one call.
    func record(_ value: Value) {
        calls.append(value)
    }
}

/// A folder standing where a file is written, so every write of that file
/// fails ("Is a directory") until `clear()` puts back what was there. Only
/// that one file is affected, which matters in the hosted test root that
/// the running app shares.
struct WriteObstruction {
    /// The file that cannot be written while the obstruction stands.
    let url: URL
    /// The file's bytes before the obstruction, or nil when it had none.
    private let originalBytes: Data?

    /// Replaces the file at `url` with a folder that is not empty.
    static func place(at url: URL) throws -> WriteObstruction {
        let original = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("obstruction".utf8).write(to: url.appendingPathComponent("obstruction"))
        return WriteObstruction(url: url, originalBytes: original)
    }

    /// Removes the folder and puts back the file's bytes, or leaves no file
    /// when there was none. Clearing twice does no harm.
    func clear() {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            try? FileManager.default.removeItem(at: url)
            if let originalBytes {
                try? originalBytes.write(to: url, options: .atomic)
            }
        }
    }
}

extension XCTestCase {
    /// Takes write permission from `directory`, so files cannot be created,
    /// replaced, or removed inside it, and gives it back when the test ends.
    /// - Returns: A function that gives the permission back sooner.
    @discardableResult
    func makeReadOnly(_ directory: URL) -> @Sendable () -> Void {
        XCTAssertEqual(chmod(directory.path, 0o555), 0, "could not make \(directory.path) read-only")
        let restore: @Sendable () -> Void = { _ = chmod(directory.path, 0o755) }
        addTeardownBlock(restore)
        return restore
    }

    /// A folder of the test's own under the isolated data root, removed with
    /// everything in it when the test ends.
    func makeTestDirectory(_ name: String) throws -> URL {
        let directory = TextMouthPaths.root.appendingPathComponent(
            "\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            // Write permission first, or nothing inside could be removed.
            _ = chmod(directory.path, 0o755)
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    /// A managed book with a real package in the isolated library, holding
    /// its content file and its bookInfo.json, removed when the test ends.
    /// - Parameters:
    ///   - title: The book's title.
    ///   - folderPath: The library folder that holds the package.
    func makePackagedBook(_ title: String, folderPath: String = "") throws -> Book {
        try TextMouthPaths.ensureDirectoryStructure()
        try TextMouthPaths.ensureLibrarySubfolder(folderPath)
        let packageName = "FailureFixture-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let content = package.appendingPathComponent("book.txt")
        try Data("Failure fixture".utf8).write(to: content)
        let book = Book(
            title: title,
            format: .txt,
            filePath: content.path,
            md5Hash: "failure-\(UUID().uuidString)",
            folderPath: folderPath,
            tmbDirectoryName: packageName
        )
        try book.saveBookInfoThrowing()
        // A test that moves the package elsewhere removes it from there.
        addTeardownBlock {
            try? FileManager.default.removeItem(at: package)
        }
        return book
    }

    /// The shared failure center that the app's services report to, cleared
    /// now and again when the test ends, so no test sees another's failures.
    @MainActor
    func cleanSharedFailureCenter() -> PersistenceFailureCenter {
        let center = PersistenceFailureCenter.shared
        center.reset()
        addTeardownBlock {
            await MainActor.run { PersistenceFailureCenter.shared.reset() }
        }
        return center
    }
}
