//
//  Comment.swift
//  SwiftSoup
//
//  Created by Nabil Chatbi on 22/10/16.
//

import Foundation

/**
 A comment node.
 */
public final class Comment: Node {
    private static let COMMENT_KEY: [UInt8] = UTF8Arrays.comment
    private static let commentKeySlice: ByteSlice = ByteSlice.fromArray(UTF8Arrays.comment)

    /**
     Create a new comment node.
     - parameter data: The contents of the comment
     - parameter baseUri: base URI
     */
    public init(_ data: [UInt8], _ baseUri: [UInt8]) {
        super.init(baseUri)
        do {
            let attr = try Attribute(keySlice: Comment.commentKeySlice, valueSlice: ByteSlice.fromArray(data))
            ensureAttributesForWrite().put(attribute: attr)
        } catch {}
    }

    internal init(slice: ByteSlice, _ baseUri: [UInt8]) {
        super.init(baseUri)
        do {
            let attr = try Attribute(keySlice: Comment.commentKeySlice, valueSlice: slice)
            ensureAttributesForWrite().put(attribute: attr)
        } catch {}
    }

    override func nodeNameUTF8() -> [UInt8] {
        return nodeName().utf8Array
    }
    
    override func nodeName() -> String {
        return "#comment"
    }

    /**
     Get the contents of the comment.
     - returns: comment content
     */
    public func getData() -> String {
        return String(decoding: getDataUTF8(), as: UTF8.self)
    }
    
    func getDataUTF8() -> [UInt8] {
        guard let attributes = attributes else {
            return []
        }
        return (attributes.valueSliceCaseSensitive(Comment.COMMENT_KEY) ?? ByteSlice.empty).toArray()
    }

    private func dataSlice() -> ByteSlice {
        guard let attributes else { return ByteSlice.empty }
        return attributes.valueSliceCaseSensitive(Comment.COMMENT_KEY) ?? ByteSlice.empty
    }


    override func outerHtmlHead(_ accum: StringBuilder, _ depth: Int, _ out: OutputSettings) {
        if (out.prettyPrint()) {
            indent(accum, depth, out)
        }
        accum
            .append("<!--")
            .append(dataSlice())
            .append("-->")
    }

    override func outerHtmlTail(_ accum: StringBuilder, _ depth: Int, _ out: OutputSettings) {}

	public override func copy(with zone: NSZone? = nil) -> Any {
        let clone = Comment(slice: dataSlice(), baseUri!)
		return copy(clone: clone)
	}

	public override func copy(parent: Node?) -> Node {
        let clone = Comment(slice: dataSlice(), baseUri!)
		return copy(clone: clone, parent: parent)
	}

    override func copyForDeepClone(parent: Node?) -> Node {
        let clone = Comment(slice: dataSlice(), baseUri!)
        return copy(clone: clone, parent: parent, copyChildren: false, rebuildIndexes: false)
    }

    public override func copy(clone: Node, parent: Node?) -> Node {
		return super.copy(clone: clone, parent: parent)
	}
}
