import CoreGraphics

/// What a Library window says of its views (the design of October 30, 2026,
/// LIBRARY-VIEWS-RESEARCH-2026-10-30.md, section 9, "The Library window"):
/// the View pop-up's bound, the sentence a view listing nothing shows, what
/// is announced when the view a window shows is deleted, and the Sort menu
/// of a view listing only feeds. The same words on screen, to VoiceOver,
/// and on a braille display.
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
}
