import SwiftUI

struct EditorContainer: View {
    @Binding var text: String
    let viewMode: ViewMode
    let htmlBody: String
    let theme: ColorTheme
    let isDarkEditor: Bool
    let imageBaseURL: URL?
    @ObservedObject var settings: AppSettings
    @ObservedObject var bridge: EditorBridge
    @ObservedObject var findController: FindController
    var onCursorChange: (Int, Int) -> Void
    var onVimModeChange: (VimMode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if findController.isVisible {
                FindBar(controller: findController)
            }

            Group {
                switch viewMode {
                case .sideBySide:
                    HSplitView {
                        editorView.frame(minWidth: 240)
                        previewView.frame(minWidth: 240)
                    }
                case .editorOnly:
                    editorView
                case .previewOnly:
                    previewView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var editorView: some View {
        MarkdownEditorView(
            text: $text,
            settings: settings,
            bridge: bridge,
            findController: findController,
            isDark: isDarkEditor,
            imageBaseURL: imageBaseURL,
            onCursorChange: onCursorChange,
            onVimModeChange: onVimModeChange
        )
    }

    private var previewView: some View {
        PreviewWebView(htmlBody: htmlBody, theme: theme)
    }
}
