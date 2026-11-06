import Foundation

/// The numbers of KFX's shared symbols that the reader uses, named by what
/// they mean here. Each is a field of a struct, a fragment type, or a value,
/// by its number in the shared table `YJ_symbols` (KFX-FORMAT-NOTES-2026-11-05.md,
/// parts 5 to 10); a number that no part of the notes explains is not here.
enum KFXSymbol {

    // MARK: Fragment types

    /// Document data: the reading orders, among other things.
    static let documentData = 538
    /// The flat metadata fragment of older books; also holds reading orders.
    static let flatMetadata = 258
    /// The categorized book metadata (title, author, language, capabilities).
    static let bookMetadata = 490
    /// A section: a page template list that names a storyline.
    static let section = 260
    /// A storyline: the tree of nodes that holds a section's text.
    static let storyline = 259
    /// A content fragment: a list of strings the nodes point into.
    static let content = 145
    /// A style: the properties a node or run names.
    static let style = 157
    /// An anchor: a name for a position or a web address.
    static let anchor = 266
    /// Book navigation: contents, landmarks, page list, headings.
    static let navigation = 389

    // MARK: Fields of document data and metadata

    /// The reading orders (a list), in document data and in flat metadata.
    static let readingOrders = 169
    /// A reading order's name.
    static let readingOrderName = 178
    /// A reading order's section names, in order.
    static let readingOrderSections = 170
    /// The reading order that is the book's default.
    static let defaultReadingOrder = 351
    /// The categories of book metadata (a list).
    static let metadataCategories = 491
    /// A metadata category's name.
    static let categoryName = 495
    /// A metadata category's entries (a list of key and value structs).
    static let categoryEntries = 258
    /// An entry's key.
    static let entryKey = 492
    /// An entry's value.
    static let entryValue = 307
    /// The flat metadata fragment's title, author, and language fields.
    static let flatTitle = 153
    static let flatAuthor = 222
    static let flatLanguage = 10
    /// Document data's field that marks comic panel mode.
    static let comicPanels = 665

    // MARK: Fields of sections and storylines

    /// A section's page templates (a list).
    static let pageTemplates = 141
    /// A page template's (or a node's) storyline name.
    static let storylineName = 176
    /// A storyline's nodes (a list).
    static let nodes = 146

    // MARK: Fields of nodes

    /// A node's position id.
    static let nodeID = 155
    /// A node's type.
    static let nodeType = 159
    /// A node's style name (and a run's).
    static let styleName = 157
    /// A node's text: a string, or a pointer into a content fragment.
    static let text = 145
    /// A node's children (a list), the same number as `nodes`.
    static let children = 146
    /// A node's style runs (a list).
    static let runs = 142
    /// A node's heading level (an integer).
    static let headingLevel = 790
    /// A node's image resource name.
    static let imageResource = 175
    /// A node's alternative text.
    static let altText = 584
    /// A node's render mode.
    static let renderMode = 601
    /// A node's classification (footnote, endnote, and so on).
    static let classification = 615
    /// A node's list style.
    static let listStyle = 100
    /// A node's list start number.
    static let listStart = 104
    /// A node's layout.
    static let layout = 156
    /// The name field of a content pointer (the system symbol `name`).
    static let contentName = 4
    /// The index field of a content pointer.
    static let contentIndex = 403

    // MARK: Fields of runs

    /// A run's first code point.
    static let runStart = 143
    /// A run's length in code points.
    static let runLength = 144
    /// A run's link: the name of an anchor.
    static let runLink = 179
    /// A run's marker for what it is (a note reference).
    static let runKind = 616
    /// The run kind that is a reference to a note.
    static let noteReference = 617

    // MARK: Fields of content fragments, styles, anchors

    /// A content fragment's strings.
    static let contentStrings = 146
    /// A style's weight.
    static let fontWeight = 13
    /// A style's slant.
    static let fontStyle = 12
    /// A style's list of layout hints.
    static let layoutHints = 761
    /// The layout hint that marks a heading.
    static let headingHint = 760
    /// An anchor's own name.
    static let anchorName = 180
    /// An anchor's position (a struct of node id and offset).
    static let anchorPosition = 183
    /// An anchor's web address.
    static let anchorURL = 186
    /// A position's node id.
    static let positionNode = 155
    /// A position's offset in code points.
    static let positionOffset = 143

    // MARK: Values: node types

    static let textBlock = 269
    static let container = 270
    static let image = 271
    static let vectorGraphic = 272
    static let plugin = 274
    static let list = 276
    static let listItem = 277
    static let table = 278
    static let tableHead = 151
    static let tableBody = 454
    static let tableFoot = 455
    static let tableRow = 279
    static let rule = 596
    static let hiddenContent = 439

    // MARK: Values: styles, render modes, classifications

    /// Weights from 700 up: the bold ones of the hundreds `$355` (100) to
    /// `$363` (900), where `$361` is bold.
    static let boldWeights: Set<Int> = [361, 362, 363]
    /// Slants: italic and oblique.
    static let italicStyles: Set<Int> = [382, 381]
    /// Inline render mode: the node flows within its line.
    static let inlineRender = 283
    /// Classifications that mark a note's body.
    static let noteClassifications: Set<Int> = [618, 619, 281]
}
