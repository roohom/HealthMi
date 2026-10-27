import Foundation
import SwiftData
import os

/// 可同步的数据类型。stress 无 HealthKit 对应类型，存 App 内 SwiftData 展示。
/// abnormal_heart_beat 暂不纳入。
enum SyncDataType: String, CaseIterable, Identifiable, Sendable {
    case dailyActivity = "daily_activity"
    case heartRate = "heart_rate"
    case sleep = "sleep"
    case spo2 = "spo2"
    case respiratoryRate = "respiratory_rate"
    case hrv = "hrv"
    case bodyMeasurements = "body_measurements"
    case workouts = "workouts"
    case stress = "stress"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dailyActivity: return "日常活动"
        case .heartRate: return "心率"
        case .sleep: return "睡眠"
        case .spo2: return "血氧"
        case .respiratoryRate: return "呼吸频率"
        case .hrv: return "心率变异性"
        case .bodyMeasurements: return "体重/体脂"
        case .workouts: return "运动记录"
        case .stress: return "压力"
        }
    }
}

/// 每类数据的同步游标（high-water mark）。
@Model
final class SyncState {
    @Attribute(.unique) var typeRawValue: String
    /// 已同步到的最晚时间，用于增量拉取。
    var lastSyncedEnd: Date?
    var lastSyncAt: Date?
    var lastAddedCount: Int

    init(typeRawValue: String, lastSyncedEnd: Date? = nil, lastSyncAt: Date? = nil, lastAddedCount: Int = 0) {
        self.typeRawValue = typeRawValue
        self.lastSyncedEnd = lastSyncedEnd
        self.lastSyncAt = lastSyncAt
        self.lastAddedCount = lastAddedCount
    }
}

/// SwiftData 存取同步游标（必须在 MainActor 上使用，SwiftData 上下文非 Sendable）。
@MainActor
enum SyncStateStore {

    static func state(for type: SyncDataType, in context: ModelContext) -> SyncState? {
        let raw = type.rawValue
        let descriptor = FetchDescriptor<SyncState>(
            predicate: #Predicate { $0.typeRawValue == raw }
        )
        return (try? context.fetch(descriptor))?.first
    }

    static func lastSyncedEnd(for type: SyncDataType, container: ModelContainer) throws -> Date? {
        let context = ModelContext(container)
        let raw = type.rawValue
        let descriptor = FetchDescriptor<SyncState>(predicate: #Predicate { $0.typeRawValue == raw })
        return try context.fetch(descriptor).first?.lastSyncedEnd
    }

    static func ensureState(for type: SyncDataType, in context: ModelContext) throws -> SyncState {
        let raw = type.rawValue
        let descriptor = FetchDescriptor<SyncState>(predicate: #Predicate { $0.typeRawValue == raw })
        if let existing = try context.fetch(descriptor).first { return existing }
        let created = SyncState(typeRawValue: type.rawValue)
        context.insert(created)
        return created
    }

    static func record(
        type: SyncDataType, highWater: Date?, added: Int, in context: ModelContext
    ) throws {
        let writeContext = ModelContext(context.container)
        writeContext.autosaveEnabled = false
        do {
            let state = try ensureState(for: type, in: writeContext)
            state.lastSyncedEnd = highWater
            state.lastSyncAt = Date()
            state.lastAddedCount = added
            try writeContext.save()
        } catch {
            writeContext.rollback()
            throw error
        }
    }

    /// 清除所有同步游标（退出登录或切换账号时调用，防止新账号继承旧进度）。
    static func clearAll(in context: ModelContext) {
        let descriptor = FetchDescriptor<SyncState>()
        do {
            let all = try context.fetch(descriptor)
            for state in all {
                context.delete(state)
            }
            try context.save()
        } catch {
            AppLog.syncStateStore.error("清除同步游标失败：\(error.localizedDescription)")
        }
    }
}
