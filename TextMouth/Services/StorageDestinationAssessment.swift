import Foundation

// MARK: - A Folder Chosen for the Library (FR02)

/// What a folder chosen for the library in Storage settings can become,
/// judged from file-system metadata alone, off the main thread, without
/// downloading anything (FR02).
///
/// Any folder can hold the library: hidden or not, on the startup disk, an
/// external or network drive, or in a cloud folder. The chosen folder itself
/// is the data directory; nothing is added to its path.
///
/// - A folder that is missing or empty can receive a copy of the library:
///   Move Library Here.
/// - A folder holding a TextMouth library, its identity marker
///   (`LibraryIdentity`) or a library.json beside a Library folder, can be
///   used as it is, which is how another Mac restores a library from the
///   cloud: Use This Library.
/// - The folder the library is in now is said to be just that.
/// - Anything else is refused, saying why.
///
/// While the library isn't available (the Library Not Available screen),
/// nothing can be moved, since there is nothing to copy: a folder holding a
/// library can still be used, and the default location, ~/.TextMouth, can
/// start a new library when it holds none. Nothing is ever created at the
/// location that is missing.
struct StorageDestinationAssessment: Equatable, Sendable {
    /// What can be done with the chosen folder.
    enum Verdict: Equatable, Sendable {
        /// The folder is missing or empty: the library can be copied there.
        case moveHere
        /// The folder holds a TextMouth library, which TextMouth can use as
        /// it is.
        case useLibrary(FoundLibrary)
        /// The library isn't available, and the chosen folder is the default
        /// location, which holds no library: TextMouth can start a new one
        /// there, as on a first launch.
        case startNewLibrary
        /// The folder is the one the library TextMouth is using is in.
        case currentLibrary
        /// Nothing can be done with the folder, for this reason.
        case refused(Refusal)
    }

    /// A TextMouth library found in a chosen folder.
    struct FoundLibrary: Equatable, Sendable {
        /// The library's identity, when its marker could be read without
        /// downloading it; nil for a library from before identities, or one
        /// whose marker is only in the cloud.
        let identity: LibraryIdentity?
        /// Whether it is another copy of the library TextMouth is using, by
        /// identity, such as the folder an earlier move left behind.
        let isCopyOfCurrentLibrary: Bool
    }

    /// Why nothing can be done with a chosen folder.
    enum Refusal: Equatable, Sendable {
        /// A file, or anything else that is not a folder, is there.
        case notAFolder
        /// The folder holds other things than a library: their names,
        /// hidden ones included, sorted.
        case otherItems([String])
        /// The folder overlaps the data directory in use, so a copy would
        /// land inside itself; the explanation names both folders.
        case overlap(DataDirectoryOverlap, explanation: String)
        /// The folder is in the Trash.
        case inTrash
        /// The folder can't be looked into, for this reason.
        case unreadable(String)
        /// The folder's listing is only in the cloud, so looking inside it
        /// would download it.
        case notDownloaded
        /// The folder is missing, and so is the folder that would hold it.
        case parentMissing
        /// TextMouth isn't allowed to make changes in this folder.
        case notWritable(String)
        /// The folder's volume has too little free space for a copy of the
        /// library: the bytes needed and the bytes free.
        case notEnoughSpace(needed: Int64, available: Int64)
        /// The folder is missing or empty, but the library isn't available,
        /// so there is nothing to move into it.
        case nothingToMove
    }

    /// The folder as chosen.
    let folder: URL
    /// Where the folder lives.
    let location: StorageLocation
    /// What can be done with it.
    let verdict: Verdict
    /// The bytes of the library a move would copy, when known: summed only
    /// for a move.
    let librarySize: Int64?
}

// MARK: - What the Assessment Knows and Asks

