import SwiftUI
import UIKit

/// One of the reader's controls: a small UIKit button in the SwiftUI layout
/// (the spec, under "Why the reader's controls are UIKit views"; the
/// engineering review's F15).
///
/// In UIKit a control's words can be computed at the moment VoiceOver asks,
/// and adjusting changes state synchronously, so VoiceOver reads the new value
/// and not the old. A SwiftUI value updates only with a redraw, later than
/// VoiceOver's read. So every accessibility getter here asks `describe` when
/// VoiceOver asks, and nothing is pushed as the book plays.
///
/// Nothing here has run on iOS. Unverified, and on the hand-check list: what
/// VoiceOver says after an adjustment with an empty value while the book
/// plays, and that VoiceOver follows the column's order.
struct PhoneControl: UIViewRepresentable {
    /// What VoiceOver reads of the control now, asked at each read.
    let describe: @MainActor () -> PhoneControlDescription?
    /// What activating the control does. Nil leaves activation to UIKit,
    /// which does nothing for a control with no action.
    var activate: (@MainActor () -> Void)?
    /// What adjusting up does, for an adjustable control.
    var increment: (@MainActor () -> Void)?
    /// What adjusting down does.
    var decrement: (@MainActor () -> Void)?
    /// What each of its custom actions does.
    var perform: (@MainActor (PhoneControlAction) -> Void)?
    /// The kind `PhoneFocusRegistry` knows it by, for focus on arrival and on
    /// a sheet's return; nil for none.
    var focusKind: PhoneControlKind?
    /// Whether the visible title shows the value too, as Navigation unit and
    /// Speed do for a sighted helper: VoiceOver reads the words from
    /// `describe` either way.
    var showsValue = false

    func makeUIView(context: Context) -> PhoneControlButton {
        let button = PhoneControlButton()
        update(button)
        return button
    }

    func updateUIView(_ button: PhoneControlButton, context: Context) {
        update(button)
    }

    /// Gives `button` this control's closures, registers it for focus, and
    /// refreshes its visible title.
    private func update(_ button: PhoneControlButton) {
        button.describe = describe
        button.activate = activate
        button.increment = increment
        button.decrement = decrement
        button.perform = perform
        button.showsValue = showsValue
        if let focusKind {
            PhoneFocusRegistry.shared.register(button, as: focusKind)
        }
        button.refreshTitle()
    }

    /// The button's height for the width offered: its title wrapped to that
    /// width, so large text grows the control rather than cutting it off.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PhoneControlButton, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.intrinsicContentSize.width
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(fitted.height, PhoneControlButton.minimumHeight))
    }
}

/// The UIKit button under a `PhoneControl`. Its accessibility getters each ask
/// `describe` when VoiceOver asks, so the words are always the moment's.
final class PhoneControlButton: UIButton {
    /// The height below which a control is too small to find by touch:
    /// Apple's 44 points.
    static let minimumHeight: CGFloat = 44

    /// What VoiceOver reads of the control now.
    var describe: @MainActor () -> PhoneControlDescription? = { nil }
    /// What activating it does.
    var activate: (@MainActor () -> Void)?
    /// What adjusting up does.
    var increment: (@MainActor () -> Void)?
    /// What adjusting down does.
    var decrement: (@MainActor () -> Void)?
    /// What each custom action does.
    var perform: (@MainActor (PhoneControlAction) -> Void)?
    /// Whether the visible title shows the value too.
    var showsValue = false

    /// A plain, large button whose title wraps and follows the text size.
    init() {
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.gray()
        configuration.titleLineBreakMode = .byWordWrapping
        configuration.titleAlignment = .center
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .headline)
            return attributes
        }
        self.configuration = configuration
        titleLabel?.adjustsFontForContentSizeCategory = true
        titleLabel?.numberOfLines = 0
        isAccessibilityElement = true
        // A touch without VoiceOver activates it, as for a sighted helper or
        // Voice Control.
        addTarget(self, action: #selector(pressed), for: .primaryActionTriggered)
    }

    /// Not made from a storyboard: the reader builds its controls in code.
    required init?(coder: NSCoder) {
        return nil
    }

    /// A touch's press, without VoiceOver: the control's action.
    @objc private func pressed() {
        activate?()
        refreshTitle()
    }

    /// Sets the visible title from the moment's words: the label, and the
    /// value too where `showsValue` says. It's for sight alone: VoiceOver
    /// reads the getters below, so setting it pushes nothing to VoiceOver.
    func refreshTitle() {
        guard let description = describe() else { return }
        let title = showsValue && !description.value.isEmpty
            ? "\(description.label): \(description.value)"
            : description.label
        if configuration?.title != title {
            configuration?.title = title
        }
    }

    // MARK: - What VoiceOver Reads, When It Asks

    override var accessibilityLabel: String? {
        get { describe()?.label }
        set {}
    }

    override var accessibilityValue: String? {
        get { describe()?.value.nonBlank }
        set {}
    }

    override var accessibilityHint: String? {
        get { describe()?.hint.nonBlank }
        set {}
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get { Self.traits(for: describe()?.traits ?? .button) }
        set {}
    }

    /// The control's actions on the Actions rotor, made when asked; none for
    /// most controls, so VoiceOver doesn't say "Actions available".
    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            guard let actions = describe()?.actions, !actions.isEmpty else { return nil }
            return actions.map { action in
                UIAccessibilityCustomAction(name: action.name) { [weak self] _ in
                    self?.perform?(action)
                    return true
                }
            }
        }
        set {}
    }

    // MARK: - What VoiceOver Does

    /// Activating: the control's action, done now, so the words VoiceOver
    /// reads next are the new ones. Apple's documentation: return true when
    /// the element handled the activation.
    override func accessibilityActivate() -> Bool {
        guard let activate else { return false }
        activate()
        refreshTitle()
        return true
    }

    /// Adjusting up: done at once, so VoiceOver reads the new value.
    override func accessibilityIncrement() {
        increment?()
        refreshTitle()
    }

    /// Adjusting down.
    override func accessibilityDecrement() {
        decrement?()
        refreshTitle()
    }

    /// UIKit's traits for the phone's plain ones.
    static func traits(for traits: PhoneControlTraits) -> UIAccessibilityTraits {
        var mapped: UIAccessibilityTraits = []
        if traits.contains(.button) { mapped.insert(.button) }
        if traits.contains(.adjustable) { mapped.insert(.adjustable) }
        if traits.contains(.startsMediaSession) { mapped.insert(.startsMediaSession) }
        if traits.contains(.staticText) { mapped.insert(.staticText) }
        return mapped
    }
}
