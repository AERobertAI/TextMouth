import Darwin
import Foundation
import os
import XCTest
@testable import TextMouth

// MARK: - Opt-in Tests on Real Cloud Drives: Shared Pieces (FR02)
//
// `CloudDriveIntegrationTests` runs the cloud services against real sync
// services, in throwaway folders on the drives. The pieces here decide which
// folders it may use, make and delete its run folders, wait for a sync
// service within fixed limits, write synthetic books of random bytes, follow
// a book download, listen for published progress, and keep the answers it
// finds to the plan's open questions. `CloudDriveTestSupportTests` checks
// every piece that needs no cloud drive in each ordinary run, the safety
// checks first among them.

// MARK: - Which Folders

/// One folder on a cloud drive that the real-drive tests may use.
struct CloudDriveTestRoot: Equatable, Sendable {
    /// The folder, with any link in its path followed.
    let folder: URL
    /// The sync service whose folder holds it.
    let provider: CloudProvider

    /// The drive's name, as findings, failures, and the summary table give it.
    var driveName: String {
        provider.displayName
    }
}

/// The folders on real cloud drives that the opt-in tests may use (FR02),
/// read from the environment variable `TEXTMOUTH_CLOUD_TEST_ROOTS`.
///
/// The variable lists folders separated by colons. Each must be given by an
/// absolute path, already exist, be named exactly `TextMouth Cloud Tests`
/// (also after any link in its path is followed), and lie in a sync
/// service's folder. When any listed folder fails a check, no folder is used
/// at all. Unset, or listing nothing, the variable asks for nothing and the
/// tests skip, as they do in every ordinary run, `make test`, and CI.
///
/// xcodebuild hands a variable to the test host when the variable is set in
/// xcodebuild's own environment with the prefix `TEST_RUNNER_`, which it
/// strips (`man xcodebuild`):
///
///     TEST_RUNNER_TEXTMOUTH_CLOUD_TEST_ROOTS="$HOME/Library/CloudStorage/Dropbox/TextMouth Cloud Tests" \
///         xcodebuild test … -only-testing:TextMouthProductionTests/CloudDriveIntegrationTests
enum CloudDriveTestRoots {
    /// The variable that lists the folders.
    static let variableName = "TEXTMOUTH_CLOUD_TEST_ROOTS"

    /// The one name a listed folder may have.
    static let folderName = "TextMouth Cloud Tests"

    /// What the environment asks the tests to do.
    enum Selection: Equatable, Sendable {
        /// Nothing is listed, so the tests skip.
        case notRequested
        /// Every listed folder may be used, in the order listed.
        case roots([CloudDriveTestRoot])
        /// Some listed entries may not be used, for these reasons, one per
        /// refused entry; then the tests use no folder at all.
        case refused([String])
    }

    /// Why the listed folders were refused. Thrown from `setUp`, it fails
    /// each test with the reasons before the test touches anything.
    struct Refusal: LocalizedError, Equatable {
        /// One reason per refused entry.
        let reasons: [String]

        var errorDescription: String? {
            "\(CloudDriveTestRoots.variableName) was refused, so no folder was used. "
                + reasons.joined(separator: " ")
        }
    }

    /// The folders `environment` lists, each checked by its own metadata
    /// alone: nothing inside a listed folder is read or listed. `locate`
    /// says where a folder lives; by default, the app's status provider.
    static func selection(
        in environment: [String: String],
        locate: (URL) -> StorageLocation = { UbiquitousItemStatusProvider().location(of: $0) }
    ) -> Selection {
        // Empty entries, such as a trailing colon leaves, list nothing.
        let entries = (environment[variableName] ?? "").split(separator: ":").map(String.init)
        guard !entries.isEmpty else { return .notRequested }

        var roots: [CloudDriveTestRoot] = []
        var reasons: [String] = []
        for entry in entries {
            switch check(entry, locate: locate) {
            case .success(let root) where roots.contains(root):
                reasons.append("“\(entry)” names a folder listed already.")
            case .success(let root):
                roots.append(root)
            case .failure(let refusal):
                reasons.append(refusal.reason)
            }
        }
        return reasons.isEmpty ? .roots(roots) : .refused(reasons)
    }

