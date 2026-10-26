package com.longping.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UploadPolicyTest {
    @Test fun classifiesResponses() {
        listOf(200, 201, 204, 299).forEach { assertEquals(UploadVerdict.Delivered, UploadPolicy.classify(it, 10)) }
        assertEquals(UploadVerdict.AuthFailed(401), UploadPolicy.classify(401, 10))
        assertEquals(UploadVerdict.AuthFailed(403), UploadPolicy.classify(403, 10))
        assertEquals(UploadVerdict.Shrink(5), UploadPolicy.classify(413, 10))
        assertEquals(UploadVerdict.Shrink(1), UploadPolicy.classify(413, 3))
        assertEquals(UploadVerdict.Shrink(1), UploadPolicy.classify(413, 2))
        assertEquals(UploadVerdict.Rejected(413), UploadPolicy.classify(413, 1))
        listOf(0, 408, 429, 500, 502, 503, 599).forEach { assertEquals(UploadVerdict.RetryLater(it), UploadPolicy.classify(it, 10)) }
        listOf(400, 404, 405, 409, 422, 451).forEach { assertEquals(UploadVerdict.Rejected(it), UploadPolicy.classify(it, 10)) }
        listOf(100, 301, 302, 304, 600).forEach { assertEquals(UploadVerdict.RetryLater(it), UploadPolicy.classify(it, 10)) }
    }

    @Test fun exponentialBackoffCappedAt900Seconds() {
        val mid = { 0.5 } // factor 1.0
        val expected = listOf(10L, 20, 40, 80, 160, 320, 640, 900, 900, 900)
        expected.forEachIndexed { n, sec -> assertEquals(sec * 1000, UploadPolicy.backoffDelayMs(n, null, mid)) }
        assertEquals(900_000L, UploadPolicy.backoffDelayMs(1000, null, mid))
        assertEquals(10_000L, UploadPolicy.backoffDelayMs(-3, null, mid))
    }

    @Test fun jitterIsPlusMinusTwentyPercent() {
        assertEquals(8_000L, UploadPolicy.backoffDelayMs(0, null) { 0.0 })
        assertEquals(11_999L, UploadPolicy.backoffDelayMs(0, null) { 0.99999 })
        assertEquals(720_000L, UploadPolicy.backoffDelayMs(10, null) { 0.0 })
        assertEquals(1_080_000L, UploadPolicy.backoffDelayMs(10, null) { 1.0 })
        val rnd = java.util.Random(7)
        repeat(1000) {
            val d = UploadPolicy.backoffDelayMs(2, null) { rnd.nextDouble() }
            assertTrue(d in 32_000L..48_000L)
        }
    }

    @Test fun retryAfterSecondsWins() {
        assertEquals(120_000L, UploadPolicy.backoffDelayMs(5, "120") { 0.0 })
        assertEquals(0L, UploadPolicy.backoffDelayMs(5, " 0 ") { 0.0 })
        assertEquals(86_400_000L, UploadPolicy.backoffDelayMs(0, "999999999") { 0.5 })
        // HTTP-date and garbage fall back to the computed backoff
        assertEquals(10_000L, UploadPolicy.backoffDelayMs(0, "Wed, 21 Oct 2026 07:28:00 GMT") { 0.5 })
        assertEquals(10_000L, UploadPolicy.backoffDelayMs(0, "-5") { 0.5 })
        assertNull(UploadPolicy.parseRetryAfterSec(null))
        assertEquals(30L, UploadPolicy.parseRetryAfterSec("30"))
    }
}

class UploadSchedulerTest {
    @Test fun syncAndAuthorizationAlwaysRun() {
        val blocked = UploadState(nextAttemptAtMs = 10_000, authPausedUntilMs = 10_000, lastAttemptAtMs = 0)
        assertTrue(UploadScheduler.isDue(UploadTrigger.SYNC, blocked, 0, 600.0))
        assertTrue(UploadScheduler.isDue(UploadTrigger.AUTHORIZATION, blocked, 0, 600.0))
    }

    @Test fun recordTriggerHonoursUploadInterval() {
        val s = UploadState(lastAttemptAtMs = 1_000)
        assertTrue(UploadScheduler.isDue(UploadTrigger.RECORD, s, 1_001, 0.0))
        assertFalse(UploadScheduler.isDue(UploadTrigger.RECORD, s, 60_999, 60.0))
        assertTrue(UploadScheduler.isDue(UploadTrigger.RECORD, s, 61_000, 60.0))
        assertEquals(61_000L, UploadScheduler.nextDueAtMs(s, 60.0))
    }

    @Test fun backoffBlocksRecordAndWatchdogTriggers() {
        val s = UploadScheduler.retryLater(UploadState(), nowMs = 0, delayMs = 20_000, networkFailure = false)
        assertEquals(1, s.failures)
        assertFalse(UploadScheduler.isDue(UploadTrigger.RECORD, s, 19_999, 0.0))
        assertFalse(UploadScheduler.isDue(UploadTrigger.WATCHDOG, s, 19_999, 0.0))
        assertFalse(UploadScheduler.isDue(UploadTrigger.CONNECTIVITY, s, 19_999, 0.0))
        assertTrue(UploadScheduler.isDue(UploadTrigger.WATCHDOG, s, 20_000, 0.0))
    }

    @Test fun connectivitySkipsBackoffAfterANetworkFailure() {
        val s = UploadScheduler.retryLater(UploadState(), 0, 600_000, networkFailure = true)
        assertTrue(UploadScheduler.isDue(UploadTrigger.CONNECTIVITY, s, 1, 0.0))
        assertFalse(UploadScheduler.isDue(UploadTrigger.RECORD, s, 1, 0.0))
    }

