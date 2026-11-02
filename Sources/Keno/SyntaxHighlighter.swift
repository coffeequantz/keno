import AppKit

enum TokenKind: Int {
    case keyword, type, string, number, comment, function, attribute, property, tag, heading
}

/// State carried from the end of one line to the start of the next.
struct LexState: Equatable {
    static let normal = LexState(kind: 0, index: 0)
    static let blockComment = LexState(kind: 1, index: 0)
    static func multilineString(_ i: Int) -> LexState { LexState(kind: 2, index: UInt8(i)) }
    static let inTag = LexState(kind: 3, index: 0)
    static let codeFence = LexState(kind: 4, index: 0)

    var kind: UInt8
    var index: UInt8
}

/// Single-pass, allocation-light lexer over UTF-16 code units.
/// With `emit == nil` it only computes the end-of-line state (used for whole-file passes).
final class Lexer {
    typealias Emit = (_ start: Int, _ length: Int, _ kind: TokenKind) -> Void

    let language: Language
    private let lineComments: [[UInt16]]
    private let blockStart: [UInt16]?
    private let blockEnd: [UInt16]?
    private let multiline: [[UInt16]]
    private let quotes: Set<UInt16>
    private let identExtras: Set<UInt16>

    init(language: Language) {
        self.language = language
        lineComments = language.lineComments.map { Array($0.utf16) }
        blockStart = language.blockComment.map { Array($0.0.utf16) }
        blockEnd = language.blockComment.map { Array($0.1.utf16) }
        multiline = language.multilineQuotes.map { Array($0.utf16) }
        quotes = Set(language.quotes.utf16)
        identExtras = Set(language.identifierExtras.utf16)
    }

    func lex(_ s: UnsafeBufferPointer<UInt16>, from state: LexState, emit: Emit?) -> LexState {
        switch language.mode {
        case .code: return lexCode(s, state, emit)
        case .markup: return lexMarkup(s, state, emit)
        case .markdown: return lexMarkdown(s, state, emit)
        }
    }

    // MARK: Character helpers

    @inline(__always) private func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
    @inline(__always) private func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    @inline(__always) private func isAlpha(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127 }
    @inline(__always) private func isUpper(_ c: UInt16) -> Bool { c >= 65 && c <= 90 }
    @inline(__always) private func isIdentStart(_ c: UInt16) -> Bool { isAlpha(c) || (c == 36 && identExtras.contains(36)) }
    @inline(__always) private func isIdent(_ c: UInt16) -> Bool { isAlpha(c) || isDigit(c) || identExtras.contains(c) }

    private func matches(_ s: UnsafeBufferPointer<UInt16>, _ i: Int, _ p: [UInt16]) -> Bool {
        guard i + p.count <= s.count else { return false }
        for k in 0..<p.count where s[i + k] != p[k] { return false }
        return true
    }

    private func find(_ s: UnsafeBufferPointer<UInt16>, _ p: [UInt16], from: Int) -> Int? {
        var i = from
        while i + p.count <= s.count {
            if matches(s, i, p) { return i }
            i += 1
        }
        return nil
    }

    /// Index just past the closing delimiter `d` (skipping backslash escapes), or nil if the line ends first.
    private func stringEnd(_ s: UnsafeBufferPointer<UInt16>, _ d: [UInt16], from: Int) -> Int? {
        var i = from
        while i < s.count {
            if s[i] == 92 { i += 2; continue } // backslash
            if matches(s, i, d) { return i + d.count }
            i += 1
        }
        return nil
    }

    private func nextNonSpace(_ s: UnsafeBufferPointer<UInt16>, _ from: Int) -> Int {
        var i = from
        while i < s.count, s[i] == 32 || s[i] == 9 { i += 1 }
        return i
    }

    private func word(_ s: UnsafeBufferPointer<UInt16>, _ a: Int, _ b: Int) -> String {
        let w = String(decoding: UnsafeBufferPointer(rebasing: s[a..<b]), as: UTF16.self)
        return language.caseInsensitive ? w.lowercased() : w
    }

    // MARK: Code

