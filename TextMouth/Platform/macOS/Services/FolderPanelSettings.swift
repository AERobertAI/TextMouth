import AppKit

/// The settings of a panel that chooses folders, as plain values.
///
/// In a sandboxed app, building an `NSOpenPanel` starts the system's
/// open-and-save panel service in a process of its own, which can take the
/// keyboard focus from the person at the keyboard. So each folder chooser's
/// settings are decided here, as a value that costs nothing to make and that
/// a test can read, and the panel itself is built only where it is presented,
/// by `makePanel()`.
struct FolderPanelSettings: Equatable {
    /// Whether a folder can be chosen.
    var canChooseDirectories = true
    /// Whether a file can be chosen.
    var canChooseFiles = false
    /// Whether more than one item can be chosen at once.
    var allowsMultipleSelection = false
    /// Whether the panel offers a button that makes a new folder.
    var canCreateDirectories = false
    /// Whether hidden files and folders are shown.
    var showsHiddenFiles = false
    /// Whether a package, such as a book package, opens as a folder.
    var treatsFilePackagesAsDirectories = false
    /// The panel's title.
    var title: String
    /// The sentence at the top of the panel, which says what to choose.
    var message: String
    /// The title of the panel's default button, which names the action.
    var prompt: String
    /// The folder the panel starts in, or nil to leave it to the system.
    var directoryURL: URL?

    /// Sets every field on `panel`. The one place the settings become a
    /// panel's, so a recording fake in a test sees exactly what a real panel
    /// would. A nil `directoryURL` leaves the panel's own starting folder.
    @MainActor
    func apply<Panel: FolderPanelConfigurable>(to panel: Panel) {
        panel.canChooseDirectories = canChooseDirectories
        panel.canChooseFiles = canChooseFiles
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canCreateDirectories = canCreateDirectories
        panel.showsHiddenFiles = showsHiddenFiles
        panel.treatsFilePackagesAsDirectories = treatsFilePackagesAsDirectories
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        if let directoryURL {
            panel.directoryURL = directoryURL
        }
    }

    /// A real open panel set up with these settings. Call it only where the
    /// panel is about to be presented, never in a test.
    @MainActor
    func makePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        apply(to: panel)
        return panel
    }
}

/// The part of `NSOpenPanel` that `FolderPanelSettings` sets, as a protocol,
/// so a test can apply settings to a fake and so never build a real panel.
/// The `String!` types are those AppKit gives `title`, `message`, and
/// `prompt`, which are null-resettable. It is main-actor, as `NSOpenPanel` is.
@MainActor
protocol FolderPanelConfigurable: AnyObject {
    var canChooseDirectories: Bool { get set }
    var canChooseFiles: Bool { get set }
    var allowsMultipleSelection: Bool { get set }
    var canCreateDirectories: Bool { get set }
    var showsHiddenFiles: Bool { get set }
    var treatsFilePackagesAsDirectories: Bool { get set }
    var title: String! { get set }
    var message: String! { get set }
    var prompt: String! { get set }
    var directoryURL: URL? { get set }
}

extension NSOpenPanel: FolderPanelConfigurable {}
