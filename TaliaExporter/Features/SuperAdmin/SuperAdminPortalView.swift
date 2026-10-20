import SwiftUI

struct MainWorkspaceView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var notifications = SANotificationRouter.shared
    private var showingAdmin: Bool { appModel.selectedWorkspace == .superAdmin }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(showingAdmin ? "SA Portal" : "Talia Exporter", systemImage: showingAdmin ? "checkmark.shield" : "arrow.down.message")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    let enteringAdmin = !showingAdmin
                    appModel.selectedWorkspace = enteringAdmin ? .superAdmin : .exporter
                    if enteringAdmin { appModel.superAdmin.start() }
                } label: {
                    Label(showingAdmin ? "Exporter" : "SA Portal", systemImage: "arrow.left.arrow.right")
                        .font(.subheadline.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Color.taliaSecondaryBackground, in: Capsule())
                }.buttonStyle(.plain).accessibilityIdentifier("workspace-switcher")
            }.padding(.horizontal, 20).padding(.vertical, 8)
            Divider()
            ZStack {
                MainTabView().opacity(showingAdmin ? 0 : 1).allowsHitTesting(!showingAdmin).accessibilityHidden(showingAdmin)
                if showingAdmin { SuperAdminPortalView(store: appModel.superAdmin) }
            }
        }.background(Color.taliaBackground)
        .overlay {
            if showingAdmin && scenePhase != .active {
                ZStack { Color.taliaBackground.ignoresSafeArea(); Label("SA Portal", systemImage: "lock.shield").font(.title3.weight(.semibold)) }
            }
        }
        .onReceive(notifications.$pendingAlertID) { id in
            guard let id else { return }
            appModel.selectedWorkspace = .superAdmin; appModel.superAdmin.openAlert(id)
            notifications.pendingAlertID = nil; appModel.superAdmin.start()
        }
    }
}

struct SuperAdminPortalView: View {
    @ObservedObject var store: SuperAdminPortalStore
    var body: some View {
        Group {
            if store.phase == .ready {
                TabView(selection: $store.selectedTab) {
                    NavigationStack { SASectionView(store: store, section: .overview) }
                        .tabItem { Label("Overview", systemImage: "square.grid.2x2") }.tag(0)
                    NavigationStack {
                        SADatasetView(store: store, dataset: .alerts)
                            .navigationTitle("Security alerts")
                            .navigationDestination(isPresented: Binding(get: { store.alertToOpen != nil }, set: { if !$0 { store.alertToOpen = nil } })) {
                                if let id = store.alertToOpen {
                                    SARecordDetail(store: store, record: .object(["id": .string(id), "title": .string("Security alert")]), kind: .alert).id(id)
                                }
                            }
                    }.tabItem { Label("Alerts", systemImage: "bell.badge") }.tag(1)
                    NavigationStack {
                        List {
                            ForEach(SuperAdminSection.allCases.filter { $0 != .overview && $0 != .security }) { section in
                                NavigationLink { SASectionView(store: store, section: section) } label: {
                                    Label(section.title, systemImage: section.symbol).padding(.vertical, 7)
                                }.listRowBackground(Color.taliaSecondaryBackground)
                            }
                        }.taliaSurface().navigationTitle("Manage")
                    }.tabItem { Label("Manage", systemImage: "slider.horizontal.3") }.tag(2)
                    NavigationStack { SASecurityView(store: store) }
                        .tabItem { Label("Security", systemImage: "lock.shield") }.tag(3)
                }.tint(.taliaAccent).id(store.sessionRevision)
            } else { SALoginView(store: store) }
        }
        .task { await store.resume() }
    }
}

