import XCTest
@testable import LongPingCore

/// Fixes on a north-south line: `meters` north of the origin, `seconds` after t0.
private func fix(_ meters: Double = 0, at seconds: Double, accuracy: Double = 5, speed: Double = -1) -> Fix {
    Fix(latitude: 43.85 + meters / 111_195.08, longitude: 18.41, accuracy: accuracy, speed: speed,
        time: 1_000_000_000_000 + EpochMs(seconds: seconds))
}

final class GeoTests: XCTestCase {
    func testHaversineUsesMeanEarthRadius() {
        // One degree of arc = 2πR / 360 with R = 6371008.8 m.
        XCTAssertEqual(Geo.distance(0, 0, 1, 0), 111_195.08, accuracy: 0.01)
        XCTAssertEqual(Geo.distance(0, 0, 0, 1), 111_195.08, accuracy: 0.01)
        XCTAssertEqual(Geo.distance(43.85, 18.41, 43.85, 18.41), 0)
        XCTAssertEqual(Geo.distance(0, 0, 0, 180), Double.pi * Geo.earthRadiusM, accuracy: 0.01)
        XCTAssertEqual(fix(0, at: 0).distance(to: fix(100, at: 0)), 100, accuracy: 0.01)
    }
}

final class StopDetectorTests: XCTestCase {
    private let settings = StopDetector.Settings(stopRadiusM: 75, stopTimeoutSec: 300, movingSpeedMps: 3,
                                                 minAccuracyM: 100, disabled: false)

    func testFirstFixBecomesAnchor() {
        var d = StopDetector()
        XCTAssertEqual(d.process(fix(at: 0), settings: settings), .none)
        XCTAssertEqual(d.anchor, fix(at: 0))
    }

    func testParksAfterStopTimeoutWithinRadius() {
        var d = StopDetector()
        _ = d.process(fix(at: 0), settings: settings)
        XCTAssertEqual(d.process(fix(50, at: 200), settings: settings), .none)
        XCTAssertEqual(d.process(fix(60, at: 299), settings: settings), .none)
        XCTAssertEqual(d.process(fix(70, at: 300), settings: settings), .parked(at: fix(70, at: 300)))
        XCTAssertFalse(d.isMoving)
        XCTAssertEqual(d.parkedAt, fix(70, at: 300))
    }

    func testLeavingRadiusOrSpeedResetsAnchor() {
        var d = StopDetector()
        _ = d.process(fix(at: 0), settings: settings)
        _ = d.process(fix(80, at: 100), settings: settings)
        XCTAssertEqual(d.anchor, fix(80, at: 100), "distance > stopRadius moves the anchor")
        _ = d.process(fix(90, at: 200, speed: 3), settings: settings)
        XCTAssertEqual(d.anchor, fix(90, at: 200, speed: 3), "speed >= movingSpeed moves the anchor")
        XCTAssertEqual(d.process(fix(95, at: 450), settings: settings), .none, "timeout counts from the new anchor")
        XCTAssertEqual(d.process(fix(95, at: 500), settings: settings), .parked(at: fix(95, at: 500)))
    }

    func testUnknownSpeedNeverCountsAsMoving() {
        var d = StopDetector()
        _ = d.process(fix(at: 0), settings: settings)
        XCTAssertEqual(d.process(fix(10, at: 300, speed: -1), settings: settings), .parked(at: fix(10, at: 300, speed: -1)))
    }

    func testIgnoresFixesLessAccurateThanEvaluationThreshold() {
        var d = StopDetector()
        _ = d.process(fix(at: 0), settings: settings)
        // max(minAccuracyM 100, stopRadius 75) = 100
        XCTAssertEqual(d.process(fix(5000, at: 10, accuracy: 101), settings: settings), .none)
        XCTAssertEqual(d.anchor, fix(at: 0))
        XCTAssertEqual(d.process(fix(5, at: 300, accuracy: 100), settings: settings), .parked(at: fix(5, at: 300, accuracy: 100)))

        var zero = settings
        zero.minAccuracyM = 0
        XCTAssertEqual(zero.evaluationAccuracy, 75, "minAccuracyM 0 → stopRadiusM")
        var big = settings
        big.stopRadiusM = 200
        XCTAssertEqual(big.evaluationAccuracy, 200)
    }

