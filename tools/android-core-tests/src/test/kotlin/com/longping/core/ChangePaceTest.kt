package com.longping.core

import com.longping.core.RecordingGate.Decision
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * changePace() must always produce a motionchange record in the forced state (DESIGN.md, bridge
 * methods). Drives StopDetector + RecordingGate the way LongPingEngine does: changePace() uses
 * [RecordingGate.forcedMotionFix]; every OS fix goes detector first, then gate.
 *
 * Regression (Android e2e S10): changePace(false) while driving used the last fix as the parked
 * point and waited for the next fix; that fix (15 m/s) moved the detector straight back, so the
 * parked motionchange was never recorded.
 */
class ChangePaceTest {
    private val params = StopParams(minAccuracyM = 100.0, stopRadiusM = 50.0, stopTimeoutSec = 60.0, movingSpeedMps = 3.0, disableStopDetection = false)
    private val lat0 = 43.85

    private data class Recorded(val event: RecordEvent, val isMoving: Boolean, val timeMs: Long)

    private class Engine(moving: Boolean, private val params: StopParams, private val intervalMs: Long) {
        val detector = StopDetector(MotionState(moving, null, null))
        val gate = RecordingGate(lastRecordedTimeMs = 0)
        var lastFix: Fix? = null
        val records = mutableListOf<Recorded>()

        fun changePace(isMoving: Boolean, nowMs: Long) {
            val here = RecordingGate.forcedMotionFix(lastFix, nowMs, params.minAccuracyM)
            detector.force(isMoving, here?.toPoint())
            if (here != null) keep(gate.recordMotionChange(here)) else gate.requestMotionChange(nowMs)
        }

        fun onFix(fix: Fix) {
            lastFix = fix
            val transition = detector.evaluate(fix, params)
            val d = gate.offer(fix, fix.timeMs, intervalMs, params.minAccuracyM, motionChanged = transition != null)
            if (d is Decision.Record) keep(d)
        }

        private fun keep(d: Decision.Record) {
            records += Recorded(d.event, detector.state.isMoving, d.fix.timeMs)
        }
    }

    private fun driving(timeMs: Long, metersAlong: Double) = fix(lat = northOf(lat0, metersAlong), speed = 15.0, accuracy = 5.0, timeMs = timeMs)

    @Test fun parkWhileDrivingRecordsTheParkedMotionChangeAtOnce() {
        val e = Engine(moving = true, params, intervalMs = 5_000)
        e.onFix(driving(100_000, 0.0))
        e.changePace(false, nowMs = 102_000) // last fix 2 s old: it is "here, now"
        assertEquals(Recorded(RecordEvent.MOTIONCHANGE, false, 100_000), e.records.last())
        // Still driving: the next fix moves it back (as on iOS), as its own motionchange.
        e.onFix(driving(105_000, 75.0))
        assertEquals(Recorded(RecordEvent.MOTIONCHANGE, true, 105_000), e.records.last())
        assertEquals(listOf(false, true), e.records.drop(1).map { it.isMoving })
    }

    @Test fun parkWithAStaleLastFixWaitsForTheNextFixAndStillRecordsParked() {
        val e = Engine(moving = true, params, intervalMs = 30_000)
        e.onFix(driving(100_000, 0.0))
        e.changePace(false, nowMs = 125_000) // last fix 25 s old: no immediate record
        assertEquals(1, e.records.size)
        assertTrue(e.gate.isMotionChangePending)
        // The old code parked at the stale point, so this 15 m/s fix 390 m away was a MOVED transition.
        e.onFix(driving(126_000, 390.0))
        assertEquals(Recorded(RecordEvent.MOTIONCHANGE, false, 126_000), e.records.last())
        e.onFix(driving(127_000, 405.0))
        assertEquals(Recorded(RecordEvent.MOTIONCHANGE, true, 127_000), e.records.last())
    }

    @Test fun moveWhileParkedWithAStaleLastFixIsNotUndoneByTheNextFix() {
        val e = Engine(moving = false, params, intervalMs = 180_000)
        e.onFix(fix(lat = lat0, speed = 0.0, timeMs = 0))
        e.changePace(true, nowMs = 120_000) // parked interval: last fix 120 s old
        // The old code anchored at the 120 s old fix, so this fix (same spot, > stopTimeout later) parked again at once.
        e.onFix(fix(lat = lat0, speed = 0.0, timeMs = 121_000))
        assertEquals(Recorded(RecordEvent.MOTIONCHANGE, true, 121_000), e.records.last())
        assertTrue(e.detector.state.isMoving)
        // and it parks only after a full stopTimeout from there
        e.onFix(fix(lat = lat0, speed = 0.0, timeMs = 180_000))
        assertTrue(e.detector.state.isMoving)
        e.onFix(fix(lat = lat0, speed = 0.0, timeMs = 181_000))
        assertFalse(e.detector.state.isMoving)
    }

    @Test fun forcedMotionFixIsOnlyAFreshAccurateFix() {
        val f = fix(accuracy = 20.0, timeMs = 50_000)
        assertNull(RecordingGate.forcedMotionFix(null, 50_000, 100.0))
        assertSame(f, RecordingGate.forcedMotionFix(f, 60_000, 100.0)) // exactly 10 s old
        assertNull(RecordingGate.forcedMotionFix(f, 60_001, 100.0))
        assertNull(RecordingGate.forcedMotionFix(f, 55_000, 10.0)) // worse than minAccuracyM
        assertSame(f, RecordingGate.forcedMotionFix(f, 55_000, 0.0)) // 0 accepts any accuracy
    }

    @Test fun recordMotionChangeResetsTheIntervalClockAndClearsAPendingRequest() {
        val gate = RecordingGate(lastRecordedTimeMs = 0)
        gate.requestMotionChange(nowMs = 1_000)
        val d = gate.recordMotionChange(fix(timeMs = 2_000))
        assertEquals(RecordEvent.MOTIONCHANGE, d.event)
        assertFalse(d.accuracyWaived)
        assertFalse(gate.isMotionChangePending)
        assertEquals(2_000L, gate.lastRecordedTimeMs)
        assertTrue(gate.offer(fix(timeMs = 10_000), 10_000, 30_000, 100.0) is Decision.Skip)
    }
}
