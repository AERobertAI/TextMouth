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
    let hostWindow: PlatformWindow?

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

/// Where File > Export… goes (FR05): to the Library window or the book's
/// window in front, or a sheet over one, as every menu command routed to the
/// key window goes (`WindowCommandRouting`). That window exports its
/// selection or its book. With none in front, as when only Settings is,
/// VoiceOver hears why instead of nothing happening.
@MainActor
enum ExportCommandRouting {
    /// File > Export…, as the menu asks for it: from the key window, among
    /// the Library and reader windows open.
    static func exportFromWindowInFront() {
        let router = LibraryWindowRouter.shared
        perform(
            keyWindow: PlatformApplication.keyWindow,
            libraryWindows: openWindows(router.registeredLibraryWindows),
            readerWindows: openWindows(router.registeredReaderWindows),
            post: { NotificationCenter.default.post(name: .exportBooks, object: nil) }
        )
    }

    /// Posts the export command with `post` when a window in front takes it,
    /// and otherwise announces why nothing can be exported
    /// (`refusal(keyWindow:libraryWindows:readerWindows:)`).
    static func perform(
        keyWindow: PlatformWindow?,
        libraryWindows: [PlatformWindow],
        readerWindows: [PlatformWindow],
        post: () -> Void
    ) {
        if let refusal = refusal(keyWindow: keyWindow, libraryWindows: libraryWindows, readerWindows: readerWindows) {
            VoiceOverAnnouncer.announce(refusal)
            return
        }
        post()
    }

    /// What VoiceOver hears instead of an export, or nil when the key window,
    /// or the window a sheet in front belongs to, is one of the open Library
    /// windows or reader windows given: that none is open
    /// (`BookExportWording.noWindowOpen`), or, when one is open behind, to
    /// switch to it (`BookExportWording.noWindowInFront`).
    static func refusal(keyWindow: PlatformWindow?, libraryWindows: [PlatformWindow], readerWindows: [PlatformWindow]) -> String? {
        let windows = libraryWindows + readerWindows
        if let keyWindow {
            let front = WindowCommandRouting.rootWindow(for: keyWindow)
            if windows.contains(where: { $0 === front }) {
                return nil
            }
        }
        return windows.isEmpty ? BookExportWording.noWindowOpen : BookExportWording.noWindowInFront
    }

    /// The windows of `windows` still open, on screen or in the Dock: a
    /// window closed but kept by SwiftUI counts as none.
    static func openWindows(_ windows: [PlatformWindow]) -> [PlatformWindow] {
        #if os(macOS)
        windows.filter { $0.isVisible || $0.isMiniaturized }
        #else
        // Phase 0 iOS body: a UIKit window has no Dock; open means not hidden.
        windows.filter { !$0.isHidden }
        #endif
    }
}
