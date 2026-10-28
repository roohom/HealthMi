import Foundation

/// 把云端原始条目（`[MiItem]`）解析为业务模型。
/// Swift 移植自 `mi_fitness_cloud.py` 的各 `iter_*` 方法，字段与解析规则保持一致。
enum MiParser {
    enum SleepError: LocalizedError {
        case invalidRecord, conflictingVersions, unknownStage, incompleteStages
        var errorDescription: String? {
            switch self {
            case .invalidRecord: return "睡眠记录格式或分段时间无效，已停止本类同步。"
            case .conflictingVersions:
                return "同组睡眠候选存在不同内容，无法确认唯一有效记录；已保留现有健康数据。"
            case .unknownStage: return "发现未知睡眠阶段，已停止写入，避免误记成浅睡。"
            case .incompleteStages: return "云端睡眠缺少完整分期，已保留现有睡眠数据，请稍后重试。"
            }
        }
    }

    private struct SleepRecord {
        var item: MiItem
        var aliases: [String]
        let content: Data
    }

    /// `time` is a source timestamp, not a documented revision number. Never use it to
    /// guess which conflicting snapshot wins, nor assume that longer sleep is newer.
    private static func canonicalSleepRecords(_ items: [MiItem]) throws -> [SleepRecord] {
        var groups: [String: [SleepRecord]] = [:]
        for item in items {
            // Xiaomi 3.59.1 treats missing/null deleted as active. A tombstone is not a
            // HealthKit deletion instruction; it simply cannot supply importable samples.
            if item.deletionState == .deleted { continue }
            guard item.deletionState != .invalid else { throw SleepError.invalidRecord }
            let payload = valueObject(item)
            guard let start = firstInt(payload, "bedtime", "device_bedtime", "bed_timestamp"),
                  let end = firstInt(payload, "wake_up_time", "device_wake_up_time", "out_bed_timestamp") ?? item.time,
                  start > 0, end > start else { throw SleepError.invalidRecord }
            let sid = item.sid ?? "unknown"
            let key = "\(sid)_\(start)"
            let alias = "\(sid)_\(item.time ?? end)"
            var segments: [[String: Int]] = []
            if payload["items"] != nil, !(payload["items"] is [[String: Any]]) { throw SleepError.invalidRecord }
            for segment in (payload["items"] as? [[String: Any]]) ?? [] {
                guard let a = MiJSON.int(segment["start_time"]), let b = MiJSON.int(segment["end_time"]),
                      let stage = MiJSON.int(segment["state"]), b > a, a >= start, b <= end else {
                    throw SleepError.invalidRecord
                }
                guard (2...5).contains(stage) else { throw SleepError.unknownStage }
                segments.append(["start_time": a, "end_time": b, "state": stage])
            }
            segments.sort { $0["start_time"]! < $1["start_time"]! }
            var previousEnd = start
            for segment in segments {
                guard segment["start_time"]! >= previousEnd else { throw SleepError.invalidRecord }
                previousEnd = segment["end_time"]!
            }
            var semantic: [String: Any] = ["start": start, "end": end, "items": segments]
            for field in ["avg_breath", "avg_hrv", "hrv_median"] {
                if let value = MiJSON.int(payload[field]) { semantic[field] = value }
            }
            let content = try JSONSerialization.data(withJSONObject: semantic, options: .sortedKeys)
            groups[key, default: []].append(SleepRecord(item: item, aliases: [alias], content: content))
        }
        return try groups.sorted { $0.key < $1.key }.map { _, candidates in
            var selected = candidates[0]
            if candidates.contains(where: { $0.content != selected.content }) {
                selected = try completedSleepCandidate(candidates)
            }
            selected.aliases = Array(Set(candidates.flatMap(\.aliases))).sorted()
            return selected
        }
    }