    func testParkedMovesOnAccurateSpeed() {
        var d = StopDetector(isMoving: false, anchor: nil, parkedAt: fix(at: 0))
        XCTAssertEqual(d.process(fix(10, at: 10, accuracy: 51, speed: 10), settings: settings), .none, "speed needs accuracy <= 50")
        XCTAssertEqual(d.process(fix(10, at: 20, accuracy: 50, speed: 3), settings: settings), .moved(fix(10, at: 20, accuracy: 50, speed: 3)))
        XCTAssertTrue(d.isMoving)
        XCTAssertEqual(d.anchor, fix(10, at: 20, accuracy: 50, speed: 3))
        XCTAssertNil(d.parkedAt)
    }

    func testParkedMovesOnDistanceWithAccuracyWithinRadius() {
        var d = StopDetector(isMoving: false, anchor: nil, parkedAt: fix(at: 0))
        XCTAssertEqual(d.process(fix(76, at: 10, accuracy: 76), settings: settings), .none, "accuracy must be <= stopRadius")
        XCTAssertEqual(d.process(fix(74, at: 20, accuracy: 10), settings: settings), .none, "within radius stays parked")
        XCTAssertEqual(d.process(fix(76, at: 30, accuracy: 75), settings: settings), .moved(fix(76, at: 30, accuracy: 75)))
    }

    func testParkedWithoutPositionAdoptsFirstFix() {
        var d = StopDetector()
        d.forceParked(at: nil)
        XCTAssertEqual(d.process(fix(at: 0), settings: settings), .none)
        XCTAssertEqual(d.parkedAt, fix(at: 0))
        XCTAssertEqual(d.process(fix(200, at: 10), settings: settings), .moved(fix(200, at: 10)))
    }

    func testDisabledNeverParksAndLeavesParked() {
        var disabled = settings
        disabled.disabled = true
        var d = StopDetector()
        for s in stride(from: 0.0, through: 3600, by: 60) {
            XCTAssertEqual(d.process(fix(at: s), settings: disabled), .none)
        }
        XCTAssertTrue(d.isMoving)

        var parked = StopDetector(isMoving: false, anchor: nil, parkedAt: fix(at: 0))
        XCTAssertEqual(parked.process(fix(at: 10), settings: disabled), .moved(fix(at: 10)))
    }

    func testChangePace() {
        var d = StopDetector()
        d.forceParked(at: fix(at: 5))
        XCTAssertFalse(d.isMoving)
        XCTAssertEqual(d.parkedAt, fix(at: 5))
        d.forceMoving(at: nil)
        XCTAssertTrue(d.isMoving)
        XCTAssertNil(d.anchor)
        XCTAssertNil(d.parkedAt)
        d.forceMoving(at: fix(at: 6))
        XCTAssertEqual(d.anchor, fix(at: 6))
    }

    func testSettingsFromConfig() {
        let s = StopDetector.Settings(LongPingConfig.defaults)
        XCTAssertEqual(s, StopDetector.Settings(stopRadiusM: 75, stopTimeoutSec: 300, movingSpeedMps: 3, minAccuracyM: 100, disabled: false))
    }
}

final class IntervalPolicyTests: XCTestCase {
    func testEffectiveInterval() {
        var c = LongPingConfig.defaults
        let full = BatterySnapshot(level: 0.9, isCharging: false)
        XCTAssertEqual(IntervalPolicy.effectiveInterval(isMoving: true, config: c, battery: full), 30)
        XCTAssertEqual(IntervalPolicy.effectiveInterval(isMoving: false, config: c, battery: full), 180)

        c.lowBattery = LowBatteryPolicy(belowPct: 20, intervalSec: 300)
        let low = BatterySnapshot(level: 0.19, isCharging: false)
        XCTAssertEqual(IntervalPolicy.effectiveInterval(isMoving: true, config: c, battery: low), 300)
        XCTAssertEqual(IntervalPolicy.effectiveInterval(isMoving: true, config: c, battery: BatterySnapshot(level: 0.2, isCharging: false)), 30,
                       "strictly below belowPct")
        XCTAssertEqual(IntervalPolicy.effectiveInterval(isMoving: true, config: c, battery: BatterySnapshot(level: 0.1, isCharging: true)), 30,
                       "charging ignores lowBattery")
        XCTAssertEqual(IntervalPolicy.effectiveInterval(isMoving: true, config: c, battery: .unknown), 30, "unknown level ignores lowBattery")

        c.lowBattery = LowBatteryPolicy(belowPct: 20, intervalSec: 60)
        XCTAssertEqual(IntervalPolicy.effectiveInterval(isMoving: false, config: c, battery: low), 180, "max(base, intervalSec)")
    }

