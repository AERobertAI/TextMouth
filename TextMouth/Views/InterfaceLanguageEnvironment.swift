import SwiftUI

/// Makes a window's whole view tree follow the interface language (FR39): its formatters, its `Text(date, style:)`, and,
/// for a right-to-left language, its layout.
///
/// One modifier on each window's root. Its body reads `InterfaceLanguage.current`, which registers a dependency, so a
/// switch of language runs this body again and sets the new environment, while the views below keep their identity:
/// focus, selection, and scroll position stay.
struct InterfaceLanguageEnvironment: ViewModifier {
    func body(content: Content) -> some View {
        let state = InterfaceLanguage.current
        content
            .environment(\.locale, state.locale)
            .environment(\.layoutDirection, state.layoutDirection)
    }
}

extension InterfaceLanguage.State {
    /// SwiftUI's layout direction for the language: right to left for Arabic, Hebrew, Persian, and Urdu.
    var layoutDirection: LayoutDirection {
        isRightToLeft ? .rightToLeft : .leftToRight
    }
}

extension View {
    /// Sets this view's locale and layout direction from the interface language, and again whenever the language
    /// changes. Put it on the root of every window.
    func followsInterfaceLanguage() -> some View {
        modifier(InterfaceLanguageEnvironment())
    }
}
