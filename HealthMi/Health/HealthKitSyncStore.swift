import Foundation
import HealthKit

/// HealthKit mechanics only; reconciliation and recovery are tested independently.
actor HealthKitSyncStore: HealthSyncStore {
    private let store: HKHealthStore
    init(store: HKHealthStore = HealthKitManager.healthStore) { self.store = store }

    func load(types: Set<String>, start: Date, end: Date) async throws -> [StoredHealthSample] {
        var result: [StoredHealthSample] = []
        for identifier in types.sorted() {
            let type = try sampleType(identifier)
            var anchor: HKQueryAnchor?
            while true {
                try Task.checkCancellation()
                let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    HKQuery.predicateForObjects(from: HKSource.default()),
                    HKQuery.predicateForSamples(withStart: start, end: end),
                ])
                let page: ([HKSample], [HKDeletedObject], HKQueryAnchor?) = try await withCheckedThrowingContinuation { continuation in
                    let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor, limit: 1000) {
                        _, samples, deleted, next, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: (samples ?? [], deleted ?? [], next)) }
                    }
                    store.execute(query)
                }
                if page.0.isEmpty && page.1.isEmpty { break }
                guard let next = page.2, next != anchor else { throw HealthSyncError.verificationFailed }
                anchor = next
                result.append(contentsOf: page.0.map { sample in
                    let metadata = sample.metadata ?? [:]
                    return StoredHealthSample(
                        uuid: sample.uuid, type: identifier, start: sample.startDate, end: sample.endDate,
                        syncID: metadata[HKMetadataKeySyncIdentifier] as? String,
                        version: (metadata[HKMetadataKeySyncVersion] as? NSNumber)?.intValue ?? 0,
                        fingerprint: metadata[HealthSyncMetadata.fingerprint] as? String,
                        externalID: metadata[HKMetadataKeyExternalUUID] as? String,
                        scope: metadata[HealthSyncMetadata.scope] as? String
                    )
                })
            }
        }
        return result
    }

    func save(_ entries: [VersionedHealthSample]) async throws {
        let plain = try entries.filter { $0.needsWrite && $0.sample.kind != .workout }.map(makeSample)
        for offset in stride(from: 0, to: plain.count, by: 500) {
            try Task.checkCancellation()
            try await store.save(Array(plain[offset..<min(offset + 500, plain.count)]))
        }
        for entry in entries where entry.sample.kind == .workout {
            try Task.checkCancellation()
            let existing = try await find(entry.syncID, type: HKObjectType.workoutType()).first as? HKWorkout
            let children = entries.filter { $0.sample.parentKey == entry.sample.key }
            let wantedIDs = Set(children.map(\.syncID))
            if let existing, existing.metadata?[HealthSyncMetadata.fingerprint] as? String == entry.fingerprint {
                let linked = try await query(HKQuantityType(.heartRate), predicate: HKQuery.predicateForObjects(from: existing))
                let linkedIDs = Set(linked.compactMap { $0.metadata?[HKMetadataKeySyncIdentifier] as? String })
                if wantedIDs.isSubset(of: linkedIDs) { continue }
            }
            let previousVersion = (existing?.metadata?[HKMetadataKeySyncVersion] as? NSNumber)?.intValue ?? 0
            if previousVersion >= entry.version,
               existing?.metadata?[HealthSyncMetadata.fingerprint] as? String != entry.fingerprint {
                throw HealthSyncError.verificationFailed
            }
            let config = HKWorkoutConfiguration()
            guard entry.sample.value >= 0, entry.sample.value < Double(UInt.max),
                  let activity = HKWorkoutActivityType(rawValue: UInt(entry.sample.value)) else {
                throw HealthSyncError.invalidSample(entry.sample.key)
            }
            config.activityType = activity
            let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: nil)
            do {
                try await builder.beginCollection(at: entry.sample.start)
                var data = metadata(entry)
                data[HKMetadataKeySyncVersion] = max(entry.version, previousVersion + 1)
                try await builder.addMetadata(data)
                var linkedSamples: [HKSample] = []
                for child in children {
                    guard let saved = try await find(child.syncID, type: HKQuantityType(.heartRate)).first else {
                        throw HealthSyncError.verificationFailed
                    }
                    linkedSamples.append(saved)
                }
                if !linkedSamples.isEmpty { try await builder.addSamples(linkedSamples) }
                try await builder.endCollection(at: entry.sample.end)
                guard try await builder.finishWorkout() != nil else { throw HealthSyncError.verificationFailed }
            } catch {
                builder.discardWorkout()
                throw error
            }
        }
    }

    func delete(_ samples: [StoredHealthSample]) async throws {
        for (identifier, group) in Dictionary(grouping: samples, by: \.type) {
            let type = try sampleType(identifier)
            for offset in stride(from: 0, to: group.count, by: 500) {
                try Task.checkCancellation()
                let ids = Set(group[offset..<min(offset + 500, group.count)].map(\.uuid))
                let predicate = HKQuery.predicateForObjects(with: ids)
                _ = try await store.deleteObjects(of: type, predicate: predicate)
            }
        }
    }

    private func metadata(_ entry: VersionedHealthSample) -> [String: Any] {
        var data: [String: Any] = [
            HKMetadataKeyExternalUUID: entry.sample.key,
            HKMetadataKeySyncIdentifier: entry.syncID,
            HKMetadataKeySyncVersion: entry.version,
            HealthSyncMetadata.fingerprint: entry.fingerprint,
        ]
        if let scope = entry.sample.scope { data[HealthSyncMetadata.scope] = scope }
        if let parent = entry.sample.parentKey { data[HealthSyncMetadata.parent] = parent }
        return data
    }

    private func makeSample(_ entry: VersionedHealthSample) throws -> HKSample {
        let record = entry.sample
        switch record.kind {
        case .quantity:
            guard let type = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: record.type)),
                  let unit = record.unit else { throw HealthSyncError.invalidSample(record.key) }
            return HKQuantitySample(type: type, quantity: HKQuantity(unit: HKUnit(from: unit), doubleValue: record.value),
                                    start: record.start, end: record.end, metadata: metadata(entry))
        case .category:
            guard let type = HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: record.type)),
                  record.value >= 0, record.value < Double(Int.max), record.value.rounded() == record.value else {
                throw HealthSyncError.invalidSample(record.key)
            }
            return HKCategorySample(type: type, value: Int(record.value), start: record.start,
                                    end: record.end, metadata: metadata(entry))
        case .workout: throw HealthSyncError.invalidSample(record.key)
        }
    }

    private func sampleType(_ id: String) throws -> HKSampleType {
        if id == HKObjectType.workoutType().identifier { return HKObjectType.workoutType() }
        if let type = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: id)) { return type }
        if let type = HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: id)) { return type }
        throw HealthSyncError.invalidSample(id)
    }

    private func find(_ id: String, type: HKSampleType) async throws -> [HKSample] {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [id]),
        ])
        return try await query(type, predicate: predicate)
    }

    private func query(_ type: HKSampleType, predicate: NSPredicate) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, objects, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: objects ?? []) }
            }
            store.execute(query)
        }
    }
}