    func testTolerance() {
        XCTAssertEqual(IntervalPolicy.toleranceMs(intervalSec: 1), 100)
        XCTAssertEqual(IntervalPolicy.toleranceMs(intervalSec: 5), 500)
        XCTAssertEqual(IntervalPolicy.toleranceMs(intervalSec: 30), 500)
        XCTAssertEqual(IntervalPolicy.toleranceMs(intervalSec: 3600), 500)
    }
}

final class RecordingGateTests: XCTestCase {
    private let t0: EpochMs = 1_000_000_000_000

    private func at(_ seconds: Double) -> EpochMs { t0 + EpochMs(seconds: seconds) }

    func testFirstAccurateFixRecords() {
        var gate = RecordingGate(lastRecordedTime: nil, armedAt: t0)
        XCTAssertEqual(gate.evaluate(fix(at: 0), now: at(0), intervalSec: 30, minAccuracyM: 100), .record(fix(at: 0), accuracyWaived: false))
        XCTAssertEqual(gate.lastRecordedTime, fix(at: 0).time)
    }

    func testIntervalWithTolerance() {
        var gate = RecordingGate(lastRecordedTime: fix(at: 0).time, armedAt: t0)
        XCTAssertEqual(gate.evaluate(fix(at: 29.4), now: at(29.4), intervalSec: 30, minAccuracyM: 100), .tooSoon)
        XCTAssertEqual(gate.evaluate(fix(at: 29.5), now: at(29.5), intervalSec: 30, minAccuracyM: 100), .record(fix(at: 29.5), accuracyWaived: false),
                       "tolerance = min(0.5 s, 10%)")
        XCTAssertEqual(gate.evaluate(fix(at: 30), now: at(30), intervalSec: 30, minAccuracyM: 100), .tooSoon, "clock restarts at the record")

        var fast = RecordingGate(lastRecordedTime: fix(at: 0).time, armedAt: t0)
        XCTAssertEqual(fast.evaluate(fix(at: 0.89), now: at(1), intervalSec: 1, minAccuracyM: 100), .tooSoon)
        XCTAssertEqual(fast.evaluate(fix(at: 0.9), now: at(1), intervalSec: 1, minAccuracyM: 100), .record(fix(at: 0.9), accuracyWaived: false))
    }

    func testInaccurateFixesAreSkippedThenOverdueRuleRecordsTheBest() {
        var gate = RecordingGate(lastRecordedTime: fix(at: 0).time, armedAt: t0)
        XCTAssertEqual(gate.evaluate(fix(at: 31, accuracy: 300), now: at(31), intervalSec: 30, minAccuracyM: 100), .inaccurate)
        XCTAssertEqual(gate.evaluate(fix(at: 45, accuracy: 150), now: at(45), intervalSec: 30, minAccuracyM: 100), .inaccurate)
        XCTAssertEqual(gate.evaluate(fix(at: 60, accuracy: 400), now: at(60), intervalSec: 30, minAccuracyM: 100), .inaccurate,
                       "exactly interval + 30 s is not yet overdue")
        XCTAssertEqual(gate.evaluate(fix(at: 60.5, accuracy: 500), now: at(60.5), intervalSec: 30, minAccuracyM: 100),
                       .record(fix(at: 45, accuracy: 150), accuracyWaived: true))
        XCTAssertEqual(gate.lastRecordedTime, fix(at: 45).time)
        XCTAssertNil(gate.bestInaccurate)
    }

    func testOverdueFromWatchdogWithoutNewFix() {
        var gate = RecordingGate(lastRecordedTime: fix(at: 0).time, armedAt: t0)
        _ = gate.evaluate(fix(at: 35, accuracy: 200), now: at(35), intervalSec: 30, minAccuracyM: 100)
        XCTAssertNil(gate.takeOverdue(now: at(60), intervalSec: 30))
        XCTAssertEqual(gate.takeOverdue(now: at(61), intervalSec: 30), fix(at: 35, accuracy: 200))
        XCTAssertNil(gate.takeOverdue(now: at(200), intervalSec: 30), "candidate consumed")
    }

    func testOverdueBeforeFirstRecordCountsFromArming() {
        var gate = RecordingGate(lastRecordedTime: nil, armedAt: t0)
        XCTAssertEqual(gate.evaluate(fix(at: 5, accuracy: 900), now: at(5), intervalSec: 30, minAccuracyM: 100), .inaccurate)
        XCTAssertEqual(gate.takeOverdue(now: at(61), intervalSec: 30), fix(at: 5, accuracy: 900))
    }

