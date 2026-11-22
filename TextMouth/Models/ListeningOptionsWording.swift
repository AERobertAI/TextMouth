import Foundation

/// Every word the listening options' controls say and speak (FR19): the
/// three controls of a feed's Feed Info and of a folder's settings sheet,
/// their choices, and their hints. One place, so the two sheets say the
/// same thing and a test pins each string, since the listener hears them
/// through VoiceOver and reads them in braille.
///
/// Each sentence is written whole for each noun (FR34), since the article
/// before a noun ("an episode", "a book"), its plural, and its owner differ
/// by language, and no sentence is built from pieces.
enum ListeningOptionsWording {

    // MARK: Nouns

    /// What the items that follow one another are called: a feed's episodes,
    /// articles, or items, or a plain folder's books.
    enum Noun: Hashable, Sendable {
        case episode
        case article
        case item
        case book

        /// The noun for a feed whose items are called `feedNoun`
        /// (`FeedWording.ItemNoun`).
        init(_ feedNoun: FeedWording.ItemNoun) {
            switch feedNoun {
            case .episode: self = .episode
            case .article: self = .article
            case .item: self = .item
            }
        }
    }

    // MARK: When an Item Ends

    /// The label of the choice of what happens when an item ends: "When an
    /// episode ends", "When a book ends".
    static func continuationLabel(_ noun: Noun) -> String {
        switch noun {
        case .episode:
            // Translators: Label of the pop-up button in a podcast feed's Feed Info choosing what happens when one of its episodes ends.
            return InterfaceText.line("listeningOptions.continuationLabel.episode", "When an episode ends")
        case .article:
            // Translators: Label of the pop-up button in a news feed's Feed Info choosing what happens when one of its articles ends.
            return InterfaceText.line("listeningOptions.continuationLabel.article", "When an article ends")
        case .item:
            // Translators: Label of the pop-up button in a feed's Feed Info choosing what happens when one of its items ends.
            return InterfaceText.line("listeningOptions.continuationLabel.item", "When an item ends")
        case .book:
            // Translators: Label of the pop-up button in a folder's settings choosing what happens when one of its books ends.
            return InterfaceText.line("common.whenABookEnds", "When a book ends")
        }
    }

    /// The name of one choice of what happens when an item ends. The choice
    /// of nil is "Use the global setting", which names the global
    /// setting's own value in parentheses, since the choice means whatever
    /// that is: "Use the global setting (Continue to Next Book)".
    static func continuationTitle(
        _ choice: ReadingList.Continuation?,
        noun: Noun,
        global: EndOfBookBehavior
    ) -> String {
        switch choice {
        case nil:
            // Translators: A choice of the pop-up button that sets what happens when an item ends, in Feed Info and Folder Settings: do as Settings says. %@ is the name of the choice Settings has now, such as Continue to Next Book.
            return InterfaceText.line("common.useTheGlobalSettingValue", "Use the global setting (\(global.title))")
        case .playBookBelow: return playBelow(noun)
        case .playBookAbove: return playAbove(noun)
        case .stop:
            // Translators: A choice of the pop-up button that sets what happens when an item ends: stop when it ends.
            return InterfaceText.line("common.stop", "Stop")
        }
    }

    /// The choice that plays the item below the finished one.
    private static func playBelow(_ noun: Noun) -> String {
        switch noun {
        case .episode:
            // Translators: A choice of the pop-up button that sets what happens when a podcast episode ends: play the episode below it in the list.
            return InterfaceText.line("listeningOptions.playBelow.episode", "Play the episode below")
        case .article:
            // Translators: A choice of the pop-up button that sets what happens when a news article ends: play the article below it in the list.
            return InterfaceText.line("listeningOptions.playBelow.article", "Play the article below")
        case .item:
            // Translators: A choice of the pop-up button that sets what happens when a feed's item ends: play the item below it in the list.
            return InterfaceText.line("listeningOptions.playBelow.item", "Play the item below")
        case .book:
            // Translators: A choice of the pop-up button that sets what happens when a book ends: play the book below it in the folder.
            return InterfaceText.line("common.playTheBookBelow", "Play the book below")
        }
    }

    /// The choice that plays the item above the finished one.
    private static func playAbove(_ noun: Noun) -> String {
        switch noun {
        case .episode:
            // Translators: A choice of the pop-up button that sets what happens when a podcast episode ends: play the episode above it in the list.
            return InterfaceText.line("listeningOptions.playAbove.episode", "Play the episode above")
        case .article:
            // Translators: A choice of the pop-up button that sets what happens when a news article ends: play the article above it in the list.
            return InterfaceText.line("listeningOptions.playAbove.article", "Play the article above")
        case .item:
            // Translators: A choice of the pop-up button that sets what happens when a feed's item ends: play the item above it in the list.
            return InterfaceText.line("listeningOptions.playAbove.item", "Play the item above")
        case .book:
            // Translators: A choice of the pop-up button that sets what happens when a book ends: play the book above it in the folder.
            return InterfaceText.line("common.playTheBookAbove", "Play the book above")
        }
    }

