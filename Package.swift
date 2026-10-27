// swift-tools-version: 6.0
import PackageDescription

// Run the synchronization regressions on macOS without a simulator, Xiaomi login or Health database.
let package = Package(
    name: "HealthMiCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    targets: [
        .target(name: "HealthMiCore", path: "HealthMi", exclude: [
            "App", "Health", "MiFitness/MiAPIClient.swift", "MiFitness/MiCrypto.swift",
            "MiFitness/MiRegion.swift", "MiFitness/MiSession.swift", "MiFitness/MiWebLogin.swift",
            "Support/HealthMi.entitlements", "Support/Info.plist", "Support/NotificationManager.swift",
            "Sync/BackgroundSync.swift", "Sync/MigrationPlan.swift", "Sync/SyncEngine.swift", "Sync/SyncLogEntry.swift",
        ], sources: [
            "MiFitness/MiModels.swift", "MiFitness/MiParser.swift",
            "Sync/SyncWindow.swift", "Sync/HealthSync.swift",
            "Sync/SyncStateStore.swift", "Sync/StressStore.swift", "Support/AppLog.swift",
        ]),
        .testTarget(name: "HealthMiCoreTests", dependencies: ["HealthMiCore"], path: "HealthMiTests", exclude: [
            "MiCryptoTests.swift", "MiWebLoginTests.swift", "SyncEngineTests.swift",
            "TypeMapperTests.swift", "CloudContractTests.swift",
        ], sources: [
            "SyncReliabilityTests.swift", "MiParserTests.swift", "SyncStateStoreTests.swift",
        ]),
    ]
)
