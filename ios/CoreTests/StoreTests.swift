import XCTest
@testable import LongPingCore

final class RecordQueueTests: XCTestCase {
    private var queue: RecordQueue!
    private let now: EpochMs = 1_793_016_000_000

    override func setUpWithError() throws {
        queue = try RecordQueue(db: .inMemory())
    }

    func testInsertCountAndDuplicateUUIDs() throws {
        XCTAssertTrue(try queue.insert(uuid: "a", recordedAt: now, json: "{}"))
        XCTAssertFalse(try queue.insert(uuid: "a", recordedAt: now, json: "{}"), "uuid is unique")
        XCTAssertTrue(try queue.insert(uuid: "b", recordedAt: now, json: "{}"))
        XCTAssertEqual(try queue.count(), 2)
    }

    func testOldestFirstByRecordedTime() throws {
        try queue.insert(uuid: "late", recordedAt: now + 2, json: "{\"n\":3}")
        try queue.insert(uuid: "early", recordedAt: now, json: "{\"n\":1}")
        try queue.insert(uuid: "mid", recordedAt: now + 1, json: "{\"n\":2}")
        XCTAssertEqual(try queue.oldest(limit: 2).map(\.uuid), ["early", "mid"])
        let first = try XCTUnwrap(queue.oldest(limit: 1).first)
        XCTAssertEqual(first.json, "{\"n\":1}")
        XCTAssertEqual(first.recordedAt, now)
        XCTAssertEqual(first.attempts, 0)
    }

    func testDelete() throws {
        for i in 0..<5 { try queue.insert(uuid: "u\(i)", recordedAt: now + EpochMs(i), json: "{}") }
        let ids = try queue.oldest(limit: 3).map(\.id)
        XCTAssertEqual(try queue.delete(ids: ids), 3)
        XCTAssertEqual(try queue.oldest(limit: 10).map(\.uuid), ["u3", "u4"])
        XCTAssertEqual(try queue.delete(ids: []), 0)
    }

    func testFailedAttemptsDropAtThree() throws {
        try queue.insert(uuid: "a", recordedAt: now, json: "{}")
        try queue.insert(uuid: "b", recordedAt: now + 1, json: "{}")
        let a = try queue.oldest(limit: 1).map(\.id)
        let both = try queue.oldest(limit: 2).map(\.id)
        XCTAssertEqual(try queue.recordFailedAttempt(ids: a, maxAttempts: 3), [])
        XCTAssertEqual(try queue.recordFailedAttempt(ids: both, maxAttempts: 3), [])
        XCTAssertEqual(try queue.oldest(limit: 2).map(\.attempts), [2, 1])
        XCTAssertEqual(try queue.recordFailedAttempt(ids: both, maxAttempts: 3), ["a"])
        XCTAssertEqual(try queue.oldest(limit: 2).map(\.uuid), ["b"])
        XCTAssertEqual(try queue.oldest(limit: 1).first?.attempts, 2)
    }

    func testPruneByCountDeletesOldest() throws {
        for i in 0..<10 { try queue.insert(uuid: "u\(i)", recordedAt: now + EpochMs(i), json: "{}") }
        let result = try queue.prune(maxRecords: 4, maxDays: 7, now: now)
        XCTAssertEqual(result, RecordQueue.PruneResult(overLimit: 6, expired: 0))
        XCTAssertEqual(try queue.oldest(limit: 10).map(\.uuid), ["u6", "u7", "u8", "u9"])
    }

    func testPruneByAge() throws {
        try queue.insert(uuid: "old", recordedAt: now - 8 * .dayMs, json: "{}")
        try queue.insert(uuid: "edge", recordedAt: now - 7 * .dayMs, json: "{}")
        try queue.insert(uuid: "new", recordedAt: now, json: "{}")
        let result = try queue.prune(maxRecords: 100, maxDays: 7, now: now)
        XCTAssertEqual(result.expired, 1)
        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(try queue.oldest(limit: 10).map(\.uuid), ["edge", "new"])
    }

    func testLargeIdListsAreChunked() throws {
        for i in 0..<1200 { try queue.insert(uuid: "u\(i)", recordedAt: now + EpochMs(i), json: "{}") }
        let ids = try queue.oldest(limit: 1100).map(\.id)
        XCTAssertEqual(try queue.recordFailedAttempt(ids: ids, maxAttempts: 1).count, 1100)
        XCTAssertEqual(try queue.count(), 100)
    }

    func testClear() throws {
        try queue.insert(uuid: "a", recordedAt: now, json: "{}")
        XCTAssertEqual(try queue.clear(), 1)
        XCTAssertEqual(try queue.count(), 0)
    }

    func testNewestRecordedAt() throws {
        XCTAssertNil(try queue.newestRecordedAt())
        try queue.insert(uuid: "late", recordedAt: now + 5, json: "{}")
        try queue.insert(uuid: "early", recordedAt: now, json: "{}")
        XCTAssertEqual(try queue.newestRecordedAt(), now + 5)
        try queue.clear()
        XCTAssertNil(try queue.newestRecordedAt())
    }

    func testFileBackedDatabaseSurvivesReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("longping-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("longping.sqlite").path
        do {
            let q = try RecordQueue(db: SQLiteDatabase(path: path))
            try q.insert(uuid: "persisted", recordedAt: now, json: "{\"a\":1}")
        }
        let reopened = try RecordQueue(db: SQLiteDatabase(path: path))
        XCTAssertEqual(try reopened.oldest(limit: 1).first?.json, "{\"a\":1}")
        XCTAssertThrowsError(try SQLiteDatabase(path: dir.appendingPathComponent("missing/dir/x.sqlite").path))
    }
}

final class LogStoreTests: XCTestCase {
    private var log: LogStore!
    private let t0: EpochMs = 1_793_016_000_123

    override func setUpWithError() throws {
        log = try LogStore(db: .inMemory())
    }

    func testLineFormat() {
        XCTAssertEqual(LogEntry(time: t0, level: .info, tag: "upload", message: "HTTP 200").line,
                       "2026-10-26T12:00:00.123Z INFO  [upload] HTTP 200")
        XCTAssertEqual(LogEntry(time: t0, level: .error, tag: "x", message: "m").line, "2026-10-26T12:00:00.123Z ERROR [x] m")
        XCTAssertEqual(LogEntry(time: t0, level: .warn, tag: "x", message: "m").line, "2026-10-26T12:00:00.123Z WARN  [x] m")
        XCTAssertEqual(LogEntry(time: t0, level: .debug, tag: "x", message: "m").line, "2026-10-26T12:00:00.123Z DEBUG [x] m")
    }

    func testEntriesSinceLimitAndOrder() throws {
        for i in 0..<10 {
            try log.append(LogEntry(time: t0 + EpochMs(i), level: .info, tag: "t", message: "m\(i)"))
        }
        XCTAssertEqual(try log.entries(since: t0 + 5, limit: 100, ascending: true).map(\.message), ["m5", "m6", "m7", "m8", "m9"])
        XCTAssertEqual(try log.entries(since: t0, limit: 3, ascending: true).map(\.message), ["m7", "m8", "m9"],
                       "limit keeps the newest entries")
        XCTAssertEqual(try log.entries(since: t0, limit: 3, ascending: false).map(\.message), ["m9", "m8", "m7"])
        XCTAssertEqual(try log.entries(since: t0, limit: 1, ascending: true).first?.level, .info)
    }

    func testNewlinesAreFlattened() throws {
        try log.append(LogEntry(time: t0, level: .warn, tag: "t", message: "a\nb\r\nc"))
        XCTAssertEqual(try log.entries(since: 0, limit: 1, ascending: true).first?.message, "a b c")
    }

    func testPruneByAgeAndRowCeiling() throws {
        for i in 0..<10 {
            try log.append(LogEntry(time: t0 + EpochMs(i), level: .debug, tag: "t", message: "m\(i)"))
        }
        XCTAssertEqual(try log.prune(olderThan: t0 + 2, maxRows: 100), 2)
        XCTAssertEqual(try log.prune(olderThan: 0, maxRows: 5), 3)
        XCTAssertEqual(try log.entries(since: 0, limit: 100, ascending: true).map(\.message), ["m5", "m6", "m7", "m8", "m9"])
        try log.clear()
        XCTAssertEqual(try log.count(), 0)
    }

    func testQueueAndLogShareOneDatabase() throws {
        let db = try SQLiteDatabase.inMemory()
        let queue = try RecordQueue(db: db)
        let log = try LogStore(db: db)
        try queue.insert(uuid: "a", recordedAt: t0, json: "{}")
        try log.append(LogEntry(time: t0, level: .info, tag: "t", message: "m"))
        XCTAssertEqual(try queue.count(), 1)
        XCTAssertEqual(try log.count(), 1)
    }
}

final class PersistedEngineStateTests: XCTestCase {
    func testRoundTrip() throws {
        var state = PersistedEngineState()
        state.enabled = true
        state.isMoving = false
        state.anchor = Fix(latitude: 1, longitude: 2, accuracy: 3, speed: 4, heading: 5, altitude: nil, time: 6, isMock: true)
        state.parkedAt = Fix(latitude: 7, longitude: 8, accuracy: 9, altitude: 10, time: 11)
        state.lastRecordedTime = 12
        state.lastFixTime = 13
        state.lastLocation = ["uuid": "x", "timestamp": "2026-10-26T12:00:00.123Z"]
        state.authorizationRequired = true
        let decoded = PersistedEngineState(json: try JSONValue.parse(state.json.serialized()))
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.lastLocationAt, 1_793_016_000_123)
    }

    func testLenientDecoding() {
        let decoded = PersistedEngineState(json: ["enabled": "yes", "anchor": ["latitude": 1], "lastLocation": 5])
        XCTAssertEqual(decoded, PersistedEngineState())
        XCTAssertNil(decoded.lastLocationAt)
    }
}
