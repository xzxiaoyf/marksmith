import AppKit

enum VimMode: String {
    case normal = "NORMAL"
    case insert = "INSERT"
    case visual = "VISUAL"
    case visualLine = "V-LINE"
}

/// A pragmatic Vim key layer over NSTextView.
///
/// This is a documented subset (motions, operators, visual mode, yank/paste,
/// undo and dot-free editing), deliberately kept in one pure AppKit class so
/// additional motions can be added without touching the editor bridge.
/// Set `enabled = false` to let every keystroke through to AppKit.
final class VimController {
    private(set) var mode: VimMode = .normal {
        didSet { if oldValue != mode { onModeChange?(mode) } }
    }

    var enabled = true
    var onModeChange: ((VimMode) -> Void)?

    private var countBuffer = ""
    private var pendingOperator = ""
    private var pendingG = false
    private var visualAnchor = 0
    private var desiredColumn = 0
    private var yankRegister = ""
    private var yankIsLinewise = false
    private var lastChange: (String, Int) = ("", 0)   // (inserted text, repeat count)

    func reset() {
        mode = .normal
        countBuffer = ""
        pendingOperator = ""
        pendingG = false
        onModeChange?(mode)
    }

    // MARK: - Entry point

    /// Returns `true` when the key was consumed by Vim (AppKit must ignore it).
    func handle(event: NSEvent, textView: NSTextView) -> Bool {
        guard enabled else { return false }
        let key = event.charactersIgnoringModifiers ?? event.characters ?? ""

        if event.modifierFlags.contains(.control) {
            if key == "d" { pageMotion(textView: textView, down: true); return true }
            if key == "u" { pageMotion(textView: textView, down: false); return true }
            if key == "r" { textView.undoManager?.redo(); return true }
            return false
        }

        if key == "\u{1B}" { // Esc
            if mode == .insert { enterNormal(textView: textView) } else { reset() }
            return true
        }

        if mode == .insert { return false }

        if key.allSatisfy({ $0.isNumber }), key != "0", key.isEmpty == false {
            countBuffer += key
            return true
        }

        let repeatCount = consumeCount()
        switch mode {
        case .visual, .visualLine:
            return handleVisual(key, repeatCount: repeatCount, textView: textView)
        case .normal, .insert:
            return handleNormal(key, repeatCount: repeatCount, textView: textView)
        }
    }

    // MARK: - Normal mode

