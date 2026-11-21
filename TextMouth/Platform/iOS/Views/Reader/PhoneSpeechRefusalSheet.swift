import SwiftUI
import UIKit

/// The Speech Stopped sheet over the reader (the spec, "While the book is
/// loading, or can't load"), rebuilt for the phone over the Mac's report
/// (`SpeechRefusalReport`) and its words (`SpeechRefusalWording`), with the
/// iPhone's version of the sentences that said "Mac".
///
/// VoiceOver's order: the heading "Speech Stopped" with what happened, one
/// element; the Details text area, which VoiceOver reads by line and a braille
/// display pans; Copy Details; and Close in the toolbar. There is no Show Logs
/// in Finder. The sheet follows only the report, as the Mac's does
/// (PERF30), so a book that plays under it never redraws it; a second
/// refusal replaces the report in place.
///
/// Nothing here has run on iOS.
struct PhoneSpeechRefusalSheet: View {
    /// The reader whose report the sheet shows. Not observed.
    let reader: ReaderViewModel
    /// The report the reader keeps, republished only when it changes.
    @StateObject private var shown: ReaderSnapshot<SpeechRefusalReport?>
    /// Whether VoiceOver's focus is on the heading.
    @AccessibilityFocusState private var headingFocused: Bool

    /// A sheet showing the report `reader` keeps.
    init(reader: ReaderViewModel) {
        self.reader = reader
        _shown = StateObject(wrappedValue: ReaderSnapshot(of: reader) { $0.speechRefusalAlert.report })
    }

    var body: some View {
        NavigationStack {
            // Empty only for the moment the sheet closes, its report let go.
            if let report = shown.value {
                content(of: report)
            }
        }
    }

    /// The heading, the details, and Copy Details, with Close in the toolbar.
    /// Closing the report is what closes the sheet: the reader's screen shows
    /// the sheet while the reader keeps a report.
    private func content(of report: SpeechRefusalReport) -> some View {
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
            .accessibilityFocused($headingFocused)

            // Every line of the report, as Copy Details copies it.
            ReadOnlyTextArea(text: report.text, label: SpeechRefusalWording.detailsLabel)
                .frame(minHeight: 240)

            Button(SpeechRefusalWording.copyTitle) {
                SpeechRefusalReportSheet.copyDetails(of: report, to: .general)
            }
            .accessibilityHint(SpeechRefusalWording.copyHint)
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            PhoneSheetButton(title: PhoneAppWording.close, hint: SpeechRefusalWording.closeHint) {
                reader.closeSpeechRefusalReport()
            }
        }
        // VoiceOver moves to the heading once the sheet has come up, so the
        // sheet says at once why it is there.
        .task {
            try? await Task.sleep(for: .seconds(PhoneFocusPolicy.screenChangedDelay))
            headingFocused = true
        }
    }
}
