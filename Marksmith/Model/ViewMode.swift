import SwiftUI

enum ViewMode: String, CaseIterable, Identifiable {
    case sideBySide = "Side by Side"
    case editorOnly = "Editor Only"
    case previewOnly = "Preview Only"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .sideBySide: return "rectangle.split.2x1"
        case .editorOnly: return "square.text.square"
        case .previewOnly: return "doc.richtext"
        }
    }

    var localized: String {
        switch self {
        case .sideBySide: return "分栏"
        case .editorOnly: return "仅编辑"
        case .previewOnly: return "仅预览"
        }
    }
}

/// How the preview chooses light/dark styling.
enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"
    var id: String { rawValue }

    func resolved(systemDark: Bool) -> ColorTheme {
        switch self {
        case .system: return systemDark ? .dark : .light
        case .light: return .light
        case .dark: return .dark
        }
    }
}
