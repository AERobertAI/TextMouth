import CryptoKit
import Darwin
import XCTest
@testable import TextMouth

// MARK: - The sizes of a library's text

/// The sizes of about 100 made-up files shaped like the text of the real
/// library, counted read-only on November 25, 2026: 772 files, 726.7 MB, a
/// median of 660 KB, a 90th percentile of 2.0 MB, and a 99th of 3.9 MB. The
/// sizes come from a fixed curve through those percentiles, so every run
/// writes the same files, and no real book is read or copied.
enum SyncFetchSample {
    /// Control points of the curve: a fraction of the files, and the size at it, in bytes.
    private static let curve: [(share: Double, bytes: Double)] = [
        (0, 20_000), (0.1, 150_000), (0.25, 350_000), (0.5, 660_000),
        (0.75, 1_200_000), (0.9, 2_000_000), (0.99, 3_900_000), (1, 8_000_000),
    ]

    /// `count` sizes in bytes, smallest first, each the curve's size at the
    /// middle of its share of the files (log-linear between control points).
    static func sizes(count: Int = 100) -> [Int] {
        (0..<count).map { index in
            let share = (Double(index) + 0.5) / Double(count)
            let upper = curve.firstIndex { share <= $0.share } ?? curve.count - 1
            let (low, high) = (curve[upper - 1], curve[upper])
            let along = (share - low.share) / (high.share - low.share)
            return Int(exp(log(low.bytes) + along * (log(high.bytes) - log(low.bytes))))
        }
    }
}

/// The sample's shape, which needs no drive and runs everywhere.
final class SyncFetchSampleTests: XCTestCase {
    /// About 95 MB in 100 files, with the library's median and percentiles.
    func testTheSampleHasTheLibrarysShape() {
        let sizes = SyncFetchSample.sizes()
        XCTAssertEqual(sizes.count, 100)
        XCTAssertEqual(Double(sizes.reduce(0, +)) / 1e6, 95, accuracy: 6)
        XCTAssertEqual(Double(sizes[50]), 660_000, accuracy: 60_000)
        XCTAssertEqual(Double(sizes[90]), 2_000_000, accuracy: 200_000)
        XCTAssertEqual(sizes, sizes.sorted())
        XCTAssertEqual(sizes, SyncFetchSample.sizes(), "the same files every run")
    }
}

// MARK: - The spike

/// The spike of section 12 of the sync plan (FR43): what iCloud Drive does
/// with the files sync-store will put in it. Opt-in, like
/// `CloudDriveIntegrationTests`: it runs only when
/// `TEXTMOUTH_CLOUD_TEST_ROOTS` lists a folder named “TextMouth Cloud Tests”
/// (`TEST_RUNNER_` first, for xcodebuild), and only the orchestrator runs
/// it, with the user awake, since touching iCloud Drive can put a privacy
/// prompt on screen. Every file is made up (random bytes) and goes in a run
/// folder of its own that is removed when the test ends. Each wait is
/// bounded, and a test that reaches its limit fails and says what it
/// reached, instead of waiting on.
///
/// Each case prints its answers as `SYNC SPIKE <case>: …` lines and keeps
/// them with the results, so the orchestrator can read them off the run.
final class SyncRealDriveTests: XCTestCase {
    /// The folders this run uses, read before each test.
    private var roots: [CloudDriveTestRoot] = []
    /// The file-level status provider the app installs at launch.
    private let items = UbiquitousItemStatusProvider()

    override func setUp() async throws {
        try await super.setUp()
        roots = try CloudDriveTestRoots.requireRoots()
    }

    // MARK: - Helpers

    /// Prints and keeps one answer of the spike.
    private func note(_ caseName: String, _ text: String, on root: CloudDriveTestRoot) async {
        let line = "SYNC SPIKE \(caseName) (\(root.driveName)): \(text)"
        print(line)
        await keepNote(line, as: "\(caseName), \(root.driveName)")
    }

