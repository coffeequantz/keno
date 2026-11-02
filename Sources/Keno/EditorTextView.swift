import AppKit

/// NSTextView with the handful of code-editing behaviors you use daily:
/// auto-indent, soft tabs, indent/outdent, toggle line comment.
final class EditorTextView: NSTextView {
    var indentUnit = "    "
    var lineEnding = "\n"
    var commentStyle: CommentStyle?

    private var ns: NSString { string as NSString }

    // MARK: Newline with auto-indent

    override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        let lineStart = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
        var i = lineStart
        while i < sel.location, isIndentChar(ns.character(at: i)) { i += 1 }
        let indent = ns.substring(with: NSRange(location: lineStart, length: i - lineStart))

        // Character before the cursor (ignoring trailing spaces) and after the selection.
        var p = sel.location - 1
        while p >= lineStart, ns.character(at: p) == 0x20 { p -= 1 }
        let before: unichar? = p >= lineStart ? ns.character(at: p) : nil
        let afterIdx = NSMaxRange(sel)
        let after: unichar? = afterIdx < ns.length ? ns.character(at: afterIdx) : nil

        let openers: [unichar: unichar] = [0x7B: 0x7D, 0x5B: 0x5D, 0x28: 0x29] // { [ (
        if let b = before, let closer = openers[b] {
            if after == closer {
                // `{|}` -> put the closer on its own line, cursor indented in between.
                let first = lineEnding + indent + indentUnit
                insertText(first + lineEnding + indent, replacementRange: sel)
                setSelectedRange(NSRange(location: sel.location + (first as NSString).length, length: 0))
            } else {
                insertText(lineEnding + indent + indentUnit, replacementRange: sel)
            }
        } else if before == 0x3A, commentStyle?.prefix == "#" { // ':' in Python-like files
            insertText(lineEnding + indent + indentUnit, replacementRange: sel)
        } else {
            insertText(lineEnding + indent, replacementRange: sel)
        }
        scrollRangeToVisible(selectedRange())
    }

    // MARK: Tabs

    override func insertTab(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length > 0, ns.substring(with: sel).contains("\n") {
            indentLines(sender)
            return
        }
        if indentUnit == "\t" {
            insertText("\t", replacementRange: sel)
        } else {
            let lineStart = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
            let column = sel.location - lineStart
            let width = indentUnit.count
            insertText(String(repeating: " ", count: width - column % width), replacementRange: sel)
        }
    }

    override func insertBacktab(_ sender: Any?) { outdentLines(sender) }

    @objc func indentLines(_ sender: Any?) {
        transformSelectedLines { lines in
            lines.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? $0 : self.indentUnit + $0 }
        }
    }

    @objc func outdentLines(_ sender: Any?) {
        let width = indentUnit == "\t" ? 1 : indentUnit.count
        transformSelectedLines { lines in
            lines.map { line in
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                var n = 0
                for c in line { if c == " " && n < width { n += 1 } else { break } }
                return String(line.dropFirst(n))
            }
        }
    }

    // MARK: Toggle comment

    @objc func toggleComment(_ sender: Any?) {
        guard let style = commentStyle else { NSSound.beep(); return }
        transformSelectedLines { lines in
            let nonBlank = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !nonBlank.isEmpty else { return lines }
            let allCommented = nonBlank.allSatisfy {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix(style.prefix)
            }
            if allCommented {
                return lines.map { line in
                    guard let r = line.range(of: style.prefix) else { return line }
                    var out = line
                    var end = r.upperBound
                    if end < out.endIndex, out[end] == " " { end = out.index(after: end) }
                    out.removeSubrange(r.lowerBound..<end)
                    if let suffix = style.suffix, let s = out.range(of: suffix, options: .backwards) {
                        var start = s.lowerBound
                        if start > out.startIndex, out[out.index(before: start)] == " " { start = out.index(before: start) }
                        out.removeSubrange(start..<s.upperBound)
                    }
                    return out
                }
            }
            // Comment at the smallest indentation column, like VS Code.
            let minIndent = nonBlank.map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }.min() ?? 0
            return lines.map { line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
                let idx = line.index(line.startIndex, offsetBy: minIndent)
                var out = line
                out.insert(contentsOf: style.prefix + " ", at: idx)
                if let suffix = style.suffix { out += " " + suffix }
                return out
            }
        }
    }

    // MARK: Helpers

    private func isIndentChar(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }

    /// Applies `transform` to the full lines touched by the selection as one undoable edit.
    private func transformSelectedLines(_ transform: ([String]) -> [String]) {
        var sel = selectedRange()
        let original = sel
        // A selection ending exactly at the start of a line shouldn't include that line.
        if sel.length > 0, ns.character(at: NSMaxRange(sel) - 1) == 0x0A { sel.length -= 1 }
        let range = ns.lineRange(for: sel)
        let block = ns.substring(with: range)

        let hasTrailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }
        // Keep \r out of the transform so CRLF files behave.
        let crlf = lines.map { $0.hasSuffix("\r") }
        lines = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }

        var newLines = transform(lines)
        for i in newLines.indices where i < crlf.count && crlf[i] { newLines[i] += "\r" }
        let replacement = newLines.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        if replacement == block { return }

        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: typingAttributes))
        didChangeText()

        let newLength = (replacement as NSString).length
        if original.length == 0 && lines.count == 1 {
            // Keep the caret at the same distance from the end of the line.
            let fromEnd = NSMaxRange(range) - original.location
            setSelectedRange(NSRange(location: max(range.location, range.location + newLength - fromEnd), length: 0))
        } else {
            setSelectedRange(NSRange(location: range.location, length: newLength - (hasTrailingNewline ? 1 : 0)))
        }
    }
}