    private func lexCode(_ s: UnsafeBufferPointer<UInt16>, _ start: LexState, _ emit: Emit?) -> LexState {
        let n = s.count
        var i = 0

        // Continue constructs that span lines.
        if start.kind == 1, let end = blockEnd {
            guard let e = find(s, end, from: 0) else { emit?(0, n, .comment); return start }
            emit?(0, e + end.count, .comment)
            i = e + end.count
        } else if start.kind == 2, Int(start.index) < multiline.count {
            guard let e = stringEnd(s, multiline[Int(start.index)], from: 0) else { emit?(0, n, .string); return start }
            emit?(0, e, .string)
            i = e
        }

        scan: while i < n {
            let c = s[i]
            if isSpace(c) { i += 1; continue }

            if language.dollarVariables, c == 36, i + 1 < n { // $var / ${...}
                var j = i + 1
                if s[j] == 123 { while j < n, s[j] != 125 { j += 1 }; j = min(j + 1, n) }
                else if isIdent(s[j]) { while j < n, isIdent(s[j]) { j += 1 } }
                else { j += 1 }
                emit?(i, j - i, .property)
                i = j
                continue
            }

            if let bs = blockStart, let be = blockEnd, matches(s, i, bs) {
                guard let e = find(s, be, from: i + bs.count) else { emit?(i, n - i, .comment); return .blockComment }
                emit?(i, e + be.count - i, .comment)
                i = e + be.count
                continue
            }

            for lc in lineComments where matches(s, i, lc) {
                // `#` only starts a comment at a word boundary (so `a#b`, `$#` stay code).
                if lc == [35], i > 0, !isSpace(s[i - 1]) { continue }
                emit?(i, n - i, .comment)
                return .normal
            }

            for (k, d) in multiline.enumerated() where matches(s, i, d) {
                guard let e = stringEnd(s, d, from: i + d.count) else { emit?(i, n - i, .string); return .multilineString(k) }
                emit?(i, e - i, .string)
                i = e
                continue scan
            }

            if quotes.contains(c) {
                var j = i + 1
                while j < n {
                    let d = s[j]
                    if d == 92 { j += 2; continue }
                    if d == c { j += 1; break }
                    if d == 10 { break }
                    j += 1
                }
                j = min(j, n)
                if let emit {
                    let k = nextNonSpace(s, j)
                    let isKey = language.colonKeysAreProperties && k < n && s[k] == 58
                    emit(i, j - i, isKey ? .property : .string)
                }
                i = j
                continue
            }

            if isDigit(c) || (c == 46 && i + 1 < n && isDigit(s[i + 1])) {
                var j = i + 1
                while j < n, isIdent(s[j]) || s[j] == 46 { j += 1 }
                emit?(i, j - i, .number)
                i = j
                continue
            }

            if (c == 64 && language.atAttributes) || (c == 35 && language.hashDirectives), i + 1 < n, isAlpha(s[i + 1]) {
                var j = i + 1
                while j < n, isIdent(s[j]) { j += 1 }
                emit?(i, j - i, .attribute)
                i = j
                continue
            }

            if isIdentStart(c) {
                var j = i + 1
                while j < n, isIdent(s[j]) { j += 1 }
                if let emit {
                    let w = word(s, i, j)
                    let k = nextNonSpace(s, j)
                    let next: UInt16 = k < n ? s[k] : 0
                    var kind: TokenKind?
                    if language.keywords.contains(w) { kind = .keyword }
                    else if language.builtins.contains(w) { kind = .type }
                    else if language.colonKeysAreProperties, next == 58, !(k + 1 < n && s[k + 1] == 58) { kind = .property }
                    else if next == 40 { kind = .function } // (
                    else if language.capitalizedAreTypes, isUpper(c) { kind = .type }
                    if let kind { emit(i, j - i, kind) }
                }
                i = j
                continue
            }

            i += 1
        }
        return .normal
    }

    // MARK: HTML / XML

    private static let commentOpen = Array("<!--".utf16)
    private static let commentClose = Array("-->".utf16)

    private func lexMarkup(_ s: UnsafeBufferPointer<UInt16>, _ start: LexState, _ emit: Emit?) -> LexState {
        let n = s.count
        var i = 0
        var state = start
        while i < n {
            switch state.kind {
            case 1: // comment
                if let e = find(s, Self.commentClose, from: i) {
                    emit?(i, e + 3 - i, .comment)
                    i = e + 3
                    state = .normal
                } else {
                    emit?(i, n - i, .comment)
                    return state
                }
            case 3: // inside a tag
                let c = s[i]
                if c == 62 { emit?(i, 1, .tag); i += 1; state = .normal; continue } // >
                if c == 47 || c == 63 { emit?(i, 1, .tag); i += 1; continue } // / ?
                if quotes.contains(c) {
                    var j = i + 1
                    while j < n, s[j] != c { j += 1 }
                    j = min(j + 1, n)
                    emit?(i, j - i, .string)
                    i = j
                    continue
                }
                if isAlpha(c) {
                    var j = i + 1
                    while j < n, isIdent(s[j]) || s[j] == 45 || s[j] == 58 || s[j] == 46 { j += 1 }
                    emit?(i, j - i, .property)
                    i = j
                    continue
                }
                i += 1
            default:
                if matches(s, i, Self.commentOpen) {
                    state = .blockComment
                    continue
                }
                if s[i] == 60, i + 1 < n, isAlpha(s[i + 1]) || s[i + 1] == 47 || s[i + 1] == 33 || s[i + 1] == 63 {
                    var j = i + 1
                    while j < n, s[j] == 47 || s[j] == 33 || s[j] == 63 { j += 1 }
                    while j < n, isIdent(s[j]) || s[j] == 45 || s[j] == 58 || s[j] == 46 { j += 1 }
                    emit?(i, j - i, .tag)
                    i = j
                    state = .inTag
                    continue
                }
                if s[i] == 38 { // &entity;
                    var j = i + 1
                    while j < n, j - i < 12, s[j] != 59, !isSpace(s[j]) { j += 1 }
                    if j < n, s[j] == 59 { emit?(i, j + 1 - i, .number); i = j + 1; continue }
                }
                i += 1
            }
        }
        return state
    }

