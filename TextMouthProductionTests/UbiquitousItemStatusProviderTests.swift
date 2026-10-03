import Darwin
import XCTest
@testable import TextMouth

/// The file-level cloud state read from Foundation's ubiquitous-item keys
/// and the dataless flag (FR02, `UbiquitousItemStatusProvider`): which sync
/// service a folder belongs to, how the keys map to a state, and which
/// requests reach the sync service. No real cloud drive is used: the
/// metadata comes from an injected reader, or from ordinary files in the
/// sandbox.
final class UbiquitousItemStatusProviderTests: XCTestCase {

    /// The metadata the provider reads about one item.
    typealias Metadata = UbiquitousItemStatusProvider.Metadata

    // MARK: - Provider Detection from Paths

    /// A folder inside a container in Mobile Documents is in iCloud Drive,
    /// also when reached through the Data volume's own path.
    func testFoldersInMobileDocumentsContainersAreInICloudDrive() {
        for path in [
            "/Users/reader/Library/Mobile Documents/com~apple~CloudDocs/TextMouth",
            "/Users/reader/Library/Mobile Documents/com~apple~CloudDocs",
            "/Users/reader/Library/Mobile Documents/iCloud~com~example~notes/Documents/Books",
            "/System/Volumes/Data/Users/reader/Library/Mobile Documents/com~apple~CloudDocs/Books",
        ] {
            XCTAssertEqual(Self.provider(forPath: path), .iCloudDrive, path)
        }
    }

    /// A folder in CloudStorage belongs to the drive its folder names:
    /// Google Drive and Dropbox by name, any other drive by its folder's
    /// name up to the first "-".
    func testFileProviderDrivesAreNamedByTheirFolders() {
        let expectations: [(path: String, provider: CloudProvider)] = [
            ("/Users/reader/Library/CloudStorage/GoogleDrive-reader@example.com/My Drive/TextMouth", .googleDrive),
            ("/Users/reader/Library/CloudStorage/Dropbox/TextMouth", .dropbox),
            ("/Users/reader/Library/CloudStorage/Dropbox-Personal", .dropbox),
            ("/Users/reader/Library/CloudStorage/OneDrive-Personal/Books", .other("OneDrive")),
            ("/Users/reader/Library/CloudStorage/Box-Box/Books", .other("Box")),
            ("/Users/reader/Library/CloudStorage/pCloudDrive/Books", .other("pCloudDrive")),
            ("/Users/reader/Library/CloudStorage/-Unnamed/Books", .other("-Unnamed")),
        ]

        for expectation in expectations {
            XCTAssertEqual(Self.provider(forPath: expectation.path), expectation.provider, expectation.path)
        }
    }

    /// Components match without regard to case, as the startup disk does.
    func testPathsMatchWithoutRegardToCase() {
        XCTAssertEqual(Self.provider(forPath: "/Users/reader/library/mobile documents/com~apple~clouddocs/t"), .iCloudDrive)
        XCTAssertEqual(Self.provider(forPath: "/Users/reader/LIBRARY/cloudstorage/googledrive-r@example.com/x"), .googleDrive)
    }

    /// A path that runs through neither place, or stops at a place without
    /// a container or drive inside it, names no sync service.
    func testOtherPathsNameNoProvider() {
        for path in [
            "/Users/reader/.TextMouth",
            "/Users/reader/Library/Mobile Documents",
            "/Users/reader/Library/CloudStorage",
            "/Users/reader/Documents/Mobile Documents/com~apple~CloudDocs",
            "/Users/reader/Library/Application Support/CloudStorage/Dropbox",
            "/Volumes/Archive Disk/TextMouth",
            "/",
        ] {
            XCTAssertNil(Self.provider(forPath: path), path)
        }
    }