    func testAccurateFixClearsCandidate() {
        var gate = RecordingGate(lastRecordedTime: fix(at: 0).time, armedAt: t0)
        _ = gate.evaluate(fix(at: 31, accuracy: 300), now: at(31), intervalSec: 30, minAccuracyM: 100)
        XCTAssertEqual(gate.evaluate(fix(at: 32, accuracy: 20), now: at(32), intervalSec: 30, minAccuracyM: 100),
                       .record(fix(at: 32, accuracy: 20), accuracyWaived: false))
        XCTAssertNil(gate.takeOverdue(now: at(500), intervalSec: 30))
    }

    func testMinAccuracyZeroAcceptsAnything() {
        var gate = RecordingGate(lastRecordedTime: nil, armedAt: t0)
        XCTAssertEqual(gate.evaluate(fix(at: 0, accuracy: 5000), now: at(0), intervalSec: 30, minAccuracyM: 0),
                       .record(fix(at: 0, accuracy: 5000), accuracyWaived: false))
    }

    func testStaleFixIgnored() {
        var gate = RecordingGate(lastRecordedTime: fix(at: 100).time, armedAt: t0)
        XCTAssertEqual(gate.evaluate(fix(at: 50), now: at(200), intervalSec: 30, minAccuracyM: 100), .stale)
    }

    func testMotionChangeRecordRestartsClockAndRearmResets() {
        var gate = RecordingGate(lastRecordedTime: fix(at: 0).time, armedAt: t0)
        gate.markRecorded(fix(at: 20).time)
        XCTAssertEqual(gate.evaluate(fix(at: 31), now: at(31), intervalSec: 30, minAccuracyM: 100), .tooSoon)
        gate.rearm(now: at(40))
        XCTAssertNil(gate.lastRecordedTime)
        XCTAssertEqual(gate.armedAt, at(40))
        XCTAssertEqual(gate.evaluate(fix(at: 41), now: at(41), intervalSec: 30, minAccuracyM: 100), .record(fix(at: 41), accuracyWaived: false))
    }

    func testResumeTimeIsTheNewestStoredTimeButNeverLaterThanNow() {
        let now = at(100)
        XCTAssertNil(RecordingGate.resumeTime(persisted: nil, newestQueued: nil, lastLocationAt: nil, now: now))
        XCTAssertEqual(RecordingGate.resumeTime(persisted: at(60), newestQueued: at(75), lastLocationAt: at(70), now: now), at(75))
        XCTAssertEqual(RecordingGate.resumeTime(persisted: at(60), newestQueued: nil, lastLocationAt: at(70), now: now), at(70))
        XCTAssertEqual(RecordingGate.resumeTime(persisted: at(80), newestQueued: at(75), lastLocationAt: nil, now: now), at(80))
        XCTAssertEqual(RecordingGate.resumeTime(persisted: nil, newestQueued: at(75), lastLocationAt: nil, now: now), at(75))
        XCTAssertEqual(RecordingGate.resumeTime(persisted: at(60), newestQueued: at(500), lastLocationAt: nil, now: now), now,
                       "a clock set back must not hold new fixes as stale")
    }

    func testSeededClockHoldsTheFirstFixAfterARelaunch() {
        // Android e2e S12: lastRecordedTime was persisted 25 s before the kill; the newest queued record is 3 s
        // older than the first fix after the restart, so that fix is not due yet at a 10 s interval.
        let seed = RecordingGate.resumeTime(persisted: fix(at: 0).time, newestQueued: fix(at: 25).time, lastLocationAt: nil, now: at(28))
        var gate = RecordingGate(lastRecordedTime: seed, armedAt: at(28))
        XCTAssertEqual(gate.evaluate(fix(at: 28), now: at(28), intervalSec: 10, minAccuracyM: 100), .tooSoon)
        XCTAssertEqual(gate.evaluate(fix(at: 35), now: at(35), intervalSec: 10, minAccuracyM: 100), .record(fix(at: 35), accuracyWaived: false))
    }
}

final class PendingMotionChangeTests: XCTestCase {
    private let t0: EpochMs = 1_000_000_000_000

