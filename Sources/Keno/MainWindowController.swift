import AppKit

final class MainWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate, NSMenuItemValidation {
    let explorer = FileExplorer()
    let editor = EditorArea()
    let terminal = TerminalPanel()

    private let outerSplit = ThemedSplitView()
    private let innerSplit = ThemedSplitView()

    var onClose: ((MainWindowController) -> Void)?
    private(set) var folderURL: URL?

    private let defaults = UserDefaults.standard
    private var sidebarWidth: CGFloat {
        get { min(max(CGFloat(defaults.object(forKey: "sidebarWidth") as? Double ?? 240), 140), 600) }
        set { defaults.set(Double(newValue), forKey: "sidebarWidth") }
    }
    /// Terminal beside the editor (true) or below it (false).
    private var terminalOnRight: Bool {
        get { defaults.bool(forKey: "terminalOnRight") }
        set { defaults.set(newValue, forKey: "terminalOnRight") }
    }
    /// Remembered separately per position: height when at the bottom, width when on the right.
    private var terminalSize: CGFloat {
        get { CGFloat(defaults.object(forKey: terminalOnRight ? "terminalWidth" : "terminalHeight") as? Double ?? (terminalOnRight ? 480 : 260)) }
        set { defaults.set(Double(newValue), forKey: terminalOnRight ? "terminalWidth" : "terminalHeight") }
    }
    private var innerExtent: CGFloat { innerSplit.isVertical ? innerSplit.bounds.width : innerSplit.bounds.height }
    private var terminalExtent: CGFloat { innerSplit.isVertical ? terminal.frame.width : terminal.frame.height }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 600, height: 400)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.title = "Keno"
        super.init(window: window)
        window.delegate = self

        outerSplit.isVertical = true
        outerSplit.dividerStyle = .thin
        outerSplit.delegate = self
        innerSplit.isVertical = terminalOnRight
        innerSplit.dividerStyle = .thin
        innerSplit.delegate = self

        // Classic (frame-based) split views: predictable sizing, no constraint fights.
        // Hidden panels are removed from their split view entirely (NSSplitView would
        // otherwise keep drawing a divider next to them).
        if !defaults.bool(forKey: "sidebarHidden") { outerSplit.addSubview(explorer) }
        outerSplit.addSubview(innerSplit)
        innerSplit.addSubview(editor)

        window.contentView = outerSplit
        if !window.setFrameUsingName("KenoMainWindow") { window.center() }
        window.setFrameAutosaveName("KenoMainWindow")

        outerSplit.adjustSubviews()
        innerSplit.adjustSubviews()
        if explorerShown { outerSplit.setPosition(sidebarWidth, ofDividerAt: 0) }

        wireUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func wireUp() {
        explorer.onOpenFile = { [weak self] url, preview in self?.editor.open(url: url, preview: preview) }
        explorer.onItemMoved = { [weak self] old, new in self?.editor.itemMoved(from: old, to: new) }
        explorer.onOpenTerminal = { [weak self] dir in
            self?.showTerminal(createIfNeeded: false)
            self?.terminal.newTerminal(in: dir)
        }
        editor.onChange = { [weak self] in self?.updateTitle() }
        terminal.defaultDirectory = { [weak self] in self?.folderURL }
        terminal.onEmpty = { [weak self] in self?.hideTerminal() }
        terminal.onHide = { [weak self] in self?.hideTerminal() }
        terminal.onTogglePosition = { [weak self] in self?.toggleTerminalPosition(nil) }
        terminal.setPosition(onRight: terminalOnRight)
        updateTitle()
    }

    // MARK: Folder

    func setFolder(_ url: URL?) {
        folderURL = url?.resolvingSymlinksInPath().standardizedFileURL
        explorer.setRoot(folderURL)
        editor.defaultSaveDirectory = folderURL
        if let folderURL { RecentFolders.add(folderURL) }
        updateTitle()
    }

    private func updateTitle() {
        guard let window else { return }
        let doc = editor.current
        let folderName = folderURL?.lastPathComponent
        window.title = doc?.displayName ?? folderName ?? "Keno"
        window.subtitle = doc != nil ? (folderName ?? "") : ""
        window.representedURL = doc?.url ?? folderURL
        window.isDocumentEdited = doc?.isDirty ?? false
        if let url = doc?.url { explorer.reveal(url) }
    }

    // MARK: Session (open tabs per folder)

    func saveSession() {
        guard let folderURL else { return }
        var sessions = defaults.dictionary(forKey: "sessions") as? [String: [String: Any]] ?? [:]
        let files = editor.documents.compactMap { $0.url?.path }
        sessions[folderURL.path] = ["files": files, "selected": editor.current?.url?.path ?? ""]
        defaults.set(sessions, forKey: "sessions")
        defaults.set(folderURL.path, forKey: "lastFolder")
        defaults.set(!explorerShown, forKey: "sidebarHidden")
    }

    func restoreSession() {
        guard let folderURL,
              let s = (defaults.dictionary(forKey: "sessions") as? [String: [String: Any]])?[folderURL.path],
              let files = s["files"] as? [String] else { return }
        for path in files where FileManager.default.fileExists(atPath: path) {
            editor.open(url: URL(fileURLWithPath: path))
        }
        if let sel = s["selected"] as? String, !sel.isEmpty,
           let i = editor.documents.firstIndex(where: { $0.url?.path == sel }) {
            editor.select(i)
        }
    }

    // MARK: Panels

    private var explorerShown: Bool { explorer.superview != nil }
    private var terminalShown: Bool { terminal.superview != nil }

    private func showTerminal(createIfNeeded: Bool = true) {
        if !terminalShown {
            innerSplit.addSubview(terminal)
            innerSplit.adjustSubviews()
            applyTerminalSize()
        }
        if createIfNeeded && terminal.sessions.isEmpty { terminal.newTerminal(in: nil) }
        terminal.focus()
    }

    private func hideTerminal() {
        guard terminalShown else { return }
        terminalSize = terminalExtent
        terminal.removeFromSuperview() // shells keep running; only the view is detached
        innerSplit.adjustSubviews()
        editor.focus()
    }

    private func applyTerminalSize() {
        let total = innerExtent
        let size = min(terminalSize, total - 160)
        innerSplit.setPosition(total - size - innerSplit.dividerThickness, ofDividerAt: 0)
    }

    /// Switches the terminal between below the editor and beside it.
    @objc func toggleTerminalPosition(_ sender: Any?) {
        if terminalShown { terminalSize = terminalExtent }
        terminalOnRight.toggle()
        innerSplit.isVertical = terminalOnRight
        terminal.setPosition(onRight: terminalOnRight)
        innerSplit.adjustSubviews()
        if !terminalShown {
            showTerminal()
        } else {
            applyTerminalSize()
        }
        innerSplit.needsDisplay = true
    }

    // MARK: Actions (reached through the responder chain from the menu)

    @objc func newFile(_ sender: Any?) { editor.newUntitled() }

    @objc func openAnything(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = folderURL
        guard panel.runModal() == .OK else { return }
        (NSApp.delegate as? AppDelegate)?.open(urls: panel.urls, preferring: self)
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Open Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        (NSApp.delegate as? AppDelegate)?.open(urls: [url], preferring: self)
    }

    @objc func saveFile(_ sender: Any?) { if let d = editor.current { editor.save(d) } }
    @objc func saveFileAs(_ sender: Any?) { if let d = editor.current { editor.saveAs(d) } }
    @objc func saveAllFiles(_ sender: Any?) { editor.saveAll() }

    @objc func closeEditorTab(_ sender: Any?) {
        if editor.documents.isEmpty { window?.performClose(sender) } else { _ = editor.closeCurrent() }
    }

    @objc func toggleExplorer(_ sender: Any?) {
        if !explorerShown {
            outerSplit.addSubview(explorer, positioned: .below, relativeTo: innerSplit)
            outerSplit.adjustSubviews()
            outerSplit.setPosition(sidebarWidth, ofDividerAt: 0)
        } else {
            sidebarWidth = explorer.frame.width
            explorer.removeFromSuperview()
            outerSplit.adjustSubviews()
        }
        defaults.set(!explorerShown, forKey: "sidebarHidden")
    }

    /// VS Code semantics: hidden → show+focus; visible but unfocused → focus; focused → hide.
    @objc func toggleTerminal(_ sender: Any?) {
        if !terminalShown {
            showTerminal()
        } else if terminal.containsFirstResponder {
            hideTerminal()
        } else {
            showTerminal()
        }
    }

    @objc func newTerminal(_ sender: Any?) {
        showTerminal(createIfNeeded: false)
        terminal.newTerminal(in: nil)
    }

    @objc func killTerminal(_ sender: Any?) { terminal.closeCurrent() }

    @objc func formatDocument(_ sender: Any?) {
        guard let doc = editor.current, !doc.isImage else { return }
        guard let url = doc.url else {
            showMessage("Save the file first so Keno knows which formatter to use.")
            return
        }
        let original = doc.textView.string
        Formatter.format(text: original, url: url, projectRoot: folderURL) { [weak self, weak doc] outcome in
            guard let self, let doc else { return }
            switch outcome {
            case .formatted(let text):
                // Don't clobber edits made while the formatter was running.
                if doc.textView.string == original { doc.applyFormatted(text) }
            case .unchanged:
                break
            case .noFormatter(let tools):
                self.showMessage(tools.isEmpty
                    ? "No formatter is configured for “.\(url.pathExtension)” files."
                    : "No formatter found for “.\(url.pathExtension)” files.",
                    info: tools.isEmpty ? nil : "Install one of: \(tools.joined(separator: ", ")) (e.g. with Homebrew or npm).")
            case .failed(let message):
                self.showMessage("Formatting failed", info: message)
            }
        }
    }

    private func showMessage(_ text: String, info: String? = nil) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = text
        if let info { alert.informativeText = info }
        alert.beginSheetModal(for: window)
    }

    @objc func toggleWordWrap(_ sender: Any?) { editor.wordWrap.toggle() }

    @objc func zoomIn(_ sender: Any?) { Theme.fontSize += 1 }
    @objc func zoomOut(_ sender: Any?) { Theme.fontSize -= 1 }
    @objc func resetZoom(_ sender: Any?) { Theme.fontSize = Theme.defaultFontSize }

    @objc func nextTab(_ sender: Any?) {
        if terminal.containsFirstResponder { terminal.selectNext() } else { editor.selectNext() }
    }

    @objc func previousTab(_ sender: Any?) {
        if terminal.containsFirstResponder { terminal.selectPrevious() } else { editor.selectPrevious() }
    }

    @objc func focusEditor(_ sender: Any?) { editor.focus() }
    @objc func focusExplorer(_ sender: Any?) {
        if !explorerShown { toggleExplorer(nil) }
        window?.makeFirstResponder(explorer.subviews.compactMap { ($0 as? NSScrollView)?.documentView }.first)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleWordWrap(_:)):
            item.state = editor.wordWrap ? .on : .off
        case #selector(toggleTerminalPosition(_:)):
            item.title = terminalOnRight ? "Move Terminal to Bottom" : "Move Terminal to Right"
        case #selector(toggleExplorer(_:)):
            item.title = explorerShown ? "Hide Explorer" : "Show Explorer"
        case #selector(saveFile(_:)), #selector(saveFileAs(_:)), #selector(formatDocument(_:)):
            return editor.current.map { !$0.isImage } ?? false
        case #selector(killTerminal(_:)):
            return !terminal.sessions.isEmpty
        default: break
        }
        return true
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool { editor.confirmCloseAll() }

    func windowWillClose(_ notification: Notification) {
        saveSession()
        terminal.terminateAll()
        onClose?(self)
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        splitView === outerSplit ? 140 : 120
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        if splitView === outerSplit { return splitView.bounds.width - 300 }
        return innerExtent - (innerSplit.isVertical ? 200 : 60)
    }

    /// Window resizes go to the editor; the sidebar and terminal keep their size.
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== explorer && view !== terminal
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let split = notification.object as? NSSplitView, window?.inLiveResize == false else { return }
        if split === outerSplit, explorerShown, explorer.frame.width > 0 { sidebarWidth = explorer.frame.width }
        if split === innerSplit, terminalShown, terminalExtent > 0 { terminalSize = terminalExtent }
    }
}

/// Thin dividers in the theme's separator color.
final class ThemedSplitView: NSSplitView {
    override var dividerColor: NSColor { Theme.separator }
}

enum RecentFolders {
    private static let key = "recentFolders"

    static var all: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func add(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(12)), forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
