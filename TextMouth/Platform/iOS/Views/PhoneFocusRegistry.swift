import UIKit

/// The views of the reader's controls, by kind, so that focus can be posted to
/// one (`UIAccessibility.post(notification:argument:)` wants the view) and a
/// landing can be told for what it is. Each control registers its view in its
/// `makeUIView`. Views are held weakly: a screen that goes takes its views.
///
/// It also keeps the reader's delayed requests for focus, and cancels them as
/// VoiceOver lands on one of the reader's controls (`PhoneFocusRequests`).
@MainActor
final class PhoneFocusRegistry {
    /// The app's one registry: the reader's screen is shown once at a time.
    static let shared = PhoneFocusRegistry()

    /// The delayed requests for focus that are waiting, and the rule that a
    /// landing on a control cancels them.
    private var requests = PhoneFocusRequests()
    /// The observer of VoiceOver's landings, kept for the registry's life.
    private var focusObserver: NSObjectProtocol?

    private init() {
        // Told on the main queue, then claims the main actor; only the
        // element's identity crosses, which is Sendable. Every landing is
        // heard, whoever or whatever caused it: `PhoneFocusRequests` decides
        // which of them cancel a request.
        focusObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.elementFocusedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let landed = (notification.userInfo?[UIAccessibility.focusedElementUserInfoKey] as? NSObject)
                .map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.requests.focusLanded(on: self.kind(ofElementWithID: landed))
            }
        }
    }

    /// Asks for VoiceOver's focus to go to the control `kind`, by a layout
    /// change with its view as the argument, after `delay` seconds. Cancelled
    /// if VoiceOver lands on one of the reader's controls in the meantime,
    /// since that is the listener's move and must not be pulled back, or if
    /// `skip` answers true when the time comes. Does nothing if the control
    /// has no view then.
    func requestFocus(on kind: PhoneControlKind, after delay: TimeInterval, unless skip: @escaping @MainActor () -> Bool = { false }) {
        let ticket = requests.request()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                // Claimed first, so a request that is skipped is spent too.
                guard let self, self.requests.claim(ticket), !skip() else { return }
                guard let view = self.view(for: kind) else { return }
                UIAccessibility.post(notification: .layoutChanged, argument: view)
            }
        }
    }

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
