import SwiftUI

/// What the life-cycle slice does at launch over the root view: opening the
/// book open when the app last ended (`PhoneSession.takeReopeningAtLaunch`),
/// pushing its reader's screen when it was showing, and saying, with low
/// priority, that a book which closed the app while opening was not reopened.
/// A stub for now, so that the root view need not be edited again: the
/// life-cycle slice fills this file.
struct PhoneReopeningModifier: ViewModifier {
    /// The app's one model.
    let model: PhoneAppModel

    func body(content: Content) -> some View {
        content
    }
}

extension View {
    /// The life-cycle slice's reopening at launch, over this view.
    func phoneReopening(_ model: PhoneAppModel) -> some View {
        modifier(PhoneReopeningModifier(model: model))
    }
}
