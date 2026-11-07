import Foundation

/// A screen pushed on the iPhone app's one navigation stack, whose root is the
/// Library. Slice 1 has the reader alone; folders and Settings join it.
enum PhoneRoute: Hashable, Sendable {
    /// The open book's reader. It names no book: `PhoneSession` holds the one
    /// reader, so going on to the next book changes what this screen shows,
    /// with nothing pushed.
    case reader

    /// `path` with the reader's screen on top: pushed when it is not there,
    /// and otherwise everything above it taken away. The stack never holds it
    /// twice, or Back would land on the same screen.
    static func showingReader(on path: [PhoneRoute]) -> [PhoneRoute] {
        guard let index = path.firstIndex(of: .reader) else { return path + [.reader] }
        return Array(path[...index])
    }
}
