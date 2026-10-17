import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import TextMouth

// The tools of the storage-failure drill (`StorageDrillTests`): small
// disposable disk images a test can unplug or fill part-way through an
// operation, a runner for the `hdiutil` commands that make and remove them,
// a sweeper for images an earlier crashed run left attached, and a snapshot
// of a folder's checksums to show that nothing the user owns changed.
//
// Safety, in one place:
// - every image lives in the hosted test sandbox, named `TMDrill-...`;
// - the sweeper detaches only such images, and only under the sandbox base;
// - every `hdiutil` call has a timeout, so no test can hang on one;
// - nothing here reads or writes the user's library, preferences, or any
//   volume but its own images.

// MARK: - Running a Command

/// What a command printed and how it ended.
struct CommandResult: Equatable {
    /// The exit status; -1 when the command could not start or was killed
    /// for running too long.
    let status: Int32
    /// Everything it printed, standard output and error together.
    let output: String
    /// Whether it was stopped for outrunning its timeout.
    let timedOut: Bool

    /// Whether the command ended normally with status 0.
    var succeeded: Bool { status == 0 && !timedOut }
}

/// Collects a child process's output from a background reader, so a command
/// printing more than a pipe holds can never block.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    /// Stores what the reader read.
    func set(_ newData: Data) {
        lock.lock()
        data = newData
        lock.unlock()
    }

    /// The text collected so far.
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Runs one command with a timeout, never blocking longer than that.
enum CommandRunner {
    /// How long a drill's `hdiutil` call may take.
    static let defaultTimeout: TimeInterval = 60

    /// Runs `executable` with `arguments` and waits for it for at most
    /// `timeout` seconds. A command that outruns it is asked to stop, then
    /// killed, and reported as timed out.
    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = defaultTimeout
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // A reader that runs until the pipe closes, so output never fills it.
        let collector = OutputCollector()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async {
            collector.set(pipe.fileHandleForReading.readDataToEndOfFile())
            reading.leave()
        }

        do {
            try process.run()
        } catch {
            // Closing our write end lets the reader finish.
            try? pipe.fileHandleForWriting.close()
            _ = reading.wait(timeout: .now() + 5)
            return CommandResult(status: -1, output: "could not start \(executable): \(error)", timedOut: false)
        }
        // The child holds its own copy; closing ours makes the reader see
        // the end of the output when the child exits.
        try? pipe.fileHandleForWriting.close()

        var timedOut = false
        if !waitForExit(of: process, seconds: timeout) {
            timedOut = true
            process.terminate()
            if !waitForExit(of: process, seconds: 5) {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = waitForExit(of: process, seconds: 5)
            }
        }
        _ = reading.wait(timeout: .now() + 5)
        let status: Int32 = (timedOut || process.isRunning) ? -1 : process.terminationStatus
        return CommandResult(status: status, output: collector.text, timedOut: timedOut)
    }

    /// Polls until `process` has exited or `seconds` pass; whether it exited.
    private static func waitForExit(of process: Process, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return true
    }
}

// MARK: - hdiutil Commands

/// The `hdiutil` commands of the drill: the exact arguments are built here,
/// in one place, and pinned by `DiskImageDrillTests`.
enum HDIUtil {
    /// Where macOS keeps the tool.
    static let path = "/usr/bin/hdiutil"

    /// Arguments making a read/write HFS+ image of `megabytes` MB named
    /// `volumeName`, replacing any file at `image`.
    static func createArguments(megabytes: Int, volumeName: String, image: URL) -> [String] {
        ["create", "-size", "\(megabytes)m", "-fs", "HFS+", "-volname", volumeName, "-ov", image.path]
    }

    /// Arguments mounting `image` at `mountPoint`, hidden from Finder, with
    /// no checksum verification and no automatic filesystem check.
    static func attachArguments(image: URL, mountPoint: URL) -> [String] {
        ["attach", "-nobrowse", "-noverify", "-noautofsck", "-mountpoint", mountPoint.path, image.path]
    }

