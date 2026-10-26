package com.longping.core

import com.longping.core.RecordingGate.Decision
import com.longping.core.RecordingGate.SkipReason
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordingGateTest {
    private val interval = 30_000L
    private val minAcc = 50.0

    private fun Decision.recorded(): Decision.Record = this as? Decision.Record ?: throw AssertionError("expected Record, got $this")

    @Test fun firstAccurateFixRecords() {
        val gate = RecordingGate()
        val d = gate.offer(fix(accuracy = 10.0, timeMs = 1000), nowMs = 1000, intervalMs = interval, minAccuracyM = minAcc).recorded()
        assertEquals(RecordEvent.INTERVAL, d.event)
        assertFalse(d.accuracyWaived)
        assertEquals(1000L, gate.lastRecordedTimeMs)
    }

    @Test fun intervalWithTolerance() {
        val gate = RecordingGate(lastRecordedTimeMs = 0)
        // tolerance = min(0.5 s, 10 %) = 0.5 s -> due at 29_500
        assertEquals(Decision.Skip(SkipReason.TOO_SOON), gate.offer(fix(timeMs = 29_499), 29_499, interval, minAcc))
        gate.offer(fix(timeMs = 29_500), 29_500, interval, minAcc).recorded()
        assertEquals(Decision.Skip(SkipReason.TOO_SOON), gate.offer(fix(timeMs = 40_000), 40_000, interval, minAcc))
        assertEquals(Decision.Skip(SkipReason.TOO_SOON), gate.offer(fix(timeMs = 58_999), 58_999, interval, minAcc))
        gate.offer(fix(timeMs = 59_000), 59_000, interval, minAcc).recorded()
    }

    @Test fun shortIntervalToleranceIsTenPercent() {
        val gate = RecordingGate(lastRecordedTimeMs = 0)
        assertTrue(gate.offer(fix(timeMs = 899), 899, 1000, minAcc) is Decision.Skip)
        gate.offer(fix(timeMs = 900), 900, 1000, minAcc).recorded()
    }

    @Test fun inaccurateFixesAreRejectedAndZeroAcceptsAll() {
        val gate = RecordingGate(lastRecordedTimeMs = 0)
        assertEquals(Decision.Skip(SkipReason.INACCURATE), gate.offer(fix(accuracy = 50.1, timeMs = 30_000), 30_000, interval, minAcc))
        gate.offer(fix(accuracy = 50.0, timeMs = 31_000), 31_000, interval, minAcc).recorded()

        val any = RecordingGate(lastRecordedTimeMs = 0)
        any.offer(fix(accuracy = 5000.0, timeMs = 30_000), 30_000, interval, 0.0).recorded()
        val unknownAccuracy = RecordingGate(lastRecordedTimeMs = 0)
        assertTrue(unknownAccuracy.offer(fix(accuracy = -1.0, timeMs = 30_000), 30_000, interval, minAcc) is Decision.Skip)
    }

    @Test fun overdueRecordsTheMostAccurateInaccurateFix() {
        val gate = RecordingGate(lastRecordedTimeMs = 0)
        gate.offer(fix(accuracy = 300.0, timeMs = 30_000), 30_000, interval, minAcc)
        gate.offer(fix(accuracy = 120.0, lat = 1.0, timeMs = 45_000), 45_000, interval, minAcc)
        // at exactly interval + 30 s it is not yet overdue
        assertEquals(Decision.Skip(SkipReason.INACCURATE), gate.offer(fix(accuracy = 400.0, timeMs = 60_000), 60_000, interval, minAcc))
        val d = gate.offer(fix(accuracy = 200.0, timeMs = 60_001), 60_001, interval, minAcc).recorded()
        assertTrue(d.accuracyWaived)
        assertEquals(RecordEvent.INTERVAL, d.event)
        assertEquals(120.0, d.fix.accuracy, 0.0)
        assertEquals(45_000L, gate.lastRecordedTimeMs)
        // best is reset after recording
        assertEquals(Decision.Skip(SkipReason.INACCURATE), gate.offer(fix(accuracy = 300.0, timeMs = 70_000), 70_000, interval, minAcc))
    }

    @Test fun overdueBeforeAnyRecordUsesTheWindowStart() {
        val gate = RecordingGate()
        gate.beginWindow(nowMs = 0)
        assertTrue(gate.offer(fix(accuracy = 500.0, timeMs = 10_000), 10_000, interval, minAcc) is Decision.Skip)
        val d = gate.offer(fix(accuracy = 900.0, timeMs = 61_000), 61_000, interval, minAcc).recorded()
        assertEquals(500.0, d.fix.accuracy, 0.0)
        assertTrue(d.accuracyWaived)
    }

    @Test fun watchdogOverdueCheck() {
        val gate = RecordingGate(lastRecordedTimeMs = 0)
        assertNull(gate.checkOverdue(120_000, interval)) // nothing seen
        gate.offer(fix(accuracy = 300.0, timeMs = 10_000), 10_000, interval, minAcc)
        assertNull(gate.checkOverdue(60_000, interval))
        val d = gate.checkOverdue(60_001, interval)!!
        assertTrue(d.accuracyWaived)
    }

    @Test fun detectorMotionChangeRecordsImmediately() {
        val gate = RecordingGate(lastRecordedTimeMs = 0)
        val d = gate.offer(fix(accuracy = 70.0, timeMs = 1_000), 1_000, interval, minAcc, motionChanged = true).recorded()
        assertEquals(RecordEvent.MOTIONCHANGE, d.event)
        assertTrue(d.accuracyWaived)
    }

    @Test fun requestedMotionChangeTakesNextAccurateFix() {
        val gate = RecordingGate(lastRecordedTimeMs = 0)
        gate.requestMotionChange(nowMs = 1_000)
        assertTrue(gate.isMotionChangePending)
        assertEquals(Decision.Skip(SkipReason.INACCURATE), gate.offer(fix(accuracy = 80.0, timeMs = 2_000), 2_000, interval, minAcc))
        val d = gate.offer(fix(accuracy = 20.0, timeMs = 3_000), 3_000, interval, minAcc).recorded()
        assertEquals(RecordEvent.MOTIONCHANGE, d.event)
        assertFalse(d.accuracyWaived)
        assertFalse(gate.isMotionChangePending)
        // normal interval rule resumes from the motionchange record
        assertTrue(gate.offer(fix(timeMs = 10_000), 10_000, interval, minAcc) is Decision.Skip)
    }

    @Test fun requestedMotionChangeFallsBackToBestAfterGrace() {
        val gate = RecordingGate(lastRecordedTimeMs = 0)
        gate.requestMotionChange(nowMs = 0)
        gate.offer(fix(accuracy = 90.0, timeMs = 5_000), 5_000, interval, minAcc)
        gate.offer(fix(accuracy = 300.0, timeMs = 20_000), 20_000, interval, minAcc)
        val d = gate.offer(fix(accuracy = 400.0, timeMs = 30_000), 30_000, interval, minAcc).recorded()
        assertEquals(RecordEvent.MOTIONCHANGE, d.event)
        assertTrue(d.accuracyWaived)
        assertEquals(90.0, d.fix.accuracy, 0.0)
    }

    @Test fun clockMovingBackwardsDoesNotSilenceRecording() {
        val gate = RecordingGate(lastRecordedTimeMs = 2_000_000_000_000L)
        gate.offer(fix(timeMs = 1_800_000_000_000L), 1_800_000_000_000L, interval, minAcc).recorded()
        assertEquals(1_800_000_000_000L, gate.lastRecordedTimeMs)
    }

    @Test fun resumeTimeIsTheNewestStoredTimeButNeverLaterThanNow() {
        val now = 100_000L
        assertNull(RecordingGate.resumeTimeMs(null, null, null, now))
        assertEquals(75_000L, RecordingGate.resumeTimeMs(60_000, 75_000, 70_000, now))
        assertEquals(70_000L, RecordingGate.resumeTimeMs(60_000, null, 70_000, now))
        assertEquals(80_000L, RecordingGate.resumeTimeMs(80_000, 75_000, null, now))
        assertEquals(75_000L, RecordingGate.resumeTimeMs(null, 75_000, null, now))
        // a clock set back must not hold new fixes
        assertEquals(now, RecordingGate.resumeTimeMs(60_000, 500_000, null, now))
    }

    @Test fun seededClockHoldsTheFirstFixAfterARestart() {
        // Android e2e S12: lastRecordedTime was persisted 25 s before the crash; the newest queued
        // record is 3 s older than the first fix after the restart, so that fix is not due yet.
        val gate = RecordingGate(lastRecordedTimeMs = 0)
        gate.seed(RecordingGate.resumeTimeMs(0, 25_000, null, nowMs = 28_000))
        assertEquals(25_000L, gate.lastRecordedTimeMs)
        assertEquals(Decision.Skip(SkipReason.TOO_SOON), gate.offer(fix(timeMs = 28_000), 28_000, 10_000, minAcc))
        gate.offer(fix(timeMs = 35_000), 35_000, 10_000, minAcc).recorded()
    }

    @Test fun moreAccurateOrdering() {
        assertTrue(RecordingGate.moreAccurate(fix(accuracy = 5.0), fix(accuracy = 10.0)))
        assertFalse(RecordingGate.moreAccurate(fix(accuracy = -1.0), fix(accuracy = 1000.0)))
        assertTrue(RecordingGate.moreAccurate(fix(accuracy = 1000.0), fix(accuracy = -1.0)))
        assertTrue(RecordingGate.moreAccurate(fix(accuracy = 5.0, timeMs = 2), fix(accuracy = 5.0, timeMs = 1)))
    }
}
