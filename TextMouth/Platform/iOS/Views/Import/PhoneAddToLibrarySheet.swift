import SwiftUI
import UniformTypeIdentifiers

/// The iPhone's Add to Library sheet (the spec's "Adding a book"), rebuilt
/// for the phone over the Mac's words: its title, a Cancel button, then
/// "Open Book…", "Import Folder…", and "Add Feed…", each with the Mac's summary
/// as its hint, and last a note naming what only the Mac has for now (FR53).
/// Focus lands on Open Book.
///
/// Add Feed… closes the sheet and then opens the Add Feed sheet, as the Mac's
/// does, since a sheet the choice opens would be refused while this one is
/// still closing (`PhoneFeedsHub.requestAddFeed(parentPath:)`).
///
/// One `fileImporter` serves both rows, set by which row was chosen: books,
/// several at once, or one folder. Two on one view are reported not to work.
/// The system's picker is VoiceOver-accessible by Apple's own design. Once
/// files are picked, the sheet closes first, and only then does the copier
/// say "Importing Dune" and copy them (`PhoneImportCopier.addPicked`).
struct PhoneAddToLibrarySheet: View {
    /// What the one picker is set for.
    private enum PickerMode {
        /// Open Book…: books in any format TextMouth reads, several at once.
        case books
        /// Import Folder…: one folder holding a DAISY book or audio tracks.
        case folder

        /// The types the picker offers. `FileImportService.supportedTypes`
        /// is the Mac's Open Book list; a type the app's Info.plist doesn't
        /// declare drops out of it, which `IOSInfoPlistTests` guards.
        var types: [UTType] {
            switch self {
            case .books: return FileImportService.supportedTypes
            case .folder: return [.folder]
            }
        }

        /// Whether several items may be picked at once.
        var allowsMultipleSelection: Bool { self == .books }
    }

    /// The library folder the books go in: the one the Library shows.
    let folderPath: String
    /// The copier the picked files go to.
    let copier: PhoneImportCopier

    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss
    /// What the picker is set for, chosen by the row pressed.
    @State private var mode = PickerMode.books
    /// Whether the picker shows.
    @State private var isPickerPresented = false
    /// Whether VoiceOver's focus is on Open Book, where it lands.
    @AccessibilityFocusState private var isOpenBookFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(for: .openBook, mode: .books)
                        .accessibilityFocused($isOpenBookFocused)
                    row(for: .importFolder, mode: .folder)
                    addFeedRow
                } footer: {
                    onlyOnTheMacNote
                }
            }
            .navigationTitle(AddToLibraryWording.sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                PhoneSheetButton(title: AddToLibraryWording.cancel) { dismiss() }
            }
            .fileImporter(
                isPresented: $isPickerPresented,
                allowedContentTypes: mode.types,
                allowsMultipleSelection: mode.allowsMultipleSelection
            ) { result in
                picked(result)
            }
        }
        .task {
            // A moment for the sheet to finish sliding in, then VoiceOver
            // goes to Open Book rather than the sheet's first element.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            isOpenBookFocused = true
        }
    }

    /// The row of `choice`: the Mac's title as its label, and the Mac's
    /// summary, shown under it and given as its hint, so VoiceOver reads it
    /// once. Pressing it shows the picker set for `mode`.
    private func row(for choice: AddToLibraryChoice, mode: PickerMode) -> some View {
        row(for: choice) {
            self.mode = mode
            isPickerPresented = true
        }
    }

    /// Add Feed…: the sheet closes, and the Add Feed sheet opens in its place once it has (FR53).
    private var addFeedRow: some View {
        row(for: .addFeed) {
            PhoneFeedsHub.shared.requestAddFeed(parentPath: folderPath)
            dismiss()
        }
    }

    /// The row of `choice`, which runs `action` when pressed: the Mac's title as its label, and the Mac's summary, shown
    /// under it and given as its hint, so VoiceOver reads it once.
    private func row(for choice: AddToLibraryChoice, action: @escaping () -> Void) -> some View {
        let summary = AddToLibraryWording.summary(choice)
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(choice.title).phonePrimaryText()
                Text(summary)
                    .font(.footnote)
                    .phoneSecondaryText()
            }
        }
        .accessibilityLabel(choice.title)
        .accessibilityHint(summary)
    }

    /// The note under the two rows (FR53): the Mac's sheet also offers New
    /// Recording… and Add Feed…, so this says which features are the Mac's
    /// for now. Plain static text after Import Folder… in VoiceOver's order,
    /// drawn in the phone's full-contrast secondary color, since a footer's
    /// default gray fails the accessibility audit.
    private var onlyOnTheMacNote: some View {
        Text(PhoneImportWording.onlyOnTheMacNote)
            .font(.footnote)
            .phoneSecondaryText()
    }

    /// Takes what the picker returned: the sheet closes, then the files go
    /// to the copier. A failure of the picker itself says nothing more than
    /// the system did, and the sheet stays.
    private func picked(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        dismiss()
        copier.addPicked(urls, toFolder: folderPath)
    }
}
