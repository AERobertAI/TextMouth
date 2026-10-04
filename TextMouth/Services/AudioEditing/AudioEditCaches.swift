import Foundation
import os

/// What audio editing keeps in this Mac's caches (FR04), and the sweep that
/// removes what a crash left there.
///
/// Two kinds of folder live there: each book's scratch folder ("Audio
/// Edits", `AudioEditScratch`), which a save or the closing of its editor
/// removes, and each editor window's folder of audio copied or cut ("Audio
/// Editor Clips", `newClipFolder()`), which its window removes as it
/// closes. A crash leaves both behind, as quitting with an editor open
/// does. The library removes them at launch, off the main thread
/// (`removeStale`), and never a folder in use: a book's while an edit
/// session or a save uses the book (`AudioEditActivity`), since its scratch
/// folder is made only after the use begins and under the lock the sweep
/// takes to look (`AudioEditScratch.setAside`); and a window's while the
/// window is open, as each is noted from the moment its folder is named.
enum AudioEditCaches {
    /// What one sweep did.
    struct Result: Equatable, Sendable {
        /// How many folders it removed.
        var removed = 0
        /// How many it kept, as in use.
        var kept = 0
    }

    // MARK: Clip Folders

    /// The folder of all editor windows' clip folders.
    static var clipsRoot: URL {
        MachineLocalPaths.caches.appendingPathComponent("Audio Editor Clips", isDirectory: true)
    }

    /// The names of the clip folders of the editor windows open now: each
    /// noted as its window's model is made, before the folder exists, and
    /// let go as the window closes.
    private static let clipFoldersInUse = OSAllocatedUnfairLock(initialState: Set<String>())

    /// A new folder for one editor window's clips, made when its first clip
    /// is kept, and noted as in use until `endClipFolder(_:)`.
    static func newClipFolder() -> URL {
        let folder = clipsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        clipFoldersInUse.withLock { _ = $0.insert(folder.lastPathComponent) }
        return folder
    }

    /// Removes an editor window's clip folder as the window closes, and
    /// notes it in use no more.
    static func endClipFolder(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
        clipFoldersInUse.withLock { _ = $0.remove(folder.lastPathComponent) }
    }

    /// Whether the clip folder named `name` is an open editor window's.
    static func isClipFolderInUse(_ name: String) -> Bool {
        clipFoldersInUse.withLock { $0.contains(name) }
    }

    // MARK: The Sweep

    /// What a folder set aside to be removed is named after: one a sweep cut
    /// short left behind is removed by the next.
    static let setAsidePrefix = ".removing-"

    /// Removes the folders a crash left: each book's scratch folder in
    /// `scratchRoot` whose book `isBookInUse` says nothing uses, each folder
    /// a sweep cut short set aside there, and each clip folder in
    /// `clipsRoot` that `isClipFolderInUse` says no open window has. A
    /// book's folder is first set aside under the lock its folder is made
    /// under, so an edit session beginning now makes a new one; anything
    /// else there is left alone. Reads and removes files: call it off the
    /// main thread.
    static func removeStale(
        scratchRoot: URL = AudioEditScratch.root,
        clipsRoot: URL = AudioEditCaches.clipsRoot,
        isBookInUse: (UUID) -> Bool,
        isClipFolderInUse: (String) -> Bool = AudioEditCaches.isClipFolderInUse
    ) -> Result {
        var result = Result()
        for folder in subfolders(of: scratchRoot) {
            let name = folder.lastPathComponent
            if name.hasPrefix(setAsidePrefix) {
                remove(folder, counting: &result)
            } else if let bookID = UUID(uuidString: name) {
                if let aside = AudioEditScratch.setAside(folder, unless: { isBookInUse(bookID) }) {
                    remove(aside, counting: &result)
                } else {
                    result.kept += 1
                }
            }
        }
        for folder in subfolders(of: clipsRoot) {
            if isClipFolderInUse(folder.lastPathComponent) {
                result.kept += 1
            } else {
                remove(folder, counting: &result)
            }
        }
        return result
    }

    /// The folders directly inside `root`; none when it is missing.
    private static func subfolders(of root: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        return children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    /// Removes `folder`, counting it in `result` once it is gone.
    private static func remove(_ folder: URL, counting result: inout Result) {
        if (try? FileManager.default.removeItem(at: folder)) != nil {
            result.removed += 1
        }
    }
}
