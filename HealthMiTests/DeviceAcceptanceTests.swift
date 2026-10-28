import BackgroundTasks
import Foundation
import HealthKit
import SwiftData
import XCTest
@testable import HealthMi

#if DEBUG
/// Device checks with explicit opt-ins; no checked-in scheme enables real health writes.
/// The single-night harness stays bounded to the previously approved snapshot shape.
@MainActor
final class DeviceAcceptanceTests: XCTestCase {
    // MARK: - Read-only resume preflight

    func testReadOnlyResumeReadiness() async throws {
        guard ProcessInfo.processInfo.environment["HEALTHMI_READONLY_CLOUD_CHECK"] == "1" else {
            throw XCTSkip("Use the explicit read-only scheme for the resume preflight.")
        }
        var phase = "pause"
        do {
            guard HealthSyncSafety.writesPaused,
                  HealthSyncSafety.writesArePaused(environment: [:], defaults: .standard) else {
                throw ResumeReadinessError.invalidState
            }
            phase = "credentialsAndJournal"
            guard let credential = CredentialStore.load() else { throw ResumeReadinessError.invalidState }
            let journal = PendingSyncJournal.applicationDefault
            let paths = FileManager.default.fileExists(atPath: journal.directory.path)
                ? try FileManager.default.contentsOfDirectory(at: journal.directory, includingPropertiesForKeys: nil) : []
            let pending = paths.filter { $0.lastPathComponent != "legacy-owner.json" }
            guard pending.isEmpty else { throw ResumeReadinessError.pendingOperation }
            let owner = journal.directory.appendingPathComponent("legacy-owner.json")
            if FileManager.default.fileExists(atPath: owner.path) {
                guard try JSONDecoder().decode(String.self, from: Data(contentsOf: owner))
                        == HealthSyncCoordinator.accountNamespace(credential.userId) else {
                    throw ResumeReadinessError.invalidState
                }
            }
            phase = "syncProgress"
            let schema = Schema([SyncState.self, StressRecord.self, SyncLogEntry.self])
            let configuration = ModelConfiguration(schema: schema, allowsSave: false)
            let container = try ModelContainer(for: schema, migrationPlan: MigrationPlan.self,
                                               configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let states = try context.fetch(FetchDescriptor<SyncState>())
            let model = AppModel()
            model.bootstrap()
            guard model.isConfigured, model.healthKitAuthorized else { throw ResumeReadinessError.invalidState }
            for type in model.enabledTypes.sorted(by: { $0.rawValue < $1.rawValue }) {
                let state = states.first { $0.typeRawValue == type.rawValue }
                let highWater = state?.lastSyncedEnd
                if let highWater, highWater > Date().addingTimeInterval(60) { throw ResumeReadinessError.invalidState }
                let window = SyncWindow(now: Date(), highWater: highWater, days: model.backfillDays,
                                        forceBackfill: false, timeZone: MiAPIClient.regionTimeZone)
                let days = Int(window.end.timeIntervalSince(window.start) / 86400)
                print("RESUME_READINESS_TYPE type=\(type.rawValue) hasProgress=\(highWater != nil) normalWindowDays=\(days)")
            }
            let authorized = HealthKitManager.typesToShare.filter {
                HealthKitManager.healthStore.authorizationStatus(for: $0) == .sharingAuthorized
            }.count
            print("RESUME_READINESS_OK pendingPlans=0 ownerMatches=true enabledTypes=\(model.enabledTypes.count) authorizedHealthTypes=\(authorized) pausePreserved=true")
        } catch {
            XCTFail("RESUME_READINESS_FAILED phase=\(phase) \(Self.safeError(error))")
        }
    }

    // MARK: - In-memory write boundary regression

    func testLastSleepWriteFenceRejectsOutOfScopeMutations() async throws {
        let backend = LastSleepAcceptanceSpy()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(60)
        let sample = HealthSyncSample(key: "synthetic", type: "syntheticSleep", kind: .category,
                                      start: start, end: end, value: 1)
        let fenced = LastSleepAcceptanceStore(backend: backend, wanted: ["allowed": sample],
                                              deletable: [], start: start, end: end)
        var changed = sample
        changed.value = 2
        let entry = VersionedHealthSample(sample: changed, syncID: "allowed", version: 1,
                                         fingerprint: try changed.fingerprint(), needsWrite: true)
        do {
            try await fenced.save([entry])
            XCTFail("Changed content must not reach the underlying store")
        } catch LastSleepAcceptanceError.outsideApproval {}
        let row = StoredHealthSample(uuid: UUID(), type: sample.type, start: start, end: end,
                                     syncID: nil, version: 0, fingerprint: nil, externalID: nil, scope: nil)
        do {
            try await fenced.delete([row])
            XCTFail("An unapproved UUID must not reach the underlying store")
        } catch LastSleepAcceptanceError.outsideApproval {}
        do {
            _ = try await fenced.load(types: [sample.type], start: start.addingTimeInterval(-1), end: end)
            XCTFail("A wider window must not reach the underlying store")
        } catch LastSleepAcceptanceError.outsideApproval {}
        let calls = await backend.calls
        XCTAssertEqual(calls, 0)
    }

    // MARK: - Explicitly approved single-night writes

    func testApprovedLatestNightWriteAndIdempotency() async throws {
        guard ProcessInfo.processInfo.environment["HEALTHMI_LAST_SLEEP_WRITE_CHECK"] == "1" else {
            throw XCTSkip("Explicit approval and a local opt-in are required for real HealthKit writes.")
        }
        var phase = "preflight"
        do {
            guard HealthSyncSafety.writesPaused,
                  HealthSyncSafety.writesArePaused(environment: [:], defaults: .standard) else {
                throw LastSleepAcceptanceError.outsideApproval
            }
            let sleepType = HKCategoryType(.sleepAnalysis)
            guard HealthKitManager.healthStore.authorizationStatus(for: sleepType) == .sharingAuthorized,
                  let credential = CredentialStore.load() else {
                throw LastSleepAcceptanceError.authorizationRequired
            }
            phase = "cloudRead"
            let client = MiAPIClient()
            try await client.connect(userId: credential.userId, passToken: credential.passToken)
            let window = SyncWindow(now: Date(), highWater: nil, days: 7, forceBackfill: false,
                                    timeZone: MiAPIClient.regionTimeZone)
            let items = try await client.fetchData(key: "sleep", startTime: window.startTime, endTime: window.endTime)
            let sessions = try MiParser.sleepSessions(items)
            phase = "approvedSnapshotPreflight"
            guard let latest = sessions.max(by: { $0.startAt < $1.startAt }),
                  latest.segments.count == 31, latest.legacySleepIDs.count == 3,
                  latest.endAt <= Date(), Date().timeIntervalSince(latest.endAt) < 48 * 3600,
                  let complete = items.first(where: { item in
                      guard item.deletionState == .active, item.sid == latest.sourceID,
                            let data = item.valueData, let payload = MiJSON.object(from: data) else { return false }
                      return MiJSON.int(payload["bedtime"]) == Int(latest.startAt.timeIntervalSince1970)
                          && MiJSON.jsonBool(payload["is_uncomplete"]) == false
                  }), let offset = complete.zoneOffset, let zone = TimeZone(secondsFromGMT: offset) else {
                throw LastSleepAcceptanceError.approvedSnapshotChanged
            }
            phase = "nightWindowPreflight"
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let startHour = calendar.component(.hour, from: latest.startAt)
            let endHour = calendar.component(.hour, from: latest.endAt)
            let sameDay = calendar.isDate(latest.startAt, inSameDayAs: latest.endAt)
            let followingDay = calendar.date(byAdding: .day, value: 1, to: latest.startAt)!
            let crossesOneMidnight = calendar.isDate(followingDay, inSameDayAs: latest.endAt)
            guard (sameDay && startHour < 6 && (6..<12).contains(endHour))
                || (crossesOneMidnight && startHour >= 18 && (6..<12).contains(endHour)) else {
                throw LastSleepAcceptanceError.approvedSnapshotChanged
            }
            let payloads = try TypeMapper.sleepSamples(latest).map(HealthWriter.payload)
            guard payloads.count == 32, let scope = payloads.first?.scope,
                  payloads.allSatisfy({ $0.type == sleepType.identifier && $0.scope == scope }) else {
                throw LastSleepAcceptanceError.outsideApproval
            }
            let account = credential.userId
            let namespace = HealthSyncCoordinator.accountNamespace(account)
            let prefix = "healthmi.v2/\(namespace)/"
            let journal = PendingSyncJournal.applicationDefault
            let pending = journal.directory.appendingPathComponent(HealthSyncSample.digest(Data("\(namespace)/sleep".utf8)) + ".json")
            guard !FileManager.default.fileExists(atPath: pending.path) else {
                throw LastSleepAcceptanceError.pendingOperation
            }
            let owner = journal.directory.appendingPathComponent("legacy-owner.json")
            if FileManager.default.fileExists(atPath: owner.path) {
                guard try JSONDecoder().decode(String.self, from: Data(contentsOf: owner)) == namespace else {
                    throw LastSleepAcceptanceError.outsideApproval
                }
            }
            phase = "healthReadPreflight"
            let backend = HealthKitSyncStore()
            let before = try await backend.load(types: [sleepType.identifier], start: window.start, end: window.end)
            let bases = Set(latest.legacySleepIDs.map { "mi_fitness_sleep_\($0)" })
            let legacyPrefix = try XCTUnwrap(payloads.first?.legacyScopePrefix)
            let discoveredBases = Set(before.compactMap { row -> String? in
                guard row.syncID == nil, row.start == latest.startAt, let id = row.externalID,
                      id.hasPrefix(legacyPrefix), id.hasSuffix("_inBed") else { return nil }
                return String(id.dropLast("_inBed".count))
            })
            guard discoveredBases.isSubset(of: bases) else { throw LastSleepAcceptanceError.outsideApproval }
            let target = before.filter { row in
                if let id = row.syncID { return id.hasPrefix(prefix) && row.scope == scope }
                guard let id = row.externalID else { return false }
                return bases.contains { id == $0 + "_inBed" || id.hasPrefix($0 + "_") }
            }
            guard target.allSatisfy({ $0.start >= latest.startAt && $0.end <= latest.endAt }) else {
                throw LastSleepAcceptanceError.outsideApproval
            }
            let targetUUIDs = Set(target.map(\.uuid))
            let protected = Dictionary(uniqueKeysWithValues: before.filter { !targetUUIDs.contains($0.uuid) }.map { ($0.uuid, $0) })
            let wanted = Dictionary(uniqueKeysWithValues: payloads.map { (HealthSyncCoordinator.identifier(account: account, sample: $0), $0) })
            guard before.allSatisfy({ row in
                guard let id = row.syncID, wanted[id] != nil else { return true }
                return targetUUIDs.contains(row.uuid)
            }) else { throw LastSleepAcceptanceError.outsideApproval }
            let fenced = LastSleepAcceptanceStore(backend: backend, wanted: wanted,
                                                  deletable: targetUUIDs, start: window.start, end: window.end)
            // Only this coordinator opts in. App-wide and background writes remain paused.
            let coordinator = HealthSyncCoordinator(store: fenced, journal: journal, allowWrites: true)
            print("LAST_SLEEP_WRITE_PREFLIGHT samples=\(payloads.count) matchingExisting=\(target.count) protectedExisting=\(protected.count)")
            phase = "firstWrite"
            let first = try await coordinator.synchronize(payloads, account: account, dataType: "sleep", window: window)
            let afterFirst = try await backend.load(types: [sleepType.identifier], start: window.start, end: window.end)
            let byUUID = Dictionary(uniqueKeysWithValues: afterFirst.map { ($0.uuid, $0) })
            guard protected.allSatisfy({ byUUID[$0.key] == $0.value }),
                  afterFirst.filter({ row in row.syncID.map { wanted[$0] != nil } ?? false }).count == 32,
                  !afterFirst.contains(where: { $0.syncID == nil && targetUUIDs.contains($0.uuid) }) else {
                throw LastSleepAcceptanceError.verification
            }
            phase = "repeatWrite"
            let second = try await coordinator.synchronize(payloads, account: account, dataType: "sleep", window: window)
            let afterSecond = try await backend.load(types: [sleepType.identifier], start: window.start, end: window.end)
            guard second.added == 0, second.updated == 0, second.removed == 0, second.skipped == 32,
                  Dictionary(uniqueKeysWithValues: afterSecond.map { ($0.uuid, $0) }) == byUUID,
                  HealthSyncSafety.writesArePaused(environment: [:], defaults: .standard),
                  !FileManager.default.fileExists(atPath: pending.path) else {
                throw LastSleepAcceptanceError.verification
            }
            print("LAST_SLEEP_WRITE_RESULT firstAdded=\(first.added) firstUpdated=\(first.updated) firstRemoved=\(first.removed) secondSkipped=\(second.skipped) protectedPreserved=\(protected.count) pausePreserved=true")
        } catch {
            XCTFail("LAST_SLEEP_WRITE_FAILED phase=\(phase) \(Self.safeError(error))")
        }
    }

    // MARK: - Explicitly approved normal sync restoration

    func testApprovedNormalSyncRestored() async throws {
        guard ProcessInfo.processInfo.environment["HEALTHMI_VERIFY_NORMAL_SYNC"] == "1" else {
            throw XCTSkip("Only run after explicit approval to resume normal synchronization.")
        }
        var phase = "mode"
        do {
            guard !HealthSyncSafety.writesPaused,
                  !HealthSyncSafety.writesArePaused(environment: [:], defaults: .standard) else {
                throw ResumeReadinessError.invalidState
            }
            let schema = Schema([SyncState.self, StressRecord.self, SyncLogEntry.self])
            let configuration = ModelConfiguration(schema: schema)
            let container = try ModelContainer(for: schema, migrationPlan: MigrationPlan.self,
                                               configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let model = AppModel()
            model.bootstrap()
            guard model.isConfigured, model.healthKitAuthorized else { throw ResumeReadinessError.invalidState }
            phase = "scope"
            for type in model.enabledTypes {
                guard let highWater = try SyncStateStore.lastSyncedEnd(for: type, container: container) else {
                    throw ResumeReadinessError.invalidState
                }
                let window = SyncWindow(now: Date(), highWater: highWater, days: model.backfillDays,
                                        forceBackfill: false, timeZone: MiAPIClient.regionTimeZone)
                guard window.end.timeIntervalSince(window.start) <= 3 * 86400 else {
                    throw ResumeReadinessError.invalidState
                }
            }
            phase = "normalIncrementalSync"
            await model.syncAll(modelContext: context)
            for (type, outcome) in model.outcomes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                print("NORMAL_SYNC_TYPE type=\(type.rawValue) fetched=\(outcome.fetched) added=\(outcome.added) updated=\(outcome.updated)")
            }
            guard model.lastError == nil, Set(model.outcomes.keys) == model.enabledTypes,
                  !model.isSyncing, !HealthSyncSafety.writesArePaused(environment: [:], defaults: .standard) else {
                throw ResumeReadinessError.invalidState
            }
            let directory = PendingSyncJournal.applicationDefault.directory
            let pending = FileManager.default.fileExists(atPath: directory.path)
                ? try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent != "legacy-owner.json" } : []
            guard pending.isEmpty else { throw ResumeReadinessError.pendingOperation }
            let requests = await withCheckedContinuation { continuation in
                BGTaskScheduler.shared.getPendingTaskRequests { requests in
                    continuation.resume(returning: requests.map(\.identifier))
                }
            }
            print("NORMAL_SYNC_RESTORED enabledTypes=\(model.enabledTypes.count) successfulTypes=\(model.outcomes.count) persistentPause=false pendingPlans=0 backgroundScheduled=\(requests.contains(BackgroundSync.taskIdentifier))")
        } catch {
            XCTFail("NORMAL_SYNC_VERIFY_FAILED phase=\(phase) \(Self.safeError(error))")
        }
    }

