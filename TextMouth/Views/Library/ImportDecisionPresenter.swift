#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

// MARK: - Which Window Asks

extension ImportOrigin {
    /// The origin naming `window`; nil while the window is not known yet, or
    /// has never been shown and so has no number. Main actor only, as
    /// windows are.
    @MainActor
    init?(window: PlatformWindow?) {
        #if os(macOS)
        guard let window, window.windowNumber > 0 else { return nil }
        self.init(windowNumber: window.windowNumber)
        #else
        // Phase 0 iOS body: a UIKit window has no window number, so no
        // window is named yet (phase 1 names the scene's window).
        return nil
        #endif
    }
}

extension View {
    /// Asks the import questions (TODO I01) that the Library window `window`
    /// is to ask, one at a time in a sheet (`ImportDecisionPresenter`).
    func importDecisionSheet(
        for libraryViewModel: LibraryViewModel,
        in window: PlatformWindow?,
        router: LibraryWindowRouter = .shared
    ) -> some View {
        modifier(ImportDecisionPresenter(libraryViewModel: libraryViewModel, window: window, router: router))
    }
}

/// Shows a Library window's import questions (TODO I01).
///
/// Every Library window watches the one queue of questions, and exactly one
/// asks the question at its front: the window its import started in while
/// that window is open, or else the first open Library window
/// (`ImportDecisionQueue.askingWindow(for:among:)`). While that is this
/// window, it shows the question sheet. Answering a question shows the next
/// one in the same sheet, or closes the sheet when the next is asked
/// elsewhere or none is left.
struct ImportDecisionPresenter: ViewModifier {
    @ObservedObject var libraryViewModel: LibraryViewModel
    /// The Library window this modifier's view is in; nil until it is known.
    let window: PlatformWindow?
    /// Knows which Library windows are open, and in which order.
    let router: LibraryWindowRouter

    func body(content: Content) -> some View {
        content.sheet(isPresented: isAsking) {
            if let decision = libraryViewModel.importDecisions.current,
               let wording = libraryViewModel.currentImportDecisionWording {
                ImportDecisionSheet(
                    decision: decision,
                    wording: wording,
                    voiceOverDelay: ImportDecisionSheet.voiceOverFocusDelay(
                        position: libraryViewModel.importDecisions.position
                    ),
                    takesFocus: Self.userIsIn(window),
                    onAnswer: { answer in
                        // Off the main actor where the answer takes long.
                        await libraryViewModel.answerImportDecisionOffMain(decision.id, with: answer)
                    }
                )
                // Each question is a sheet's content of its own: its folder
                // name, failure, focus, and announcement start afresh.
                .id(decision.id)
            }
        }
    }

    /// Whether this window asks the current question. Only answering a
    /// question settles it, so the sheet's own dismissal, which no control
    /// asks for, changes nothing.
    private var isAsking: Binding<Bool> {
        Binding(get: { asksCurrentQuestion }, set: { _ in })
    }

    /// Whether a question is waiting and this window is the one to ask it.
    private var asksCurrentQuestion: Bool {
        guard let decision = libraryViewModel.importDecisions.current,
              let thisWindow = ImportOrigin(window: window) else { return false }
        let openWindows = router.registeredLibraryWindows.compactMap { ImportOrigin(window: $0) }
        return ImportDecisionQueue.askingWindow(for: decision.request.origin, among: openWindows) == thisWindow
    }

    /// Whether the user is in `window`, a Library window, or in the sheet
    /// it shows: TextMouth is the active app and one of them is key. A
    /// question that appears while the user is elsewhere, such as listening
    /// in a reader window when a background import finishes, waits in its
    /// sheet without taking focus or speaking over the reader.
    static func userIsIn(_ window: PlatformWindow?) -> Bool {
        #if os(macOS)
        guard PlatformApplication.isActive, let window else { return false }
        return window.isKeyWindow || window.attachedSheet?.isKeyWindow == true
        #else
        // Phase 0 iOS body: a UIKit window has no attached sheets to ask.
        return PlatformApplication.isActive && window?.isKeyWindow == true
        #endif
    }
}