    /// Only path components count, never the home folder, so the hosted
    /// tests' sandbox home has the same places as a real one.
    func testASandboxHomeHasTheSamePlaces() {
        let folder = HostedTestSandbox.home.appendingPathComponent("Library/CloudStorage/Dropbox/Books", isDirectory: true)

        XCTAssertEqual(UbiquitousItemStatusProvider.provider(forPath: folder), .dropbox)
    }

    // MARK: - Location from Injected Metadata

    /// A path in a sync service's place is cloud before anything is read.
    func testAFolderInASyncServicesPlaceNeedsNoRead() {
        let provider = Self.provider(knowing: [:], failingReads: true)

        XCTAssertEqual(
            provider.location(of: URL(fileURLWithPath: "/Users/reader/Library/CloudStorage/Dropbox/New Library")),
            .cloud(.dropbox)
        )
    }

    /// A folder a sync service manages outside both places is in iCloud
    /// Drive, which syncs Desktop and Documents where they are.
    func testAManagedFolderOutsideThePlacesIsInICloudDrive() {
        let provider = Self.provider(knowing: [
            "/": Metadata(volumeURL: Self.startupVolume),
            "/Users/reader/Documents/TextMouth": Metadata(isUbiquitousItem: true, volumeURL: Self.startupVolume),
        ])

        XCTAssertEqual(provider.location(of: URL(fileURLWithPath: "/Users/reader/Documents/TextMouth")), .cloud(.iCloudDrive))
    }

    /// A folder that does not exist yet is judged by its nearest ancestor
    /// that does.
    func testAFolderNotMadeYetIsJudgedByItsNearestExistingAncestor() {
        let provider = Self.provider(knowing: [
            "/": Metadata(volumeURL: Self.startupVolume),
            "/Users/reader/Documents": Metadata(isUbiquitousItem: true, volumeURL: Self.startupVolume),
            "/Volumes/Archive Disk": Metadata(volumeURL: Self.archiveDisk, volumeName: "Archive Disk"),
        ])

        XCTAssertEqual(
            provider.location(of: URL(fileURLWithPath: "/Users/reader/Documents/TextMouth/Library")),
            .cloud(.iCloudDrive)
        )
        XCTAssertEqual(
            provider.location(of: URL(fileURLWithPath: "/Volumes/Archive Disk/Books/TextMouth")),
            .otherVolume(name: "Archive Disk")
        )
    }

    /// A folder on another volume is named by that volume, or by the
    /// volume's folder when it reports no name.
    func testAFolderOnAnotherVolumeIsNamedByItsVolume() {
        let named = Self.provider(knowing: [
            "/": Metadata(volumeURL: Self.startupVolume),
            "/Volumes/Archive Disk/TextMouth": Metadata(volumeURL: Self.archiveDisk, volumeName: "Archive Disk"),
        ])
        let unnamed = Self.provider(knowing: [
            "/": Metadata(volumeURL: Self.startupVolume),
            "/Volumes/Archive Disk/TextMouth": Metadata(volumeURL: Self.archiveDisk),
        ])
        let folder = URL(fileURLWithPath: "/Volumes/Archive Disk/TextMouth")

        XCTAssertEqual(named.location(of: folder), .otherVolume(name: "Archive Disk"))
        XCTAssertEqual(unnamed.location(of: folder), .otherVolume(name: "Archive Disk"))
    }

    /// A folder on the startup volume is local, also when its volume's URL
    /// is spelled with a trailing slash.
    func testAFolderOnTheStartupVolumeIsLocal() {
        let provider = Self.provider(knowing: [
            "/": Metadata(volumeURL: Self.startupVolume),
            "/Users/reader/.TextMouth": Metadata(volumeURL: URL(fileURLWithPath: "/", isDirectory: false)),
        ])

        XCTAssertEqual(provider.location(of: URL(fileURLWithPath: "/Users/reader/.TextMouth")), .local)
    }

