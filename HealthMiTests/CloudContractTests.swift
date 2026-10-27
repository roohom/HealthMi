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
        XCTAssertTrue(HealthSyncSafety.writesPaused, "Cloud diagnostics must pause all health writes.")
        XCTAssertTrue(HealthSyncSafety.writesArePaused(environment: [:], defaults: .standard),
                      "The write pause must survive after the diagnostic process exits.")
        let credential = try XCTUnwrap(CredentialStore.load(), "Sign in on this device before the cloud check.")
        let client = MiAPIClient()
        do {
            try await client.connect(userId: credential.userId, passToken: credential.passToken)
        } catch {
            XCTFail("READONLY_CLOUD_AUTH_FAILED \(Self.safeError(error))")
            return
        }
        let window = SyncWindow(now: Date(), highWater: nil, days: 7, forceBackfill: false,
                                timeZone: MiAPIClient.regionTimeZone)
        let items: [MiItem]
        do {
            items = try await client.fetchData(key: "sleep", startTime: window.startTime, endTime: window.endTime)
        } catch {
            XCTFail("READONLY_CLOUD_FETCH_FAILED \(Self.safeError(error))")
            return
        }
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
        Self.describeCandidateGroups(items)
        XCTAssertFalse(items.isEmpty, "No sleep records returned; the real sleep contract has not been verified.")
        XCTAssertNoThrow(try MiParser.sleepSessions(items), "Cloud sleep candidates require explicit contract handling.")
    }

    /// Compare candidates on-device; emit field names and equality relations, never values or identities.
    private static func describeCandidateGroups(_ items: [MiItem]) {
        var groups: [String: [[String: Any]]] = [:]
        var missingIdentity = 0
        for item in items {
            guard let data = item.valueData, let payload = MiJSON.object(from: data),
                  let bedtime = MiJSON.int(payload["bedtime"])
                    ?? MiJSON.int(payload["device_bedtime"]) ?? MiJSON.int(payload["bed_timestamp"]) else {
                missingIdentity += 1
                continue
            }
            groups["\(item.sid ?? "unknown")_\(bedtime)", default: []].append(payload)
        }
        let multiple = groups.values.filter { $0.count > 1 }
        var differingFields = Set<String>()
        var versionRelations = ["absent": 0, "equal": 0, "different": 0, "mixed": 0]
        var endRelations = ["equal": 0, "different": 0]
        for group in multiple {
            let keys = Set(group.flatMap { $0.keys })
            for key in keys where Set(group.map { signature($0[key]) }).count > 1 {
                differingFields.insert(key)
            }
            let versions = group.compactMap { $0["version"] }
            let relation = versions.isEmpty ? "absent" : versions.count != group.count ? "mixed"
                : Set(versions.map { signature($0) }).count == 1 ? "equal" : "different"
            versionRelations[relation, default: 0] += 1
            let ends = Set(group.map { signature($0["wake_up_time"] ?? $0["device_wake_up_time"] ?? $0["out_bed_timestamp"]) })
            endRelations[ends.count == 1 ? "equal" : "different", default: 0] += 1
        }
        print("READONLY_SLEEP_CANDIDATES groups=\(groups.count) multiCandidateGroups=\(multiple.count) missingIdentity=\(missingIdentity) differingFields=\(differingFields.sorted()) versionRelations=\(versionRelations) endRelations=\(endRelations)")
    }

    private static func signature(_ value: Any?) -> Data {
        guard let value else { return Data("missing".utf8) }
        return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]))
            ?? Data("unencodable".utf8)
    }

    /// XCTest must not dump server messages or URLSession redirect URLs containing login material.
    private static func safeError(_ error: Error) -> String {
        if let login = error as? MiLoginError {
            switch login {
            case .loginRejected(let code, _): return "loginRejected code=\(code ?? -1)"
            case .badPayload: return "invalidLoginPayload"
            case .network(let underlying): return "network code=\((underlying as NSError).code)"
            }
        }
        if let api = error as? MiAPIError {
            switch api {
            case .api(let code, _): return "api code=\(code)"
            case .http(let code): return "http code=\(code)"
            case .network(let underlying): return "network code=\((underlying as NSError).code)"
            case .notConnected: return "notConnected"
            case .paginationLimit: return "paginationLimit"
            case .cursorLoop: return "cursorLoop"
            case .invalidResponse: return "invalidResponse"
            }
        }
        return "errorType=\(String(describing: type(of: error))) code=\((error as NSError).code)"
    }
}
