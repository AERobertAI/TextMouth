import SwiftUI

/// What each reader sheet shows. A stub for now, naming the sheet, which the
/// panels' slice replaces with the sheets themselves. It takes the reader as a
/// plain value, never observed, so the sheet does not redraw as the book plays.
struct PhoneReaderSheetContent: View {
    /// The sheet to show.
    let sheet: PhoneReaderSheet
    /// The reader the sheet is over.
    let reader: ReaderViewModel

    var body: some View {
        NavigationStack {
            Text(name)
                .navigationTitle(name)
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// The sheet's name, as the spec names each.
    private var name: String {
        switch sheet {
        case .bookmarks: return "Bookmarks"
        case .headings: return "Headings"
        case .goTo: return "Go To"
        case .sleepTimer: return "Sleep Timer"
        case .voice: return "Voice & Speed"
        case .bookInfo: return "Book Info"
        case .navigationUnit: return "Navigation unit"
        }
    }
}