    /// Writes `bytes` of random data at `url`, staged in `staging` and moved in, as a change file is.
    private func writeStaged(_ bytes: Int, to url: URL, staging: URL) throws {
        let staged = staging.appendingPathComponent(UUID().uuidString)
        try SyntheticPackage.randomBytes(count: bytes).write(to: staged)
        try FileManager.default.moveItem(at: staged, to: url)
    }

    /// Waits, within `limit`, until every file reports its content uploaded, and returns how long that took.
    private func waitUntilUploaded(_ files: [URL], limit: Duration = CloudDriveWait.upload) async throws -> Duration {
        guard let took = try await CloudDriveWait.until(limit: limit, { files.allSatisfy { items.status(of: $0).isUploaded } }) else {
            throw CloudDriveStepFailure(reason: "\(files.count) files were not reported uploaded within \(CloudDriveWait.describe(limit)).")
        }
        return took
    }

    /// Evicts every file and waits, within the removal limit, until each is dataless.
    private func evictAll(_ files: [URL]) async throws {
        for file in files { try items.removeLocalCopy(of: file) }
        guard try await CloudDriveWait.until(limit: CloudDriveWait.removal, { files.allSatisfy { items.status(of: $0).state == .notDownloaded } }) != nil else {
            throw CloudDriveStepFailure(reason: "the local copies of \(files.count) files were not removed within \(CloudDriveWait.describe(CloudDriveWait.removal)).")
        }
    }

    /// The SHA-256 of `data`, lower-case hex.
    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The bytes a file really takes on disk, which a clone doesn't double.
    private func allocatedBytes(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize.map(Int64.init)
    }

    /// Seconds in `duration`, with a decimal.
    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: - Case 1: an upload's state

