import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CursorPosition {
    var line: Int = 1
    var column: Int = 1
}

// MARK: - Find / replace controller

final class FindController: ObservableObject {
    weak var textView: NSTextView?

    @Published var query = "" { didSet { recount() } }
    @Published var replacement = ""
    @Published var isVisible = false
    @Published var showReplace = false
    @Published var matchCount = 0
    @Published var status = ""

    func show(replace: Bool) {
        isVisible = true
        showReplace = replace
        recount()
        DispatchQueue.main.async { [weak self] in
            self?.textView?.window?.makeFirstResponder(self?.textView)
        }
    }

    func hide() {
        isVisible = false
        status = ""
        textView?.window?.makeFirstResponder(textView)
    }

    func recount() {
        guard !query.isEmpty, let textView else {
            matchCount = 0
            status = ""
            return
        }
        let content = textView.string as NSString
        var count = 0
        var search = NSRange(location: 0, length: content.length)
        while search.location < content.length {
            let found = content.range(of: query, options: [.caseInsensitive], range: search)
            if found.location == NSNotFound { break }
            count += 1
            search = NSRange(location: NSMaxRange(found), length: max(0, content.length - NSMaxRange(found)))
        }
        matchCount = count
        status = count == 0 ? "无匹配" : "\(count) 处匹配"
    }

    func findNext(forward: Bool = true) {
        guard !query.isEmpty, let textView else { return }
        let content = textView.string as NSString
        guard content.length > 0 else { return }
        let selection = textView.selectedRange
        let start = forward ? NSMaxRange(selection) : selection.location
        var range: NSRange
        if forward {
            range = NSRange(location: min(start, content.length),
                            length: max(0, content.length - min(start, content.length)))
        } else {
            range = NSRange(location: 0, length: max(0, min(start, content.length)))
        }

        var found = content.range(
            of: query,
            options: forward ? [.caseInsensitive] : [.caseInsensitive, .backwards],
            range: range
        )
        if found.location == NSNotFound {
            // Wrap around.
            let wrapRange = NSRange(location: 0, length: content.length)
            found = content.range(
                of: query,
                options: forward ? [.caseInsensitive] : [.caseInsensitive, .backwards],
                range: wrapRange
            )
        }
        guard found.location != NSNotFound else { status = "无匹配"; return }
        textView.setSelectedRange(found)
        textView.scrollRangeToVisible(found)
        status = "\(matchCount) 处匹配"
    }

    func replaceCurrent() {
        guard let textView, !query.isEmpty,
              (textView.string as NSString).substring(with: textView.selectedRange)
                .caseInsensitiveCompare(query) == .orderedSame else {
            findNext()
            return
        }
        let range = textView.selectedRange
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        recount()
        findNext()
    }

    func replaceAll() {
        guard let textView, !query.isEmpty else { return }
        let original = textView.string
        let updated = original.replacingOccurrences(of: query, with: replacement,
                                                    options: [.caseInsensitive])
        guard updated != original else { return }
        let whole = NSRange(location: 0, length: (original as NSString).length)
        guard textView.shouldChangeText(in: whole, replacementString: updated) else { return }
        textView.textStorage?.replaceCharacters(in: whole, with: updated)
        textView.didChangeText()
        recount()
        status = "已全部替换"
    }
}

// MARK: - Bridge used by menu commands

final class EditorBridge: ObservableObject {
    weak var textView: MarkdownEditorTextView?
    weak var findController: FindController?
    weak var scrollView: NSScrollView?

    /// Newest text handed to the bridge. Keeping it makes two previously
    /// fragile situations safe:
    ///  * a sync that arrives before `makeNSView` connects the text view is
    ///    replayed on attach instead of being dropped;
    ///  * a deferred repair pass can replay the *current* value without
    ///    capturing — and later restoring — a stale snapshot.
    private(set) var latestText: String?

    func applyInsert(_ command: InsertCommand) {
        textView?.apply(command)
    }

    func showFind(replace: Bool) {
        findController?.show(replace: replace)
    }

    func setLineNumbersVisible(_ visible: Bool) {
        scrollView?.hasVerticalRuler = visible
        scrollView?.rulersVisible = visible
    }

