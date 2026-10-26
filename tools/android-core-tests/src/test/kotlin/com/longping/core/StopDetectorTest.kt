package com.longping.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StopDetectorTest {
    private val p = StopParams(minAccuracyM = 100.0, stopRadiusM = 75.0, stopTimeoutSec = 300.0, movingSpeedMps = 3.0, disableStopDetection = false)
    private val lat0 = 43.85

    private fun moving() = StopDetector(MotionState(isMoving = true, anchor = null, parkedAt = null))

    @Test fun firstFixBecomesTheAnchorAndParksAfterTimeout() {
        val d = moving()
        assertNull(d.evaluate(fix(lat = lat0, timeMs = 0), p))
        assertEquals(0L, d.state.anchor!!.timeMs)
        assertNull(d.evaluate(fix(lat = northOf(lat0, 40.0), timeMs = 299_999), p))
        assertEquals(MotionTransition.PARKED, d.evaluate(fix(lat = northOf(lat0, 40.0), timeMs = 300_000), p))
        assertFalse(d.state.isMoving)
        assertEquals(300_000L, d.state.parkedAt!!.timeMs)
        assertNull(d.state.anchor)
    }

    @Test fun displacementOrSpeedResetsTheAnchor() {
        val d = moving()
        d.evaluate(fix(lat = lat0, timeMs = 0), p)
        assertNull(d.evaluate(fix(lat = northOf(lat0, 80.0), timeMs = 200_000), p))
        assertEquals(200_000L, d.state.anchor!!.timeMs)
        assertNull(d.evaluate(fix(lat = northOf(lat0, 80.0), speed = 3.0, timeMs = 400_000), p))
        assertEquals(400_000L, d.state.anchor!!.timeMs)
        assertNull(d.evaluate(fix(lat = northOf(lat0, 80.0), speed = 2.9, timeMs = 699_999), p))
        assertEquals(MotionTransition.PARKED, d.evaluate(fix(lat = northOf(lat0, 80.0), speed = 2.9, timeMs = 700_000), p))
    }

    @Test fun onlyFixesWithinTheAccuracyLimitAreEvaluated() {
        val d = moving()
        assertNull(d.evaluate(fix(accuracy = 100.1, timeMs = 0), p))
        assertNull(d.state.anchor)
        assertNull(d.evaluate(fix(accuracy = -1.0, timeMs = 0), p))
        assertNull(d.state.anchor)
        d.evaluate(fix(accuracy = 100.0, timeMs = 0), p)
        assertNotNull(d.state.anchor)

        // minAccuracyM 0 -> the limit is stopRadiusM
        val zero = p.copy(minAccuracyM = 0.0)
        val d2 = moving()
        d2.evaluate(fix(accuracy = 76.0, timeMs = 0), zero)
        assertNull(d2.state.anchor)
        d2.evaluate(fix(accuracy = 75.0, timeMs = 0), zero)
        assertNotNull(d2.state.anchor)

        // stopRadiusM above minAccuracyM widens the limit
        val wide = p.copy(minAccuracyM = 20.0, stopRadiusM = 150.0)
        val d3 = moving()
        d3.evaluate(fix(accuracy = 140.0, timeMs = 0), wide)
        assertNotNull(d3.state.anchor)
    }

    @Test fun parkedMovesOnSpeedOnlyWithGoodAccuracy() {
        val d = StopDetector(MotionState(false, null, GeoPoint(lat0, 18.41, 5.0, 0)))
        assertNull(d.evaluate(fix(lat = lat0, speed = 10.0, accuracy = 60.0, timeMs = 1000), p))
        assertEquals(MotionTransition.MOVED, d.evaluate(fix(lat = lat0, speed = 3.0, accuracy = 50.0, timeMs = 2000), p))
        assertTrue(d.state.isMoving)
        assertEquals(2000L, d.state.anchor!!.timeMs)
        assertNull(d.state.parkedAt)
    }

    @Test fun parkedMovesOnDistanceOnlyWhenAccuracyWithinRadius() {
        val d = StopDetector(MotionState(false, null, GeoPoint(lat0, 18.41, 5.0, 0)))
        assertNull(d.evaluate(fix(lat = northOf(lat0, 70.0), accuracy = 10.0, timeMs = 1000), p))
        assertNull(d.evaluate(fix(lat = northOf(lat0, 500.0), accuracy = 76.0, timeMs = 2000), p))
        assertEquals(MotionTransition.MOVED, d.evaluate(fix(lat = northOf(lat0, 80.0), accuracy = 75.0, timeMs = 3000), p))
    }

    @Test fun disableStopDetectionNeverParksButForcedParkStillMoves() {
        val off = p.copy(disableStopDetection = true)
        val d = moving()
        d.evaluate(fix(timeMs = 0), off)
        assertNull(d.evaluate(fix(timeMs = 10_000_000), off))
        assertTrue(d.state.isMoving)

        d.force(false, GeoPoint(lat0, 18.41, 5.0, 0))
        assertEquals(MotionTransition.MOVED, d.evaluate(fix(lat = lat0, speed = 5.0, accuracy = 5.0, timeMs = 1), off))
    }

    @Test fun forceAndParkedWithoutAPoint() {
        val d = moving()
        d.force(false, null)
        assertFalse(d.state.isMoving)
        assertNull(d.evaluate(fix(lat = lat0, timeMs = 10), p))
        assertEquals(10L, d.state.parkedAt!!.timeMs)
        assertEquals(MotionTransition.MOVED, d.evaluate(fix(lat = northOf(lat0, 100.0), accuracy = 10.0, timeMs = 20), p))

        d.force(true, GeoPoint(1.0, 2.0, 3.0, 4))
        assertEquals(MotionState(true, GeoPoint(1.0, 2.0, 3.0, 4), null), d.state)
    }
}
