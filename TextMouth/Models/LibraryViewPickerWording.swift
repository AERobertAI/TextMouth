import CoreGraphics

/// What a Library window says of its views (the design of October 30, 2026,
/// LIBRARY-VIEWS-RESEARCH-2026-10-30.md, section 9, "The Library window"):
/// the View pop-up's bound, the sentence a view listing nothing shows, what
/// is announced when the view a window shows is deleted, the Sort menu of a
/// view listing only feeds, and Go to View's submenu and announcements. The
/// same words on screen, to VoiceOver, and on a braille display.
enum LibraryViewPickerWording {
    /// The widest the View pop-up grows, so a long view name never makes the
    /// window's content wider than the window, which once ended the test
    /// host (the design's section 6).
    static let pickerWidthLimit: CGFloat = 320

    /// The row a Feeds view or a view the listener made shows while it lists
    /// nothing at all.
    static let emptyView = "Nothing matches this view now."

    /// What a window announces when the view it showed was deleted, from
    /// Settings or by a change of config.json, and it shows `name`, the
    /// first view its pop-up offers, instead.
    static func deletedView(nowShowing name: String) -> String {
        "The view this window showed was deleted. It now shows \(name)."
    }

    /// The one item of the Sort menu of a view listing only feeds, which are
    /// always listed by title.
    static let feedsOrderName = "Title"
    /// The Sort button's spoken label in a view listing only feeds.
    static let feedsSortMenuLabel = "Sort feeds by Title"
    /// The hint of that one item, which says why there is no other.
    static let feedsOrderHint = "Feeds are always listed by title"
    /// What VoiceOver says when that item is chosen.
    static let feedsOrderAnnouncement = "Feeds are listed by title"

    // MARK: - Go to View (Design Section 6)

    /// The Library menu's submenu listing the views the key Library window
    /// offers, each item titled by its view's name.
    static let goToViewMenuTitle = "Go to View"
    /// The submenu's one item, dimmed, while no Library window is in front.
    static let noLibraryWindow = "No Library Window"

    /// What a window says on going to the view `name` by Go to View's key or
    /// menu item: the name, then `counts`, what the view lists there
    /// (`CountWording.listItems(of:feeds:)`), as "All Items, 743 books, 2
    /// feeds".
    static func wentToView(name: String, counts: String) -> String {
        "\(name), \(counts)"
    }

    /// What a window says when Go to View `number` has no view, its View
    /// pop-up offering `offered` views, counted as the keys count them: "There
    /// is no view 7. The View pop-up offers 6 views."
    static func noView(number: Int, offered: Int) -> String {
        "There is no view \(number). The View pop-up offers \(CountWording.phrase(offered, singular: "view", plural: "views"))."
    }
}
