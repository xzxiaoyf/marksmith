import SwiftUI
import AppKit

struct FolderSidebarView: View {
    @ObservedObject var model: FolderTreeModel
    let onOpen: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("过滤文件", text: $model.filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !model.filter.isEmpty {
                    Button { model.filter = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()

            Group {
                if let root = model.root {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.visibleChildren(root)) { child in
                                FileNodeRow(node: child, model: model, depth: 0, onOpen: onOpen)
                            }
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ContentUnavailableView {
                        Label("未打开文件夹", systemImage: "folder")
                    } description: {
                        Text("使用「文件 › 打开文件夹」浏览 Markdown 文件。")
                    }
                }
            }
            .frame(maxHeight: .infinity)

            if let rootURL = model.rootURL {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(rootURL.lastPathComponent)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button { model.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("刷新文件树")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 200)
    }
}

private struct FileNodeRow: View {
    let node: FileNode
    @ObservedObject var model: FolderTreeModel
    let depth: Int
    let onOpen: (URL) -> Void

    private var isSelected: Bool { !node.isDirectory && model.selectedURL == node.id }
    private var isExpanded: Bool { model.isExpanded(node.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                if node.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 11)
                } else {
                    Spacer().frame(width: 11)
                }

                Image(systemName: node.isDirectory ? "folder.fill" : "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(node.isDirectory ? .blue : .secondary)
                    .frame(width: 15)

                Text(node.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(node.name)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 14 + 8)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if node.isDirectory {
                    withAnimation(.easeInOut(duration: 0.12)) { model.toggle(node.id) }
                } else {
                    model.selectedURL = node.id
                    onOpen(node.id)
                }
            }

            if node.isDirectory, isExpanded {
                ForEach(model.visibleChildren(node)) { child in
                    FileNodeRow(node: child, model: model, depth: depth + 1, onOpen: onOpen)
                }
            }
        }
    }
}
