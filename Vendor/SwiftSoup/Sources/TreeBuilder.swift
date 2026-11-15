//
//  TreeBuilder.swift
//  SwiftSoup
//
//  Created by Nabil Chatbi on 24/10/16.
//

import Foundation

class TreeBuilder {
    var reader: CharacterReader
    var tokeniser: Tokeniser
    var doc: Document // current doc we are building into
    var stack: Array<Element> // the stack of open elements
    var baseUri: [UInt8] // current base uri, for creating new elements
    var currentToken: Token? // currentToken is used only for error tracking.
    var errors: ParseErrorList // null when not tracking errors
    var settings: ParseSettings
    var tracksSourceRanges: Bool = false
    var tracksErrors: Bool = false
    var pendingAttributeElements: [Element] = []
    
    private let start: Token.StartTag = Token.StartTag() // start tag to process
    private let end: Token.EndTag  = Token.EndTag()
    
    /// Bulk-build suppression flag
    var isBulkBuilding: Bool = false
    
    
    func defaultSettings() -> ParseSettings {preconditionFailure("This method must be overridden")}
    
    public init() {
        doc =  Document([])
        reader = CharacterReader([])
        stack = Array<Element>()
        baseUri = []
        errors = ParseErrorList(0, 0)
        settings = ParseSettings(false, false)
        tokeniser = Tokeniser(reader, nil, settings)
    }
    
    func beginBulkAppend() {
        isBulkBuilding = true
    }
    
    func endBulkAppend() {
        isBulkBuilding = false
    }
    
    func initialiseParse(_ input: [UInt8], _ baseUri: [UInt8], _ errors: ParseErrorList, _ settings: ParseSettings) {
        doc = Document(baseUri)
        tracksSourceRanges = settings.tracksSourceRanges()
        if tracksSourceRanges {
            doc.sourceBuffer = SourceBuffer(input)
        } else {
            doc.sourceBuffer = nil
        }
        doc.parsedAsXml = false
        self.settings = settings
        let parseBuffer: [UInt8]
        if tracksSourceRanges, let sourceBuffer = doc.sourceBuffer {
            parseBuffer = sourceBuffer.bytes
        } else {
            parseBuffer = input
        }
        reader = CharacterReader(parseBuffer)
        self.errors = errors
        tracksErrors = errors.getMaxSize() > 0
        tokeniser = Tokeniser(reader, tracksErrors ? errors : nil, settings)
        stack = Array<Element>()
        self.baseUri = baseUri
        pendingAttributeElements.removeAll(keepingCapacity: true)
    }

    func initialiseParse(_ input: UnsafeBufferPointer<UInt8>, owner: AnyObject?, _ baseUri: [UInt8], _ errors: ParseErrorList, _ settings: ParseSettings) {
        doc = Document(baseUri)
        tracksSourceRanges = settings.tracksSourceRanges()
        if tracksSourceRanges {
            let copied = Array(input)
            doc.sourceBuffer = SourceBuffer(copied)
            reader = CharacterReader(copied)
        } else {
            doc.sourceBuffer = nil
            reader = CharacterReader(input, owner: owner)
        }
        doc.parsedAsXml = false
        self.settings = settings
        self.errors = errors
        tracksErrors = errors.getMaxSize() > 0
        tokeniser = Tokeniser(reader, tracksErrors ? errors : nil, settings)
        stack = Array<Element>()
        self.baseUri = baseUri
        pendingAttributeElements.removeAll(keepingCapacity: true)
    }
    
    func parse(_ input: [UInt8], _ baseUri: [UInt8],
               _ errors: ParseErrorList,
               _ settings: ParseSettings) throws -> Document {
        // Associate builder for node-level checks
        doc.treeBuilder = self
        
        // Suppress per-append index invalidation; rebuild once at end
        beginBulkAppend()
        defer { endBulkAppend() }
        
        initialiseParse(input, baseUri, errors, settings)
        try runParser()
        if !tracksSourceRanges, !pendingAttributeElements.isEmpty {
            for element in pendingAttributeElements {
                element.attributes?.ensureMaterialized()
            }
            pendingAttributeElements.removeAll(keepingCapacity: true)
        }
        return doc
    }

    func parse(_ input: UnsafeBufferPointer<UInt8>, owner: AnyObject?, _ baseUri: [UInt8],
               _ errors: ParseErrorList,
               _ settings: ParseSettings) throws -> Document {
        doc.treeBuilder = self
        beginBulkAppend()
        defer { endBulkAppend() }

        initialiseParse(input, owner: owner, baseUri, errors, settings)
        try runParser()
        if !tracksSourceRanges, !pendingAttributeElements.isEmpty {
            for element in pendingAttributeElements {
                element.attributes?.ensureMaterialized()
            }
            pendingAttributeElements.removeAll(keepingCapacity: true)
        }
        return doc
    }
    
    func registerPendingAttributes(_ element: Element) {
        guard !tracksSourceRanges else { return }
        if let attributes = element.attributes,
           attributes.pendingAttributesCount > 0 {
            pendingAttributeElements.append(element)
        }
    }
    
    func runParser() throws {
        while (true) {
            let token: Token = try tokeniser.read()
            try process(token)
            if (token.type == Token.TokenType.EOF) {
                break
            }
        }
    }

    @discardableResult
    func process(_ token: Token)throws->Bool {preconditionFailure("This method must be overridden")}
    
    @discardableResult
    func processStartTag(_ name: [UInt8]) throws -> Bool {
        if (currentToken === start) { // don't recycle an in-use token
            return try process(Token.StartTag().name(name))
        }
        return try process(start.reset().name(name))
    }
    
    @discardableResult
    func processStartTag(_ name: String) throws -> Bool {
        return try processStartTag(name.utf8Array)
    }
    
    @discardableResult
    func processStartTag(_ name: [UInt8], _ attrs: Attributes) throws -> Bool {
        if (currentToken === start) { // don't recycle an in-use token
            return try process(Token.StartTag().nameAttr(name, attrs))
        }
        start.reset()
        start.nameAttr(name, attrs)
        return try process(start)
    }
    
    @discardableResult
    func processStartTag(_ name: String, _ attrs: Attributes) throws -> Bool {
        return try processStartTag(name.utf8Array, attrs)
    }
    
    @discardableResult
    func processEndTag(_ name: [UInt8]) throws -> Bool {
        if (currentToken === end) { // don't recycle an in-use token
            return try process(Token.EndTag().name(name))
        }
        
        return try process(end.reset().name(name))
    }

    
    @discardableResult
    func processEndTag(_ name: String) throws -> Bool {
        return try processEndTag(name.utf8Array)
    }
    
    func currentElement() -> Element? {
        return stack.last
    }
}