// MARK: - Line numbers

final class LineNumberRulerView: NSRulerView {
    private weak var textView: EditorTextView?
    private let lines: LineIndex
    private var numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(textView: EditorTextView, scrollView: NSScrollView, lines: LineIndex) {
        self.textView = textView
        self.lines = lines
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        clipsToBounds = true
    }

    required init(coder: NSCoder) { fatalError() }

    func fontDidChange() {
        numberFont = .monospacedDigitSystemFont(ofSize: max(Theme.fontSize - 2, 8), weight: .regular)
        linesChanged()
    }

    func linesChanged() {
        let digits = max(3, String(lines.count).count)
        let w = ("0" as NSString).size(withAttributes: [.font: numberFont]).width
        let thickness = ceil(CGFloat(digits) * w + 24)
        if abs(thickness - ruleThickness) > 0.5 { ruleThickness = thickness }
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        dirtyRect.intersection(bounds).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let length = lines.length
        let visible = tv.visibleRect
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let caretLine = lines.line(of: tv.selectedRange().location)
        let originY = tv.textContainerOrigin.y

        let dim: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: Theme.gutterForeground]
        let bright: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: Theme.editorForeground]

        func drawNumber(_ line: Int, fragment: NSRect) {
            let y = convert(NSPoint(x: 0, y: fragment.minY + originY), from: tv).y
            let label = String(line + 1) as NSString
            let attrs = line == caretLine ? bright : dim
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 12,
                                   y: y + (fragment.height - size.height) / 2),
                       withAttributes: attrs)
        }

        var line = lines.line(of: charRange.location)
        let end = NSMaxRange(charRange)
        let starts = lines.starts
        while line < starts.count {
            let start = starts[line]
            if start >= length || start > end { break }
            let glyph = lm.glyphIndexForCharacter(at: start)
            let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            drawNumber(line, fragment: fragment)
            line += 1
        }
        // Empty last line (file ends with a newline, or is empty).
        if starts.last == length, !lm.extraLineFragmentRect.isEmpty {
            drawNumber(starts.count - 1, fragment: lm.extraLineFragmentRect)
        }
    }
}
