import SwiftUI

/// The card at the top of the Library for an export that goes on with its sheet closed (FR31, phase 2), after the title
/// and before the search field, as the import's card is placed: the sheet's title, the progress words with a bar and
/// Stop while it runs, and the Mac's sentence of what it did with Close once it has ended. It shows nothing while no
/// export has its card.
///
/// What it says and which buttons it holds are `PhoneExportOffer.card`'s, read from the model, which the Mac's test host
/// tests. Each of its lines is an element of its own in a container, so that Stop stays within VoiceOver's reach, and the
/// words change as the export moves, which VoiceOver reads when the card is focused and does not announce; the end is
/// announced once, at low priority (`BookExportModel.announcementPriority`).
struct PhoneExportProgressCard: View {
    /// The session that holds the export the card shows.
    @ObservedObject var session: PhoneExportSession
    /// Where VoiceOver's focus is asked to go, the Library's: the card's title takes it when the card appears and ends.
    let focus: AccessibilityFocusState<PhoneLibraryFocus?>.Binding

    /// The card for the app's session.
    init(session: PhoneExportSession = .shared, focus: AccessibilityFocusState<PhoneLibraryFocus?>.Binding) {
        self.session = session
        self.focus = focus
    }

    var body: some View {
        if let model = session.cardModel {
            CardContent(model: model, session: session, focus: focus)
        }
    }

    /// The card of one export, drawn again as that export moves.
    private struct CardContent: View {
        /// The export shown.
        @ObservedObject var model: BookExportModel
        /// The session, whose Stop and Close the buttons press.
        let session: PhoneExportSession
        /// The Library's focus, which the title takes.
        let focus: AccessibilityFocusState<PhoneLibraryFocus?>.Binding

        /// What the card says now.
        private var card: PhoneExportOffer.Card? {
            PhoneExportOffer.card(
                stage: PhoneExportOffer.Stage(model.phase),
                title: model.title,
                progressText: model.progressText,
                fraction: model.progressFraction,
                finishedWords: model.finishedWords ?? model.summary
            )
        }

        var body: some View {
            if let card {
                VStack(alignment: .leading, spacing: 8) {
                    Text(card.title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused(focus, equals: .exportCard)
                    if card.close == nil {
                        progressBar(card)
                    } else {
                        Text(card.status)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let stop = card.stop {
                        button(stop) { session.stop() }
                            .accessibilityFocused(focus, equals: .exportCardStop)
                    }
                    if let close = card.close {
                        button(close) { session.closeCard() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // A container, not one combined element: combining would fold the buttons into the status, out of
                // VoiceOver's reach.
                .accessibilityElement(children: .contain)
                // What the Library's focus helper scrolls to before it focuses the title (`PhoneListFocus.focus`): a
                // list makes no row far above what it shows, and focus asked for a row it has not made goes nowhere.
                .id(PhoneLibraryFocus.exportCard)
            }
        }

        /// The progress bar, labelled with the progress words, whose value VoiceOver gives as a percent.
        @ViewBuilder
        private func progressBar(_ card: PhoneExportOffer.Card) -> some View {
            Group {
                if let fraction = card.fraction {
                    ProgressView(value: fraction, total: 1) { Text(card.status) }
                } else {
                    ProgressView { Text(card.status) }
                }
            }
            .progressViewStyle(.linear)
            .accessibilityLabel(card.status)
        }

        /// A button of the card, titled, hinted, and borderless so that each keeps its own touch area in a list row.
        private func button(_ spec: PhoneExportOffer.BarButton, action: @escaping () -> Void) -> some View {
            Button(spec.title, action: action)
                .buttonStyle(.borderless)
                .accessibilityHint(spec.hint)
        }
    }
}
