import Foundation

// PhoneReaderCloudPhase.swift: what the iPhone's reader shows in place of its book
// while the book is got from the cloud (FR43, sync-iphone, section 8 of
// research/CLOUD-SYNC-BUILD-PLAN-2026-11-25.md; the Mac's is `ReaderCloudPhaseView`).
// A book a synced library lists but the phone doesn't hold yet opens into this: the
// download with its progress and Cancel, or why the book isn't ready and the one thing
// to do about it. The words are the Mac's own (`ReaderCloudWording`, `ReaderViewWording`),
// with this device named "this iPhone" where they name one. The decisions are plain
// values the Mac's test host pins; the view only draws them.

/// What the phone's reader shows for one `ReaderCloudPhase`.
struct PhoneReaderCloudPhaseContent: Equatable {
    /// What a button of the view is called and does, as VoiceOver hints it.
    struct Button: Equatable {
        let title: String
        let hint: String
    }

    /// The download under way, or the message that says why the book isn't ready.
    enum Body: Equatable {
        /// A download: its heading, where it comes from, and what the progress bar is called.
        case download(heading: String, source: String, progressLabel: String, cancel: Button)
        /// A reason, and the one button that tries again (or downloads again).
        case message(text: String, action: Button)
    }

    let body: Body

    /// What the view shows for `phase`, in the iPhone's words.
    /// - Parameters:
    ///   - phase: The reader's cloud phase.
    ///   - title: The book's title.
    ///   - provider: The sync service holding the library, when known.
    ///   - isPhone: Which device's sentences to use; this build's by default.
    static func of(phase: ReaderCloudPhase, title: String, provider: CloudProvider?, isPhone: Bool = ThisDevice.isPhone) -> PhoneReaderCloudPhaseContent {
        switch phase {
        case .downloading(let download):
            return PhoneReaderCloudPhaseContent(body: .download(
                heading: ReaderCloudWording.heading(title: title),
                source: ReaderCloudWording.source(provider: download.provider, chapterNumber: download.chapterNumber),
                progressLabel: ReaderCloudWording.progressLabel,
                cancel: Button(title: ReaderViewWording.cancelTitle, hint: ReaderViewWording.cancelDownloadHint)
            ))
        case .notDownloaded:
            return PhoneReaderCloudPhaseContent(body: .message(
                text: ReaderCloudWording.notDownloaded(title: title),
                action: Button(title: ReaderViewWording.downloadTitle, hint: ReaderViewWording.downloadHint)
            ))
        case .failed(let failure):
            return PhoneReaderCloudPhaseContent(body: .message(
                text: ReaderCloudWording.message(for: failure, title: title, provider: provider),
                action: Button(title: ReaderViewWording.tryAgainTitle, hint: ReaderViewWording.tryAgainHint)
            ))
        case .waitingForSync:
            return PhoneReaderCloudPhaseContent(body: .message(
                text: ReaderCloudWording.waitingForSync(title: title, provider: provider, isPhone: isPhone),
                action: Button(title: ReaderViewWording.tryAgainTitle, hint: ReaderViewWording.lookAgainHint)
            ))
        }
    }
}
