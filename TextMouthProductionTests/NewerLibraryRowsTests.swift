import XCTest
@testable import TextMouth

/// library.json keeps what a newer TextMouth wrote (V03): a row it cannot
/// read stays in the file, exactly as it was, and a sort field it does not
/// know is written back as it was, so going back to this version never
/// loses a library.
final class NewerLibraryRowsTests: XCTestCase {

    // MARK: - JSONValue

    /// Decodes `json` (a complete JSON text) as a `JSONValue`.
    private func decodeValue(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    /// Encodes `value` as the text it is written as, with sorted keys so the
    /// text is the same every time.
    private func encodedText(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// A value holding every case survives encoding and decoding unchanged.
    /// The top level is an array, which every JSON reader accepts.
    func testAValueHoldingEveryCaseRoundTrips() throws {
        let value = JSONValue.array([
            .object([
                "nothing": .null,
                "flag": .bool(false),
                "whole": .integer(-7),
                "fraction": .number(2.5),
                "text": .string("héllo \"quoted\""),
                "list": .array([.integer(1), .string("two"), .null]),
                "inner": .object(["deep": .array([])]),
            ]),
        ])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }

    /// A whole number stays an integer: it is read as one and written back
    /// as `3`, never `3.0`.
    func testAWholeNumberStaysAnInteger() throws {
        XCTAssertEqual(try decodeValue("3"), .integer(3))
        XCTAssertEqual(try encodedText(.integer(3)), "3")
    }

    /// A number with a fraction is a number, written back with its fraction.
    func testANumberWithAFractionStaysANumber() throws {
        XCTAssertEqual(try decodeValue("2.5"), .number(2.5))
        XCTAssertEqual(try encodedText(.number(2.5)), "2.5")
    }

    /// `1` and `0` are integers, never bools: a row's counts must not come
    /// back as `true` and `false`.
    func testOneAndZeroAreIntegersNotBools() throws {
        XCTAssertEqual(try decodeValue("1"), .integer(1))
        XCTAssertEqual(try decodeValue("0"), .integer(0))
        XCTAssertEqual(try encodedText(.integer(1)), "1")
        XCTAssertEqual(try encodedText(.integer(0)), "0")
    }

    /// `true` is a bool, never an integer, and `false` likewise.
    func testABoolIsNeverAnInteger() throws {
        XCTAssertEqual(try decodeValue("true"), .bool(true))
        XCTAssertEqual(try decodeValue("false"), .bool(false))
        XCTAssertEqual(try encodedText(.bool(true)), "true")
    }

    /// An ISO 8601 date is only text here, and stays the string it was.
    func testADateStaysTheStringItWas() throws {
        let value = try decodeValue("\"2026-10-23T04:20:00Z\"")
        XCTAssertEqual(value, .string("2026-10-23T04:20:00Z"))
        XCTAssertEqual(value.stringValue, "2026-10-23T04:20:00Z")
    }

    /// The convenience members read an object's member and a string, and
    /// give nil for anything else.
    func testTheConvenienceMembersGiveNilForTheWrongKind() throws {
        let object = try decodeValue("{\"id\": \"abc\", \"count\": 2}")
        XCTAssertEqual(object["id"], .string("abc"))
        XCTAssertNil(object["missing"])
        XCTAssertNil(object["count"]?.stringValue)
        XCTAssertNil(JSONValue.array([])["id"])
        XCTAssertNil(JSONValue.null.stringValue)
    }

    /// A value nested 100 arrays deep is refused with an error, not decoded
    /// and not trapped on.
    func testAValueNestedTooDeeplyThrows() {
        let json = String(repeating: "[", count: 100) + String(repeating: "]", count: 100)
        XCTAssertThrowsError(try decodeValue(json)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
            XCTAssertTrue(context.debugDescription.contains("\(JSONValue.maximumDepth)"))
        }
    }

    /// Objects nested too deeply are refused the same way.
    func testObjectsNestedTooDeeplyThrow() {
        let json = String(repeating: "{\"a\":", count: 100) + "1" + String(repeating: "}", count: 100)
        XCTAssertThrowsError(try decodeValue(json))
    }

    /// A value nested 30 arrays deep is within the limit and decodes.
    func testAValueNestedThirtyDeepDecodes() throws {
        let json = String(repeating: "[", count: 30) + String(repeating: "]", count: 30)
        var value = try decodeValue(json)
        var depth = 0
        while case .array(let items) = value, let first = items.first {
            value = first
            depth += 1
        }
        XCTAssertEqual(depth, 29)
    }
}
