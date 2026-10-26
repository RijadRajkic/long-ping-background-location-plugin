import XCTest
@testable import LongPingCore

/// changePace() must always produce a motionchange record in the forced state (DESIGN.md, bridge methods).
/// Drives StopDetector, PendingMotionChange and RecordingGate the way Tracker does: changePace() goes through
/// `StopDetector.changePace`; every OS fix goes detector first, then the pending motion change, then the gate.
///
/// Mirrors the Android ChangePaceTest (e2e S10), plus the iOS case: a fresh but inaccurate last fix used to become
/// the parked point, and the next accurate fix was judged against it and moved the detector straight back.
final class ChangePaceTests: XCTestCase {
    private struct Recorded: Equatable {
        let event: RecordEvent
        let isMoving: Bool
        let time: EpochMs
    }

    private struct Engine {
        let settings: StopDetector.Settings
        let intervalSec: Double
        var detector: StopDetector
        var gate = RecordingGate(lastRecordedTime: 0, armedAt: 0)
        var pending: PendingMotionChange?
        var lastFix: Fix?
        var records: [Recorded] = []

        init(moving: Bool, settings: StopDetector.Settings, intervalSec: Double) {
            self.settings = settings
            self.intervalSec = intervalSec
            detector = StopDetector(isMoving: moving)
        }

        mutating func changePace(_ isMoving: Bool, now: EpochMs) {
            if let here = detector.changePace(isMoving, lastFix: lastFix, now: now, minAccuracyM: settings.minAccuracyM) {
                pending = nil
                record(here, .motionchange)
            } else {
                pending = PendingMotionChange(isMoving: isMoving, requestedAt: now)
            }
        }

        mutating func onFix(_ fix: Fix) {
            lastFix = fix
            switch detector.process(fix, settings: settings) {
            case .parked(let at), .moved(let at):
                pending = nil
                record(at, .motionchange)
            case .none:
                if var waiting = pending {
                    if let chosen = waiting.offer(fix, now: fix.time, minAccuracyM: settings.minAccuracyM) {
                        pending = nil
                        record(chosen, .motionchange)
                    } else {
                        pending = waiting
                    }
                    return
                }
                if case .record(let chosen, _) = gate.evaluate(fix, now: fix.time, intervalSec: intervalSec,
                                                               minAccuracyM: settings.minAccuracyM) {
                    record(chosen, .interval)
                }
            }
        }

        private mutating func record(_ fix: Fix, _ event: RecordEvent) {
            gate.markRecorded(fix.time)
            records.append(Recorded(event: event, isMoving: detector.isMoving, time: fix.time))
        }
    }

    private let settings = StopDetector.Settings(stopRadiusM: 50, stopTimeoutSec: 60, movingSpeedMps: 3,
                                                 minAccuracyM: 100, disabled: false)

    /// `meters` north of the origin at `time` ms.
    private func fix(_ meters: Double = 0, at time: EpochMs, speed: Double = -1, accuracy: Double = 5) -> Fix {
        Fix(latitude: 43.85 + meters / 111_195.08, longitude: 18.41, accuracy: accuracy, speed: speed, time: time)
    }

    private func driving(_ time: EpochMs, _ meters: Double, accuracy: Double = 5) -> Fix {
        fix(meters, at: time, speed: 15, accuracy: accuracy)
    }

    func testParkWhileDrivingRecordsTheParkedMotionChangeAtOnce() {
        var e = Engine(moving: true, settings: settings, intervalSec: 5)
        e.onFix(driving(100_000, 0))
        e.changePace(false, now: 102_000) // last fix 2 s old: it is "here, now"
        XCTAssertEqual(e.records.last, Recorded(event: .motionchange, isMoving: false, time: 100_000))
        // Still driving: the next fix moves it back, as its own motionchange.
        e.onFix(driving(105_000, 75))
        XCTAssertEqual(e.records.last, Recorded(event: .motionchange, isMoving: true, time: 105_000))
        XCTAssertEqual(e.records.dropFirst().map(\.isMoving), [false, true])
    }

