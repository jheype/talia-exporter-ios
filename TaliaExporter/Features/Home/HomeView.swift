import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var showLiveFeed = false

    var body: some View {
        NavigationStack {
            content
            .background(Color.taliaBackground)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showLiveFeed) {
                LiveFeedView()
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TaliaLayout.sectionSpacing) {
                header
                statusCopy
                CapturePulseView(isActive: appModel.captureIsLive)
                summary
                primaryActions
                recentActivity
            }
            .padding(.horizontal, TaliaLayout.screenPadding)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .refreshable {
            await appModel.refreshDashboard()
        }
    }

    private var header: some View {
        HStack {
            BrandLockup(compact: true)

            Spacer()

            Button {
                appModel.selectedTab = .settings
            } label: {
                Image(systemName: "person.crop.circle")
            }
            .buttonStyle(TaliaIconButtonStyle())
            .accessibilityLabel("Open settings")
        }
    }

    private var statusCopy: some View {
        VStack(alignment: .leading, spacing: 10) {
            LivePill(title: statusPillTitle, colour: appModel.captureStatusColour)

            Text(statusTitle)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .tracking(-0.8)

            Text(statusDescription)
            .font(.body)
            .foregroundStyle(.secondary)
            .lineSpacing(3)
        }
    }

    private var statusPillTitle: String {
        switch appModel.session?.status {
        case .reconnecting: "RECONNECTING"
        case .interrupted, .loggedOut: "NEEDS ATTENTION"
        default: appModel.captureIsLive ? "LIVE CAPTURE" : "PAUSED"
        }
    }

    private var statusTitle: String {
        switch appModel.session?.status {
        case .reconnecting: "Restoring connection"
        case .interrupted, .loggedOut: "Connection interrupted"
        default: appModel.captureIsLive ? "Capture is active" : "Capture is paused"
        }
    }

    private var statusDescription: String {
        switch appModel.session?.status {
        case .reconnecting:
            "The service is reconnecting to WhatsApp automatically."
        case .interrupted, .loggedOut:
            "Open settings to review the WhatsApp connection."
        default:
            appModel.captureIsLive
                ? "Messages continue synchronising when the app is closed."
                : "Resume capture to keep selected groups in sync."
        }
    }

    private var summary: some View {
        HStack(spacing: 0) {
            SummaryMetric(
                systemImage: "person.2.fill",
                value: "\(appModel.selectedGroupCount)",
                label: appModel.selectedGroupCount == 1 ? "group" : "groups"
            )

            Divider()
                .frame(height: 54)
                .padding(.horizontal, 18)

            SummaryMetric(
                systemImage: "clock.arrow.circlepath",
                value: appModel.session?.lastSynchronisedAt?.relativeDescription ?? "Pending",
                label: "Last sync"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .taliaCard(padding: 18)
    }

    private var primaryActions: some View {
        VStack(spacing: 14) {
            Button {
                appModel.selectedTab = .groups
            } label: {
                HStack {
                    Text("Manage groups")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .padding(.horizontal, 20)
            }
            .buttonStyle(TaliaPrimaryButtonStyle())

            Button {
                showLiveFeed = true
            } label: {
                Label("Open live feed", systemImage: "text.bubble")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.taliaBlue)
        }
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent activity")
                    .font(.title3.bold())

                Spacer()

                Button("View all") {
                    appModel.selectedTab = .activity
                }
                .font(.subheadline.weight(.semibold))
            }

            VStack(spacing: 0) {
                ForEach(recentEvents) { event in
                    ActivityRow(event: event)

                    if event.id != recentEvents.last?.id {
                        Divider().padding(.leading, 58)
                    }
                }
            }
            .taliaCard(padding: 14)
        }
    }

    private var recentEvents: [CaptureEvent] {
        Array(appModel.events.prefix(2))
    }
}

private struct CapturePulseView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isActive: Bool
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                PulseRing(
                    index: index,
                    isAnimating: animate && isActive,
                    reduceMotion: reduceMotion
                )
            }

            CaptureStatusButton(isActive: isActive)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 230)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isActive ? "Capture is active" : "Capture is paused")
        .onAppear { animate = true }
    }
}

private struct PulseRing: View {
    let index: Int
    let isAnimating: Bool
    let reduceMotion: Bool

    private var diameter: CGFloat {
        92 + CGFloat(index * 42)
    }

    private var ringOpacity: Double {
        Swift.max(0.08, 0.34 - (Double(index) * 0.07))
    }

    private var animation: Animation {
        if reduceMotion {
            return .default
        }

        let duration = 1.9 + (Double(index) * 0.18)
        return .easeInOut(duration: duration).repeatForever(autoreverses: true)
    }

    var body: some View {
        Circle()
            .stroke(
                Color.taliaBlue.opacity(ringOpacity),
                lineWidth: index == 0 ? 1.5 : 1
            )
            .frame(width: diameter, height: diameter)
            .scaleEffect(isAnimating ? 1.035 : 0.98)
            .opacity(isAnimating ? 0.60 : 1)
            .animation(animation, value: isAnimating)
    }
}

private struct CaptureStatusButton: View {
    let isActive: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(Color.taliaSecondaryBackground)
                .frame(width: 82, height: 82)
                .overlay {
                    Circle().strokeBorder(Color.taliaBlue.opacity(0.32), lineWidth: 1)
                }

            Image(systemName: isActive ? "message.fill" : "pause.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.taliaBlue)
                .frame(width: 82, height: 82)

            Circle()
                .fill(isActive ? Color.taliaLive : Color.orange)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.taliaSecondaryBackground, lineWidth: 3))
                .offset(x: -2, y: 4)
        }
    }
}

private struct SummaryMetric: View {
    let systemImage: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.taliaBlue)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ActivityRow: View {
    let event: CaptureEvent

    var body: some View {
        HStack(spacing: 12) {
            GroupAvatar(initials: event.groupName.initials, size: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.groupName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(event.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Text(event.relativeTime)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
    }
}

private extension String {
    var initials: String {
        split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
            .map(String.init)
            .joined()
            .uppercased()
    }
}

#Preview("Home — Light") {
    HomeView()
        .environmentObject(AppModel.preview())
        .preferredColorScheme(.light)
}

#Preview("Home — Dark") {
    HomeView()
        .environmentObject(AppModel.preview())
        .preferredColorScheme(.dark)
}
