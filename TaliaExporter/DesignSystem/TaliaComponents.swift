import SwiftUI

struct BrandLockup: View {
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 2) {
            Text("TALIA")
                .font(.system(size: compact ? 17 : 21, weight: .semibold, design: .rounded))
                .tracking(compact ? 4 : 5)
                .foregroundStyle(.primary)

            Text("EXPORTER")
                .font(.system(size: compact ? 9 : 11, weight: .semibold, design: .rounded))
                .tracking(compact ? 2.4 : 3.2)
                .foregroundStyle(Color.taliaBlue)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Talia Exporter")
    }
}

struct LivePill: View {
    let title: String
    var colour: Color = .taliaLive

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(colour)
                .frame(width: 8, height: 8)

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .clipShape(Capsule())
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        }
    }
}

struct GroupAvatar: View {
    let initials: String
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.taliaBlue.opacity(0.12))

            Text(initials)
                .font(.system(size: size * 0.28, weight: .bold, design: .rounded))
                .foregroundStyle(Color.taliaBlue)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(message)
        )
    }
}
