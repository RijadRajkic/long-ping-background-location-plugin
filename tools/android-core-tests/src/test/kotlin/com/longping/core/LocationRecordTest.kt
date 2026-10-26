package com.longping.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class LocationRecordTest {
    private val t = Instant.parse("2026-10-26T12:00:00.123Z").toEpochMilli()

    @Test fun buildsTheContractShape() {
        val r = LocationRecord.build(
            "6f1c2a1e-0000-4000-8000-000000000001",
            Fix(43.85, 18.41, 4.8, 12.3, 181.0, 520.4, t, mock = false),
            RecordEvent.INTERVAL, isMoving = true, battery = BatteryState(0.82, false), extras = null,
        )
        assertEquals(setOf("uuid", "timestamp", "event", "is_moving", "coords", "battery", "mock"), Json.keys(r).toSet())
        assertEquals("2026-10-26T12:00:00.123Z", r.getString("timestamp"))
        assertEquals("interval", r.getString("event"))
        assertTrue(r.getBoolean("is_moving"))
        val c = r.getJSONObject("coords")
        assertEquals(setOf("latitude", "longitude", "accuracy", "speed", "heading", "altitude"), Json.keys(c).toSet())
        assertEquals(43.85, c.getDouble("latitude"), 0.0)
        assertEquals(520.4, c.getDouble("altitude"), 0.0)
        assertEquals(0.82, r.getJSONObject("battery").getDouble("level"), 0.0)
        assertFalse(r.getJSONObject("battery").getBoolean("is_charging"))
        assertFalse(r.getBoolean("mock"))
        // numbers are JSON numbers, not strings
        assertTrue(r.toString().contains("\"latitude\":43.85"))
    }

    @Test fun unknownValuesAndExtras() {
        val r = LocationRecord.build(
            "u", Fix(1.0, 2.0, -1.0, timeMs = t, mock = true), RecordEvent.MOTIONCHANGE, false,
            BatteryState.UNKNOWN, JSONObject().put("driver", 7),
        )
        val c = r.getJSONObject("coords")
        assertEquals(-1.0, c.getDouble("speed"), 0.0)
        assertEquals(-1.0, c.getDouble("heading"), 0.0)
        assertTrue(c.isNull("altitude"))
        assertEquals(-1.0, r.getJSONObject("battery").getDouble("level"), 0.0)
        assertTrue(r.getBoolean("mock"))
        assertEquals("motionchange", r.getString("event"))
        assertEquals(7, r.getJSONObject("extras").getInt("driver"))

        val noExtras = LocationRecord.build("u", fix(timeMs = t), RecordEvent.CURRENT, false, BatteryState.UNKNOWN, JSONObject())
        assertFalse(noExtras.has("extras"))
        assertEquals("current", noExtras.getString("event"))
    }

    @Test fun nonFiniteNumbersNeverBreakTheRecord() {
        val r = LocationRecord.build("u", Fix(1.0, 2.0, Double.NaN, Double.POSITIVE_INFINITY, Double.NaN, Double.NaN, t), RecordEvent.INTERVAL, true, BatteryState(Double.NaN, false), null)
        assertEquals(-1.0, r.getJSONObject("coords").getDouble("accuracy"), 0.0)
        assertTrue(r.getJSONObject("coords").isNull("altitude"))
        assertEquals(-1.0, r.getJSONObject("battery").getDouble("level"), 0.0)
    }

    @Test fun extrasMergeCallWinsAndEmptyIsNull() {
        val merged = LocationRecord.mergeExtras(JSONObject().put("a", 1).put("b", 1), JSONObject().put("b", 2).put("c", JSONArray("[1]")))!!
        assertEquals(1, merged.getInt("a"))
        assertEquals(2, merged.getInt("b"))
        assertEquals(1, merged.getJSONArray("c").length())
        assertNull(LocationRecord.mergeExtras(JSONObject(), null))
        assertNull(LocationRecord.mergeExtras(JSONObject(), JSONObject()))
    }
}

class LocationTemplateTest {
    private val record = LocationRecord.build(
        "abc", Fix(43.85, 18.41, 4.8, 12.3, 181.0, null, Instant.parse("2026-10-26T12:00:00.123Z").toEpochMilli()),
        RecordEvent.INTERVAL, true, BatteryState(0.5, true), JSONObject().put("k", "v"),
    )

