import SwiftUI

// The rows of the iPhone's Library list. Each takes only its row value, built
// by `PhoneLibraryRows`, and compares equal while the value does, so SwiftUI
// leaves a row alone until its words change: a row's label never changes
// under a listener while a book plays (the engineering review's F11). The
// closure a row runs its commands through is left out of the comparison: it
// acts on the list as it is when the command runs.
//
// Nothing here has run on iOS.

/// A book's row: a button that opens the book, said in the Mac's words, with
/// its commands as named VoiceOver actions and as a context menu for touch.
struct PhoneBookRow: View, Equatable {
    /// The row's words and commands.
    let value: PhoneRowValue
    /// Opens the book.
    let open: () -> Void
    /// Runs one of the row's commands.
    let perform: (PhoneLibraryOffer.Action) -> Void

    var body: some View {
        Button(action: open) {
            PhoneRowLines(title: value.title, detail: value.detail)
        }
        // The Mac's label replaces the lines read together, title first.
        .accessibilityLabel(value.label)
        .accessibilityHint(BookRow.accessibilityHint(isEditMode: false, isEditSelected: false))
        .phoneRowCommands(value.commands, perform: perform)
    }

    /// Rows compare by their value alone.
    nonisolated static func == (lhs: PhoneBookRow, rhs: PhoneBookRow) -> Bool {
        lhs.value == rhs.value
    }
}

/// A folder's row: a button that opens the folder, said in the Mac's words,
/// "Fiction, 12 books", with the folder's commands.
struct PhoneFolderRow: View, Equatable {
    /// The row's words and commands.
    let value: PhoneRowValue
    /// Opens the folder.
    let open: () -> Void
    /// Runs one of the row's commands.
    let perform: (PhoneLibraryOffer.Action) -> Void

    var body: some View {
        Button(action: open) {
            HStack {
                // For sight alone: the label says it's a folder by its count.
                Image(systemName: "folder")
                    .accessibilityHidden(true)
                PhoneRowLines(title: value.title, detail: value.detail)
            }
        }
        .accessibilityLabel(value.label)
        .accessibilityHint(FolderRow.accessibilityHint)
        .phoneRowCommands(value.commands, perform: perform)
    }

    /// Rows compare by their value alone.
    nonisolated static func == (lhs: PhoneFolderRow, rhs: PhoneFolderRow) -> Bool {
        lhs.value == rhs.value
    }
}

/// The one sentence a list shows where it has nothing: static text, read as
/// it is.
struct PhoneNoteRow: View {
    /// The sentence's row.
    let value: PhoneRowValue

    var body: some View {
        Text(value.title)
            .phonePrimaryText()
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The Continue row (the spec, "The Continue row"): the Mac's Continue
/// button, which opens the book in reach, and beside it, for a sighted
/// helper, a Play button that VoiceOver passes over, since the magic tap does
/// the same.
struct PhoneContinueRowView: View, Equatable {
    /// The row's words.
    let value: PhoneContinueRow
    /// Opens the book's reader.
    let open: () -> Void
    /// Plays or pauses the book.
    let playPause: () -> Void

    var body: some View {
        HStack {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    // The system's label colors, not the button's tint (see
                    // `PhoneRowLines`).
                    Text(value.visibleTitle)
                        .font(.headline)
                        .phonePrimaryText()
                    if let time = value.timeText {
                        Text(time)
                            .font(.subheadline)
                            .phoneSecondaryText()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Two buttons in one row each need their own touch area.
            .buttonStyle(.borderless)
            .accessibilityLabel(value.label)
            .accessibilityHint(PhoneRowWording.continueHint)

            Button(action: playPause) {
                Image(systemName: value.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            // The Mac's Play button's words, for whatever reads it by name.
            .accessibilityLabel(PhoneAppWording.playButton(isPlaying: value.isPlaying))
            // Not in VoiceOver's order: the magic tap plays and pauses from
            // here (principle 9's named exception).
            .accessibilityHidden(true) // lint-ok: the spec's Continue row keeps Play out of VoiceOver's order
        }
    }

    /// Rows compare by their value alone.
    nonisolated static func == (lhs: PhoneContinueRowView, rhs: PhoneContinueRowView) -> Bool {
        lhs.value == rhs.value
    }
}

/// A row's two visible lines: the title, then the detail, at Dynamic Type
/// sizes. VoiceOver reads the row's own label instead.
private struct PhoneRowLines: View {
    /// The first line.
    let title: String
    /// The second line, or nil.
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The system's label colors, named as colors: inside a Button the
            // hierarchical `.primary`/`.secondary` styles are taken from the
            // button's tint, which drew the second line in light blue and
            // failed Apple's contrast audit.
            Text(title)
                .font(.headline)
                .phonePrimaryText()
            if let detail, !detail.isEmpty {
                // Full contrast too (`PhoneTextColor`): the audit found the
                // secondary color "nearly" enough, not enough. The title stays
                // distinct by its semibold headline font against this
                // regular, smaller one.
                Text(detail)
                    .font(.subheadline)
                    .fontWeight(.regular)
                    .phoneSecondaryText()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// Gives a row `commands` twice over: as named VoiceOver actions, on the
    /// Actions rotor, and as a context menu for touch, in the same order
    /// under the same names (the spec, "Lists"). Apple's criteria ask for the
    /// context menu's commands as custom actions too, and a context menu
    /// alone is a touch and hold.
    func phoneRowCommands(
        _ commands: [PhoneLibraryOffer.Command],
        perform: @escaping (PhoneLibraryOffer.Action) -> Void
    ) -> some View {
        self
            .accessibilityActions {
                ForEach(commands) { command in
                    Button(command.title) { perform(command.action) }
                }
            }
            .contextMenu {
                ForEach(commands) { command in
                    Button(command.title, role: command.action == .remove ? .destructive : nil) {
                        perform(command.action)
                    }
                }
            }
    }
}