    /// Arguments detaching `target` (a mount point or a device) by force,
    /// as a pulled cable would.
    static func detachArguments(target: String) -> [String] {
        ["detach", "-force", target]
    }

    /// Runs `hdiutil` with `arguments`, within the timeout.
    static func run(_ arguments: [String]) -> CommandResult {
        CommandRunner.run(path, arguments)
    }
}

// MARK: - Leftover Images

/// An image of the drill that is still attached, as `hdiutil info -plist`
/// lists it.
struct AttachedImage: Equatable {
    /// The image file's path.
    let imagePath: String
    /// The devices to detach (the whole disk, for example `/dev/disk4`).
    let devices: [String]
}

/// Finds the drill's own images among those attached, so a crashed earlier
/// run's can be detached, and nothing else ever is.
enum LeftoverImages {
    /// What a drill image's file name starts with.
    static let namePrefix = "TMDrill-"

    /// The path prefixes the drill's images live under: the sandbox base
    /// (the folder holding every `TextMouthTests-<pid>` sandbox, so an
    /// earlier process's too) followed by that name prefix, spelled both as
    /// given and with links resolved (`/var` is `/private/var`).
    static func sandboxPrefixes(sandboxHome: URL) -> [String] {
        let base = sandboxHome.deletingLastPathComponent()
        let prefixes = [base, base.resolvingSymlinksInPath()].map {
            $0.standardizedFileURL.path + "/" + TextMouthRuntime.sandboxNamePrefix
        }
        // Order kept, duplicates dropped.
        var seen = Set<String>()
        return prefixes.filter { seen.insert($0).inserted }
    }

    /// The images in `infoPlist` (the output of `hdiutil info -plist`)
    /// whose file is named `TMDrill-...` and lies under one of `prefixes`.
    /// An image outside the sandbox, or not named so, is never returned,
    /// however much it looks like one.
    static func drillImages(inInfoPlist infoPlist: Data, sandboxPrefixes prefixes: [String]) -> [AttachedImage] {
        guard let plist = try? PropertyListSerialization.propertyList(from: infoPlist, format: nil),
              let root = plist as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return [] }
        return images.compactMap { image in
            guard let path = image["image-path"] as? String,
                  prefixes.contains(where: { path.hasPrefix($0) }),
                  URL(fileURLWithPath: path).lastPathComponent.hasPrefix(namePrefix) else { return nil }
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            let devices = entities.compactMap { $0["dev-entry"] as? String }
            // A whole disk (`/dev/disk4`) is detached with its slices.
            let wholeDisks = devices.filter { $0.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil }
            return AttachedImage(imagePath: path, devices: wholeDisks.isEmpty ? devices : wholeDisks)
        }
    }
}

// MARK: - A Disk Image

/// Why a disk image operation failed.
struct DiskImageError: LocalizedError {
    /// What was being done.
    let action: String
    /// What the command or call said.
    let detail: String

    var errorDescription: String? { "Disk image: \(action) failed: \(detail)" }
}

/// One disposable disk image: made, attached, unplugged by force, filled,
/// and deleted. Its file and its mount point live in the test's sandbox.
final class DiskImage: @unchecked Sendable {
    /// The image file, `TMDrill-<token>-<name>.dmg`.
    let imageURL: URL
    /// Where it mounts, `mnt-<name>-<token>` beside the image file.
    let mountPoint: URL
    /// The volume's name, `TMDrill-<token>`.
    let volumeName: String

    /// An image to be made in `folder`, named for `name`.
    init(in folder: URL, name: String, token: String = String(UUID().uuidString.prefix(8))) {
        volumeName = "\(LeftoverImages.namePrefix)\(token)"
        imageURL = folder.appendingPathComponent("\(volumeName)-\(name).dmg")
        mountPoint = folder.appendingPathComponent("mnt-\(name)-\(token)", isDirectory: true)
    }

