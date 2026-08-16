import SwiftUI
import UIKit

extension Color {
    static let taliaNavy = Color(red: 51 / 255, green: 77 / 255, blue: 133 / 255)
    static let taliaBlue = Color(red: 91 / 255, green: 135 / 255, blue: 229 / 255)
    static let taliaLive = Color(red: 41 / 255, green: 190 / 255, blue: 104 / 255)

    static let taliaBackground = Color(uiColor: .systemBackground)
    static let taliaGroupedBackground = Color(uiColor: .systemGroupedBackground)
    static let taliaSecondaryBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let taliaTertiaryBackground = Color(uiColor: .tertiarySystemGroupedBackground)
    static let taliaSeparator = Color(uiColor: .separator)
    static let taliaSecondaryText = Color(uiColor: .secondaryLabel)
}

enum TaliaLayout {
    static let screenPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 24
    static let cardRadius: CGFloat = 24
    static let compactRadius: CGFloat = 16
}

struct TaliaCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.taliaSecondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: TaliaLayout.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: TaliaLayout.cardRadius, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06),
                        lineWidth: 0.75
                    )
            }
    }
}

extension View {
    func taliaCard(padding: CGFloat = 18) -> some View {
        modifier(TaliaCardModifier(padding: padding))
    }
}

struct TaliaPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                LinearGradient(
                    colors: [.taliaNavy, .taliaBlue],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .opacity(isEnabled ? 1 : 0.45)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct TaliaIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.primary)
            .frame(width: 42, height: 42)
            .background(.thinMaterial)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
