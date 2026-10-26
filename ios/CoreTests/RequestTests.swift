import XCTest
@testable import LongPingCore

private func fixAt(_ ms: EpochMs, accuracy: Double = 10) -> Fix {
    Fix(latitude: 43.85, longitude: 18.41, accuracy: accuracy, time: ms)
}

final class CurrentPositionTests: XCTestCase {
    private let now: EpochMs = 1_793_016_000_000

    func testOptionDefaultsAndParsing() {
        XCTAssertEqual(CurrentPositionOptions(nil), CurrentPositionOptions())
        let defaults = CurrentPositionOptions()
        XCTAssertEqual(defaults.timeoutSec, 30)
        XCTAssertEqual(defaults.maximumAgeSec, 0)
        XCTAssertNil(defaults.accuracy)
        XCTAssertFalse(defaults.persist)
        XCTAssertTrue(defaults.extras.isEmpty)

        let parsed = CurrentPositionOptions(["timeoutSec": 5, "maximumAgeSec": 60, "accuracy": "balanced", "persist": true,
                                             "extras": ["trip": 9]])
        XCTAssertEqual(parsed.timeoutSec, 5)
        XCTAssertEqual(parsed.maximumAgeSec, 60)
        XCTAssertEqual(parsed.accuracy, .balanced)
        XCTAssertTrue(parsed.persist)
        XCTAssertEqual(parsed.extras["trip"], 9)
    }

    func testOptionsAreLenient() {
        let odd = CurrentPositionOptions(["timeoutSec": "10", "maximumAgeSec": -5, "accuracy": "ultra", "persist": 1, "extras": [1]])
        XCTAssertEqual(odd.timeoutSec, 30)
        XCTAssertEqual(odd.maximumAgeSec, 0)
        XCTAssertNil(odd.accuracy)
        XCTAssertFalse(odd.persist)
        XCTAssertTrue(odd.extras.isEmpty)
        XCTAssertEqual(CurrentPositionOptions(["timeoutSec": 0]).timeoutSec, 1)
    }

    func testTargetAccuracy() {
        XCTAssertEqual(CurrentPositionPolicy.targetAccuracyM(.high), 20)
        XCTAssertEqual(CurrentPositionPolicy.targetAccuracyM(.balanced), 100)
        XCTAssertEqual(CurrentPositionPolicy.targetAccuracyM(.low), 1000)
    }

    func testAcceptanceWindowRejectsCachedFixes() {
        XCTAssertTrue(CurrentPositionPolicy.accepts(fixAt(now), startedAt: now, maximumAgeSec: 0))
        XCTAssertTrue(CurrentPositionPolicy.accepts(fixAt(now - 2000), startedAt: now, maximumAgeSec: 0))
        XCTAssertFalse(CurrentPositionPolicy.accepts(fixAt(now - 2001), startedAt: now, maximumAgeSec: 0))
        XCTAssertTrue(CurrentPositionPolicy.accepts(fixAt(now - 60_000), startedAt: now, maximumAgeSec: 60))
    }

    func testCachedFixHonoursMaximumAge() {
        XCTAssertNil(CurrentPositionPolicy.cachedFix(fixAt(now), now: now, maximumAgeSec: 0), "0 always waits for a new fix")
        XCTAssertEqual(CurrentPositionPolicy.cachedFix(fixAt(now - 30_000), now: now, maximumAgeSec: 30), fixAt(now - 30_000))
        XCTAssertNil(CurrentPositionPolicy.cachedFix(fixAt(now - 30_001), now: now, maximumAgeSec: 30))
        XCTAssertNil(CurrentPositionPolicy.cachedFix(nil, now: now, maximumAgeSec: 30))
    }

