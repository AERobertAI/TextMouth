import AppKit
import SwiftUI

// MARK: - The Report's Sheet (B05)

/// The report of a speech refusal as its sheet shows it (B05), for VoiceOver
/// and a braille display first:
/// - the heading, "Speech Stopped", and what happened, in one plain
///   sentence, read together, which VoiceOver moves to as the sheet opens in
///   front of the listener, so the sheet says at once why it is there;
/// - the whole report, line by line, in a read-only text area that
///   VoiceOver reads with its text navigation and a braille display pans,
///   its text selectable and copyable;
/// - Copy Details, which copies the whole report as plain text;
/// - Close, the default button, which Return and Escape press too.
struct SpeechRefusalReportView: View {
    /// The report shown.
    let report: SpeechRefusalReport
    /// Whether VoiceOver moves to the heading as the sheet opens: only when
    /// it opens in front of the listener (`SpeechRefusalWindowStanding`).
    let takesVoiceOverFocus: Bool
    /// What Copy Details does.
    let onCopy: () -> Void
    /// What Close, Return, and Escape do.
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // One element for VoiceOver: the heading, then what happened.
            VStack(alignment: .leading, spacing: 6) {
                Text(SpeechRefusalWording.heading)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(SpeechRefusalWording.summary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .modifier(InitialVoiceOverFocusModifier(isTarget: takesVoiceOverFocus))

            // Every line of the report, as Copy Details copies it. Labelled
            // "Details" alone: no heading above it says the word first.
            FeedReadOnlyText(text: report.text, label: SpeechRefusalWording.detailsLabel)
                .frame(minHeight: 300)

            HStack {
                Button(SpeechRefusalWording.copyTitle, action: onCopy)
                    .accessibilityHint(SpeechRefusalWording.copyHint)
                Spacer()
                // Return presses Close: nothing in the sheet takes typing.
                // A button carries one shortcut, so Escape closes through
                // the key equivalent below instead.
                Button(SpeechRefusalWording.closeTitle, action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(SpeechRefusalWording.closeHint)
            }
        }
        .padding()
        .frame(width: 620, height: 560)
        // Escape closes the sheet too, wherever focus is, as Return does.
        // Not the exit command: from the text area, an AppKit text view,
        // that command never reaches SwiftUI.
        .background(SilentKeyEquivalent(key: .escape, action: onClose))
    }
}

/// The sheet over a reader that shows the report of a speech refusal the
/// reader keeps (B05).
///
/// It follows only the report (PERF30): a reader publishes eight times a
/// second while it plays, and Play can come from the AirPods while the sheet
/// is open, so the sheet holds a snapshot of the report and draws again only
/// when a refusal changes it, in place. Whether VoiceOver moves to it is
/// decided once, as the sheet is made, from where the reader's window
/// stands then.
struct SpeechRefusalReportSheet: SheetOverOneReader {
    /// The reader whose report the sheet shows. Not observed: the sheet
    /// follows `shown` instead.
    let viewModel: ReaderViewModel
    /// The report the reader keeps, republished only when it changes.
    @StateObject private var shown: ReaderSnapshot<SpeechRefusalReport?>
    /// Whether VoiceOver moves to the sheet's heading as it opens.
    @State private var takesVoiceOverFocus: Bool

    /// A sheet showing the report `viewModel` keeps.
    init(viewModel: ReaderViewModel) {
        self.viewModel = viewModel
        _shown = StateObject(wrappedValue: ReaderSnapshot(of: viewModel) { $0.speechRefusalAlert.report })
        _takesVoiceOverFocus = State(initialValue: viewModel.speechRefusalWindowStanding.sheetTakesVoiceOverFocus)
    }

    var body: some View {
        // Empty only for the moment the sheet closes, its report let go.
        if let report = shown.value {
            SpeechRefusalReportView(
                report: report,
                takesVoiceOverFocus: takesVoiceOverFocus,
                onCopy: { Self.copyDetails(of: report, to: .general) },
                onClose: { viewModel.closeSpeechRefusalReport() }
            )
        }
    }

    /// Copy Details: puts the whole report on `pasteboard` as plain text,
    /// the general pasteboard in the app, and tells VoiceOver whether it
    /// was copied.
    static func copyDetails(of report: SpeechRefusalReport, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let copied = pasteboard.setString(report.text, forType: .string)
        VoiceOverAnnouncer.announce(copied ? SpeechRefusalWording.copiedAnnouncement : SpeechRefusalWording.notCopiedAnnouncement)
    }
}

/// Presents the report of a speech refusal over the reader while the reader
/// keeps one (B05). A window shows one sheet at a time, so the report waits
/// while one of the reader's panels shows, and opens as the panel closes;
/// it closes only through its own Close, Return, or Escape, so a panel
/// opened over it puts it aside rather than losing it.
struct SpeechRefusalReportPresenter: ViewModifier {
    /// The reader whose report is shown, observed so the sheet comes with
    /// the report.
    @ObservedObject var viewModel: ReaderViewModel
    /// The reader's panels, each a sheet of its own.
    let panels: ReaderPanels

    func body(content: Content) -> some View {
        content.sheet(isPresented: isPresented) {
            SpeechRefusalReportSheet(viewModel: viewModel)
        }
    }

    /// Whether the sheet shows: while the reader keeps a report and none of
    /// its panels shows. Nothing is done when SwiftUI puts the sheet away:
    /// the report is closed only by its own buttons and keys.
    private var isPresented: Binding<Bool> {
        Binding(
            get: { viewModel.speechRefusalAlert.report != nil && !panels.isShowingAny },
            set: { _ in }
        )
    }
}

extension ReaderPanels {
    /// Whether any of the reader's panels shows. A panel added to
    /// `ReaderPanels` must be added here too; a test counts the panels.
    var isShowingAny: Bool {
        headings || bookmarks || sleepTimer || bookInfo || voice || search
    }
}