    /// The folders the tests may use now. Skips the calling test when none
    /// is asked for, and throws `Refusal`, failing it, when any listed
    /// folder may not be used.
    static func requireRoots(
        in environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [CloudDriveTestRoot] {
        switch selection(in: environment) {
        case .notRequested:
            throw XCTSkip(
                "Opt-in: list folders named “\(folderName)” on cloud drives in \(variableName) "
                    + "(for xcodebuild, set TEST_RUNNER_\(variableName)) to run these tests."
            )
        case .refused(let reasons):
            throw Refusal(reasons: reasons)
        case .roots(let roots):
            return roots
        }
    }

    /// Why one entry was refused, in words.
    private struct EntryRefusal: Error {
        let reason: String
    }

    /// The folder `entry` names, when the tests may use it, or why not.
    private static func check(
        _ entry: String,
        locate: (URL) -> StorageLocation
    ) -> Result<CloudDriveTestRoot, EntryRefusal> {
        guard entry.hasPrefix("/") else {
            return .failure(EntryRefusal(reason: "“\(entry)” is not an absolute path."))
        }
        let listed = URL(fileURLWithPath: entry, isDirectory: true).standardizedFileURL
        guard listed.lastPathComponent == folderName else {
            return .failure(EntryRefusal(reason: "“\(entry)” is not named “\(folderName)”."))
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: listed.path, isDirectory: &isFolder), isFolder.boolValue else {
            return .failure(EntryRefusal(reason: "“\(entry)” is not an existing folder."))
        }
        // A link with the right name could lead to any folder at all.
        let folder = listed.resolvingSymlinksInPath()
        guard folder.lastPathComponent == folderName else {
            return .failure(EntryRefusal(
                reason: "“\(entry)” leads to “\(folder.path)”, which is not named “\(folderName)”."
            ))
        }
        guard case .cloud(let provider) = locate(folder) else {
            return .failure(EntryRefusal(reason: "“\(entry)” is not in a cloud drive's folder."))
        }
        return .success(CloudDriveTestRoot(folder: folder, provider: provider))
    }
}

// MARK: - Run Folders

/// The folders the tests work in, inside a test root: one per test and
/// drive, named `run-<date>-<process>-<label>`, always made new, and deleted
/// with everything in them when the test ends.
enum CloudDriveRunFolder {
    /// The name of the run folder that process `processIdentifier` makes at
    /// `date` for `label`, the time written in `timeZone`.
    static func name(label: String, date: Date, processIdentifier: Int32, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "run-\(formatter.string(from: date))-\(processIdentifier)-\(label)"
    }

    /// Makes a new run folder for `label` in `root`. Throws rather than
    /// reuse a folder that is there already.
    static func make(in root: CloudDriveTestRoot, label: String) throws -> URL {
        let runName = name(label: label, date: Date(), processIdentifier: ProcessInfo.processInfo.processIdentifier)
        let folder = root.folder.appendingPathComponent(runName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    /// Deletes `folder` and everything in it, with downloading switched
    /// off, so no file only in the cloud is fetched just to be deleted.
    static func remove(_ folder: URL) throws {
        try DatalessFiles.withoutDownloading {
            try FileManager.default.removeItem(at: folder)
        }
    }
}

// MARK: - Waiting for a Sync Service

/// How the tests wait for a sync service: they check once a second, never
/// sleep a fixed time, and give up at a limit.
enum CloudDriveWait {
    /// The time between two checks.
    static let interval: Duration = .seconds(1)
    /// The longest wait for files to upload.
    static let upload: Duration = .seconds(180)
    /// The longest wait for files to download.
    static let download: Duration = .seconds(120)
    /// The longest wait for local copies to go once their removal is asked for.
    static let removal: Duration = .seconds(60)

    /// Checks `condition` now, then once every `interval`, until it holds
    /// or `limit` has passed. Returns how long it took to hold, or nil when
    /// the limit ran out first.
    static func until(limit: Duration, _ condition: () -> Bool) async throws -> Duration? {
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            if condition() {
                return clock.now - start
            }
            guard clock.now - start < limit else { return nil }
            try await Task.sleep(for: interval)
        }
    }

    /// `duration` in whole seconds, as findings give it: "4 s".
    static func describe(_ duration: Duration) -> String {
        "\(duration.components.seconds) s"
    }
}

// MARK: - Synthetic Books

/// A synthetic book package the tests write: files of random bytes, so no
/// sync service can skip an upload by recognizing content it has seen.
struct SyntheticPackage: Sendable {
    /// One file to write: its name and its size in bytes.
    struct FileSpec: Equatable, Sendable {
        let name: String
        let byteCount: Int
    }

