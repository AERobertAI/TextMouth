import SwiftUI

extension PhoneListFocus {
    /// Moves VoiceOver's focus to `row` of a list inside a `ScrollViewReader`:
    /// scrolls it into being, waits for the list to make it (`settleDelay`),
    /// then sets the focus state to nil and then to the row, since setting the
    /// value it already holds does nothing. The caller picks the row with
    /// `row(_:in:fallback:)`. Unverified until a first run: that 0.35 seconds
    /// is long enough for a long list.
    @MainActor
    static func focus<ID: Hashable & Sendable>(
        _ row: ID,
        proxy: ScrollViewProxy,
        state: AccessibilityFocusState<ID?>.Binding
    ) {
        proxy.scrollTo(row)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(settleDelay))
            state.wrappedValue = nil
            await Task.yield()
            state.wrappedValue = row
        }
    }
}
