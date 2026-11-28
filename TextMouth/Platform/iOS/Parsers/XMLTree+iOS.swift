// Phase 0 stand-in: Foundation's XML tree on the Mac. On the Mac,
// `XMLDocument`, `XMLElement`, and `XMLNode` are Foundation's own, and the
// EPUB, feed, and OPML readers walk them and search them with XPath. iOS's
// Foundation has only the streaming `XMLParser`, so on iOS those three names
// are the portable tree (TextMouth/Parsers/PortableXML.swift), which has the
// part of Foundation's interface the readers use, and the reader files
// compile for iOS as they are. The Mac never compiles this file.

import Foundation

/// An XML document: the portable tree's, on iOS.
typealias XMLDocument = PortableXMLDocument
/// An XML element: the portable tree's, on iOS.
typealias XMLElement = PortableXMLElement
/// An XML node: the portable tree's, on iOS.
typealias XMLNode = PortableXMLNode
