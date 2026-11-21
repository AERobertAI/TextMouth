import Foundation

/// The files that sit beside a KFX book on disk and belong to it: the folder
/// Kindle's apps keep next to a book (`Book.sdr` beside `Book.kfx`), and the
/// voucher that sits beside a protected book in the Kindle for PC and Mac
/// folders (KFX-FORMAT-NOTES-2026-11-05.md, parts 2 and 3).
///
/// The scan is bounded and stays inside the folder: it follows no symbolic
/// link, visits at most `maximumEntries` names, and goes no deeper than
/// `maximumDepth`. It reads at most the first bytes of a file to say what it
/// is, and a file is read whole only when it is a container.
enum KFXSidecar {

    /// The most names visited in a book's folder.
    static let maximumEntries = 200
    /// The deepest level of the folder scanned (the folder itself is level 0).
    static let maximumDepth = 3
    /// The most containers taken from a folder.
    static let maximumContainers = 16

    /// What a book's neighbours hold.
    struct Scan {
        /// A voucher is present, or a file starts with the protected mark.
        var isProtected = false
        /// The containers found in the folder, in name order.
        var containers: [URL] = []
    }

    /// Looks at the places that belong to the book at `book`: its `.sdr`
    /// folder, and the files beside it that share its name.
    static func scan(near book: URL) -> Scan {
        var scan = Scan()
        let manager = FileManager.default
        let parent = book.deletingLastPathComponent()
        let base = book.deletingPathExtension().lastPathComponent

        // A voucher with the book's own name beside it, as the Kindle for PC
        // and Mac folders keep one (Book.voucher beside Book.azw).
        if exists(parent.appendingPathComponent(base + ".voucher"), manager) { scan.isProtected = true }

        // The .sdr folder: Book.kfx and Book.sdr.
        let folder = parent.appendingPathComponent(base + ".sdr", isDirectory: true)
        guard isPlainDirectory(folder, manager) else { return scan }

        var visited = 0
        // Breadth first, so the files nearest the book come first.
        var queue: [(url: URL, depth: Int)] = [(folder, 0)]
        while !queue.isEmpty {
            let (directory, depth) = queue.removeFirst()
            let names = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? []).sortedStably()
            for name in names {
                visited += 1
                guard visited <= maximumEntries else { return scan }
                let item = directory.appendingPathComponent(name)
                // A link named like a voucher still says the book is protected;
                // nothing else about a link is followed out of the folder.
                if KFXSignature.isVoucherName(name) { scan.isProtected = true; continue }
                guard !isSymbolicLink(item) else { continue }
                if isPlainDirectory(item, manager) {
                    if depth < maximumDepth { queue.append((item, depth + 1)) }
                    continue
                }
                switch (try? KFXSignature.kind(ofFileAt: item)) ?? .other {
                case .protected: scan.isProtected = true
                case .container:
                    if scan.containers.count < maximumContainers, item.resolvingSymlinksInPath() != book.resolvingSymlinksInPath() {
                        scan.containers.append(item)
                    }
                case .zip, .other: break
                }
            }
        }
        return scan
    }

    // MARK: Files

    /// Whether `url` is a symbolic link (read without following it).
    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
    }

    /// Whether something that is not a link exists at `url`.
    private static func exists(_ url: URL, _ manager: FileManager) -> Bool {
        !isSymbolicLink(url) && manager.fileExists(atPath: url.path)
    }

    /// Whether `url` is a folder and not a link to one.
    private static func isPlainDirectory(_ url: URL, _ manager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return !isSymbolicLink(url) && manager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
