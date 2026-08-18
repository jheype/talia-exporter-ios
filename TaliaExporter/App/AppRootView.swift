import SwiftUI

struct AppRootView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch appModel.route {
            case .loading:
                LaunchView()
            case .signedOut:
                SignInView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .connection:
                ConnectionFlowView()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .main:
                MainTabView()
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.38), value: appModel.route)
        .task {
            await appModel.bootstrap()
        }
        .task(id: "\(appModel.route)-\(scenePhase)") {
            guard appModel.route == .main, scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, scenePhase == .active else { return }
                await appModel.refreshDashboard(showErrors: false)
            }
        }
        .alert(item: $appModel.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

private struct LaunchView: View {
    var body: some View {
        ZStack {
            Color.taliaBackground.ignoresSafeArea()

            VStack(spacing: 22) {
                BrandLockup()
                ProgressView()
                    .tint(Color.taliaBlue)
            }
        }
    }
}

private struct MainTabView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        TabView(selection: $appModel.selectedTab) {
            HomeView()
                .tag(MainTab.home)
                .tabItem {
                    Label("Home", systemImage: appModel.selectedTab == .home ? "house.fill" : "house")
                }

            GroupsView()
                .tag(MainTab.groups)
                .tabItem {
                    Label("Groups", systemImage: appModel.selectedTab == .groups ? "person.2.fill" : "person.2")
                }

            ActivityView()
                .tag(MainTab.activity)
                .tabItem {
                    Label("Activity", systemImage: appModel.selectedTab == .activity ? "clock.fill" : "clock")
                }

            SettingsView()
                .tag(MainTab.settings)
                .tabItem {
                    Label("Settings", systemImage: appModel.selectedTab == .settings ? "gearshape.fill" : "gearshape")
                }
        }
        .tint(Color.taliaBlue)
    }
}

#Preview("App") {
    AppRootView()
        .environmentObject(AppModel.preview())
}
