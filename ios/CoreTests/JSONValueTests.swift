import XCTest
@testable import LongPingCore

final class JSONValueTests: XCTestCase {
    func testSerializesNumbersShortestAndIntegralWithoutFraction() {
        XCTAssertEqual(JSONValue.number(4.8).serialized(), "4.8")
        XCTAssertEqual(JSONValue.number(181.0).serialized(), "181")
        XCTAssertEqual(JSONValue.number(-1).serialized(), "-1")
        XCTAssertEqual(JSONValue.number(1_761_480_000_123).serialized(), "1761480000123")
        XCTAssertEqual(JSONValue.number(.nan).serialized(), "null")
        XCTAssertEqual(JSONValue.number(-0.0).serialized(), "0")
    }

    func testEscapesStrings() {
        XCTAssertEqual(JSONValue.string("a\"b\\c\nd\u{01}").serialized(), "\"a\\\"b\\\\c\\nd\\u0001\"")
        XCTAssertEqual(JSONValue.string("Sarajevo ✓").serialized(), "\"Sarajevo ✓\"")
    }

    func testObjectsKeepInsertionOrder() {
        let value: JSONValue = ["z": 1, "a": [true, .null, "x"], "m": ["k": 2.5]]
        XCTAssertEqual(value.serialized(), "{\"z\":1,\"a\":[true,null,\"x\"],\"m\":{\"k\":2.5}}")
    }

    func testParseRoundTripsAndDistinguishesBooleansFromNumbers() throws {
        let parsed = try JSONValue.parse("{\"b\":true,\"n\":1,\"f\":0,\"s\":\"x\",\"nul\":null,\"arr\":[1.5]}")
        XCTAssertEqual(parsed["b"], .bool(true))
        XCTAssertEqual(parsed["n"], .number(1))
        XCTAssertEqual(parsed["f"], .number(0))
        XCTAssertEqual(parsed["s"], .string("x"))
        XCTAssertEqual(parsed["nul"], .null)
        XCTAssertEqual(parsed["arr"], .array([.number(1.5)]))
        XCTAssertEqual(try JSONValue.parse(parsed.serialized()), parsed)
    }

    func testParseRejectsInvalidJSON() {
        XCTAssertThrowsError(try JSONValue.parse("{\"a\":"))
        XCTAssertThrowsError(try JSONValue.parse(""))
    }

    func testFoundationBridgeHandlesNSNumberBooleansAndRejectsUnsupported() {
        let dict: [String: Any] = ["yes": NSNumber(value: true), "one": NSNumber(value: 1), "null": NSNull(),
                                   "nested": ["list": [1, "a"]]]
        let value = JSONValue(foundation: dict)
        XCTAssertEqual(value?["yes"], .bool(true))
        XCTAssertEqual(value?["one"], .number(1))
        XCTAssertEqual(value?["null"], .null)
        XCTAssertEqual(value?["nested"]?["list"], .array([.number(1), .string("a")]))
        XCTAssertNil(JSONValue(foundation: ["date": Date()]))

        let back = value?.foundationObject as? [String: Any]
        XCTAssertEqual(back?["yes"] as? Bool, true)
        XCTAssertTrue(back?["null"] is NSNull)
    }

    func testDeepMergeMergesObjectsAndReplacesArraysAndScalars() {
        let base: JSONValue = ["a": 1, "o": ["x": 1, "y": 2], "arr": [1, 2, 3]]
        let patch: JSONValue = ["o": ["y": 20, "z": 30], "arr": [9], "b": true]
        let merged = base.deepMerged(with: patch)
        XCTAssertEqual(merged, ["a": 1, "o": ["x": 1, "y": 20, "z": 30], "arr": [9], "b": true])
        XCTAssertEqual(base.deepMerged(with: ["o": .null])["o"], .null)
    }

    func testObjectEqualityIgnoresOrderAndSubscriptRemoves() {
        var a = JSONObject([("x", 1), ("y", 2)])
        let b = JSONObject([("y", 2), ("x", 1)])
        XCTAssertEqual(a, b)
        a["x"] = nil
        XCTAssertEqual(a.keys, ["y"])
        XCTAssertEqual(a.merging(JSONObject([("y", 3), ("z", 4)])).keys, ["y", "z"])
    }
}

final class TimestampTests: XCTestCase {
    func testFormatsUTCWithMilliseconds() {
        XCTAssertEqual(Timestamp.iso8601(0), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(Timestamp.iso8601(1_793_016_000_123), "2026-10-26T12:00:00.123Z")
        XCTAssertEqual(Timestamp.iso8601(-1), "1969-12-31T23:59:59.999Z")
    }

    func testParsesWhatItFormats() {
        for ms: EpochMs in [0, 1_793_016_000_123, 951_782_400_000, 4_102_444_799_999] {
            XCTAssertEqual(Timestamp.parseISO8601(Timestamp.iso8601(ms)), ms)
        }
        XCTAssertNil(Timestamp.parseISO8601("2026-10-26T12:00:00Z"))
        XCTAssertNil(Timestamp.parseISO8601("2026-13-26T12:00:00.000Z"))
    }

    func testSystemClockIsNearNow() {
        let now = EpochMs(Date().timeIntervalSince1970 * 1000)
        XCTAssertLessThan(abs(SystemClock().nowMs - now), 1000)
    }
}
