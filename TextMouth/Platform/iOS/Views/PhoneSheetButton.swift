import SwiftUI

/// Where every sheet puts its buttons, and how it names them: the one place
/// the placement is decided, so changing it back is one line.
///
/// **Why not `.cancellationAction` and `.confirmationAction`.** In the iOS
/// simulator's tests (iPhone 17, iOS 26), Book Information's and the choice
/// sheet's Cancel were reported missing, where Go To's Cancel, in
/// `.topBarTrailing`, was found. A probe test put every button back in
/// `.cancellationAction` and read the sheet's tree on November 8, 2026 (the
/// probe has since been removed; the history keeps it). **What it showed:** the
/// buttons are there, as ordinary buttons labeled "Cancel" and "Save" (the
/// labels this file gives; the probe did not try them without), with no
/// identifier, drawn as text pills (66 and 51 points wide, 36 tall) and not as
/// an xmark, and not "Close". **What was wrong was their place in the order:**
/// they come *before* the title, in the tree as in the bar ("Cancel, Save,
/// Book Information"), because those placements are the bar's leading side.
/// The spec's order is the title, then Cancel, then the confirm button, and the
/// tests read a sheet from its title on, so they found no Cancel after it.
/// `.topBarTrailing` puts the title first, as the other sheets already did.
///
/// Every sheet's buttons are trailing, in the order the spec gives after the
/// title: Cancel (or Close, or Done), then the confirming button. Each is
/// given its label outright, so VoiceOver and braille say the spec's word
/// whatever the system draws.
enum PhoneSheetButtonPlacement {
    /// The placement of every sheet button, and of any other button beside
    /// them in the bar (Bookmarks' Add). Changing it back is this one line.
    static let placement: ToolbarItemPlacement = .topBarTrailing
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
