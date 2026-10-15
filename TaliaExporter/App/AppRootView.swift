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
        .environmentObject(appModel.workspace)
        .environmentObject(appModel.calendarSync)
        .onOpenURL { appModel.openWorkspaceURL($0) }
        .animation(.snappy(duration: 0.38), value: appModel.route)
        .task {
            await appModel.bootstrap()
        }
        .task(id: "\(appModel.route)-\(scenePhase)-\(appModel.user?.id.uuidString ?? "")") {
            guard appModel.route == .main, scenePhase == .active else { return }
            appModel.workspace.setOwner(appModel.user?.id)
            await appModel.calendarSync.refresh(force: true)
            await appModel.refreshWidgetSnapshot()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, scenePhase == .active else { return }
                await appModel.calendarSync.refresh()
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
                    .tint(Color.taliaAccent)
            }
        }
    }
}

struct MainTabView: View {
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

            TasksView()
                .tag(MainTab.tasks)
                .tabItem {
                    Label("Tasks", systemImage: appModel.selectedTab == .tasks ? "checkmark.square.fill" : "checkmark.square")
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
        .tint(Color.taliaAccent)
    }
}

#Preview("App") {
    AppRootView()
        .environmentObject(AppModel.preview())
}