extension StorageDestinationAssessment {
    /// What an assessment knows about TextMouth's own library.
    struct Context: Sendable {
        /// The data directory in use, as `TextMouthPaths.root` names it.
        var currentRoot: URL
        /// Whether the library in use is available; false while the Library
        /// Not Available screen shows.
        var libraryIsAvailable: Bool
        /// The identity of the library this Mac expects, if it knows one.
        var currentIdentity: UUID?
        /// The default location, ~/.TextMouth in this process's home.
        var defaultRoot: URL
    }

    /// What an assessment asks the system, so tests can answer for it.
    struct Probes: Sendable {
        /// Where a folder lives (`CloudItemStatusProviding.location(of:)`).
        var itemStatus: any CloudItemStatusProviding
        /// The names in a folder, hidden ones included, as
        /// `FileManager.contentsOfDirectory(atPath:)` lists them.
        var listFolder: @Sendable (URL) throws -> [String]
        /// The bytes free for important use on the volume of the existing
        /// folder at a URL, or nil when unknown.
        var availableCapacity: @Sendable (URL) -> Int64?
        /// Whether two existing folders are on one volume, where a copy
        /// clones its files and needs next to no space.
        var areOnOneVolume: @Sendable (URL, URL) -> Bool

        /// The system's answers, with `itemStatus` saying where folders are.
        static func live(itemStatus: any CloudItemStatusProviding) -> Probes {
            Probes(
                itemStatus: itemStatus,
                listFolder: { try FileManager.default.contentsOfDirectory(atPath: $0.path) },
                availableCapacity: { url in
                    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    return values?.volumeAvailableCapacityForImportantUsage
                },
                areOnOneVolume: { first, second in
                    let key: Set<URLResourceKey> = [.volumeIdentifierKey]
                    guard let one = (try? first.resourceValues(forKeys: key))?.volumeIdentifier as? NSObject,
                          let other = (try? second.resourceValues(forKeys: key))?.volumeIdentifier as? NSObject else {
                        return false
                    }
                    return one.isEqual(other)
                }
            )
        }
    }
}

// MARK: - Assessing

extension StorageDestinationAssessment {
    /// Assesses `folder` for the library of `model`, off the main thread:
    /// the work reads metadata, which can wait on a drive or the network.
    /// - Parameter probes: What the assessment asks the system; the app's
    ///   own unless a test passes its answers.
    @MainActor
    static func assess(
        _ folder: URL,
        for model: LibraryViewModel,
        probes: Probes? = nil
    ) async -> StorageDestinationAssessment {
        let context = Context(
            currentRoot: TextMouthPaths.root,
            libraryIsAvailable: model.dataDirectoryUnavailability == nil,
            currentIdentity: DataDirectoryPreferences.expectedIdentity.read(from: model.dataDirectoryEnvironment.preferences),
            defaultRoot: TextMouthPaths.defaultRoot
        )
        let probes = probes ?? .live(itemStatus: CloudServices.itemStatus)
        return await OffMainWork.run {
            assess(folder, context: context, probes: probes)
        }
    }

    /// Assesses `folder` on this thread, with dataless files left in the
    /// cloud, for a library described by `context`. It reads metadata, the
    /// identity marker's few bytes when they are on this Mac, and, for a
    /// move, the sizes of the library's files; nothing is created, changed,
    /// or downloaded.
    static func assess(_ folder: URL, context: Context, probes: Probes) -> StorageDestinationAssessment {
        DatalessFiles.withoutDownloading {
            let destination = DataDirectoryLocation(folder)
            let source = DataDirectoryLocation(context.currentRoot)
            let location = probes.itemStatus.location(of: destination.named)
            let reading = Reading(destination: destination, source: source, context: context, probes: probes)
            let (verdict, size) = reading.verdict()
            return StorageDestinationAssessment(folder: folder, location: location, verdict: verdict, librarySize: size)
        }
    }

    /// The facts about one chosen folder, read as the verdict needs them.
    private struct Reading {
        let destination: DataDirectoryLocation
        let source: DataDirectoryLocation
        let context: Context
        let probes: Probes