    /// Change files moved in from staging are written, and their upload keys
    /// are read every 2 seconds until all report uploaded: how long it takes,
    /// and which keys the drive gives.
    func testCase1UploadStateOfChangeFiles() async throws {
        await forEachCloudRoot(roots, label: "sync-spike-1") { root, run in
            let staging = run.appendingPathComponent("Staging", isDirectory: true)
            let device = run.appendingPathComponent("Devices/spike", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
            let files = (1...5).map { device.appendingPathComponent(SyncNames.changeFile(seq: $0, kind: .changes)) }
            for file in files { try writeStaged(20_000, to: file, staging: staging) }
            let first = items.flaggedStatus(of: files.first ?? device)
            await note("case 1", "right after the move: state \(first.status.state), uploaded \(first.status.isUploaded), "
                + "upload reported \(first.status.isUploadReported), carries flags \(first.carriesSyncFlags)", on: root)
            let took = try await waitUntilUploaded(files)
            await note("case 1", "5 files of 20 KB reported uploaded after \(CloudDriveWait.describe(took))", on: root)
        }
    }

    // MARK: - Case 2: the clone

    /// A 16 MB blob is copied with `FileManager.copyItem` (a clone on APFS):
    /// the bytes both take on disk at the copy, after the upload, five minutes
    /// on, and after eviction.
    func testCase2TheCloneUsesNoSecondCopy() async throws {
        await forEachCloudRoot(roots, label: "sync-spike-2") { root, run in
            // The original stays in the test's sandbox, off the drive.
            let local = try makeSandboxDirectory("sync-spike-original").appendingPathComponent("original.bin")
            try SyntheticPackage.randomBytes(count: 16_000_000).write(to: local)
            let blob = run.appendingPathComponent("blob.bin")
            try FileManager.default.copyItem(at: local, to: blob)
            func sizes() -> String { "original \(allocatedBytes(local) ?? -1), copy \(allocatedBytes(blob) ?? -1)" }
            await note("case 2", "at the copy: \(sizes())", on: root)
            _ = try await waitUntilUploaded([blob])
            await note("case 2", "uploaded: \(sizes())", on: root)
            _ = try await CloudDriveWait.until(limit: .seconds(300)) { false }
            await note("case 2", "five minutes on: \(sizes())", on: root)
            try await evictAll([blob])
            await note("case 2", "after eviction: \(sizes())", on: root)
        }
    }

    // MARK: - Case 3: a read-back

    /// An evicted file is seen dataless, requested, read, and its SHA-256
    /// compared with what was written; the time is recorded.
    func testCase3ReadBackAfterEviction() async throws {
        await forEachCloudRoot(roots, label: "sync-spike-3") { root, run in
            let blob = run.appendingPathComponent("blob.bin")
            let data = SyntheticPackage.randomBytes(count: 4_000_000)
            try data.write(to: blob)
            _ = try await waitUntilUploaded([blob])
            try await evictAll([blob])
            XCTAssertEqual(items.status(of: blob).state, .notDownloaded)
            try items.requestDownload(of: blob)
            let clock = ContinuousClock()
            let started = clock.now
            guard try await CloudDriveWait.until(limit: CloudDriveWait.download, { items.status(of: blob).state == .downloaded }) != nil else {
                throw CloudDriveStepFailure(reason: "the evicted file did not download within \(CloudDriveWait.describe(CloudDriveWait.download)).")
            }
            let back = try Data(contentsOf: blob)
            let took = clock.now - started
            XCTAssertEqual(sha256(back), sha256(data), "the read-back matches what was written")
            await note("case 3", "evicted, seen dataless, downloaded and read in \(String(format: "%.1f", seconds(took))) s; digest matches \(sha256(back) == sha256(data))", on: root)
        }
    }

    // MARK: - Case 7: how a large download shows its progress

    /// A 64 MB file is uploaded, evicted, and requested; at each half second of the download the status, the bytes the file
    /// system allocates, and the size it reports are logged. `SyncFolderIO.waitUntilHere` restarts its stall clock only when
    /// the allocated size changes; this shows whether iCloud Drive moves it while a file downloads. Every wait is bounded.
    func testCase7ADownloadsProgressAsTheFileSystemShowsIt() async throws {
        await forEachCloudRoot(roots, label: "sync-spike-7") { root, run in
            let blob = run.appendingPathComponent("large.bin")
            try SyntheticPackage.randomBytes(count: 64_000_000).write(to: blob)
            _ = try await waitUntilUploaded([blob], limit: .seconds(900))
            try await evictAll([blob])
            try items.requestDownload(of: blob)
            let clock = ContinuousClock()
            let started = clock.now
            var lines: [String] = []
            var changes = 0
            var last: Int64?
            while clock.now - started < CloudDriveWait.download {
                let state = items.status(of: blob).state
                let allocated = SyncFolderIO.allocatedBytes(of: blob)
                if allocated != last { changes += 1; last = allocated }
                lines.append(String(format: "%.1f s: %@, allocated %@, size %@", seconds(clock.now - started), "\(state)", allocated.map(String.init) ?? "nil", items.status(of: blob).byteCount.map(String.init) ?? "nil"))
                if state == .downloaded { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            await note("case 7", "the allocated size changed \(changes) times during the download; the polls follow", on: root)
            for line in lines { await note("case 7", line, on: root) }
        }
    }

    // MARK: - Case 4: a listing with evicted files

    /// A folder is listed while its files are evicted: under their own names,
    /// or as `.icloud` stand-ins, and with what sizes.
    func testCase4ListingWithEvictedFiles() async throws {
        await forEachCloudRoot(roots, label: "sync-spike-4") { root, run in
            let files = (1...3).map { run.appendingPathComponent("file\($0).bin") }
            for file in files { try SyntheticPackage.randomBytes(count: 100_000).write(to: file) }
            _ = try await waitUntilUploaded(files)
            try await evictAll(files)
            let names = try FileManager.default.contentsOfDirectory(atPath: run.path).sorted()
            let sizes = files.map { items.status(of: $0).byteCount.map(String.init) ?? "nil" }
            await note("case 4", "listing of evicted files: \(names); sizes by the status \(sizes)", on: root)
            XCTAssertEqual(names.filter { $0.hasPrefix("file") }.count, 3)
        }
    }

    // MARK: - Case 5: the identity token

    /// `FileManager.ubiquityIdentityToken` without the iCloud entitlement:
    /// whether it is nil, which sets the "signed out" sentence.
    func testCase5IdentityTokenWithoutTheEntitlement() async throws {
        let token = FileManager.default.ubiquityIdentityToken
        for root in roots {
            await note("case 5", "ubiquityIdentityToken is \(token == nil ? "nil" : "present")", on: root)
        }
    }

    // MARK: - Case 6: fetching a library's text

    /// How long fetching every book's text takes, one book at a time or every
    /// download started at once, for 100 made-up files shaped like the real
    /// library's text (`SyncFetchSample`, about 95 MB). The files are written
    /// and uploaded, evicted, and read one at a time (each waited for);
    /// evicted again, and then every download is started at once and the
    /// files read when all are local. Both totals, the MB per second, and the
    /// median time per file are logged. Every wait is bounded and the case
    /// gives up past its limit, saying which step it reached.
    func testCase6FetchingTheTextOneAtATimeOrAllAtOnce() async throws {
        await forEachCloudRoot(roots, label: "sync-spike-6") { root, run in
            let sizes = SyncFetchSample.sizes()
            let files = sizes.indices.map { run.appendingPathComponent(String(format: "text%03d.md", $0)) }
            for (file, size) in zip(files, sizes) { try SyntheticPackage.randomBytes(count: size).write(to: file) }
            let totalMB = Double(sizes.reduce(0, +)) / 1e6
            let uploadLimit: Duration = .seconds(1800)
            let uploadTook = try await waitUntilUploaded(files, limit: uploadLimit)
            await note("case 6", "\(files.count) files, \(String(format: "%.1f", totalMB)) MB uploaded after \(CloudDriveWait.describe(uploadTook))", on: root)
            try await evictAll(files)

            // One at a time: request, wait until local, read, and time each.
            let clock = ContinuousClock()
            let perFileLimit: Duration = .seconds(300)
            var each: [Double] = []
            let serialStart = clock.now
            for file in files {
                let started = clock.now
                try items.requestDownload(of: file)
                guard try await CloudDriveWait.until(limit: perFileLimit, { items.status(of: file).state == .downloaded }) != nil else {
                    throw CloudDriveStepFailure(reason: "one at a time: \(file.lastPathComponent) did not arrive within \(CloudDriveWait.describe(perFileLimit)) (\(each.count) fetched).")
                }
                _ = try Data(contentsOf: file)
                each.append(seconds(clock.now - started))
            }
            let serial = seconds(clock.now - serialStart)
            try await evictAll(files)

            // All at once: start every download, wait until all are local, then read.
            let parallelStart = clock.now
            for file in files { try items.requestDownload(of: file) }
            let allLimit: Duration = .seconds(1800)
            guard try await CloudDriveWait.until(limit: allLimit, { files.allSatisfy { items.status(of: $0).state == .downloaded } }) != nil else {
                let arrived = files.filter { items.status(of: $0).state == .downloaded }.count
                throw CloudDriveStepFailure(reason: "all at once: only \(arrived) of \(files.count) files arrived within \(CloudDriveWait.describe(allLimit)).")
            }
            for file in files { _ = try Data(contentsOf: file) }
            let parallel = seconds(clock.now - parallelStart)

            let median = each.sorted()[each.count / 2]
            await note("case 6", String(format: "one at a time: %.1f s total, %.2f MB/s, median %.2f s a file (slowest %.1f s)", serial, totalMB / serial, median, each.max() ?? 0), on: root)
            await note("case 6", String(format: "all at once: %.1f s total, %.2f MB/s", parallel, totalMB / parallel), on: root)
            await note("case 6", String(format: "all at once took %.0f%% of the one-at-a-time time", 100 * parallel / serial), on: root)
        }
    }
}
