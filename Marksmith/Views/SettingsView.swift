import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TabView {
            editorTab
                .tabItem { Label("编辑器", systemImage: "square.and.pencil") }
            previewTab
                .tabItem { Label("预览", systemImage: "doc.richtext") }
            aboutTab
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 500, height: 340)
        .padding(4)
    }

    private var editorTab: some View {
        Form {
            Section("字体与排版") {
                HStack {
                    Text("字号")
                    Spacer()
                    Slider(value: $settings.editorFontSize, in: 10...24, step: 1)
                        .frame(width: 150)
                    Stepper(value: $settings.editorFontSize, in: 10...24, step: 1) {
                        Text("\(Int(settings.editorFontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                Picker("编辑字体", selection: $settings.editorFontName) {
                    ForEach(AppSettings.availableFonts, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Toggle("自动换行", isOn: $settings.wordWrap)
                Toggle("显示行号", isOn: $settings.showLineNumbers)
            }

            Section("输入") {
                Toggle("Vim 模式（常用子集）", isOn: $settings.vimModeEnabled)
                Text("支持 h/j/k/l、w/b/e、0/$、gg/G、i/a/o/O、x、dd、yy、p、u、v/V 与计数。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var previewTab: some View {
        Form {
            Section("外观") {
                Picker("预览主题", selection: $settings.appearanceRaw) {
                    ForEach(AppearanceSetting.allCases) { option in
                        Text(option.rawValue).tag(option.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)

                Picker("默认视图", selection: $settings.defaultViewModeRaw) {
                    ForEach(ViewMode.allCases) { mode in
                        Text(mode.localized).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("性能") {
                HStack {
                    Text("预览刷新延迟")
                    Spacer()
                    Slider(value: $settings.previewDebounceMs, in: 100...1000, step: 50)
                        .frame(width: 160)
                    Text("\(Int(settings.previewDebounceMs)) ms")
                        .monospacedDigit()
                        .frame(width: 58, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 76, height: 76)
            Text(AppMetadata.displayName)
                .font(.title2.bold())
            Text("原生 macOS Markdown 编辑器 · 版本 \(AppMetadata.version)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("SwiftUI + AppKit，无第三方 SwiftPM 依赖。\n预览内置 KaTeX、Mermaid 与 highlight.js，完全离线可用。")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
    }
}
