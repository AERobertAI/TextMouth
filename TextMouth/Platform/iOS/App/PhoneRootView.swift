import SwiftUI

/// The root of the iPhone app's window: the one navigation stack, bound to the
/// model's path, and what is presented over every screen, each slice's in a
/// modifier of its own file, so that this view is edited again only for its
/// first screen.
///
/// Slice 1's first screen is thin on purpose: a list of the library's books by
/// title. The Library's slice replaces `bookList` with `PhoneLibraryView`.
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
            bookList
                .navigationTitle(PhoneAppWording.libraryTitle)
                .navigationDestination(for: PhoneRoute.self) { route in
                    switch route {
                    case .reader:
                        PhoneReaderView(session: session)
                    case .folder, .settings:
                        // Nothing pushes these yet: the Library's slice and
                        // the Settings slice build them.
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

    /// Every book in the library by title, each a button that opens its reader
    /// and pushes the reader's screen. A row names the book, as VoiceOver reads
    /// a button by its title.
    private var bookList: some View {
        let books = library.displayedBooks(at: LibraryLocation(category: .allItems, folderPath: ""))
        return List {
            if books.isEmpty {
                Text(PhoneAppWording.emptyLibrary)
            }
            ForEach(books) { book in
                Button(book.title) {
                    guard session.open(book) != nil else { return }
                    model.showReader()
                }
            }
        }
    }
}
