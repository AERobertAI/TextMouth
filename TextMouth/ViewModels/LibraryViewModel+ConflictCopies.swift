import Foundation
#if os(macOS)
import AppKit
#endif

// MARK: - Reporting a Cloud Drive's Conflict Copies (Phase 0 of the local-first design)

extension ConflictCopyFinding {
    /// The finding in a log line's words: what kind of file, and the copy's
    /// file name, never a path or anything it holds.
    var logDescription: String {
        let file: String
        switch place {
        case .file(let path): file = (path as NSString).lastPathComponent
        case .version(_, let path): file = "a version of \((path as NSString).lastPathComponent)"
        }
        switch subject {
        case .libraryIndex: return "library index: \(file)"
        case .feedRecord: return "feed record: \(file)"
        case .feedIndex: return "feed index: \(file)"
        case .bookRecord: return "book record: \(file)"
        }
    }
}

extension LibraryViewModel {
    /// In a library kept in a cloud location, looks for the conflict copies a
    /// sync service set aside of library.json, a feed's record, or a book's
    /// record, and iCloud Drive's unresolved versions of them, and reports
    /// each one once, saying what it holds and where it is. Nothing is
    /// merged or removed. The folders are listed off the main thread with
    /// downloads refused, so a library that hasn't arrived is not waited
    /// for; a copy reported before, remembered on this Mac
    /// (`ConflictCopyMemory`), is not reported again.
    ///
    /// - Parameters:
    ///   - finder: How the copies are found; the app's sync service unless
    ///     a test passes its own.
    ///   - memory: What was reported before; this Mac's own unless a test
    ///     passes its own.
    ///   - present: How a report is shown; an alert, which VoiceOver reads
    ///     as it appears, unless a test passes its own.
    func reportConflictCopiesInBackground(
        finder: ConflictCopyFinder? = nil,
        memory: ConflictCopyMemory? = nil,
        present: (@MainActor ([ConflictCopyFinding]) -> Void)? = nil
    ) {
        let finder = finder ?? ConflictCopyFinder(itemStatus: CloudServices.itemStatus)
        let memory = memory ?? .thisMac
        let root = TextMouthPaths.root
        Task { [weak self] in
            let fresh = await OffMainWork.run { memory.unreported(finder.findAll(in: root)) }
            guard let self else { return }
            await Self.reportAndRemember(
                fresh,
                libraryIsAvailable: self.dataDirectoryUnavailability == nil,
                memory: memory,
                present: present ?? Self.presentConflictCopyReport
            )
        }
    }

    /// Shows `fresh` and only then remembers it as reported, so a report that
    /// never reached the listener (the library became unavailable first, or
    /// the app quit before it showed) is made again at the next look: the
    /// copy may hold the only record of a change.
    @MainActor
    static func reportAndRemember(
        _ fresh: [ConflictCopyFinding],
        libraryIsAvailable: Bool,
        memory: ConflictCopyMemory,
        present: @MainActor ([ConflictCopyFinding]) -> Void
    ) async {
        guard !fresh.isEmpty, libraryIsAvailable else { return }
        for finding in fresh {
            DiagnosticLog.event(.storage, "CONFLICT_COPY_FOUND: \(finding.logDescription)")
        }
        present(fresh)
        await OffMainWork.run { memory.remember(fresh) }
    }

    /// Shows the report as an alert on the key window, which VoiceOver reads
    /// as it appears; OK is the default, and Show in Finder opens the first
    /// copy's folder. On iOS nothing is shown: the log line says it.
    @MainActor
    static func presentConflictCopyReport(_ findings: [ConflictCopyFinding]) {
        #if os(macOS)
        guard let first = findings.first else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ConflictCopyWording.alertTitle
        alert.informativeText = ConflictCopyWording.message(for: findings)
        alert.addButton(withTitle: ConflictCopyWording.okTitle)
        alert.addButton(withTitle: ConflictCopyWording.showTitle)
        let show: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.open(URL(fileURLWithPath: first.folderPath, isDirectory: true))
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: show)
        } else {
            show(alert.runModal())
        }
        #endif
    }
}
