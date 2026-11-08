import SwiftUI

/// Where every sheet puts its buttons, and how it names them: the one place
/// the placement is decided, so changing it back is one line.
///
/// **Why not `.cancellationAction` and `.confirmationAction`.** In the iOS
/// simulator's tests (iPhone 17, iOS 26), the buttons of those two placements
/// were the only toolbar buttons the tests did not find under their words:
/// Book Information's and the choice sheet's Cancel were missed, where Go To's
/// Cancel in `.topBarTrailing` was found. iOS 26 draws those two placements
/// itself, in its own glass style, and the tests did not find the word
/// "Cancel" in the tree. What the tree showed in its place is
/// **RECORDED BELOW** by `ToolbarPlacementProbeUITests`, which sets
/// `PhoneSheetButtonPlacement.probeVariable` so that this file uses
/// `.cancellationAction` again and the test reads the bar.
///
/// Every sheet's buttons are trailing, in the order the spec gives after the
/// title: Cancel (or Close, or Done), then the confirming button. Each is
/// given its label outright, so VoiceOver and braille say the spec's word
/// whatever the system draws.
enum PhoneSheetButtonPlacement {
    /// A launch environment variable, read in debug builds only, that makes
    /// every sheet button take `.cancellationAction`, so that a test can read
    /// what iOS shows for it. Set to "1".
    static let probeVariable = "TEXTMOUTH_PROBE_SYSTEM_PLACEMENT"

    /// The placement of every sheet button, and of any other button beside
    /// them in the bar (Bookmarks' Add).
    static var placement: ToolbarItemPlacement {
        #if DEBUG
        if ProcessInfo.processInfo.environment[probeVariable] == "1" {
            return .cancellationAction
        }
        #endif
        return .topBarTrailing
    }
}

/// One button of a sheet's bar, in `PhoneSheetButtonPlacement.placement`, its
/// words drawn at full contrast (`PhoneActionButton`) and its label given
/// outright. Used in a `.toolbar` in place of a `ToolbarItem` with a `Button`.
struct PhoneSheetButton: ToolbarContent {
    /// The button's words, and its label unless `label` is given.
    let title: String
    /// What VoiceOver and braille call it, when that is not `title`.
    var label: String?
    /// What VoiceOver says of what it does; none by default.
    var hint = ""
    /// Whether it can be pressed; a button that can't is dimmed.
    var isEnabled = true
    /// What pressing it does.
    let action: @MainActor () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: PhoneSheetButtonPlacement.placement) {
            PhoneActionButton(title: title, action: action)
                .accessibilityLabel(label ?? title)
                .accessibilityHint(hint)
                .disabled(!isEnabled)
        }
    }
}
