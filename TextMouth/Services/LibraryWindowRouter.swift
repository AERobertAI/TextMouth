import AppKit
import Combine

/// Routes each app-wide action to the one window that should take it
/// (TODO A05): an action asked for by a menu command, a keyboard shortcut,
/// or a finished book, whichever window is key, or with no window open.
///
/// It keeps weak references to the open Library windows, each with its way
/// of taking an action, and to the open reader windows, each with its way of
/// opening another reader: SwiftUI gives `openWindow` only to views, never to
/// the app or its delegate. A reader or Settings window can be key when an
/// action arrives, so routing cannot depend solely on a key Library window.
///
/// Every action goes through `route(_:)`, which decides once who takes it
/// (`handler(for:keyWindow:registeredLibraryWindows:readerWindows:)`), so it
/// is taken exactly once whatever windows exist. Receivers in each Library
/// window could not promise that: SwiftUI keeps closed Library windows alive,
/// and their views go on receiving every notification. An action no open
/// window can take waits (`PendingGlobalActions`) while a Library window
/// opens, and is handed to it once it has registered.
@MainActor
final class LibraryWindowRouter: ObservableObject {
    /// Shared registry used by both SwiftUI views and the AppKit delegate.
    static let shared = LibraryWindowRouter()

    /// Runs `work` on the main queue once `delay` seconds have passed.
    typealias Scheduler = @MainActor (
        _ delay: TimeInterval,
        _ work: @escaping @MainActor @Sendable () -> Void
    ) -> Void

    /// The current time: the system clock, unless a test controls it.
    private let now: @MainActor () -> Date
    /// The window receiving keystrokes now.
    private let currentKeyWindow: @MainActor () -> NSWindow?
    /// Runs the router's later work: handing waiting actions to a Library
    /// window that has registered, and asking for a Library window.
    private let schedule: Scheduler

    /// Opens a new Library window and reports whether one opened. The app
    /// delegate supplies SwiftUI's way at launch; until then nothing opens.
    var openLibraryWindow: @MainActor () -> Bool = { false }

