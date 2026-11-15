import Foundation

/// The base of the small XML readers of lexicons and XSPF playlists (FMT08,
/// FMT12). Neither format uses an entity declared in the file's own DOCTYPE,
/// and `XMLParser` reads a reference to one as nothing ("&w; Wide Web"
/// became " Wide Web"), which would change a rule or a title without a
/// word. So a file that declares any entity, internal or external, stops
/// the parse and is refused, and the reader's owner says so.
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

    /// Notes the declaration and stops the parse.
    private func refuseEntities(_ parser: XMLParser) {
        declaresEntities = true
        parser.abortParsing()
    }
}
