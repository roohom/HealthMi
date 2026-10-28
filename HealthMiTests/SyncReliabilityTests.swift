import Foundation
import SwiftData
import XCTest
#if canImport(HealthMiCore)
@testable import HealthMiCore
#else
@testable import HealthMi
#endif

@MainActor
final class SyncReliabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_088_000)

    private func window(days: Int = 7) -> SyncWindow {
        SyncWindow(now: now, highWater: nil, days: days, forceBackfill: false,
                   timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    }

    private func journal() throws -> PendingSyncJournal {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return PendingSyncJournal(directory: directory)
    }

    private func steps(_ value: Double) -> HealthSyncSample {
        HealthSyncSample(key: "mi_fitness_steps_2026-10-27", type: "steps", kind: .quantity,
                         start: window().start, end: window().end, value: value, unit: "count")
    }

    func testCloudCheckPauseSurvivesRelaunchUntilExplicitlyResumed() throws {
        let suite = "HealthMiCloudCheckTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        HealthSyncSafety.prepareForLaunch(environment: ["HEALTHMI_READONLY_CLOUD_CHECK": "1"], defaults: defaults)
        HealthSyncSafety.prepareForLaunch(environment: [:], defaults: defaults)
        XCTAssertTrue(HealthSyncSafety.writesArePaused(environment: [:], defaults: defaults))
        HealthSyncSafety.prepareForLaunch(environment: ["HEALTHMI_RESUME_HEALTH_WRITES": "1"], defaults: defaults)
        XCTAssertFalse(HealthSyncSafety.writesArePaused(environment: [:], defaults: defaults))
        HealthSyncSafety.prepareForLaunch(environment: ["HEALTHMI_READONLY_CLOUD_CHECK": "1",
                                                        "HEALTHMI_RESUME_HEALTH_WRITES": "1"], defaults: defaults)
        XCTAssertTrue(HealthSyncSafety.writesArePaused(environment: [:], defaults: defaults))
    }

    func testReadOnlyCheckCannotWriteOrReplayPendingHealthPlan() async throws {
        let store = MemoryHealthStore()
        let journal = try journal()
        let normal = HealthSyncCoordinator(store: store, journal: journal, allowWrites: true)
        await store.setFault(.save)
        do {
            _ = try await normal.synchronize([steps(3000)], account: "A", dataType: "daily", window: window())
            XCTFail("Expected an unfinished write plan")
        } catch HealthSyncError.verificationFailed {}
        let paths = try FileManager.default.contentsOfDirectory(at: journal.directory, includingPropertiesForKeys: nil)
        let before = try paths.map { try Data(contentsOf: $0) }
        let diagnostic = HealthSyncCoordinator(store: store, journal: journal, allowWrites: false)
        do {
            try await diagnostic.resume(account: "A", dataType: "daily")
            XCTFail("Read-only diagnostics must not recover pending writes")
        } catch HealthSyncError.readOnlyCheck {}
        do {
            _ = try await diagnostic.synchronize([steps(8000)], account: "A", dataType: "daily", window: window())
            XCTFail("Read-only diagnostics must not create writes")
        } catch HealthSyncError.readOnlyCheck {}
        let stored = await store.snapshot()
        XCTAssertTrue(stored.isEmpty)
        XCTAssertEqual(try paths.map { try Data(contentsOf: $0) }, before)
    }

    func testSevenCalendarDaysAndHalfOpenBoundary() {
        let w = window()
        XCTAssertEqual(w.end.timeIntervalSince(w.start), 7 * 86400)
        XCTAssertEqual(w.endTime + 1, Int(w.end.timeIntervalSince1970))
        XCTAssertEqual(w.cutoff, now)
    }

    func testCalendarDaysAcrossDaylightSaving() {
        let cutoff = ISO8601DateFormatter().date(from: "2026-03-09T12:00:00-04:00")!
        let w = SyncWindow(now: cutoff, highWater: nil, days: 3, forceBackfill: false,
                           timeZone: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(w.end.timeIntervalSince(w.start), 71 * 3600)
    }

    func testIncrementalStartIsMidnightAndIncludesMorning() {
        let w = SyncWindow(now: now, highWater: now, days: 7, forceBackfill: false,
                           timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        XCTAssertEqual(calendar.component(.hour, from: w.start), 0)
        XCTAssertEqual(w.startTime, Int(w.start.timeIntervalSince1970))
    }

    func testIdenticalSyncIsIdempotentAndChangedTotalUpdates() async throws {
        let store = MemoryHealthStore()
        let sync = HealthSyncCoordinator(store: store, journal: try journal(), allowWrites: true)
        _ = try await sync.synchronize([steps(3000)], account: "account", dataType: "daily", window: window())
        let repeated = try await sync.synchronize([steps(3000), steps(3000)], account: "account", dataType: "daily", window: window())
        XCTAssertEqual(repeated.added, 0)
        XCTAssertEqual(repeated.skipped, 1)
        let changed = try await sync.synchronize([steps(8000)], account: "account", dataType: "daily", window: window())
        XCTAssertEqual(changed.updated, 1)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot[0].version, 2)
        let values = await store.values()
        XCTAssertEqual(values, [8000])
    }

    func testAccountNamespacesAreIndependent() async throws {
        let store = MemoryHealthStore()
        let sync = HealthSyncCoordinator(store: store, journal: try journal(), allowWrites: true)
        _ = try await sync.synchronize([steps(3000)], account: "A", dataType: "daily", window: window())
        _ = try await sync.synchronize([steps(8000)], account: "B", dataType: "daily", window: window())
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(Set(snapshot.compactMap(\.syncID)).count, 2)
    }

    func testWriteFailureKeepsOldDataAndResumesExactVersion() async throws {
        let store = MemoryHealthStore()
        let journal = try journal()
        let sync = HealthSyncCoordinator(store: store, journal: journal, allowWrites: true)
        _ = try await sync.synchronize([steps(3000)], account: "private-account", dataType: "daily", window: window())
        await store.setFault(.save)
        do {
            _ = try await sync.synchronize([steps(8000)], account: "private-account", dataType: "daily", window: window())
            XCTFail("Expected save failure")
        } catch {}
        let before = await store.values()
        XCTAssertEqual(before, [3000])
        let restarted = HealthSyncCoordinator(store: store, journal: journal, allowWrites: true)
        try await restarted.resume(account: "private-account", dataType: "daily")
        let after = await store.values()
        let snapshot = await store.snapshot()
        XCTAssertEqual(after, [8000])
        XCTAssertEqual(snapshot[0].version, 2)
    }

    func testLegacySleepCleanupResumesAfterCrashWithoutDeletingAnotherNight() async throws {
        let start = window().start.addingTimeInterval(3600)
        func old(_ key: String, _ start: Date) -> StoredHealthSample {
            StoredHealthSample(uuid: UUID(), type: "sleep", start: start, end: start.addingTimeInterval(600),
                               syncID: nil, version: 0, fingerprint: nil, externalID: key, scope: nil)
        }
        let legacy = old("mi_fitness_sleep_device_999_inBed", start)
        let stage = old("mi_fitness_sleep_device_999_deep_111", start.addingTimeInterval(60))
        let other = old("mi_fitness_sleep_device_998_inBed", start.addingTimeInterval(86400))
        let store = MemoryHealthStore(seed: [legacy, stage, other])
        let journal = try journal()
        let sample = HealthSyncSample(key: "mi_fitness_sleep_device_111_inBed", type: "sleep", kind: .category,
                                     start: start, end: start.addingTimeInterval(600), value: 0,
                                     scope: "night", replacesScope: true, legacyScopePrefix: "mi_fitness_sleep_device_")
        let sync = HealthSyncCoordinator(store: store, journal: journal, allowWrites: true)
        await store.setFault(.delete)
        do {
            _ = try await sync.synchronize([sample], account: "A", dataType: "sleep", window: window())
            XCTFail("Expected cleanup failure")
        } catch {}
        let interrupted = await store.snapshot()
        XCTAssertEqual(interrupted.count, 4)
        let restarted = HealthSyncCoordinator(store: store, journal: journal, allowWrites: true)
        _ = try await restarted.synchronize([sample], account: "A", dataType: "sleep", window: window())
        let restored = await store.snapshot()
        XCTAssertEqual(restored.count, 2)
        XCTAssertTrue(restored.contains { $0.uuid == other.uuid })
        XCTAssertEqual(restored.first { $0.syncID != nil }?.version, 1)
    }

    func testReadbackFailurePreventsLegacyDeletion() async throws {
        let candidate = steps(8000)
        let old = StoredHealthSample(uuid: UUID(), type: candidate.type, start: candidate.start, end: candidate.end,
                                     syncID: nil, version: 0, fingerprint: nil, externalID: candidate.key, scope: nil)
        let store = MemoryHealthStore(seed: [old])
        let sync = HealthSyncCoordinator(store: store, journal: try journal(), allowWrites: true)
        await store.setFault(.silentSave)
        do {
            _ = try await sync.synchronize([candidate], account: "A", dataType: "daily", window: window())
            XCTFail("Expected readback failure")
        } catch {}
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.map(\.uuid), [old.uuid])
    }

    func testChangedSleepStageAndRemovedSegmentUseSameSession() async throws {
        let start = window().start.addingTimeInterval(3600)
        let first = HealthSyncSample(key: "night_segment_1", type: "sleep", kind: .category,
                                    start: start, end: start.addingTimeInterval(600), value: 3, scope: "night")
        var removed = first
        removed.key = "night_segment_2"
        removed.start = removed.end
        removed.end = removed.end.addingTimeInterval(600)
        var nap = first
        nap.key = "nap_segment_1"
        nap.scope = "nap"
        let store = MemoryHealthStore()
        let sync = HealthSyncCoordinator(store: store, journal: try journal(), allowWrites: true)
        _ = try await sync.synchronize([first, removed, nap], account: "A", dataType: "sleep", window: window())
        var corrected = first
        corrected.value = 4
        corrected.replacesScope = true
        let outcome = try await sync.synchronize([corrected], account: "A", dataType: "sleep", window: window())
        XCTAssertEqual(outcome.updated, 1)
        XCTAssertEqual(outcome.removed, 1)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertTrue(snapshot.contains { $0.scope == "nap" })
    }

    func testEmptyCloudResultDoesNotDeleteHealthHistory() async throws {
        let store = MemoryHealthStore()
        let sync = HealthSyncCoordinator(store: store, journal: try journal(), allowWrites: true)
        _ = try await sync.synchronize([steps(3000)], account: "A", dataType: "daily", window: window())
        _ = try await sync.synchronize([], account: "A", dataType: "daily", window: window())
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, 1)
    }

    func testConflictingBatchStopsBeforeWriting() async throws {
        let store = MemoryHealthStore()
        let sync = HealthSyncCoordinator(store: store, journal: try journal(), allowWrites: true)
        do {
            _ = try await sync.synchronize([steps(3000), steps(8000)], account: "A", dataType: "daily", window: window())
            XCTFail("Expected conflicting content")
        } catch {}
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }

    func testSleepDuplicatesCollapseButAmbiguousRevisionsAreRejected() throws {
        let bedtime = Int(now.timeIntervalSince1970) - 86400
        func item(_ duration: Int, stamp: Int) throws -> MiItem {
            let payload: [String: Any] = ["bedtime": bedtime, "wake_up_time": bedtime + duration * 60,
                                        "items": [["start_time": bedtime, "end_time": bedtime + duration * 60, "state": 2]]]
            return MiItem(time: stamp, zoneOffset: 28800, zoneName: "Asia/Shanghai", sid: "device", key: "sleep",
                          category: nil, valueData: try JSONSerialization.data(withJSONObject: payload))
        }
        let a = try item(480, stamp: bedtime + 100)
        let b = try item(480, stamp: bedtime + 200)
        XCTAssertEqual(try MiParser.sleepSessions([a, b]).count, 1)
        XCTAssertEqual(try MiParser.sleepSessions([a, b])[0].sleepId, "device_\(bedtime)")
        XCTAssertThrowsError(try MiParser.sleepSessions([a, item(240, stamp: bedtime + 300)]))
    }

    private func sleepCandidate(start: Int, minutes: Int, incomplete: Any? = nil,
                                stage: Int = 2, hrv: Int = 40, sid: String? = "device") throws -> MiItem {
        let end = start + minutes * 60
        var payload: [String: Any] = ["bedtime": start, "wake_up_time": end, "version": 4,
                                     "avg_hrv": hrv, "avg_breath": 16,
                                     "items": [["start_time": start, "end_time": end, "state": stage]]]
        if let incomplete { payload["is_uncomplete"] = incomplete }
        return MiItem(time: end, zoneOffset: 28800, zoneName: "Asia/Shanghai", sid: sid, key: "sleep",
                      category: nil, valueData: try JSONSerialization.data(withJSONObject: payload))
    }

    func testVerifiedSleepCompletionResolvesEightRowsWithoutDroppingIndependentNap() throws {
        let start = Int(now.timeIntervalSince1970) - 5 * 86400
        let partial = try sleepCandidate(start: start, minutes: 240, incomplete: true)
        let later = try sleepCandidate(start: start, minutes: 360, incomplete: true)
        let complete = try sleepCandidate(start: start, minutes: 480, incomplete: false, stage: 3, hrv: 60)
        let otherPartial = try sleepCandidate(start: start + 86400, minutes: 300, incomplete: true)
        let otherComplete = try sleepCandidate(start: start + 86400, minutes: 420, incomplete: false)
        let night3 = try sleepCandidate(start: start + 2 * 86400, minutes: 450, incomplete: false)
        let night4 = try sleepCandidate(start: start + 3 * 86400, minutes: 470, incomplete: false)
        // Completion state is not a nap classifier: keep this independent, staged sleep.
        let nap = try sleepCandidate(start: start + 12 * 3600, minutes: 30, incomplete: true)
        let rows = [partial, later, complete, otherPartial, otherComplete, night3, night4, nap]
        let expected = try MiParser.sleepSessions([complete, otherComplete, night3, night4, nap])
        let sessions = try MiParser.sleepSessions(rows)
        XCTAssertEqual(sessions.map(\.sleepId), expected.map(\.sleepId))
        XCTAssertEqual(sessions.map(\.endAt), expected.map(\.endAt))
        XCTAssertEqual(sessions.map(\.segments), expected.map(\.segments))
        XCTAssertEqual(try MiParser.sleepSessions(Array(rows.reversed())), sessions)
        let selected = try XCTUnwrap(expected.first { $0.sleepId == "device_\(start)" })
        XCTAssertEqual(selected.segments.first?.stage, .light)
        let resolved = try XCTUnwrap(MiParser.sleepSessions(rows).first { $0.sleepId == selected.sleepId })
        XCTAssertEqual(resolved.legacySleepIDs.count, 3)
        XCTAssertEqual(try MiParser.hrvSamples(rows).first { $0.sleepId == selected.sleepId }?.sdnnMs, 60)
        XCTAssertEqual(try MiParser.respiratoryRateSamples(rows).count, 5)
    }

    func testRepeatedCompleteCandidateCanResolveAcrossPageOrder() throws {
        let start = Int(now.timeIntervalSince1970) - 86400
        let partial = try sleepCandidate(start: start, minutes: 240, incomplete: true)
        let complete = try sleepCandidate(start: start, minutes: 480, incomplete: false)
        XCTAssertEqual(try MiParser.sleepSessions([complete, partial, complete]),
                       try MiParser.sleepSessions([partial, complete]))
    }

    func testUncertainCompletionFlagsCannotResolveDifferentSleepContent() throws {
        let start = Int(now.timeIntervalSince1970) - 86400
        let complete = try sleepCandidate(start: start, minutes: 480, incomplete: false)
        let unknowns: [Any?] = [nil, NSNull(), "true", "false", 0, 1, "unknown"]
        for unknown in unknowns {
            let other = try sleepCandidate(start: start, minutes: 240, incomplete: unknown)
            XCTAssertThrowsError(try MiParser.sleepSessions([other, complete]))
        }
        let unfinished = try sleepCandidate(start: start, minutes: 240, incomplete: true)
        let laterUnfinished = try sleepCandidate(start: start, minutes: 360, incomplete: true)
        XCTAssertThrowsError(try MiParser.sleepSessions([unfinished, laterUnfinished]))
    }

    func testDivergentCompleteCandidatesRemainConflicting() throws {
        let start = Int(now.timeIntervalSince1970) - 86400
        let a = try sleepCandidate(start: start, minutes: 420, incomplete: false)
        let b = try sleepCandidate(start: start, minutes: 480, incomplete: false)
        XCTAssertThrowsError(try MiParser.sleepSessions([a, b]))
        XCTAssertThrowsError(try MiParser.sleepSessions([b, a]))
    }

    func testCompleteCandidateMustContainTheUnfinishedCandidate() throws {
        let start = Int(now.timeIntervalSince1970) - 86400
        let longerUnfinished = try sleepCandidate(start: start, minutes: 480, incomplete: true)
        let shorterComplete = try sleepCandidate(start: start, minutes: 420, incomplete: false)
        XCTAssertThrowsError(try MiParser.sleepSessions([longerUnfinished, shorterComplete]))
    }

    func testCompletionDoesNotInventOrBlurSleepIdentity() throws {
        let start = Int(now.timeIntervalSince1970) - 86400
        let a = try sleepCandidate(start: start, minutes: 420, incomplete: false)
        let nearby = try sleepCandidate(start: start + 60, minutes: 20, incomplete: true)
        let anotherSource = try sleepCandidate(start: start, minutes: 420, incomplete: false, sid: "other-device")
        XCTAssertEqual(try MiParser.sleepSessions([a, nearby, anotherSource]).count, 3)
        let missingSource = try sleepCandidate(start: start, minutes: 240, incomplete: true, sid: nil)
        let missingSourceComplete = try sleepCandidate(start: start, minutes: 480, incomplete: false, sid: nil)
        XCTAssertThrowsError(try MiParser.sleepSessions([missingSource, missingSourceComplete]))
        var differentCategory = try sleepCandidate(start: start, minutes: 240, incomplete: true)
        differentCategory.category = "other"
        XCTAssertThrowsError(try MiParser.sleepSessions([differentCategory, a]))
    }

    func testSleepDeletionMarkersNeverBecomeImportedSleepSamples() throws {
        let start = Int(now.timeIntervalSince1970) - 86400
        let active = try sleepCandidate(start: start, minutes: 420, incomplete: false)
        let tombstone = MiItem(time: start, sid: "device", key: "sleep", deletionState: .deleted)
        XCTAssertEqual(try MiParser.sleepSessions([tombstone, active]), try MiParser.sleepSessions([active]))
        XCTAssertTrue(try MiParser.sleepSessions([tombstone]).isEmpty)
        var invalid = active
        invalid.deletionState = .invalid
        XCTAssertThrowsError(try MiParser.sleepSessions([invalid]))
    }

    func testSleepWireStatusFlagsRequireActualJSONBooleans() throws {
        let data = Data("{\"t\":true,\"f\":false,\"one\":1,\"zero\":0,\"text\":\"false\",\"null\":null}".utf8)
        let payload = try XCTUnwrap(MiJSON.object(from: data))
        XCTAssertEqual(MiJSON.jsonBool(payload["t"]), true)
        XCTAssertEqual(MiJSON.jsonBool(payload["f"]), false)
        for key in ["one", "zero", "text", "null", "missing"] { XCTAssertNil(MiJSON.jsonBool(payload[key])) }
        XCTAssertEqual(MiJSON.deletionState(nil), .active)
        XCTAssertEqual(MiJSON.deletionState(payload["null"]), .active)
        XCTAssertEqual(MiJSON.deletionState(payload["f"]), .active)
        XCTAssertEqual(MiJSON.deletionState(payload["t"]), .deleted)
        XCTAssertEqual(MiJSON.deletionState(payload["text"]), .invalid)
    }

    func testStressBackfillPreservesOutOfRangeAndUpdatesCursor() throws {
        let schema = Schema([StressRecord.self, SyncState.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let oldTime = window().start.addingTimeInterval(-86400)
        let inside = window().start.addingTimeInterval(3600)
        let old = MiStressSample(timestamp: oldTime, stressScore: 10)
        let current = MiStressSample(timestamp: inside, stressScore: 20)
        context.insert(StressRecord(externalID: old.id, timestamp: oldTime, stressScore: 10))
        context.insert(StressRecord(externalID: current.id, timestamp: inside, stressScore: 20))
        try context.save()
        _ = try StressStore.apply(samples: [MiStressSample(timestamp: inside, stressScore: 30)], window: window(),
                                  highWater: now, replace: true, container: container)
        let read = ModelContext(container)
        let records = try read.fetch(FetchDescriptor<StressRecord>())
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first { $0.externalID == old.id }?.stressScore, 10)
        XCTAssertEqual(records.first { $0.externalID == current.id }?.stressScore, 30)
        XCTAssertEqual(try read.fetch(FetchDescriptor<SyncState>()).first?.lastSyncedEnd, now)
    }

    func testPartialBatchFailureReplaysWithoutExtraVersions() async throws {
        let store = MemoryHealthStore()
        let journal = try journal()
        let sync = HealthSyncCoordinator(store: store, journal: journal, allowWrites: true)
        var a = steps(3000)
        var b = steps(2000)
        b.key += "_b"
        _ = try await sync.synchronize([a, b], account: "A", dataType: "daily", window: window())
        a.value = 8000
        b.value = 5000
        await store.setFault(.partialSave)
        do {
            _ = try await sync.synchronize([a, b], account: "A", dataType: "daily", window: window())
            XCTFail("Expected interrupted batch")
        } catch {}
        let interrupted = await store.snapshot()
        XCTAssertEqual(interrupted.count, 2)
        let restarted = HealthSyncCoordinator(store: store, journal: journal, allowWrites: true)
        try await restarted.resume(account: "A", dataType: "daily")
        let values = await store.values()
        let restored = await store.snapshot()
        XCTAssertEqual(values, [5000, 8000])
        XCTAssertTrue(restored.allSatisfy { $0.version == 2 })
    }

    func testConcurrentSyncCannotPlanTwoWrites() async throws {
        let store = MemoryHealthStore()
        let sync = HealthSyncCoordinator(store: store, journal: try journal(), allowWrites: true)
        await store.pauseNextLoad()
        let task = Task { try await sync.synchronize([steps(3000)], account: "A", dataType: "daily", window: window()) }
        await store.waitUntilPaused()
        do {
            _ = try await sync.synchronize([steps(8000)], account: "A", dataType: "daily", window: window())
            XCTFail("Expected busy")
        } catch HealthSyncError.busy {} catch { XCTFail("Unexpected \(error)") }
        await store.releaseLoad()
        _ = try await task.value
        let values = await store.values()
        XCTAssertEqual(values, [3000])
    }

    func testCancellationBeforeWritingKeepsHealthStoreUnchanged() async throws {
        let store = MemoryHealthStore()
        let sync = HealthSyncCoordinator(store: store, journal: try journal(), allowWrites: true)
        await store.pauseNextLoad()
        let task = Task { try await sync.synchronize([steps(3000)], account: "A", dataType: "daily", window: window()) }
        await store.waitUntilPaused()
        task.cancel()
        await store.releaseLoad()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }

    func testUnknownSleepStageIsNotInventedAsLightSleep() throws {
        let start = Int(now.timeIntervalSince1970) - 3600
        let payload: [String: Any] = ["bedtime": start, "wake_up_time": start + 600,
                                    "items": [["start_time": start, "end_time": start + 600, "state": 99]]]
        let item = MiItem(time: start, zoneOffset: 0, zoneName: nil, sid: "device", key: "sleep", category: nil,
                          valueData: try JSONSerialization.data(withJSONObject: payload))
        XCTAssertThrowsError(try MiParser.sleepSessions([item]))
    }

    func testIncompleteSleepSnapshotCannotEraseExistingStages() throws {
        let start = Int(now.timeIntervalSince1970) - 3600
        let payload: [String: Any] = ["bedtime": start, "wake_up_time": start + 600]
        let item = MiItem(time: start, zoneOffset: 0, zoneName: nil, sid: "device", key: "sleep", category: nil,
                          valueData: try JSONSerialization.data(withJSONObject: payload))
        XCTAssertThrowsError(try MiParser.sleepSessions([item]))
    }

    func testMissingOptionalFieldsDoNotAuthorizeScopeDeletion() async throws {
        let store = MemoryHealthStore()
        let sync = HealthSyncCoordinator(store: store, journal: try journal(), allowWrites: true)
        var a = steps(100)
        var b = steps(200)
        a.scope = "workout"
        b.key += "_b"
        b.scope = "workout"
        _ = try await sync.synchronize([a, b], account: "A", dataType: "workouts", window: window())
        a.value = 150
        _ = try await sync.synchronize([a], account: "A", dataType: "workouts", window: window())
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, 2)
    }

    func testMissingStepFieldsDoNotBecomeZeroMeasurements() throws {
        let item = MiItem(time: Int(now.timeIntervalSince1970), zoneOffset: 28800, zoneName: "Asia/Shanghai",
                          sid: "device", key: "calories", category: nil,
                          valueData: try JSONSerialization.data(withJSONObject: ["calories": 123]))
        let activity = try XCTUnwrap(MiParser.dailyActivity(stepsItems: [], calorieItems: [item]).first)
        XCTAssertFalse(activity.hasSteps)
        XCTAssertFalse(activity.hasDistance)
        XCTAssertTrue(activity.hasActiveCalories)
    }

    func testRepeatedRawDailyItemsAreNotAddedTwice() throws {
        let item = MiItem(time: Int(now.timeIntervalSince1970), zoneOffset: 28800, zoneName: "Asia/Shanghai",
                          sid: "device", key: "steps", category: nil,
                          valueData: try JSONSerialization.data(withJSONObject: ["steps": 123]))
        let activity = try XCTUnwrap(MiParser.dailyActivity(stepsItems: [item, item], calorieItems: []).first)
        XCTAssertEqual(activity.steps, 123)
    }

    func testCursorReadSeesCommittedUpdatesDespiteAnOldUIObject() throws {
        let schema = Schema([SyncState.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        try SyncStateStore.record(type: .sleep, highWater: now.addingTimeInterval(-3600), added: 1, in: context)
        _ = SyncStateStore.state(for: .sleep, in: context)
        try SyncStateStore.record(type: .sleep, highWater: now, added: 1, in: context)
        XCTAssertEqual(try SyncStateStore.lastSyncedEnd(for: .sleep, container: container), now)
    }

    func testCorrectedZeroValueIsWritten() async throws {
        let store = MemoryHealthStore()
        let sync = HealthSyncCoordinator(store: store, journal: try journal(), allowWrites: true)
        _ = try await sync.synchronize([steps(3000)], account: "A", dataType: "daily", window: window())
        _ = try await sync.synchronize([steps(0)], account: "A", dataType: "daily", window: window())
        let values = await store.values()
        XCTAssertEqual(values, [0])
    }
}

private actor MemoryHealthStore: HealthSyncStore {
    enum Fault { case save, partialSave, silentSave, delete }
    private var stored: [UUID: StoredHealthSample]
    private var payloads: [String: Double] = [:]
    private var fault: Fault?
    private var pauseNext = false
    private var paused = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var barrier: CheckedContinuation<Void, Never>?

    init(seed: [StoredHealthSample] = []) { stored = Dictionary(uniqueKeysWithValues: seed.map { ($0.uuid, $0) }) }
    func setFault(_ value: Fault) { fault = value }
    func snapshot() -> [StoredHealthSample] { Array(stored.values) }
    func values() -> [Double] { payloads.values.sorted() }
    func pauseNextLoad() { pauseNext = true }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }
    func releaseLoad() { barrier?.resume(); barrier = nil; paused = false }

    func load(types: Set<String>, start: Date, end: Date) async throws -> [StoredHealthSample] {
        if pauseNext {
            pauseNext = false
            paused = true
            for waiter in loadWaiters { waiter.resume() }
            loadWaiters.removeAll()
            await withCheckedContinuation { barrier = $0 }
        }
        return stored.values.filter { types.contains($0.type) && $0.end >= start && $0.start < end }
    }

    func save(_ entries: [VersionedHealthSample]) async throws {
        if fault == .save { fault = nil; throw HealthSyncError.verificationFailed }
        if fault == .silentSave { fault = nil; return }
        let partial = fault == .partialSave
        if partial { fault = nil }
        for entry in entries where entry.needsWrite {
            if let existing = stored.values.first(where: { $0.syncID == entry.syncID }) {
                if existing.version >= entry.version { continue }
                stored.removeValue(forKey: existing.uuid)
            }
            let record = StoredHealthSample(uuid: UUID(), type: entry.sample.type,
                                            start: entry.sample.start, end: entry.sample.end,
                                            syncID: entry.syncID, version: entry.version,
                                            fingerprint: entry.fingerprint, externalID: entry.sample.key, scope: entry.sample.scope)
            stored[record.uuid] = record
            payloads[entry.syncID] = entry.sample.value
            if partial { throw HealthSyncError.verificationFailed }
        }
    }

    func delete(_ samples: [StoredHealthSample]) async throws {
        if fault == .delete { fault = nil; throw HealthSyncError.verificationFailed }
        for sample in samples { stored.removeValue(forKey: sample.uuid) }
    }
}