    /// Makes an image of `sizeMegabytes` MB for `test` and attaches it. The
    /// teardown that detaches it by force and deletes it is registered
    /// BEFORE anything is made, so a failure part-way still cleans up; it
    /// runs after every teardown block registered later, so the test's own
    /// restoring of the data directory happens while the volume is there.
    static func make(for test: XCTestCase, name: String, sizeMegabytes: Int) throws -> DiskImage {
        let folder = try test.makeSandboxDirectory("StorageDrill-\(name)")
        let image = DiskImage(in: folder, name: name)
        // Refuse an image the sweeper could not find again.
        let prefixes = LeftoverImages.sandboxPrefixes(sandboxHome: HostedTestSandbox.home)
        guard prefixes.contains(where: { image.imageURL.path.hasPrefix($0) }) else {
            throw DiskImageError(action: "placing the image", detail: "\(image.imageURL.path) is outside the test sandbox")
        }
        test.addTeardownBlock {
            image.detach()
            image.delete()
        }
        try image.create(sizeMegabytes: sizeMegabytes)
        try image.attach()
        return image
    }

    /// Detaches every image of an earlier crashed run that is still
    /// attached: the drill's own (`TMDrill-...` under the sandbox base)
    /// and nothing else. Returns what it detached.
    @discardableResult
    static func sweepLeftovers() -> [AttachedImage] {
        let info = HDIUtil.run(["info", "-plist"])
        guard info.succeeded else { return [] }
        let leftovers = LeftoverImages.drillImages(
            inInfoPlist: Data(info.output.utf8),
            sandboxPrefixes: LeftoverImages.sandboxPrefixes(sandboxHome: HostedTestSandbox.home)
        )
        for leftover in leftovers {
            for device in leftover.devices {
                _ = HDIUtil.run(HDIUtil.detachArguments(target: device))
            }
        }
        return leftovers
    }

    /// Makes the image file.
    func create(sizeMegabytes: Int) throws {
        let result = HDIUtil.run(HDIUtil.createArguments(megabytes: sizeMegabytes, volumeName: volumeName, image: imageURL))
        guard result.succeeded else { throw DiskImageError(action: "creating \(imageURL.lastPathComponent)", detail: result.output) }
    }

    /// Mounts the image at its mount point, making that folder first.
    func attach() throws {
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let result = HDIUtil.run(HDIUtil.attachArguments(image: imageURL, mountPoint: mountPoint))
        guard result.succeeded else { throw DiskImageError(action: "attaching \(imageURL.lastPathComponent)", detail: result.output) }
    }

    /// Unplugs the volume by force, even while it is busy. Does nothing,
    /// and says so by returning false, when it is not attached.
    @discardableResult
    func detach() -> Bool {
        guard isAttached else { return false }
        return HDIUtil.run(HDIUtil.detachArguments(target: mountPoint.path)).succeeded
    }

    /// Whether the volume is mounted at the mount point: its device differs
    /// from the device of the folder holding it.
    var isAttached: Bool {
        guard let inside = deviceNumber(of: mountPoint),
              let outside = deviceNumber(of: mountPoint.deletingLastPathComponent()) else { return false }
        return inside != outside
    }

    /// Removes the image file and the empty mount point folder. Does nothing
    /// while the volume is still attached: a mounted volume's files are
    /// never deleted, and `rmdir` below refuses anything but an empty folder.
    func delete() {
        guard !isAttached else { return }
        try? FileManager.default.removeItem(at: imageURL)
        _ = rmdir(mountPoint.path)
    }

    /// Bytes available on the volume (`statfs`), or nil when it cannot be
    /// read.
    var freeBytes: UInt64? {
        var info = statfs()
        guard statfs(mountPoint.path, &info) == 0 else { return nil }
        return UInt64(info.f_bavail) * UInt64(info.f_bsize)
    }