    /// Without the startup volume to compare with, or with nothing readable
    /// at all, a folder counts as local.
    func testAFolderThatCannotBeComparedIsLocal() {
        let withoutStartupVolume = Self.provider(knowing: [
            "/Volumes/Archive Disk/TextMouth": Metadata(volumeURL: Self.archiveDisk, volumeName: "Archive Disk"),
        ])
        let withNothing = Self.provider(knowing: [:])

        XCTAssertEqual(withoutStartupVolume.location(of: URL(fileURLWithPath: "/Volumes/Archive Disk/TextMouth")), .local)
        XCTAssertEqual(withNothing.location(of: URL(fileURLWithPath: "/Users/reader/.TextMouth")), .local)
    }

    // MARK: - Location on This Mac

    /// The hosted tests' data directory, their sandbox, and a folder not
    /// made yet inside it are all local: installing the real provider
    /// changes nothing for them.
    func testTheSandboxIsLocal() {
        let provider = UbiquitousItemStatusProvider()

        XCTAssertEqual(provider.location(of: TextMouthPaths.root), .local)
        XCTAssertEqual(provider.location(of: HostedTestSandbox.home), .local)
        XCTAssertEqual(provider.location(of: HostedTestSandbox.home.appendingPathComponent("Not Made Yet/Library")), .local)
    }