    // MARK: Markdown

    private static let fence = Array("```".utf16)

    private func lexMarkdown(_ s: UnsafeBufferPointer<UInt16>, _ start: LexState, _ emit: Emit?) -> LexState {
        let n = s.count
        let first = nextNonSpace(s, 0)
        if start.kind == 4 {
            emit?(0, n, .string)
            return matches(s, first, Self.fence) ? .normal : start
        }
        if matches(s, first, Self.fence) { emit?(0, n, .string); return .codeFence }
        guard let emit, first < n else { return .normal }

        let c = s[first]
        if c == 35 { emit(first, n - first, .heading); return .normal } // # heading
        if c == 62 { emit(first, n - first, .comment); return .normal } // > quote
        if (c == 45 || c == 42 || c == 43), first + 1 < n, s[first + 1] == 32 { emit(first, 1, .keyword) } // list
        if isDigit(c) {
            var j = first
            while j < n, isDigit(s[j]) { j += 1 }
            if j < n, s[j] == 46 { emit(first, j + 1 - first, .keyword) }
        }
        var i = first
        while i < n {
            let ch = s[i]
            if ch == 96 { // `code`
                var j = i + 1
                while j < n, s[j] != 96 { j += 1 }
                if j < n { emit(i, j + 1 - i, .string); i = j + 1; continue }
            } else if ch == 91 { // [text](url)
                var j = i + 1
                while j < n, s[j] != 93 { j += 1 }
                if j + 1 < n, s[j + 1] == 40 {
                    var k = j + 2
                    while k < n, s[k] != 41 { k += 1 }
                    if k < n {
                        emit(i, j + 1 - i, .function)
                        emit(j + 1, k + 1 - (j + 1), .property)
                        i = k + 1
                        continue
                    }
                }
            } else if ch == 42 || ch == 95, i + 1 < n, s[i + 1] == ch { // **bold**
                let pair = [ch, ch]
                if let e = find(s, pair, from: i + 2) { emit(i, e + 2 - i, .type); i = e + 2; continue }
            }
            i += 1
        }
        return .normal
    }
}

/// Owns per-line lexer states for a document and paints colors (as layout-manager temporary
/// attributes, so the text storage and undo stack are never touched) for visible lines only.
final class SyntaxHighlighter {
    private let lexer: Lexer
    private weak var textView: NSTextView?
    private let lines: LineIndex
    private var endStates: [LexState] = []
    private var colored: [Bool] = []
    private var buffer: [UInt16] = []

    /// Above this size we skip highlighting entirely to stay fast.
    static let maxLength = 4_000_000

    init(language: Language, textView: NSTextView, lines: LineIndex) {
        lexer = Lexer(language: language)
        self.textView = textView
        self.lines = lines
    }

    var languageName: String { lexer.language.name }

