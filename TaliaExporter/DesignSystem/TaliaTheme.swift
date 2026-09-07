import SwiftUI
import UIKit

extension Color {
    static let taliaAccent = adaptive(light: 0x181818, dark: 0xF4F3EF)
    static let taliaOnAccent = adaptive(light: 0xFFFFFF, dark: 0x151515)
    static let taliaLive = Color(red: 0.40, green: 0.76, blue: 0.46)
    static let taliaBackground = adaptive(light: 0xF8F8F5, dark: 0x151515)
    static let taliaGroupedBackground = taliaBackground
    static let taliaSecondaryBackground = adaptive(light: 0xEEEEEA, dark: 0x242424)
    static let taliaTertiaryBackground = adaptive(light: 0xE5E5E0, dark: 0x303030)
    static let taliaSeparator = adaptive(light: 0xDADAD5, dark: 0x363636)
    static let taliaSecondaryText = adaptive(light: 0x626262, dark: 0xA8A8A8)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }

    init(workHex: String) {
        let hex = workHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = hex.count == 6 ? (UInt32(hex, radix: 16) ?? 0xA8A8A8) : 0xA8A8A8
        self.init(red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

enum TaliaLayout {
    static let screenPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 24
    static let cardRadius: CGFloat = 18
    static let compactRadius: CGFloat = 14
}

struct TaliaCardModifier: ViewModifier {
    let padding: CGFloat
    func body(content: Content) -> some View {
        content.padding(padding)
            .background(Color.taliaSecondaryBackground, in: RoundedRectangle(cornerRadius: TaliaLayout.cardRadius))
            .overlay { RoundedRectangle(cornerRadius: TaliaLayout.cardRadius)
                .strokeBorder(Color.taliaSeparator, lineWidth: 0.5) }
    }
}

extension View {
    func taliaCard(padding: CGFloat = 16) -> some View { modifier(TaliaCardModifier(padding: padding)) }
    func taliaSurface() -> some View {
        scrollContentBackground(.hidden).background(Color.taliaBackground).tint(Color.taliaAccent)
    }
}

struct TaliaPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold))
            .foregroundStyle(Color.taliaOnAccent)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color.taliaAccent.opacity(isEnabled ? 1 : 0.4),
                        in: RoundedRectangle(cornerRadius: 14))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
    }
}

struct TaliaIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold)).foregroundStyle(Color.taliaAccent)
            .frame(width: 44, height: 44)
            .background(Color.taliaSecondaryBackground, in: RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct TaliaSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold)).foregroundStyle(Color.taliaAccent)
            .frame(minHeight: 44).padding(.horizontal, 14)
            .background(Color.taliaSecondaryBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.taliaSeparator, lineWidth: 1) }
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
    }
}
