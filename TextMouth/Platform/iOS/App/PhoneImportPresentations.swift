import SwiftUI

/// What the import slice presents over every screen: the Add to Library sheet,
/// the import questions, and the progress card. A stub for now, so that the
/// root view need not be edited again: the import slice fills this file.
struct PhoneImportPresentations: ViewModifier {
    /// The app's one model.
    let model: PhoneAppModel

    func body(content: Content) -> some View {
        content
    }
}

extension View {
    /// The import slice's presentations, over this view.
    func phoneImportPresentations(_ model: PhoneAppModel) -> some View {
        modifier(PhoneImportPresentations(model: model))
    }
}
