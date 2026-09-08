import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var showUnlinkConfirmation = false
    @State private var notificationsEnabled = false
    @State private var isChangingNotifications = false

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                captureSection
                appearanceSection
                Section("Calendar") {
                    NavigationLink {
                        CalendarSettingsView(controller: appModel.calendarSync)
                    } label: {
                        Label("Apple Calendar", systemImage: "calendar.badge.clock")
                    }
                }
                widgetsSection
                aboutSection
            }
            .taliaSurface()
            .navigationTitle("Settings")
            .confirmationDialog(
                "Unlink WhatsApp?",
                isPresented: $showUnlinkConfirmation,
                titleVisibility: .visible
            ) {
                Button("Unlink", role: .destructive) {
                    Task { await appModel.unlinkWhatsApp() }
                }
            } message: {
                Text("Capture will stop until the account is linked again.")
            }
            .task {
                notificationsEnabled = await appModel.interruptionAlertsEnabled()
            }
        }
    }

    private var accountSection: some View {
        Section("Talia account") {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.taliaAccent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(appModel.user?.displayName ?? "Talia user")
                        .font(.body.weight(.semibold))

                    Text(appModel.user?.email ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.taliaLive)
            }


        }
    }

    private var captureSection: some View {
        Section("Capture") {
            Toggle(
                isOn: Binding(
                    get: { appModel.captureEnabled },
                    set: { value in Task { await appModel.setCaptureEnabled(value) } }
                )
            ) {
                Label("Capture enabled", systemImage: "dot.radiowaves.left.and.right")
            }
            .tint(Color.taliaAccent)
            .disabled(appModel.isWorking || appModel.session == nil)

            Toggle(isOn: Binding(
                get: { notificationsEnabled },
                set: updateNotifications
            )) {
                Label("Interruption alerts", systemImage: "bell.badge")
            }
            .tint(Color.taliaAccent)
            .disabled(isChangingNotifications)


        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            HStack(spacing: 10) {
                ForEach(AppearanceMode.allCases) { mode in
                    AppearanceChoice(mode: mode, isSelected: appModel.appearance == mode) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            appModel.appearance = mode
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var widgetsSection: some View {
        Section("Widgets") {
            NavigationLink {
                WidgetSettingsView()
            } label: {
                Label("Configure iOS widgets", systemImage: "rectangle.3.group")
            }

            LabeledContent {
                Text(appModel.widgetLastRefreshedAt?.relativeDescription ?? "Not refreshed")
                    .foregroundStyle(.secondary)
            } label: {
                Label("Task and message snapshot", systemImage: "checkmark.rectangle.stack")
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: version)
            if appModel.session != nil {
                Button { showUnlinkConfirmation = true } label: {
                    Label("Unlink WhatsApp", systemImage: "link.badge.plus")
                }.foregroundStyle(.red)
            } else {
                Button("Connect WhatsApp", systemImage: "link") {
                    appModel.connectionStage = .intro
                    appModel.route = .connection
                }
            }
            Button(role: .destructive) {
                Task { await appModel.signOut() }
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            LabeledContent("WhatsApp", value: appModel.session?.phoneNumber ?? "Not linked")
            LabeledContent("Status", value: appModel.session?.status.title ?? "Unavailable")
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private func updateNotifications(_ enabled: Bool) {
        guard !isChangingNotifications else { return }
        isChangingNotifications = true
        Task {
            if enabled {
                notificationsEnabled = await appModel.enableInterruptionAlerts()
            } else {
                await appModel.disableInterruptionAlerts()
                notificationsEnabled = false
            }
            isChangingNotifications = false
        }
    }
}

private struct AppearanceChoice: View {
    let mode: AppearanceMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: mode.systemImage)
                    .font(.title3)

                Text(mode.title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(isSelected ? Color.taliaOnAccent : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 74)
            .background(isSelected ? Color.taliaAccent : Color.taliaTertiaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isSelected ? 0 : 0.07), lineWidth: 0.75)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppModel.preview())
}
