import Foundation

/// What the Library tab of Settings says of the Leading Articles setting
/// (TITLE-ARTICLES-RESEARCH-2026-11-13.md): its heading, its pop-up's label,
/// hint, and choices, and what each choice does, the same on screen, to
/// VoiceOver, and on a braille display.
enum LeadingArticleWording {
    /// The heading of the tab's section holding the setting.
    static let sectionHeader = "Titles"

    /// The pop-up's label, which VoiceOver reads before the choice.
    static let pickerLabel = "Leading articles"

    /// The pop-up's hint, which VoiceOver speaks and the pointer shows as a
    /// tooltip: what the setting decides, in words that need no example.
    static let pickerHint = "Chooses whether The, A, and An at the start of a title count when the Library sorts "
        + "titles and when you type a title's first letters to go to it."

    /// A choice's name in the pop-up: "Part of the Title", "Ignored When
    /// Typing", or "Ignored When Typing and Sorting".
    static func name(_ choice: LeadingArticles) -> String {
        switch choice {
        case .partOfTitle: return "Part of the Title"
        case .ignoredWhenTyping: return "Ignored When Typing"
        case .ignoredWhenTypingAndSorting: return "Ignored When Typing and Sorting"
        }
    }

    /// What the choice in force does, under the pop-up, with The Hobbit for
    /// its example.
    static func description(_ choice: LeadingArticles) -> String {
        switch choice {
        case .partOfTitle:
            return "Titles sort, and are found by typing, as they are written: The Hobbit is among the T's."
        case .ignoredWhenTyping:
            return "The Hobbit counts as an H when you type. The list keeps its order and shows each title as it is written."
        case .ignoredWhenTypingAndSorting:
            return "The Hobbit sorts among the H's and shows as Hobbit, The. Typing H finds it among the H's."
        }
    }

    /// Which languages' articles count beside English's, and that folder
    /// names are left as typed: said only where articles are ignored (the
    /// second and third choices), since under the first nothing passes over
    /// an article, in any language.
    static let languagesNote = "When articles are ignored, a book whose metadata names French, German, Spanish, "
        + "Italian, Portuguese, Dutch, Catalan, Swedish, Danish, or Norwegian passes over that language's articles, "
        + "such as Le and Die, and The. Any other book passes over The, A, and An. "
        + "Folder names stay as you typed them."

    /// The words under the pop-up for `choice`: what it does, and, for the
    /// choices that ignore articles, which languages' articles count.
    static func caption(for choice: LeadingArticles) -> String {
        choice.typesWithoutArticles ? "\(description(choice)) \(languagesNote)" : description(choice)
    }
}