    /// Verified against com.mi.health 3.59.1: is_uncomplete is the inverse of
    /// isCompleteSleep; a new containing sleep can supersede an unfinished segment.
    /// This is deliberately narrower than Xiaomi's containment cleanup: exact source
    /// and bedtime, one complete content, no fuzzy grouping or clock-based ranking.
    private static func completedSleepCandidate(_ candidates: [SleepRecord]) throws -> SleepRecord {
        guard let sid = candidates[0].item.sid, !sid.isEmpty else { throw SleepError.conflictingVersions }
        let category = candidates[0].item.category
        let offset = candidates[0].item.zoneOffset
        let zone = candidates[0].item.zoneName
        var completed: [SleepRecord] = []
        for candidate in candidates {
            let item = candidate.item
            let payload = valueObject(item)
            guard item.key == "sleep", item.sid == sid, item.category == category,
                  item.zoneOffset == offset, item.zoneName == zone,
                  MiJSON.int(payload["bedtime"]) != nil,
                  let incomplete = MiJSON.jsonBool(payload["is_uncomplete"]) else {
                throw SleepError.conflictingVersions
            }
            if !incomplete { completed.append(candidate) }
        }
        guard let winner = completed.first,
              completed.allSatisfy({ $0.content == winner.content }),
              let end = firstInt(valueObject(winner.item), "wake_up_time", "device_wake_up_time", "out_bed_timestamp"),
              candidates.allSatisfy({ candidate in
                  guard let candidateEnd = firstInt(valueObject(candidate.item), "wake_up_time", "device_wake_up_time", "out_bed_timestamp") else { return false }
                  return candidateEnd <= end
              }) else { throw SleepError.conflictingVersions }
        return winner
    }
    // MARK: - 日常活动（steps + calories 两个 key）

    /// 对应 `iter_daily_activity`：步数/距离来自 steps，活动卡路里以 calories 总量为准。
    static func dailyActivity(
        stepsItems: [MiItem],
        calorieItems: [MiItem]
    ) -> [MiDailyActivity] {
        struct Acc {
            var steps = 0
            var distance = 0.0
            var kcalFromSteps = 0.0
            var timezone = "UTC"
            var hasSteps = false
            var hasDistance = false
            var hasCalories = false
        }
        var byDate: [String: Acc] = [:]
        var seenSteps = Set<MiItem>()
        for item in stepsItems where seenSteps.insert(item).inserted {
            let date = calendarDay(of: item)
            let payload = valueObject(item)
            var acc = byDate[date] ?? Acc()
            if let steps = MiJSON.int(payload["steps"]) { acc.steps += steps; acc.hasSteps = true }
            if let distance = MiJSON.double(payload["distance"]) { acc.distance += distance; acc.hasDistance = true }
            if let calories = MiJSON.double(payload["calories"]) { acc.kcalFromSteps += calories; acc.hasCalories = true }
            if let zone = item.zoneName { acc.timezone = zone }
            byDate[date] = acc
        }
        var calorieTotals: [String: Double] = [:]
        var seenCalories = Set<MiItem>()
        for item in calorieItems where seenCalories.insert(item).inserted {
            let date = calendarDay(of: item)
            let payload = valueObject(item)
            if let calories = MiJSON.double(payload["calories"]) { calorieTotals[date, default: 0] += calories }
        }
        for (date, total) in calorieTotals {
            byDate[date, default: Acc()].kcalFromSteps = total
            byDate[date, default: Acc()].hasCalories = true
        }
        return byDate.sorted { $0.key < $1.key }.map { date, acc in
            MiDailyActivity(
                date: date,
                steps: acc.steps,
                distanceM: acc.distance,
                activeKcal: acc.kcalFromSteps,
                timezone: acc.timezone,
                hasSteps: acc.hasSteps,
                hasDistance: acc.hasDistance,
                hasActiveCalories: acc.hasCalories
            )
        }
    }

    // MARK: - 睡眠

