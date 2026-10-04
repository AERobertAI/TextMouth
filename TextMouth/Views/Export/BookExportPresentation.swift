import SwiftUI

/// What a Library window does for Export (FR05): File > Export… exports the
/// books selected in the window that takes the command, and the Export
/// dialog opens as a sheet on that window. The rows' context menus open the
/// same dialog through `exportModel`.
///
/// A modifier of its own, so the Library window's body, near the type
/// checker's limit, grows by one line.
struct LibraryExportSupport: ViewModifier {
    /// The dialog showing, or nil.
    @Binding var exportModel: BookExportModel?
    /// The library, whose rows the export reads as they are when Export is
    /// pressed.
    let library: LibraryViewModel
    /// Whether this window takes a menu command, as `WindowCommandRouting`
    /// decides for every Library window command.
    let takesCommand: (Notification) -> Bool
    /// The books selected in the window, in list order.
    let selectedBooks: () -> [Book]
    /// The window, which VoiceOver hears a refusal from.
    let hostWindow: NSWindow?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .exportBooks)) { notification in
                guard takesCommand(notification), exportModel == nil else { return }
                let books = selectedBooks()
                guard !books.isEmpty else {
                    VoiceOverAnnouncer.announce(LibraryCloudWording.noBooksSelected, from: hostWindow)
                    return
                }
                exportModel = BookExportModel(books: books, library: library)
            }
            .sheet(item: $exportModel) { model in
                BookExportSheet(model: model, close: { exportModel = nil })
            }
    }
}
