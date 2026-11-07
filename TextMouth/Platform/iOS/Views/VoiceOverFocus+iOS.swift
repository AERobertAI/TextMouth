// Phase 0 stand-in: the Mac's TextMouth/Platform/macOS/Views/VoiceOverFocus.swift
// places VoiceOver's focus in a new window or sheet by searching AppKit's
// accessibility tree for the element marked `voiceOverFocusID` and posting a
// focus change to it. iOS does nothing of the kind yet: every name the shared
// views use is declared here with the same signature, the triggers draw
// nothing and move no focus, and the marking modifier only sets the
// identifier. Phase 1 does real iPhone focus (SwiftUI's AccessibilityFocusState).

import SwiftUI
import UIKit

/// The accessibility identifier placed on the SwiftUI element that should
/// receive VoiceOver focus; the same string as on the Mac.
let voiceOverFocusID = "vo-focus-target"

/// Writes a VoiceOver focus line to the debug log while tracing is on, as the
/// Mac does; the message is built only then.
func voiceOverFocusLog(_ message: @autoclosure () -> String) {
    DiagnosticLog.trace(.focus, message())
}

extension PlatformWindow {
    /// Whether this window still shows content a waiting focus request could
    /// search: a root view controller whose view has subviews. (The Mac asks
    /// the same of its content view.)
    var hasContentForVoiceOverFocus: Bool {
        guard let rootView = rootViewController?.view else { return false }
        return !rootView.subviews.isEmpty
    }
}

/// The trigger the play button and similar standard targets put in their
/// background. On the Mac it places focus after `delay`; on iOS it is an
/// invisible, hidden view that does nothing yet.
struct StandardVoiceOverFocus: View {
    var delay: TimeInterval = 0.8

    /// Draws nothing, and is hidden from VoiceOver so nothing new is heard.
    var body: some View {
        Color.clear.accessibilityHidden(true)
    }
}

/// The trigger a sheet puts in its background. On the Mac it places focus on
/// the marked element after `delay`; on iOS it is an invisible, hidden view
/// that does nothing yet.
struct VoiceOverFocus: View {
    var delay: TimeInterval = 1.2

    /// Draws nothing, and is hidden from VoiceOver so nothing new is heard.
    var body: some View {
        Color.clear.accessibilityHidden(true)
    }
}

/// Marks the one element of a view that should take VoiceOver's focus first.
/// On the Mac a trigger view then moves focus after `delay`; on iOS only the
/// identifier is set (`isTarget`), and `delay` is unused until phase 1.
struct InitialVoiceOverFocusModifier: ViewModifier {
    let isTarget: Bool
    var delay: TimeInterval = 1.2

    /// Sets `voiceOverFocusID` on the target; any other element is unchanged.
    @ViewBuilder
    func body(content: Content) -> some View {
        if isTarget {
            content.accessibilityIdentifier(voiceOverFocusID)
        } else {
            content
        }
    }
}

/// The Mac's AppKit view that finds the marked element in a window and puts
/// focus on it. On iOS it is a plain class with the same entry points, which
/// shared code (SwitchedWindowFocus, FeedDownloadProgressSection) calls and
/// which find and place nothing yet.
@MainActor
final class StandardVoiceOverFocusTriggerView {
    init() {}

    /// How many times focus has been posted to `window`. The Mac counts its
    /// posts; iOS posts none, so the count is always 0.
    static func focusPostCount(of window: PlatformWindow) -> Int { 0 }

    /// The element in `window` marked with `voiceOverFocusID`. The Mac
    /// searches the accessibility tree; iOS finds nothing yet (nil).
    func findMarkedElement(in window: PlatformWindow) -> Any? { nil }

    /// Puts VoiceOver's focus on `target`, found in `window`. The Mac posts
    /// the focus change; iOS does nothing yet.
    static func placeFocus(on target: Any, in window: PlatformWindow) {}

    /// Finds the marked element in `window` and focuses it, retrying as the
    /// Mac does. iOS does nothing yet.
    static func staticFindAndFocus(in window: PlatformWindow) {}
}
