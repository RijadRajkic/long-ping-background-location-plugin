import XCTest
@testable import LongPingCore

/// DESIGN.md, "Remote config": the server's overrides are their own layer on top of configure() / setConfig().
final class ConfigLayersTests: XCTestCase {
    private let appConfig: JSONValue = [
        "movingIntervalSec": 10,
        "http": ["url": "https://api.example.com/locations", "uploadIntervalSec": 60],
    ]

    private func configured(_ patch: JSONValue? = nil) throws -> ConfigLayers {
        var layers = ConfigLayers()
        _ = try layers.setLocal(patch ?? appConfig, merge: false)
        return layers
    }

    func testOverrideSurvivesConfigure() throws {
        var layers = try configured()
        let change = layers.applyRemote(config: ["movingIntervalSec": 5, "http": ["uploadIntervalSec": 15]], reset: false)
        XCTAssertTrue(change.overridesChanged)
        XCTAssertTrue(change.effectiveChanged)
        XCTAssertEqual(layers.effective.movingIntervalSec, 5)
        XCTAssertEqual(layers.effective.http.uploadIntervalSec, 15)
        XCTAssertEqual(layers.effective.http.url, "https://api.example.com/locations", "objects deep-merge")
        XCTAssertEqual(layers.local.movingIntervalSec, 10)

        // Relaunch: both layers come back from storage, then the app calls configure() as it does on every launch.
        let restored = ConfigLayers.restore(local: layers.local, overrides: .object(layers.overrides))
        XCTAssertNil(restored.dropped)
        var relaunched = restored.layers
        XCTAssertEqual(relaunched.effective.movingIntervalSec, 5)
        XCTAssertNil(try relaunched.setLocal(appConfig, merge: false).droppedOverrides)
        XCTAssertEqual(relaunched.effective.movingIntervalSec, 5)
        XCTAssertEqual(relaunched.effective.http.uploadIntervalSec, 15)
        XCTAssertEqual(relaunched.local.movingIntervalSec, 10)

        // A different configure() still keeps the overridden keys; everything else is the app's.
        _ = try relaunched.setLocal(["parkedIntervalSec": 600], merge: false)
        XCTAssertEqual(relaunched.effective.movingIntervalSec, 5)
        XCTAssertEqual(relaunched.effective.parkedIntervalSec, 600)
        XCTAssertNil(relaunched.effective.http.url)
        XCTAssertEqual(relaunched.effective.http.uploadIntervalSec, 15)
    }

    func testOverridesAccumulateAndWinOverSetConfig() throws {
        var layers = try configured()
        _ = layers.applyRemote(config: ["movingIntervalSec": 5], reset: false)
        _ = layers.applyRemote(config: ["parkedIntervalSec": 60, "http": ["batch": false]], reset: false)
        XCTAssertEqual(JSONValue.object(layers.overrides), ["movingIntervalSec": 5, "parkedIntervalSec": 60, "http": ["batch": false]])

        // setConfig() merges into the app's layer: an overridden key keeps the server's value, the rest applies.
        _ = try layers.setLocal(["movingIntervalSec": 20, "stopRadiusM": 150, "http": ["maxBatchSize": 10]], merge: true)
        XCTAssertEqual(layers.local.movingIntervalSec, 20)
        XCTAssertEqual(layers.effective.movingIntervalSec, 5)
        XCTAssertEqual(layers.effective.parkedIntervalSec, 60)
        XCTAssertEqual(layers.effective.stopRadiusM, 150)
        XCTAssertEqual(layers.effective.http.maxBatchSize, 10)
        XCTAssertFalse(layers.effective.http.batch)
        XCTAssertEqual(layers.effective.http.url, "https://api.example.com/locations")

        let repeated = layers.applyRemote(config: ["movingIntervalSec": 5], reset: false)
        XCTAssertFalse(repeated.overridesChanged)
        XCTAssertFalse(repeated.effectiveChanged, "the same config again is not a change")
    }

    func testResetClearsTheOverrides() throws {
        var layers = try configured()
        _ = layers.applyRemote(config: ["movingIntervalSec": 5], reset: false)
        let change = layers.applyRemote(config: nil, reset: true)
        XCTAssertTrue(change.overridesChanged)
        XCTAssertTrue(change.effectiveChanged)
        XCTAssertTrue(layers.overrides.isEmpty)
        XCTAssertEqual(layers.effective, layers.local)
        XCTAssertEqual(layers.effective.movingIntervalSec, 10)
        XCTAssertFalse(layers.applyRemote(config: nil, reset: true).effectiveChanged, "nothing left to clear")
    }

