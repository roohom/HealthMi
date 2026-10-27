import Foundation
import HealthKit

struct SyncOutcome: Sendable {
    let type: SyncDataType
    let fetched: Int
    let added: Int
    let highWater: Date
    var updated: Int = 0
}

/// Incremental sync and backfill share reconciliation; only the read window differs.
actor SyncEngine {
    private let client: MiAPIClient
    private let writer: HealthWriter
    private var userId: String?
    private var sleepCache: (startTime: Int, endTime: Int, items: [MiItem])?

    init(client: MiAPIClient = MiAPIClient(), writer: HealthWriter = HealthWriter()) {
        self.client = client
        self.writer = writer
    }

    func clearCache() { sleepCache = nil }

    private func fetchSleepData(startTime: Int, endTime: Int) async throws -> [MiItem] {
        if let cache = sleepCache, cache.startTime == startTime, cache.endTime == endTime { return cache.items }
        let items = try await client.fetchData(key: "sleep", startTime: startTime, endTime: endTime)
        sleepCache = (startTime, endTime, items)
        return items
    }

    func connect(userId: String, passToken: String) async throws {
        try await client.connect(userId: userId, passToken: passToken)
        self.userId = userId
    }

    func sync(type: SyncDataType, highWater: Date?, backfillDays: Int,
              forceBackfill: Bool = false, now: Date = Date()) async throws -> SyncOutcome {
        guard let userId else { throw MiAPIError.notConnected }
        let window = SyncWindow(now: now, highWater: highWater, days: backfillDays,
                                forceBackfill: forceBackfill, timeZone: MiAPIClient.regionTimeZone)
        try await writer.resume(account: userId, dataType: type.rawValue)
        let samples = try await fetchAndMap(type: type, startTime: window.startTime, endTime: window.endTime)
        try Task.checkCancellation()
        let result = try await writer.reconcile(samples, account: userId, dataType: type.rawValue, window: window)
        return SyncOutcome(type: type, fetched: samples.count, added: result.added,
                           highWater: window.cutoff, updated: result.updated)
    }

    func syncStress(highWater: Date?, backfillDays: Int, forceBackfill: Bool = false,
                    now: Date = Date()) async throws -> (samples: [MiStressSample], outcome: SyncOutcome, window: SyncWindow) {
        let window = SyncWindow(now: now, highWater: highWater, days: backfillDays,
                                forceBackfill: forceBackfill, timeZone: MiAPIClient.regionTimeZone)
        let items = try await client.fetchData(key: "stress", startTime: window.startTime, endTime: window.endTime)
        try Task.checkCancellation()
        let samples = MiParser.stressSamples(items)
        return (samples, SyncOutcome(type: .stress, fetched: samples.count, added: 0, highWater: window.cutoff), window)
    }

    func syncWindow(highWater: Date?, backfillDays: Int, forceBackfill: Bool,
                    now: Date = Date()) -> (start: Date, end: Date, startTime: Int, endTime: Int) {
        let window = SyncWindow(now: now, highWater: highWater, days: backfillDays,
                                forceBackfill: forceBackfill, timeZone: MiAPIClient.regionTimeZone)
        return (window.start, window.cutoff, window.startTime, window.endTime)
    }

    private func fetchAndMap(type: SyncDataType, startTime: Int, endTime: Int) async throws -> [HealthSyncSample] {
        let samples: [HKSample]
        switch type {
        case .dailyActivity:
            let steps = try await client.fetchData(key: "steps", startTime: startTime, endTime: endTime)
            let calories = try await client.fetchData(key: "calories", startTime: startTime, endTime: endTime)
            samples = MiParser.dailyActivity(stepsItems: steps, calorieItems: calories).flatMap(TypeMapper.dailyActivitySamples)
        case .heartRate:
            let hr = try await client.fetchData(key: "heart_rate", startTime: startTime, endTime: endTime)
            let resting = try await client.fetchData(key: "resting_heart_rate", startTime: startTime, endTime: endTime)
            samples = MiParser.heartRateSamples(hr, restingItems: resting).compactMap(TypeMapper.heartRateSample)
        case .sleep:
            let items = try await fetchSleepData(startTime: startTime, endTime: endTime)
            samples = try MiParser.sleepSessions(items).flatMap(TypeMapper.sleepSamples)
        case .spo2:
            let items = try await client.fetchData(key: "spo2", startTime: startTime, endTime: endTime)
            samples = MiParser.spo2Samples(items).compactMap(TypeMapper.spo2Sample)
        case .respiratoryRate:
            let items = try await fetchSleepData(startTime: startTime, endTime: endTime)
            samples = try MiParser.respiratoryRateSamples(items).compactMap(TypeMapper.respiratoryRateSample)
        case .hrv:
            let items = try await fetchSleepData(startTime: startTime, endTime: endTime)
            samples = try MiParser.hrvSamples(items).compactMap(TypeMapper.hrvSample)
        case .bodyMeasurements:
            let items = try await client.fetchData(key: "weight", startTime: startTime, endTime: endTime)
            samples = MiParser.bodyMeasurements(items).flatMap(TypeMapper.bodyMeasurementSamples)
        case .workouts:
            let items = try await client.fetchSportRecords(startTime: startTime, endTime: endTime)
            return MiParser.workouts(items).compactMap(TypeMapper.workoutDraft).flatMap(TypeMapper.workoutSyncSamples)
        case .stress: return []
        }
        return try samples.map(HealthWriter.payload)
    }
}
