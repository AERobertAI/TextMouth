import SwiftUI

/// The root of the iPhone app's window: the one navigation stack, and what is
/// presented over every screen.
///
/// Slice 1's first screen is thin on purpose: a list of the library's books by
/// title. Slice 2 replaces `bookList` with `PhoneLibraryView`.
struct PhoneRootView: View {
    /// The app's one model.
    let model: PhoneAppModel
    /// The library the list shows, and whose errors the alert says.
    @ObservedObject private var library: LibraryViewModel
    /// The owner of the reader. Only its own `reader` and `snapshot` publish,
    /// so this view never hears the reader's place move.
    @ObservedObject private var session: PhoneSession
    /// The screens pushed over the Library.
    @State private var path: [PhoneRoute] = []

    /// A root view over `model`.
    init(model: PhoneAppModel) {
        self.model = model
        library = model.library
        session = model.session
    }

    var body: some View {
        NavigationStack(path: $path) {
            bookList
                .navigationTitle(PhoneAppWording.libraryTitle)
                .navigationDestination(for: PhoneRoute.self) { route in
                    switch route {
                    case .reader:
                        PhoneReaderView(session: session)
                    }
                }
        }
        // The Mac's alert for what the library reports, in ContentView.
        .alert(library.errorTitle ?? PhoneAppWording.errorTitle, isPresented: $library.showError) {
            Button(PhoneAppWording.errorDismiss, role: .cancel) {}
        } message: {
            Text(library.errorMessage ?? PhoneAppWording.unknownError)
        }
        // A book opened by something other than its row, such as an import.
        .onReceive(session.showReaderRequests) { _ in
            path = PhoneRoute.showingReader(on: path)
        }
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
                    session.open(book)
                    path = PhoneRoute.showingReader(on: path)
                }
            }
        }
    }
}
