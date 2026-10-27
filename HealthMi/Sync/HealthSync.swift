import CryptoKit
import Foundation

enum HealthSyncMetadata {
    static let fingerprint = "com.healthmi.sync.contentHash"
    static let scope = "com.healthmi.sync.scope"
    static let parent = "com.healthmi.sync.parent"
    static let aliases = "com.healthmi.sync.legacyAliases"
    static let legacyPrefix = "com.healthmi.sync.legacyPrefix"
    static let completeScope = "com.healthmi.sync.completeScope"
}

enum HealthSampleKind: String, Codable, Sendable { case quantity, category, workout }

/// A small, serializable write payload; contains no login credentials or raw cloud response.
struct HealthSyncSample: Codable, Sendable, Equatable {
    var key: String
    var type: String
    var kind: HealthSampleKind
    var start: Date
    var end: Date
    var value: Double
    var unit: String? = nil
    var scope: String? = nil
    var replacesScope = false
    var parentKey: String? = nil
    var workoutHeartRates: [String: Double] = [:]
    var legacyKeys: [String] = []
    var legacyScopePrefix: String? = nil

    func fingerprint() throws -> String {
        guard !key.isEmpty, !type.isEmpty, value.isFinite,
              start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
              end >= start, kind == .quantity || end > start else {
            throw HealthSyncError.invalidSample(key)
        }
        // Only semantic content participates; aliases and JSON field order aren't revisions.
        struct Content: Encodable {
            let key: String, type: String, kind: HealthSampleKind
            let start: Date, end: Date
            let value: Double
            let unit: String?, scope: String?, parentKey: String?
            let workoutHeartRates: [String: Double]
        }
        let content = Content(key: key, type: type, kind: kind, start: start, end: end,
                              value: value, unit: unit, scope: scope, parentKey: parentKey,
                              workoutHeartRates: workoutHeartRates)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return Self.digest(try encoder.encode(content))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct StoredHealthSample: Codable, Sendable, Equatable {
    let uuid: UUID
    let type: String
    let start: Date
    let end: Date
    let syncID: String?
    let version: Int
    let fingerprint: String?
    let externalID: String?
    let scope: String?
}

struct VersionedHealthSample: Codable, Sendable {
    let sample: HealthSyncSample
    let syncID: String
    let version: Int
    let fingerprint: String
    let needsWrite: Bool
}

struct HealthSyncResult: Codable, Sendable {
    var added = 0
    var updated = 0
    var skipped = 0
    var removed = 0
}

/// A real HealthKit adapter and a fault-injecting test store share this boundary.
protocol HealthSyncStore: Sendable {
    func load(types: Set<String>, start: Date, end: Date) async throws -> [StoredHealthSample]
    func save(_ samples: [VersionedHealthSample]) async throws
    func delete(_ samples: [StoredHealthSample]) async throws
}

enum HealthSyncError: LocalizedError {
    case busy, invalidSample(String), conflictingSample(String), verificationFailed, invalidJournal
    var errorDescription: String? {
        switch self {
        case .busy: return "已有同步任务正在运行，请稍后重试。"
        case .invalidSample(let key): return "样本时间或数值无效：\(key)"
        case .conflictingSample(let key): return "同一记录存在冲突内容，已停止写入：\(key)"
        case .verificationFailed: return "HealthKit 写入或清理尚未完成，下次同步将继续恢复。"
        case .invalidJournal: return "待恢复同步记录损坏，已停止写入以保护现有数据。"
        }
    }
}

private struct PendingHealthPlan: Codable {
    let account: String
    let dataType: String
    let start: Date
    let end: Date
    let samples: [VersionedHealthSample]
    let obsolete: [StoredHealthSample]
    let result: HealthSyncResult
}

/// Only unfinished operations are kept. Atomic, protected files avoid a new database schema.
struct PendingSyncJournal: Sendable {
    let directory: URL

    static var applicationDefault: Self {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(directory: support.appendingPathComponent("HealthMi/PendingSync", isDirectory: true))
    }

    private func url(_ key: String) -> URL {
        directory.appendingPathComponent(HealthSyncSample.digest(Data(key.utf8)) + ".json")
    }

    fileprivate func read(_ key: String) throws -> PendingHealthPlan? {
        let path = url(key)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        do { return try JSONDecoder().decode(PendingHealthPlan.self, from: Data(contentsOf: path)) }
        catch { throw HealthSyncError.invalidJournal }
    }

    private func write(_ data: Data, to path: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        var options: Data.WritingOptions = .atomic
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: attributes)
        try data.write(to: path, options: options)
    }

    fileprivate func save(_ plan: PendingHealthPlan, key: String) throws {
        try write(JSONEncoder().encode(plan), to: url(key))
    }

    fileprivate func remove(_ key: String) throws { try FileManager.default.removeItem(at: url(key)) }

    fileprivate func ownsLegacy(_ account: String) throws -> Bool {
        let path = directory.appendingPathComponent("legacy-owner.json")
        if FileManager.default.fileExists(atPath: path.path) {
            return try JSONDecoder().decode(String.self, from: Data(contentsOf: path)) == account
        }
        // Legacy records didn't contain an account. Bind adoption to the first upgraded account.
        try write(JSONEncoder().encode(account), to: path)
        return true
    }
}

actor HealthSyncCoordinator {
    private let store: any HealthSyncStore
    private let journal: PendingSyncJournal
    private var running = false

    init(store: any HealthSyncStore, journal: PendingSyncJournal = .applicationDefault) {
        self.store = store
        self.journal = journal
    }

    static func accountNamespace(_ account: String) -> String {
        HealthSyncSample.digest(Data(account.utf8))
    }

    static func identifier(account: String, sample: HealthSyncSample) -> String {
        "healthmi.v2/\(accountNamespace(account))/\(sample.type)/\(sample.key)"
    }

    func resume(account: String, dataType: String) async throws {
        guard !running else { throw HealthSyncError.busy }
        running = true
        defer { running = false }
        try await recover(account: account, dataType: dataType)
    }

    private func recover(account: String, dataType: String) async throws {
        let namespace = Self.accountNamespace(account)
        let key = namespace + "/" + dataType
        if let plan = try journal.read(key) {
            guard plan.account == namespace, plan.dataType == dataType else {
                throw HealthSyncError.invalidJournal
            }
            try await execute(plan)
            try journal.remove(key)
        }
    }

    func synchronize(_ input: [HealthSyncSample], account: String, dataType: String,
                     window: SyncWindow) async throws -> HealthSyncResult {
        guard !running else { throw HealthSyncError.busy }
        running = true
        defer { running = false }
        try await recover(account: account, dataType: dataType)
        try Task.checkCancellation()
        let namespace = Self.accountNamespace(account)
        let prefix = "healthmi.v2/\(namespace)/"

        var unique: [String: HealthSyncSample] = [:]
        for sample in input {
            let id = prefix + sample.type + "/" + sample.key
            let hash = try sample.fingerprint()
            if let previous = unique[id], try previous.fingerprint() != hash {
                throw HealthSyncError.conflictingSample(sample.key)
            }
            unique[id] = sample
        }
        let samples = unique.sorted { $0.key < $1.key }.map(\.value)
        guard !samples.isEmpty else { return HealthSyncResult() }
        let start = min(window.start, samples.map(\.start).min()!)
        let end = max(window.end, samples.map(\.end).max()!)
        var types = Set(samples.map(\.type))
        if samples.contains(where: { $0.kind == .workout }) {
            types.insert("HKQuantityTypeIdentifierHeartRate")
        }
        let stored = try await store.load(types: types, start: start, end: end)
        try Task.checkCancellation()
        let canAdoptLegacy = try journal.ownsLegacy(namespace)
        var current: [String: StoredHealthSample] = [:]
        for sample in stored {
            if let id = sample.syncID, id.hasPrefix(prefix),
               sample.version > (current[id]?.version ?? -1) { current[id] = sample }
        }

        var result = HealthSyncResult()
        let versioned = try samples.map { sample -> VersionedHealthSample in
            let id = prefix + sample.type + "/" + sample.key
            let hash = try sample.fingerprint()
            let previous = current[id]
            let unchanged = previous?.fingerprint == hash
            let version = unchanged ? previous!.version : (previous?.version ?? 0) + 1
            if unchanged { result.skipped += 1 }
            else if previous != nil { result.updated += 1 }
            else { result.added += 1 }
            return VersionedHealthSample(sample: sample, syncID: id, version: version,
                                         fingerprint: hash, needsWrite: !unchanged)
        }
        let wanted = Set(versioned.map(\.syncID))
        let scopes = Set(samples.filter(\.replacesScope).compactMap(\.scope))
        let aliases = Set(samples.flatMap { [$0.key] + $0.legacyKeys })
        var legacyBases: [String: Bool] = [:]
        if canAdoptLegacy {
            for sample in samples {
                guard let scopePrefix = sample.legacyScopePrefix else { continue }
                for old in stored where old.syncID == nil && old.type == sample.type && old.start == sample.start {
                    guard let id = old.externalID, id.hasPrefix(scopePrefix) else { continue }
                    if sample.kind == .category, sample.replacesScope, id.hasSuffix("_inBed") {
                        legacyBases[String(id.dropLast("_inBed".count))] = true
                    } else if sample.kind != .category {
                        legacyBases[id] = false
                    }
                }
            }
        }
        let obsolete = stored.filter { old in
            if let id = old.syncID {
                return id.hasPrefix(prefix) && old.scope.map(scopes.contains) == true && !wanted.contains(id)
            }
            guard canAdoptLegacy, let id = old.externalID else { return false }
            if aliases.contains(id) { return true }
            return legacyBases.contains { id == $0.key || ($0.value && id.hasPrefix($0.key + "_")) }
        }
        result.removed = obsolete.count
        guard versioned.contains(where: \.needsWrite) || !obsolete.isEmpty else { return result }
        let plan = PendingHealthPlan(account: namespace, dataType: dataType, start: start, end: end,
                                     samples: versioned, obsolete: obsolete, result: result)
        let key = namespace + "/" + dataType
        try journal.save(plan, key: key)
        try await execute(plan)
        try journal.remove(key)
        return result
    }

    private func execute(_ plan: PendingHealthPlan) async throws {
        try Task.checkCancellation()
        try await store.save(plan.samples)
        let types = Set(plan.samples.map { $0.sample.type }).union(plan.obsolete.map(\.type))
        let written = try await store.load(types: types, start: plan.start, end: plan.end)
        let byID = Dictionary(written.compactMap { sample in
            sample.syncID.map { ($0, sample) }
        }, uniquingKeysWith: { $0.version >= $1.version ? $0 : $1 })
        for expected in plan.samples {
            guard let saved = byID[expected.syncID], saved.version >= expected.version,
                  saved.fingerprint == expected.fingerprint else { throw HealthSyncError.verificationFailed }
        }
        try Task.checkCancellation()
        // Exact owned UUIDs only. Never infer a server deletion from a missing response row.
        try await store.delete(plan.obsolete)
        if !plan.obsolete.isEmpty {
            let remaining = try await store.load(types: types, start: plan.start, end: plan.end)
            let obsoleteIDs = Set(plan.obsolete.map(\.uuid))
            guard !remaining.contains(where: { obsoleteIDs.contains($0.uuid) }) else {
                throw HealthSyncError.verificationFailed
            }
        }
    }
}