    private func handleNormal(_ key: String, repeatCount: Int, textView: NSTextView) -> Bool {
        if pendingG {
            pendingG = false
            if key == "g" { move(to: 0, in: textView) }
            resetPending()
            return true
        }

        if pendingOperator == "d" {
            pendingOperator = ""
            if key == "d" {
                deleteLines(repeatCount, in: textView)
            } else if let range = motionRange(key, from: textView.selectedRange.location,
                                              repeatCount: repeatCount, in: textView) {
                yankRegister = text(in: range, of: textView)
                yankIsLinewise = false
                replace(range, with: "", in: textView)
            }
            return true
        }
        if pendingOperator == "y" {
            pendingOperator = ""
            if key == "y" {
                yankLines(repeatCount, in: textView)
            } else if let range = motionRange(key, from: textView.selectedRange.location,
                                              repeatCount: repeatCount, in: textView) {
                yankRegister = text(in: range, of: textView)
                yankIsLinewise = false
            }
            return true
        }

        switch key {
        case "h": moveHorizontally(-repeatCount, in: textView)
        case "l": moveHorizontally(repeatCount, in: textView)
        case "j", "k":
            moveVertically(key == "j" ? repeatCount : -repeatCount, in: textView)
        case "0": move(to: lineRange(at: textView.selectedRange.location, in: textView).location, in: textView)
        case "^":
            let line = lineRange(at: textView.selectedRange.location, in: textView)
            let s = text(in: line, of: textView) as NSString
            var offset = 0
            while offset < s.length, s.character(at: offset) == 32 || s.character(at: offset) == 9 { offset += 1 }
            move(to: line.location + offset, in: textView)
        case "$":
            let line = lineRange(at: textView.selectedRange.location, in: textView)
            move(to: max(line.location, NSMaxRange(line) - 1), in: textView)
        case "w": move(to: wordBoundary(from: textView.selectedRange.location, forward: true, repeatCount: repeatCount, in: textView), in: textView)
        case "b": move(to: wordBoundary(from: textView.selectedRange.location, forward: false, repeatCount: repeatCount, in: textView), in: textView)
        case "e": move(to: wordEnd(from: textView.selectedRange.location, repeatCount: repeatCount, in: textView), in: textView)
        case "g": pendingG = true
        case "G": move(to: max(0, length(of: textView) - 1), in: textView)
        case "i": enterInsert(textView: textView)
        case "a": moveHorizontally(1, in: textView); enterInsert(textView: textView)
        case "I": move(to: lineRange(at: textView.selectedRange.location, in: textView).location, in: textView); enterInsert(textView: textView)
        case "A":
            let line = lineRange(at: textView.selectedRange.location, in: textView)
            move(to: max(line.location, NSMaxRange(line) - 1), in: textView)
            enterInsert(textView: textView)
        case "o":
            let line = lineRange(at: textView.selectedRange.location, in: textView)
            replace(NSRange(location: NSMaxRange(line), length: 0), with: "\n", in: textView)
            enterInsert(textView: textView)
        case "O":
            let line = lineRange(at: textView.selectedRange.location, in: textView)
            replace(NSRange(location: line.location, length: 0), with: "\n", in: textView)
            move(to: line.location, in: textView)
            enterInsert(textView: textView)
        case "x":
            let loc = textView.selectedRange.location
            let range = NSRange(location: loc, length: min(repeatCount, max(0, length(of: textView) - loc)))
            if range.length > 0 {
                yankRegister = text(in: range, of: textView)
                yankIsLinewise = false
                replace(range, with: "", in: textView)
            }
        case "d", "y": pendingOperator = key
        case "p": paste(in: textView)
        case "u": textView.undoManager?.undo()
        case "v": mode = .visual; visualAnchor = textView.selectedRange.location
        case "V": mode = .visualLine; visualAnchor = textView.selectedRange.location
        case "J": joinLines(repeatCount, in: textView)
        case ".": replayLastChange(in: textView)
        default:
            resetPending()
            return false
        }
        return true
    }

    // MARK: - Visual mode

    private func handleVisual(_ key: String, repeatCount: Int, textView: NSTextView) -> Bool {
        let cursor = mode == .visual
            ? NSMaxRange(textView.selectedRange)
            : NSMaxRange(lineRange(at: NSMaxRange(textView.selectedRange), in: textView))

        switch key {
        case "h", "l", "j", "k", "w", "b", "0", "$", "G":
            var target = cursor
            switch key {
            case "h": target -= repeatCount
            case "l": target += repeatCount
            case "j", "k":
                let line = lineRange(at: cursor, in: textView)
                let column = min(desiredColumn, max(0, line.length - 1))
                let offset = key == "j" ? repeatCount : -repeatCount
                target = lineOffset(line, by: offset, column: column, in: textView)
            case "w": target = wordBoundary(from: cursor, forward: true, repeatCount: repeatCount, in: textView)
            case "b": target = wordBoundary(from: cursor, forward: false, repeatCount: repeatCount, in: textView)
            case "0": target = lineRange(at: cursor, in: textView).location
            case "$": target = max(0, NSMaxRange(lineRange(at: cursor, in: textView)) - 1)
            case "G": target = max(0, length(of: textView) - 1)
            default: break
            }
            select(from: visualAnchor, to: target, linewise: mode == .visualLine, in: textView)
            return true

        case "y", "d", "x":
            let range = textView.selectedRange
            yankRegister = text(in: range, of: textView)
            yankIsLinewise = mode == .visualLine
            if key != "y" { replace(range, with: "", in: textView) }
            reset()
            return true

        default:
            reset()
            return false
        }
    }

    // MARK: - State transitions

    private func enterInsert(textView: NSTextView) {
        mode = .insert
        lastChange = ("", 0)
        textView.insertionPointColor = .controlAccentColor
    }

    private func enterNormal(textView: NSTextView) {
        let location = max(0, textView.selectedRange.location - 1)
        mode = .normal
        move(to: location, in: textView)
    }

    private func resetPending() {
        countBuffer = ""
        pendingOperator = ""
        pendingG = false
    }

    private func consumeCount() -> Int {
        let value = Int(countBuffer) ?? 1
        countBuffer = ""
        return max(1, min(value, 999))
    }

