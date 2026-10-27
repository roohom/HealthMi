import HealthKit
import XCTest
@testable import HealthMi

final class TypeMapperTests: XCTestCase {
    private let cn = TimeZone(secondsFromGMT: 8 * 3600)!
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = cn; return c }

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))!
    }

    func testDailyActivitySamples() throws {
        let activity = MiDailyActivity(
            date: "2026-08-10", steps: 8123, distanceM: 5200, activeKcal: 210, timezone: "Asia/Shanghai"
        )
        let samples = TypeMapper.dailyActivitySamples(activity)
        XCTAssertEqual(samples.count, 3)

        let steps = try XCTUnwrap(samples.first { $0.quantityType == HKQuantityType(.stepCount) })
        XCTAssertEqual(steps.quantity.doubleValue(for: .count()), 8123)
        XCTAssertEqual(steps.startDate, day(2026, 8, 10))
        XCTAssertEqual(steps.endDate, day(2026, 8, 11))
        XCTAssertEqual(steps.metadata?[HKMetadataKeyExternalUUID] as? String, "mi_fitness_steps_2026-08-10")

        let distance = try XCTUnwrap(samples.first { $0.quantityType == HKQuantityType(.distanceWalkingRunning) })
        XCTAssertEqual(distance.quantity.doubleValue(for: .meter()), 5200)

        let energy = try XCTUnwrap(samples.first { $0.quantityType == HKQuantityType(.activeEnergyBurned) })
        XCTAssertEqual(energy.quantity.doubleValue(for: .kilocalorie()), 210)
    }

    func testHeartRateResting() throws {
        let ts = day(2026, 8, 10, hour: 6)
        let resting = MiHeartRateSample(timestamp: ts, bpm: 55, sampleType: .resting)
        let sample = try XCTUnwrap(TypeMapper.heartRateSample(resting))
        XCTAssertEqual(sample.quantityType, HKQuantityType(.restingHeartRate))
        XCTAssertEqual(
            sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
            55
        )
        XCTAssertEqual(
            sample.metadata?[HKMetadataKeyExternalUUID] as? String,
            "mi_fitness_resting_hr_\(Int(ts.timeIntervalSince1970))"
        )
    }

    func testSpo2FractionConversion() throws {
        let ts = day(2026, 8, 10, hour: 7)
        let sample = try XCTUnwrap(TypeMapper.spo2Sample(MiSpO2Sample(timestamp: ts, spo2Pct: 98)))
        XCTAssertEqual(sample.quantityType, HKQuantityType(.oxygenSaturation))
        // 98% → 0.98
        XCTAssertEqual(sample.quantity.doubleValue(for: .percent()), 0.98, accuracy: 0.0001)
    }

    func testBodyMeasurementConversion() throws {
        let ts = day(2026, 8, 10, hour: 8)
        let measurement = MiBodyMeasurement(
            timestamp: ts, weightKg: 70.5, bmi: 23.1, bodyFatPct: 20, muscleMassKg: 30.2,
            waterPct: 55, boneMassKg: nil, visceralFatScore: nil,
            basalMetabolismKcal: 1620, metabolicAge: 28
        )
        let samples = TypeMapper.bodyMeasurementSamples(measurement)
        XCTAssertEqual(samples.count, 5)

        let weight = try XCTUnwrap(samples.first { $0.quantityType == HKQuantityType(.bodyMass) })
        XCTAssertEqual(weight.quantity.doubleValue(for: .gramUnit(with: .kilo)), 70.5)

        let fat = try XCTUnwrap(samples.first { $0.quantityType == HKQuantityType(.bodyFatPercentage) })
        // 20% → 0.20
        XCTAssertEqual(fat.quantity.doubleValue(for: .percent()), 0.20, accuracy: 0.0001)

        let bmi = try XCTUnwrap(samples.first { $0.quantityType == HKQuantityType(.bodyMassIndex) })
        XCTAssertEqual(bmi.quantity.doubleValue(for: .count()), 23.1, accuracy: 0.0001)

        let muscle = try XCTUnwrap(samples.first { $0.quantityType == HKQuantityType(.leanBodyMass) })
        XCTAssertEqual(muscle.quantity.doubleValue(for: .gramUnit(with: .kilo)), 30.2)

        let bmr = try XCTUnwrap(samples.first { $0.quantityType == HKQuantityType(.basalEnergyBurned) })
        XCTAssertEqual(bmr.quantity.doubleValue(for: .kilocalorie()), 1620)
    }

    func testSleepSamples() throws {
        let start = day(2026, 8, 10, hour: 23, minute: 30)
        let end = day(2026, 8, 11, hour: 6, minute: 30)
        let session = MiSleepSession(
            sleepId: "123_456",
            startAt: start, endAt: end,
            durationMinutes: 420, timeAsleepMinutes: 380, timeAwakeMinutes: 40,
            sleepScore: 88, isNap: false,
            segments: [
                MiSleepSegment(startAt: start, endAt: start.addingTimeInterval(60), stage: .deep),
                MiSleepSegment(startAt: start.addingTimeInterval(60), endAt: start.addingTimeInterval(120), stage: .rem),
                MiSleepSegment(startAt: start.addingTimeInterval(120), endAt: start.addingTimeInterval(180), stage: .awake),
                MiSleepSegment(startAt: start.addingTimeInterval(180), endAt: start.addingTimeInterval(300), stage: .light),
            ]
        )
        let samples = TypeMapper.sleepSamples(session)
        // inBed + 4 个阶段段（不再写整晚 asleep 聚合样本）
        XCTAssertEqual(samples.count, 5)

        let inBed = try XCTUnwrap(samples.first {
            ($0.metadata?[HKMetadataKeyExternalUUID] as? String) == "mi_fitness_sleep_123_456_inBed"
        })
        XCTAssertEqual(inBed.value, HKCategoryValueSleepAnalysis.inBed.rawValue)

        // deep 段应映射为 AsleepDeep
        let deepUUID = "mi_fitness_sleep_123_456_segment_\(Int(start.timeIntervalSince1970))"
        let deep = try XCTUnwrap(samples.first {
            ($0.metadata?[HKMetadataKeyExternalUUID] as? String) == deepUUID
        })
        XCTAssertEqual(deep.value, HKCategoryValueSleepAnalysis.asleepDeep.rawValue)
    }

    func testHRVSample() throws {
        let start = day(2026, 8, 10, hour: 23)
        let end = day(2026, 8, 11, hour: 6)
        let sample = MiHRVSample(sleepId: "s1", startAt: start, endAt: end, sdnnMs: 37)
        let hk = try XCTUnwrap(TypeMapper.hrvSample(sample))
        XCTAssertEqual(hk.quantityType, HKQuantityType(.heartRateVariabilitySDNN))
        XCTAssertEqual(hk.quantity.doubleValue(for: .secondUnit(with: .milli)), 37)
        XCTAssertEqual(hk.startDate, start)
        XCTAssertEqual(hk.endDate, end)
        XCTAssertEqual(hk.metadata?[HKMetadataKeyExternalUUID] as? String, "mi_fitness_hrv_s1")
    }

    func testRespiratoryRateSample() throws {
        let start = day(2026, 8, 10, hour: 23)
        let end = day(2026, 8, 11, hour: 6)
        let sample = MiRespiratoryRateSample(
            sleepId: "s1", startAt: start, endAt: end, breathsPerMinute: 16
        )
        let hk = try XCTUnwrap(TypeMapper.respiratoryRateSample(sample))
        XCTAssertEqual(hk.quantityType, HKQuantityType(.respiratoryRate))
        XCTAssertEqual(
            hk.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
            16
        )
        XCTAssertEqual(hk.startDate, start)
        XCTAssertEqual(hk.endDate, end)
        XCTAssertEqual(hk.metadata?[HKMetadataKeyExternalUUID] as? String, "mi_fitness_respiratory_s1")
    }

    func testActivityTypeMapping() {
        XCTAssertEqual(TypeMapper.mapActivityType("跑步"), .running)
        XCTAssertEqual(TypeMapper.mapActivityType("Run"), .running)
        XCTAssertEqual(TypeMapper.mapActivityType("cycling"), .cycling)
        XCTAssertEqual(TypeMapper.mapActivityType("游泳"), .swimming)
        XCTAssertEqual(TypeMapper.mapActivityType("瑜伽"), .yoga)
        XCTAssertEqual(TypeMapper.mapActivityType("unknown sport"), .other)
    }
}