        /// The verdict, with the library's size when the verdict is a move.
        func verdict() -> (Verdict, Int64?) {
            // The folder the library is in now, under any name.
            if context.libraryIsAvailable, destination.real.path == source.real.path {
                return (.currentLibrary, nil)
            }
            if DataDirectoryPaths.isInTrash(destination.real.path) || DataDirectoryPaths.isInTrash(destination.named.path) {
                return (.refused(.inTrash), nil)
            }
            let names: [String]
            switch FolderContents(of: destination.real, listing: probes.listFolder) {
            case .notAFolder:
                return (.refused(.notAFolder), nil)
            case .unreadable(let reason):
                return (.refused(.unreadable(reason)), nil)
            case .onlyInCloud:
                return (.refused(.notDownloaded), nil)
            case .missing:
                names = []
            case .folder(let listed):
                names = listed
            }

            if holdsLibrary(names) {
                guard Self.isWritable(destination.real) else {
                    return (.refused(.notWritable(destination.real.path)), nil)
                }
                let identity = DataDirectoryPreferences.identity(in: destination.real)
                let isCopy = identity != nil && identity?.id == context.currentIdentity
                return (.useLibrary(FoundLibrary(identity: identity, isCopyOfCurrentLibrary: isCopy)), nil)
            }
            guard context.libraryIsAvailable else {
                if isDefaultLocation {
                    return (.startNewLibrary, nil)
                }
                return (.refused(names.isEmpty ? .nothingToMove : .otherItems(names)), nil)
            }
            guard names.isEmpty else {
                return (.refused(.otherItems(names)), nil)
            }
            return moveVerdict()
        }

        /// The verdict for a move into the missing or empty folder: refused
        /// when the copy would land inside the library or hold it, when the
        /// folder can't be made or replaced, or when its volume lacks room.
        private func moveVerdict() -> (Verdict, Int64?) {
            if let overlap = DataDirectoryOverlap(source: source, destination: destination) {
                let explanation = overlap.explanation(source: source, destination: destination)
                return (.refused(.overlap(overlap, explanation: explanation)), nil)
            }
            // The copy is staged and renamed into place in the folder that
            // holds the new location, which must be there and writable.
            let parent = destination.real.deletingLastPathComponent()
            guard Self.isFolder(parent) else {
                return (.refused(.parentMissing), nil)
            }
            guard Self.isWritable(parent) else {
                return (.refused(.notWritable(parent.path)), nil)
            }
            let size = try? DataDirectoryCopyPlan(of: source.real).totalBytes
            if let size, !probes.areOnOneVolume(source.real, parent),
               let available = probes.availableCapacity(parent), available < size {
                return (.refused(.notEnoughSpace(needed: size, available: available)), size)
            }
            return (.moveHere, size)
        }

        /// Whether the folder holding `names` holds a TextMouth library: its
        /// identity marker, or a library index beside a folder of books.
        private func holdsLibrary(_ names: [String]) -> Bool {
            if names.contains(LibraryIdentity.fileName) {
                return true
            }
            guard names.contains("library.json"), names.contains(TextMouthPaths.libraryFolderName) else {
                return false
            }
            return Self.isFolder(destination.real.appendingPathComponent(TextMouthPaths.libraryFolderName, isDirectory: true))
        }

        /// Whether a folder, or a link to one, is at `url`.
        private static func isFolder(_ url: URL) -> Bool {
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
        }

        /// Whether the chosen folder is the default location.
        private var isDefaultLocation: Bool {
            let defaultRoot = DataDirectoryLocation(context.defaultRoot)
            return destination.named.path == defaultRoot.named.path || destination.real.path == defaultRoot.real.path
        }

        /// Whether TextMouth may add, rename, and remove items in the
        /// existing folder at `folder`.
        private static func isWritable(_ folder: URL) -> Bool {
            folder.withUnsafeFileSystemRepresentation { path in
                guard let path else { return false }
                return access(path, W_OK | X_OK) == 0
            }
        }
    }
}

