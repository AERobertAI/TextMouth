import SwiftUI

/// The root of the iPhone app's window: the one navigation stack, bound to the
/// model's path, and what is presented over every screen, each slice's in a
/// modifier of its own file, so that this view is edited again only for its
/// first screen.
///
/// Its first screen is the Library at the top of the Folders view
/// (`PhoneLibraryView`), and a folder pushed on the path is the same view at
/// that folder.
struct PhoneRootView: View {
    /// The app's one model, whose path the stack binds to.
    @ObservedObject private var model: PhoneAppModel
    /// The owner of the readers. Only its own published values change, so this
    /// view never hears a reader's place move.
    @ObservedObject private var session: PhoneSession

    /// A root view over `model`. It doesn't observe the library, which
    /// publishes at every checkpoint of a playing book: only the alert's own
    /// modifier does (the slices' rule, from the engineering review's F11).
    init(model: PhoneAppModel) {
        self.model = model
        session = model.session
    }

    var body: some View {
        NavigationStack(path: $model.path) {
            PhoneLibraryView(model: model, location: Self.libraryTop)
                .navigationDestination(for: PhoneRoute.self) { route in
                    switch route {
                    case .reader:
                        PhoneReaderView(session: session)
                    case .folder(let path):
                        PhoneLibraryView(model: model, location: LibraryLocation(category: .folders, folderPath: path))
                    case .settings:
                        // Slice 9's screen. Its voice preview doesn't yet pause
                        // a playing book: the session's closure for that is a
                        // follow-up, and with none the preview just speaks.
                        PhoneSettingsView(settings: model.settings)
                    }
                }
        }
        .modifier(PhoneLibraryErrorAlert(library: model.library))
        .phoneImportPresentations(model)
        .phoneReopening(model)
        .task {
            model.startAfterFirstWindow()
        }
    }

    /// Where the app opens: the top of the Folders view.
    private static let libraryTop = LibraryLocation(category: .folders, folderPath: "")
}

/// The Mac's alert for what the library reports, as ContentView shows it. The
/// one part of the root that observes the library, so that a change of the
/// library redraws the alert alone, never the navigation stack under it.
private struct PhoneLibraryErrorAlert: ViewModifier {
    /// The library whose errors the alert says.
    @ObservedObject var library: LibraryViewModel

    func body(content: Content) -> some View {
        content
            .alert(library.errorTitle ?? PhoneAppWording.errorTitle, isPresented: $library.showError) {
                Button(PhoneAppWording.errorDismiss, role: .cancel) {}
            } message: {
                Text(library.errorMessage ?? PhoneAppWording.unknownError)
            }
    }
}
