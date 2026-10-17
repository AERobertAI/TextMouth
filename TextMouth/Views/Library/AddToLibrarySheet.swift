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
// MARK: - The Sheet

/// The Add to Library sheet (FR20): a heading, one button for each way to
/// add (`AddToLibraryChoice.allCases`), each with its summary under it, and
/// Cancel. Tab and Space reach every button, Escape presses Cancel, and each
/// choice is one button for VoiceOver, spoken with its key and its summary
/// as the hint.
struct AddToLibrarySheet: View {
    @ObservedObject var model: AddToLibraryModel
    /// A choice's key in words, nil for none (`AddToLibraryChoice.keyDescription(under:)`).
    let keyDescription: (AddToLibraryChoice) -> String?

    /// The sheet's fixed size. A view that outgrows its hosting window
    /// crashes the test host, and five rows with a heading and Cancel fit
    /// this height, so nothing needs to scroll.
    private static let width: CGFloat = 420
    private static let height: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AddToLibraryWording.sheetTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            ForEach(AddToLibraryChoice.allCases) { choice in
                choiceButton(choice)
            }

            HStack {
                Spacer()
                Button(AddToLibraryWording.cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .navigationTitle(AddToLibraryWording.sheetTitle)
    }

    /// One choice's button: its title (and key) with the summary under it in
    /// a smaller, secondary style, as a single element for VoiceOver, dimmed
    /// where its menu command does not work. The first takes VoiceOver's
    /// initial focus, as the other sheets' first control does.
    private func choiceButton(_ choice: AddToLibraryChoice) -> some View {
        let key = keyDescription(choice)
        let enabled = model.isEnabled(choice)
        return Button {
            model.choose(choice)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(choice.title)
                    if let key {
                        Spacer()
                        Text(key).foregroundStyle(.secondary)
                    }
                }
                Text(choice.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .accessibilityLabel(AddToLibraryWording.label(choice, key: key))
        .accessibilityHint(enabled ? AddToLibraryWording.summary(choice) : AddToLibraryWording.unavailableHint(choice))
        .modifier(InitialVoiceOverFocusModifier(isTarget: choice == AddToLibraryChoice.allCases.first))
    }
}