/// What is at a chosen folder's place: one lstat(2), which follows no link
/// there, an access(2) check of a folder found, and its listing.
private enum FolderContents {
    /// Nothing is there.
    case missing
    /// A file, a link, or anything else that is not a folder.
    case notAFolder
    /// A folder that can't be looked into, with why.
    case unreadable(String)
    /// A folder whose listing is only in the cloud.
    case onlyInCloud
    /// A folder, with the names of the items inside it, hidden ones
    /// included, sorted.
    case folder([String])

    /// What is at `url` now, its listing read through `listing`.
    init(of url: URL, listing: (URL) throws -> [String]) {
        var status = stat()
        let examined = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &status)
        }
        guard examined == 0 else {
            let code = errno
            self = code == ENOENT || code == ENOTDIR ? .missing : .unreadable(Self.reason(code))
            return
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            self = .notAFolder
            return
        }
        let readable = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return access(path, R_OK | X_OK)
        }
        guard readable == 0 else {
            let code = errno
            self = .unreadable(Self.reason(code))
            return
        }
        do {
            self = .folder(try listing(url).sortedStably())
        } catch where DatalessFiles.isDownloadRefusal(error) {
            self = .onlyInCloud
        } catch {
            self = .unreadable(error.localizedDescription)
        }
    }

    /// A failed call's `code` in plain words, such as "permission denied".
    private static func reason(_ code: Int32) -> String {
        code == EACCES || code == EPERM
            // Translators: A reason in a few words, with no full stop, that a folder can't be read: the Mac refused TextMouth access. It follows a colon in a sentence about the folder.
            ? InterfaceText.line("common.permissionDenied", "permission denied")
            : String(cString: strerror(code)).lowercased()
    }
}

// MARK: - What Storage Settings Offer

/// What Storage settings offer for a chosen folder once it is assessed
/// (FR02): a confirmation before anything is done, or a sentence for the
/// status line. The words are built once, for the screen, VoiceOver, and a
/// braille display alike.
enum StorageChoice: Equatable {
    /// What a confirmed choice does.
    enum Action: Equatable {
        /// Copies the library into the folder and uses it there.
        case move(to: URL)
        /// Uses the library in the folder, or starts a new one in the
        /// default location, once TextMouth has opened again.
        case useLibrary(at: URL)
    }

    /// Asks first: an alert titled `title`, explaining `message`, whose
    /// confirming `button` does `action`.
    case confirm(title: String, message: String, button: String, action: Action)
    /// Says `message` in the status line, shown as a refusal when
    /// `isRefusal`.
    case report(String, isRefusal: Bool)

    /// What the words say about the library TextMouth is using.
    struct CurrentLibrary: Equatable {
        /// The data directory's full path.
        var folder: String
        /// How many books the library lists: its own, never a feed's items.
        var bookCount: Int
        /// How many feeds the library is subscribed to, which the words name
        /// beside its books (FR11); 0 for none.
        var feedCount: Int = 0
        /// Whether the library is available.
        var isAvailable: Bool
        /// What can't be saved while the library isn't available, in the
        /// banner's sentences, which switching libraries loses; empty when
        /// nothing is unsaved.
        var unsavedChanges: [String] = []
    }

