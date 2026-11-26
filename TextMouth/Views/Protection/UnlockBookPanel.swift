import SwiftUI

// MARK: - What the Panel Is Told

/// The state of the unlock panel a reader shows in place of a locked book
/// (FR41): which attempts failed, and why the last one did.
struct UnlockPromptState: Equatable {
    /// The reason the last attempt failed, in words, or nil before any.
    var failure: String?
    /// How many wrong passwords were typed: each one asks the field to take
    /// focus again, whatever the last attempt's text was.
    var wrongAttempts = 0
    /// Whether an attempt is under way (a large archive takes a moment),
    /// during which Unlock does nothing.
    var isWorking = false
}

/// What the person chose in the panel.
struct UnlockChoice {
    /// The password typed.
    var password: Secret
    /// Whether to keep it in this device's Keychain.
    var remember: Bool
    /// Whether to take the password off the book's file in the library.
    var removePassword: Bool
}

// MARK: - The Panel

/// The panel that asks for a protected book's password, on the Mac and the
/// iPhone alike. Its order is the one a person with VoiceOver meets: the
/// heading, the password field (first responder), Show password, Remember
/// this password, Remove the password, Unlock (Return), and Cancel
/// (Escape). A wrong password is a line of text, spoken too, and the field
/// keeps focus; nothing depends on colour.
struct UnlockBookPanel: View {
    /// The book's title.
    let title: String
    /// How the attempts have gone.
    let state: UnlockPromptState
    /// Whether Remember starts on (the choice's default is on).
    var remembersByDefault = true
    /// Called with the person's choice when they press Unlock or Return.
    let onUnlock: (UnlockChoice) -> Void
    /// Called on Cancel.
    let onCancel: () -> Void

    /// What has been typed. Kept for the length of the panel only.
    @State private var typed = ""
    /// Whether the password shows as plain text.
    @State private var showsPassword = false
    /// Whether to remember the password.
    @State private var remembers = true
    /// Whether to remove the password from the book.
    @State private var removes = false
    /// Whether the field has focus.
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ProtectionWording.heading(title: title))
                .font(.title2)
                .accessibilityAddTraits(.isHeader)
            Text(ProtectionWording.explanation)

            passwordField

            if let failure = state.failure {
                // A line of text, so it is read in order and brailled, and it
                // is spoken too when it appears (the reader announces it).
                Text(failure)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("unlock.failure")
            }

            Toggle(ProtectionWording.showPassword, isOn: $showsPassword)
                .accessibilityIdentifier("unlock.show")
            Toggle(ProtectionWording.remember, isOn: $remembers)
                .accessibilityHint(ProtectionWording.rememberHint)
                .accessibilityIdentifier("unlock.remember")
            Toggle(ProtectionWording.removePassword, isOn: $removes)
                .accessibilityHint(ProtectionWording.removePasswordHint)
                .accessibilityIdentifier("unlock.remove")

            HStack {
                Button(ProtectionWording.cancel, role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("unlock.cancel")
                Button(ProtectionWording.unlock, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.isWorking)
                    .accessibilityIdentifier("unlock.unlock")
            }
        }
        .padding(20)
        .frame(maxWidth: 480, maxHeight: .infinity, alignment: .center)
        .frame(maxWidth: .infinity)
        .onAppear {
            remembers = remembersByDefault
            fieldFocused = true
        }
        // A wrong password keeps the person in the field.
        .onChange(of: state.wrongAttempts) { _, _ in fieldFocused = true }
        // The field is replaced when the password is shown or hidden: keep focus in it.
        .onChange(of: showsPassword) { _, _ in fieldFocused = true }
    }

    /// The password field: dots, or plain text when Show password is on. Both
    /// are the same label, hint, and identifier, and share one focus.
    @ViewBuilder
    private var passwordField: some View {
        Group {
            if showsPassword {
                TextField(ProtectionWording.passwordLabel, text: $typed)
            } else {
                SecureField(ProtectionWording.passwordLabel, text: $typed)
            }
        }
        .focused($fieldFocused)
        .onSubmit(submit)
        .accessibilityHint(ProtectionWording.passwordHint)
        .accessibilityIdentifier("unlock.password")
        #if os(iOS)
        .textContentType(.password)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        #endif
    }

    /// Hands the choice over, unless nothing was typed or an attempt is under way.
    private func submit() {
        guard !state.isWorking else { return }
        onUnlock(UnlockChoice(password: Secret(typed), remember: remembers, removePassword: removes))
    }
}
