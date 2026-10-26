package com.longping.core

import org.json.JSONObject
import java.io.File

internal fun json(text: String) = JSONObject(text)

internal fun fix(
    lat: Double = 43.85,
    lon: Double = 18.41,
    accuracy: Double = 5.0,
    speed: Double = -1.0,
    timeMs: Long = 0,
    heading: Double = -1.0,
    altitude: Double? = null,
    mock: Boolean = false,
) = Fix(lat, lon, accuracy, speed, heading, altitude, timeMs, mock)

/** Moves [meters] due north from (lat, lon). */
internal fun northOf(lat: Double, meters: Double): Double = lat + Math.toDegrees(meters / Geo.EARTH_RADIUS_M)

internal fun androidDir(): File = File(System.getProperty("longping.androidDir") ?: "../../android")

internal fun repoFile(relative: String): File = File(androidDir().parentFile, relative)

internal fun assertThrowsConfig(keyFragment: String, block: () -> Unit): ConfigException {
    try {
        block()
    } catch (e: ConfigException) {
        org.junit.Assert.assertTrue("message '${e.message}' should name '$keyFragment'", e.message!!.contains(keyFragment))
        org.junit.Assert.assertEquals(ErrorCode.INVALID_CONFIG, e.code)
        return e
    }
    throw AssertionError("expected ConfigException naming $keyFragment")
}
