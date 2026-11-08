import UIKit

/// The views of the reader's controls, by kind, so that focus can be posted to
/// one (`UIAccessibility.post(notification:argument:)` wants the view) and a
/// landing can be told for what it is. Each control registers its view in its
/// `makeUIView`. Views are held weakly: a screen that goes takes its views.
@MainActor
final class PhoneFocusRegistry {
    /// The app's one registry: the reader's screen is shown once at a time.
    static let shared = PhoneFocusRegistry()

    /// A view held without keeping it.
    private final class WeakView {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }

    /// Each control's view.
    private var views: [PhoneControlKind: WeakView] = [:]

    /// Keeps `view` as the view of the control `kind`, in place of any before.
    func register(_ view: UIView, as kind: PhoneControlKind) {
        views[kind] = WeakView(view)
    }

    /// The view of the control `kind`, while it exists.
    func view(for kind: PhoneControlKind) -> UIView? {
        views[kind]?.view
    }

    /// Which control the element with identity `id` is, as VoiceOver reports
    /// a landing on it; nil for anything else, such as the Back button or the
    /// title. Taken by identity because that's what crosses from the
    /// notification's queue to the main actor (an `ObjectIdentifier` is
    /// Sendable, a view isn't).
    func kind(ofElementWithID id: ObjectIdentifier?) -> PhoneControlKind? {
        guard let id else { return nil }
        return views.first { $0.value.view.map(ObjectIdentifier.init) == id }?.key
    }
}
