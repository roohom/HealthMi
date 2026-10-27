import SwiftData
import SwiftUI

@main
struct HealthMiApp: App {
    let modelContainer: ModelContainer

    @State private var model = AppModel()

    init() {
        HealthSyncSafety.prepareForLaunch()
        let schema = Schema([SyncState.self, StressRecord.self, SyncLogEntry.self])
        let configuration = ModelConfiguration(schema: schema)
        do {
            modelContainer = try ModelContainer(
                for: schema, migrationPlan: MigrationPlan.self,
                configurations: [configuration]
            )
        } catch {
            fatalError("无法初始化 SwiftData 容器：\(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            if HealthSyncSafety.writesPaused {
                ContentUnavailableView("云端只读验收", systemImage: "checkmark.shield",
                                       description: Text("健康数据同步已暂停，等待验收确认。"))
            } else {
                RootView()
                    .environment(model)
                    .modelContainer(modelContainer)
                    .task {
                        model.bootstrap()
                        await NotificationManager.requestAuthorization()
                        BackgroundSync.register { [model, modelContainer] in
                            let context = modelContainer.mainContext
                            await model.syncAll(modelContext: context, isBackground: true)
                        }
                        BackgroundSync.schedule()
                    }
            }
        }
    }
}
