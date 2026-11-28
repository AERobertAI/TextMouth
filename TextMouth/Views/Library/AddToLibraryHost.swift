import SwiftUI

// MARK: - The Runner

/// Runs an Add to Library choice (FR20) the way its menu item runs: it posts
/// the notification the menu posts, or shows the Record window, and does
/// nothing more. It is a pair of closures so a test can watch what it would do
/// without a file panel, a sheet, or the Record window opening in the app the
/// tests run inside.
struct AddToLibraryRunner {
    /// Posts a notification with this `userInfo`, nil for none.
    let post: (Notification.Name, [AnyHashable: Any]?) -> Void
    /// Shows the Record window, as File > New Recording… does.
    let showRecordingWindow: () -> Void

    /// The runner the app uses: notifications go out on the default center,
    /// and the Record window comes from `showRecordingWindow`, which knows
    /// the library recordings are saved into.
    static func live(showRecordingWindow: @escaping () -> Void) -> AddToLibraryRunner {
        AddToLibraryRunner(
            post: { name, userInfo in
                NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
            },
            showRecordingWindow: showRecordingWindow
        )
    }

    /// Runs `choice`. `sourceWindow`, the Library window the sheet was in,
    /// goes with Add Feed alone, which names its window as the old toolbar
    /// button did, so the sheet it opens is that window's; the other
    /// choices are posted exactly as the menus post them, with none.
    func run(_ choice: AddToLibraryChoice, sourceWindow: PlatformWindow?) {
        switch choice.run {
        case .notification(let name):
            var userInfo: [AnyHashable: Any]?
            if choice == .addFeed, let sourceWindow {
                userInfo = ["sourceWindow": sourceWindow]
            }
            post(name, userInfo)
        case .recordingWindow:
            showRecordingWindow()
        }
    }
}

// MARK: - What a Window Owns

/// What one Library window owns of its Add to Library button (FR20): the
/// model of the sheet, and what its choices need to know about the window
/// (the window itself, and the library recordings are saved into), which
/// the window tells it once it has them, since the host is made before
/// either exists.
@MainActor
final class AddToLibraryHost: ObservableObject {
    /// The sheet's model: `isPresented` shows the sheet, and a choice runs
    /// after the sheet has gone.
    let model: AddToLibraryModel

    /// The shortcuts the choices follow: which of their menu commands work
    /// in a Library window, and the keys in force. This one follows the
    /// preferences store as the app's own does, but takes no key presses.
    let shortcuts: KeyboardShortcutManager

    /// A host whose choices follow `shortcuts` (the store's, unless a test
    /// passes its own) and run through `runner` (the live one unless a test
    /// passes its own).
    init(
        shortcuts: KeyboardShortcutManager = KeyboardShortcutManager(installsEventMonitor: false),
        runner: AddToLibraryRunner? = nil
    ) {
        self.shortcuts = shortcuts
        // The model's closures reach the window and library through a box
        // made first, since they cannot capture `self` before it is made.
        let context = Context()
        self.context = context
        let runner = runner ?? .live(showRecordingWindow: {
            RecordingWindowController.shared.show(library: context.library)
        })
        model = AddToLibraryModel(
            isEnabled: { $0.isEnabled(under: shortcuts, in: .library) },
            perform: { runner.run($0, sourceWindow: context.window) }
        )
    }

    /// The window the sheet is in and the library it shows, as the model's
    /// closures read them: nil until the window has told the host.
    private final class Context {
        var window: PlatformWindow?
        var library: LibraryViewModel?
    }
    private let context: Context

    /// Tells the host the window it is in and the library it shows.
    func attach(window: PlatformWindow?, library: LibraryViewModel) {
        context.window = window
        context.library = library
    }

    /// Shows the sheet.
    func present() {
        model.isPresented = true
    }

    /// `choice`'s key in words, nil for none: what the sheet shows beside it.
    func keyDescription(_ choice: AddToLibraryChoice) -> String? {
        choice.keyDescription(under: shortcuts)
    }
}

// MARK: - The Window's Sheet

/// A Library window's Add to Library sheet (FR20): it shows the sheet
/// whenever the model says so, and runs the choice made once the sheet has
/// gone (`AddToLibraryModel.sheetDidDismiss`). It also tells the host the
/// window and library its choices need.
struct LibraryAddToLibrarySupport: ViewModifier {
    /// What the window owns of the button.
    let host: AddToLibraryHost
    /// The sheet's model, observed so the sheet follows `isPresented`.
    @ObservedObject var model: AddToLibraryModel
    /// The library the window shows.
    let library: LibraryViewModel
    /// The window the sheet is in, nil until it is found.
    let hostWindow: PlatformWindow?

    func body(content: Content) -> some View {
        content
            // The window is found after the first draw, so the host is told
            // again when it is.
            .onAppear { host.attach(window: hostWindow, library: library) }
            .onChange(of: hostWindow) { _, window in host.attach(window: window, library: library) }
            .sheet(isPresented: $model.isPresented, onDismiss: model.sheetDidDismiss) {
                AddToLibrarySheet(model: model, keyDescription: host.keyDescription)
            }
    }
}
