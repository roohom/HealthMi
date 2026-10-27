import XCTest
@testable import HealthMi

/// Explicit opt-in, physical-device diagnostic. Reads Xiaomi sleep data only;
/// never instantiates a writer, logs credentials, or emits raw health records.
@MainActor
final class CloudContractTests: XCTestCase {
    func testReadOnlySleepContract() async throws {
        guard ProcessInfo.processInfo.environment["HEALTHMI_READONLY_CLOUD_CHECK"] == "1" else {
            throw XCTSkip("Use the HealthMiCloudCheck scheme for the opt-in cloud check.")
        }
        guard let credential = CredentialStore.load() else { throw XCTSkip("Sign in on this device first.") }
        let client = MiAPIClient()
        try await client.connect(userId: credential.userId, passToken: credential.passToken)
        let window = SyncWindow(now: Date(), highWater: nil, days: 7, forceBackfill: false,
                                timeZone: MiAPIClient.regionTimeZone)
        let items = try await client.fetchData(key: "sleep", startTime: window.startTime, endTime: window.endTime)
        var fields = Set<String>()
        var clocks = ["equalsBedtime": 0, "equalsWakeTime": 0, "other": 0]
        for item in items {
            guard let data = item.valueData, let payload = MiJSON.object(from: data) else { continue }
            fields.formUnion(payload.keys)
            if item.time == MiJSON.int(payload["bedtime"]) { clocks["equalsBedtime", default: 0] += 1 }
            else if item.time == MiJSON.int(payload["wake_up_time"]) { clocks["equalsWakeTime", default: 0] += 1 }
            else { clocks["other", default: 0] += 1 }
        }
        print("READONLY_SLEEP_CONTRACT records=\(items.count) fields=\(fields.sorted()) clockRelations=\(clocks)")
        XCTAssertNoThrow(try MiParser.sleepSessions(items), "Cloud sleep candidates require explicit contract handling.")
    }
}
