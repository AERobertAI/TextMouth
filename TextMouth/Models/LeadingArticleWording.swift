import Foundation

/// What the Library tab of Settings says of the Leading Articles setting
/// (TITLE-ARTICLES-RESEARCH-2026-11-13.md): its heading, its pop-up's label,
/// hint, and choices, and what each choice does, the same on screen, to
/// VoiceOver, and on a braille display.
enum LeadingArticleWording {
    /// The heading of the tab's section holding the setting.
    static var sectionHeader: String {
        // Translators: Heading of the Library settings section that holds the Leading Articles pop-up, which decides how book titles are sorted and typed.
        InterfaceText.line("leadingArticle.sectionHeader", "Titles")
    }

    /// The pop-up's label, which VoiceOver reads before the choice.
    static var pickerLabel: String {
        // Translators: Label of the pop-up in the Library settings that chooses whether a title's leading article (The, A, An) counts when sorting and typing.
        InterfaceText.line("leadingArticle.pickerLabel", "Leading articles")
    }

    /// The pop-up's hint, which VoiceOver speaks and the pointer shows as a
    /// tooltip: what the setting decides, in words that need no example.
    static var pickerHint: String {
        // Translators: Hint and tooltip of the Leading Articles pop-up in the Library settings. The, A, and An are the English articles the setting skips.
        InterfaceText.line("leadingArticle.pickerHint", "Chooses whether The, A, and An at the start of a title count when sorting and when typing a title's first letters.")
    }

    /// A choice's name in the pop-up: "Part of the Title", "Ignored When
    /// Typing", or "Ignored When Typing and Sorting".
    static func name(_ choice: LeadingArticles) -> String {
        switch choice {
        case .partOfTitle:
            // Translators: A choice of the Leading Articles pop-up: the leading article counts like any other word of the title.
            return InterfaceText.line("leadingArticle.name.partOfTitle", "Part of the Title")
        case .ignoredWhenTyping:
            // Translators: A choice of the Leading Articles pop-up: a title's leading article does not count when typing a title's first letters, but the list keeps its order.
            return InterfaceText.line("leadingArticle.name.ignoredWhenTyping", "Ignored When Typing")
        case .ignoredWhenTypingAndSorting:
            // Translators: A choice of the Leading Articles pop-up: a title's leading article does not count when typing or when sorting.
            return InterfaceText.line("leadingArticle.name.ignoredWhenTypingAndSorting", "Ignored When Typing and Sorting")
        }
    }

    /// What the choice in force does, under the pop-up, with The Hobbit for
    /// its example.
    static func description(_ choice: LeadingArticles) -> String {
        switch choice {
        case .partOfTitle:
            // Translators: Describes the Leading Articles choice Part of the Title, under the pop-up. The Hobbit is the example title; the T's are the books sorted under the letter T.
            return InterfaceText.line("leadingArticle.description.partOfTitle", "Titles sort, and are found by typing, as they are written: The Hobbit is among the T's.")
        case .ignoredWhenTyping:
            // Translators: Describes the Leading Articles choice Ignored When Typing, under the pop-up. The Hobbit is the example title, typed under the letter H.
            return InterfaceText.line("leadingArticle.description.ignoredWhenTyping", "The Hobbit counts as an H when you type. The list keeps its order and shows each title as it is written.")
        case .ignoredWhenTypingAndSorting:
            // Translators: Describes the Leading Articles choice Ignored When Typing and Sorting, under the pop-up. The Hobbit is the example title; the article moves to the end and the book sorts and types under H.
            return InterfaceText.line("leadingArticle.description.ignoredForBoth", "The Hobbit sorts among the H's and shows as Hobbit, The. Typing H finds it among the H's.")
        }
    }

    /// Which languages' articles count beside English's, and that folder
    /// names are left as typed: said only where articles are ignored (the
    /// second and third choices), since under the first nothing passes over
    /// an article, in any language.
    static var languagesNote: String {
        SentenceWording.joined([
            // Translators: First sentence of the note under the Leading Articles pop-up, shown where articles are ignored. Names the languages whose articles TextMouth skips; Le, Die, and The are example articles and stay as written.
            InterfaceText.line("leadingArticle.languagesNote.portuguese", "When articles are ignored, a book whose metadata names French, German, Spanish, Italian, Portuguese, Dutch, Catalan, Swedish, Danish, or Norwegian passes over that language's articles, such as Le and Die, and The."),
            // Translators: Second sentence of the note under the Leading Articles pop-up: the articles skipped for a book in any other language. The, A, and An are the English articles and stay as written.
            InterfaceText.line("leadingArticle.languagesNote.other", "Any other book passes over The, A, and An."),
            // Translators: Last sentence of the note under the Leading Articles pop-up: folder names are never changed by the setting.
            InterfaceText.line("leadingArticle.languagesNote.folder", "Folder names stay as you typed them."),
        ])
    }

    /// The words under the pop-up for `choice`: what it does, and, for the
    /// choices that ignore articles, which languages' articles count.
    static func caption(for choice: LeadingArticles) -> String {
        choice.typesWithoutArticles ? SentenceWording.joined([description(choice), languagesNote]) : description(choice)
    }
}
