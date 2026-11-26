import XCTest
@testable import TextMouth

/// What the iPhone's reader shows while its book is got from the cloud (FR43): each of
/// the four phases, in the iPhone's words, with the one button each offers. The view
/// draws these; a book opened from a synced library that the phone doesn't hold yet
/// would otherwise have said "Loading <title>" for ever.
final class PhoneReaderCloudPhaseTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 0)

    private func content(_ phase: ReaderCloudPhase, provider: CloudProvider? = .iCloudDrive) -> PhoneReaderCloudPhaseContent {
        PhoneReaderCloudPhaseContent.of(phase: phase, title: "Dune", provider: provider, isPhone: true)
    }

    /// A download: its heading, where it comes from, the bar's label, and Cancel with its hint; the bar's value is the Mac's
    /// words (the percent, and the time waited, spoken in full).
    func testDownloading() {
        let progress = BookDownloadProgress(completedFiles: 2, totalFiles: 5, completedBytes: 40, totalBytes: 100)
        let download = ReaderDownload(provider: .iCloudDrive, chapterNumber: nil, startedAt: started, progress: progress)
        XCTAssertEqual(
            content(.downloading(download)).body,
            .download(
                heading: "Downloading Dune",
                source: "From iCloud Drive",
                progressLabel: "Download progress",
                cancel: .init(title: "Cancel", hint: ReaderViewWording.cancelDownloadHint)
            )
        )
        let value = ReaderCloudWording.progressValue(of: download, elapsed: 65, spoken: true)
        XCTAssertTrue(value.contains("40 percent"), value)
        // A chapter's download says which chapter.
        let chapter = ReaderDownload(provider: .iCloudDrive, chapterNumber: 6, startedAt: started, progress: nil)
        guard case .download(_, let source, _, _) = content(.downloading(chapter)).body else { return XCTFail("not a download") }
        XCTAssertEqual(source, "Chapter 6, from iCloud Drive")
    }

    /// A cancelled opening says the book isn't downloaded, and offers Download.
    func testNotDownloaded() {
        XCTAssertEqual(
            content(.notDownloaded).body,
            .message(
                text: ReaderCloudWording.notDownloaded(title: "Dune"),
                action: .init(title: ReaderViewWording.downloadTitle, hint: ReaderViewWording.downloadHint)
            )
        )
    }

    /// A failure says why, naming this iPhone where it names a device, and offers Try Again.
    func testFailed() {
        let phase = ReaderCloudPhase.failed(.partNotOnThisMac)
        guard case .message(let text, let action) = content(phase).body else { return XCTFail("not a message") }
        XCTAssertEqual(text, ReaderCloudWording.message(for: .partNotOnThisMac, title: "Dune", provider: .iCloudDrive))
        XCTAssertEqual(action, .init(title: ReaderViewWording.tryAgainTitle, hint: ReaderViewWording.tryAgainHint))
        guard case .message(let offline, _) = content(.failed(.download(.offline))).body else { return XCTFail("not a message") }
        XCTAssertEqual(offline, ReaderCloudWording.message(for: .download(.offline), title: "Dune", provider: .iCloudDrive))
    }

    /// A book whose files haven't arrived says so on this iPhone, and offers Try Again with the look-again hint.
    func testWaitingForSync() {
        XCTAssertEqual(
            content(.waitingForSync).body,
            .message(
                text: "Dune hasn't arrived on this iPhone yet. iCloud Drive may still be syncing it.",
                action: .init(title: ReaderViewWording.tryAgainTitle, hint: ReaderViewWording.lookAgainHint)
            )
        )
    }
}
