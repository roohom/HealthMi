import Foundation
import SwiftData
import os

/// 压力记录（来自小米云端 stress key，无 HealthKit 对应类型，存 SwiftData 供 App 内展示）。
@Model
final class StressRecord {
    @Attribute(.unique) var externalID: String
    var timestamp: Date
    var stressScore: Int

    init(externalID: String, timestamp: Date, stressScore: Int) {
        self.externalID = externalID
        self.timestamp = timestamp
        self.stressScore = stressScore
    }
}

/// 压力数据存取（MainActor，SwiftData 上下文非 Sendable）。
@MainActor
enum StressStore {
    /// Update a selected window and its cursor in one isolated save. No autosave
    /// may persist a range deletion before the replacement has been validated.
    static func apply(samples: [MiStressSample], window: SyncWindow, highWater: Date,
                      replace: Bool, container: ModelContainer) throws -> Int {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            try Task.checkCancellation()
            let start = window.start
            let end = window.end
            let descriptor = FetchDescriptor<StressRecord>(
                predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end }
            )
            let existing = try context.fetch(descriptor)
            var byID = Dictionary(existing.map { ($0.externalID, $0) }, uniquingKeysWith: { first, _ in first })
            let incomingIDs = Set(samples.filter { $0.timestamp >= start && $0.timestamp < end }.map(\.id))
            if replace {
                for record in existing where !incomingIDs.contains(record.externalID) { context.delete(record) }
            }
            var added = 0
            for sample in samples where sample.timestamp >= start && sample.timestamp < end {
                if let record = byID[sample.id] { record.stressScore = sample.stressScore }
                else {
                    let record = StressRecord(externalID: sample.id, timestamp: sample.timestamp, stressScore: sample.stressScore)
                    context.insert(record)
                    byID[sample.id] = record
                    added += 1
                }
            }
            let state = try SyncStateStore.ensureState(for: .stress, in: context)
            state.lastSyncedEnd = highWater
            state.lastSyncAt = Date()
            state.lastAddedCount = added
            try Task.checkCancellation()
            try context.save()
            return added
        } catch {
            context.rollback()
            throw error
        }
    }

    /// 批量写入压力记录，按 externalID 去重，返回新增条数。
    @discardableResult
    static func save(samples: [MiStressSample], in context: ModelContext) -> Int {
        guard !samples.isEmpty else { return 0 }
        let ids = Set(samples.map(\.id))
        let existing = fetchExistingIDs(ids: ids, in: context)
        var added = 0
        for sample in samples where !existing.contains(sample.id) {
            context.insert(StressRecord(
                externalID: sample.id,
                timestamp: sample.timestamp,
                stressScore: sample.stressScore
            ))
            added += 1
        }
        if added > 0 {
            do {
                try context.save()
            } catch {
                AppLog.stressStore.error("保存压力记录失败：\(error.localizedDescription)")
            }
        }
        return added
    }

    /// 删除指定时间范围内的压力记录（重新回填时先清理）。
    static func deleteRange(start: Date, end: Date, in context: ModelContext) {
        let descriptor = FetchDescriptor<StressRecord>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp <= end }
        )
        if let records = try? context.fetch(descriptor) {
            for record in records {
                context.delete(record)
            }
            try? context.save()
        }
    }

    /// 清除所有压力记录（退出登录时调用）。
    static func clearAll(in context: ModelContext) {
        let descriptor = FetchDescriptor<StressRecord>()
        if let records = try? context.fetch(descriptor) {
            for record in records {
                context.delete(record)
            }
            try? context.save()
        }
    }

    /// 查询最近 N 天的压力记录（按时间排序）。
    static func recent(days: Int, in context: ModelContext) -> [StressRecord] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<StressRecord>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchExistingIDs(ids: Set<String>, in context: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<StressRecord>(
            predicate: #Predicate { ids.contains($0.externalID) }
        )
        let records = (try? context.fetch(descriptor)) ?? []
        return Set(records.map(\.externalID))
    }
}
