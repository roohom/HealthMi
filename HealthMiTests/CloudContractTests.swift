import CoreFoundation
import XCTest
@testable import HealthMi

/// Explicit, read-only cloud diagnostics. Never creates a HealthKit writer or emits raw records.
@MainActor
final class CloudContractTests: XCTestCase {
    #if DEBUG
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
            XCTFail("READONLY_CLOUD_AUTH_FAILED \(DeviceCheckDiagnostics.safeError(error))")
            return
        }
        let window = SyncWindow(now: Date(), highWater: nil, days: 7, forceBackfill: false,
                                timeZone: MiAPIClient.regionTimeZone)
        let items: [MiItem]
        do {
            let (wire, mapped) = try await client.readOnlySleepWireSnapshot(startTime: window.startTime,
                                                                         endTime: window.endTime)
            items = mapped
            let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: wire) as? [[String: Any]])
            Self.inspectWireCandidates(raw).forEach { print($0) }
        } catch {
            XCTFail("READONLY_CLOUD_FETCH_FAILED \(DeviceCheckDiagnostics.safeError(error))")
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
        if let sessions = try? MiParser.sleepSessions(items) {
            let latest = sessions.max { $0.startAt < $1.startAt }
            let samples = latest.map(TypeMapper.sleepSamples) ?? []
            print("READONLY_SLEEP_RESOLUTION sessions=\(sessions.count) latestSessionStageSegments=\(latest?.segments.count ?? 0) latestSessionHealthSamples=\(samples.count) latestSessionLegacyIDs=\(latest?.legacySleepIDs.count ?? 0)")
        }
    }
    #endif

    func testWireInspectionKeepsRawBooleanTypesAndRedactsIdentity() throws {
        let start = 1_700_000_000
        func row(_ end: Int, incomplete: Any, updated: Int) throws -> [String: Any] {
            let payload: [String: Any] = ["bedtime": start, "wake_up_time": end,
                                          "is_uncomplete": incomplete, "items": []]
            return ["sid": "SYNTHETIC_PRIVATE_ID", "zone_name": "Asia/Shanghai", "zone_offset": 28800,
                    "update_time": updated, "deleted": false,
                    "value": String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)]
        }
        let report = Self.inspectWireCandidates(try [row(start + 60, incomplete: true, updated: 10),
                                                     row(start + 120, incomplete: 0, updated: 20)])
            .joined(separator: "\n")
        XCTAssertTrue(report.contains("is_uncomplete=boolean:true"))
        XCTAssertTrue(report.contains("is_uncomplete=number:false"))
        XCTAssertTrue(report.contains("update_timeRelation=different"))
        XCTAssertTrue(report.contains("deleted=boolean:false"))
        XCTAssertFalse(report.contains("SYNTHETIC_PRIVATE_ID"))
        XCTAssertFalse(report.contains(String(start)))
    }

    /// All raw values stay inside the phone test process; only this allowlisted summary is printed.
    private static func inspectWireCandidates(_ rows: [[String: Any]]) -> [String] {
        struct Candidate {
            let outer: [String: Any]
            let payload: [String: Any]
            let start: Int
            let end: Int
        }
        var groups: [String: [Candidate]] = [:]
        for raw in rows {
            let payload: [String: Any]?
            if let text = raw["value"] as? String { payload = MiJSON.object(from: Data(text.utf8)) }
            else { payload = raw["value"] as? [String: Any] }
            guard let payload,
                  let start = MiJSON.int(payload["bedtime"] ?? payload["device_bedtime"] ?? payload["bed_timestamp"]),
                  let end = MiJSON.int(payload["wake_up_time"] ?? payload["device_wake_up_time"] ?? payload["out_bed_timestamp"]),
                  end > start else { continue }
            groups["\(MiJSON.string(raw["sid"]) ?? "unknown")_\(start)", default: []]
                .append(Candidate(outer: raw, payload: payload, start: start, end: end))
        }
        // Sorting labels is for App comparison only; it never selects a winning candidate.
        let ordered = groups.values.sorted { $0[0].start > $1[0].start }
        var report: [String] = []
        var conflictIndex = 0
        for (position, group) in ordered.enumerated() where group.count > 1 {
            conflictIndex += 1
            let label = "G\(conflictIndex)"
            let candidates = group.sorted { $0.end < $1.end }
            let payloadKeys = Set(candidates.flatMap { $0.payload.keys })
            let differences = payloadKeys.filter { key in Set(candidates.map { signature($0.payload[key]) }).count > 1 }.sorted()
            let updates = candidates.compactMap { candidate -> Double? in
                guard rawType(candidate.outer["update_time"]) == "number",
                      let value = candidate.outer["update_time"] as? NSNumber,
                      value.doubleValue.isFinite else { return nil }
                return value.doubleValue
            }
            let orderedUpdates = Array(Set(updates)).sorted()
            func relation(_ key: String) -> String {
                let values = candidates.compactMap { $0.outer[key] }
                if values.isEmpty { return "allMissing" }
                if values.count != candidates.count { return "partlyMissing" }
                return Set(values.map { signature($0) }).count == 1 ? "equal" : "different"
            }
            report.append("READONLY_WIRE_GROUP \(label) sessionOrderNewestFirst=\(position + 1) candidates=\(candidates.count) differingFields=\(differences) update_timeRelation=\(relation("update_time")) deletedRelation=\(relation("deleted"))")
            for (index, candidate) in candidates.enumerated() {
                let raw = candidate.outer
                let p = candidate.payload
                let startDate = Date(timeIntervalSince1970: Double(candidate.start))
                let endDate = Date(timeIntervalSince1970: Double(candidate.end))
                let namedZone = (raw["zone_name"] as? String).flatMap(TimeZone.init(identifier:))
                let offset = (raw["zone_offset"] as? NSNumber)?.intValue
                let offsetZone = offset.flatMap { abs($0) <= 14 * 3600 ? TimeZone(secondsFromGMT: $0) : nil }
                let zone = namedZone ?? offsetZone
                let agrees = namedZone == nil || offset == nil || namedZone!.secondsFromGMT(for: startDate) == offset!
                var temporal = "unresolved"
                var localBands = "unresolved"
                if let zone, agrees {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = zone
                    let startHour = calendar.component(.hour, from: startDate)
                    let endHour = calendar.component(.hour, from: endDate)
                    let crosses = !calendar.isDate(startDate, inSameDayAs: endDate)
                    func band(_ hour: Int) -> String {
                        switch hour {
                        case 0..<6: return "nightBeforeDawn"
                        case 6..<12: return "morning"
                        case 12..<18: return "afternoon"
                        default: return "evening"
                        }
                    }
                    localBands = "\(band(startHour))->\(band(endHour))/\(crosses ? "crossesLocalDay" : "sameLocalDay")"
                    if crosses, startHour >= 18, endHour < 12 { temporal = "eveningToMorningAcrossLocalMidnight" }
                    else if crosses { temporal = "crossesLocalMidnight" }
                    else if startHour < 6 || endHour < 6 { temporal = "includesLocalNight" }
                    else { temporal = "sameLocalDayNotClassifiedAsNap" }
                }
                let zoneSource = namedZone != nil ? "zone_name" : offsetZone != nil ? "zone_offset" : "missing"
                let timezoneField = (p["timezone"] as? NSNumber)?.intValue
                let payloadZoneRelation = offset.flatMap { seconds in timezoneField.map { $0 * 15 * 60 == seconds ? "matchesQuarterHourOffset" : "doesNotMatchQuarterHourOffset" } } ?? "notComparable"
                let updateRank = updates.count == candidates.count ? String(orderedUpdates.firstIndex(of: updates[index])! + 1) : "notComparable"
                report.append("READONLY_WIRE_CANDIDATE \(label).C\(index + 1) timezoneSource=\(zoneSource) outerTimezoneAgreement=\(agrees) payloadTimezoneRelation=\(payloadZoneRelation) temporalPattern=\(temporal) localBands=\(localBands) is_nap=\(booleanObservation(p["is_nap"])) is_uncomplete=\(booleanObservation(p["is_uncomplete"])) update_time=\(rawType(raw["update_time"])) updateNumericRank=\(updateRank) deleted=\(booleanObservation(raw["deleted"]))")
            }
        }
        return report
    }

    private static func rawType(_ value: Any?) -> String {
        guard let value else { return "missing" }
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number"
        }
        if value is String { return "string" }
        if value is [Any] { return "array" }
        if value is [String: Any] { return "object" }
        return "unknown"
    }

    private static func booleanObservation(_ value: Any?) -> String {
        let type = rawType(value)
        guard let value else { return type }
        let bool: Bool?
        if let number = value as? NSNumber, number == 0 || number == 1 { bool = number.boolValue }
        else if let string = value as? String {
            switch string.lowercased() {
            case "true", "1": bool = true
            case "false", "0": bool = false
            default: bool = nil
            }
        } else { bool = nil }
        return type + ":" + (bool.map { String($0) } ?? "unresolved")
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
}

/// Shared error redaction for device checks; no server messages or credential-bearing URLs.
enum DeviceCheckDiagnostics {
    /// XCTest must not dump server messages or URLSession redirect URLs containing login material.
    static func safeError(_ error: Error) -> String {
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
