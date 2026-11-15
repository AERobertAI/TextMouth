import Foundation
import os
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - The Model of the Compare Libraries Sheet (Phase 0 of the local-first design)

/// What the Compare Libraries sheet shows and says: the library in use
/// compared with another copy, read off the main thread, stopped on request,
/// the count first and then one full sentence for each difference, and then
/// the files that could not be read. It changes neither copy: the reading is
/// all `LibraryCopyReader` does.
@MainActor
final class LibraryComparisonModel: ObservableObject {
    /// One row of the results: a sentence that makes sense heard alone.
    struct Row: Identifiable, Equatable {
        let id: Int
        let sentence: String
    }

    /// What the sheet is doing.
    enum Phase: Equatable {
        /// Reading and comparing.
        case comparing
        /// Done, stopped, or unable to compare.
        case finished
    }

    /// What the sheet is doing.
    @Published private(set) var phase: Phase = .comparing
    /// The sentence that heads the list: what is under way, then the count
    /// of differences, or why nothing was compared.
    @Published private(set) var heading: String
    /// The rows of the differences.
    @Published private(set) var rows: [Row] = []
    /// The rows of the files not read, a list of their own.
    @Published private(set) var unreadRows: [Row] = []

    /// The folder compared with the library in use.
    let otherFolder: URL

    private let thisFolder: URL
    private let thisLibrary: Library
    private let reader: LibraryCopyReader
    /// How often a long comparison says it is still going.
    private let progressInterval: Duration
    /// Says a sentence to VoiceOver: the announcer, unless a test listens.
    private let announce: @MainActor (String) -> Void
    /// Whether the listener asked to stop, read by the work off the main thread.
    private let stopRequested = OSAllocatedUnfairLock(initialState: false)
    /// The comparison under way.
    private var task: Task<Void, Never>?
    /// The spoken progress while it runs.
    private var progressTask: Task<Void, Never>?

    /// A comparison of `thisLibrary`, the library in `thisFolder` as the app
    /// holds it, with the copy in `otherFolder`.
    init(
        otherFolder: URL,
        thisFolder: URL,
        thisLibrary: Library,
        reader: LibraryCopyReader,
        progressInterval: Duration = .seconds(30),
        announce: @escaping @MainActor (String) -> Void = { VoiceOverAnnouncer.announce($0) }
    ) {
        self.progressInterval = progressInterval
        self.announce = announce
        self.otherFolder = otherFolder
        self.thisFolder = thisFolder
        self.thisLibrary = thisLibrary
        self.reader = reader
        heading = LibraryComparisonWording.comparingSentence(folder: otherFolder.path)
    }

    /// Starts reading and comparing, once. The result is announced to
    /// VoiceOver when it is ready.
    func start() {
        guard task == nil else { return }
        let reader = reader
        let thisFolder = thisFolder
        let thisLibrary = thisLibrary
        let otherFolder = otherFolder
        let stopRequested = stopRequested
        task = Task { [weak self] in
            let outcome = await OffMainWork.run {
                reader.compare(
                    thisFolder: thisFolder,
                    thisLibrary: thisLibrary,
                    otherFolder: otherFolder,
                    isCancelled: { stopRequested.withLock { $0 } }
                )
            }
            self?.finish(with: outcome)
        }
        // A long comparison says now and then that it is going on, since
        // nothing else would be heard for minutes.
        let began = Date()
        progressTask = Task { [weak self] in
            while let self, self.phase == .comparing {
                try? await Task.sleep(for: self.progressInterval)
                guard self.phase == .comparing, !Task.isCancelled else { return }
                self.announce(LibraryComparisonWording.progressSentence(seconds: Int(Date().timeIntervalSince(began))))
            }
        }
    }

    /// Stops the comparison. Nothing was changed, and the sheet says so.
    func stop() {
        stopRequested.withLock { $0 = true }
    }

    /// Shows `outcome`, logs its counts, and announces the count.
    private func finish(with outcome: LibraryComparisonOutcome) {
        let shown = Self.present(outcome, folder: otherFolder.path)
        heading = shown.heading
        rows = shown.rows.enumerated().map { Row(id: $0.offset, sentence: $0.element) }
        unreadRows = shown.unread.enumerated().map { Row(id: $0.offset, sentence: $0.element) }
        phase = .finished
        progressTask?.cancel()
        if case .compared(let comparison) = outcome {
            DiagnosticLog.event(
                .storage,
                "LIBRARY_COMPARED: \(comparison.differences.count) differences, \(comparison.unread.count) files not read"
            )
        }
        announce(shown.heading)
    }

    /// Everything the sheet says as text, one sentence to a line, for Copy
    /// Results.
    var copyableText: String {
        ([heading] + rows.map(\.sentence) + unreadRows.map(\.sentence)).joined(separator: "\n")
    }

    /// Puts `copyableText` on the clipboard, and says so.
    func copyResults() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyableText, forType: .string)
        #else
        UIPasteboard.general.string = copyableText
        #endif
        VoiceOverAnnouncer.announce(LibraryComparisonWording.copiedSentence)
    }

    /// The heading and the sentences of `outcome`, for the folder at
    /// `folder`: the count first, each difference as a sentence, and then the
    /// files not read, the first few by name and the rest counted.
    nonisolated static func present(_ outcome: LibraryComparisonOutcome, folder: String) -> (heading: String, rows: [String], unread: [String]) {
        switch outcome {
        case .compared(let comparison):
            let heading = LibraryComparisonWording.countSentence(
                differences: comparison.differences.count,
                unread: comparison.unread.count,
                folder: folder
            )
            return (heading, comparison.differences.map { LibraryComparisonWording.sentence(for: $0) }, unreadSentences(comparison.unread))
        case .differentLibraries:
            return (LibraryComparisonWording.differentLibrarySentence(folder: folder), [], [])
        case .notComparable(let unread):
            return (LibraryComparisonWording.nothingComparedSentence(folder: folder), [], unreadSentences(unread))
        case .cancelled:
            return (LibraryComparisonWording.stoppedSentence, [], [])
        }
    }

    /// One sentence for each unread file, the first `unreadListed` of them,
    /// and one for the rest.
    private nonisolated static func unreadSentences(_ files: [LibraryUnreadFile]) -> [String] {
        let listed = files.prefix(LibraryComparisonWording.unreadListed).map { LibraryComparisonWording.sentence(for: $0) }
        let rest = files.count - LibraryComparisonWording.unreadListed
        return rest > 0 ? listed + [LibraryComparisonWording.moreUnreadSentence(rest)] : listed
    }
}
