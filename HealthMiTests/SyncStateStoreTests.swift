import SwiftData
import XCTest
#if canImport(HealthMiCore)
@testable import HealthMiCore
#else
@testable import HealthMi
#endif

@MainActor
final class SyncStateStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    private func prepare() throws {
        let schema = Schema([SyncState.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = container.mainContext
    }

    func testRecordUpdatesState() throws {
        try prepare()
        let type: SyncDataType = .heartRate
        let highWater = Date()
        try SyncStateStore.record(type: type, highWater: highWater, added: 42, in: context)

        let state = SyncStateStore.state(for: type, in: context)
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.lastSyncedEnd?.timeIntervalSince(highWater) ?? -1, 0, accuracy: 1)
        XCTAssertEqual(state?.lastAddedCount, 42)
    }

    func testClearAllRemovesAllStates() throws {
        try prepare()
        try SyncStateStore.record(type: .heartRate, highWater: Date(), added: 10, in: context)
        try SyncStateStore.record(type: .sleep, highWater: Date(), added: 5, in: context)
        try SyncStateStore.record(type: .spo2, highWater: Date(), added: 3, in: context)

        SyncStateStore.clearAll(in: context)

        for type in SyncDataType.allCases {
            XCTAssertNil(SyncStateStore.state(for: type, in: context))
        }
    }

    func testRecordTwiceUpdatesSameRow() throws {
        try prepare()
        let type: SyncDataType = .heartRate
        try SyncStateStore.record(type: type, highWater: Date(timeIntervalSinceNow: -3600), added: 10, in: context)
        try SyncStateStore.record(type: type, highWater: Date(), added: 20, in: context)

        let state = SyncStateStore.state(for: type, in: context)
        XCTAssertEqual(state?.lastAddedCount, 20)
    }
}