    /// The package the brief describes: a 5 MB, a 50 KB, and a 1 KB file.
    static let standardFiles = [
        FileSpec(name: "large-5MB.bin", byteCount: 5 * 1024 * 1024),
        FileSpec(name: "medium-50KB.bin", byteCount: 50 * 1024),
        FileSpec(name: "small-1KB.bin", byteCount: 1024),
    ]

    /// The package folder.
    let url: URL
    /// The book the package stands for, as the cloud services know it.
    let bookID: UUID
    /// What each file holds, by file name.
    let contents: [String: Data]

    /// The package's files, in name order.
    var files: [URL] {
        contents.keys.sorted().map { url.appendingPathComponent($0, isDirectory: false) }
    }

    /// The package as the cloud services see a book: an audiobook's package
    /// folder, whose files are read while it plays.
    var bookPackage: BookPackage {
        BookPackage(bookID: bookID, url: url, isPackage: true, isAudio: true)
    }

    /// Writes a new package called `name` in `folder`, holding `files`.
    /// Throws rather than write over anything already there.
    static func write(named name: String, in folder: URL, files: [FileSpec] = standardFiles) throws -> SyntheticPackage {
        let url = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        var contents: [String: Data] = [:]
        for file in files {
            let bytes = randomBytes(count: file.byteCount)
            try bytes.write(to: url.appendingPathComponent(file.name, isDirectory: false), options: .withoutOverwriting)
            contents[file.name] = bytes
        }
        return SyntheticPackage(url: url, bookID: UUID(), contents: contents)
    }

    /// The same package after it was moved to `newURL`.
    func moved(to newURL: URL) -> SyntheticPackage {
        SyntheticPackage(url: newURL, bookID: bookID, contents: contents)
    }

    /// The names of the files that do not hold what was written, each read
    /// at `location` of the file (the file itself by default, or its copy
    /// elsewhere) with downloading switched off, so a file only in the cloud
    /// is among them.
    func filesNotIntact(at location: (URL) -> URL = { $0 }) -> [String] {
        files.filter { file in
            let read = DatalessFiles.withoutDownloading { try? Data(contentsOf: location(file)) }
            return read != contents[file.lastPathComponent]
        }
        .map(\.lastPathComponent)
    }

    /// `count` random bytes.
    static func randomBytes(count: Int) -> Data {
        var bytes = Data(count: count)
        bytes.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress {
                arc4random_buf(base, buffer.count)
            }
        }
        return bytes
    }
}

// MARK: - What lstat Says

/// A file's size and modification time as lstat(2) reports them. lstat
/// reads no content, so it never downloads anything.
struct FileSnapshot: Equatable, Sendable {
    /// The size in bytes.
    let byteCount: Int64
    /// The modification time's whole seconds since 1970.
    let modifiedSeconds: Int
    /// The modification time's nanoseconds past those seconds.
    let modifiedNanoseconds: Int

    /// The modification time as its seconds and nine digits of nanoseconds.
    var modificationTime: String {
        "\(modifiedSeconds).\(String(format: "%09ld", modifiedNanoseconds))"
    }

    /// The snapshot of the item at `url`, or nil when nothing is there.
    /// Looked up with downloading switched off, so it never waits on the
    /// network.
    static func read(_ url: URL) -> FileSnapshot? {
        DatalessFiles.withoutDownloading {
            var status = stat()
            let found = url.withUnsafeFileSystemRepresentation { path -> Bool in
                guard let path else { return false }
                return lstat(path, &status) == 0
            }
            guard found else { return nil }
            return FileSnapshot(
                byteCount: Int64(status.st_size),
                modifiedSeconds: Int(status.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int(status.st_mtimespec.tv_nsec)
            )
        }
    }
}

// MARK: - Following a Book Download

/// A book download through the cloud service, followed to its end or to a
/// time limit: every progress it reported, in order, and how it ended.
struct CloudDriveDownloadRecord: Sendable {
    /// How a download ended.
    enum Outcome: Sendable {
        /// The stream finished: every file is on this Mac.
        case finished
        /// The stream threw this error.
        case failed(Error)
        /// The limit ran out first, and the download was stopped.
        case timedOut
    }