    @Test fun authPauseBlocksForFifteenMinutesUnlessAuthorizationIsSet() {
        val paused = UploadScheduler.authPaused(UploadState(), nowMs = 0)
        assertTrue(paused.authorizationRequired)
        assertFalse(UploadScheduler.isDue(UploadTrigger.RECORD, paused, 15 * 60_000 - 1, 0.0))
        assertFalse(UploadScheduler.isDue(UploadTrigger.CONNECTIVITY, paused, 1, 0.0))
        assertTrue(UploadScheduler.isDue(UploadTrigger.WATCHDOG, paused, 15 * 60_000, 0.0))
        val cleared = UploadScheduler.authorizationSet(paused)
        assertFalse(cleared.authorizationRequired)
        assertTrue(UploadScheduler.isDue(UploadTrigger.RECORD, cleared, 1, 0.0))
    }

    @Test fun deliveredResetsEverything() {
        val messy = UploadState(failures = 4, nextAttemptAtMs = 99, authPausedUntilMs = 99, authorizationRequired = true, lastFailureWasNetwork = true, lastAttemptAtMs = 5)
        assertEquals(UploadState(lastAttemptAtMs = 5), UploadScheduler.delivered(messy))
        assertEquals(42L, UploadScheduler.attempted(UploadState(), 42).lastAttemptAtMs)
    }

    @Test fun statePersistsAndToleratesGarbage() {
        val s = UploadState(3, 10, 20, 30, true, true)
        assertEquals(s, UploadState.fromJson(s.toJson().toString()))
        assertEquals(UploadState(), UploadState.fromJson("{oops"))
        assertEquals(UploadState(), UploadState.fromJson(null))
    }
}

class RemoteDirectiveTest {
    @Test fun parsesConfigAndStop() {
        val d = RemoteDirective.parse("""{"ok":true,"long_ping":{"config":{"movingIntervalSec":5},"stop":true}}""")!!
        assertEquals(5, d.config!!.getInt("movingIntervalSec"))
        assertTrue(d.stop)
        val onlyConfig = RemoteDirective.parse("""{"long_ping":{"config":{"debug":true}}}""")!!
        assertFalse(onlyConfig.stop)
    }

    @Test fun ignoresAnythingElse() {
        assertNull(RemoteDirective.parse(null))
        assertNull(RemoteDirective.parse(""))
        assertNull(RemoteDirective.parse("OK"))
        assertNull(RemoteDirective.parse("[1]"))
        assertNull(RemoteDirective.parse("{broken"))
        assertNull(RemoteDirective.parse("""{"long_ping":"stop"}"""))
        val weird = RemoteDirective.parse("""{"long_ping":{"config":"x","stop":"true"}}""")!!
        assertNull(weird.config)
        assertFalse(weird.stop)
    }
}

class AuthCredentialsTest {
    @Test fun validatesInput() {
        assertThrowsConfig("accessToken") { AuthCredentials.fromJson(json("{}")) }
        assertThrowsConfig("accessToken") { AuthCredentials.fromJson(json("""{"accessToken":""}""")) }
        assertThrowsConfig("refreshUrl") { AuthCredentials.fromJson(json("""{"accessToken":"a","refreshUrl":"ftp://x"}""")) }
        assertThrowsConfig("refreshPayload") { AuthCredentials.fromJson(json("""{"accessToken":"a","refreshPayload":"x"}""")) }
        assertThrowsConfig("refreshHeaders.X") { AuthCredentials.fromJson(json("""{"accessToken":"a","refreshHeaders":{"X":1}}""")) }
        val a = AuthCredentials.fromJson(json("""{"accessToken":"a","refreshToken":"r","refreshUrl":"https://x.test/r","refreshHeaders":{"X":"1"}}"""))
        assertTrue(a.canRefresh)
        assertEquals(a, AuthCredentials.restore(a.toJson().toString()))
        assertFalse(AuthCredentials.fromJson(json("""{"accessToken":"a"}""")).canRefresh)
        assertNull(AuthCredentials.restore("garbage"))
    }

    @Test fun refreshBodyFillsTheToken() {
        val a = AuthCredentials("a", refreshToken = "r-1", refreshUrl = "https://x.test")
        assertEquals("r-1", json(a.refreshBody()).getString("refresh_token"))
        val custom = a.copy(refreshPayloadJson = """{"grant_type":"refresh_token","token":"Bearer {{refreshToken}}","n":1}""")
        val body = json(custom.refreshBody())
        assertEquals("refresh_token", body.getString("grant_type"))
        assertEquals("Bearer r-1", body.getString("token"))
        assertEquals(1, body.getInt("n"))
    }

    @Test fun parsesRefreshReplies() {
        assertEquals("n" to "m", AuthCredentials.parseRefreshResponse("""{"access_token":"n","refresh_token":"m"}"""))
        assertEquals("n" to null, AuthCredentials.parseRefreshResponse("""{"accessToken":"n"}"""))
        assertEquals("n" to "m", AuthCredentials.parseRefreshResponse("""{"accessToken":"n","refreshToken":"m"}"""))
        assertNull(AuthCredentials.parseRefreshResponse("""{"token":"n"}"""))
        assertNull(AuthCredentials.parseRefreshResponse("<html>"))
        assertNull(AuthCredentials.parseRefreshResponse(null))
    }

    @Test fun withTokensKeepsTheOldRefreshTokenWhenNoneIsReturned() {
        val a = AuthCredentials("a", refreshToken = "r", refreshUrl = "https://x.test")
        assertEquals(AuthCredentials("b", "r", "https://x.test"), a.withTokens("b", null))
        assertEquals(AuthCredentials("b", "s", "https://x.test"), a.withTokens("b", "s"))
    }
}
