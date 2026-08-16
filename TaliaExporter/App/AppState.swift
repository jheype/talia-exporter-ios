import Foundation
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppRoute: Hashable {
    case loading
    case signedOut
    case connection
    case main
}

enum MainTab: Hashable {
    case home
    case groups
    case activity
    case settings
}

enum ConnectionStage: Int, Hashable {
    case intro
    case number
    case pairing
    case groups

    var previous: ConnectionStage {
        switch self {
        case .intro, .number: .intro
        case .pairing: .number
        case .groups: .pairing
        }
    }
}

struct AppAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

