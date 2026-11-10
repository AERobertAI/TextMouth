import AppKit

/// What TextMouth shows and says while it finishes work before it quits
/// (`QuitFinisher`): a small panel in plain words, and the same words
/// announced through VoiceOver, so a listener who pressed Command-Q hears
/// what is happening instead of a silent app that seems not to have quit.
/// A second request to quit shows and says the words again.
@MainActor
final class QuitNotice {
    /// The app's notice.
    static let shared = QuitNotice()

    /// The panel, while it is up.
    private var panel: NSPanel?
    /// The panel's text, to change when the words are said again.
    private var label: NSTextField?

    /// Shows `message` in the panel, bringing it forward without taking the
    /// keyboard from the window the person is in, and announces it through
    /// VoiceOver from the panel, which is a window to post from even when
    /// every other window is closed.
    func show(_ message: String) {
        let panel = self.panel ?? makePanel()
        // The label is static text VoiceOver reads in the panel; the
        // window's title, "Quitting TextMouth", names it.
        label?.stringValue = message
        panel.orderFrontRegardless()
        VoiceOverAnnouncer.announce(message, from: panel)
    }

    /// Takes the panel down, once the work has ended.
    func dismiss() {
        panel?.orderOut(nil)
    }

    /// Whether the panel is on screen.
    var isShowing: Bool {
        panel?.isVisible ?? false
    }

    /// Builds the panel: a titled utility window, with no close button since
    /// the work cannot be skipped, holding the message as wrapped text.
    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 110),
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = QuitHoldWording.title
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let label = NSTextField(wrappingLabelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isSelectable = true
        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            content.widthAnchor.constraint(equalToConstant: 420),
        ])
        panel.contentView = content
        panel.center()

        self.panel = panel
        self.label = label
        return panel
    }
}
