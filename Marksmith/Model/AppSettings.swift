import SwiftUI
import AppKit
import Combine

/// Centralised, persisted user preferences.
/// Adding a new setting = one `@AppStorage` property here plus a control in
/// `SettingsView`; no other layer needs to change.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("marksmith.editorFontSize") var editorFontSize: Double = 14
    @AppStorage("marksmith.editorFontName") var editorFontName: String = "SF Mono"
    @AppStorage("marksmith.wordWrap") var wordWrap: Bool = true
    @AppStorage("marksmith.showLineNumbers") var showLineNumbers: Bool = false
    @AppStorage("marksmith.vimModeEnabled") var vimModeEnabled: Bool = false
    @AppStorage("marksmith.defaultViewMode") var defaultViewModeRaw: String = ViewMode.sideBySide.rawValue
    @AppStorage("marksmith.appearance") var appearanceRaw: String = AppearanceSetting.system.rawValue
    @AppStorage("marksmith.previewDebounceMs") var previewDebounceMs: Double = 250
    @AppStorage("marksmith.syncScroll") var syncScroll: Bool = false

    var defaultViewMode: ViewMode {
        get { ViewMode(rawValue: defaultViewModeRaw) ?? .sideBySide }
        set { defaultViewModeRaw = newValue.rawValue }
    }

    var appearance: AppearanceSetting {
        get { AppearanceSetting(rawValue: appearanceRaw) ?? .system }
        set { appearanceRaw = newValue.rawValue }
    }

    static let availableFonts: [String] = [
        "SF Mono", "Menlo", "Monaco", "SF Mono Regular", "Helvetica",
        "PingFang SC", "System"
    ]

    /// Resolves a usable NSFont, falling back gracefully for unknown names.
    func editorFont() -> NSFont {
        let size = CGFloat(max(9, min(36, editorFontSize)))
        if editorFontName == "System" {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return NSFont(name: editorFontName, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private init() {}
}
