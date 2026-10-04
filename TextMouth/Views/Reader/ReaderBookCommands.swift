import SwiftUI

/// What a reader window does for the commands that act on its book as a
/// whole (FR05): File > Export… exports the book of the reader that takes
/// the command, and, when Playback settings say so, an Export button in the
/// toolbar does the same. The Export dialog opens as a sheet on the reader.
///
/// ReaderView attaches this in one line: its body sits at the type
/// checker's limit (board #829), so everything here lives in views of its
/// own. The reader itself is not observed, so a playing reader's frequent
/// publishes never draw this again; only the settings it shows are.
struct ReaderBookCommandsSupport: ViewModifier {
    /// The reader whose book the commands act on.
    let viewModel: ReaderViewModel
    /// The settings, observed for the toolbar's Export button.
    @ObservedObject private var settings: SettingsViewModel
    /// The Export dialog showing, or nil.
    @State private var exportModel: BookExportModel?

    init(viewModel: ReaderViewModel) {
        self.viewModel = viewModel
        _settings = ObservedObject(wrappedValue: viewModel.settingsViewModel)
    }

    func body(content: Content) -> some View {
        content
            .toolbar {
                if settings.showExportInReaderToolbar {
                    ToolbarItem {
                        ReaderExportToolbarButton(action: openExport)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportBooks)) { notification in
                guard takesCommand(notification) else { return }
                openExport()
            }
            .sheet(item: $exportModel) { model in
                BookExportSheet(model: model, close: { exportModel = nil })
            }
    }

    /// Opens the Export dialog for the reader's book, as the library holds
    /// it now, unless it is open already.
    private func openExport() {
        guard exportModel == nil else { return }
        let library = viewModel.libraryViewModel
        let book = library.bookByID(viewModel.book.id) ?? viewModel.book
        exportModel = BookExportModel(books: [book], library: library)
    }

    /// Whether this reader takes the menu command `notification` carries:
    /// the reader whose window, or a sheet over it, is key, as for every
    /// reader command (`WindowCommandRouting`).
    private func takesCommand(_ notification: Notification) -> Bool {
        WindowCommandRouting.shouldAccept(
            sourceWindow: notification.userInfo?["sourceWindow"] as? NSWindow,
            hostWindow: viewModel.hostWindow,
            keyWindow: NSApp.keyWindow
        )
    }
}

/// The reader toolbar's Export button, shown while Playback settings' "Show
/// Export in the reader toolbar" is on: a labelled button with a hint.
struct ReaderExportToolbarButton: View {
    /// Opens the Export dialog.
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(BookExportWording.toolbarTitle, systemImage: "square.and.arrow.up")
        }
        .accessibilityLabel(BookExportWording.toolbarLabel)
        .accessibilityHint(BookExportWording.toolbarHint)
    }
}
