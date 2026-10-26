import XCTest
@testable import LongPingCore

final class UploadPolicyTests: XCTestCase {
    private func action(_ status: Int, count: Int = 10, refresh: Bool = false, refreshed: Bool = false) -> UploadAction {
        UploadPolicy.action(status: status, sentCount: count, refreshAvailable: refresh, alreadyRefreshed: refreshed)
    }

    func testSuccess() {
        for status in [200, 201, 204, 299] { XCTAssertEqual(action(status), .deleteSent) }
    }

    func testAuthFailures() {
        for status in [401, 403] {
            XCTAssertEqual(action(status, refresh: true), .refreshAndRetry)
            XCTAssertEqual(action(status, refresh: true, refreshed: true), .pauseForAuthorization, "retry once only")
            XCTAssertEqual(action(status, refresh: false), .pauseForAuthorization)
        }
    }

    func testPayloadTooLargeHalves() {
        XCTAssertEqual(action(413, count: 100), .retrySmaller(limit: 50))
        XCTAssertEqual(action(413, count: 3), .retrySmaller(limit: 1))
        XCTAssertEqual(action(413, count: 2), .retrySmaller(limit: 1))
        XCTAssertEqual(action(413, count: 1), .countAttempt, "a single record that is too large counts as rejected")
    }

    func testTransientFailuresBackOff() {
        for status in [0, 408, 429, 500, 502, 503, 599, 302, 101] { XCTAssertEqual(action(status), .backoff, "\(status)") }
    }

    func testOtherClientErrorsCountAttempts() {
        for status in [400, 404, 409, 410, 422, 499] { XCTAssertEqual(action(status), .countAttempt, "\(status)") }
    }

    func testBackoffDoublesCapsAndJitters() {
        XCTAssertEqual(UploadPolicy.backoffSec(failures: 0, random: { 0.5 }), 10)
        XCTAssertEqual(UploadPolicy.backoffSec(failures: 1, random: { 0.5 }), 20)
        XCTAssertEqual(UploadPolicy.backoffSec(failures: 6, random: { 0.5 }), 640)
        XCTAssertEqual(UploadPolicy.backoffSec(failures: 7, random: { 0.5 }), 900)
        XCTAssertEqual(UploadPolicy.backoffSec(failures: 1000, random: { 0.5 }), 900)
        XCTAssertEqual(UploadPolicy.backoffSec(failures: 0, random: { 0 }), 8, accuracy: 1e-9)
        XCTAssertEqual(UploadPolicy.backoffSec(failures: 0, random: { 1 }), 12, accuracy: 1e-9)
        XCTAssertEqual(UploadPolicy.backoffSec(failures: 7, random: { 0 }), 720, accuracy: 1e-9)
        XCTAssertEqual(UploadPolicy.backoffSec(failures: 7, random: { 5 }), 1080, accuracy: 1e-9, "random clamped to 0...1")
    }

    func testRetryAfter() {
        let now: EpochMs = 1_793_016_000_000 // 2026-10-26T12:00:00Z
        XCTAssertEqual(UploadPolicy.retryAfterSec("120", now: now), 120)
        XCTAssertEqual(UploadPolicy.retryAfterSec(" 5 ", now: now), 5)
        XCTAssertEqual(UploadPolicy.retryAfterSec("-3", now: now), 0)
        XCTAssertEqual(UploadPolicy.retryAfterSec("99999999", now: now), 86_400)
        XCTAssertEqual(UploadPolicy.retryAfterSec("Mon, 26 Oct 2026 12:01:30 GMT", now: now), 90)
        XCTAssertEqual(UploadPolicy.retryAfterSec("Mon, 26 Oct 2026 11:00:00 GMT", now: now), 0)
        XCTAssertNil(UploadPolicy.retryAfterSec("soon", now: now))
        XCTAssertNil(UploadPolicy.retryAfterSec("", now: now))
        XCTAssertNil(UploadPolicy.retryAfterSec(nil, now: now))
    }

    func testResponseTextIsCappedAtTwoKilobytes() {
        XCTAssertEqual(UploadPolicy.responseText(Data(repeating: 0x61, count: 5000)).count, 2048)
        XCTAssertEqual(UploadPolicy.responseText(Data("ok".utf8)), "ok")
        XCTAssertEqual(UploadPolicy.responseText(nil), "")
        // A multi-byte character split at the cut still yields text.
        let text = String(repeating: "a", count: 2047) + "é"
        XCTAssertFalse(UploadPolicy.responseText(Data(text.utf8)).isEmpty)
    }
}