    /// Creates a router. The app's shared router uses the system clock, the
    /// application's key window, and the main queue; a test passes its own.
    init(
        now: @escaping @MainActor () -> Date = { Date() },
        keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow },
        schedule: @escaping Scheduler = LibraryWindowRouter.scheduleOnMainQueue
    ) {
        self.now = now
        self.currentKeyWindow = keyWindow
        self.schedule = schedule
    }

    // MARK: - Library Windows

    /// A registered Library window and its way of taking app-wide actions.
    /// Weak storage avoids extending an `NSWindow`'s lifetime after SwiftUI
    /// closes its scene.
    private final class LibraryWindowEntry {
        weak var window: NSWindow?
        var perform: @MainActor (GlobalAction) -> Void

        init(window: NSWindow, perform: @escaping @MainActor (GlobalAction) -> Void) {
            self.window = window
            self.perform = perform
        }
    }

    /// The registered Library windows, in the order they registered.
    private var libraryWindowEntries: [LibraryWindowEntry] = []

    /// The registered Library windows still open, in the order they
    /// registered.
    var registeredLibraryWindows: [NSWindow] {
        pruneClosedWindows()
        return libraryWindowEntries.compactMap(\.window)
    }

    /// Whether at least one Library scene has supplied its hosting window.
    var hasRegisteredWindow: Bool {
        !registeredLibraryWindows.isEmpty
    }

    /// Registers a Library window, with its way of taking app-wide actions,
    /// once its hosting AppKit window is available. Registering a window
    /// again replaces its action and keeps its place.
    ///
    /// Actions waiting for a Library window are handed on just after, on
    /// the next turn of the main queue, to the window the decision names
    /// then. SwiftUI can build a Library window for a book opened from Finder
    /// and discard it within the same turn, and that window must not take
    /// the waiting actions with it.
    func register(_ window: NSWindow, perform: @escaping @MainActor (GlobalAction) -> Void) {
        pruneClosedWindows()
        if let entry = libraryWindowEntries.first(where: { $0.window === window }) {
            entry.perform = perform
        } else {
            libraryWindowEntries.append(LibraryWindowEntry(window: window, perform: perform))
        }
        // A Library window is here, whichever was asked for: the next
        // action that finds none open asks for one again.
        libraryWindowRequestedAt = nil
        if !pendingActions.isEmpty {
            schedule(0) { [weak self] in
                self?.deliverWaitingActions()
            }
        }
    }

    /// Removes a Library window when its SwiftUI scene disappears.
    func unregister(_ window: NSWindow) {
        libraryWindowEntries.removeAll { $0.window == nil || $0.window === window }
    }

    /// Pure selection core used by production routing and deterministic tests.
    /// A key window only wins when it is itself one of the Library candidates.
    static func selectedWindow(
        from libraryWindows: [NSWindow],
        keyWindow: NSWindow?
    ) -> NSWindow? {
        if let keyWindow,
           libraryWindows.contains(where: { $0 === keyWindow }) {
            return keyWindow
        }
        return libraryWindows.first
    }

    /// Drops Library and reader windows that SwiftUI has already released.
    private func pruneClosedWindows() {
        libraryWindowEntries.removeAll { $0.window == nil }
        readerWindowOpeners.removeAll { $0.window == nil }
    }

    // MARK: - Reader Windows

    /// An open reader window, and the action that opens a reader window
    /// from it.
    private final class ReaderWindowOpener {
        weak var window: NSWindow?
        let openReader: (UUID) -> Void

        init(window: NSWindow, openReader: @escaping (UUID) -> Void) {
            self.window = window
            self.openReader = openReader
        }
    }

    /// The open reader windows, in the order they registered.
    private var readerWindowOpeners: [ReaderWindowOpener] = []

    /// The registered reader windows still open, in the order they
    /// registered.
    var registeredReaderWindows: [NSWindow] {
        pruneClosedWindows()
        return readerWindowOpeners.compactMap(\.window)
    }

    /// Registers a reader window with the action that opens a reader window
    /// from it, replacing any action the window registered before.
    ///
    /// SwiftUI gives `openWindow` only to views; the app and its delegate
    /// have none of their own. While no Library window is open, the router
    /// opens a book's reader through one of these instead.
    func registerReaderWindow(_ window: NSWindow, openReader: @escaping (UUID) -> Void) {
        unregisterReaderWindow(window)
        readerWindowOpeners.append(ReaderWindowOpener(window: window, openReader: openReader))
    }

    /// Removes a reader window when its SwiftUI scene disappears.
    func unregisterReaderWindow(_ window: NSWindow) {
        readerWindowOpeners.removeAll { $0.window == nil || $0.window === window }
    }

    /// Pure choice of the reader window another reader opens through: the
    /// key window when it is one of `readerWindows`, otherwise the one
    /// registered most recently, the last of them.
    static func selectedReaderWindow(
        from readerWindows: [NSWindow],
        keyWindow: NSWindow?
    ) -> NSWindow? {
        if let keyWindow,
           readerWindows.contains(where: { $0 === keyWindow }) {
            return keyWindow
        }
        return readerWindows.last
    }

    // MARK: - App-Wide Actions (TODO A05)

    /// Pure decision of who takes `action`, given the windows open now.
    /// Every arrangement is decided here, so each is tested without opening
    /// a window:
    ///
    /// 1. A registered Library window takes every action whenever there is
    ///    one: the key window when it is one of them, otherwise the first
    ///    registered, even while a reader or Settings is key
    ///    (`selectedWindow(from:keyWindow:)`).
    /// 2. With no Library window, an action that only opens a book's reader
    ///    goes to a registered reader window, which opens it through the
    ///    action it lent the router (`selectedReaderWindow(from:keyWindow:)`).
    /// 3. Otherwise no open window can take it, as on a cold launch, while
    ///    only readers are open (for an action that needs a Library window),
    ///    or with every window closed and the app still running: a new
    ///    Library window opens and takes the action once it has registered.
    ///
    /// - Parameters:
    ///   - action: The app-wide action to take.
    ///   - keyWindow: The window currently receiving keystrokes, if any.
    ///   - registeredLibraryWindows: The registered Library windows, in the
    ///     order they registered.
    ///   - readerWindows: The registered reader windows, in the order they
    ///     registered.
    static func handler(
        for action: GlobalAction,
        keyWindow: NSWindow?,
        registeredLibraryWindows: [NSWindow],
        readerWindows: [NSWindow]
    ) -> GlobalActionHandler {
        if let library = selectedWindow(from: registeredLibraryWindows, keyWindow: keyWindow) {
            return .libraryWindow(library)
        }
        if action.bookToOpen != nil,
           let reader = selectedReaderWindow(from: readerWindows, keyWindow: keyWindow) {
            return .readerWindow(reader)
        }
        return .newLibraryWindow
    }

    /// How many of the most recent decisions `recordedDecisions` keeps.
    static let recordedDecisionLimit = 50

    /// The router's most recent decisions, oldest first: each app-wide
    /// action and who took it. Tests read them to see that every action was
    /// decided exactly once; they also leave a trail for diagnosis.
    private(set) var recordedDecisions: [GlobalActionDecision] = []

    /// Takes `action` exactly once: through the Library window or reader
    /// window the decision names, or, when no open window can take it, by
    /// keeping it waiting while a Library window opens.
    func route(_ action: GlobalAction) {
        switch decide(action) {
        case .libraryWindow(let window):
            libraryWindowEntries.first { $0.window === window }?.perform(action)
        case .readerWindow(let window):
            guard let bookID = action.bookToOpen else { return }
            readerWindowOpeners.first { $0.window === window }?.openReader(bookID)
        case .newLibraryWindow:
            pendingActions.add(action, at: now())
            log("no open window can take \(action.logDescription); it waits for a Library window")
            requestLibraryWindow(after: 0)
        }
    }

    /// Decides who takes `action` with the windows registered now, and
    /// records the decision.
    private func decide(_ action: GlobalAction) -> GlobalActionHandler {
        let handler = Self.handler(
            for: action,
            keyWindow: currentKeyWindow(),
            registeredLibraryWindows: registeredLibraryWindows,
            readerWindows: registeredReaderWindows
        )
        recordedDecisions.append(GlobalActionDecision(action: action, handler: handler))
        if recordedDecisions.count > Self.recordedDecisionLimit {
            recordedDecisions.removeFirst(recordedDecisions.count - Self.recordedDecisionLimit)
        }
        return handler
    }

    // MARK: - Waiting for a Library Window

    /// The actions waiting for a Library window to take them.
    private var pendingActions = PendingGlobalActions()

    /// The actions waiting for a Library window now, oldest first.
    var waitingActions: [GlobalAction] {
        pendingActions.actions
    }

    /// When the Library window on its way was asked for, or nil when none
    /// is on its way. While one is, actions wait for it instead of asking
    /// for another, so one Library window opens for any number of them.
    private var libraryWindowRequestedAt: Date?

    /// Notes that a Library window is on its way without asking for one.
    /// SwiftUI opens the first Library window itself at launch, after any
    /// book Finder hands over, so an action that arrives before that window
    /// registers waits for it instead of opening a second. Does nothing
    /// once a Library window has registered.
    func expectLibraryWindow() {
        guard !hasRegisteredWindow else { return }
        libraryWindowRequestedAt = now()
    }

    /// Asks for a Library window once `delay` seconds have passed, if one
    /// is still needed then (`openLibraryWindowIfStillNeeded()`).
    private func requestLibraryWindow(after delay: TimeInterval) {
        schedule(delay) { [weak self] in
            self?.openLibraryWindowIfStillNeeded()
        }
    }

    /// Opens a Library window for the actions waiting, unless none is
    /// waiting any more, a Library window has registered (its registration
    /// hands them on), or one asked for less than an action's lifetime ago
    /// is still on its way.
    private func openLibraryWindowIfStillNeeded() {
        discardExpiredActions()
        guard !pendingActions.isEmpty, !hasRegisteredWindow else { return }
        let date = now()
        if let requestedAt = libraryWindowRequestedAt,
           abs(date.timeIntervalSince(requestedAt)) <= PendingGlobalActions.lifetime {
            return
        }
        libraryWindowRequestedAt = date
        let waiting = pendingActions.actions.map(\.logDescription).joined(separator: ", ")
        if openLibraryWindow() {
            log("opened a Library window for \(waiting)")
        } else {
            log("could not open a Library window for \(waiting)")
        }
    }

    /// Hands every waiting action on, oldest first, through the decision,
    /// which names a Library window for each while one is registered.
    private func deliverWaitingActions() {
        discardExpiredActions()
        guard hasRegisteredWindow else { return }
        for action in pendingActions.takeAll() {
            route(action)
        }
    }

    /// Throws away the waiting actions too old to take, and logs each.
    private func discardExpiredActions() {
        for action in pendingActions.discardExpired(at: now()) {
            log("\(action.logDescription) waited too long for a Library window and was dropped")
        }
    }

    // MARK: - Notifications

    /// The subscriptions to the center the router takes actions from.
    private var notificationSubscriptions: [AnyCancellable] = []

    /// The center the router takes app-wide actions from, if any.
    private(set) weak var listenedCenter: NotificationCenter?

    /// Takes every app-wide action asked for on `center`
    /// (`GlobalAction.routedNotificationNames`), each exactly once, in place
    /// of any center listened to before. The app delegate listens to the
    /// default center from launch.
    func listen(to center: NotificationCenter) {
        listenedCenter = center
        notificationSubscriptions = GlobalAction.routedNotificationNames.map { name in
            center.publisher(for: name).sink { [weak self] notification in
                guard let action = GlobalAction(notification: notification) else { return }
                self?.route(action)
            }
        }
    }

    // MARK: - Scheduling and Logging

    /// The app's scheduler: runs `work` on the main queue once `delay`
    /// seconds have passed.
    static func scheduleOnMainQueue(
        _ delay: TimeInterval,
        _ work: @escaping @MainActor @Sendable () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            work()
        }
    }

    /// Notes a routing event in the debug log.
    private func log(_ message: String) {
        TextMouthPaths.appendLog(to: TextMouthPaths.debugLogFile, message: "app-wide action: \(message)")
    }
}

