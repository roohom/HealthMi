import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.isConfigured {
                DashboardView()
            } else if HealthSyncSafety.writesPaused {
                ContentUnavailableView("同步暂停", systemImage: "pause.circle",
                                       description: Text("只读检查期间不会更改登录或健康数据。"))
            } else {
                OnboardingView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isConfigured)
    }
}

#Preview {
    RootView()
        .environment(AppModel())
}
