import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - The List's Letter Navigation

/// The Library list's letter navigation while the Leading articles setting
/// passes over articles when typing (its second and third choices,
/// TITLE-ARTICLES-RESEARCH-2026-11-13.md): the first letters of a title
/// typed while the list has the keyboard go to the first row, in the list's
/// order, that they reach (`TitleTyping`), "h" to "The Hobbit" and "the h"
/// to it too.
///
/// The row is selected, which VoiceOver follows and reads as it reads any
/// row, so nothing more is announced, and scrolled into view once the list
/// has drawn it selected (`scrollSelectedRowIntoView`). A key that reaches
/// no row leaves the selection where it was, and makes no sound.
/// Typed letters add up within `interval` of each other, as AppKit's type
/// select gathers them (`TitleTypingSearch`); a held key types once.
///
/// While titles are part of the title (the first choice), every key goes
/// on to the list, whose own type select (AppKit's) works as it always has.
/// A key with Command or Control is never typing; a Space is only while a
/// title in the list goes on with the letters typed and a space, as "The
/// Hobbit" goes on with "the " (`TitleTyping.spaceGoesOn`), and keeps its
/// own meaning, Play or Pause, at every other time
/// (`TitleTypingSpaceClaim`).
struct LibraryTitleTyping: ViewModifier {
    /// How titles are typed (the Leading articles setting).
    let articles: LeadingArticles
    /// The list's rows, in its order, as typing reaches them, made at a key
    /// press rather than at every drawing.
    let rows: () -> [TypedRow<UUID>]
    /// The list's selection, which a match replaces.
    @Binding var selection: Set<UUID>
    /// The window the list is in, where a Space continuing a title is
    /// claimed from the shortcuts.
    let window: PlatformWindow?

    /// The letters typed so far.
    @State private var search = TitleTypingSearch()
    /// How many times typing has reached a row, each of which the list then
    /// scrolls into view: a count, so reaching the row reached last time, or
    /// any other, scrolls again.
    @State private var reaches = 0

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .onKeyPress(phases: [.down, .repeat]) { press in
                    take(press, scrollingWith: proxy)
                }
                // A newer reach cancels a look still waiting for the last one.
                .task(id: reaches) {
                    guard reaches > 0 else { return }
                    await scrollSelectedRowIntoView()
                }
        }
    }

    /// Acts on `press` as letter navigation: returns `.ignored` for a key
    /// the list's own handling keeps, and `.handled` for one typed here. A
    /// key that is not typing, such as an arrow, ends the search, so the
    /// next letter starts afresh.
    private func take(_ press: KeyPress, scrollingWith proxy: ScrollViewProxy) -> KeyPress.Result {
        guard articles.typesWithoutArticles else { return .ignored }
        guard Self.isTyping(press.characters, modifiers: press.modifiers) else {
            search = TitleTypingSearch()
            TitleTypingSpaceClaim.shared.release(in: window)
            return .ignored
        }
        // A held key types once; its repeats go nowhere.
        guard press.phase == .down else { return .handled }
        let now = TitleTypingSpaceClaim.clock()
        let interval = Self.interval
        let listed = rows()
        let inverted = articles.sortsWithoutArticles
        if press.characters == " " {
            // A Space reaches the list only while a title goes on with it,
            // which the shortcuts were told; at any other time it goes on as
            // it always has.
            guard search.isUnderWay(at: now, interval: interval),
                  TitleTyping.spaceGoesOn(after: search.typed, in: listed, showingInverted: inverted) else { return .ignored }
        }
        search.add(press.characters, at: now, interval: interval)
        if let row = TitleTyping.firstRow(reachedBy: search.typed, in: listed, showingInverted: inverted) {
            selection = [row]
            // SwiftUI's scroll also takes the selection to the table: on
            // GitHub's runner a row far down that the list had never drawn
            // stayed unselected in the table without it.
            proxy.scrollTo(row)
            reaches += 1
        }
        // A Space typed next joins the letters only while a title goes on
        // with them and a space.
        if TitleTyping.spaceGoesOn(after: search.typed, in: listed, showingInverted: inverted) {
            TitleTypingSpaceClaim.shared.claim(in: window, until: now + interval)
        } else {
            TitleTypingSpaceClaim.shared.release(in: window)
        }
        return .handled
    }

    /// Finishes scrolling the row typing reached into view, once the list
    /// has drawn it selected: through the Mac's table, by the heights its
    /// rows are drawn at. SwiftUI's `scrollTo`, and AppKit's own type select
    /// too, fall short of a row far down the Library list (on GitHub's
    /// runner, row 62 selected with rows 47 to 54 in view, and row 61 with
    /// rows 46 to 53), as if the rows not yet drawn were shorter than they
    /// are. So the table is looked at a moment after the scroll, and again
    /// after each scroll it makes, up to `scrollLooks` times, until the
    /// selected row shows whole. Only the Mac's list has letter navigation
    /// (on the iPhone, `LibraryViewModel.leadingArticles` is always the
    /// first choice), so elsewhere there is nothing to scroll.
    private func scrollSelectedRowIntoView() async {
        #if os(macOS)
        for _ in 0..<Self.scrollLooks {
            // Lets the list draw the selection, and the rows scrolled to.
            try? await Task.sleep(for: Self.scrollLookDelay)
            // The list has the keyboard while it is typed into, so its
            // table is the window's first responder.
            guard !Task.isCancelled, let table = window?.firstResponder as? NSTableView else { return }
            if Self.showsSelectedRow(of: table) { return }
        }
        #endif
    }

    /// How many times the table is looked at after a row is reached.
    static let scrollLooks = 4
    /// How long the list is given to draw before each look: about two
    /// frames.
    static let scrollLookDelay = Duration.milliseconds(30)

    #if os(macOS)
    /// Whether `table`'s selected row shows whole: if it does not, scrolls
    /// it into view and returns false, so the caller looks again once the
    /// rows scrolled to are drawn. With no row selected yet, as before
    /// SwiftUI has taken the selection to the table, it returns false too,
    /// so the caller looks again.
    static func showsSelectedRow(of table: NSTableView) -> Bool {
        let row = table.selectedRow
        guard row >= 0 else { return false }
        guard !rowShowsWhole(row, in: table) else { return true }
        table.scrollRowToVisible(row)
        return false
    }

    /// Whether all of `row`'s height is within what `table` shows: from
    /// top to bottom only, since a list scrolls up and down, so a row whose
    /// width the table draws past its edge still shows.
    static func rowShowsWhole(_ row: Int, in table: NSTableView) -> Bool {
        let drawn = table.rect(ofRow: row)
        let shown = table.visibleRect
        return drawn.minY >= shown.minY && drawn.maxY <= shown.maxY
    }
    #endif

    /// How long after one typed key the next still adds to the search, in
    /// seconds: AppKit's type select's own time on GitHub's runner, where
    /// letters 1.2 seconds apart added up and 1.3 seconds apart did not
    /// (trains 1113-0322 and 1113-0427).
    static let interval: TimeInterval = 1.25

    /// Whether `characters`, pressed with `modifiers`, are typing: one or
    /// more letters, numbers, punctuation marks, symbols, or spaces, with
    /// neither Command nor Control; never a control character, or a function
    /// key, which AppKit writes in the private-use area.
    nonisolated static func isTyping(_ characters: String, modifiers: EventModifiers) -> Bool {
        guard !characters.isEmpty, !modifiers.contains(.command), !modifiers.contains(.control) else { return false }
        return characters.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .privateUse, .surrogate, .unassigned, .format, .lineSeparator, .paragraphSeparator:
                return false
            default:
                return true
            }
        }
    }
}