    private static func safeError(_ error: Error) -> String {
        if let acceptance = error as? LastSleepAcceptanceError {
            return "acceptance=\(acceptance)"
        }
        return DeviceCheckDiagnostics.safeError(error)
    }
}

private actor LastSleepAcceptanceSpy: HealthSyncStore {
    private(set) var calls = 0
    func load(types: Set<String>, start: Date, end: Date) async throws -> [StoredHealthSample] {
        calls += 1
        return []
    }
    func save(_ samples: [VersionedHealthSample]) async throws { calls += 1 }
    func delete(_ samples: [StoredHealthSample]) async throws { calls += 1 }
}

private enum LastSleepAcceptanceError: Error {
    case outsideApproval, approvedSnapshotChanged, authorizationRequired, pendingOperation, verification
}

private struct LastSleepAcceptanceStore: HealthSyncStore {
    let backend: any HealthSyncStore
    let wanted: [String: HealthSyncSample]
    let deletable: Set<UUID>
    let start: Date
    let end: Date

    func load(types: Set<String>, start: Date, end: Date) async throws -> [StoredHealthSample] {
        guard types == Set(wanted.values.map(\.type)), start == self.start, end == self.end else {
            throw LastSleepAcceptanceError.outsideApproval
        }
        return try await backend.load(types: types, start: start, end: end)
    }

    func save(_ entries: [VersionedHealthSample]) async throws {
        guard entries.count == wanted.count,
              Set(entries.map(\.syncID)) == Set(wanted.keys) else { throw LastSleepAcceptanceError.outsideApproval }
        for entry in entries {
            guard wanted[entry.syncID] == entry.sample,
                  try entry.sample.fingerprint() == entry.fingerprint else { throw LastSleepAcceptanceError.outsideApproval }
        }
        try await backend.save(entries)
    }

    func delete(_ rows: [StoredHealthSample]) async throws {
        guard Set(rows.map(\.uuid)).isSubset(of: deletable) else { throw LastSleepAcceptanceError.outsideApproval }
        try await backend.delete(rows)
    }
}

private enum ResumeReadinessError: Error { case invalidState, pendingOperation }
#endif