    /// The choice offered for `assessment`, with `current` the library in
    /// use. For a folder holding another copy of that library, `comparison`
    /// is what comparing the two copies found (`LibraryCopyReader`), which
    /// the confirmation says in words (`StorageWording.copyOfCurrentLibrarySentence`);
    /// nil when no comparison was made.
    init(for assessment: StorageDestinationAssessment, current: CurrentLibrary, comparison: LibraryComparisonOutcome? = nil) {
        let path = assessment.folder.path
        switch assessment.verdict {
        case .moveHere:
            let message = [
                StorageWording.moveSentence(to: path),
                StorageWording.moveLocationSentence(assessment.location, size: assessment.librarySize),
            ]
            self = .confirm(
                // Translators: Title of the question asked before copying the library into the folder the listener chose.
                title: InterfaceText.line("storageChoice.moveHere.question", "Move Library Here?"),
                message: SentenceWording.joined(message.compactMap { $0 }),
                // Translators: Button of the question that confirms copying the library into the chosen folder.
                button: InterfaceText.line("storageChoice.moveHere.button", "Move Library Here"),
                action: .move(to: assessment.folder)
            )
        case .useLibrary(let found):
            let message = [
                StorageWording.useSentence(of: path, current: current),
                found.isCopyOfCurrentLibrary ? StorageWording.copyOfCurrentLibrarySentence(comparison) : nil,
                StorageWording.useLocationSentence(assessment.location),
                StorageWording.unsavedSentence(current),
            ]
            self = .confirm(
                // Translators: Title of the question asked before using the library the chosen folder holds.
                title: InterfaceText.line("storageChoice.useLibrary.question", "Use This Library?"),
                message: SentenceWording.joined(message.compactMap { $0 }),
                // Translators: Button of the question that confirms using the library the chosen folder holds.
                button: InterfaceText.line("storageChoice.useLibrary.button", "Use This Library"),
                action: .useLibrary(at: assessment.folder)
            )
        case .startNewLibrary:
            let message = [
                StorageWording.startNewLibrarySentence(in: path, current: current),
                StorageWording.unsavedSentence(current),
            ]
            self = .confirm(
                // Translators: Title of the question asked before starting a new, empty library in the default location.
                title: InterfaceText.line("storageChoice.startNewLibrary.question", "Start a New Library?"),
                message: SentenceWording.joined(message.compactMap { $0 }),
                // Translators: Button of the question that confirms starting a new, empty library.
                button: InterfaceText.line("storageChoice.startNewLibrary.button", "Start New Library"),
                action: .useLibrary(at: assessment.folder)
            )
        case .currentLibrary:
            // Translators: Status line when the listener chose the folder that already holds the library in use. %@ is the folder's path.
            self = .report(InterfaceText.line("storageChoice.currentLibrary", "This is the library TextMouth is using: \(path)."),
                           isRefusal: false)
        case .refused(let refusal):
            self = .report(
                StorageWording.refusal(
                    refusal,
                    path: path,
                    location: assessment.location,
                    libraryIsAvailable: current.isAvailable
                ),
                isRefusal: true
            )
        }
    }
}

/// The sentences of `StorageChoice`, each built in one place (FR02).
enum StorageWording {
    /// A size in bytes as Finder shows a file's, such as "5.5 GB".
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// What a move does, in the words Storage settings have always used.
    static func moveSentence(to path: String) -> String {
        SentenceWording.joined([
            // Translators: First sentence of the question asked before moving the library. %@ is the new folder's path.
            InterfaceText.line("storage.moveSentence.validate", "Copy all TextMouth data to \(path), validate it, and use the new location?"),
            // Translators: Last sentence of the question asked before moving the library: the old folder is kept.
            InterfaceText.line("storage.moveSentence.directory", "The current directory will be retained as recovery data."),
        ])
    }