    /// Writes zeros to a ballast file at the volume's top until the volume
    /// reports it is full (`ENOSPC`), then shortens the file so about
    /// `reserve` bytes are free again, and flushes. Returns the ballast's
    /// location.
    func fillToCapacity(leavingFree reserve: Int) throws -> URL {
        let ballast = mountPoint.appendingPathComponent("ballast.bin")
        let descriptor = open(ballast.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else { throw posixError("creating the ballast file") }
        defer { close(descriptor) }

        var written: off_t = 0
        // Big writes first, then ever smaller ones for the last gap.
        for chunkSize in [1 << 16, 4096, 512, 1] {
            let chunk = [UInt8](repeating: 0, count: chunkSize)
            while true {
                let count = chunk.withUnsafeBytes { write(descriptor, $0.baseAddress, chunkSize) }
                if count < 0 {
                    guard errno == ENOSPC else { throw posixError("filling the volume") }
                    break
                }
                written += off_t(count)
            }
        }
        let kept = max(0, written - off_t(reserve))
        guard ftruncate(descriptor, kept) == 0 else { throw posixError("shortening the ballast file") }
        _ = fsync(descriptor)
        return ballast
    }

    /// The device number of the item at `url`, or nil.
    private func deviceNumber(of url: URL) -> dev_t? {
        var info = stat()
        return stat(url.path, &info) == 0 ? info.st_dev : nil
    }

    /// An error naming `action` and the current `errno`.
    private func posixError(_ action: String) -> DiskImageError {
        DiskImageError(action: action, detail: String(cString: strerror(errno)))
    }
}

// MARK: - Folder Snapshots

/// A folder's contents as checksums: each file's SHA-256 by path relative
/// to the folder, and each folder and link as a marker. Two snapshots
/// compare to a list of the paths that differ, by name, so a failure says
/// exactly which of the user's files changed.
struct FolderSnapshot: Equatable {
    /// Names the volume or the system adds on its own; never part of a
    /// snapshot, so a volume's index folders do not count as changes.
    static let systemNames: Set<String> = [
        ".DS_Store", ".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems",
        ".DocumentRevisions-V100", ".metadata_never_index", ".metadata_never_index_unless_rootfs",
        ".VolumeIcon.icns", ".hotfiles.btree", ".journal", ".journal_info_block"
    ]
    /// The marker standing for a folder.
    static let folderMarker = "<folder>"
    /// The marker prefix standing for a link, followed by its target.
    static let linkMarker = "<link> "

    /// Each item's digest or marker, by path relative to the folder.
    let entries: [String: String]

    /// A snapshot of known entries, for tests.
    init(entries: [String: String]) {
        self.entries = entries
    }

    /// Reads the folder at `folder` and everything inside it.
    init(of folder: URL) throws {
        let fileManager = FileManager.default
        guard let paths = fileManager.enumerator(atPath: folder.path) else {
            throw DiskImageError(action: "listing \(folder.path)", detail: "it cannot be read")
        }
        var entries: [String: String] = [:]
        for case let relative as String in paths {
            // Skip the names the system adds, and what is inside them.
            if relative.split(separator: "/").contains(where: { Self.systemNames.contains(String($0)) }) {
                paths.skipDescendants()
                continue
            }
            let url = folder.appendingPathComponent(relative)
            let type = try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            switch type {
            case .typeDirectory:
                entries[relative] = Self.folderMarker
            case .typeSymbolicLink:
                let target = (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) ?? "?"
                entries[relative] = Self.linkMarker + target
            default:
                entries[relative] = try Self.sha256(of: url)
            }
        }
        self.entries = entries
    }

    /// The SHA-256 of the file at `url` as lowercase hex, read in pieces.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty {
            hasher.update(data: piece)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The paths that differ from `before`, which is how things were: each
    /// as "changed: path", "missing: path" (in `before`, gone now), or
    /// "extra: path" (new), sorted. Empty when nothing differs.
    func differences(from before: FolderSnapshot) -> [String] {
        var lines: [String] = []
        for (path, digest) in before.entries {
            if let now = entries[path] {
                if now != digest { lines.append("changed: \(path)") }
            } else {
                lines.append("missing: \(path)")
            }
        }
        for path in entries.keys where before.entries[path] == nil {
            lines.append("extra: \(path)")
        }
        return lines.sorted()
    }
}
