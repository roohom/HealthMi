import HealthKit
import Foundation

/// 小米模型 → HealthKit 对象映射与单位换算。
/// 关键换算：百分比一律转分数（血氧 98% → 0.98，体脂 20% → 0.20）。
enum TypeMapper {
    static var regionTimeZone: TimeZone { MiRegion.current.timeZone }
    static let kilogram = HKUnit.gramUnit(with: .kilo)

    // MARK: - 日常活动（整日区间）

    /// 步数 / 距离 / 活动卡路里 → 3 个整日样本。
    static func dailyActivitySamples(_ activity: MiDailyActivity) -> [HKQuantitySample] {
        guard let day = parseDate(activity.date),
              let start = calendarStartOfDay(day),
              let end = calendar.date(byAdding: .day, value: 1, to: start)
        else { return [] }

        var samples: [HKQuantitySample] = []
        if activity.hasSteps && activity.steps >= 0 {
            samples.append(quantity(
                .stepCount, unit: .count(), value: Double(activity.steps),
                start: start, end: end,
                uuid: "mi_fitness_steps_\(activity.date)"
            ))
        }
        if activity.hasDistance && activity.distanceM >= 0 {
            samples.append(quantity(
                .distanceWalkingRunning, unit: .meter(), value: activity.distanceM,
                start: start, end: end,
                uuid: "mi_fitness_distance_\(activity.date)"
            ))
        }
        if activity.hasActiveCalories && activity.activeKcal >= 0 {
            samples.append(quantity(
                .activeEnergyBurned, unit: .kilocalorie(), value: activity.activeKcal,
                start: start, end: end,
                uuid: "mi_fitness_active_energy_\(activity.date)"
            ))
        }
        return samples
    }

    // MARK: - 心率 / 血氧 / 体重

    /// 心率点样本（timestamp 起止相同）。
    static func heartRateSample(_ sample: MiHeartRateSample) -> HKQuantitySample? {
        guard sample.bpm > 0 else { return nil }
        let identifier: HKQuantityTypeIdentifier = sample.sampleType == .resting ? .restingHeartRate : .heartRate
        let uuid = sample.sampleType == .resting
            ? "mi_fitness_resting_hr_\(Int(sample.timestamp.timeIntervalSince1970))"
            : "mi_fitness_hr_\(Int(sample.timestamp.timeIntervalSince1970))"
        return quantity(
            identifier, unit: .count().unitDivided(by: .minute()),
            value: Double(sample.bpm),
            start: sample.timestamp, end: sample.timestamp,
            uuid: uuid
        )
    }

    /// 血氧点样本：百分比 → 分数（0–1）。
    static func spo2Sample(_ sample: MiSpO2Sample) -> HKQuantitySample? {
        guard sample.spo2Pct > 0 else { return nil }
        return quantity(
            .oxygenSaturation, unit: .percent(),
            value: Double(sample.spo2Pct) / 100.0,
            start: sample.timestamp, end: sample.timestamp,
            uuid: "mi_fitness_spo2_\(Int(sample.timestamp.timeIntervalSince1970))"
        )
    }

    /// 睡眠平均呼吸频率 → 覆盖整个睡眠时段的 respiratoryRate 样本（次/分）。
    static func respiratoryRateSample(_ sample: MiRespiratoryRateSample) -> HKQuantitySample? {
        guard sample.breathsPerMinute > 0 else { return nil }
        return quantity(
            .respiratoryRate, unit: .count().unitDivided(by: .minute()),
            value: Double(sample.breathsPerMinute),
            start: sample.startAt, end: sample.endAt,
            uuid: sample.id,
            scope: "sleep:\(sample.sleepId)",
            aliases: sample.legacySleepIDs.map { "mi_fitness_respiratory_\($0)" },
            legacyPrefix: "mi_fitness_respiratory_\(sample.sourceID ?? "unknown")_"
        )
    }