    func testTimeoutFallbackOrder() {
        let best = fixAt(now - 5000, accuracy: 80)
        let known = fixAt(now - 60_000)
        XCTAssertEqual(CurrentPositionPolicy.onTimeout(best: best, lastKnown: known, now: now), best)
        XCTAssertEqual(CurrentPositionPolicy.onTimeout(best: nil, lastKnown: known, now: now), known)
        XCTAssertEqual(CurrentPositionPolicy.onTimeout(best: nil, lastKnown: fixAt(now - 599_999), now: now), fixAt(now - 599_999))
        XCTAssertNil(CurrentPositionPolicy.onTimeout(best: nil, lastKnown: fixAt(now - 600_000), now: now), "10 min or older → TIMEOUT")
        XCTAssertNil(CurrentPositionPolicy.onTimeout(best: nil, lastKnown: nil, now: now))
    }

    func testFreshest() {
        XCTAssertEqual(CurrentPositionPolicy.freshest([fixAt(1), nil, fixAt(3), fixAt(2)]), fixAt(3))
        XCTAssertNil(CurrentPositionPolicy.freshest([nil, nil]))
    }
}

final class LogQueryTests: XCTestCase {
    func testDefaults() {
        let q = LogQuery(nil, now: 1_000_000_000_000)
        XCTAssertEqual(q, LogQuery(.object(JSONObject()), now: 1_000_000_000_000))
        XCTAssertEqual(q.sinceMs, 1_000_000_000_000 - 86_400_000)
        XCTAssertEqual(q.limit, 1000)
        XCTAssertTrue(q.ascending)
    }

    func testParsingAndClamping() {
        let q = LogQuery(["sinceMs": 5, "limit": 10, "order": "desc"], now: 0)
        XCTAssertEqual(q.sinceMs, 5)
        XCTAssertEqual(q.limit, 10)
        XCTAssertFalse(q.ascending)
        XCTAssertEqual(LogQuery(["limit": 0], now: 0).limit, 1)
        XCTAssertEqual(LogQuery(["limit": 1e9], now: 0).limit, LogQuery.maxLimit)
        XCTAssertTrue(LogQuery(["order": "sideways"], now: 0).ascending)
    }
}

final class ConversionSafetyTests: XCTestCase {
    func testSaturatingConversionNeverTraps() {
        XCTAssertEqual(EpochMs(clamping: .nan), 0)
        XCTAssertEqual(EpochMs(clamping: .infinity), .max)
        XCTAssertEqual(EpochMs(clamping: -.infinity), .min)
        XCTAssertEqual(EpochMs(clamping: 1e300), .max)
        XCTAssertEqual(EpochMs(clamping: 1234.9), 1234)
        XCTAssertEqual(EpochMs(seconds: 1e300), .max)
        XCTAssertEqual(EpochMs(seconds: 1.5), 1500)
    }

    func testImplausibleTimestampsAreRejected() {
        XCTAssertEqual(EpochMs.timestamp(1_793_016_000_000), 1_793_016_000_000)
        XCTAssertNil(EpochMs.timestamp(-1))
        XCTAssertNil(EpochMs.timestamp(1e300))
        XCTAssertNil(EpochMs.timestamp(.nan))
        XCTAssertNil(EpochMs.timestamp(nil))
        XCTAssertNil(Fix(json: ["latitude": 1, "longitude": 2, "accuracy": 3, "time": 1e300]))
        let state = PersistedEngineState(json: ["enabled": true, "lastRecordedTime": -5e300, "lastFixTime": 1e300])
        XCTAssertTrue(state.enabled)
        XCTAssertNil(state.lastRecordedTime)
        XCTAssertNil(state.lastFixTime)
    }

    func testLogQueryWithAbsurdSince() {
        XCTAssertEqual(LogQuery(["sinceMs": 1e300], now: 0).sinceMs, .max)
        XCTAssertEqual(LogQuery(["sinceMs": -1e300], now: 0).sinceMs, .min)
        XCTAssertEqual(LogQuery(["sinceMs": .number(.nan)], now: 100_000_000_000).sinceMs, 100_000_000_000 - 86_400_000)
    }
}
