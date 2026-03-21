import SwiftUI

struct StorageSettingsView: View {
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    @State private var showRebuildConfirmation = false
    @State private var showResetToDefaultConfirmation = false
    @State private var showMoveConfirmation = false
    @State private var pendingMoveURL: URL?
    @State private var showFolderPicker = false
    @State private var statusMessage: String?
    @State private var importDeleteBehavior: ImportDeleteBehavior
    @State private var confirmBeforeDelete: Bool

    init() {
        _importDeleteBehavior = State(initialValue: ConfigService.shared.config.importDeleteBehavior)
        _confirmBeforeDelete = State(initialValue: ConfigService.shared.config.confirmBeforeDelete)
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
                    Text(TextMouthPaths.directoryExists ? "Active" : "Not Created")
                        .foregroundColor(TextMouthPaths.directoryExists ? .green : .red)
                }

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

                Button("Rebuild Directory") {
                    showRebuildConfirmation = true
                }
                .accessibilityLabel("Rebuild TextMouth directory")
                .accessibilityHint("Recreates the directory structure and migrates any books using old storage")

                if let status = statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                statusMessage = "Error: \(error.localizedDescription)"
            }
        }
        .alert("Rebuild Directory", isPresented: $showRebuildConfirmation) {
            Button("Rebuild") {
                performRebuild()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will recreate the directory structure and migrate any books using old storage. Your books and reading positions will be preserved.")
        }
        .alert("Reset to Default Location?", isPresented: $showResetToDefaultConfirmation) {
            Button("Reset & Move") {
                performResetToDefault()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will move all data from \(TextMouthPaths.rootPath) back to the default location at \(TextMouthPaths.defaultRoot.path).")
        }
        .alert("Move Data Directory?", isPresented: $showMoveConfirmation) {
            Button("Move") {
                if let url = pendingMoveURL {
                    performMove(to: url)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingMoveURL = nil
            }
        } message: {
            if let url = pendingMoveURL {
                Text("Move all TextMouth data to \(url.path)? The app will use this location going forward.")
            }
        }
    }

    private func performRebuild() {
        statusMessage = "Rebuilding..."
        libraryViewModel.rebuildDirectory()
        let bookCount = libraryViewModel.library.books.count
        statusMessage = "Done. \(bookCount) book\(bookCount == 1 ? "" : "s") in library."
    }

    private func performResetToDefault() {
        statusMessage = "Moving to default location..."
        libraryViewModel.rebuildToDefault()
        statusMessage = "Done. Data is now at \(TextMouthPaths.rootPath)"
    }

    private func performMove(to url: URL) {
        statusMessage = "Moving data..."
        libraryViewModel.moveDataDirectory(to: url)
        pendingMoveURL = nil
        statusMessage = "Done. Data is now at \(TextMouthPaths.rootPath)"
    }
}
