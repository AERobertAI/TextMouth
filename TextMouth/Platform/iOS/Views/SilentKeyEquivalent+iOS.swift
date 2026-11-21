// Phase 0 stand-in: the Mac's SilentKeyEquivalent takes a hardware key (such as Escape) anywhere in its window and runs an action; iOS draws nothing and answers no key yet.
import SwiftUI

/// A key that runs `action` when pressed. On the Mac it listens to the
/// keyboard in its whole window. On iOS it has the same shape, so the sheets
/// that put it in a `.background` compile, but it takes no key, takes no
/// space, and is no element to VoiceOver.
struct SilentKeyEquivalent: View {
    /// The key (ignored on iOS for now).
    let key: KeyEquivalent
    /// What pressing it does (never run on iOS for now).
    let action: () -> Void

    /// Draws nothing: an empty, zero-size view hidden from VoiceOver.
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}