    /// Every progress the stream yielded, in order.
    var updates: [BookDownloadProgress]
    /// How the download ended.
    var outcome: Outcome
    /// How long it took to end.
    var elapsed: Duration

    /// Whether the download finished.
    var finished: Bool {
        if case .finished = outcome { return true }
        return false
    }

    /// Whether the progress only ever moved forward: files done and percent
    /// never fell, and the count of files never changed.
    var isInOrder: Bool {
        zip(updates, updates.dropFirst()).allSatisfy { earlier, later in
            later.completedFiles >= earlier.completedFiles
                && later.percent >= earlier.percent
                && later.totalFiles == earlier.totalFiles
        }
    }

    /// Follows `stream` until it ends or `limit` passes. At the limit the
    /// iteration stops, which ends the stream and so the download's checks.
    static func follow(
        _ stream: AsyncThrowingStream<BookDownloadProgress, Error>,
        limit: Duration
    ) async -> CloudDriveDownloadRecord {
        let clock = ContinuousClock()
        let start = clock.now
        let updates = OSAllocatedUnfairLock(initialState: [BookDownloadProgress]())
        let outcome = await withTaskGroup(of: Outcome?.self) { group -> Outcome in
            group.addTask {
                do {
                    for try await progress in stream {
                        updates.withLock { $0.append(progress) }
                    }
                    // An iteration stopped at the limit ends quietly too, and
                    // must not count as a finished download.
                    return Task.isCancelled ? nil : .finished
                } catch {
                    return Task.isCancelled ? nil : .failed(error)
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: limit)
                } catch {
                    return nil
                }
                return .timedOut
            }
            // The first to end decides; the other is stopped.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .timedOut
        }
        return CloudDriveDownloadRecord(
            updates: updates.withLock { $0 },
            outcome: outcome,
            elapsed: clock.now - start
        )
    }
}

// MARK: - Progress Other Processes Publish

/// Listens for the progress the system publishes for files, through the
/// app's own listener (`PublishedFileProgress`), for question 2: does an
/// app without an iCloud entitlement hear of a sync service's downloads?
/// What it hears is what a book's download folds into its progress.
///
/// `@unchecked Sendable`: the system reports on threads of its own, so
/// every stored property is read and written only under `lock`.
final class PublishedProgressRecorder: @unchecked Sendable {
    /// Guards every property below.
    private let lock = NSLock()
    /// The listening, one for each file, stopped by `stop()`.
    private var listeners: [PublishedFileProgress] = []
    /// Every fraction published for each file, by file name, in the order
    /// heard.
    private var fractions: [String: [Double]] = [:]

    /// Starts listening for progress published for each of `files`.
    func subscribe(to files: [URL]) {
        for file in files {
            let name = file.lastPathComponent
            let listening = PublishedFileProgress.listen(to: file) { [self] fraction in
                note(fraction, for: name)
            }
            lock.withLock { listeners.append(listening) }
        }
    }

    /// Stops listening.
    func stop() {
        let listeners = lock.withLock { () -> [PublishedFileProgress] in
            defer { self.listeners = [] }
            return self.listeners
        }
        listeners.forEach { $0.stop() }
    }

    /// What was heard for `files`, in words: for each file that heard
    /// anything, how many reports came and the first and last fraction.
    func summary(of files: [URL]) -> String {
        let heard = lock.withLock { fractions }
        let lines = files.compactMap { file -> String? in
            guard let seen = heard[file.lastPathComponent], let first = seen.first, let last = seen.last else {
                return nil
            }
            return "\(file.lastPathComponent) had \(seen.count) reports, from \(Self.percent(first)) to \(Self.percent(last))"
        }
        guard !lines.isEmpty else {
            return "No: the publishing handler never fired for any of the \(files.count) files."
        }
        return "Yes, for \(lines.count) of \(files.count) files: " + lines.joined(separator: "; ") + "."
    }

    /// Notes that `fraction` was published for the file called `name`.
    private func note(_ fraction: Double, for name: String) {
        lock.withLock { fractions[name, default: []].append(fraction) }
    }

    /// `fraction` as a whole percent.
    private static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded())) percent"
    }
}

// MARK: - Answers to the Open Questions

