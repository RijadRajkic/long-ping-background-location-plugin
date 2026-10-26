import XCTest
@testable import LongPingCore

private let sampleFix = Fix(latitude: 43.85, longitude: 18.41, accuracy: 4.8, speed: 12.3, heading: 181,
                            altitude: 520.4, time: 1_793_016_000_123)

private func makeRecord(_ uuid: String = "6f1c2a1e-0000-4000-8000-000000000001", fix: Fix = sampleFix,
                    extras: JSONObject = JSONObject()) -> LocationRecord {
    LocationRecord(uuid: uuid, fix: fix, event: .interval, isMoving: true,
                   battery: BatterySnapshot(level: 0.82, isCharging: false), extras: extras)
}

final class LocationRecordTests: XCTestCase {
    func testJSONMatchesContract() {
        XCTAssertEqual(makeRecord().json.serialized(),
                       "{\"uuid\":\"6f1c2a1e-0000-4000-8000-000000000001\",\"timestamp\":\"2026-10-26T12:00:00.123Z\","
                       + "\"event\":\"interval\",\"is_moving\":true,\"coords\":{\"latitude\":43.85,\"longitude\":18.41,"
                       + "\"accuracy\":4.8,\"speed\":12.3,\"heading\":181,\"altitude\":520.4},"
                       + "\"battery\":{\"level\":0.82,\"is_charging\":false},\"mock\":false}")
    }

    func testUnknownValues() {
        let unknown = Fix(latitude: 1, longitude: 2, accuracy: 3, speed: -5, heading: -0.5, altitude: nil, time: 0, isMock: true)
        let json = LocationRecord(uuid: "u", fix: unknown, event: .current, isMoving: false, battery: .unknown).json
        XCTAssertEqual(json["coords"]?["speed"], .number(-1))
        XCTAssertEqual(json["coords"]?["heading"], .number(-1))
        XCTAssertEqual(json["coords"]?["altitude"], .null)
        XCTAssertEqual(json["battery"]?["level"], .number(-1))
        XCTAssertEqual(json["mock"], .bool(true))
        XCTAssertEqual(json["event"], .string("current"))
        XCTAssertEqual(json["is_moving"], .bool(false))
    }

    func testExtrasOnlyWhenNonEmpty() {
        XCTAssertNil(makeRecord().json["extras"])
        XCTAssertEqual(makeRecord(extras: JSONObject([("driver", 7)])).json["extras"], ["driver": 7])
    }

    func testBatteryLevelNormalized() {
        XCTAssertEqual(LocationRecord.normalizedLevel(Double(Float(0.82))), 0.82)
        XCTAssertEqual(LocationRecord.normalizedLevel(1.2), 1)
        XCTAssertEqual(LocationRecord.normalizedLevel(-0.5), -1)
    }

    func testUUIDIsLowercaseV4() {
        let uuid = LocationRecord.makeUUID()
        XCTAssertEqual(uuid, uuid.lowercased())
        XCTAssertEqual(uuid.count, 36)
        XCTAssertEqual(Array(uuid)[14], "4")
        XCTAssertNotEqual(LocationRecord.makeUUID(), uuid)
    }
}

final class LocationTemplateTests: XCTestCase {
    func testRendersRawValuesWithoutQuotingStrings() throws {
        let template = "{\"id\":\"{{uuid}}\",\"t\":\"{{timestamp}}\",\"e\":\"{{event}}\",\"m\":{{is_moving}},"
            + "\"lat\":{{latitude}},\"lng\":{{longitude}},\"acc\":{{accuracy}},\"spd\":{{speed}},\"hdg\":{{heading}},"
            + "\"alt\":{{altitude}},\"bat\":{{battery_level}},\"chg\":{{battery_is_charging}},\"mock\":{{mock}},\"x\":{{extras}}}"
        let rendered = LocationTemplate.render(template, record: makeRecord(extras: JSONObject([("k", "v")])).json)
        XCTAssertEqual(rendered,
                       "{\"id\":\"6f1c2a1e-0000-4000-8000-000000000001\",\"t\":\"2026-10-26T12:00:00.123Z\",\"e\":\"interval\","
                       + "\"m\":true,\"lat\":43.85,\"lng\":18.41,\"acc\":4.8,\"spd\":12.3,\"hdg\":181,\"alt\":520.4,"
                       + "\"bat\":0.82,\"chg\":false,\"mock\":false,\"x\":{\"k\":\"v\"}}")
        XCTAssertNoThrow(try JSONValue.parse(rendered))
    }