    func testParkWithAStaleLastFixWaitsForTheNextFixAndStillRecordsParked() {
        var e = Engine(moving: true, settings: settings, intervalSec: 30)
        e.onFix(driving(100_000, 0))
        e.changePace(false, now: 125_000) // last fix 25 s old: no immediate record
        XCTAssertEqual(e.records.count, 1)
        XCTAssertNotNil(e.pending)
        XCTAssertNil(e.detector.parkedAt)
        // Parked at the stale point, this 15 m/s fix 390 m away would be a move before the park was recorded.
        e.onFix(driving(126_000, 390))
        XCTAssertEqual(e.records.last, Recorded(event: .motionchange, isMoving: false, time: 126_000))
        e.onFix(driving(127_000, 405))
        XCTAssertEqual(e.records.last, Recorded(event: .motionchange, isMoving: true, time: 127_000))
    }

    func testParkWithAFreshButInaccurateLastFixWaitsForAnAccurateOne() {
        let strict = StopDetector.Settings(stopRadiusM: 50, stopTimeoutSec: 60, movingSpeedMps: 3, minAccuracyM: 20, disabled: false)
        var e = Engine(moving: true, settings: strict, intervalSec: 5)
        e.onFix(driving(100_000, 0))
        e.onFix(driving(104_000, 60, accuracy: 40)) // evaluated by the detector (<= 50 m), not recordable (> 20 m)
        e.changePace(false, now: 105_000)
        XCTAssertNil(e.detector.parkedAt, "an unrecorded fix must not become the parked point")
        XCTAssertNotNil(e.pending)
        e.onFix(driving(106_000, 90))
        XCTAssertEqual(e.records.last, Recorded(event: .motionchange, isMoving: false, time: 106_000))
        e.onFix(driving(107_000, 105))
        XCTAssertEqual(e.records.map(\.event), [.interval, .motionchange, .motionchange])
        XCTAssertEqual(e.records.map(\.isMoving), [true, false, true])
    }

    func testMoveWhileParkedWithAStaleLastFixIsNotUndoneByTheNextFix() {
        var e = Engine(moving: false, settings: settings, intervalSec: 180)
        e.onFix(fix(at: 0, speed: 0))
        e.changePace(true, now: 120_000) // parked interval: last fix 120 s old
        // Anchored at the 120 s old fix, this fix (same spot, > stopTimeout later) would park again at once.
        e.onFix(fix(at: 121_000, speed: 0))
        XCTAssertEqual(e.records.last, Recorded(event: .motionchange, isMoving: true, time: 121_000))
        XCTAssertTrue(e.detector.isMoving)
        // It parks only after a full stopTimeout from there.
        e.onFix(fix(at: 180_000, speed: 0))
        XCTAssertTrue(e.detector.isMoving)
        e.onFix(fix(at: 181_000, speed: 0))
        XCTAssertFalse(e.detector.isMoving)
    }

    func testOnlyAFreshAccurateFixBecomesThePoint() {
        let f = fix(at: 50_000, accuracy: 20)
        var d = StopDetector()
        XCTAssertNil(d.changePace(false, lastFix: nil, now: 50_000, minAccuracyM: 100))
        XCTAssertEqual(d.changePace(false, lastFix: f, now: 60_000, minAccuracyM: 100), f, "exactly 10 s old")
        XCTAssertEqual(d.parkedAt, f)
        XCTAssertNil(d.changePace(false, lastFix: f, now: 60_001, minAccuracyM: 100))
        XCTAssertNil(d.parkedAt)
        XCTAssertNil(d.changePace(true, lastFix: f, now: 55_000, minAccuracyM: 10), "worse than minAccuracyM")
        XCTAssertNil(d.anchor)
        XCTAssertEqual(d.changePace(true, lastFix: f, now: 55_000, minAccuracyM: 0), f, "0 accepts any accuracy")
        XCTAssertEqual(d.anchor, f)
        XCTAssertTrue(d.isMoving)
    }

    func testTheMotionChangeRecordRestartsTheIntervalClockAndEndsTheWait() {
        var e = Engine(moving: true, settings: settings, intervalSec: 30)
        e.changePace(false, now: 1_000) // no fix yet: waits
        XCTAssertNotNil(e.pending)
        e.onFix(fix(at: 2_000))
        XCTAssertEqual(e.records, [Recorded(event: .motionchange, isMoving: false, time: 2_000)])
        XCTAssertNil(e.pending)
        XCTAssertEqual(e.gate.lastRecordedTime, 2_000)
        e.onFix(fix(at: 10_000))
        XCTAssertEqual(e.records.count, 1, "the next interval counts from the motionchange")
    }
}