    // MARK: - Text primitives

    private func length(of textView: NSTextView) -> Int { (textView.string as NSString).length }
    private func string(of textView: NSTextView) -> NSString { textView.string as NSString }
    private func text(in range: NSRange, of textView: NSTextView) -> String {
        guard range.location >= 0, NSMaxRange(range) <= length(of: textView) else { return "" }
        return string(of: textView).substring(with: range)
    }

    private func replace(_ range: NSRange, with replacement: String, in textView: NSTextView) {
        guard let storage = textView.textStorage,
              range.location >= 0, NSMaxRange(range) <= storage.length,
              textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        let location = min(range.location + (replacement as NSString).length, length(of: textView))
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange)
        if !replacement.isEmpty { lastChange = (replacement, 1) }
    }

    private func move(to rawLocation: Int, in textView: NSTextView) {
        let location = max(0, min(rawLocation, max(0, length(of: textView) - 1)))
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange)
        desiredColumn = column(of: location, in: textView)
    }

    private func moveHorizontally(_ delta: Int, in textView: NSTextView) {
        let line = lineRange(at: textView.selectedRange.location, in: textView)
        let lower = line.location
        let upper = max(lower, NSMaxRange(line) - 1)
        move(to: max(lower, min(upper, textView.selectedRange.location + delta)), in: textView)
    }

    private func moveVertically(_ lines: Int, in textView: NSTextView) {
        let line = lineRange(at: textView.selectedRange.location, in: textView)
        let target = lineOffset(line, by: lines, column: desiredColumn, in: textView)
        move(to: target, in: textView)
        desiredColumn = column(of: textView.selectedRange.location, in: textView)
        // `move` recomputes desiredColumn from the clamped destination; restore
        // the remembered column so repeated j/k keep the original column.
        desiredColumn = column(of: target, in: textView)
    }

    private func lineOffset(_ line: NSRange, by offset: Int, column: Int, in textView: NSTextView) -> Int {
        let s = string(of: textView)
        var targetLine = line
        var remaining = abs(offset)
        while remaining > 0 {
            if offset > 0 {
                let next = NSMaxRange(targetLine)
                if next >= s.length { break }
                targetLine = s.lineRange(for: NSRange(location: next, length: 0))
            } else {
                if targetLine.location == 0 { break }
                targetLine = s.lineRange(for: NSRange(location: targetLine.location - 1, length: 0))
            }
            remaining -= 1
        }
        let usable = max(0, targetLine.length - 1)
        return targetLine.location + min(max(0, column), usable)
    }

    private func lineRange(at location: Int, in textView: NSTextView) -> NSRange {
        let s = string(of: textView)
        guard s.length > 0 else { return NSRange(location: 0, length: 0) }
        return s.lineRange(for: NSRange(location: max(0, min(location, s.length - 1)), length: 0))
    }

    private func column(of location: Int, in textView: NSTextView) -> Int {
        location - lineRange(at: location, in: textView).location
    }

    private func select(from anchor: Int, to cursor: Int, linewise: Bool, in textView: NSTextView) {
        let lower = min(anchor, cursor)
        let upper = max(anchor, cursor)
        let range: NSRange
        if linewise {
            let start = lineRange(at: lower, in: textView)
            let end = lineRange(at: upper, in: textView)
            range = NSRange(location: start.location, length: NSMaxRange(end) - start.location)
        } else {
            range = NSRange(location: lower, length: min(upper - lower + 1, max(0, length(of: textView) - lower)))
        }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    // MARK: - Word motions

    private func wordBoundary(from start: Int, forward: Bool, repeatCount: Int, in textView: NSTextView) -> Int {
        let s = string(of: textView)
        var position = max(0, min(start, max(0, s.length - 1)))
        for _ in 0..<repeatCount {
            if forward {
                while position < s.length - 1, isWordCharacter(s.character(at: position)) { position += 1 }
                while position < s.length - 1, !isWordCharacter(s.character(at: position)) { position += 1 }
            } else {
                while position > 0, !isWordCharacter(s.character(at: position - 1)) { position -= 1 }
                while position > 0, isWordCharacter(s.character(at: position - 1)) { position -= 1 }
            }
        }
        return position
    }

    private func wordEnd(from start: Int, repeatCount: Int, in textView: NSTextView) -> Int {
        let s = string(of: textView)
        var position = max(0, min(start + 1, max(0, s.length - 1)))
        for _ in 0..<repeatCount {
            while position < s.length - 1, !isWordCharacter(s.character(at: position)) { position += 1 }
            while position < s.length - 1, isWordCharacter(s.character(at: position + 1)) { position += 1 }
        }
        return position
    }

    private func isWordCharacter(_ code: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(code)) else { return false }
        return Character(scalar).isLetter || Character(scalar).isNumber || scalar == "_"
    }

    // MARK: - Operators

    private func motionRange(_ key: String, from start: Int, repeatCount: Int, in textView: NSTextView) -> NSRange? {
        let target: Int
        switch key {
        case "h": target = start - repeatCount
        case "l": target = start + repeatCount
        case "w": target = wordBoundary(from: start, forward: true, repeatCount: repeatCount, in: textView)
        case "b": target = wordBoundary(from: start, forward: false, repeatCount: repeatCount, in: textView)
        case "e": target = wordEnd(from: start, repeatCount: repeatCount, in: textView) + 1
        case "$": target = max(0, NSMaxRange(lineRange(at: start, in: textView)) - 1)
        case "0": target = lineRange(at: start, in: textView).location
        case "j", "k":
            let line = lineRange(at: start, in: textView)
            target = lineOffset(line, by: key == "j" ? repeatCount : -repeatCount,
                                column: column(of: start, in: textView), in: textView)
        default: return nil
        }
        let lower = max(0, min(start, target))
        let upper = min(length(of: textView), max(start, target))
        guard upper > lower else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    private func deleteLines(_ count: Int, in textView: NSTextView) {
        var line = lineRange(at: textView.selectedRange.location, in: textView)
        let start = line.location
        var end = NSMaxRange(line)
        for _ in 1..<count where end < length(of: textView) {
            line = string(of: textView).lineRange(for: NSRange(location: end, length: 0))
            end = NSMaxRange(line)
        }
        let range = NSRange(location: start, length: end - start)
        yankRegister = text(in: range, of: textView)
        yankIsLinewise = true
        replace(range, with: "", in: textView)
    }

    private func yankLines(_ count: Int, in textView: NSTextView) {
        var line = lineRange(at: textView.selectedRange.location, in: textView)
        var end = NSMaxRange(line)
        for _ in 1..<count where end < length(of: textView) {
            line = string(of: textView).lineRange(for: NSRange(location: end, length: 0))
            end = NSMaxRange(line)
        }
        yankRegister = text(in: NSRange(location: lineRange(at: textView.selectedRange.location, in: textView).location,
                                        length: end - lineRange(at: textView.selectedRange.location, in: textView).location),
                            of: textView)
        yankIsLinewise = true
    }

    private func paste(in textView: NSTextView) {
        guard !yankRegister.isEmpty else { return }
        if yankIsLinewise {
            let line = lineRange(at: textView.selectedRange.location, in: textView)
            replace(NSRange(location: NSMaxRange(line), length: 0),
                    with: yankRegister, in: textView)
        } else {
            replace(NSRange(location: textView.selectedRange.location, length: 0),
                    with: yankRegister, in: textView)
        }
    }

    private func joinLines(_ count: Int, in textView: NSTextView) {
        for _ in 0..<max(1, count) {
            let line = lineRange(at: textView.selectedRange.location, in: textView)
            guard NSMaxRange(line) < length(of: textView) else { break }
            var trimmed = NSMaxRange(line) - 1
            while trimmed > line.location,
                  string(of: textView).character(at: trimmed - 1) == 10 ||
                  string(of: textView).character(at: trimmed - 1) == 13 { trimmed -= 1 }
            let range = NSRange(location: trimmed, length: NSMaxRange(line) - trimmed)
            replace(range, with: " ", in: textView)
        }
    }

    private func replayLastChange(in textView: NSTextView) {
        guard !lastChange.0.isEmpty else { return }
        replace(NSRange(location: textView.selectedRange.location, length: 0),
                with: lastChange.0, in: textView)
    }

    private func pageMotion(textView: NSTextView, down: Bool) {
        let line = lineRange(at: textView.selectedRange.location, in: textView)
        moveVertically(down ? 20 : -20, in: textView)
        _ = line
    }
}