// MARK: - A Space That Continues a Title

/// The Library window whose list is typing a title that goes on with a
/// space ("the h", "lord of"), until when, so a Space pressed there joins
/// the title rather than playing or pausing, as a Space typed into a
/// Finder window's type select does. The shortcut manager asks it before
/// it takes a Space (`KeyboardShortcutManager.handleKeyEvent`); the list's
/// letter navigation claims and releases it (`LibraryTitleTyping`).
@MainActor
final class TitleTypingSpaceClaim {
    /// The one claim the app's Library windows share.
    static let shared = TitleTypingSpaceClaim()

    /// The clock the list's letter navigation and its Space claim are both
    /// timed by, read as each key is handled, in seconds of system uptime;
    /// one clock, so the shortcut manager and the list never disagree on
    /// whether a Space came in time. A test sets its own, so nothing waits.
    static var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// The window claiming a Space, held weakly; nil for none.
    private weak var window: PlatformWindow?
    /// Until when, by `clock`.
    private var until: TimeInterval = 0

    /// Claims a Space pressed in `window` until `time`, for its list.
    func claim(in window: PlatformWindow?, until time: TimeInterval) {
        guard let window else { return }
        self.window = window
        until = time
    }

    /// Lets the Space go, if `window` claimed it.
    func release(in window: PlatformWindow?) {
        if let window, self.window === window {
            self.window = nil
        }
    }

    /// Whether a Space pressed in `window` at `time` continues a title its
    /// list is typing: that window claimed it, until `time` or later.
    func takesSpace(in window: PlatformWindow?, at time: TimeInterval) -> Bool {
        guard let window, let claimed = self.window, claimed === window else { return false }
        return time <= until
    }

    /// Whether a Space pressed in `window` now, by `clock`, continues a
    /// title its list is typing.
    func takesSpace(in window: PlatformWindow?) -> Bool {
        takesSpace(in: window, at: Self.clock())
    }
}
