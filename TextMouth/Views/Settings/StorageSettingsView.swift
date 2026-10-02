import SwiftUI

/// A data-directory operation started from Storage settings.
enum StorageOperation: Equatable {
    /// Rebuild Directory.
    case rebuild
    /// Reset to Default: move the data back to ~/.TextMouth.
    case resetToDefault
    /// Change Location: move the data into the given directory.
    case move(to: URL)

    /// What the status line says while the operation runs.
    var runningMessage: String {
        switch self {
        case .rebuild:
            return "Rebuilding the data directory..."
        case .resetToDefault:
            return "Moving data to the default location..."
        case .move(let destination):
            return "Moving data to \(destination.path)..."
        }
    }
}

/// The line under the storage buttons: what an operation is doing, what it
/// did, or why it failed (TODO A07). "Done" appears only after a success.
struct StorageStatus: Equatable {
    /// The words shown, which are also what VoiceOver reads and announces.
    let message: String
    /// Whether the line reports a refusal or failure, which is shown in red.
    /// The words say so too, so color is never the only signal.
    let isFailure: Bool

    /// The status while `operation` runs.
    static func running(_ operation: StorageOperation) -> StorageStatus {
        StorageStatus(message: operation.runningMessage, isFailure: false)
    }

    /// The status once an operation has finished with `outcome`: its own
    /// words, which after a failure are those of the library's error alert.
    static func finished(_ outcome: OperationOutcome) -> StorageStatus {
        StorageStatus(message: outcome.message ?? "Done.", isFailure: !outcome.succeeded)
    }

    /// The finished status, announced once. VoiceOver does not read a
    /// status line that changes by itself, so each operation's result is
    /// spoken when it is shown.
    @MainActor
    static func announced(after outcome: OperationOutcome) -> StorageStatus {
        let status = finished(outcome)
        VoiceOverAnnouncer.announce(status.message)
        return status
    }
}

struct StorageSettingsView: View {
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    @State private var showRebuildConfirmation = false
    @State private var showResetToDefaultConfirmation = false
    @State private var showMoveConfirmation = false
    @State private var pendingMoveURL: URL?
    @State private var showFolderPicker = false
    /// What the last data-directory operation is doing or did.
    @State private var status: StorageStatus?
    /// The data-directory operation in progress, if any.
    @State private var runningOperation: StorageOperation?
    @State private var importDeleteBehavior: ImportDeleteBehavior
    @State private var confirmBeforeDelete: Bool
    @State private var moveToTrash: Bool
    @State private var showDuplicateFinder = false
    @State private var showRedoExtractionConfirmation = false

    init() {
        _importDeleteBehavior = State(initialValue: ConfigService.shared.config.importDeleteBehavior)
        _confirmBeforeDelete = State(initialValue: ConfigService.shared.config.confirmBeforeDelete)
        _moveToTrash = State(initialValue: ConfigService.shared.config.moveToTrashInsteadOfDeleting)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Location") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(TextMouthPaths.rootPath)
                            .textSelection(.enabled)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .font(.caption)

                        if TextMouthPaths.isCustomPath {
                            Text("Custom location")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        } else {
                            Text("Default location")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                    }
                }
                .accessibilityLabel("Data directory: \(TextMouthPaths.rootPath)")

                LabeledContent("Status") {
                    Text(Self.statusText(
                        isRecoveringIndex: isRecoveringIndex,
                        directoryExists: TextMouthPaths.directoryExists
                    ))
                    .foregroundColor(isRecoveringIndex || !TextMouthPaths.directoryExists ? .red : .green)
                }