final class UploadSchedulerTests: XCTestCase {
    func testRecordInsertedRespectsUploadInterval() {
        var s = UploadScheduler()
        XCTAssertTrue(s.shouldUpload(.recordInserted, now: 0, uploadIntervalSec: 60))
        s.attemptStarted(now: 1000)
        XCTAssertFalse(s.shouldUpload(.recordInserted, now: 60_999, uploadIntervalSec: 60))
        XCTAssertTrue(s.shouldUpload(.recordInserted, now: 61_000, uploadIntervalSec: 60))
        XCTAssertTrue(s.shouldUpload(.recordInserted, now: 1001, uploadIntervalSec: 0), "0 = as soon as recorded")
        XCTAssertEqual(s.nextDueAt(uploadIntervalSec: 60), 61_000)
    }

    func testBackoffBlocksAllButSyncAndSuccessResets() {
        var s = UploadScheduler()
        s.attemptStarted(now: 0)
        XCTAssertEqual(s.failedTransiently(now: 0, status: 503, retryAfterSec: nil, random: { 0.5 }), 10)
        XCTAssertFalse(s.shouldUpload(.recordInserted, now: 9_999, uploadIntervalSec: 0))
        XCTAssertFalse(s.shouldUpload(.watchdog, now: 9_999, uploadIntervalSec: 0))
        XCTAssertFalse(s.shouldUpload(.connectivity, now: 9_999, uploadIntervalSec: 0))
        XCTAssertTrue(s.shouldUpload(.sync, now: 1, uploadIntervalSec: 0))
        XCTAssertTrue(s.shouldUpload(.watchdog, now: 10_000, uploadIntervalSec: 0))

        XCTAssertEqual(s.failedTransiently(now: 10_000, status: 500, retryAfterSec: nil, random: { 0.5 }), 20, "exponential")
        XCTAssertEqual(s.consecutiveFailures, 2)
        s.succeeded()
        XCTAssertEqual(s.consecutiveFailures, 0)
        XCTAssertEqual(s.backoffUntil, 0)
    }

    func testRetryAfterWinsOverBackoff() {
        var s = UploadScheduler()
        XCTAssertEqual(s.failedTransiently(now: 0, status: 429, retryAfterSec: 300, random: { 0.5 }), 300)
        XCTAssertEqual(s.backoffUntil, 300_000)
    }

    func testConnectivityClearsOnlyNetworkBackoff() {
        var network = UploadScheduler()
        network.failedTransiently(now: 0, status: 0, retryAfterSec: nil, random: { 0.5 })
        network.connectivityRestored()
        XCTAssertTrue(network.shouldUpload(.connectivity, now: 1, uploadIntervalSec: 0))

        var server = UploadScheduler()
        server.failedTransiently(now: 0, status: 503, retryAfterSec: nil, random: { 0.5 })
        server.connectivityRestored()
        XCTAssertFalse(server.shouldUpload(.connectivity, now: 1, uploadIntervalSec: 0))
    }

    func testConnectivityIgnoresUploadInterval() {
        var s = UploadScheduler()
        s.attemptStarted(now: 0)
        XCTAssertTrue(s.shouldUpload(.connectivity, now: 1, uploadIntervalSec: 600))
    }

    func testAuthPauseLastsFifteenMinutesOrUntilNewCredentials() {
        var s = UploadScheduler()
        s.pauseForAuthorization(now: 0)
        XCTAssertFalse(s.shouldUpload(.recordInserted, now: 899_999, uploadIntervalSec: 0))
        XCTAssertFalse(s.shouldUpload(.watchdog, now: 899_999, uploadIntervalSec: 0))
        XCTAssertFalse(s.shouldUpload(.connectivity, now: 899_999, uploadIntervalSec: 0))
        XCTAssertTrue(s.shouldUpload(.watchdog, now: 900_000, uploadIntervalSec: 0))
        XCTAssertTrue(s.shouldUpload(.sync, now: 1, uploadIntervalSec: 0))
        XCTAssertEqual(s.nextDueAt(uploadIntervalSec: 0), 900_000)
        s.authorizationChanged()
        XCTAssertTrue(s.shouldUpload(.authorization, now: 1, uploadIntervalSec: 0))
        XCTAssertTrue(s.shouldUpload(.recordInserted, now: 1, uploadIntervalSec: 0))
    }
}

