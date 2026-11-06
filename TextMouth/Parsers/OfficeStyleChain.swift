import Foundation

// MARK: - Following a Style Through the Styles It Is Based On

/// The walk both style sheets make, the OpenDocument one (`ODTStyleSheet`)
/// and the Word 2003 XML one (`WordMLStyleSheet`): from a style to the style
/// it is based on, and on, with a guard against a chain that loops (a
/// hostile file can name a style as its own ancestor) and a limit on its
/// length.
enum OfficeStyleChain {
    /// What a walk found.
    struct Walk<Style> {
        /// The styles found, the one asked for first.
        var styles: [Style] = []
        /// The names of those styles.
        var names: Set<String> = []
        /// The name of the style the walk stopped at, if it did not end: one
        /// the document does not define, or one already met (a loop).
        var next: String?
    }

    /// The styles from `name` on, through each one's parent.
    /// - Parameters:
    ///   - lookup: finds a style by name, or nil for one the document does not define.
    ///   - parent: the name of the style a style is based on.
    ///   - limit: the most styles followed.
    static func walk<Style>(
        from name: String?,
        limit: Int,
        lookup: (String) -> Style?,
        parent: (Style) -> String?
    ) -> Walk<Style> {
        var walk = Walk<Style>()
        var next = name
        while let current = next, !walk.names.contains(current), walk.styles.count < limit, let style = lookup(current) {
            walk.names.insert(current)
            walk.styles.append(style)
            next = parent(style)
        }
        walk.next = next
        return walk
    }
}