    /// UTF-16 caret offset used by "append imported Markdown at cursor".
    func cursorLocation() -> Int {
        guard let textView else { return 0 }
        return min(max(0, textView.selectedRange.location), (textView.string as NSString).length)
    }

    func moveCursor(to location: Int) {
        guard let textView else { return }
        let bounded = min(max(0, location), (textView.string as NSString).length)
        textView.setSelectedRange(NSRange(location: bounded, length: 0))
        textView.scrollRangeToVisible(NSRange(location: bounded, length: 0))
    }

    /// Connects the AppKit editor. On the first connection, any text queued
    /// by `syncText` is replayed, so an import landing while a window is
    /// being built cannot be lost.
    func attach(textView: MarkdownEditorTextView, scrollView: NSScrollView,
                findController: FindController) {
        let needsReplay = self.textView == nil
        self.textView = textView
        self.scrollView = scrollView
        self.findController = findController
        findController.textView = textView
        if needsReplay { flush() }
    }

    /// Single entry point for text coming from the document (file load,
    /// import, undo, sidebar switch). SwiftUI's `updateNSView` is not
    /// guaranteed for every mutation, so `ContentView.onChange` and the
    /// import service both call this with the authoritative value.
    func syncText(_ value: String) {
        latestText = value
        flush()
    }

    /// Re-applies the newest text and forces a redraw. Deliberately takes no
    /// text argument: a deferred call must never reintroduce an older value.
    /// (Capturing the pre-import starter text in such a deferred call was
    /// exactly the "preview shows the import, editor shows the old document"
    /// bug.)
    func flush() {
        guard let textView else { return }
        if let value = latestText, textView.string != value {
            textView.applyProgrammaticText(value)
        }
        textView.setNeedsDisplay(textView.visibleRect)
        scrollView?.contentView.setNeedsDisplay(scrollView?.contentView.bounds ?? .zero)
    }
}

// MARK: - Syntax-highlighting text storage

final class HighlightingTextStorage: NSTextStorage {
    private let backing = NSMutableAttributedString()
    private var isHighlighting = false

    var baseFont: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    var theme: HighlightTheme = .make(dark: false)

    override var string: String { backing.string }

    override func attributes(at location: Int,
                             effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        backing.replaceCharacters(in: range, with: str)
        edited([.editedCharacters], range: range,
               changeInLength: (str as NSString).length - range.length)
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        backing.setAttributes(attrs, range: range)
        edited([.editedAttributes], range: range, changeInLength: 0)
    }

    override func processEditing() {
        guard !isHighlighting else {
            // A nested notification from the attribute edits published below.
            // It must still reach the layout managers.
            super.processEditing()
            return
        }
        super.processEditing()
        guard backing.length > 0 else { return }
        isHighlighting = true
        let paragraph = (backing.string as NSString).paragraphRange(for: editedRange)
        let end = min(NSMaxRange(paragraph), backing.length)
        let bounded = NSRange(location: paragraph.location,
                              length: max(0, end - paragraph.location))
        if bounded.length > 0 {
            SyntaxHighlighter.apply(to: backing, range: bounded,
                                    baseFont: baseFont, theme: theme)
            // Styles were written into the backing store directly, so publish
            // an attribute edit. Without it the layout manager keeps the old
            // glyph runs and skips font substitution: CJK characters then get
            // zero-width glyphs and vanish, and colours can go stale too.
            edited([.editedAttributes], range: bounded, changeInLength: 0)
            for manager in layoutManagers {
                manager.invalidateDisplay(forCharacterRange: bounded)
            }
        }
        isHighlighting = false
    }

    /// Re-applies attributes to the whole document and notifies layout
    /// managers. Must be used instead of mutating `backing` silently.
    func highlightAll() {
        guard backing.length > 0, !isHighlighting else { return }
        let whole = NSRange(location: 0, length: backing.length)
        isHighlighting = true
        SyntaxHighlighter.apply(to: backing, range: whole,
                                baseFont: baseFont, theme: theme)
        edited([.editedAttributes], range: whole, changeInLength: 0)
        isHighlighting = false
        for manager in layoutManagers {
            manager.invalidateDisplay(forCharacterRange: whole)
        }
    }