    /// The hint of the choice of what happens when an item ends.
    static func continuationHint(_ noun: Noun) -> String {
        switch noun {
        case .episode:
            // Translators: VoiceOver hint of the pop-up button in a podcast feed's Feed Info that sets what happens when one of its episodes ends.
            return InterfaceText.line("listeningOptions.continuationHint.episode", "Chooses what happens when one of this feed's episodes ends")
        case .article:
            // Translators: VoiceOver hint of the pop-up button in a news feed's Feed Info that sets what happens when one of its articles ends.
            return InterfaceText.line("listeningOptions.continuationHint.article", "Chooses what happens when one of this feed's articles ends")
        case .item:
            // Translators: VoiceOver hint of the pop-up button in a feed's Feed Info that sets what happens when one of its items ends.
            return InterfaceText.line("listeningOptions.continuationHint.item", "Chooses what happens when one of this feed's items ends")
        case .book:
            // Translators: VoiceOver hint of the pop-up button in a folder's settings that sets what happens when one of its books ends.
            return InterfaceText.line("listeningOptions.continuationHint.book", "Chooses what happens when one of this folder's books ends")
        }
    }

    // MARK: Skipping Finished Items

    /// The label of the switch that passes over finished items: "Skip
    /// finished episodes".
    static func skipFinishedLabel(_ noun: Noun) -> String {
        switch noun {
        case .episode:
            // Translators: Label of the switch in a podcast feed's Feed Info that passes over episodes already finished.
            return InterfaceText.line("listeningOptions.skipFinishedLabel.episode", "Skip finished episodes")
        case .article:
            // Translators: Label of the switch in a news feed's Feed Info that passes over articles already finished.
            return InterfaceText.line("listeningOptions.skipFinishedLabel.article", "Skip finished articles")
        case .item:
            // Translators: Label of the switch in a feed's Feed Info that passes over items already finished.
            return InterfaceText.line("listeningOptions.skipFinishedLabel.item", "Skip finished items")
        case .book:
            // Translators: Label of the switch in a folder's settings that passes over books already finished.
            return InterfaceText.line("common.skipFinishedBooks", "Skip finished books")
        }
    }

    /// The hint of the switch that passes over finished items.
    static func skipFinishedHint(_ noun: Noun) -> String {
        switch noun {
        case .episode:
            // Translators: VoiceOver hint of the Skip finished episodes switch in a podcast feed's Feed Info.
            return InterfaceText.line("listeningOptions.skipFinishedHint.episode", "Applies when listening goes on to another episode")
        case .article:
            // Translators: VoiceOver hint of the Skip finished articles switch in a news feed's Feed Info.
            return InterfaceText.line("listeningOptions.skipFinishedHint.article", "Applies when listening goes on to another article")
        case .item:
            // Translators: VoiceOver hint of the Skip finished items switch in a feed's Feed Info.
            return InterfaceText.line("listeningOptions.skipFinishedHint.item", "Applies when listening goes on to another item")
        case .book:
            // Translators: VoiceOver hint of the Skip finished books switch in a folder's settings.
            return InterfaceText.line("listeningOptions.skipFinishedHint.book", "Applies when listening goes on to another book")
        }
    }

    // MARK: Downloading the Next Item

    /// The label of the switch that downloads the next item before the
    /// playing one ends: "Download the next episode before this one ends".
    static func predownloadLabel(_ noun: Noun) -> String {
        switch noun {
        case .episode:
            // Translators: Label of the switch in a podcast feed's Feed Info that downloads the next episode before the playing one ends.
            return InterfaceText.line("listeningOptions.predownloadLabel.episode", "Download the next episode before this one ends")
        case .article:
            // Translators: Label of the switch in a news feed's Feed Info that downloads the next article before the playing one ends.
            return InterfaceText.line("listeningOptions.predownloadLabel.article", "Download the next article before this one ends")
        case .item:
            // Translators: Label of the switch in a feed's Feed Info that downloads the next item before the playing one ends.
            return InterfaceText.line("listeningOptions.predownloadLabel.item", "Download the next item before this one ends")
        case .book:
            // Translators: Label of a switch that downloads the next book before the playing one ends (a folder's settings do not show it today).
            return InterfaceText.line("listeningOptions.predownloadLabel.book", "Download the next book before this one ends")
        }
    }

    /// The hint of the switch that downloads the next item. While listening
    /// does not go on from one item to another, the switch can do nothing,
    /// and the hint says when it is available instead of what it does: word
    /// for word the sentence of the Open the next book in pop-up button
    /// beside it (`NextBookWindowWording.unavailableHint`), so the two read
    /// alike and share one translation.
    static func predownloadHint(_ noun: Noun, enabled: Bool) -> String {
        guard enabled else { return NextBookWindowWording.unavailableHint(noun) }
        // The lead time in whole minutes: a count inside the sentence.
        let lead = Int(ListeningOptions.predownloadLeadTime / 60)
        switch noun {
        case .episode:
            // Translators: VoiceOver hint of the Download the next episode switch in a podcast feed's Feed Info. %lld is the number of minutes left that start the download.
            return InterfaceText.line("listeningOptions.predownloadHint.episode", "When \(number: lead) minutes or less are left, downloads the next episode if it is not on this Mac yet")
        case .article:
            // Translators: VoiceOver hint of the Download the next article switch in a news feed's Feed Info. %lld is the number of minutes left that start the download.
            return InterfaceText.line("listeningOptions.predownloadHint.article", "When \(number: lead) minutes or less are left, downloads the next article if it is not on this Mac yet")
        case .item:
            // Translators: VoiceOver hint of the Download the next item switch in a feed's Feed Info. %lld is the number of minutes left that start the download.
            return InterfaceText.line("listeningOptions.predownloadHint.item", "When \(number: lead) minutes or less are left, downloads the next item if it is not on this Mac yet")
        case .book:
            // Translators: VoiceOver hint of a switch that downloads the next book (a folder's settings do not show it today). %lld is the number of minutes left that start the download.
            return InterfaceText.line("listeningOptions.predownloadHint.book", "When \(number: lead) minutes or less are left, downloads the next book if it is not on this Mac yet")
        }
    }
}
