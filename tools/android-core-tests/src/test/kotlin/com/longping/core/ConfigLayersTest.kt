package com.longping.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** DESIGN.md, "Remote config": the server's overrides are their own layer on top of configure() / setConfig(). */
class ConfigLayersTest {
    private val appConfig = """{"movingIntervalSec":10,"http":{"url":"https://api.example.com/locations","uploadIntervalSec":60}}"""

    private fun configured(text: String = appConfig) = ConfigLayers().also { it.setLocal(json(text), merge = false) }

    private fun remote(layers: ConfigLayers, config: String?, reset: Boolean = false) =
        layers.applyRemote(config?.let { json(it) }, reset)

    private fun overrides(layers: ConfigLayers) = json(layers.overridesJson)

    @Test fun overrideSurvivesConfigure() {
        val layers = configured()
        val change = remote(layers, """{"movingIntervalSec":5,"http":{"uploadIntervalSec":15}}""")
        assertTrue(change.overridesChanged)
        assertTrue(change.effectiveChanged)
        assertEquals(5.0, layers.effective.movingIntervalSec, 0.0)
        assertEquals(15.0, layers.effective.http.uploadIntervalSec, 0.0)
        assertEquals("objects deep-merge", "https://api.example.com/locations", layers.effective.http.url)
        assertEquals(10.0, layers.local.movingIntervalSec, 0.0)

        // Relaunch: both layers come back from storage, then the app calls configure() as it does on every launch.
        val restored = ConfigLayers.restore(layers.local, layers.overridesJson)
        assertNull(restored.droppedOverrides)
        val relaunched = restored.layers
        assertEquals(5.0, relaunched.effective.movingIntervalSec, 0.0)
        assertNull(relaunched.setLocal(json(appConfig), merge = false).droppedOverrides)
        assertEquals(5.0, relaunched.effective.movingIntervalSec, 0.0)
        assertEquals(15.0, relaunched.effective.http.uploadIntervalSec, 0.0)
        assertEquals(10.0, relaunched.local.movingIntervalSec, 0.0)

        // A different configure() still keeps the overridden keys; everything else is the app's.
        relaunched.setLocal(json("""{"parkedIntervalSec":600}"""), merge = false)
        assertEquals(5.0, relaunched.effective.movingIntervalSec, 0.0)
        assertEquals(600.0, relaunched.effective.parkedIntervalSec, 0.0)
        assertNull(relaunched.effective.http.url)
        assertEquals(15.0, relaunched.effective.http.uploadIntervalSec, 0.0)
    }

    @Test fun overridesAccumulateAndWinOverSetConfig() {
        val layers = configured()
        remote(layers, """{"movingIntervalSec":5}""")
        remote(layers, """{"parkedIntervalSec":60,"http":{"batch":false}}""")
        val o = overrides(layers)
        assertEquals(5, o.getInt("movingIntervalSec"))
        assertEquals(60, o.getInt("parkedIntervalSec"))
        assertFalse(o.getJSONObject("http").getBoolean("batch"))

        // setConfig() merges into the app's layer: an overridden key keeps the server's value, the rest applies.
        layers.setLocal(json("""{"movingIntervalSec":20,"stopRadiusM":150,"http":{"maxBatchSize":10}}"""), merge = true)
        assertEquals(20.0, layers.local.movingIntervalSec, 0.0)
        assertEquals(5.0, layers.effective.movingIntervalSec, 0.0)
        assertEquals(60.0, layers.effective.parkedIntervalSec, 0.0)
        assertEquals(150.0, layers.effective.stopRadiusM, 0.0)
        assertEquals(10, layers.effective.http.maxBatchSize)
        assertFalse(layers.effective.http.batch)
        assertEquals("https://api.example.com/locations", layers.effective.http.url)

        val repeated = remote(layers, """{"movingIntervalSec":5}""")
        assertFalse(repeated.overridesChanged)
        assertFalse("the same config again is not a change", repeated.effectiveChanged)
    }

    @Test fun resetClearsTheOverrides() {
        val layers = configured()
        remote(layers, """{"movingIntervalSec":5}""")
        val change = remote(layers, null, reset = true)
        assertTrue(change.overridesChanged)
        assertTrue(change.effectiveChanged)
        assertEquals("{}", layers.overridesJson)
        assertEquals(layers.local, layers.effective)
        assertEquals(10.0, layers.effective.movingIntervalSec, 0.0)
        assertFalse("nothing left to clear", remote(layers, null, reset = true).effectiveChanged)
    }

