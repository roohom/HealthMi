import XCTest
@testable import HealthMi

final class SyncEngineTests: XCTestCase {
    private let engine = SyncEngine()

    func testFirstSyncWindow() async {
        // 首次同步：无游标，按 backfillDays 回填
        let before = Date()
        let result = await engine.syncWindow(highWater: nil, backfillDays: 30, forceBackfill: false)
        let after = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MiAPIClient.regionTimeZone
        let today = calendar.startOfDay(for: result.end)
        let expectedStart = calendar.date(byAdding: .day, value: -29, to: today)!
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: today)!
        // end is the synchronization cutoff; endTime is the inclusive cloud query boundary.
        XCTAssertGreaterThanOrEqual(result.end, before)
        XCTAssertLessThanOrEqual(result.end, after)
        XCTAssertEqual(result.start, expectedStart)
        XCTAssertEqual(result.startTime, Int(expectedStart.timeIntervalSince1970))
        XCTAssertEqual(result.endTime + 1, Int(nextMidnight.timeIntervalSince1970))
    }

    func testIncrementalSyncWindow() async {
        // 增量同步：有游标，从游标往前 1 天（重叠）
        let highWater = Date(timeIntervalSinceNow: -86400) // 1 天前
        let result = await engine.syncWindow(highWater: highWater, backfillDays: 30, forceBackfill: false)
        // start 应该在 highWater 前 1 天（重叠）
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MiAPIClient.regionTimeZone
        let previousDay = calendar.date(byAdding: .day, value: -1, to: highWater)!
        let expected = calendar.startOfDay(for: previousDay)
        XCTAssertEqual(result.start.timeIntervalSince(expected), 0, accuracy: 60)
    }

    func testForceBackfillWindow() async {
        // 强制回填：忽略游标，按 backfillDays 重拉
        let highWater = Date(timeIntervalSinceNow: -86400 * 7)
        let now = Date()
        let result = await engine.syncWindow(highWater: highWater, backfillDays: 7, forceBackfill: true)
        let daysDiff = Calendar.current.dateComponents([.day], from: result.start, to: now).day ?? 0
        XCTAssertEqual(daysDiff, 7, accuracy: 1)
    }

    func testStartTimeBeforeEndTime() async {
        let result = await engine.syncWindow(highWater: nil, backfillDays: 30, forceBackfill: false)
        XCTAssertLessThan(result.start, result.end)
        XCTAssertLessThan(result.startTime, result.endTime)
    }
}
