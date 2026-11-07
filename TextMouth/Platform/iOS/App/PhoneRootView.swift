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
    /// The library the list shows, and whose errors the alert says.
    @ObservedObject private var library: LibraryViewModel
    /// The owner of the readers. Only its own published values change, so this
    /// view never hears a reader's place move.
    @ObservedObject private var session: PhoneSession

    /// A root view over `model`.
    init(model: PhoneAppModel) {
        self.model = model
        library = model.library
        session = model.session
    }

    var body: some View {
        NavigationStack(path: $model.path) {
            PhoneLibraryView(model: model, location: Self.libraryTop, navigation: libraryNavigation)
                .navigationDestination(for: PhoneRoute.self) { route in
                    switch route {
                    case .reader:
                        PhoneReaderView(session: session)
                    case .folder(let path):
                        PhoneLibraryView(
                            model: model,
                            location: LibraryLocation(category: .folders, folderPath: path),
                            navigation: libraryNavigation
                        )
                    case .settings:
                        // The Settings slice's screen takes this place.
                        EmptyView()
                    }
                }
        }
        // The Mac's alert for what the library reports, in ContentView.
        .alert(library.errorTitle ?? PhoneAppWording.errorTitle, isPresented: $library.showError) {
            Button(PhoneAppWording.errorDismiss, role: .cancel) {}
        } message: {
            Text(library.errorMessage ?? PhoneAppWording.unknownError)
        }
        .phoneImportPresentations(model)
        .phoneReopening(model)
        .task {
            model.startAfterFirstWindow()
        }
    }

    /// Where the app opens: the top of the Folders view.
    private static let libraryTop = LibraryLocation(category: .folders, folderPath: "")

    /// What every Library screen asks of the slices around it. Add to Library
    /// is the import slice's sheet, which reaches this branch with it.
    private var libraryNavigation: PhoneLibraryNavigation {
        PhoneLibraryNavigation(addToLibrary: {})
    }
}
