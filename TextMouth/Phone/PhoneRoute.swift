import Foundation

/// A screen pushed on the iPhone app's one navigation stack, whose root is the
/// Library. `PhoneAppModel.path` holds them, and `NavigationStack(path:)` binds
/// to it, so imports, the Continue row, and reopening all push the reader the
/// same way.
enum PhoneRoute: Hashable, Sendable {
    /// A folder of the Library, by its path.
    case folder(path: String)
    /// The open book's reader. It names no book on purpose: `PhoneSession`
    /// holds the reader, so going on to the next book changes what this screen
    /// shows with nothing pushed or rebuilt, and VoiceOver's focus stays.
    case reader
    /// Settings, pushed from the Library's root.
    case settings

    /// `path` with the reader's screen on top: pushed when it is not there,
    /// and otherwise everything above it taken away. The stack never holds it
    /// twice, or Back would land on the same screen.
    static func showingReader(on path: [PhoneRoute]) -> [PhoneRoute] {
        guard let index = path.firstIndex(of: .reader) else { return path + [.reader] }
        return Array(path[...index])
    }

    /// Whether `path` shows the reader's screen, on top or under another.
    static func showsReader(_ path: [PhoneRoute]) -> Bool {
        path.contains(.reader)
    }
}