    @Test fun rendersEveryTokenRaw() {
        val all = LocationTemplate.TOKENS.filter { it != "extras" }.joinToString(",") { "\"$it\":\"{{$it}}\"" } + ",\"extras\":{{extras}}"
        val out = JSONObject(LocationTemplate.render("{$all}", record))
        assertEquals("abc", out.getString("uuid"))
        assertEquals("2026-10-26T12:00:00.123Z", out.getString("timestamp"))
        assertEquals("interval", out.getString("event"))
        assertEquals("true", out.getString("is_moving"))
        assertEquals("43.85", out.getString("latitude"))
        assertEquals("18.41", out.getString("longitude"))
        assertEquals("4.8", out.getString("accuracy"))
        assertEquals("12.3", out.getString("speed"))
        assertEquals("181", out.getString("heading"))
        assertEquals("null", out.getString("altitude"))
        assertEquals("0.5", out.getString("battery_level"))
        assertEquals("true", out.getString("battery_is_charging"))
        assertEquals("false", out.getString("mock"))
        assertEquals("v", out.getJSONObject("extras").getString("k"))
    }

    @Test fun stringsGoInWithoutQuotesAndExtrasAsObjectText() {
        val tpl = """{"id":"{{uuid}}","lat":{{latitude}},"alt":{{altitude}},"moving":{{is_moving}},"x":{{extras}}}"""
        val text = LocationTemplate.render(tpl, record)
        assertEquals("""{"id":"abc","lat":43.85,"alt":null,"moving":true,"x":{"k":"v"}}""", text)
        val noExtras = JSONObject(record.toString()).also { it.remove("extras") }
        assertTrue(LocationTemplate.render("{{extras}}", noExtras) == "{}")
        assertTrue(LocationTemplate.render("{{ latitude }}", record) == "43.85")
    }

    @Test fun validation() {
        assertNull(LocationTemplate.validate("""{"lat":{{latitude}},"t":"{{timestamp}}"}""", requireObject = true))
        assertNull(LocationTemplate.validate("""[{{latitude}},{{longitude}}]""", requireObject = false))
        assertTrue(LocationTemplate.validate("""{"t":{{timestamp}}}""", false)!!.contains("valid JSON"))
        assertTrue(LocationTemplate.validate("""{"a":{{nope}},"b":{{latitude}},"c":{{nope}}}""", false)!!.contains("{{nope}}"))
        assertEquals(listOf("nope"), LocationTemplate.unknownTokens("{{nope}} {{latitude}} {{nope}}"))
        assertTrue(LocationTemplate.validate("[{{latitude}}]", requireObject = true)!!.contains("object"))
    }
}

class UploadBodyTest {
    private val r1 = """{"uuid":"1"}"""
    private val r2 = """{"uuid":"2"}"""

    @Test fun batchUsesLocationsByDefaultAndMergesParams() {
        assertEquals("""{"locations":[{"uuid":"1"},{"uuid":"2"}]}""", UploadBody.batch(listOf(r1, r2), JSONObject(), null))
        assertEquals("""{"locations":[{"uuid":"1"}]}""", UploadBody.batch(listOf(r1), JSONObject(), "."))
        val body = JSONObject(UploadBody.batch(listOf(r1, r2), JSONObject().put("device", "d1").put("n", 2), "points"))
        assertEquals("d1", body.getString("device"))
        assertEquals(2, body.getInt("n"))
        assertEquals(2, body.getJSONArray("points").length())
        assertEquals("2", body.getJSONArray("points").getJSONObject(1).getString("uuid"))
    }

    @Test fun recordsWinOverAParamWithTheSameKey() {
        val body = JSONObject(UploadBody.batch(listOf(r1), JSONObject().put("locations", "param"), null))
        assertEquals(1, body.getJSONArray("locations").length())
        assertEquals(1, body.length())
    }

    @Test fun singleUsesLocationOrRoot() {
        assertEquals("""{"location":{"uuid":"1"}}""", UploadBody.single(r1, JSONObject(), null))
        val wrapped = JSONObject(UploadBody.single(r1, JSONObject().put("k", 1), "loc"))
        assertEquals("1", wrapped.getJSONObject("loc").getString("uuid"))
        assertEquals(1, wrapped.getInt("k"))
        val atRoot = JSONObject(UploadBody.single("""{"uuid":"1","k":"record"}""", JSONObject().put("k", "param").put("p", true), "."))
        assertEquals("1", atRoot.getString("uuid"))
        assertEquals("record", atRoot.getString("k"))
        assertTrue(atRoot.getBoolean("p"))
    }

    @Test fun recordTextIsVerbatimOrRenderedTemplate() {
        val stored = LocationRecord.build("u1", fix(timeMs = 0), RecordEvent.INTERVAL, true, BatteryState.UNKNOWN, null).toString()
        assertEquals(stored, UploadBody.recordText(stored, null))
        assertEquals("""{"id":"u1"}""", UploadBody.recordText(stored, """{"id":"{{uuid}}"}"""))
        // rendered records go into the batch verbatim
        assertEquals("""{"locations":[{"id":"u1"}]}""", UploadBody.batch(listOf(UploadBody.recordText(stored, """{"id":"{{uuid}}"}""")), JSONObject(), null))
    }
}