    func testMissingValuesRenderAsJSON() {
        let noAltitude = Fix(latitude: 1, longitude: 2, accuracy: 3, time: 0)
        let json = LocationRecord(uuid: "u", fix: noAltitude, event: .interval, isMoving: true, battery: .unknown).json
        XCTAssertEqual(LocationTemplate.render("[{{altitude}},{{extras}},{{ speed }}]", record: json), "[null,{},-1]")
    }

    func testTokenScanning() {
        XCTAssertEqual(LocationTemplate.tokenNames(in: "{\"a\":{{latitude}},\"b\":{{ nope }}}"), ["latitude", "nope"])
        XCTAssertEqual(LocationTemplate.tokenNames(in: "{\"a\":\"{{unclosed\"}"), [])
        XCTAssertEqual(LocationTemplate.render("{\"a\":\"{{unclosed\"}", record: makeRecord().json), "{\"a\":\"{{unclosed\"}")
    }

    func testValidation() {
        XCTAssertNoThrow(try LocationTemplate.validate("{\"lat\":{{latitude}}}", extras: JSONObject()))
        XCTAssertThrowsError(try LocationTemplate.validate("{\"lat\":{{lat}}}", extras: JSONObject())) {
            XCTAssertEqual(($0 as? ConfigError)?.reason, "has unknown token {{lat}}")
        }
        XCTAssertThrowsError(try LocationTemplate.validate("{\"id\":{{uuid}}}", extras: JSONObject()))
        XCTAssertEqual(LocationTemplate.tokens.count, 14)
    }
}

final class UploadBodyTests: XCTestCase {
    private var http = HTTPConfig()

    private func stored(_ uuid: String) -> String { makeRecord(uuid).json.serialized() }

    func testBatchDefaultsToLocationsAndMergesParams() {
        http.params = JSONObject([("device", "abc"), ("locations", "overwritten")])
        let items = [makeRecord("a").json, makeRecord("b").json]
        let body = UploadBody.batch(items, http: http)
        XCTAssertEqual(body.objectValue?.keys, ["device", "locations"])
        XCTAssertEqual(body["locations"], .array(items))
        XCTAssertEqual(body["device"], "abc")
    }

    func testBatchCustomRootAndDotFallsBack() {
        http.rootProperty = "data"
        XCTAssertEqual(UploadBody.batch([1], http: http), ["data": [1]])
        http.rootProperty = "."
        XCTAssertEqual(UploadBody.batch([1], http: http), ["locations": [1]])
    }

    func testSingleRootVariants() {
        let r = makeRecord().json
        http.params = JSONObject([("device", "abc"), ("uuid", "param-loses")])
        XCTAssertEqual(UploadBody.single(r, http: http)["location"], r)
        http.rootProperty = "loc"
        XCTAssertEqual(UploadBody.single(r, http: http)["loc"], r)
        http.rootProperty = "."
        let root = UploadBody.single(r, http: http)
        XCTAssertEqual(root["device"], "abc")
        XCTAssertEqual(root["uuid"], r["uuid"], "record keys win over params")
        XCTAssertEqual(root["coords"], r["coords"])
        XCTAssertEqual(UploadBody.single([1, 2], http: http)["location"], [1, 2], "non-object at root falls back")
    }

    func testItemUsesTemplateWhenSet() {
        XCTAssertEqual(UploadBody.item(fromStored: stored("a"), http: http)?.value, makeRecord("a").json)
        http.locationTemplate = "{\"id\":\"{{uuid}}\",\"lat\":{{latitude}}}"
        XCTAssertEqual(UploadBody.item(fromStored: stored("a"), http: http), UploadBody.Item(value: ["id": "a", "lat": 43.85]))
    }

    func testItemFallsBackWhenTemplateBreaksAndRejectsCorruptRows() {
        http.locationTemplate = "{\"id\":{{uuid}}}"
        let item = UploadBody.item(fromStored: stored("a"), http: http)
        XCTAssertEqual(item?.value, makeRecord("a").json)
        XCTAssertNotNil(item?.templateError)
        XCTAssertNil(UploadBody.item(fromStored: "{not json", http: http))
        XCTAssertNil(UploadBody.item(fromStored: "[1]", http: http))
    }
}