/// The open questions of the cloud plan that only a real sync service can
/// answer, numbered as in the task brief.
enum CloudDriveQuestion: Int, CaseIterable, Sendable {
    case downloadAndRemovalRequests = 1
    case publishedProgress
    case evictedFileSize
    case modificationTime
    case cloneAfterEviction
    case renamedPackage
    case dotFolder
    case removalWhileUploading

    /// The question in a few words.
    var title: String {
        switch self {
        case .downloadAndRemovalRequests:
            return "Do startDownloadingUbiquitousItem and evictUbiquitousItem work?"
        case .publishedProgress:
            return "Does Progress.addSubscriber(forFileURL:) hear download progress?"
        case .evictedFileSize:
            return "Does an evicted file report its real size, or 0?"
        case .modificationTime:
            return "Does the modification time keep its nanoseconds through eviction and download?"
        case .cloneAfterEviction:
            return "Does an APFS clone keep its data after the original is evicted?"
        case .renamedPackage:
            return "Is a package renamed in from outside published as one item?"
        case .dotFolder:
            return "Does a dot-folder sync?"
        case .removalWhileUploading:
            return "Does removeDownload refuse while a change is uploading?"
        }
    }
}

/// One answer found on one drive.
struct CloudDriveFinding: Equatable, Sendable {
    /// The drive's name.
    let drive: String
    /// The question answered.
    let question: CloudDriveQuestion
    /// The answer, in words.
    let answer: String
}

/// The answers the real-drive tests find during a run, kept for the table
/// printed when their class ends.
///
/// `@unchecked Sendable`: tests record from any thread, so `findings` is
/// read and written only under `lock`.
final class CloudDriveFindings: @unchecked Sendable {
    /// The answers of this run.
    static let shared = CloudDriveFindings()

    /// Guards `findings`.
    private let lock = NSLock()
    /// The answers in the order found.
    private var findings: [CloudDriveFinding] = []

    /// Keeps `finding`.
    func record(_ finding: CloudDriveFinding) {
        lock.withLock { findings.append(finding) }
    }

    /// Every answer kept, in the order found.
    var all: [CloudDriveFinding] {
        lock.withLock { findings }
    }

    /// `findings` as one Markdown table with a row per answer naming its
    /// drive: by drive, then by question, and answers to the same question
    /// in the order found.
    static func table(of findings: [CloudDriveFinding]) -> String {
        let ordered = findings.enumerated().sorted { first, second in
            (first.element.drive, first.element.question.rawValue, first.offset)
                < (second.element.drive, second.element.question.rawValue, second.offset)
        }
        let rows = ordered.map { _, finding in
            "| \(cell(finding.drive)) | \(finding.question.rawValue). \(cell(finding.question.title)) | \(cell(finding.answer)) |"
        }
        return (["| Drive | Question | Answer |", "| --- | --- | --- |"] + rows).joined(separator: "\n")
    }

    /// `error` in words for a finding or a failure: its description, then
    /// its domain and code.
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }

    /// `text` as a table cell holds it: pipes escaped, lines joined.
    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}

/// A step on a real drive that could not go on. The drive's later steps
/// are not run, and the reason fails the test under the drive's name.
struct CloudDriveStepFailure: LocalizedError {
    /// Why the step could not go on.
    let reason: String

    var errorDescription: String? {
        reason
    }
}

extension XCTestCase {
    /// Records `answer` to `question` on the drive of `root`: in the log at
    /// once, as an activity with the answer attached, which the test's
    /// results keep, and in the table printed when the class ends.
    func recordAnswer(_ answer: String, to question: CloudDriveQuestion, on root: CloudDriveTestRoot) async {
        let finding = CloudDriveFinding(drive: root.driveName, question: question, answer: answer)
        CloudDriveFindings.shared.record(finding)
        let line = "\(finding.drive), question \(question.rawValue) (\(question.title)): \(answer)"
        print("CLOUD DRIVE FINDING: \(line)")
        await keepNote(line, as: "\(finding.drive), question \(question.rawValue)")
    }

    /// Keeps `text` with the test's results: an activity named `text`, with
    /// `text` attached under `attachmentName` and kept even when the test
    /// passes.
    func keepNote(_ text: String, as attachmentName: String) async {
        // XCTest makes activities on the main actor only.
        await MainActor.run {
            XCTContext.runActivity(named: text) { activity in
                let attachment = XCTAttachment(string: text)
                attachment.name = attachmentName
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
        }
    }
}