// MARK: - App-Wide Action Vocabulary

/// An action the app takes as a whole, asked for by a menu command, a
/// keyboard shortcut, or a finished book, whichever window is key, or with
/// no window open at all (TODO A05). The router decides who takes each one
/// (`LibraryWindowRouter.handler(for:keyWindow:registeredLibraryWindows:readerWindows:)`),
/// so it is taken exactly once whatever windows exist.
enum GlobalAction: Equatable {
    /// File > Open Book...: a Library window presents the Open panel.
    case openBookFile
    /// Library > Import DAISY Folder…: a Library window presents the
    /// folder-only panel (TODO I02).
    case importDAISYFolder
    /// Open a book's reader window, or bring it forward when it is already
    /// open: a book just imported, or a package from Finder the library
    /// already lists.
    case openBookWindow(UUID)
    /// Continue to Next Book: open the reader window of the book after the
    /// one that finished, which then starts playing (`ReaderAutoplayRequests`).
    case continueToNextBook(UUID)

    /// The book whose reader window this action opens, or nil for an action
    /// that needs a Library window. An action that only opens a reader can
    /// be taken by any window that lent the router a way to open readers:
    /// a reader window as well as a Library window.
    var bookToOpen: UUID? {
        switch self {
        case .openBookWindow(let bookID), .continueToNextBook(let bookID):
            return bookID
        case .openBookFile, .importDAISYFolder:
            return nil
        }
    }

