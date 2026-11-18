import SwiftUI

struct StatusBarView: View {
    let stats: DocumentStats
    let cursor: CursorPosition
    let vimMode: VimMode
    let vimEnabled: Bool
    let viewMode: ViewMode
    let appearance: ColorTheme

    var body: some View {
        HStack(spacing: 14) {
            if vimEnabled {
                Text(vimMode.rawValue)
                    .font(.caption2.bold().monospaced())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 4).fill(vimColor))
            }

            Text(viewMode.localized)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            statusItem("Ln \(cursor.line), Col \(cursor.column)")
            divider
            statusItem("\(stats.words) 词")
            divider
            statusItem("\(stats.characters) 字符")
            divider
            statusItem("\(stats.lines) 行")
            divider
            statusItem("约 \(stats.readingMinutes) 分钟")
            divider
            statusItem(appearance == .dark ? "深色预览" : "浅色预览")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func statusItem(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var divider: some View {
        Divider().frame(height: 11)
    }

    private var vimColor: Color {
        switch vimMode {
        case .normal: return .blue
        case .insert: return .green
        case .visual: return .orange
        case .visualLine: return .purple
        }
    }
}