    /// Replaces the whole text through the NSTextStorage editing pipeline so
    /// attached layout managers receive a change notification. Suppresses the
    /// incremental highlighter during the bulk edit — `highlightAll()` below
    /// does the job once, with a proper attribute-change notification.
    func setText(_ value: String) {
        guard value != backing.string else { return }
        let whole = NSRange(location: 0, length: backing.length)
        isHighlighting = true
        replaceCharacters(in: whole, with: value)
        isHighlighting = false
        highlightAll()
    }
}

// MARK: - Line-number ruler

final class LineNumberRulerView: NSRulerView {
    var font: NSFont = .monospacedSystemFont(ofSize: 11, weight: .regular)
    var textColor: NSColor = .tertiaryLabelColor

    override var requiredThickness: CGFloat { 44 }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let visible = textView.visibleRect
        let inset = textView.textContainerInset
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: NSRect(x: 0, y: visible.minY - inset.height,
                                    width: visible.width, height: visible.height),
            in: container
        )
        let characters = (textView.string as NSString)
        var lineNumber = 1
        var index = 0
        while index < glyphRange.location, index < characters.length {
            let line = characters.lineRange(for: NSRange(location: index, length: 0))
            lineNumber += 1
            index = NSMaxRange(line)
        }

        var location = glyphRange.location
        while location < NSMaxRange(glyphRange), location < characters.length {
            let line = characters.lineRange(for: NSRange(location: location, length: 0))
            var effective: NSRange = NSRange(location: 0, length: 0)
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: line.location)
            let lineFragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex,
                                                              effectiveRange: &effective)
            let y = lineFragment.minY + inset.height - visible.minY
            let label = "\(lineNumber)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 7, y: y + 1),
                       withAttributes: attributes)
            lineNumber += 1
            location = NSMaxRange(line)
        }
    }
}

// MARK: - NSTextView subclass

final class MarkdownEditorTextView: NSTextView {
    let vim = VimController()

    var onTextChange: ((String) -> Void)?
    var onCursorChange: ((Int, Int) -> Void)?
    var onVimModeChange: ((VimMode) -> Void)?
    var imageBaseURL: URL?

    private var storageBridge: HighlightingTextStorage? { textStorage as? HighlightingTextStorage }
    private var configurationKey = ""

    func configure(font: NSFont, dark: Bool, wordWrap: Bool, vimEnabled: Bool, force: Bool = false) {
        let key = "\(font.fontName)|\(font.pointSize)|\(dark)|\(wordWrap)|\(vimEnabled)"
        guard force || key != configurationKey else { return }
        configurationKey = key
        let theme = HighlightTheme.make(dark: dark)
        storageBridge?.baseFont = font
        storageBridge?.theme = theme
        storageBridge?.highlightAll()
        self.font = font
        // `isRichText` is on so the storage's syntax colours survive. Set an
        // explicit fallback colour anyway: if AppKit ever coalesces the
        // attributes away, text must still contrast with the dark background.
        textColor = theme.text
        typingAttributes = [.font: font, .foregroundColor: theme.text]
        backgroundColor = dark ? NSColor(calibratedWhite: 0.13, alpha: 1) : .textBackgroundColor
        insertionPointColor = .controlAccentColor
        vim.enabled = vimEnabled
        if !vimEnabled { vim.reset() }

        guard let container = textContainer else { return }
        if wordWrap {
            let available = enclosingScrollView?.contentSize.width ?? 600
            container.size = NSSize(width: max(240, available),
                                    height: CGFloat.greatestFiniteMagnitude)
            container.widthTracksTextView = true
            isHorizontallyResizable = false
        } else {
            container.size = NSSize(width: 1_000_000,
                                    height: CGFloat.greatestFiniteMagnitude)
            container.widthTracksTextView = false
            isHorizontallyResizable = true
        }
        setNeedsDisplay(bounds)
    }