    /// The notifications that ask for app-wide actions, which the router
    /// listens for (`LibraryWindowRouter.listen(to:)`).
    static let routedNotificationNames: [Notification.Name] = [
        .openBookFile,
        .importDAISYFolder,
        .openBookWindow,
        .continueToNextBook,
    ]

    /// The action `notification` asks for, or nil when it asks for none: a
    /// name the router does not route, or a book action naming no book.
    init?(notification: Notification) {
        switch notification.name {
        case .openBookFile:
            self = .openBookFile
        case .importDAISYFolder:
            self = .importDAISYFolder
        case .openBookWindow:
            guard let bookID = notification.object as? UUID else { return nil }
            self = .openBookWindow(bookID)
        case .continueToNextBook:
            guard let bookID = notification.nextBookID else { return nil }
            self = .continueToNextBook(bookID)
        default:
            return nil
        }
    }

    /// A short description for the debug log. It names a book by the start
    /// of its identifier and never a file.
    var logDescription: String {
        switch self {
        case .openBookFile:
            return "Open Book"
        case .importDAISYFolder:
            return "Import DAISY Folder"
        case .openBookWindow(let bookID):
            return "open book \(bookID.uuidString.prefix(8))"
        case .continueToNextBook(let bookID):
            return "Continue to Next Book \(bookID.uuidString.prefix(8))"
        }
    }
}

