import SwiftUI

struct ConnectionFlowView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var phoneNumber = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.taliaBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    connectionHeader

                    Group {
                        switch appModel.connectionStage {
                        case .intro:
                            ConnectIntroView(onContinue: appModel.advanceFromIntro)
                        case .number:
                            PhoneNumberView(
                                phoneNumber: $phoneNumber,
                                isWorking: appModel.isWorking
                            ) {
                                Task {
                                    await appModel.requestPairingCode(phoneNumber: phoneNumber)
                                }
                            }
                        case .pairing:
                            PairingCodeView(
                                code: appModel.pairingCode ?? "",
                                expiresAt: appModel.pairingExpiresAt,
                                status: appModel.session?.status ?? .pairing
                            ) {
                                Task { await appModel.checkPairingStatusNow() }
                            }
                        case .groups:
                            ConnectionGroupSelectionView {
                                Task { await appModel.completeConnection() }
                            }
                        }
                    }
                    .id(appModel.connectionStage)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var connectionHeader: some View {
        HStack {
            if appModel.connectionStage != .intro {
                Button(action: appModel.goBackInConnectionFlow) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(TaliaIconButtonStyle())
                .accessibilityLabel("Back")
            } else {
                BrandLockup(compact: true)
            }

            Spacer()

            Text("\(appModel.connectionStage.rawValue + 1) of 4")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, TaliaLayout.screenPadding)
        .padding(.top, 8)
    }
}

private struct ConnectIntroView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            Image(systemName: "link.circle.fill")
                .font(.system(size: 60))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.taliaBlue)

            Text("Connect your work WhatsApp")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .tracking(-0.8)
                .padding(.top, 26)

            VStack(alignment: .leading, spacing: 14) {
                ConnectionBenefit(icon: "iphone.gen3", text: "Complete the setup from this iPhone")
                ConnectionBenefit(icon: "person.2.fill", text: "Choose the groups you want to capture")
                ConnectionBenefit(icon: "arrow.triangle.2.circlepath", text: "Capture continues after the app is closed")
            }
            .padding(.top, 28)

            Spacer()

            Button("Connect WhatsApp", action: onContinue)
                .buttonStyle(TaliaPrimaryButtonStyle())
        }
        .padding(TaliaLayout.screenPadding)
    }
}

private struct ConnectionBenefit: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.taliaBlue)
                .frame(width: 26)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PhoneNumberView: View {
    @Binding var phoneNumber: String
    let isWorking: Bool
    let onContinue: () -> Void
    @FocusState private var fieldIsFocused: Bool

    private var canContinue: Bool {
        phoneNumber.filter(\.isNumber).count >= 8 && !isWorking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            Text("Enter your WhatsApp number")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .tracking(-0.7)

            Text("Include the country code used by the WhatsApp account.")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 12)

            TextField("+44 7700 900123", text: $phoneNumber)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .font(.title3.weight(.semibold))
                .focused($fieldIsFocused)
                .padding(.horizontal, 16)
                .frame(height: 58)
                .background(Color.taliaSecondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                }
                .padding(.top, 28)

            Spacer()

            Button(action: onContinue) {
                Group {
                    if isWorking {
                        ProgressView().tint(.white)
                    } else {
                        Text("Generate pairing code")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TaliaPrimaryButtonStyle())
            .disabled(!canContinue)
        }
        .padding(TaliaLayout.screenPadding)
        .onAppear { fieldIsFocused = true }
    }
}

private struct PairingCodeView: View {
    let code: String
    let expiresAt: Date?
    let status: ExporterSessionStatus
    let onCheck: () -> Void

    private var digits: [Character] {
        Array(code.filter(\.isNumber))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Link this device")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .tracking(-0.7)
                    .padding(.top, 54)

                Text("Open WhatsApp, then go to Settings → Linked Devices → Link with phone number.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .padding(.top, 12)

                codeView
                    .padding(.top, 30)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 10) {
                        if status == .connecting {
                            ProgressView()
                        } else {
                            Image(systemName: "timer")
                        }
                        Text(countdownText(at: context.date))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 24)

                Button("Check link", action: onCheck)
                    .buttonStyle(TaliaPrimaryButtonStyle())
                    .padding(.top, 44)
            }
            .padding(TaliaLayout.screenPadding)
        }
    }

    @ViewBuilder
    private var codeView: some View {
        if digits.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(height: 54)
        } else {
            GeometryReader { proxy in
                let spacing: CGFloat = 6
                let separatorWidth: CGFloat = 14
                let digitWidth = max(
                    24,
                    (proxy.size.width - separatorWidth - (spacing * 8)) / 8
                )

                HStack(spacing: spacing) {
                    ForEach(digits.indices, id: \.self) { index in
                        Text(String(digits[index]))
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .frame(width: digitWidth, height: 54)
                            .background(Color.taliaSecondaryBackground)
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: 12,
                                    style: .continuous
                                )
                            )

                        if index == 3 && digits.count > 4 {
                            Text("–")
                                .foregroundStyle(.tertiary)
                                .frame(width: separatorWidth)
                        }
                    }
                }
                .frame(width: proxy.size.width, alignment: .leading)
            }
            .frame(height: 54)
            .textSelection(.enabled)
        }
    }

    private func countdownText(at date: Date) -> String {
        guard let expiresAt else { return "Waiting for WhatsApp" }
        let remaining = max(0, Int(expiresAt.timeIntervalSince(date)))
        return "Code expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))"
    }
}

private struct ConnectionGroupSelectionView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var searchText = ""
    let onComplete: () -> Void

    private var filteredGroups: [ExportGroup] {
        guard !searchText.isEmpty else { return appModel.groups }
        return appModel.groups.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose groups to capture")
                .font(.system(size: 31, weight: .bold, design: .rounded))
                .tracking(-0.6)
                .padding(.horizontal, TaliaLayout.screenPadding)
                .padding(.top, 28)

            TextField("Search groups", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, TaliaLayout.screenPadding)
                .padding(.top, 16)

            List(filteredGroups) { group in
                Button {
                    appModel.toggleGroup(group)
                } label: {
                    HStack(spacing: 12) {
                        GroupAvatar(initials: group.initials, size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.name).foregroundStyle(.primary)
                            Text(group.category)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: group.isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(group.isSelected ? Color.taliaBlue : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            Button(action: onComplete) {
                Group {
                    if appModel.isWorking {
                        ProgressView().tint(.white)
                    } else {
                        Text("Start capturing \(appModel.selectedGroupsDescription)")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TaliaPrimaryButtonStyle())
            .disabled(appModel.selectedGroupCount == 0 || appModel.isWorking)
            .padding(TaliaLayout.screenPadding)
        }
    }
}

#Preview("Connection") {
    ConnectionFlowView()
        .environmentObject(AppModel.preview(route: .connection))
}