    /// 对应 `iter_sleep_sessions`。分段（stages）保留精确起止时间，供 HealthKit 精细写入。
    static func sleepSessions(_ items: [MiItem]) throws -> [MiSleepSession] {
        var sessions: [MiSleepSession] = []
        for record in try canonicalSleepRecords(items) {
            let item = record.item
            let payload = valueObject(item)
            guard let stages = payload["items"] as? [[String: Any]], !stages.isEmpty else {
                throw SleepError.incompleteStages
            }
            let sleepStart = firstInt(payload, "bedtime", "device_bedtime", "bed_timestamp")
            let sleepEnd = firstInt(payload, "wake_up_time", "device_wake_up_time", "out_bed_timestamp")
                ?? item.time
            guard let start = sleepStart, let end = sleepEnd else { continue }

            let startAt = Date(timeIntervalSince1970: Double(start))
            let endAt = Date(timeIntervalSince1970: Double(end))
            let duration = MiJSON.int(payload["duration"])
                ?? max(0, (end - start) / 60)
            let awake = MiJSON.int(payload["awake_duration"])
                ?? MiJSON.int(payload["sleep_awake_duration"])
                ?? 0
            let asleep = max(0, duration - awake)

            var segments: [MiSleepSegment] = []
            if let rawSegments = payload["items"] as? [[String: Any]] {
                for seg in rawSegments {
                    let segStart = MiJSON.int(seg["start_time"])
                    let segEnd = MiJSON.int(seg["end_time"])
                    guard let segStart, let segEnd, segEnd > segStart else { continue }
                    let stage = sleepStageName(MiJSON.int(seg["state"]))
                    segments.append(MiSleepSegment(
                        startAt: Date(timeIntervalSince1970: Double(segStart)),
                        endAt: Date(timeIntervalSince1970: Double(segEnd)),
                        stage: stage
                    ))
                }
            }

            let sid = item.sid ?? "unknown"
            let sleepId = "\(sid)_\(start)"
            sessions.append(MiSleepSession(
                sleepId: sleepId,
                startAt: startAt,
                endAt: endAt,
                durationMinutes: duration,
                timeAsleepMinutes: asleep,
                timeAwakeMinutes: awake,
                sleepScore: MiJSON.int(payload["score"]) ?? MiJSON.int(payload["sleep_score"]),
                isNap: MiJSON.bool(payload["is_nap"]) ?? false,
                segments: segments.sorted { $0.startAt < $1.startAt },
                sourceID: item.sid,
                legacySleepIDs: record.aliases
            ))
        }
        return sessions
    }

    /// 睡眠 state 编码（实测交叉验证：分段分钟数 = 顶层 sleep_*_duration）：
    /// 2 = 深度睡眠, 3 = 浅睡(核心), 4 = REM, 5 = 清醒。
    /// 注：Python 参考实现的旧映射（1=深睡/4=清醒/5=REM）与实际数据不符，已按实测修正。
    static func sleepStageName(_ state: Int?) -> MiSleepSegment.Stage {
        switch state {
        case 2: return .deep
        case 3: return .light
        case 4: return .rem
        case 5: return .awake
        default: return .light
        }
    }

    // MARK: - 心率

    /// 对应 `iter_heart_rate`：普通采样 + 静息心率。
    static func heartRateSamples(_ items: [MiItem], restingItems: [MiItem]) -> [MiHeartRateSample] {
        var samples: [MiHeartRateSample] = []
        for item in items {
            let payload = valueObject(item)
            let bpm = MiJSON.int(payload["bpm"]) ?? 0
            let type: MiHeartRateSample.SampleType = (MiJSON.int(payload["type"]) ?? 0) == 0 ? .passive : .active
            samples.append(MiHeartRateSample(
                timestamp: recordDate(of: item),
                bpm: bpm,
                sampleType: type
            ))
        }
        for item in restingItems {
            let payload = valueObject(item)
            let ts = MiJSON.int(payload["date_time"]) ?? item.time ?? 0
            samples.append(MiHeartRateSample(
                timestamp: Date(timeIntervalSince1970: Double(ts)),
                bpm: MiJSON.int(payload["bpm"]) ?? 0,
                sampleType: .resting
            ))
        }
        return samples
    }