/// App-wide actions waiting for a Library window to take them (TODO A05).
///
/// When no open window can take an action, the router keeps it here while
/// a Library window opens, and hands it on once one has registered. Taking
/// the actions removes them, so no later window takes them again. An action
/// older than `lifetime` is thrown away instead of taken, so a window that
/// never opened cannot leave an Open panel to appear, unasked, in a Library
/// window opened much later. The limit holds in both directions, so a clock
/// set back cannot keep an action waiting any longer either.
struct PendingGlobalActions {
    /// How long an action waits, in seconds. A Library window opens and
    /// registers in well under a second, and on a cold launch as soon as
    /// the library has loaded; the margin covers a slow launch. It is as
    /// long as a Continue to Next Book autoplay request lasts
    /// (`ReaderAutoplayRequests.lifetime`), so a waiting Continue to Next
    /// Book still finds its request when its reader opens.
    static let lifetime: TimeInterval = 30

    /// One waiting action and when it began to wait.
    private struct Entry {
        let action: GlobalAction
        let queuedAt: Date
    }

    /// The waiting actions, oldest first.
    private var waiting: [Entry] = []

    /// Whether no action is waiting.
    var isEmpty: Bool { waiting.isEmpty }

    /// The waiting actions, oldest first, including any too old to take.
    var actions: [GlobalAction] { waiting.map(\.action) }

    /// Keeps `action` waiting from `date` on.
    mutating func add(_ action: GlobalAction, at date: Date) {
        waiting.append(Entry(action: action, queuedAt: date))
    }

    /// Throws away every action too old to take at `date`.
    ///
    /// - Returns: The actions thrown away, oldest first, for the log.
    @discardableResult
    mutating func discardExpired(at date: Date) -> [GlobalAction] {
        let expired = waiting.filter { !Self.isUsable($0, at: date) }
        waiting.removeAll { !Self.isUsable($0, at: date) }
        return expired.map(\.action)
    }

    /// Takes every waiting action, oldest first, leaving none. Call
    /// `discardExpired(at:)` first, so nothing too old is taken.
    mutating func takeAll() -> [GlobalAction] {
        defer { waiting.removeAll() }
        return actions
    }

    /// Whether `entry` may still be taken at `date`: no further than
    /// `lifetime` from when it began to wait, in either direction.
    private static func isUsable(_ entry: Entry, at date: Date) -> Bool {
        abs(date.timeIntervalSince(entry.queuedAt)) <= lifetime
    }
}

/// Who takes an app-wide action. Windows compare by identity, the equality
/// `NSObject` gives them.
enum GlobalActionHandler: Equatable {
    /// This registered Library window takes the action.
    case libraryWindow(NSWindow)
    /// This registered reader window opens the book's reader through the
    /// action it lent the router. Only for an action that opens a reader.
    case readerWindow(NSWindow)
    /// No open window can take the action: a Library window opens first,
    /// and takes the action once it has registered.
    case newLibraryWindow
}

/// One decision of the router: an app-wide action, and who took it.
struct GlobalActionDecision: Equatable {
    /// The action decided.
    let action: GlobalAction
    /// Who took it.
    let handler: GlobalActionHandler
}
