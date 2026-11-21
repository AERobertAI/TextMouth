import SwiftUI

/// What the life-cycle slice does at launch over the root view: at the app's
/// first activation, it opens again the book open when the app last ended,
/// pushing its reader's screen when it was showing, and then says the book's
/// title with low priority, after Play, where the reader's screen puts focus
/// as it arrives; or it says, with low priority, that a book which closed the
/// app while opening was not reopened (`PhoneLifeCycle.reopenAtLaunch(in:)`).
///
/// At the first activation, not as the view appears: the scene delegate shows
/// the window before it hands the life cycle the files a launch was for, and a
/// file opened at launch wins over reopening. Once for the process: a scene
/// that connects again shows a new root view over the same model.
///
/// It also joins the life cycle's iOS work at the first appearance
/// (`PhoneBackgroundWork.install(on:)`), which does nothing a second time.
struct PhoneReopeningModifier: ViewModifier {
    /// The app's one model.
    let model: PhoneAppModel

    func body(content: Content) -> some View {
        content.onAppear {
            PhoneBackgroundWork.install(on: model)
            PhoneReopeningAtLaunch.arm(model)
        }
    }
}

/// Reopening at launch, once for the process.
@MainActor
private enum PhoneReopeningAtLaunch {
    /// Whether reopening has been armed: it is armed once.
    private static var isArmed = false
    /// Whether reopening has run: it runs once, though the life cycle keeps
    /// its handler for every activation after.
    private static var hasRun = false

    /// Runs the reopening at the first activation: now, if the app has become
    /// active already, or when it does.
    static func arm(_ model: PhoneAppModel) {
        guard !isArmed else { return }
        isArmed = true
        guard !model.lifeCycle.hasBecomeActive else {
            reopen(model)
            return
        }
        model.lifeCycle.onDidBecomeActive { [weak model] in
            guard let model else { return }
            PhoneReopeningAtLaunch.reopen(model)
        }
    }

    /// Reopens, once, and says what it says with low priority, after the
    /// reader's screen has put focus on Play: `PhoneLifeCycle.wordsDelay`, then
    /// the announcer's own short wait.
    private static func reopen(_ model: PhoneAppModel) {
        guard !hasRun else { return }
        hasRun = true
        let reopened = model.lifeCycle.reopenAtLaunch(in: model)
        guard let words = reopened.lowPriorityWords else { return }
        PhoneAnnouncer.schedule(PhoneLifeCycle.wordsDelay) {
            PhoneAnnouncer.say(words)
        }
    }
}

extension View {
    /// The life-cycle slice's reopening at launch, over this view.
    func phoneReopening(_ model: PhoneAppModel) -> some View {
        modifier(PhoneReopeningModifier(model: model))
    }
}
