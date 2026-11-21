import Foundation

/// The base of the small XML readers of lexicons and XSPF playlists (FMT08,
/// FMT12). Neither format uses an entity declared in the file's own DOCTYPE,
/// and `XMLParser` reads a reference to one as nothing ("&w; Wide Web"
/// became " Wide Web"), which would change a rule or a title without a
/// word. So a file that declares an internal entity, or uses one it did not
/// declare (which is how `XMLParser` shows an external declaration), is
/// refused, and the reader's owner says so.
class EntityRefusingXMLReader: NSObject, XMLParserDelegate {
    /// Whether the document declared an entity, so its parse was stopped.
    private(set) var declaresEntities = false

    /// An entity declared with its text in the DOCTYPE (`<!ENTITY w "World">`).
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        refuseEntities(parser)
    }

    /// An entity declared as the contents of a file or address.
    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        refuseEntities(parser)
    }

    /// A reference to an entity the file never declared. `XMLParser` makes no
    /// callback for an entity declared as external when it is told not to
    /// resolve them (checked on this Mac), so the reference that follows is
    /// how such a declaration shows: the parse fails as undeclared. It is
    /// refused as the declared kind is.
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if (parseError as NSError).code == XMLParser.ErrorCode.undeclaredEntityError.rawValue {
            declaresEntities = true
        }
    }

    /// Notes the declaration and stops the parse.
    private func refuseEntities(_ parser: XMLParser) {
        declaresEntities = true
        parser.abortParsing()
    }
}