                if isRecoveringIndex {
                    Text(LibraryIndexRecoveryText.settingsExplanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Moving or rebuilding the directory would act on the
                // temporary library while the index cannot be read, and
                // must not start twice while one operation runs.
                HStack {
                    Button("Change Location...") {
                        showFolderPicker = true
                    }
                    .accessibilityLabel("Choose a new location for the data directory")
                    .accessibilityHint("Opens a folder picker to select where TextMouth stores its data")

                    if TextMouthPaths.isCustomPath {
                        Button("Reset to Default") {
                            showResetToDefaultConfirmation = true
                        }
                        .accessibilityLabel("Reset to default location")
                        .accessibilityHint("Moves data back to the default location at ~/.TextMouth")
                    }
                }
                .disabled(maintenanceUnavailable)

                Button("Rebuild Directory") {
                    showRebuildConfirmation = true
                }
                .disabled(maintenanceUnavailable)
                .accessibilityLabel("Rebuild TextMouth directory")
                .accessibilityHint("Recreates the directory structure and migrates any books using old storage")

                if let status {
                    Text(status.message)
                        .font(.caption)
                        .foregroundColor(status.isFailure ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Storage Directory")
            }

            Section {
                Picker("After Importing a Book", selection: $importDeleteBehavior) {
                    ForEach(ImportDeleteBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.rawValue).tag(behavior)
                    }
                }
                .accessibilityLabel("Original file handling")
                .accessibilityHint("What to do with the original file after importing a book")
                .onChange(of: importDeleteBehavior) { newValue in
                    ConfigService.shared.config.importDeleteBehavior = newValue
                    ConfigService.shared.saveToDisk()
                }

                switch importDeleteBehavior {
                case .keepOriginal:
                    Text("The original file will remain untouched after import.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .deleteAfterImport:
                    Text("The original file will be permanently deleted after a successful import.")
                        .font(.caption)
                        .foregroundColor(.orange)
                case .askEachTime:
                    Text("You will be asked whether to delete the original after each import.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Import Behavior")
            }

            Section {
                Toggle("Confirm before removing a book", isOn: $confirmBeforeDelete)
                    .onChange(of: confirmBeforeDelete) { newValue in
                        ConfigService.shared.config.confirmBeforeDelete = newValue
                        ConfigService.shared.saveToDisk()
                    }
                    .accessibilityHint("When enabled, you will be asked to confirm before a book is removed, with the option to keep or delete the file")

                Toggle("Move to Trash instead of deleting", isOn: $moveToTrash)
                    .onChange(of: moveToTrash) { newValue in
                        ConfigService.shared.config.moveToTrashInsteadOfDeleting = newValue
                        ConfigService.shared.saveToDisk()
                    }
                    .accessibilityHint("When enabled, deleted books are moved to the Trash where they can be recovered. When disabled, files are permanently deleted.")

                Text(moveToTrash
                    ? "Removed books go to the Trash and can be recovered."
                    : "Removed books are permanently deleted from disk.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Removal Behavior")
            }

            Section {
                LabeledContent("Books") {
                    Text("\(libraryViewModel.library.books.count)")
                }
                LabeledContent("Folders") {
                    Text("\(libraryViewModel.library.folders.count)")
                }
                let tmbCount = libraryViewModel.library.books.filter { !$0.tmbDirectoryName.isEmpty }.count
                LabeledContent("TMB Packages") {
                    Text("\(tmbCount) of \(libraryViewModel.library.books.count)")
                }
            } header: {
                Text("Library Statistics")
            }

            Section {
                Button("Find Duplicate Books...") {
                    showDuplicateFinder = true
                }
                .accessibilityLabel("Find duplicate books")
                .accessibilityHint("Scans the library for books with matching files, titles, or authors")

                Text("Search across all folders for potential duplicate books based on file content, title, or author.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Redo Text Extraction...") {
                    showRedoExtractionConfirmation = true
                }
                .disabled(libraryViewModel.isExtracting)
                .accessibilityLabel("Redo text extraction")
                .accessibilityHint("Re-extracts cached text from all books. Useful after parser fixes or format improvements.")

                if libraryViewModel.isExtracting {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(libraryViewModel.extractionProgressCurrent),
                                     total: Double(max(libraryViewModel.extractionProgressTotal, 1)))
                            .progressViewStyle(.linear)
                        Text("\(libraryViewModel.extractionProgressCurrent)/\(libraryViewModel.extractionProgressTotal)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Text extraction progress: \(libraryViewModel.extractionProgressCurrent) of \(libraryViewModel.extractionProgressTotal)")
                } else {
                    Text("Re-extract the cached text for all books. Use this after parser updates to refresh the cached content.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Library Maintenance")
            }
        }
        .padding()
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    // The user picked a parent folder — we'll put .TextMouth inside it
                    let target = url.appendingPathComponent(".TextMouth", isDirectory: true)
                    pendingMoveURL = target
                    showMoveConfirmation = true
                }
            case .failure(let error):
                status = .announced(after: .failure("Could not choose a new location", error))
            }
        }
        .alert("Rebuild Directory", isPresented: $showRebuildConfirmation) {
            Button("Rebuild") {
                start(.rebuild)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will recreate the directory structure and migrate any books using old storage. Your books and reading positions will be preserved.")
        }
        .alert("Reset to Default Location?", isPresented: $showResetToDefaultConfirmation) {
            Button("Reset & Move") {
                start(.resetToDefault)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will move all data from \(TextMouthPaths.rootPath) back to the default location at \(TextMouthPaths.defaultRoot.path).")
        }
        .alert("Move Data Directory?", isPresented: $showMoveConfirmation) {
            Button("Move") {
                if let url = pendingMoveURL {
                    pendingMoveURL = nil
                    start(.move(to: url))
                }
            }
            Button("Cancel", role: .cancel) {
                pendingMoveURL = nil
            }
        } message: {
            if let url = pendingMoveURL {
                Text("Copy all TextMouth data to \(url.path), validate it, and use the new location? The current directory will be retained as recovery data.")
            }
        }
        .alert("Redo Text Extraction?", isPresented: $showRedoExtractionConfirmation) {
            Button("Re-extract All") {
                libraryViewModel.redoAllTextExtraction()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will re-extract the cached text for all books in your library. This may take a while for large libraries. Reading positions will be preserved, but character offsets may shift slightly if the extraction produces different text.")
        }
        .sheet(isPresented: $showDuplicateFinder) {
            DuplicateFinderView(libraryViewModel: libraryViewModel)
        }
    }

    /// Whether the library index could not be read and is being recovered.
    private var isRecoveringIndex: Bool {
        libraryViewModel.indexRecovery != nil
    }

    /// Whether the location and rebuild buttons are unavailable right now.
    private var maintenanceUnavailable: Bool {
        Self.maintenanceUnavailable(isRecoveringIndex: isRecoveringIndex, isRunning: runningOperation != nil)
    }

    /// Whether the location and rebuild buttons are unavailable: while the
    /// library index cannot be read, since they would act on the temporary
    /// library, and while one of them runs. Once an operation ends, whether
    /// it worked or failed, they are available again, so a failure can be
    /// retried.
    nonisolated static func maintenanceUnavailable(isRecoveringIndex: Bool, isRunning: Bool) -> Bool {
        isRecoveringIndex || isRunning
    }

    /// The data directory status, as shown and as VoiceOver reads it. An
    /// unreadable library index outranks "Active": the directory exists, but
    /// its library index is not being saved.
    nonisolated static func statusText(isRecoveringIndex: Bool, directoryExists: Bool) -> String {
        if isRecoveringIndex {
            return LibraryIndexRecoveryText.settingsStatus
        }
        return directoryExists ? "Active" : "Not Created"
    }

    // MARK: - Running Operations

    /// Runs `operation`. While it works the status line says so and the
    /// buttons are unavailable; afterwards the status line says what really
    /// happened, "Done" only after a success, VoiceOver announces it once,
    /// and the buttons are available again for a retry (TODO A07).
    private func start(_ operation: StorageOperation) {
        guard runningOperation == nil else { return }
        runningOperation = operation
        status = .running(operation)
        Task { @MainActor in
            // The work runs on the main actor and holds the interface while
            // it does. A short pause first lets the run loop draw the running
            // status and the unavailable buttons before the work begins.
            try? await Task.sleep(for: .milliseconds(50))
            let outcome = perform(operation)
            status = .announced(after: outcome)
            runningOperation = nil
        }
    }

    /// Does the work of `operation` through the library model, which
    /// returns its outcome instead of raising an alert in the Library window.
    private func perform(_ operation: StorageOperation) -> OperationOutcome {
        switch operation {
        case .rebuild:
            return libraryViewModel.rebuildDirectoryReturningOutcome()
        case .resetToDefault:
            return libraryViewModel.rebuildToDefaultReturningOutcome()
        case .move(let destination):
            return libraryViewModel.moveDataDirectoryReturningOutcome(to: destination)
        }
    }
}
