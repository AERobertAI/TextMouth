import SwiftUI

// MARK: - The Model

/// What the Add to Library sheet asks of its owner (FR20): which choices work
/// in the window the sheet is in, and how to run one.
///
/// A choice runs only after the sheet has gone. The sheet's buttons call
/// `choose(_:)`, which closes the sheet and remembers the choice; the owner
/// passes `sheetDidDismiss` as `onDismiss` of
/// `.sheet(isPresented: $model.isPresented, onDismiss:)`, and that runs the
/// choice, once. A sheet the choice opens (New from Text, Add Feed), or the
/// file panel Open Book… shows, would be refused by SwiftUI while this sheet
/// was still closing (the library window's Move sheet waits for its
/// `onDismiss` for the same reason). Cancel and Escape close the sheet and
/// run nothing.
@MainActor
final class AddToLibraryModel: ObservableObject {
    /// Whether the sheet is showing; the owner binds its sheet to this.
    @Published var isPresented = false

    /// Whether `choice`'s menu command works in the window the sheet is in.
    let isEnabled: (AddToLibraryChoice) -> Bool
    /// Runs `choice`, the same code its menu item runs; called once the
    /// sheet has gone.
    private let perform: (AddToLibraryChoice) -> Void
    /// The choice made, waiting for the sheet to finish closing.
    private var pending: AddToLibraryChoice?

    init(isEnabled: @escaping (AddToLibraryChoice) -> Bool, perform: @escaping (AddToLibraryChoice) -> Void) {
        self.isEnabled = isEnabled
        self.perform = perform
    }

    /// Makes `choice` and closes the sheet; the choice runs in
    /// `sheetDidDismiss()`. A choice that does not work here is ignored. A
    /// second choice before the sheet has gone takes the first one's place.
    func choose(_ choice: AddToLibraryChoice) {
        guard isEnabled(choice) else { return }
        pending = choice
        isPresented = false
    }

    /// Closes the sheet and runs nothing, even for a choice made before.
    func cancel() {
        pending = nil
        isPresented = false
    }

    /// The sheet has gone: runs the choice made, if any, exactly once.
    func sheetDidDismiss() {
        guard let choice = pending else { return }
        pending = nil
        perform(choice)
    }
}

// MARK: - The Menu Commands' Rules

@MainActor
extension AddToLibraryChoice {
    /// Whether the choice works while a window of `kind` is in front, nil
    /// meaning no window: the rule its menu item follows
    /// (`menuCommandKey`, FR12's branch E).
    func isEnabled(under shortcuts: KeyboardShortcutManager, in kind: ShortcutWindowKind?) -> Bool {
        shortcuts.scope(of: action).admitsMenuCommand(in: kind)
    }

    /// The choice's key in force, in words ("Command + O"), or nil for none:
    /// the key its menu item shows.
    func keyDescription(under shortcuts: KeyboardShortcutManager) -> String? {
        shortcuts.keyEquivalent(for: action)?.accessibleDisplayString
    }
}
