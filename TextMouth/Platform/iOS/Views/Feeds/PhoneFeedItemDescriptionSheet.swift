import SwiftUI

/// Show Description… on the iPhone (FR53, phase F1): what the Mac's sheet
/// shows of a feed's item, in the Mac's words: its title as the heading, a
/// line naming its feed, date, and duration, its text in a read-only text area
/// VoiceOver reads with its text navigation, and its web page; and Close.
///
/// VoiceOver's order: the title (a heading), Close, the line of details, the
/// text, then the web page. Focus starts on the text, as the Mac's does.
struct PhoneFeedItemDescriptionSheet: View {
    /// What the sheet shows.
    let description: FeedItemDescription
    /// Closes the sheet.
    let onClose: @MainActor () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(description.details)
                    .font(.callout)
                    .phoneSecondaryText()
                    .phoneWholeWords()
                    .padding(.horizontal)
                ReadOnlyTextArea(
                    text: description.text,
                    label: FeedWording.descriptionTextLabel(title: description.title),
                    takesFocus: true
                )
                if let link = description.link {
                    PhoneValueRow(name: FeedWording.webPageLabel, value: link.absoluteString)
                        .accessibilityElement(children: .combine)
                        .padding(.horizontal)
                }
            }
            .navigationTitle(description.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                PhoneSheetButton(title: FeedWording.closeTitle, action: onClose)
            }
        }
    }
}