    /// Applies text that came from outside the text view (file load, undo,
    /// sidebar switch). Goes through the storage pipeline and forces both a
    /// layout invalidation and a display pass so the editor cannot stay blank.
    func applyProgrammaticText(_ value: String) {
        guard let storage = textStorage as? HighlightingTextStorage,
              string != value else { return }
        let caret = min(selectedRange.location, (value as NSString).length)
        storage.setText(value)
        setSelectedRange(NSRange(location: caret, length: 0))
        if let container = textContainer, let manager = layoutManager {
            let whole = NSRange(location: 0, length: (string as NSString).length)
            if whole.length > 0 {
                manager.invalidateDisplay(forCharacterRange: whole)
                _ = manager.glyphRange(for: container)
            }
        }
        setNeedsDisplay(bounds)
        if let clip = enclosingScrollView?.contentView {
            clip.setNeedsDisplay(clip.bounds)
        }
        reportCursor()
    }

    override func keyDown(with event: NSEvent) {
        if vim.enabled, vim.handle(event: event, textView: self) {
            reportCursor()
            vim.onModeChange?(vim.mode)
            return
        }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        onTextChange?(string)
        reportCursor()
    }

    override func setSelectedRange(_ charRange: NSRange,
                                   affinity: NSSelectionAffinity,
                                   stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelectingFlag)
        if !stillSelectingFlag { reportCursor() }
    }

    func reportCursor() {
        let content = string as NSString
        let location = min(selectedRange.location, content.length)
        let prefix = content.substring(to: location) as NSString
        let line = prefix.components(separatedBy: "\n").count
        let lastLine = prefix.components(separatedBy: "\n").last ?? ""
        onCursorChange?(line, lastLine.count + 1)
    }

    // MARK: Image paste / drop

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let data = imageData(from: pasteboard), insertImage(data) { return }
        // Rich text is enabled so the syntax colours survive, but a Markdown
        // editor must still paste plain text rather than foreign fonts/colours.
        if let plain = pasteboard.string(forType: .string) {
            insertText(plain, replacementRange: selectedRange)
            return
        }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let data = imageData(from: pasteboard), insertImage(data) { return true }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first {
            let ext = first.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff"].contains(ext),
               let data = try? Data(contentsOf: first), insertImage(data, name: first.lastPathComponent) {
                return true
            }
            if ["md", "markdown", "txt"].contains(ext),
               let content = try? String(contentsOf: first, encoding: .utf8) {
                insertText(content, replacementRange: selectedRange)
                return true
            }
        }
        return super.performDragOperation(sender)
    }

    private func imageData(from pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: .png) { return data }
        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }

    @discardableResult
    private func insertImage(_ data: Data, name: String? = nil) -> Bool {
        let fileName = name ?? "marksmith-\(UUID().uuidString.prefix(8)).png"
        let markdown: String
        if let base = imageBaseURL {
            let directory = base.appendingPathComponent("assets", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(sanitise(fileName))
            guard (try? data.write(to: destination, options: .atomic)) != nil else { return false }
            markdown = "![\(fileName)](\(URL(fileURLWithPath: "assets").appendingPathComponent(sanitise(fileName)).relativePath))"
        } else {
            markdown = "![\(fileName)](data:image/png;base64,\(data.base64EncodedString()))"
        }
        insertText(markdown, replacementRange: selectedRange)
        return true
    }

    private func sanitise(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "-")
    }

    // MARK: Format commands

    func apply(_ command: InsertCommand) {
        let range = selectedRange
        let selected = (string as NSString).substring(with: range)
        switch command {
        case .bold: wrap(range, selected: selected, prefix: "**", suffix: "**", placeholder: "粗体")
        case .italic: wrap(range, selected: selected, prefix: "*", suffix: "*", placeholder: "斜体")
        case .strikethrough: wrap(range, selected: selected, prefix: "~~", suffix: "~~", placeholder: "删除线")
        case .inlineCode: wrap(range, selected: selected, prefix: "`", suffix: "`", placeholder: "代码")
        case .link:
            let text = selected.isEmpty ? "链接文字" : selected
            let replacement = "[\(text)](https://example.com)"
            replace(range, with: replacement,
                    selection: NSRange(location: range.location + text.count + 3, length: 19))
        case .codeBlock:
            replaceBlock("```\n\n```\n", cursorOffset: 4, at: range)
        case .quote:
            let replacement = selected.isEmpty ? "> " :
                selected.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \($0)" }.joined(separator: "\n")
            replace(range, with: replacement)
        case .heading(let level):
            let line = (string as NSString).lineRange(for: NSRange(location: range.location, length: 0))
            let lineText = (string as NSString).substring(with: line)
            if level == 0 {
                // "正文": strip an existing ATX heading marker.
                var hashes = 0
                for ch in lineText {
                    guard ch == "#" else { break }
                    hashes += 1
                }
                if (1...6).contains(hashes) {
                    let after = lineText.index(lineText.startIndex, offsetBy: hashes)
                    if after < lineText.endIndex, lineText[after] == " " {
                        replace(line, with: String(lineText[lineText.index(after: after)...]))
                    }
                }
                return
            }
            let marker = String(repeating: "#", count: max(1, min(level, 6))) + " "
            let updated = lineText.hasPrefix(marker) ? String(lineText.dropFirst(marker.count)) : marker + lineText
            replace(line, with: updated)
        case .table:
            replaceBlock("| 列 1 | 列 2 |\n| --- | --- |\n| 内容 | 内容 |\n", cursorOffset: 2, at: range)
        case .horizontalRule:
            replaceBlock("\n---\n", cursorOffset: 4, at: range)
        case .unorderedList:
            replaceBlock("- ", cursorOffset: 2, at: range)
        case .orderedList:
            replaceBlock("1. ", cursorOffset: 3, at: range)
        case .task:
            replaceBlock("- [ ] ", cursorOffset: 6, at: range)
        case .template(let template):
            insertTemplate(template, at: range, selected: selected)
        case .image:
            insertImageFromPanel()
        }
    }

    /// Guided snippets (公式 / 流程图). The placeholder is selected so a
    /// beginner can type immediately; an existing selection is used *as* the
    /// placeholder instead (select `x^2`, click 行内公式 → `$x^2$`).
    private func insertTemplate(_ template: InsertTemplate, at range: NSRange,
                                selected: String) {
        var snippet = template.snippet
        var placeholder = template.placeholderRange
        if !selected.isEmpty, let original = placeholder {
            snippet = (snippet as NSString).replacingCharacters(in: original, with: selected)
            placeholder = NSRange(location: original.location,
                                  length: (selected as NSString).length)
        }
        insertSnippet(snippet, placeholder: placeholder, at: range,
                      isBlock: template.isBlock)
    }

    private func insertSnippet(_ text: String, placeholder: NSRange?, at range: NSRange,
                               isBlock: Bool) {
        let content = string as NSString
        let needsLeadingNewline = isBlock && range.location > 0 &&
            content.character(at: range.location - 1) != 10 &&
            !text.hasPrefix("\n")
        let prefix = needsLeadingNewline ? "\n" : ""
        var selection: NSRange?
        if let placeholder {
            selection = NSRange(location: range.location + prefix.count + placeholder.location,
                                length: placeholder.length)
        }
        replace(range, with: prefix + text, selection: selection)
    }

    /// Toolbar / menu command for inserting a picture. Reuses the same asset
    /// path as paste & drag (`assets/` next to the document, or a data URI for
    /// unsaved documents).
    private func insertImageFromPanel() {
        let panel = NSOpenPanel()
        panel.title = "插入图片"
        panel.message = "选择图片，插入到光标位置"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "webp"]
            .compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        window?.makeFirstResponder(self)
        _ = insertImage(data, name: url.lastPathComponent)
    }

    private func wrap(_ range: NSRange, selected: String,
                      prefix: String, suffix: String, placeholder: String) {
        let content = selected.isEmpty ? placeholder : selected
        let replacement = prefix + content + suffix
        replace(range, with: replacement,
                selection: NSRange(location: range.location + prefix.count, length: content.count))
    }

    private func replaceBlock(_ text: String, cursorOffset: Int, at range: NSRange) {
        let content = string as NSString
        let needsLeadingNewline = range.location > 0 &&
            content.character(at: range.location - 1) != 10 &&
            !text.hasPrefix("\n")
        let prefix = needsLeadingNewline ? "\n" : ""
        replace(range, with: prefix + text,
                selection: NSRange(location: range.location + prefix.count + min(cursorOffset, text.count),
                                   length: 0))
    }

    func replace(_ range: NSRange, with replacement: String, selection: NSRange? = nil) {
        guard let storage = textStorage,
              range.location >= 0, NSMaxRange(range) <= storage.length,
              shouldChangeText(in: range, replacementString: replacement) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        didChangeText()
        let target = selection ?? NSRange(location: range.location + (replacement as NSString).length,
                                          length: 0)
        setSelectedRange(target)
        scrollRangeToVisible(target)
        window?.makeFirstResponder(self)
    }
}