    // MARK: - 血氧 / 压力

    static func spo2Samples(_ items: [MiItem]) -> [MiSpO2Sample] {
        var out: [MiSpO2Sample] = []
        for item in items {
            let payload = valueObject(item)
            let ts = MiJSON.int(payload["time"]) ?? item.time
            let spo2 = MiJSON.int(payload["spo2"]) ?? MiJSON.int(payload["value"])
            if let ts, let spo2 {
                out.append(MiSpO2Sample(
                    timestamp: Date(timeIntervalSince1970: Double(ts)),
                    spo2Pct: spo2
                ))
            }
        }
        return out
    }

    static func stressSamples(_ items: [MiItem]) -> [MiStressSample] {
        var out: [MiStressSample] = []
        for item in items {
            let payload = valueObject(item)
            let ts = MiJSON.int(payload["time"]) ?? item.time
            let stress = MiJSON.int(payload["stress"])
                ?? MiJSON.int(payload["score"])
                ?? MiJSON.int(payload["value"])
            if let ts, let stress {
                out.append(MiStressSample(
                    timestamp: Date(timeIntervalSince1970: Double(ts)),
                    stressScore: stress
                ))
            }
        }
        return out
    }

    // MARK: - 心率变异性（睡眠 HRV）

    /// 从睡眠记录提取 HRV（优先 `avg_hrv`，回退 `hrv_median`），单位毫秒。
    static func hrvSamples(_ items: [MiItem]) throws -> [MiHRVSample] {
        try canonicalSleepRecords(items).compactMap { record in
            let item = record.item
            let payload = valueObject(item)
            let sdnn = MiJSON.int(payload["avg_hrv"]) ?? MiJSON.int(payload["hrv_median"])
            guard let sdnn, sdnn > 0 else { return nil }
            let start = firstInt(payload, "bedtime", "device_bedtime", "bed_timestamp") ?? item.time
            let end = firstInt(payload, "wake_up_time", "device_wake_up_time", "out_bed_timestamp") ?? item.time
            guard let start, let end, end > start else { return nil }
            let sleepId = "\(item.sid ?? "unknown")_\(start)"
            return MiHRVSample(
                sleepId: sleepId,
                startAt: Date(timeIntervalSince1970: Double(start)),
                endAt: Date(timeIntervalSince1970: Double(end)),
                sdnnMs: sdnn,
                sourceID: item.sid,
                legacySleepIDs: record.aliases
            )
        }
    }

    // MARK: - 呼吸频率（睡眠平均）

    /// 从睡眠记录提取 `avg_breath`（每次睡眠的平均呼吸频率）。
    static func respiratoryRateSamples(_ items: [MiItem]) throws -> [MiRespiratoryRateSample] {
        try canonicalSleepRecords(items).compactMap { record in
            let item = record.item
            let payload = valueObject(item)
            guard let breaths = MiJSON.int(payload["avg_breath"]), breaths > 0 else { return nil }
            let start = firstInt(payload, "bedtime", "device_bedtime", "bed_timestamp") ?? item.time
            let end = firstInt(payload, "wake_up_time", "device_wake_up_time", "out_bed_timestamp") ?? item.time
            guard let start, let end, end > start else { return nil }
            let sleepId = "\(item.sid ?? "unknown")_\(start)"
            return MiRespiratoryRateSample(
                sleepId: sleepId,
                startAt: Date(timeIntervalSince1970: Double(start)),
                endAt: Date(timeIntervalSince1970: Double(end)),
                breathsPerMinute: breaths,
                sourceID: item.sid,
                legacySleepIDs: record.aliases
            )
        }
    }

    // MARK: - 身体测量