    /// What a library moved to `location` means: uploading in the
    /// background for a cloud folder, the drive to keep connected for
    /// another volume, and nothing more for this Mac's own disk.
    /// - Parameter size: The library's bytes, when known.
    static func moveLocationSentence(_ location: StorageLocation, size: Int64?) -> String? {
        switch location {
        case .local:
            return nil
        case .otherVolume(let name):
            return driveSentence(name)
        case .cloud(let provider):
            let uploading = size.map {
                // Translators: First sentence of what moving the library into a cloud folder means. %1$@ is the library's size, such as "5.5 GB"; %2$@ is the cloud service's name.
                InterfaceText.line("storage.moveLocationSentence.cloud.uploadNamed", "Your library (\(Self.size($0))) will upload to \(provider.displayName) in the background.")
            // Translators: First sentence of what moving the library into a cloud folder means, when its size is not known. %@ is the cloud service's name.
            } ?? InterfaceText.line("storage.moveLocationSentence.cloud.libraryUpload", "Your library will upload to \(provider.displayName) in the background.")
            return SentenceWording.joined([
                uploading,
                // Translators: Second sentence of what moving the library into a cloud folder means.
                InterfaceText.line("storage.moveLocationSentence.cloud.downloads", "Books stay on this Mac until you remove their downloads or macOS needs space."),
                // Translators: Last sentence of what moving the library into a cloud folder means.
                InterfaceText.line("storage.moveLocationSentence.cloud.connection", "A book that's only in the cloud needs an internet connection to open."),
            ])
        }
    }

    /// What a library used where it is, in `location`, means.
    static func useLocationSentence(_ location: StorageLocation) -> String? {
        switch location {
        case .local:
            return nil
        case .otherVolume(let name):
            return driveSentence(name)
        case .cloud(let provider):
            // Translators: What using a library in a cloud folder means. %@ is the cloud service's name.
            return InterfaceText.line("storage.useLocationSentence.cloud", "A book that's only in \(provider.displayName) needs an internet connection to open.")
        }
    }

    /// The drive a library on another volume needs, named as Finder names it.
    static func driveSentence(_ name: String) -> String {
        // Translators: What using a library on another drive means. %@ is the drive's name.
        InterfaceText.line("storage.driveSentence", "TextMouth needs the drive “\(name)” connected to open the library.")
    }

    /// What using the library in `path` does, naming the library in use
    /// and, while it is available, how many books it lists.
    static func useSentence(of path: String, current: StorageChoice.CurrentLibrary) -> String {
        guard current.isAvailable else {
            return SentenceWording.joined([
                // Translators: First sentence of the question asked before using another library while the one in use is not available. %1$@ is the chosen folder's path; %2$@ is the path of the library in use.
                InterfaceText.line("storage.useSentence.available", "TextMouth will open the library in \(path) instead of the one in \(current.folder), which isn't available."),
                // Translators: Second sentence of the question asked before using another library while the one in use is not available. %@ is the path of the library in use.
                InterfaceText.line("storage.useSentence.created", "Nothing is copied, and nothing is created in \(current.folder)."),
                // Translators: Last sentence of the question asked before using another library: TextMouth opens again.
                InterfaceText.line("storage.useSentence.again", "TextMouth will quit and open again to load it."),
            ])
        }
        let counts = CountWording.booksAndFeeds(books: current.bookCount, feeds: current.feedCount)
        return SentenceWording.joined([
            // Translators: First sentence of the question asked before using another library. %1$@ is the path of the library in use; %2$@ is what it holds, such as "743 books, 2 feeds"; %3$@ is the chosen folder's path.
            InterfaceText.line("storage.useSentence.using", "TextMouth will stop using the library in \(current.folder) (\(counts)) and open the library in \(path) instead."),
            // Translators: Second sentence of the question asked before using another library. %@ is the path of the library in use.
            InterfaceText.line("storage.useSentence.stays", "Nothing is copied, and the library in \(current.folder) stays as it is."),
            // Translators: Last sentence of the question asked before using another library: TextMouth opens again.
            InterfaceText.line("storage.useSentence.again", "TextMouth will quit and open again to load it."),
        ])
    }

