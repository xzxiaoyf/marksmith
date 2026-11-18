import Foundation

struct DocumentStats {
    let characters: Int
    let words: Int
    let lines: Int
    let readingMinutes: Int

    init(text: String) {
        characters = text.count
        lines = text.isEmpty ? 1 : text.split(separator: "\n", omittingEmptySubsequences: false).count

        // Count CJK characters individually and Latin words as whitespace runs:
        // a plain `components(separatedBy:)` would treat a Chinese paragraph
        // with no spaces as a single "word".
        var count = 0
        var inLatinWord = false
        for ch in text {
            if ch.isWhitespace || ch.isNewline {
                inLatinWord = false
            } else if ch.isCJK {
                count += 1
                inLatinWord = false
            } else if !inLatinWord {
                count += 1
                inLatinWord = true
            }
        }
        words = count
        readingMinutes = max(1, Int(ceil(Double(count) / 300.0)))
    }
}

private extension Character {
    var isCJK: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x3400...0x4DBF).contains(v) ||
               (0x4E00...0x9FFF).contains(v) ||
               (0xF900...0xFAFF).contains(v) ||
               (0x20000...0x2A6DF).contains(v)
    }
}