    /// 对应 `iter_body_measurements`（体重 key）。`0` 视为无值。
    static func bodyMeasurements(_ items: [MiItem]) -> [MiBodyMeasurement] {
        items.compactMap { item in
            let payload = valueObject(item)
            guard let weight = MiJSON.double(payload["weight"]), weight > 0 else { return nil }
            return MiBodyMeasurement(
                timestamp: recordDate(of: item),
                weightKg: weight,
                bmi: MiJSON.double(payload["bmi"]),
                bodyFatPct: optionalDouble(payload["body_fat_rate"]),
                muscleMassKg: optionalDouble(payload["muscle_rate"]),
                waterPct: optionalDouble(payload["moisture_rate"]),
                boneMassKg: optionalDouble(payload["bone_mass"]),
                visceralFatScore: optionalInt(payload["visceral_fat"]),
                basalMetabolismKcal: optionalInt(payload["basal_metabolism"]),
                metabolicAge: optionalInt(payload["body_age"])
            )
        }
    }

    // MARK: - 运动记录

    /// 对应 `iter_workouts`（走 `get_sport_records_by_time`）。
    static func workouts(_ items: [MiItem]) -> [MiWorkout] {
        var out: [MiWorkout] = []
        for item in items {
            let payload = valueObject(item)
            let startTs = MiJSON.int(payload["start_time"]) ?? item.time
            var endTs = MiJSON.int(payload["end_time"])
            let durationSeconds = MiJSON.int(payload["duration"]) ?? 0
            if endTs == nil, let startTs { endTs = startTs + durationSeconds }
            guard let startTs, let endTs else { continue }

            var durationMinutes = durationSeconds / 60
            if durationMinutes == 0 { durationMinutes = max(0, (endTs - startTs) / 60) }

            let key = item.key ?? "workout"
            let workoutId = "\(item.sid ?? "unknown")_\(key)_\(startTs)"
            let legacyID = "\(item.sid ?? "unknown")_\(key)_\(item.time ?? startTs)"
            out.append(MiWorkout(
                workoutId: workoutId,
                activityType: item.category ?? item.key ?? MiJSON.string(payload["sport_type"]) ?? "workout",
                startAt: Date(timeIntervalSince1970: Double(startTs)),
                endAt: Date(timeIntervalSince1970: Double(endTs)),
                durationMinutes: durationMinutes,
                distanceM: optionalDouble(payload["distance"]),
                caloriesKcal: optionalDouble(payload["calories"]) ?? optionalDouble(payload["total_cal"]),
                avgHeartRateBpm: optionalInt(payload["avg_hrm"]),
                maxHeartRateBpm: optionalInt(payload["max_hrm"]),
                totalSteps: optionalInt(payload["steps"]) ?? optionalInt(payload["total_steps"]),
                legacyWorkoutIDs: [legacyID],
                legacyPrefix: "mi_fitness_workout_\(item.sid ?? "unknown")_\(key)_"
            ))
        }
        return out
    }

    // MARK: - 工具

    private static func valueObject(_ item: MiItem) -> [String: Any] {
        guard let data = item.valueData else { return [:] }
        return MiJSON.object(from: data) ?? [:]
    }

    /// `_record_datetime`：item.time 是绝对时刻，无需时区转换。
    private static func recordDate(of item: MiItem) -> Date {
        Date(timeIntervalSince1970: Double(item.time ?? 0))
    }

    /// 按 item 自带 zone_offset 得到所在日历日（YYYY-MM-DD）。
    private static func calendarDay(of item: MiItem) -> String {
        let ts = item.time ?? 0
        let tz = TimeZone(secondsFromGMT: item.zoneOffset ?? 0) ?? .gmt
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let comps = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(ts)))
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    private static func firstInt(_ dict: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            if let v = MiJSON.int(dict[key]) { return v }
        }
        return nil
    }

    /// `_optional_float`：0 视为 nil。
    private static func optionalDouble(_ value: Any?) -> Double? {
        guard let parsed = MiJSON.double(value), parsed != 0 else { return nil }
        return parsed
    }

    /// `_optional_int`：0 视为 nil。
    private static func optionalInt(_ value: Any?) -> Int? {
        guard let parsed = MiJSON.int(value), parsed != 0 else { return nil }
        return parsed
    }
}
