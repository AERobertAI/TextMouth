import SwiftUI

/// The Library tab's Titles section (TITLE-ARTICLES-RESEARCH-2026-11-13.md):
/// the Leading articles pop-up, which chooses what a title's leading article
/// does in the Library's lists (`LeadingArticles`), and, under it, what the
/// choice in force does and which languages' articles count.
///
/// VoiceOver reads the heading, then the pop-up by its label, its choice,
/// and its hint, then the description as text, so a listener who has hints
/// turned off still hears what the choice does, as a braille display shows
/// it. The pop-up changes the setting through the settings model, which
/// saves it to the store and config.json, and every open Library window
/// sorts and shows its titles anew.
struct LeadingArticlesSettingsSection: View {
    /// The settings, which keep the choice.
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    /// The words, named once.
    private typealias Wording = LeadingArticleWording

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Wording.sectionHeader)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Picker(Wording.pickerLabel, selection: $settingsViewModel.leadingArticles) {
                ForEach(LeadingArticles.allCases, id: \.self) { choice in
                    Text(Wording.name(choice)).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 420)
            .accessibilityHint(Wording.pickerHint)
            .help(Wording.pickerHint)
            Text(Self.caption(for: settingsViewModel.leadingArticles))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The words under the pop-up: what `choice` does, then which
    /// languages' articles count and that folder names stay as typed.
    static func caption(for choice: LeadingArticles) -> String {
        "\(LeadingArticleWording.description(choice)) \(LeadingArticleWording.languagesNote)"
    }
}