    /// Recomputes every line state (on open / language change).
    func rebuildAll() {
        endStates = []
        colored = []
        if let lm = textView?.layoutManager, lines.length > 0 {
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: lines.length))
        }
        textEdited(NSRange(location: 0, length: lines.length), lineCountBefore: 0)
    }

    func clearColors() {
        guard let lm = textView?.layoutManager, lines.length > 0 else { return }
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: lines.length))
    }

    /// Call after `lines` was rebuilt. Re-lexes from the first edited line until line states
    /// converge with the old ones, so typing costs O(edited lines), not O(file).
    func textEdited(_ edited: NSRange, lineCountBefore oldCount: Int) {
        guard let ns = textView?.string as NSString?, ns.length <= Self.maxLength else { return }
        let newCount = lines.count
        let lineDelta = newCount - oldCount
        let firstLine = min(lines.line(of: edited.location), endStates.count)
        let lastEdited = lines.line(of: NSMaxRange(edited))

        var newStates = Array(endStates.prefix(firstLine))
        var newColored = Array(colored.prefix(firstLine))
        newStates.reserveCapacity(newCount)
        newColored.reserveCapacity(newCount)

        var state = firstLine > 0 ? newStates[firstLine - 1] : .normal
        var i = firstLine
        while i < newCount {
            state = lex(line: i, in: ns, from: state, emit: nil)
            newStates.append(state)
            newColored.append(false)
            let old = i - lineDelta
            if i > lastEdited, old >= 0, old < endStates.count, endStates[old] == state {
                newStates.append(contentsOf: endStates[(old + 1)...])
                newColored.append(contentsOf: colored[(old + 1)...])
                break
            }
            i += 1
        }
        endStates = newStates
        colored = newColored
    }

    /// Paints any visible (plus a small margin) lines that aren't colored yet.
    func colorVisible() {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer,
              endStates.count == lines.count else { return }
        let ns = tv.string as NSString
        guard ns.length > 0 else { return }
        var rect = tv.visibleRect
        rect = rect.insetBy(dx: 0, dy: -rect.height / 2)
        let glyphs = lm.glyphRange(forBoundingRect: rect, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = lines.line(of: chars.location)
        let last = lines.line(of: NSMaxRange(chars))
        guard first <= last else { return }
        for line in first...last where line < colored.count && !colored[line] {
            let range = lines.range(ofLine: line)
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            let start = line > 0 ? endStates[line - 1] : .normal
            _ = lex(line: line, in: ns, from: start) { loc, len, kind in
                lm.addTemporaryAttribute(.foregroundColor, value: SyntaxColors.color(kind),
                                         forCharacterRange: NSRange(location: range.location + loc, length: len))
            }
            colored[line] = true
        }
    }

    private func lex(line: Int, in ns: NSString, from state: LexState, emit: Lexer.Emit?) -> LexState {
        let range = lines.range(ofLine: line)
        if buffer.count < range.length { buffer = [UInt16](repeating: 0, count: max(range.length, 256)) }
        return buffer.withUnsafeMutableBufferPointer { buf -> LexState in
            ns.getCharacters(buf.baseAddress!, range: range)
            return lexer.lex(UnsafeBufferPointer(rebasing: buf[0..<range.length]), from: state, emit: emit)
        }
    }
}

/// Line start offsets for a document, shared by the gutter and the highlighter.
final class LineIndex {
    private(set) var starts: [Int] = [0]
    private(set) var length = 0
    private var buffer = [UInt16](repeating: 0, count: 65_536)

    var count: Int { starts.count }

    func rebuild(_ ns: NSString) {
        let len = ns.length
        var out = [0]
        out.reserveCapacity(max(16, starts.count + 8))
        var loc = 0
        buffer.withUnsafeMutableBufferPointer { buf in
            while loc < len {
                let n = min(buf.count, len - loc)
                ns.getCharacters(buf.baseAddress!, range: NSRange(location: loc, length: n))
                for j in 0..<n where buf[j] == 10 { out.append(loc + j + 1) }
                loc += n
            }
        }
        starts = out
        length = len
    }

    /// Index of the line containing character `char`.
    func line(of char: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= char { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func range(ofLine i: Int) -> NSRange {
        let s = starts[i]
        let e = i + 1 < starts.count ? starts[i + 1] : length
        return NSRange(location: s, length: e - s)
    }
}

/// VS Code Dark+ / Light+ inspired palette; adapts to the system appearance at draw time.
enum SyntaxColors {
    private static func c(_ light: UInt32, _ dark: UInt32) -> NSColor {
        func rgb(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        let l = rgb(light), d = rgb(dark)
        return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l }
    }

    private static let table: [NSColor] = [
        c(0x0000FF, 0x569CD6), // keyword
        c(0x267F99, 0x4EC9B0), // type
        c(0xA31515, 0xCE9178), // string
        c(0x098658, 0xB5CEA8), // number
        c(0x008000, 0x6A9955), // comment
        c(0x795E26, 0xDCDCAA), // function
        c(0xAF00DB, 0xC586C0), // attribute / directive
        c(0x001080, 0x9CDCFE), // property / variable / key
        c(0x800000, 0x569CD6), // tag
        c(0x0451A5, 0x569CD6), // heading
    ]

    static func color(_ kind: TokenKind) -> NSColor { table[kind.rawValue] }
}
