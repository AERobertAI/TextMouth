import Foundation
import XCTest
@testable import TextMouth

/// A stand-in for iCloud Drive's sync folder (FR43, section 11): a real
/// folder in the test's sandbox, with the cloud's behaviours put in the
/// test's hands. Offline, an upload held, failed, or unreported, a file
/// that has not downloaded, one deleted "in the cloud", and the folder
/// lost. No test touches the user's drive or library.
///
/// `@unchecked Sendable`: every mutable property is read and changed only
/// under `lock`; `root` and `fileManager` are constants.
final class SyncTestDrive: SyncFolderAccess, @unchecked Sendable {
    /// What an upload of a file reports.
    enum Upload {
        case uploaded, uploading, failed(SyncProblem), notReported
    }

    /// The sandbox folder standing for the sync folder.
    let root: URL
    /// Guards the mutable state below.
    private let lock = NSLock()
    private var offline = false
    private var folderLost = false
    private var uploadPolicy: Upload = .uploaded
    private var uploadByName: [String: Upload] = [:]
    private var notDownloaded: Set<String> = []
    private var copies: [String] = []
    private var copiedFromRoot: [String] = []
    private var failCopiesAfter: Int?
    private var limits: [Duration] = []

    /// A drive whose folder is `root`.
    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: The test's controls

    /// Whether the network is gone: reads of files not downloaded fail at once.
    func setOffline(_ value: Bool) { locked { offline = value } }
    /// Whether the folder is lost: `withFolder` fails.
    func setFolderLost(_ value: Bool) { locked { folderLost = value } }
    /// What every upload reports, unless a file has its own.
    func setUpload(_ value: Upload) { locked { uploadPolicy = value } }
    /// What the upload of the file named `name` reports.
    func setUpload(_ value: Upload, forName name: String) { locked { uploadByName[name] = value } }
    /// Marks the file named `name` as in the cloud only.
    func setNotDownloaded(_ name: String, _ value: Bool = true) {
        locked { if value { notDownloaded.insert(name) } else { notDownloaded.remove(name) } }
    }
    /// Lets `count` more copies work, then fails the next (a crash or a full drive).
    func failCopies(after count: Int?) { locked { failCopiesAfter = count } }
    /// The limit of every read made, so a test shows every wait was bounded.
    var readLimits: [Duration] { locked { limits } }
    /// The paths of the files copied in, from the drive's folder (`Devices/<id>/<name>`): two devices write files of
    /// the same name (each numbers its own seqs), so only a path tells a file sent twice from two devices' files.
    var copiedPaths: [String] { locked { copiedFromRoot } }
    /// The names of the files copied in, in order, for "nothing went twice".
    var copiedNames: [String] { locked { copies } }

    /// Runs `body` under the lock.
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: SyncFolderAccess

    func withFolder<T: Sendable>(_ body: @Sendable (URL) async throws -> T) async throws -> T {
        if locked({ folderLost }) { throw SyncProblem.folderMissing }
        return try await body(root)
    }

    func list(_ folder: URL) throws -> [SyncFolderItem] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return locked {
            names.sorted().map { name in
                let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? Int64) ?? nil
                return SyncFolderItem(name: name, size: size, isOnThisDevice: !notDownloaded.contains(name))
            }
        }
    }

    func read(_ file: URL, within limit: Duration) async throws -> Data {
        locked { limits.append(limit) }
        let state = locked { (offline: offline, away: notDownloaded.contains(file.lastPathComponent)) }
        if state.away {
            throw state.offline ? SyncProblem.offline : SyncProblem.notDownloaded(device: file.deletingLastPathComponent().lastPathComponent)
        }
        return try Data(contentsOf: file)
    }

    func write(_ data: Data, to file: URL, replacing: Bool) throws {
        if !replacing, FileManager.default.fileExists(atPath: file.path) { throw SyncProblem.exists }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    func copyIn(_ local: URL, to file: URL) throws {
        if FileManager.default.fileExists(atPath: file.path) { throw SyncProblem.exists }
        let refused = locked { () -> Bool in
            if let left = failCopiesAfter {
                if left == 0 { return true }
                failCopiesAfter = left - 1
            }
            return false
        }
        if refused { throw SyncProblem.outOfSpace }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: local, to: file)
        let relative = file.path.hasPrefix(root.path + "/") ? String(file.path.dropFirst(root.path.count + 1)) : file.path
        locked {
            copies.append(file.lastPathComponent)
            copiedFromRoot.append(relative)
        }
    }

    func uploadState(of file: URL) -> SyncUploadState {
        let upload = locked { uploadByName[file.lastPathComponent] ?? uploadPolicy }
        switch upload {
        case .uploaded: return .uploaded
        case .uploading: return .uploading
        case .failed(let problem): return .failed(problem)
        case .notReported: return .notReported
        }
    }

    func evictLocalCopy(of file: URL) throws {
        locked { _ = notDownloaded.insert(file.lastPathComponent) }
    }
}