// MARK: - SwiftUI bridge

struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var settings: AppSettings
    @ObservedObject var bridge: EditorBridge
    @ObservedObject var findController: FindController
    var isDark: Bool
    var imageBaseURL: URL?
    var onCursorChange: (Int, Int) -> Void
    var onVimModeChange: (VimMode) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let storage = HighlightingTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let textView = MarkdownEditorTextView(frame: NSRect.zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.allowsUndo = true
        // Keep attributed text (syntax colours). Plain-text paste is enforced
        // in `paste(_:)` above. `isRichText = false` made AppKit discard the
        // font/colour attributes on some programmatic text replacements.
        textView.isRichText = true
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 14)
        textView.minSize = NSSize.zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = NSView.AutoresizingMask.width
        textView.registerForDraggedTypes([
            NSPasteboard.PasteboardType.fileURL,
            .png,
            .tiff,
            .string
        ])
        textView.imageBaseURL = imageBaseURL

        let textBinding = _text
        let controller = findController
        textView.onTextChange = { (newValue: String) in
            DispatchQueue.main.async {
                guard textBinding.wrappedValue != newValue else {
                    controller.recount()
                    return
                }
                textBinding.wrappedValue = newValue
                controller.recount()
            }
        }
        textView.onCursorChange = onCursorChange
        textView.onVimModeChange = onVimModeChange
        textView.vim.onModeChange = onVimModeChange

        let scrollView = NSScrollView(frame: NSRect.zero)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = isDark ? NSColor(calibratedWhite: 0.13, alpha: 1) : .textBackgroundColor
        let ruler = LineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)
        ruler.clientView = textView
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = settings.showLineNumbers
        scrollView.rulersVisible = settings.showLineNumbers

        storage.setText(text)
        textView.configure(font: settings.editorFont(), dark: isDark,
                           wordWrap: settings.wordWrap,
                           vimEnabled: settings.vimModeEnabled, force: true)

        DispatchQueue.main.async {
            bridge.attach(textView: textView, scrollView: scrollView,
                          findController: findController)
            findController.recount()
            textView.reportCursor()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownEditorTextView else { return }

        // Refresh the bridge's authoritative value first, then connect. The
        // bridge replays text that arrived before the view existed; comparing
        // with `latestText` avoids overwriting keystrokes that have not yet
        // been written back into the SwiftUI binding.
        if text != bridge.latestText { bridge.syncText(text) }
        bridge.attach(textView: textView, scrollView: scrollView,
                      findController: findController)
        textView.imageBaseURL = imageBaseURL
        textView.configure(font: settings.editorFont(), dark: isDark,
                           wordWrap: settings.wordWrap, vimEnabled: settings.vimModeEnabled)
        scrollView.backgroundColor = isDark ? NSColor(calibratedWhite: 0.13, alpha: 1) : .textBackgroundColor
        scrollView.hasVerticalRuler = settings.showLineNumbers
        scrollView.rulersVisible = settings.showLineNumbers
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textDidChange(_ notification: Notification) {
            // `didChangeText()` on the text view publishes the new string;
            // this delegate hook is kept for AppKit bookkeeping.
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownEditorTextView else { return }
            textView.reportCursor()
        }
    }
}
