import SwiftUI

/// The phone's Go To sheet (the iPhone interface spec, "The Go To sheet"):
/// the Mac's three jump panels in one sheet, Page, Percent, and Time, each a
/// field with its own Jump, with focus landing in Page, or in an audiobook's
/// time, its text selected so typing replaces it.
///
/// Thin over `PhoneGoToModel`, which holds the words and the Mac's rule for
/// taking a field; the jumps are the reader's own.
struct PhoneGoToSheet: View {
    /// The reader the sheet jumps.
    let reader: ReaderViewModel
    /// What the sheet leaves to say once it has closed.
    let farewell: PhoneSheetFarewell
    /// Tells the session the book was moved here, so it counts as opened
    /// (`PhoneReaderModel.noteJumped`).
    let noteJumped: @MainActor () -> Void

    /// What the sheet offers, and the refusals it shows.
    @State private var model: PhoneGoToModel
    /// What each field holds.
    @State private var texts: [PhoneGoToField: String]
    /// Each field's selection, so the field focus lands in starts selected.
    @State private var selections: [PhoneGoToField: TextSelection] = [:]
    /// The field holding the keyboard.
    @FocusState private var keyboardField: PhoneGoToField?
    /// The field VoiceOver's focus is asked to land in.
    @AccessibilityFocusState private var voiceOverField: PhoneGoToField?
    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss

    /// A sheet over `reader`, farewell words kept in `farewell`.
    init(reader: ReaderViewModel, farewell: PhoneSheetFarewell, noteJumped: @escaping @MainActor () -> Void) {
        self.reader = reader
        self.farewell = farewell
        self.noteJumped = noteJumped
        let model = PhoneGoToModel(reader: reader)
        _model = State(initialValue: model)
        _texts = State(initialValue: model.startingTexts)
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(model.fields, id: \.self) { field in
                    fieldSection(field)
                }
            }
            .navigationTitle(PhoneGoToModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                PhoneSheetButton(title: PhoneAppWording.cancel) { dismiss() }
            }
            .task {
                await focusOpeningField()
            }
        }
    }

    /// One field, its refusal under it when it has one, and its Jump.
    ///
    /// The keyboard is numbers and punctuation, which has a Go key, unlike a
    /// decimal pad; Go takes the field as Jump does (the spec).
    @ViewBuilder
    private func fieldSection(_ field: PhoneGoToField) -> some View {
        Section {
            // No prompt: a long one ("Percent through the book") was found
            // clipped at large sizes by the audit. The name is shown above
            // for sight and is the field's label for VoiceOver.
            TextField("", text: text(of: field), selection: selection(of: field)) // lint-ok: named by the .accessibilityLabel below
                .keyboardType(.numbersAndPunctuation)
                .submitLabel(.go)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { take(field) }
                .focused($keyboardField, equals: field)
                .accessibilityFocused($voiceOverField, equals: field)
                .accessibilityLabel(model.label(of: field))
                .accessibilityHint(model.hint(of: field))
            if let refusal = model.refusalText(of: field) {
                Text(refusal)
                    .foregroundStyle(.red)
            }
            PhoneActionButton(title: PhoneGoToVocabulary.jump) { take(field) }
                .accessibilityLabel(field.jumpLabel)
        } header: {
            // For sight: VoiceOver hears the name once, as the field's label.
            // (Showing it to VoiceOver as a heading did not clear the
            // audit's one "potentially inaccessible text" finding, so the
            // spec's single reading stands.)
            Text(model.label(of: field))
                .phoneSecondaryText()
                .accessibilityHidden(true)
        }
    }

    /// The text of `field`, whose edit forgets its refusal, as the Mac's
    /// panel forgets one.
    private func text(of field: PhoneGoToField) -> Binding<String> {
        Binding(
            get: { texts[field] ?? "" },
            set: { newText in
                guard newText != texts[field] else { return }
                texts[field] = newText
                model.noteEdited(field)
            }
        )
    }

    /// The selection of `field`.
    private func selection(of field: PhoneGoToField) -> Binding<TextSelection?> {
        Binding(
            get: { selections[field] },
            set: { selections[field] = $0 }
        )
    }

    /// Puts the keyboard and VoiceOver's focus in the opening field, its text
    /// selected, a moment after the sheet appears, as every sheet's arrival
    /// waits (`PhoneFocusPolicy.screenChangedDelay`).
    private func focusOpeningField() async {
        try? await Task.sleep(for: .seconds(PhoneFocusPolicy.screenChangedDelay))
        let field = model.initialFocus
        let text = texts[field] ?? ""
        selections[field] = TextSelection(range: text.startIndex..<text.endIndex)
        keyboardField = field
        voiceOverField = field
    }

    /// Takes `field` by the Mac's rule: its starting value closes the sheet
    /// without moving; a jump closes it, and the Mac's "Jumped to page 12."
    /// is said once it has closed; a refusal stays under the field, said
    /// once, with focus left in the field.
    private func take(_ field: PhoneGoToField) {
        let typed = texts[field] ?? ""
        var outcome = JumpFieldOutcome.unchanged
        let said = VoiceOverAnnouncer.collectingAnnouncements {
            outcome = model.take(typed, from: field, in: reader)
        }
        switch outcome {
        case .unchanged:
            dismiss()
        case .jumped:
            farewell.keep(said.map(\.message))
            noteJumped()
            dismiss()
        case .refused(let problem):
            PhoneAnnouncer.say(problem)
        }
    }
}
