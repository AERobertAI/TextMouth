import AppKit
import SwiftUI

/// A text VoiceOver reads as a text area (FR03): its lines, words, and
/// letters reached with VoiceOver's text navigation and the arrow keys,
/// which also move its insertion point, and shown on a braille display as
/// they are, with selection and copying, but no typing. AppKit's text view
/// gives all of that, where a SwiftUI text gives a single static element.
/// Used by Feed Info's description, Show Description…, and the reader's
/// speech refusal report.
struct ReadOnlyTextArea: NSViewRepresentable {
    /// The text.
    let text: String
    /// The text area's spoken label.
    let label: String
    /// Whether the text takes keyboard focus as it appears, so VoiceOver
    /// starts in it.
    var takesFocus = false

    /// Builds the scrolling, read-only text view.
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.font = .preferredFont(forTextStyle: .body)
            textView.textContainerInset = NSSize(width: 6, height: 6)
            textView.string = text
            textView.setAccessibilityLabel(label)
            if takesFocus {
                // Once the text view is in its window, after the sheet's
                // own animation.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak textView] in
                    guard let textView, let window = textView.window else { return }
                    window.makeFirstResponder(textView)
                    textView.setSelectedRange(NSRange(location: 0, length: 0))
                }
            }
        }
        return scrollView
    }

    /// Keeps the text view's text and label current.
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.setAccessibilityLabel(label)
    }
}