    /// Said of a folder holding another copy of the library in use, by its
    /// identity, such as the folder an earlier move left behind: which copy
    /// is newer, from comparing the two (Compare Libraries), or that this
    /// could not be told, and why. `comparison` is nil when none was made.
    static func copyOfCurrentLibrarySentence(_ comparison: LibraryComparisonOutcome?) -> String {
        switch comparison {
        case .compared(let found):
            return LibraryComparisonWording.newerCopySentence(found, reason: nil)
        case .notComparable(let unread):
            let reason = unread.first.map { LibraryComparisonWording.shortReason(for: $0) }
            return LibraryComparisonWording.newerCopySentence(nil, reason: reason)
        case .cancelled:
            // Translators: A reason, in a clause with no capital letter and no full stop, that Use This Library could not tell which copy of the library is newer: the listener cancelled the comparison.
            return LibraryComparisonWording.newerCopySentence(nil, reason: InterfaceText.line("storage.copyOfCurrentLibrarySentence.cancelled", "you stopped the comparison"))
        case .differentLibraries, nil:
            return LibraryComparisonWording.newerCopySentence(nil, reason: nil)
        }
    }

    /// What starting a new library in the default location, `path`, does
    /// while the library in use isn't available.
    static func startNewLibrarySentence(in path: String, current: StorageChoice.CurrentLibrary) -> String {
        SentenceWording.joined([
            // Translators: First sentence of the question asked before starting a new library. %1$@ is the default location's path; %2$@ is the path of the library in use, which is not available.
            InterfaceText.line("storage.startNewLibrarySentence.available", "TextMouth will start a new, empty library in the default location, \(path), instead of the library in \(current.folder), which isn't available."),
            // Translators: Second sentence of the question asked before starting a new library. %@ is the path of the library in use.
            InterfaceText.line("storage.startNewLibrarySentence.nothing", "Nothing is created in \(current.folder)."),
            // Translators: Last sentence of the question asked before starting a new library: TextMouth opens again.
            InterfaceText.line("storage.startNewLibrarySentence.again", "TextMouth will quit and open again to start it."),
        ])
    }

    /// What switching away from a library that isn't available loses, or
    /// nil when nothing is unsaved.
    static func unsavedSentence(_ current: StorageChoice.CurrentLibrary) -> String? {
        guard !current.unsavedChanges.isEmpty else { return nil }
        // Translators: Sentence in the question asked before switching libraries: changes that could not be saved are lost. The failure notices follow.
        let lead = InterfaceText.line("storage.unsavedSentence", "Switching loses the changes TextMouth couldn't save while the library isn't available.")
        return SentenceWording.joined([lead] + current.unsavedChanges)
    }

