package com.longping.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Random

class Iso8601Test {
    private val reference = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)

    @Test fun formatsEpochAndContractExample() {
        assertEquals("1970-01-01T00:00:00.000Z", Iso8601.format(0))
        val ms = Instant.parse("2026-10-26T12:00:00.123Z").toEpochMilli()
        assertEquals("2026-10-26T12:00:00.123Z", Iso8601.format(ms))
        assertEquals("2026-10-26", Iso8601.date(ms))
    }

    @Test fun matchesJavaTimeAcrossRangeIncludingLeapDays() {
        val rnd = Random(42)
        repeat(20_000) {
            val ms = (rnd.nextDouble() * 8_000_000_000_000L).toLong() - 1_000_000_000_000L
            assertEquals(reference.format(Instant.ofEpochMilli(ms)), Iso8601.format(ms))
        }
        val leap = Instant.parse("2028-02-29T23:59:59.999Z").toEpochMilli()
        assertEquals("2028-02-29T23:59:59.999Z", Iso8601.format(leap))
        assertEquals("2028-03-01T00:00:00.000Z", Iso8601.format(leap + 1))
    }
}

class JsonTest {
    @Test fun deepMergeMergesObjectsAndReplacesArraysAndScalars() {
        val base = json("""{"a":1,"o":{"x":1,"y":{"k":1}},"arr":[1,2,3],"n":{"z":1}}""")
        val overlay = json("""{"a":2,"o":{"y":{"j":2}},"arr":[9],"n":null,"new":"v"}""")
        val merged = Json.deepMerge(base, overlay)
        assertEquals(2, merged.getInt("a"))
        assertEquals(1, merged.getJSONObject("o").getInt("x"))
        assertEquals(1, merged.getJSONObject("o").getJSONObject("y").getInt("k"))
        assertEquals(2, merged.getJSONObject("o").getJSONObject("y").getInt("j"))
        assertEquals(1, merged.getJSONArray("arr").length())
        assertTrue(merged.isNull("n"))
        assertTrue(merged.has("n"))
        assertEquals("v", merged.getString("new"))
        // inputs untouched
        assertEquals(3, base.getJSONArray("arr").length())
        assertTrue(base.getJSONObject("o").getJSONObject("y").has("k") && !base.getJSONObject("o").getJSONObject("y").has("j"))
    }

    @Test fun valueAndValueText() {
        val o = json("""{"n":null,"s":"x","d":1.5,"i":3,"b":true}""")
        assertNull(Json.value(o, "n"))
        assertNull(Json.value(o, "missing"))
        assertEquals("\"x\"", Json.valueText("x"))
        assertEquals("1.5", Json.valueText(1.5))
        assertEquals("3", Json.valueText(3))
        assertEquals("true", Json.valueText(true))
        assertEquals("null", Json.valueText(JSONObject.NULL))
        assertEquals("[1]", Json.valueText(JSONArray("[1]")))
    }
}

class StrictJsonTest {
    @Test fun acceptsValidDocuments() {
        listOf(
            "{}", "[]", "0", "-0", "1.5e10", "-2.25E-3", "\"a\\u00e9\\n\"", "true", "false", "null",
            """ {"a":[1,{"b":null}],"c":"d"} """, "[\"\\/\"]",
        ).forEach { assertNull(it, StrictJson.validate(it)) }
    }

    @Test fun rejectsWhatLenientParsersAccept() {
        listOf(
            """{"t":2026-10-26T12:00:00.123Z}""", // unquoted timestamp token
            "{a:1}", "{'a':1}", "[1,]", "{\"a\":1,}", "01", "1.", ".5", "+1", "NaN", "\"tab\there\"",
            "{\"a\":1} x", "", "[", "{\"a\"1}", "tru", "\"\\x\"", "[1 2]",
        ).forEach { assertNotNull(it, StrictJson.validate(it)) }
    }

    @Test fun guardsAgainstDeepNesting() {
        assertNotNull(StrictJson.validate("[".repeat(10_000) + "]".repeat(10_000)))
    }
}
