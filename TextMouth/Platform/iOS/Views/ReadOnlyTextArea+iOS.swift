// Phase 0 stand-in: the Mac's ReadOnlyTextArea wraps an NSTextView in a
// scroll view so VoiceOver reads it as a text area (lines, words, letters,
// selection, copying, no typing). This is its iOS twin with the same name
// and initializer: a read-only, selectable UITextView whose text and label
// VoiceOver reads. Phase 1 decides on further iPhone behavior.
import SwiftUI
import UIKit

/// A read-only text VoiceOver reads as a text area (iOS twin of the Mac's
/// `ReadOnlyTextArea`). Used by Feed Info's description, Show Description…,
/// and the reader's speech refusal report.
struct ReadOnlyTextArea: UIViewRepresentable {
    /// The text.
    let text: String
    /// The text area's spoken label.
    let label: String
    /// Whether VoiceOver is moved to the text as it appears.
    var takesFocus = false

    /// Builds the read-only, selectable text view.
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        // Follow the user's Dynamic Type size.
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        textView.text = text
        // One element for VoiceOver, spoken with the same label as the Mac.
        textView.isAccessibilityElement = true
        textView.accessibilityLabel = label
        if takesFocus {
            // The Mac makes the text view the first responder once it is in
            // its window, after the sheet's own animation. iOS has no
            // first-responder focus for VoiceOver, so the equivalent is a
            // screen-changed notification naming the text view, posted with
            // the same 0.2 second delay and a weak reference.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak textView] in
                guard let textView, textView.window != nil else { return }
                UIAccessibility.post(notification: .screenChanged, argument: textView)
            }
        }
        return textView
    }

    /// Keeps the text view's text and label current.
    func updateUIView(_ textView: UITextView, context: Context) {
        // Assign the text only when it changed, so selection is not reset.
        if textView.text != text {
            textView.text = text
        }
        textView.accessibilityLabel = label
    }
}