private struct SALoginView: View {
    @ObservedObject var store: SuperAdminPortalStore
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: "lock.shield").font(.system(size: 38)).padding(.top, 32)
                    Text(store.phase == .enrolment ? "Set up your authenticator" : "Super Admin").font(.largeTitle.bold())
                    Text("Manage Talia and review security alerts from your iPhone.").foregroundStyle(.secondary)
                    if store.phase == .loading { ProgressView("Checking access…") }
                    else if store.phase == .challenge {
                        Text(store.challengePrompt)
                        TextField("Six-digit code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode).textFieldStyle(.roundedBorder)
                        Button("Verify") { Task { await store.verify(code: code); code = "" } }.buttonStyle(TaliaPrimaryButtonStyle()).disabled(store.busy || code.count != 6)
                    } else if store.phase == .enrolment {
                        if store.enrolment.isNull {
                            SecureField("Confirm your Talia password", text: $password).textContentType(.password).textFieldStyle(.roundedBorder)
                            Button("Set up authenticator") { Task { await store.enrol(password: password); password = "" } }.buttonStyle(TaliaPrimaryButtonStyle()).disabled(store.busy || password.isEmpty)
                        } else {
                            Text("Add this setup key to your authenticator, then enter its six-digit code.")
                            Text(store.enrolment["secret"].text).font(.system(.body, design: .monospaced)).textSelection(.enabled).taliaCard()
                            TextField("Six-digit code", text: $code).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                            Button("Confirm authenticator") { Task { await store.verifyEnrolment(code: code); code = "" } }.buttonStyle(TaliaPrimaryButtonStyle()).disabled(store.busy || code.count != 6)
                        }
                    } else {
                        VStack(spacing: 16) {
                            TextField("Talia email", text: $email).keyboardType(.emailAddress).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Divider()
                            SecureField("Talia password", text: $password).textContentType(.password)
                        }.taliaCard()
                        Text("Use your Talia Super Admin account. Your authenticator will be required.").font(.footnote).foregroundStyle(.secondary)
                        Button("Sign in to SA Portal") { Task { await store.signIn(email: email, password: password); password = "" } }.buttonStyle(TaliaPrimaryButtonStyle()).disabled(store.busy || email.isEmpty || password.isEmpty)
                    }
                    if store.busy { ProgressView() }
                    if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
                    if let notice = store.notice { Text(notice).foregroundStyle(.secondary) }
                    if store.phase == .challenge || store.phase == .enrolment {
                        Button("Back to sign in") { Task { await store.signOut() } }.disabled(store.busy)
                    }
                }.padding(24)
            }.background(Color.taliaBackground)
        }.tint(.taliaAccent)
        .onDisappear { password = ""; code = "" }
    }
}

struct SASecurityView: View {
    @ObservedObject var store: SuperAdminPortalStore
    @Environment(\.openURL) private var openURL
    @State private var action: SAAction?
    @State private var signingOut = false
    @State private var testingPush = false
    @State private var pushTestResult: SAPushTestResult?
    var body: some View {
        List {
            Section("This iPhone") {
                Label(store.pushStatus, systemImage: store.pushEnabled ? "bell.badge" : "bell.slash")
                Picker("Notify me about", selection: $store.minimumSeverity) {
                    Text("High and critical risk").tag("high")
                    Text("Critical risk only").tag("critical")
                }.disabled(store.pushEnabled)
                if store.pushEnabled {
                    Button {
                        guard !testingPush else { return }
                        let scope = store.sessionRevision
                        testingPush = true
                        pushTestResult = nil
                        Task {
                            let result = await store.testPush()
                            testingPush = false
                            guard scope == store.sessionRevision else { return }
                            pushTestResult = result
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if testingPush { ProgressView() }
                            Text(testingPush ? "Sending test…" : "Send a test notification")
                        }
                    }.disabled(testingPush)
                    Button("Turn off security alerts", role: .destructive) { Task { await store.disablePush() } }
                } else { Button("Enable security alerts") { Task { await store.enablePush() } } }
                Button("iPhone notification settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
            }
            Section {
                Text("Alerts cover high-risk access, scanners, rate-limit abuse and repeated rejected sign-ins detected by Talia. Similar events are grouped. Tap a notification to inspect the incident.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Admin account") {
                LabeledContent("Signed in", value: store.email)
                Label("Authenticator verified", systemImage: "checkmark.shield")
                Button("Disable authenticator", role: .destructive) {
                    action = .init("Disable authenticator", "auth/mfa/disable", fields: [.init("password", "Current password", kind: .password), .init("code", "Authenticator code")], warning: "This removes MFA and ends access to SA Portal until you enrol again.")
                }
                Button("Sign out of SA Portal", role: .destructive) { signingOut = true }
            }
            if store.busy { ProgressView() }
            if let error = store.errorMessage { Section { Text(error).foregroundStyle(.red) } }
            if let notice = store.notice { Section { Text(notice) } }
        }.taliaSurface().navigationTitle("Security").disabled(store.busy)
        .alert(item: $pushTestResult) { result in
            Alert(title: Text(result.title), message: Text(result.message), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog("Sign out of SA Portal and unregister this phone?", isPresented: $signingOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await store.signOut() } }
        }
        .sheet(item: $action) { action in SAActionView(store: store, action: action) { Task { await store.signOut() } } }
    }
}
