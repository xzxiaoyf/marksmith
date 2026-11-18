import Foundation
import CoreServices

// MARK: - Tree node

struct FileNode: Identifiable, Equatable {
    let id: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?

    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name &&
        lhs.isDirectory == rhs.isDirectory && lhs.children == rhs.children
    }
}

enum FileTreeBuilder {
    static let supportedExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx", "txt"]

    /// Runs off the main thread: deep trees must not block the UI.
    static nonisolated func build(url: URL, depth: Int = 0) -> FileNode? {
        guard depth <= 8 else { return nil }
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var children: [FileNode] = []
        for item in contents {
            let name = item.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }       // avoid cycles
            let isDirectory = values?.isDirectory == true
            if isDirectory {
                if let node = build(url: item, depth: depth + 1) { children.append(node) }
            } else if supportedExtensions.contains(item.pathExtension.lowercased()) {
                children.append(FileNode(id: item, name: name, isDirectory: false, children: nil))
            }
        }
        children.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return FileNode(id: url, name: url.lastPathComponent,
                        isDirectory: true, children: children)
    }
}

// MARK: - FSEvents watcher

/// Recursive filesystem watcher for the sidebar. Falls back to periodic
/// refresh in `FolderTreeModel` if the stream cannot be created.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let box: WatcherBox

    private final class WatcherBox {
        weak var owner: FolderWatcher?
        let onChange: () -> Void
        init(onChange: @escaping () -> Void) { self.onChange = onChange }
    }

    init?(path: String, onChange: @escaping () -> Void) {
        let box = WatcherBox(onChange: onChange)
        self.box = box
        let opaque = Unmanaged.passUnretained(box).toOpaque()

        var context = FSEventStreamContext(
            version: 0,
            info: opaque,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let target = Unmanaged<WatcherBox>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { target.onChange() }
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.6,
            flags
        ) else { return nil }

        self.stream = stream
        // Dispatch-queue scheduling is the modern replacement for the
        // deprecated run-loop API (macOS 13+).
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        if !FSEventStreamStart(stream) {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
        // `box` is retained by this watcher instance, and the stream is torn
        // down in `deinit`, so the unretained `info` pointer stays valid.
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

// MARK: - Tree model

@MainActor
final class FolderTreeModel: ObservableObject {
    @Published var root: FileNode?
    @Published var rootURL: URL?
    @Published var selectedURL: URL?
    @Published var expanded: Set<URL> = []
    @Published var filter: String = ""

    private var watcher: FolderWatcher?
    private var fallbackTimer: Timer?

    func load(_ url: URL) {
        watcher = nil
        fallbackTimer?.invalidate()
        rootURL = url
        expanded = [url]
        refresh()
        watcher = FolderWatcher(path: url.path) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        if watcher == nil {
            fallbackTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    func refresh() {
        guard let url = rootURL else { return }
        // Explicit strong capture avoids a mutable weak `self` crossing an
        // actor boundary; the task is short-lived, so there is no cycle.
        Task.detached(priority: .utility) { [self] in
            let node = FileTreeBuilder.build(url: url)
            await MainActor.run { [self] in
                self.root = node
            }
        }
    }

    func isExpanded(_ url: URL) -> Bool { expanded.contains(url) }

    func toggle(_ url: URL) {
        if expanded.contains(url) { expanded.remove(url) } else { expanded.insert(url) }
    }

    func visibleChildren(_ node: FileNode) -> [FileNode] {
        guard let children = node.children else { return [] }
        guard !filter.isEmpty else { return children }
        return children.filter { $0.name.localizedCaseInsensitiveContains(filter) || $0.isDirectory }
    }
}
