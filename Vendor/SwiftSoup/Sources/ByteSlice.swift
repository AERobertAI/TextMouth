import Foundation

final class ByteStorage: @unchecked Sendable {
    enum Backing {
        case array([UInt8])
        case data(Data)
        case buffer(UnsafePointer<UInt8>, Int, AnyObject?)
    }

    let backing: Backing

    init(array: [UInt8]) {
        self.backing = .array(array)
    }

    init(data: Data) {
        self.backing = .data(data)
    }

    init(buffer base: UnsafePointer<UInt8>, count: Int, owner: AnyObject?) {
        self.backing = .buffer(base, count, owner)
    }

    func byte(at index: Int) -> UInt8 {
        switch backing {
        case .array(let array):
            return array[index]
        case .data(let data):
            return data[data.startIndex + index]
        case .buffer(let base, _, _):
            return base[index]
        }
    }

    func withUnsafeBytes<R>(_ start: Int, _ end: Int, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        let length = end - start
        switch backing {
        case .array(let array):
            return try array.withUnsafeBufferPointer { buf in
                let base = buf.baseAddress
                let slice = UnsafeBufferPointer(start: base == nil ? nil : base! + start, count: length)
                return try body(slice)
            }
        case .data(let data):
            return try data.withUnsafeBytes { raw in
                let base = raw.bindMemory(to: UInt8.self).baseAddress
                let slice = UnsafeBufferPointer(start: base == nil ? nil : base! + start, count: length)
                return try body(slice)
            }
        case .buffer(let base, _, _):
            let slice = UnsafeBufferPointer(start: base + start, count: length)
            return try body(slice)
        }
    }

    func toArray(_ start: Int, _ end: Int) -> [UInt8] {
        let length = end - start
        if length <= 0 { return [] }
        switch backing {
        case .array(let array):
            return Array(array[start..<end])
        case .data(let data):
            return Array(data[data.startIndex + start ..< data.startIndex + end])
        case .buffer(let base, _, _):
            return Array(UnsafeBufferPointer(start: base + start, count: length))
        }
    }

    func toArraySlice(_ start: Int, _ end: Int) -> ArraySlice<UInt8> {
        switch backing {
        case .array(let array):
            return array[start..<end]
        case .data:
            return ArraySlice(toArray(start, end))
        case .buffer:
            return ArraySlice(toArray(start, end))
        }
    }
}

struct ByteSlice: RandomAccessCollection, Hashable, Sendable {
    typealias Index = Int
    typealias Element = UInt8
    typealias SubSequence = ByteSlice

    let storage: ByteStorage
    let start: Int
    let end: Int

    init(storage: ByteStorage, start: Int, end: Int) {
        self.storage = storage
        self.start = start
        self.end = end
    }

    var startIndex: Int { 0 }

    var endIndex: Int { end - start }

    var count: Int { end - start }

    var isEmpty: Bool { start >= end }

    subscript(position: Int) -> UInt8 {
        return storage.byte(at: start + position)
    }

    subscript(bounds: Range<Int>) -> ByteSlice {
        return ByteSlice(storage: storage, start: start + bounds.lowerBound, end: start + bounds.upperBound)
    }

    func toArray() -> [UInt8] {
        return storage.toArray(start, end)
    }

    func toArraySlice() -> ArraySlice<UInt8> {
        return storage.toArraySlice(start, end)
    }

    func withUnsafeBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        return try storage.withUnsafeBytes(start, end, body)
    }

    func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        return try withUnsafeBytes(body)
    }
}

extension ByteSlice {
    static let emptyStorage = ByteStorage(array: [])
    static let empty = ByteSlice(storage: emptyStorage, start: 0, end: 0)

    func lowercased() -> ByteSlice {
        var needsLower = false
        for b in self {
            if b >= 65 && b <= 90 { needsLower = true; break }
        }
        if !needsLower { return self }
        var out: [UInt8] = []
        out.reserveCapacity(count)
        for b in self {
            if b >= 65 && b <= 90 {
                out.append(b + 32)
            } else {
                out.append(b)
            }
        }
        let storage = ByteStorage(array: out)
        return ByteSlice(storage: storage, start: 0, end: out.count)
    }

    func trim() -> ByteSlice {
        func isWhitespace(_ byte: UInt8) -> Bool {
            return byte == TokeniserStateVars.spaceByte ||
                (byte >= TokeniserStateVars.tabByte && byte <= TokeniserStateVars.carriageReturnByte)
        }

        var s = start
        var e = end
        var trimmed = false
        while s < e, isWhitespace(storage.byte(at: s)) {
            s &+= 1
            trimmed = true
        }
        while s < e, isWhitespace(storage.byte(at: e - 1)) {
            e &-= 1
            trimmed = true
        }
        return trimmed ? ByteSlice(storage: storage, start: s, end: e) : self
    }
}

extension ByteSlice {
    static func fromArray(_ array: [UInt8]) -> ByteSlice {
        let storage = ByteStorage(array: array)
        return ByteSlice(storage: storage, start: 0, end: array.count)
    }

    static func fromArraySlice(_ slice: ArraySlice<UInt8>) -> ByteSlice {
        return fromArray(Array(slice))
    }
}

extension ByteSlice {
    static func == (lhs: ByteSlice, rhs: ByteSlice) -> Bool {
        if lhs.count != rhs.count { return false }
        var i = lhs.startIndex
        while i < lhs.endIndex {
            if lhs[i] != rhs[i] { return false }
            i = lhs.index(after: i)
        }
        return true
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(count)
        for b in self {
            hasher.combine(b)
        }
    }
}
