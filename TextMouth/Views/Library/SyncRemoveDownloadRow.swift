import SwiftUI

/// Remove Download in Book Information, for a book of a synced library (FR46): a button, shown while sync is on, that
/// frees the book's space on this device while the book stays in iCloud Drive. It runs the command a row's menu runs
/// (`LibraryCloudCommands.removeDownloads`), which proves the copy first and says what came of it.
///
/// The button stays in its place, dimmed, once the book is away or can't be removed, so VoiceOver's focus is not
/// lost when it has been pressed. A refusal is shown as words under it and spoken once; a success is spoken by the
/// command itself.
struct SyncRemoveDownloadRow: View {
    /// The book the sheet shows.
    let book: Book
    /// The library, whose cloud commands run the removal.
    let library: LibraryViewModel
    /// What is known of each book's files, and whether sync is on.
    @ObservedObject private var states = BookCloudStates.shared
    /// Why the download stayed, in words, after a refusal; nil otherwise.
    @State private var refusal: String?
    /// Whether a removal is under way, which holds a second press back.
    @State private var isWorking = false

    var body: some View {
        if states.syncIsOn {
            Button(LibraryCloudWording.removeDownloadTitle(count: 1, forSelection: false)) { remove() }
                .disabled(isWorking || !states.canRemoveDownload(book))
                .accessibilityHint(SyncWording.removeDownloadHint)
            if let refusal {
                // The words say why, so nothing is told by a color alone.
                Text(refusal).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Runs Remove Download for the book, and shows and speaks a refusal.
    private func remove() {
        let commands = LibraryCloudCommand.commands(for: [book], isSelection: false, states: states, kept: [])
        guard let command = commands.first(where: { $0.kind == .removeDownload }) else { return }
        isWorking = true
        refusal = nil
        Task {
            let refused = await library.cloudCommands.perform(command, in: library, from: nil)
            isWorking = false
            if let refused {
                refusal = refused.message
                VoiceOverAnnouncer.announce(refused.message)
            }
        }
    }
}