    func testImmediateFixMustBeFreshAndAccurate() {
        let now = fix(at: 10).time
        XCTAssertEqual(PendingMotionChange.immediateFix(lastFix: fix(at: 0), now: now, minAccuracyM: 100), fix(at: 0))
        XCTAssertNil(PendingMotionChange.immediateFix(lastFix: fix(at: -0.1), now: now, minAccuracyM: 100))
        XCTAssertNil(PendingMotionChange.immediateFix(lastFix: fix(at: 5, accuracy: 101), now: now, minAccuracyM: 100))
        XCTAssertNil(PendingMotionChange.immediateFix(lastFix: nil, now: now, minAccuracyM: 100))
    }

    func testOfferTakesFirstFreshAccurateFix() {
        var p = PendingMotionChange(isMoving: true, requestedAt: fix(at: 100).time)
        XCTAssertNil(p.offer(fix(at: 80), now: fix(at: 100).time, minAccuracyM: 100), "cached fix older than 10 s")
        XCTAssertNil(p.offer(fix(at: 101, accuracy: 300), now: fix(at: 101).time, minAccuracyM: 100))
        XCTAssertEqual(p.offer(fix(at: 102, accuracy: 10), now: fix(at: 102).time, minAccuracyM: 100), fix(at: 102, accuracy: 10))
    }

    func testWaiverRecordsBestAfterThirtySeconds() {
        var p = PendingMotionChange(isMoving: false, requestedAt: fix(at: 0).time)
        XCTAssertNil(p.offer(fix(at: 5, accuracy: 300), now: fix(at: 5).time, minAccuracyM: 100))
        XCTAssertNil(p.offer(fix(at: 20, accuracy: 200), now: fix(at: 20).time, minAccuracyM: 100))
        XCTAssertNil(p.takeExpired(now: fix(at: 29.9).time))
        XCTAssertEqual(p.takeExpired(now: fix(at: 30).time), fix(at: 20, accuracy: 200))
        XCTAssertEqual(p.offer(fix(at: 31, accuracy: 900), now: fix(at: 31).time, minAccuracyM: 100), fix(at: 20, accuracy: 200))
    }
}

final class SamplingPlanTests: XCTestCase {
    func testBelowSixtySecondsKeepsConfiguredAccuracy() {
        let plan = SamplingPlan.plan(now: 10_000, intervalSec: 59, lastRecordedTime: 0, needsFixNow: false)
        XCTAssertEqual(plan.mode, .configured)
        XCTAssertNil(plan.boostAt)
    }

    func testLowPowerUntilFifteenSecondsBeforeDue() {
        let last: EpochMs = 1_000_000
        let early = SamplingPlan.plan(now: last + 1000, intervalSec: 180, lastRecordedTime: last, needsFixNow: false)
        XCTAssertEqual(early.mode, .lowPower)
        XCTAssertEqual(early.boostAt, last + 165_000)
        let boost = SamplingPlan.plan(now: last + 165_000, intervalSec: 180, lastRecordedTime: last, needsFixNow: false)
        XCTAssertEqual(boost.mode, .configured)
        let late = SamplingPlan.plan(now: last + 400_000, intervalSec: 180, lastRecordedTime: last, needsFixNow: false)
        XCTAssertEqual(late.mode, .configured, "stays on until a fix is recorded")
        XCTAssertEqual(SamplingPlan.plan(now: last + 1000, intervalSec: 60, lastRecordedTime: last, needsFixNow: false).mode, .lowPower)
    }

    func testPendingWorkOrNoRecordForcesConfiguredAccuracy() {
        XCTAssertEqual(SamplingPlan.plan(now: 5000, intervalSec: 600, lastRecordedTime: 0, needsFixNow: true).mode, .configured)
        XCTAssertEqual(SamplingPlan.plan(now: 5000, intervalSec: 600, lastRecordedTime: nil, needsFixNow: false).mode, .configured)
    }
}

final class WatchdogTests: XCTestCase {
    func testStallThreshold() {
        // interval 30 → max(60, 90) = 90 s
        XCTAssertFalse(Watchdog.isStalled(now: 90_000, lastFixTime: 0, intervalSec: 30))
        XCTAssertTrue(Watchdog.isStalled(now: 90_001, lastFixTime: 0, intervalSec: 30))
        // interval 180 → max(360, 240) = 360 s
        XCTAssertFalse(Watchdog.isStalled(now: 360_000, lastFixTime: 0, intervalSec: 180))
        XCTAssertTrue(Watchdog.isStalled(now: 360_001, lastFixTime: 0, intervalSec: 180))
    }
}
