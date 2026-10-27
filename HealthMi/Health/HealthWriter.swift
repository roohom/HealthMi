import Foundation
import HealthKit

/// Coordinates native upserts, exact legacy cleanup and durable retry.
actor HealthWriter {
    private let coordinator: HealthSyncCoordinator

    init(store: HKHealthStore = HealthKitManager.healthStore) {
        coordinator = HealthSyncCoordinator(store: HealthKitSyncStore(store: store))
    }

    func resume(account: String, dataType: String) async throws {
        try await coordinator.resume(account: account, dataType: dataType)
    }

    func reconcile(_ samples: [HealthSyncSample], account: String, dataType: String,
                   window: SyncWindow) async throws -> HealthSyncResult {
        try await coordinator.synchronize(samples, account: account, dataType: dataType, window: window)
    }

    static func payload(_ sample: HKSample) throws -> HealthSyncSample {
        let metadata = sample.metadata ?? [:]
        guard let key = metadata[HKMetadataKeyExternalUUID] as? String else {
            throw HealthSyncError.invalidSample(sample.sampleType.identifier)
        }
        let kind: HealthSampleKind
        let value: Double
        let unit: String?
        if let quantity = sample as? HKQuantitySample {
            kind = .quantity
            let measurementUnit = try unitFor(quantity.quantityType)
            value = quantity.quantity.doubleValue(for: measurementUnit)
            unit = measurementUnit.unitString
        } else if let category = sample as? HKCategorySample {
            kind = .category
            value = Double(category.value)
            unit = nil
        } else { throw HealthSyncError.invalidSample(key) }
        let aliases: [String]
        if let encoded = metadata[HealthSyncMetadata.aliases] as? String {
            aliases = try JSONDecoder().decode([String].self, from: Data(encoded.utf8))
        } else { aliases = [] }
        return HealthSyncSample(key: key, type: sample.sampleType.identifier, kind: kind,
                                start: sample.startDate, end: sample.endDate, value: value, unit: unit,
                                scope: metadata[HealthSyncMetadata.scope] as? String,
                                replacesScope: metadata[HealthSyncMetadata.completeScope] as? Bool ?? false,
                                parentKey: metadata[HealthSyncMetadata.parent] as? String,
                                legacyKeys: aliases,
                                legacyScopePrefix: metadata[HealthSyncMetadata.legacyPrefix] as? String)
    }

    private static func unitFor(_ type: HKQuantityType) throws -> HKUnit {
        switch type.identifier {
        case HKQuantityTypeIdentifier.stepCount.rawValue, HKQuantityTypeIdentifier.bodyMassIndex.rawValue:
            return .count()
        case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue: return .meter()
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue, HKQuantityTypeIdentifier.basalEnergyBurned.rawValue:
            return .kilocalorie()
        case HKQuantityTypeIdentifier.heartRate.rawValue, HKQuantityTypeIdentifier.restingHeartRate.rawValue,
             HKQuantityTypeIdentifier.respiratoryRate.rawValue:
            return .count().unitDivided(by: .minute())
        case HKQuantityTypeIdentifier.oxygenSaturation.rawValue, HKQuantityTypeIdentifier.bodyFatPercentage.rawValue:
            return .percent()
        case HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue: return .secondUnit(with: .milli)
        case HKQuantityTypeIdentifier.bodyMass.rawValue, HKQuantityTypeIdentifier.leanBodyMass.rawValue:
            return .gramUnit(with: .kilo)
        default: throw HealthSyncError.invalidSample(type.identifier)
        }
    }
}