    /// Why nothing can be done with the folder at `path`, in `location`.
    /// - Parameter libraryIsAvailable: Whether the library in use is, which
    ///   decides what else the user can choose.
    static func refusal(
        _ refusal: StorageDestinationAssessment.Refusal,
        path: String,
        location: StorageLocation,
        libraryIsAvailable: Bool
    ) -> String {
        let instead = libraryIsAvailable
            // Translators: Last sentence of why the chosen folder can't be used, while the library in use is available: what to choose instead.
            ? InterfaceText.line("storage.instead.empty", "Choose an empty folder, or one that holds a TextMouth library.")
            // Translators: Last sentence of why the chosen folder can't be used, while the library in use is not available: what to choose instead.
            : InterfaceText.line("storage.instead.location", "Choose a folder that holds a TextMouth library, or use the default location.")
        switch refusal {
        case .notAFolder:
            return SentenceWording.joined([
                // Translators: First sentence of why the chosen location can't be used: a file is there. %@ is the path.
                InterfaceText.line("common.thereIsAFileAtValue", "There is a file at \(path), not a folder."),
                // Translators: Last sentence of why the chosen location can't be used because it is a file.
                InterfaceText.line("storage.chooseFolder", "Choose a folder."),
            ])
        case .otherItems(let names):
            return SentenceWording.joined([
                // Translators: First sentence of why the chosen folder can't be used: it holds other items. %1$@ is the folder's path; %2$lld is how many items; %3$@ is their names as a short list.
                InterfaceText.line("storage.folderHoldsOther", "The folder \(path) holds \(number: names.count) other items: \(DataDirectoryDestinationChange.listing(names))."),
                instead,
            ])
        case .overlap(_, let explanation):
            return explanation
        case .inTrash:
            return SentenceWording.joined([
                // Translators: First sentence of why the chosen folder can't be used: it is in the Trash. %@ is the folder's path.
                InterfaceText.line("storage.folderTrash", "The folder \(path) is in the Trash."),
                // Translators: Last sentence of why the chosen folder can't be used because it is in the Trash. "It" is the Trash.
                InterfaceText.line("storage.chooseFolderOutside", "Choose a folder outside it."),
            ])
        case .unreadable(let reason):
            // Translators: Why the chosen folder can't be used: it can't be read. %1$@ is the folder's path; %2$@ is the reason in a few words, such as "permission denied", with no full stop.
            return InterfaceText.line("common.textmouthCantReadTheFolderValue", "TextMouth can't read the folder \(path): \(reason).")
        case .notDownloaded:
            return SentenceWording.joined([
                // Translators: First sentence of why the chosen folder can't be used: it is only in the cloud. %1$@ is the folder's path; %2$@ is the cloud service's name, or "the cloud" when it is unknown.
                InterfaceText.line("storage.folderIsntMac", "The folder \(path) is in \(DataDirectoryUnavailability.service(location.provider)) and isn't on this Mac yet."),
                // Translators: Last sentence of why the chosen folder can't be used because it is only in the cloud: what to do. "It" is the folder.
                InterfaceText.line("storage.openFinderDownload", "Open it in Finder to download it, then choose it again."),
            ])
        case .parentMissing:
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            // Translators: Why the chosen location can't be used: the folder that would hold it is missing. %1$@ is the chosen path; %2$@ is the missing folder's path.
            return InterfaceText.line("storage.cantMadeBecause", "\(path) can't be made, because the folder that would hold it, \(parent), can't be found.")
        case .notWritable(let folder):
            return SentenceWording.joined([
                // Translators: First sentence of why the chosen location can't be used: macOS does not let TextMouth write there. %@ is the folder's path.
                InterfaceText.line("storage.isntAllowedMake", "TextMouth isn't allowed to make changes in \(folder)."),
                // Translators: Last sentence of why the chosen location can't be used: what to do.
                InterfaceText.line("storage.chooseAnotherFolder", "Choose another folder."),
            ])
        case .notEnoughSpace(let needed, let available):
            // Translators: Why the chosen location can't be used: the disk is too full. %1$@ is the size the library needs, such as "5.5 GB"; %2$@ is the free space.
            return InterfaceText.line("storage.thereIsntEnough", "There isn't enough free space for the library there: it needs \(size(needed)), and \(size(available)) is free.")
        case .nothingToMove:
            return SentenceWording.joined([
                // Translators: First sentence of why the chosen folder can't be used: it holds no library and there is none to move. %@ is the folder's path.
                InterfaceText.line("storage.thereNoLibrary", "There's no library in \(path) to use, and none to move there while the library isn't available."),
                instead,
            ])
        }
    }
}

// MARK: - Work Off the Main Actor

/// Runs blocking work, such as reading or copying a folder that can wait on
/// a drive or the network, on a background queue, and hands its result back
/// to the caller without holding the main actor (FR02). A dispatch queue,
/// not a Swift task, runs it: the work blocks its thread for as long as it
/// takes, which Swift's cooperative threads must never do.
enum OffMainWork {
    /// What `work` returns, once it has run on `queue`: a global queue,
    /// unless the caller passes a queue of its own, such as a serial queue
    /// that keeps its work in order.
    static func run<Value: Sendable>(
        on queue: DispatchQueue = .global(qos: .userInitiated),
        _ work: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }

    /// What `work` returns, or the error it throws, once it has run on a
    /// background queue.
    static func runThrowing<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
