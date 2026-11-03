import AppKit

enum DocumentError: LocalizedError {
    case binary(String)
    var errorDescription: String? {
        switch self {
        case .binary(let name): return "“\(name)” appears to be a binary file and can’t be opened as text."
        }
    }
}

/// One open file (or untitled buffer). Owns its own text view, so each tab keeps
/// its own undo stack, selection and scroll position.
final class Document: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    var url: URL? {
        didSet {
            textView.commentStyle = CommentStyle.forURL(url)
            updateLanguage()
            if let url, url != oldValue { image?.reload(url: url) }
        }
    }
    var encoding: String.Encoding = .utf8
    var fileModDate: Date?
    var untitledNumber = 0
    /// Preview tabs (single-click in the explorer) get replaced by the next preview, like VS Code.
    var isPreview = false { didSet { if oldValue != isPreview { onStateChange?() } } }
    private(set) var isDirty = false

    var onStateChange: (() -> Void)?

    let undo = UndoManager()
    let textView: EditorTextView
    let scrollView: NSScrollView
    let ruler: LineNumberRulerView
    let lines = LineIndex()
    /// Set for image tabs, which show a read-only preview instead of the text view.
    let image: ImagePreviewView?
    var isImage: Bool { image != nil }
    /// The view shown in the editor area for this tab.
    var contentView: NSView { image ?? scrollView }
    /// The view that should receive keyboard focus.
    var focusView: NSView { image ?? textView }
    private(set) var highlighter: SyntaxHighlighter?

    var displayName: String { url?.lastPathComponent ?? "Untitled-\(untitledNumber)" }

    static func openImage(url: URL) -> Document {
        let doc = Document(url: url, text: "", wordWrap: false, image: ImagePreviewView(url: url))
        doc.fileModDate = modificationDate(of: url)
        return doc
    }

    init(url: URL?, text: String, wordWrap: Bool, image: ImagePreviewView? = nil) {
        self.image = image
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true // big win for large files
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        layout.addTextContainer(container)

        textView = EditorTextView(frame: .zero, textContainer: container)
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.editorBackground
        scrollView.documentView = textView

        ruler = LineNumberRulerView(textView: textView, scrollView: scrollView, lines: lines)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        self.url = url
        super.init()

        storage.delegate = self
        configureTextView()
        scrollView.rulersVisible = true // must come after `usesRuler = false`, which hides rulers
        textView.commentStyle = CommentStyle.forURL(url)
        updateLanguage()
        setText(text)
        setWordWrap(wordWrap)

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                                               name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                                               name: NSView.frameDidChangeNotification, object: clip)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func viewportChanged() {
        ruler.needsDisplay = true
        highlighter?.colorVisible()
    }

    /// Called when the tab becomes visible (layout exists only once the view is on screen).
    func didBecomeVisible() {
        scrollView.rulersVisible = true
        DispatchQueue.main.async { [weak self] in self?.highlighter?.colorVisible() }
    }

    private func updateLanguage() {
        let language = Language.forURL(url)
        if language?.name == highlighter?.languageName { return }
        highlighter?.clearColors()
        highlighter = language.map { SyntaxHighlighter(language: $0, textView: textView, lines: lines) }
        highlighter?.rebuildAll()
        didBecomeVisible()
    }

    var languageName: String { highlighter?.languageName ?? "Plain Text" }

    private func configureTextView() {
        let tv = textView
        tv.delegate = self
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.usesFontPanel = false
        tv.usesRuler = false
        tv.smartInsertDeleteEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        if #available(macOS 14.0, *) { tv.inlinePredictionType = .no }
        if #available(macOS 15.0, *) { tv.writingToolsBehavior = .none }
        tv.drawsBackground = true
        tv.backgroundColor = Theme.editorBackground
        tv.insertionPointColor = Theme.editorForeground
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        applyFont()
    }

    func applyFont() {
        let font = Theme.editorFont
        let para = NSMutableParagraphStyle()
        let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        para.tabStops = []
        para.defaultTabInterval = charWidth * 4
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Theme.editorForeground,
            .paragraphStyle: para,
        ]
        textView.font = font
        textView.defaultParagraphStyle = para
        textView.typingAttributes = attrs
        if let storage = textView.textStorage, storage.length > 0 {
            storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
        }
        ruler.fontDidChange()
    }

    private func setText(_ text: String) {
        guard let storage = textView.textStorage else { return }
        storage.setAttributedString(NSAttributedString(string: text, attributes: textView.typingAttributes))
        // Replacing the storage leaves the caret at the end, which makes AppKit scroll
        // to the bottom on first display. Start at the top like every editor does.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.lineEnding = text.contains("\r\n") ? "\r\n" : "\n"
        textView.indentUnit = Self.detectIndent(text)
        didBecomeVisible()
    }

    func setWordWrap(_ wrap: Bool) {
        guard let container = textView.textContainer else { return }
        let big = CGFloat.greatestFiniteMagnitude
        if wrap {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            let w = scrollView.contentSize.width
            textView.setFrameSize(NSSize(width: w, height: textView.frame.height))
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: w, height: big)
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = [.width, .height]
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: big, height: big)
        }
        ruler.needsDisplay = true
    }

    // MARK: File IO

    static func read(url: URL) throws -> (String, String.Encoding) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) {
            return (s, .utf16)
        }
        if data.prefix(8192).contains(0) { throw DocumentError.binary(url.lastPathComponent) }
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8) }
        var converted: NSString?
        var lossy = ObjCBool(false)
        let raw = NSString.stringEncoding(for: data, encodingOptions: [.allowLossyKey: false], convertedString: &converted, usedLossyConversion: &lossy)
        if raw != 0, let converted { return (converted as String, String.Encoding(rawValue: raw)) }
        return (String(decoding: data, as: UTF8.self), .utf8)
    }

    static func open(url: URL, wordWrap: Bool) throws -> Document {
        let (text, enc) = try read(url: url)
        let doc = Document(url: url, text: text, wordWrap: wordWrap)
        doc.encoding = enc
        doc.fileModDate = modificationDate(of: url)
        return doc
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func write(to target: URL) throws {
        guard !isImage else { return } // previews are read-only
        let text = textView.string
        let data: Data
        if let d = text.data(using: encoding) {
            data = d
        } else {
            encoding = .utf8
            data = Data(text.utf8)
        }
        try data.write(to: target, options: .atomic)
        url = target
        fileModDate = Self.modificationDate(of: target)
        isDirty = false
        isPreview = false
        onStateChange?()
    }

    /// Reloads from disk if the file changed externally and we have no unsaved edits.
    func reloadIfChangedOnDisk() {
        guard let url, !isDirty, let mod = Self.modificationDate(of: url), mod != fileModDate else { return }
        if let image {
            fileModDate = mod
            image.reload()
            return
        }
        guard let (text, enc) = try? Self.read(url: url) else { return }
        fileModDate = mod
        encoding = enc
        if text == textView.string { return }
        let sel = textView.selectedRange()
        let origin = scrollView.contentView.bounds.origin
        setText(text)
        undo.removeAllActions()
        let len = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private static func detectIndent(_ text: String) -> String {
        var tabs = 0, spaces = 0, scanned = 0
        text.enumerateLines { line, stop in
            if line.hasPrefix("\t") { tabs += 1 } else if line.hasPrefix("  ") { spaces += 1 }
            scanned += 1
            if scanned > 500 { stop = true }
        }
        return tabs > spaces ? "\t" : "    "
    }

    // MARK: NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let before = lines.count
        lines.rebuild(textStorage.string as NSString)
        highlighter?.textEdited(editedRange, lineCountBefore: before)
        ruler.linesChanged()
        NotificationCenter.default.post(name: Self.textDidChange, object: self)
    }

    func textDidChange(_ notification: Notification) {
        highlighter?.colorVisible()
        if !isDirty || isPreview {
            isDirty = true
            isPreview = false
            onStateChange?()
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        ruler.needsDisplay = true
        NotificationCenter.default.post(name: Self.selectionDidChange, object: self)
    }

    /// Posted (object: the document) for every text change, including reloads; drives the status bar.
    static let textDidChange = Notification.Name("KenoDocumentTextDidChange")
    static let selectionDidChange = Notification.Name("KenoDocumentSelectionDidChange")
}

// MARK: - Dictation

extension Document: DictationTarget {
    var dictationLabel: String { displayName }
    var dictationStreamsText: Bool { true }

    /// The text just before the cursor, so Whisper continues in the same style and spelling.
    func dictationPrompt() -> String? {
        let ns = textView.string as NSString
        let loc = textView.selectedRange().location
        let start = max(0, loc - 220)
        let tail = ns.substring(with: NSRange(location: start, length: loc - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? nil : tail
    }

    /// Inserts at the cursor (replacing a selection) with sensible spacing, as its own undo step.
    func insertDictation(_ text: String, newParagraph: Bool) {
        let tv = textView
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        func isBreak(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }

        var prefix = ""
        if sel.location > 0 {
            let prev = ns.character(at: sel.location - 1)
            if newParagraph {
                let blankLineAlready = isBreak(prev) && sel.location > 1 && isBreak(ns.character(at: sel.location - 2))
                prefix = blankLineAlready ? "" : isBreak(prev) ? tv.lineEnding : tv.lineEnding + tv.lineEnding
            } else if !isBreak(prev), prev != 0x20, prev != 0x09 {
                prefix = " "
            }
        }
        // Dictating in front of a word: keep a space between the new text and it.
        var suffix = ""
        let after = NSMaxRange(sel)
        if after < ns.length, let u = UnicodeScalar(ns.character(at: after)), CharacterSet.alphanumerics.contains(u) {
            suffix = " "
        }

        tv.breakUndoCoalescing()
        tv.insertText(prefix + text + suffix, replacementRange: sel)
        if !suffix.isEmpty { // cursor before the space, so the next piece continues the sentence
            let end = tv.selectedRange().location - 1
            tv.setSelectedRange(NSRange(location: end, length: 0))
        }
        tv.breakUndoCoalescing()
        tv.scrollRangeToVisible(tv.selectedRange())
    }
}

// MARK: - Comment syntax

struct CommentStyle {
    let prefix: String
    let suffix: String?

    static func forURL(_ url: URL?) -> CommentStyle? {
        guard let url else { return nil }
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if ["makefile", "dockerfile", "gemfile", "rakefile", "podfile", ".gitignore", ".env", ".zshrc", ".bashrc", ".bash_profile", ".zprofile"].contains(name) {
            return CommentStyle(prefix: "#", suffix: nil)
        }
        switch ext {
        case "swift", "c", "h", "m", "mm", "cpp", "cc", "cxx", "hpp", "hh", "js", "mjs", "cjs", "jsx", "ts", "tsx",
             "java", "kt", "kts", "go", "rs", "cs", "scala", "dart", "php", "jsonc", "json5", "zig", "groovy",
             "gradle", "scss", "less", "proto", "glsl", "metal", "v", "sol":
            return CommentStyle(prefix: "//", suffix: nil)
        case "py", "rb", "sh", "zsh", "bash", "fish", "yml", "yaml", "toml", "pl", "pm", "r", "conf", "mk",
             "cmake", "ps1", "nim", "cr", "ex", "exs", "tf", "properties", "env", "gitignore", "dockerignore", "jl", "coffee":
            return CommentStyle(prefix: "#", suffix: nil)
        case "sql", "lua", "hs", "elm", "ada":
            return CommentStyle(prefix: "--", suffix: nil)
        case "lisp", "clj", "cljs", "el", "scm", "asm", "s", "ini":
            return CommentStyle(prefix: ";", suffix: nil)
        case "tex", "erl", "sty":
            return CommentStyle(prefix: "%", suffix: nil)
        case "vim":
            return CommentStyle(prefix: "\"", suffix: nil)
        case "html", "htm", "xml", "svg", "md", "markdown", "plist", "vue", "svelte", "xib", "storyboard":
            return CommentStyle(prefix: "<!--", suffix: "-->")
        case "css":
            return CommentStyle(prefix: "/*", suffix: "*/")
        default:
            return nil
        }
    }
}