    /// A link that leads into a sync service's place leads to that service,
    /// for the link itself and for a folder not made yet behind it.
    func testALinkIntoASyncServicesPlaceLeadsToIt() throws {
        let scratch = try makeSandboxDirectory("CloudLocation")
        let drive = scratch.appendingPathComponent("Library/CloudStorage/GoogleDrive-reader@example.com/My Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let link = scratch.appendingPathComponent("Drive", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: drive)
        let provider = UbiquitousItemStatusProvider()

        XCTAssertEqual(provider.location(of: link), .cloud(.googleDrive))
        XCTAssertEqual(provider.location(of: link.appendingPathComponent("TextMouth", isDirectory: true)), .cloud(.googleDrive))
    }

    // MARK: - Status Mapping

    /// An item no sync service manages is local with its size, whatever
    /// its other keys say: nil and false both mean unmanaged.
    func testAnUnmanagedItemIsLocalWhateverItsOtherKeysSay() {
        for isUbiquitousItem in [nil, false] as [Bool?] {
            for metadata in Self.everyKeyCombination(isUbiquitousItem: isUbiquitousItem, isDataless: false) {
                XCTAssertEqual(UbiquitousItemStatusProvider.status(from: metadata), .local(byteCount: 42), "\(metadata)")
            }
        }
    }

    /// The status keys and the dataless flag agreeing give their state.
    func testKeysThatAgreeWithTheDatalessFlagGiveTheirState() {
        let expectations: [(metadata: Metadata, state: CloudItemState)] = [
            (Metadata(isUbiquitousItem: true, downloadingStatus: .current, isDataless: false), .downloaded),
            (Metadata(isUbiquitousItem: true, downloadingStatus: .downloaded, isDataless: false), .downloaded),
            (Metadata(isUbiquitousItem: true, downloadingStatus: .notDownloaded, isDataless: true), .notDownloaded),
            (
                Metadata(isUbiquitousItem: true, downloadingStatus: .notDownloaded, isDownloading: true, isDataless: true),
                .downloading
            ),
        ]

        for expectation in expectations {
            XCTAssertEqual(UbiquitousItemStatusProvider.status(from: expectation.metadata).state, expectation.state)
        }
    }

    /// The dataless flag overrules keys that disagree with it: the content
    /// is only in the cloud when the item is dataless, and on this Mac when
    /// it is not, since a sync service puts content in place only whole.
    func testTheDatalessFlagOverrulesKeysThatDisagree() {
        let expectations: [(metadata: Metadata, state: CloudItemState)] = [
            (Metadata(isUbiquitousItem: true, downloadingStatus: .current, isDataless: true), .notDownloaded),
            (
                Metadata(isUbiquitousItem: true, downloadingStatus: .downloaded, isDownloading: true, isDataless: true),
                .downloading
            ),
            (Metadata(isUbiquitousItem: true, downloadingStatus: .notDownloaded, isDataless: false), .downloaded),
            (Metadata(isUbiquitousItem: true, isDownloading: true, isDataless: false), .downloaded),
            (Metadata(isUbiquitousItem: nil, isDataless: true), .notDownloaded),
            (Metadata(isUbiquitousItem: false, downloadingStatus: .current, isDataless: true), .notDownloaded),
        ]

        for expectation in expectations {
            XCTAssertEqual(
                UbiquitousItemStatusProvider.status(from: expectation.metadata).state,
                expectation.state,
                "\(expectation.metadata)"
            )
        }
    }

    /// Every combination of keys and the flag: unmanaged and not dataless
    /// is local; dataless is downloading while the service says so and
    /// otherwise not downloaded; managed and not dataless is downloaded.
    func testEveryCombinationOfKeys() {
        for isUbiquitousItem in [nil, false, true] as [Bool?] {
            for isDataless in [false, true] {
                for metadata in Self.everyKeyCombination(isUbiquitousItem: isUbiquitousItem, isDataless: isDataless) {
                    let expected: CloudItemState
                    if isUbiquitousItem != true && !isDataless {
                        expected = .local
                    } else if isDataless {
                        expected = metadata.isDownloading == true ? .downloading : .notDownloaded
                    } else {
                        expected = .downloaded
                    }
                    XCTAssertEqual(UbiquitousItemStatusProvider.status(from: metadata).state, expected, "\(metadata)")
                }
            }
        }
    }

    /// A managed item's upload flag, conflicts, error, and size come
    /// through; missing flags mean uploaded and no conflict.
    func testAManagedItemsSyncDetailsComeThrough() {
        let waiting = UbiquitousItemStatusProvider.status(from: Metadata(
            isUbiquitousItem: true,
            downloadingStatus: .current,
            isUploaded: false,
            hasUnresolvedConflicts: true,
            downloadError: "The network connection was lost.",
            byteCount: 7
        ))
        let quiet = UbiquitousItemStatusProvider.status(from: Metadata(isUbiquitousItem: true, isDataless: true))

        XCTAssertEqual(
            waiting,
            CloudItemStatus(
                state: .downloaded,
                isUploaded: false,
                byteCount: 7,
                hasUnresolvedConflicts: true,
                downloadError: "The network connection was lost."
            )
        )
        XCTAssertEqual(
            quiet,
            CloudItemStatus(state: .notDownloaded, isUploaded: true, byteCount: nil, hasUnresolvedConflicts: false, downloadError: nil)
        )
    }

    // MARK: - Reading One File

    /// A file the system will not look up without downloading, because a
    /// folder above it is only in the cloud, is not downloaded.
    func testAFileTheSystemWillNotLookUpIsNotDownloaded() {
        let refusal = CocoaError(.fileReadUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(.EDEADLK)])
        let provider = UbiquitousItemStatusProvider(readMetadata: { _, _ in throw refusal })

        XCTAssertEqual(
            provider.status(of: URL(fileURLWithPath: "/Users/reader/Library/Mobile Documents/com~apple~CloudDocs/a.txt")),
            CloudItemStatus(state: .notDownloaded, isUploaded: true, byteCount: nil, hasUnresolvedConflicts: false, downloadError: nil)
        )
    }

    /// A path with nothing at it is missing.
    func testAPathWithNothingAtItIsMissing() {
        let provider = UbiquitousItemStatusProvider(readMetadata: { _, _ in throw CocoaError(.fileReadNoSuchFile) })

        XCTAssertEqual(provider.status(of: URL(fileURLWithPath: "/Users/reader/absent.txt")), .missing)
    }