    func testResetAndConfigInOneReplyApplyInThatOrder() throws {
        var layers = try configured()
        _ = layers.applyRemote(config: ["movingIntervalSec": 5, "parkedIntervalSec": 60], reset: false)
        let change = layers.applyRemote(config: ["parkedIntervalSec": 90], reset: true)
        XCTAssertNil(change.rejected)
        XCTAssertEqual(JSONValue.object(layers.overrides), ["parkedIntervalSec": 90])
        XCTAssertEqual(layers.effective.movingIntervalSec, 10)
        XCTAssertEqual(layers.effective.parkedIntervalSec, 90)

        // An invalid config is refused whole; the reset in the same reply still applies.
        let refused = layers.applyRemote(config: ["movingIntervalSec": "fast"], reset: true)
        XCTAssertEqual(refused.rejected?.key, "movingIntervalSec")
        XCTAssertTrue(layers.overrides.isEmpty)
        XCTAssertEqual(layers.effective, layers.local)
    }

    func testRemoteConfigFalseKeepsOverridesStoredButUnapplied() throws {
        var layers = try configured()
        _ = layers.applyRemote(config: ["movingIntervalSec": 5], reset: false)
        _ = try layers.setLocal(["remoteConfig": false], merge: true)
        XCTAssertEqual(layers.effective, layers.local)
        XCTAssertEqual(layers.effective.movingIntervalSec, 10)
        XCTAssertEqual(JSONValue.object(layers.overrides), ["movingIntervalSec": 5], "kept stored")

        let ignored = layers.applyRemote(config: ["parkedIntervalSec": 60], reset: false)
        XCTAssertTrue(ignored.ignored)
        XCTAssertFalse(ignored.overridesChanged)
        XCTAssertFalse(ignored.effectiveChanged)

        // Kept across a relaunch, and applied again once the app turns remoteConfig back on.
        var relaunched = ConfigLayers.restore(local: layers.local, overrides: .object(layers.overrides)).layers
        XCTAssertEqual(relaunched.effective.movingIntervalSec, 10)
        _ = try relaunched.setLocal(["remoteConfig": true], merge: true)
        XCTAssertEqual(relaunched.effective.movingIntervalSec, 5)
        XCTAssertEqual(relaunched.effective.parkedIntervalSec, 180, "what arrived while off was not stored")
    }

    func testTheServerCannotChangeRemoteConfig() throws {
        var layers = try configured()
        let change = layers.applyRemote(config: ["remoteConfig": false, "movingIntervalSec": 5], reset: false)
        XCTAssertTrue(change.remoteConfigKeyIgnored)
        XCTAssertTrue(layers.effective.remoteConfig)
        XCTAssertEqual(layers.effective.movingIntervalSec, 5)
        XCTAssertNil(layers.overrides["remoteConfig"])
    }

    func testInvalidOverridesAreRefusedAndOnesThatStopValidatingAreDropped() throws {
        var layers = try configured(["lowBattery": ["belowPct": 20, "intervalSec": 600]])
        let bad = layers.applyRemote(config: ["http": ["url": "ftp://x"]], reset: false)
        XCTAssertEqual(bad.rejected?.key, "http.url")
        XCTAssertFalse(bad.overridesChanged)
        XCTAssertFalse(bad.effectiveChanged)

        XCTAssertNil(layers.applyRemote(config: ["lowBattery": ["belowPct": 10]], reset: false).rejected)
        XCTAssertEqual(layers.effective.lowBattery, LowBatteryPolicy(belowPct: 10, intervalSec: 600))
        // configure() without lowBattery leaves the override half a policy: the overrides go, the app's call stands.
        let change = try layers.setLocal(["movingIntervalSec": 10], merge: false)
        XCTAssertEqual(change.droppedOverrides?.key, "lowBattery.intervalSec")
        XCTAssertTrue(layers.overrides.isEmpty)
        XCTAssertEqual(layers.effective, layers.local)

        XCTAssertThrowsError(try layers.setLocal(["movingIntervalSec": "10"], merge: false), "the app's own mistakes still reject")
        let stored = ConfigLayers.restore(local: layers.local, overrides: ["lowBattery": ["belowPct": 10]])
        XCTAssertEqual(stored.dropped?.key, "lowBattery.intervalSec")
        XCTAssertTrue(stored.layers.overrides.isEmpty)
    }
}
