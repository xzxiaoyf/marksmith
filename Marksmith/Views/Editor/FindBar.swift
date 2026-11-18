import SwiftUI

struct FindBar: View {
    @ObservedObject var controller: FindController
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("查找", text: $controller.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160, maxWidth: 260)
                    .focused($searchFocused)
                    .onSubmit { controller.findNext() }

                Text(controller.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 70, alignment: .leading)

                Button { controller.findNext(forward: false) } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .help("上一个")

                Button { controller.findNext(forward: true) } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("下一个")

                Divider().frame(height: 16)

                Toggle("替换", isOn: $controller.showReplace)
                    .toggleStyle(.button)
                    .font(.caption)

                Button {
                    controller.hide()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("关闭")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            if controller.showReplace {
                HStack(spacing: 8) {
                    Text("替换为")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("替换文本", text: $controller.replacement)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Button("替换") { controller.replaceCurrent() }
                    Button("全部替换") { controller.replaceAll() }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { searchFocused = true }
        .onChange(of: controller.isVisible) { _, visible in
            if visible { searchFocused = true }
        }
    }
}
