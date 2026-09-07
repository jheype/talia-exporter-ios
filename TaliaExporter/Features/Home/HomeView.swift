import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var showLiveFeed = false
    private var snapshot: ExporterWidgetSnapshot? { appModel.widgetSnapshot }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        BrandLockup(compact: true)
                        Spacer()
                        Button { appModel.selectedTab = .settings } label: {
                            GroupAvatar(initials: (appModel.user?.displayName ?? "T").workInitials, size: 44)
                        }.buttonStyle(.plain).accessibilityLabel("Open settings")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Overview").font(.system(size: 34, weight: .bold)).tracking(-0.8)
                        Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide).year())
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    captureCard
                    if let snapshot {
                        HStack(spacing: 12) {
                            metric("\(snapshot.summary.totalOpen)", label: "Open tasks", symbol: "checklist") {
                                openTasks()
                            }
                            metric("\(snapshot.summary.dueToday)", label: "Due today", symbol: "calendar") {
                                openTasks(due: "today")
                            }
                        }
                        if !snapshot.tasks.isEmpty {
                            sectionHeading("Your next task") { openTasks() }
                            VStack(spacing: 16) {
                                ForEach(snapshot.tasks.prefix(1)) { task in
                                    Button {
                                        openTasks(search: task.publicID, status: WorkStatus(rawValue: task.status) ?? .inProgress)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 10) {
                                            HStack {
                                                Text(task.title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
                                                Spacer()
                                                Text("\(task.progress)%").font(.caption).foregroundStyle(.secondary)
                                            }
                                            ProgressView(value: Double(min(100, max(0, task.progress))), total: 100).tint(Color.taliaAccent)
                                            Text(task.assigneeName ?? "Unassigned").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.buttonStyle(.plain)
                                    if task.id != snapshot.tasks.prefix(1).last?.id { Divider() }
                                }
                            }.taliaCard()
                        }
                    }
                    sectionHeading("Recent activity") { appModel.selectedTab = .activity }
                    if appModel.events.isEmpty {
                        Text("New capture events will appear here.").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(appModel.events.prefix(3)) { event in ActivityRow(event: event) }
                        }.taliaCard()
                    }
                }.padding(20)
            }
            .taliaSurface().toolbar(.hidden, for: .navigationBar)
            .refreshable { await appModel.refreshDashboard(); await appModel.refreshWidgetSnapshot(force: true) }
            .sheet(isPresented: $showLiveFeed) { LiveFeedView().presentationDragIndicator(.visible) }
        }
    }

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                LivePill(title: appModel.session == nil ? "NOT LINKED" : appModel.compactCaptureStatus,
                         colour: appModel.captureStatusColour)
                Spacer()
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.secondary)
            }
            Text(appModel.session == nil ? "Connect WhatsApp" : appModel.captureIsLive ? "Capture is active" : appModel.session?.status == .reconnecting ? "Restoring connection" : "Capture is paused")
                .font(.title2.bold())
            if let coverage = snapshot?.ukChatsCoverage {
                VStack(alignment: .leading, spacing: 4) {
                    Text(coverage.captured.formatted()).font(.system(size: 40, weight: .bold)).monospacedDigit()
                    Text("messages captured · \(coverage.period.title.lowercased())").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Label("\(appModel.selectedGroupCount) groups", systemImage: "person.2")
                Spacer()
                Text("Synced \(appModel.session?.lastSynchronisedAt?.relativeDescription ?? "—")")
            }.font(.caption).foregroundStyle(.secondary)
            if appModel.session == nil || appModel.session?.status == .loggedOut {
                Button("Connect WhatsApp") { appModel.connectionStage = .intro; appModel.route = .connection }
                    .buttonStyle(TaliaPrimaryButtonStyle())
            } else {
                HStack(spacing: 12) {
                    Button(appModel.captureEnabled ? "Pause" : "Resume", systemImage: appModel.captureEnabled ? "pause.fill" : "play.fill") {
                        Task { await appModel.setCaptureEnabled(!appModel.captureEnabled) }
                    }.buttonStyle(TaliaSecondaryButtonStyle()).disabled(appModel.isWorking)
                    Button { showLiveFeed = true } label: {
                        Label("Live feed", systemImage: "arrow.up.right").frame(maxWidth: .infinity)
                    }.buttonStyle(TaliaSecondaryButtonStyle())
                }
            }
        }.taliaCard()
    }

    private func metric(_ value: String, label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol).font(.body).foregroundStyle(.secondary)
                Text(value).font(.system(size: 32, weight: .semibold)).monospacedDigit()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).taliaCard()
        }.buttonStyle(.plain)
    }

    private func sectionHeading(_ title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.title3.bold())
            Spacer()
            Button("View all", action: action).font(.caption.weight(.semibold))
        }
    }

    private func openTasks(search: String = "", status: WorkStatus = .inProgress, due: String = "") {
        appModel.workspace.section = .board
        var filters = WorkFilters()
        filters.search = search; filters.status = status; filters.due = due
        appModel.workspace.filters = filters
        appModel.selectedTab = .tasks
    }
}

struct ActivityRow: View {
    let event: CaptureEvent
    var body: some View {
        HStack(spacing: 12) {
            GroupAvatar(initials: event.groupName.workInitials, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.groupName).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(event.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(event.relativeTime).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 10)
    }
}