    @Test fun resetAndConfigInOneReplyApplyInThatOrder() {
        val layers = configured()
        remote(layers, """{"movingIntervalSec":5,"parkedIntervalSec":60}""")
        val change = remote(layers, """{"parkedIntervalSec":90}""", reset = true)
        assertNull(change.rejected)
        val o = overrides(layers)
        assertEquals(listOf("parkedIntervalSec"), Json.keys(o))
        assertEquals(90, o.getInt("parkedIntervalSec"))
        assertEquals(10.0, layers.effective.movingIntervalSec, 0.0)
        assertEquals(90.0, layers.effective.parkedIntervalSec, 0.0)

        // An invalid config is refused whole; the reset in the same reply still applies.
        val refused = remote(layers, """{"movingIntervalSec":"fast"}""", reset = true)
        assertEquals("movingIntervalSec", refused.rejected?.key)
        assertEquals("{}", layers.overridesJson)
        assertEquals(layers.local, layers.effective)
    }

    @Test fun remoteConfigFalseKeepsOverridesStoredButUnapplied() {
        val layers = configured()
        remote(layers, """{"movingIntervalSec":5}""")
        layers.setLocal(json("""{"remoteConfig":false}"""), merge = true)
        assertEquals(layers.local, layers.effective)
        assertEquals(10.0, layers.effective.movingIntervalSec, 0.0)
        assertEquals("kept stored", 5, overrides(layers).getInt("movingIntervalSec"))

        val ignored = remote(layers, """{"parkedIntervalSec":60}""")
        assertTrue(ignored.ignored)
        assertFalse(ignored.overridesChanged)
        assertFalse(ignored.effectiveChanged)

        // Kept across a relaunch, and applied again once the app turns remoteConfig back on.
        val relaunched = ConfigLayers.restore(layers.local, layers.overridesJson).layers
        assertEquals(10.0, relaunched.effective.movingIntervalSec, 0.0)
        relaunched.setLocal(json("""{"remoteConfig":true}"""), merge = true)
        assertEquals(5.0, relaunched.effective.movingIntervalSec, 0.0)
        assertEquals("what arrived while off was not stored", 180.0, relaunched.effective.parkedIntervalSec, 0.0)
    }

    @Test fun theServerCannotChangeRemoteConfig() {
        val layers = configured()
        val change = remote(layers, """{"remoteConfig":false,"movingIntervalSec":5}""")
        assertTrue(change.remoteConfigKeyIgnored)
        assertTrue(layers.effective.remoteConfig)
        assertEquals(5.0, layers.effective.movingIntervalSec, 0.0)
        assertFalse(overrides(layers).has("remoteConfig"))
    }

    @Test fun invalidOverridesAreRefusedAndOnesThatStopValidatingAreDropped() {
        val layers = configured("""{"lowBattery":{"belowPct":20,"intervalSec":600}}""")
        val bad = remote(layers, """{"http":{"url":"ftp://x"}}""")
        assertEquals("http.url", bad.rejected?.key)
        assertFalse(bad.overridesChanged)
        assertFalse(bad.effectiveChanged)

        assertNull(remote(layers, """{"lowBattery":{"belowPct":10}}""").rejected)
        assertEquals(LowBattery(10.0, 600.0), layers.effective.lowBattery)
        // configure() without lowBattery leaves the override half a policy: the overrides go, the app's call stands.
        val change = layers.setLocal(json("""{"movingIntervalSec":10}"""), merge = false)
        assertEquals("lowBattery.intervalSec", change.droppedOverrides?.key)
        assertEquals("{}", layers.overridesJson)
        assertEquals(layers.local, layers.effective)

        assertThrowsConfig("movingIntervalSec") { layers.setLocal(json("""{"movingIntervalSec":"10"}"""), merge = false) }
        val stored = ConfigLayers.restore(layers.local, """{"lowBattery":{"belowPct":10}}""")
        assertEquals("lowBattery.intervalSec", stored.droppedOverrides?.key)
        assertEquals("{}", stored.layers.overridesJson)
        assertEquals(layers.local, ConfigLayers.restore(layers.local, "not json").layers.effective)
    }
}
