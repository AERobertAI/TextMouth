//
//  DataNode.swift
//  SwifSoup
//
//  Created by Nabil Chatbi on 29/09/16.
//

import Foundation

/**
 A data node, for contents of style, script tags etc, where contents should not show in text().
 */
public final class DataNode: Node {
    private static let DATA_KEY  = "data".utf8Array
    private var rawDataSlice: ByteSlice? = nil
    private var rawDataSlices: [ByteSlice]? = nil
    private var rawDataSlicesCount: Int = 0

    /**
     Create a new DataNode.
     - parameter data: data contents
     - parameter baseUri: base URI
     */
    public init(_ data: [UInt8], _ baseUri: [UInt8]) {
        super.init(baseUri)
        do {
            try ensureAttributesForWrite().put(DataNode.DATA_KEY, data)
        } catch {}

    }

    internal init(slice: ByteSlice, baseUri: [UInt8]) {
        super.init(baseUri)
        rawDataSlice = slice
        rawDataSlices = nil
        rawDataSlicesCount = 0
    }

    internal convenience init(slice: ArraySlice<UInt8>, baseUri: [UInt8]) {
        self.init(slice: ByteSlice.fromArraySlice(slice), baseUri: baseUri)
    }

    override func nodeNameUTF8() -> [UInt8] {
        return nodeName().utf8Array
    }
    
    override func nodeName() -> String {
        return "#data"
    }

    /**
     Get the data contents of this node. Will be unescaped and with original new lines, space etc.
     - returns: data
     */
    public func getWholeData() -> String {
        return String(decoding: getWholeDataUTF8(), as: UTF8.self)
    }
    
    private func materializeRawDataIfNeeded() -> [UInt8]? {
        if let slices = rawDataSlices {
            var out: [UInt8] = []
            out.reserveCapacity(rawDataSlicesCount)
            for slice in slices {
                out.append(contentsOf: slice)
            }
            rawDataSlices = nil
            rawDataSlicesCount = 0
            rawDataSlice = nil
            return out
        }
        if let slice = rawDataSlice {
            rawDataSlice = nil
            return slice.toArray()
        }
        return nil
    }

    func getWholeDataUTF8() -> [UInt8] {
        if let materialized = materializeRawDataIfNeeded() {
            do {
                try ensureAttributesForWrite().put(DataNode.DATA_KEY, materialized)
            } catch {}
            return materialized
        }
        guard let attributes = attributes else {
            return []
        }
        if let slice = attributes.valueSliceCaseSensitive(DataNode.DATA_KEY) {
            return slice.toArray()
        }
        return []
    }

    internal func wholeDataSlice() -> ByteSlice {
        if let slice = rawDataSlice {
            return slice
        }
        if rawDataSlices != nil {
            let materialized = getWholeDataUTF8()
            return ByteSlice.fromArray(materialized)
        }
        guard let attributes = attributes else {
            return ByteSlice.empty
        }
        return attributes.valueSliceCaseSensitive(DataNode.DATA_KEY) ?? ByteSlice.empty
    }

    internal func appendSlice(_ slice: ByteSlice) {
        if let attrs = attributes {
            if !attrs.hasKey(key: DataNode.DATA_KEY) {
                if let slices = rawDataSlices {
                    for existing in slices {
                        attrs.appendValueSlice(key: DataNode.DATA_KEY, slice: existing)
                    }
                    rawDataSlices = nil
                    rawDataSlicesCount = 0
                } else if let existingSlice = rawDataSlice {
                    attrs.appendValueSlice(key: DataNode.DATA_KEY, slice: existingSlice)
                    rawDataSlice = nil
                }
            }
            attrs.appendValueSlice(key: DataNode.DATA_KEY, slice: slice)
        } else if var slices = rawDataSlices {
            slices.append(slice)
            rawDataSlices = slices
            rawDataSlicesCount += slice.count
        } else if let existingSlice = rawDataSlice {
            rawDataSlices = [existingSlice, slice]
            rawDataSlicesCount = existingSlice.count + slice.count
            rawDataSlice = nil
        } else {
            rawDataSlice = slice
        }
        markSourceDirty()
    }

    internal func extendSliceFromSourceRange(_ source: SourceBuffer, newRange: SourceRange) -> Bool {
        guard rawDataSlice != nil,
              rawDataSlices == nil,
              attributes == nil,
              !sourceRangeDirty
        else {
            return false
        }
        guard let existingRange = sourceRange,
              existingRange.isValid,
              newRange.isValid,
              existingRange.end == newRange.start,
              newRange.end <= source.bytes.count
        else {
            return false
        }
        rawDataSlice = ByteSlice(storage: source.storage, start: existingRange.start, end: newRange.end)
        rawDataSlicesCount = 0
        return true
    }


    internal func appendBytes(_ bytes: [UInt8]) {
        appendSlice(ByteSlice.fromArray(bytes))
    }




    /**
     Set the data contents of this node.
     - parameter data: unencoded data
     - returns: this node, for chaining
     */
    @discardableResult
    func setWholeData(_ data: String) -> DataNode {
        rawDataSlice = nil
        rawDataSlices = nil
        rawDataSlicesCount = 0
        do {
            try ensureAttributesForWrite().put(DataNode.DATA_KEY, data.utf8Array)
        } catch {}
        markSourceDirty()
        return self
    }


    override func outerHtmlHead(_ accum: StringBuilder, _ depth: Int, _ out: OutputSettings)throws {
        accum.append(wholeDataSlice()) // data is not escaped in return from data nodes, so " in script, style is plain
    }

    override func outerHtmlTail(_ accum: StringBuilder, _ depth: Int, _ out: OutputSettings) {}

    /**
     Create a new DataNode from HTML encoded data.
     - parameter encodedData: encoded data
     - parameter baseUri: bass URI
     - returns: new DataNode
     */
    static func createFromEncoded(_ encodedData: String, _ baseUri: String) throws -> DataNode {
        let data = try Entities.unescape(encodedData.utf8Array)
        return DataNode(data, baseUri.utf8Array)
    }

    public override func copy(with zone: NSZone? = nil) -> Any {
		let clone = DataNode(getWholeDataUTF8(), baseUri!)
		return copy(clone: clone)
	}

	public override func copy(parent: Node?) -> Node {
		let clone = DataNode(getWholeDataUTF8(), baseUri!)
		return copy(clone: clone, parent: parent)
	}

    override func copyForDeepClone(parent: Node?) -> Node {
        let clone = DataNode(getWholeDataUTF8(), baseUri!)
        return copy(clone: clone, parent: parent, copyChildren: false, rebuildIndexes: false)
    }

    public override func copy(clone: Node, parent: Node?) -> Node {
		return super.copy(clone: clone, parent: parent)
	}
}