    /// Ordinary files on this Mac: a file is local with its size, and a
    /// path with nothing at it is missing.
    func testRealFilesAreLocalOrMissing() throws {
        let folder = try makeSandboxDirectory("CloudStatus")
        let file = folder.appendingPathComponent("chapter.txt")
        try Data("twelve bytes".utf8).write(to: file)
        let provider = UbiquitousItemStatusProvider()

        XCTAssertEqual(provider.status(of: file), .local(byteCount: 12))
        XCTAssertEqual(provider.status(of: folder.appendingPathComponent("absent.txt")), .missing)
    }

    /// A file read again reports what it is now, even through a URL that
    /// has already read its values: `NSURL` would otherwise answer from
    /// what it cached.
    func testAFileReadAgainReportsWhatItIsNow() throws {
        let folder = try makeSandboxDirectory("CloudStatus")
        let file = folder.appendingPathComponent("chapter.txt")
        try Data("five!".utf8).write(to: file)
        XCTAssertEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, 5, "the URL has read and cached its size")
        let provider = UbiquitousItemStatusProvider()

        try Data("now eleven!".utf8).write(to: file)

        XCTAssertEqual(provider.status(of: file), .local(byteCount: 11))
    }

    /// Every read happens with dataless files left in the cloud.
    func testEveryReadLeavesDatalessFilesInTheCloud() throws {
        let policies = DatalessPolicyRecorder()
        let provider = UbiquitousItemStatusProvider(
            readMetadata: { url, keys in
                policies.record()
                return try UbiquitousItemStatusProvider.readFreshMetadata(of: url, keys: keys)
            },
            startDownload: { _ in },
            evict: { _ in }
        )
        let file = try makeSandboxDirectory("CloudStatus").appendingPathComponent("chapter.txt")
        try Data("here".utf8).write(to: file)

        _ = provider.status(of: file)
        _ = provider.location(of: file.deletingLastPathComponent())
        try provider.removeLocalCopy(of: file)

        XCTAssertFalse(policies.recorded.isEmpty)
        XCTAssertEqual(Set(policies.recorded), [IOPOL_MATERIALIZE_DATALESS_FILES_OFF])
    }

    // MARK: - Requests

    /// A download request reaches the sync service for the item asked for.
    func testARequestedDownloadReachesTheSyncService() throws {
        let requests = URLRecorder()
        let provider = UbiquitousItemStatusProvider(
            readMetadata: { _, _ in Metadata(isUbiquitousItem: true, isDataless: true) },
            startDownload: { requests.record($0) },
            evict: { _ in XCTFail("nothing is removed") }
        )
        let file = URL(fileURLWithPath: "/Users/reader/Library/CloudStorage/Dropbox/Book.tmb/content.md")

        try provider.requestDownload(of: file)

        XCTAssertEqual(requests.recorded, [file])
    }

    /// Only a managed file whose content is on this Mac has a local copy to
    /// remove: one only in the cloud, a local file, and a missing path are
    /// left alone.
    func testOnlyAManagedFileOnThisMacIsEvicted() throws {
        let cases: [(metadata: Metadata?, evicts: Bool)] = [
            (Metadata(isUbiquitousItem: true, downloadingStatus: .current), true),
            (Metadata(isUbiquitousItem: true, isDownloading: true, isDataless: true), true),
            (Metadata(isUbiquitousItem: true, downloadingStatus: .notDownloaded, isDataless: true), false),
            (Metadata(isUbiquitousItem: nil, byteCount: 10), false),
            (nil, false),
        ]

        for testCase in cases {
            let evictions = URLRecorder()
            let metadata = testCase.metadata
            let provider = UbiquitousItemStatusProvider(
                readMetadata: { _, _ in
                    guard let metadata else { throw CocoaError(.fileReadNoSuchFile) }
                    return metadata
                },
                startDownload: { _ in XCTFail("nothing is downloaded") },
                evict: { evictions.record($0) }
            )
            let file = URL(fileURLWithPath: "/Users/reader/Library/Mobile Documents/com~apple~CloudDocs/a.txt")

            try provider.removeLocalCopy(of: file)

            XCTAssertEqual(evictions.recorded, testCase.evicts ? [file] : [], "\(String(describing: metadata))")
        }
    }

    /// Removing the local copy of a real local file does nothing to it: it
    /// has no copy in the cloud to fall back on.
    func testRemovingAnOrdinaryFilesLocalCopyKeepsItsContent() throws {
        let file = try makeSandboxDirectory("CloudStatus").appendingPathComponent("chapter.txt")
        try Data("still here".utf8).write(to: file)

        try UbiquitousItemStatusProvider().removeLocalCopy(of: file)

        XCTAssertEqual(try Data(contentsOf: file), Data("still here".utf8))
    }

    // MARK: - Helpers

    /// The startup volume's root, as metadata reports it.
    private static let startupVolume = URL(fileURLWithPath: "/", isDirectory: true)

    /// Another volume's root.
    private static let archiveDisk = URL(fileURLWithPath: "/Volumes/Archive Disk", isDirectory: true)

    /// The provider `provider(forPath:)` names for `path`.
    private static func provider(forPath path: String) -> CloudProvider? {
        UbiquitousItemStatusProvider.provider(forPath: URL(fileURLWithPath: path))
    }

    /// A provider that reads `items`' metadata by standardized path; any
    /// other path has nothing at it. With `failingReads`, any read fails
    /// the test. Requests fail the test.
    private static func provider(knowing items: [String: Metadata], failingReads: Bool = false) -> UbiquitousItemStatusProvider {
        UbiquitousItemStatusProvider(
            readMetadata: { url, _ in
                if failingReads { XCTFail("no read is needed: \(url.path)") }
                guard let metadata = items[url.standardizedFileURL.path] else { throw CocoaError(.fileReadNoSuchFile) }
                return metadata
            },
            startDownload: { _ in XCTFail("nothing is downloaded") },
            evict: { _ in XCTFail("nothing is removed") }
        )
    }

    /// Metadata for every combination of the status keys, with the given
    /// management key and dataless flag, a size of 42 bytes, and the upload
    /// and conflict flags of a quiet file.
    private static func everyKeyCombination(isUbiquitousItem: Bool?, isDataless: Bool) -> [Metadata] {
        let statuses: [URLUbiquitousItemDownloadingStatus?] = [nil, .current, .downloaded, .notDownloaded]
        let downloading: [Bool?] = [nil, false, true]
        return statuses.flatMap { status in
            downloading.map { isDownloading in
                Metadata(
                    isUbiquitousItem: isUbiquitousItem,
                    downloadingStatus: status,
                    isDownloading: isDownloading,
                    isUploaded: true,
                    hasUnresolvedConflicts: false,
                    byteCount: 42,
                    isDataless: isDataless
                )
            }
        }
    }
}

// MARK: - Recorders

/// URLs a request was made for, from any thread.
private final class URLRecorder: @unchecked Sendable {
    /// Guards `urls`.
    private let lock = NSLock()
    /// The URLs, in order.
    private var urls: [URL] = []

    /// Records `url`.
    func record(_ url: URL) {
        lock.withLock { urls.append(url) }
    }

    /// The URLs recorded, in order.
    var recorded: [URL] {
        lock.withLock { urls }
    }
}

/// The calling thread's dataless-file policy at each read, for the cloud
/// service tests that check a read never downloads.
final class DatalessPolicyRecorder: @unchecked Sendable {
    /// Guards `policies`.
    private let lock = NSLock()
    /// The policies, in order.
    private var policies: [Int32] = []

    /// Records the calling thread's policy.
    func record() {
        let policy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        lock.withLock { policies.append(policy) }
    }

    /// The policies recorded, in order.
    var recorded: [Int32] {
        lock.withLock { policies }
    }
}