final class AuthTests: XCTestCase {
    func testCredentialsParseAndValidate() throws {
        let creds = try AuthCredentials(json: ["accessToken": "a", "refreshToken": "r", "refreshUrl": "https://x.example/refresh",
                                               "refreshPayload": ["grant": "{{refreshToken}}"], "refreshHeaders": ["X": "1"]])
        XCTAssertEqual(creds, AuthCredentials(accessToken: "a", refreshToken: "r", refreshUrl: "https://x.example/refresh",
                                              refreshPayload: ["grant": "{{refreshToken}}"], refreshHeaders: ["X": "1"]))
        XCTAssertTrue(creds.canRefresh)
        XCTAssertEqual(try AuthCredentials(json: creds.json), creds)
        XCTAssertFalse(try AuthCredentials(json: ["accessToken": "a"]).canRefresh)

        XCTAssertThrowsError(try AuthCredentials(json: [:])) { XCTAssertEqual(($0 as? ConfigError)?.key, "accessToken") }
        XCTAssertThrowsError(try AuthCredentials(json: ["accessToken": ""])) { XCTAssertEqual(($0 as? ConfigError)?.key, "accessToken") }
        XCTAssertThrowsError(try AuthCredentials(json: ["accessToken": "a", "refreshUrl": "nope"])) {
            XCTAssertEqual(($0 as? ConfigError)?.key, "refreshUrl")
        }
        XCTAssertThrowsError(try AuthCredentials(json: ["accessToken": "a", "refreshHeaders": ["X": 1]])) {
            XCTAssertEqual(($0 as? ConfigError)?.key, "refreshHeaders.X")
        }
    }

    func testRefreshBody() {
        XCTAssertEqual(AuthRefresh.body(for: AuthCredentials(accessToken: "a", refreshToken: "r1")), ["refresh_token": "r1"])
        let custom = AuthCredentials(accessToken: "a", refreshToken: "r1",
                                     refreshPayload: ["grant_type": "refresh_token", "token": "Bearer {{refreshToken}}"])
        XCTAssertEqual(AuthRefresh.body(for: custom), ["grant_type": "refresh_token", "token": "Bearer r1"])
    }

    func testRefreshResponseParsing() {
        XCTAssertEqual(AuthRefresh.tokens(from: Data("{\"access_token\":\"n\",\"refresh_token\":\"m\"}".utf8))?.accessToken, "n")
        XCTAssertEqual(AuthRefresh.tokens(from: Data("{\"accessToken\":\"n\",\"refreshToken\":\"m\"}".utf8))?.refreshToken, "m")
        XCTAssertNil(AuthRefresh.tokens(from: Data("{\"accessToken\":\"n\"}".utf8))?.refreshToken)
        XCTAssertNil(AuthRefresh.tokens(from: Data("{\"token\":\"n\"}".utf8)))
        XCTAssertNil(AuthRefresh.tokens(from: Data("<html>".utf8)))

        let old = AuthCredentials(accessToken: "a", refreshToken: "r")
        XCTAssertEqual(AuthRefresh.updated(old, accessToken: "b", refreshToken: nil).refreshToken, "r")
        XCTAssertEqual(AuthRefresh.updated(old, accessToken: "b", refreshToken: "s"), AuthCredentials(accessToken: "b", refreshToken: "s"))
    }

    func testBearerWinsOverConfiguredAuthorization() {
        let headers = UploadHeaders.make(configured: ["authorization": "Basic x", "X-App": "1"], accessToken: "tok")
        XCTAssertEqual(headers.filter { $0.0.lowercased() == "authorization" }.map(\.1), ["Bearer tok"])
        XCTAssertTrue(headers.contains { $0 == ("X-App", "1") })
        XCTAssertTrue(headers.contains { $0 == ("Content-Type", "application/json") })
        XCTAssertTrue(headers.contains { $0 == ("Accept", "application/json") })

        let noToken = UploadHeaders.make(configured: ["Authorization": "Basic x"], accessToken: nil)
        XCTAssertTrue(noToken.contains { $0 == ("Authorization", "Basic x") })

        let override = UploadHeaders.make(configured: ["content-type": "application/vnd.api+json"], accessToken: nil)
        XCTAssertEqual(override.filter { $0.0.lowercased() == "content-type" }.map(\.1), ["application/vnd.api+json"])
    }
}

final class RemoteCommandTests: XCTestCase {
    func testParsesConfigAndStop() {
        let data = Data("{\"ok\":true,\"long_ping\":{\"config\":{\"movingIntervalSec\":10},\"stop\":true}}".utf8)
        XCTAssertEqual(RemoteCommand.parse(data), RemoteCommand(config: ["movingIntervalSec": 10], stop: true))
        XCTAssertEqual(RemoteCommand.parse(Data("{\"long_ping\":{\"stop\":true}}".utf8)), RemoteCommand(config: nil, stop: true))
    }

    func testIgnoresAnythingElse() {
        XCTAssertNil(RemoteCommand.parse(Data("{\"long_ping\":{\"config\":5,\"stop\":\"yes\"}}".utf8)))
        XCTAssertNil(RemoteCommand.parse(Data("{\"long_ping\":true}".utf8)))
        XCTAssertNil(RemoteCommand.parse(Data("{\"ok\":true}".utf8)))
        XCTAssertNil(RemoteCommand.parse(Data("not json".utf8)))
        XCTAssertNil(RemoteCommand.parse(Data()))
        XCTAssertNil(RemoteCommand.parse(nil))
    }
}