    /// 睡眠 HRV → 覆盖整个睡眠时段的 heartRateVariabilitySDNN 样本（毫秒）。
    static func hrvSample(_ sample: MiHRVSample) -> HKQuantitySample? {
        guard sample.sdnnMs > 0 else { return nil }
        return quantity(
            .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli),
            value: Double(sample.sdnnMs),
            start: sample.startAt, end: sample.endAt,
            uuid: sample.id,
            scope: "sleep:\(sample.sleepId)",
            aliases: sample.legacySleepIDs.map { "mi_fitness_hrv_\($0)" },
            legacyPrefix: "mi_fitness_hrv_\(sample.sourceID ?? "unknown")_"
        )
    }

    /// 体重（kg）、体脂（百分比 → 分数）、BMI、肌肉量、基础代谢。
    static func bodyMeasurementSamples(_ measurement: MiBodyMeasurement) -> [HKQuantitySample] {
        var samples: [HKQuantitySample] = []
        let ts = Int(measurement.timestamp.timeIntervalSince1970)
        if measurement.weightKg > 0 {
            samples.append(quantity(
                .bodyMass, unit: kilogram, value: measurement.weightKg,
                start: measurement.timestamp, end: measurement.timestamp,
                uuid: "mi_fitness_weight_\(ts)"
            ))
        }
        if let fat = measurement.bodyFatPct, fat > 0 {
            samples.append(quantity(
                .bodyFatPercentage, unit: .percent(), value: fat / 100.0,
                start: measurement.timestamp, end: measurement.timestamp,
                uuid: "mi_fitness_body_fat_\(ts)"
            ))
        }
        if let bmi = measurement.bmi, bmi > 0 {
            samples.append(quantity(
                .bodyMassIndex, unit: .count(), value: bmi,
                start: measurement.timestamp, end: measurement.timestamp,
                uuid: "mi_fitness_bmi_\(ts)"
            ))
        }
        if let muscle = measurement.muscleMassKg, muscle > 0 {
            samples.append(quantity(
                .leanBodyMass, unit: kilogram, value: muscle,
                start: measurement.timestamp, end: measurement.timestamp,
                uuid: "mi_fitness_lean_mass_\(ts)"
            ))
        }
        if let bmr = measurement.basalMetabolismKcal, bmr > 0 {
            samples.append(quantity(
                .basalEnergyBurned, unit: .kilocalorie(), value: Double(bmr),
                start: measurement.timestamp, end: measurement.timestamp,
                uuid: "mi_fitness_bmr_\(ts)"
            ))
        }
        return samples
    }

    // MARK: - 睡眠（分类样本）

    /// 一条睡眠会话 → inBed + 各分期样本。
    ///
    /// 注意：**不要**再写一个覆盖整晚的 `asleep` 聚合样本 —— 它会与所有分期段重叠，
    /// 导致 Health App 不渲染分期（只显示一个整体睡眠）。分期由各段样本的值
    /// （Awake / AsleepCore / AsleepDeep / AsleepREM）直接表达，Health 会自动聚合。
    static func sleepSamples(_ session: MiSleepSession) -> [HKCategorySample] {
        let base = session.startAt
        let end = session.endAt
        guard end > base else { return [] }

        var samples: [HKCategorySample] = []
        samples.append(category(
            .inBed, start: base, end: end,
            uuid: "mi_fitness_sleep_\(session.sleepId)_inBed",
            scope: "sleep:\(session.sleepId)",
            aliases: session.legacySleepIDs.map { "mi_fitness_sleep_\($0)_inBed" },
            legacyPrefix: "mi_fitness_sleep_\(session.sourceID ?? "unknown")_",
            completeScope: true
        ))
        for segment in session.segments where segment.minutes > 0 {
            samples.append(category(
                stageValue(segment.stage), start: segment.startAt, end: segment.endAt,
                uuid: "mi_fitness_sleep_\(session.sleepId)_segment_\(Int(segment.startAt.timeIntervalSince1970))",
                scope: "sleep:\(session.sleepId)",
                aliases: session.legacySleepIDs.map {
                    "mi_fitness_sleep_\($0)_\(segment.stage.rawValue)_\(Int(segment.startAt.timeIntervalSince1970))"
                }
            ))
        }
        return samples
    }

    /// 小米分期 → HealthKit 睡眠分类值。
    static func stageValue(_ stage: MiSleepSegment.Stage) -> HKCategoryValueSleepAnalysis {
        switch stage {
        case .awake: return .awake
        case .deep: return .asleepDeep
        case .rem: return .asleepREM
        case .light: return .asleepCore
        }
    }

    // MARK: - 运动

    /// 运动草稿：用 `HKWorkoutBuilder` 构建（iOS 17 起旧构造器已废弃）。
    /// 心率样本作为运动关联样本写入（不与日总计重复计数）。
    /// 不关联能量/距离样本，避免与每日活动总量重复计算；
    /// 因此 Health 里运动记录保留类型/时长/心率，但不显示独立热量/距离。
    struct WorkoutDraft: Sendable {
        let externalUUID: String
        let activityType: HKWorkoutActivityType
        let start: Date
        let end: Date
        let avgHeartRateBpm: Int?
        let maxHeartRateBpm: Int?
        var legacyUUIDs: [String] = []
        var legacyPrefix: String? = nil
    }

    static func workoutDraft(_ workout: MiWorkout) -> WorkoutDraft? {
        guard workout.endAt > workout.startAt else { return nil }
        return WorkoutDraft(
            externalUUID: "mi_fitness_workout_\(workout.workoutId)",
            activityType: mapActivityType(workout.activityType),
            start: workout.startAt,
            end: workout.endAt,
            avgHeartRateBpm: workout.avgHeartRateBpm,
            maxHeartRateBpm: workout.maxHeartRateBpm,
            legacyUUIDs: workout.legacyWorkoutIDs.map { "mi_fitness_workout_\($0)" },
            legacyPrefix: workout.legacyPrefix
        )
    }

    static func workoutSyncSamples(_ draft: WorkoutDraft) -> [HealthSyncSample] {
        var samples = [HealthSyncSample(
            key: draft.externalUUID, type: HKObjectType.workoutType().identifier, kind: .workout,
            start: draft.start, end: draft.end, value: Double(draft.activityType.rawValue),
            scope: draft.externalUUID, legacyKeys: draft.legacyUUIDs,
            legacyScopePrefix: draft.legacyPrefix
        )]
        for (suffix, bpm) in [("avg_hr", draft.avgHeartRateBpm), ("max_hr", draft.maxHeartRateBpm)] {
            guard let bpm, bpm > 0 else { continue }
            samples[0].workoutHeartRates[suffix] = Double(bpm)
            samples.append(HealthSyncSample(
                key: "\(draft.externalUUID)_\(suffix)", type: HKQuantityType(.heartRate).identifier,
                kind: .quantity, start: draft.start, end: draft.end, value: Double(bpm),
                unit: HKUnit.count().unitDivided(by: .minute()).unitString,
                scope: draft.externalUUID, parentKey: draft.externalUUID,
                legacyKeys: draft.legacyUUIDs.map { "\($0)_\(suffix)" }
            ))
        }
        return samples
    }

    /// 小米运动类型关键词 → `HKWorkoutActivityType`（中文/英文关键词，默认 .other）。
    static func mapActivityType(_ raw: String) -> HKWorkoutActivityType {
        let text = raw.lowercased()
        func contains(_ keywords: String...) -> Bool {
            keywords.contains { text.contains($0) }
        }
        if contains("跑步", "run", "jog") { return .running }
        if contains("步行", "健走", "walk") { return .walking }
        if contains("骑行", "骑车", "cycl", "bike", "ride") { return .cycling }
        if contains("游泳", "swim") { return .swimming }
        if contains("hiit", "interval") { return .highIntensityIntervalTraining }
        if contains("瑜伽", "yoga") { return .yoga }
        if contains("力量", "器械", "weight", "strength", "gym") { return .traditionalStrengthTraining }
        if contains("羽毛球", "badminton") { return .badminton }
        if contains("篮球", "basketball") { return .basketball }
        if contains("足球", "soccer", "football") { return .soccer }
        if contains("网球", "tennis") { return .tennis }
        if contains("乒乓球", "table tennis", "ping") { return .tableTennis }
        if contains("登山", "徒步", "hike", "climb", "mount") { return .hiking }
        return .other
    }

    // MARK: - 基础构造

    private static func quantity(
        _ identifier: HKQuantityTypeIdentifier, unit: HKUnit, value: Double,
        start: Date, end: Date, uuid: String, scope: String? = nil,
        aliases: [String] = [], legacyPrefix: String? = nil
    ) -> HKQuantitySample {
        HKQuantitySample(
            type: HKQuantityType(identifier),
            quantity: HKQuantity(unit: unit, doubleValue: value),
            start: start, end: end,
            metadata: metadata(uuid: uuid, scope: scope, aliases: aliases, legacyPrefix: legacyPrefix)
        )
    }

    private static func category(
        _ value: HKCategoryValueSleepAnalysis, start: Date, end: Date, uuid: String,
        scope: String? = nil, aliases: [String] = [], legacyPrefix: String? = nil,
        completeScope: Bool = false
    ) -> HKCategorySample {
        HKCategorySample(
            type: HKCategoryType(.sleepAnalysis),
            value: value.rawValue,
            start: start, end: end,
            metadata: metadata(uuid: uuid, scope: scope, aliases: aliases, legacyPrefix: legacyPrefix,
                               completeScope: completeScope)
        )
    }

    private static func metadata(uuid: String, scope: String?, aliases: [String],
                                 legacyPrefix: String?, completeScope: Bool = false) -> [String: Any] {
        var result: [String: Any] = [HKMetadataKeyExternalUUID: uuid]
        if let scope { result[HealthSyncMetadata.scope] = scope }
        if let legacyPrefix { result[HealthSyncMetadata.legacyPrefix] = legacyPrefix }
        if completeScope { result[HealthSyncMetadata.completeScope] = true }
        if !aliases.isEmpty, let data = try? JSONEncoder().encode(aliases) {
            result[HealthSyncMetadata.aliases] = String(data: data, encoding: .utf8)
        }
        return result
    }

    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = regionTimeZone
        return cal
    }()

    private static func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = regionTimeZone
        return formatter.date(from: string)
    }

    private static func calendarStartOfDay(_ date: Date) -> Date? {
        calendar.startOfDay(for: date)
    }
}
