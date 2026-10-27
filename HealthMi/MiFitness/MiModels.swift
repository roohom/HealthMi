import Foundation

// MARK: - 解析中间类型（actor 边界内安全传递）

/// 小米云端返回的原始条目（已抽取出通用字段，`value` 保留为 JSON 数据）。
/// 对应 Python 端 item：`{time, zone_offset, zone_name, sid, key, category, value}`。
struct MiItem: Sendable, Hashable {
    var time: Int?
    var zoneOffset: Int?
    var zoneName: String?
    var sid: String?
    var key: String?
    var category: String?
    /// `value` 字段的 JSON 数据（字典已序列化，字符串按原样编码）。
    var valueData: Data?
}

/// 一页数据 + 分页游标。
struct MiDataPage: Sendable {
    let items: [MiItem]
    let hasMore: Bool
    let nextKey: String?
}

// MARK: - 业务模型（均与已确认的 pydantic 字段对应）

struct MiDailyActivity: Sendable, Identifiable, Hashable {
    let date: String // YYYY-MM-DD
    let steps: Int
    let distanceM: Double
    let activeKcal: Double
    let timezone: String
    var hasSteps = true
    var hasDistance = true
    var hasActiveCalories = true
    var id: String { "mi_fitness_activity_\(date)" }
}

struct MiSleepSegment: Sendable, Identifiable, Hashable {
    enum Stage: String, Sendable {
        case deep, light, rem, awake
    }
    let startAt: Date
    let endAt: Date
    let stage: Stage
    var id: String { "\(startAt.timeIntervalSince1970)_\(endAt.timeIntervalSince1970)" }
    var minutes: Int { max(0, Int((endAt.timeIntervalSince(startAt) / 60).rounded())) }
}

struct MiSleepSession: Sendable, Identifiable, Hashable {
    let sleepId: String
    let startAt: Date
    let endAt: Date
    let durationMinutes: Int
    let timeAsleepMinutes: Int
    let timeAwakeMinutes: Int
    let sleepScore: Int?
    let isNap: Bool
    /// 原始分期段（带精确起止时间），供 HealthKit 精细写入。
    let segments: [MiSleepSegment]
    var sourceID: String? = nil
    var legacySleepIDs: [String] = []
    var id: String { "mi_fitness_sleep_\(sleepId)" }

    /// 各分期累计分钟数（与 Python `stages` 聚合一致）。
    var stageSummary: [MiSleepSegment.Stage: Int] {
        Dictionary(grouping: segments, by: \.stage).mapValues { segs in
            segs.reduce(0) { $0 + $1.minutes }
        }
    }
}

struct MiHeartRateSample: Sendable, Identifiable, Hashable {
    enum SampleType: String, Sendable {
        case resting, active, passive, workout
    }
    let timestamp: Date
    let bpm: Int
    let sampleType: SampleType
    var id: String { "mi_fitness_hr_\(Int(timestamp.timeIntervalSince1970))_\(sampleType.rawValue)" }
}

struct MiSpO2Sample: Sendable, Identifiable, Hashable {
    let timestamp: Date
    let spo2Pct: Int
    var id: String { "mi_fitness_spo2_\(Int(timestamp.timeIntervalSince1970))" }
}

struct MiStressSample: Sendable, Identifiable, Hashable {
    let timestamp: Date
    let stressScore: Int
    var id: String { "mi_fitness_stress_\(Int(timestamp.timeIntervalSince1970))" }
}

/// 睡眠平均呼吸频率（来自睡眠记录的 `avg_breath` 字段）。
struct MiRespiratoryRateSample: Sendable, Identifiable, Hashable {
    let sleepId: String
    let startAt: Date
    let endAt: Date
    let breathsPerMinute: Int
    var sourceID: String? = nil
    var legacySleepIDs: [String] = []
    var id: String { "mi_fitness_respiratory_\(sleepId)" }
}

/// 睡眠心率变异性（来自睡眠记录的 `avg_hrv` / `hrv_median`，单位毫秒）。
struct MiHRVSample: Sendable, Identifiable, Hashable {
    let sleepId: String
    let startAt: Date
    let endAt: Date
    let sdnnMs: Int
    var sourceID: String? = nil
    var legacySleepIDs: [String] = []
    var id: String { "mi_fitness_hrv_\(sleepId)" }
}

struct MiBodyMeasurement: Sendable, Identifiable, Hashable {
    let timestamp: Date
    let weightKg: Double
    let bmi: Double?
    let bodyFatPct: Double?
    let muscleMassKg: Double?
    let waterPct: Double?
    let boneMassKg: Double?
    let visceralFatScore: Int?
    let basalMetabolismKcal: Int?
    let metabolicAge: Int?
    var id: String { "mi_fitness_weight_\(Int(timestamp.timeIntervalSince1970))" }
}

struct MiWorkout: Sendable, Identifiable, Hashable {
    let workoutId: String
    let activityType: String
    let startAt: Date
    let endAt: Date
    let durationMinutes: Int
    let distanceM: Double?
    let caloriesKcal: Double?
    let avgHeartRateBpm: Int?
    let maxHeartRateBpm: Int?
    let totalSteps: Int?
    var legacyWorkoutIDs: [String] = []
    var legacyPrefix: String? = nil
    var id: String { "mi_fitness_workout_\(workoutId)" }
}

// MARK: - JSON 安全取值工具（对应 Python 端宽容解析）

enum MiJSON {
    static func object(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func array(from data: Data) -> [[String: Any]]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(Double(s) ?? 0) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String { return s == "true" || s == "1" }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }
}
