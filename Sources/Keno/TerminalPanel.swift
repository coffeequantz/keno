import AppKit
import SwiftTerm

final class TerminalSession {
    let view: LocalProcessTerminalView
    var title: String
    var running = true

    init(view: LocalProcessTerminalView, title: String) {
        self.view = view
        self.title = title
    }
}

/// Draws with Metal, so busy terminals render on their own thread and leave the main thread free.
/// SwiftTerm needs a window before it can switch; if Metal can't start, the view stays on CoreGraphics.
final class KenoTerminalView: LocalProcessTerminalView {
    private var triedMetal = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !triedMetal else { return }
        triedMetal = true
        do {
            try setUseMetal(true)
        } catch {
            NSLog("Keno: Metal unavailable, using CoreGraphics: \(error)")
        }
    }

    /// SwiftTerm's Metal surface covers this view but can't take keyboard focus,
    /// so clicks must land on the terminal itself or focus would stay where it was.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit?.layer is CAMetalLayer ? self : hit
    }
}

/// Bottom panel with tabbed terminals running your login shell.
final class TerminalPanel: NSView, LocalProcessTerminalViewDelegate {
    private let tabBar = TabBarView()
    private let content = NSView()
    private(set) var sessions: [TerminalSession] = []
    private(set) var selectedIndex = -1

    /// Called when the last terminal exits, so the window can hide the panel.
    var onEmpty: (() -> Void)?
    /// Default working directory for new terminals.
    var defaultDirectory: () -> URL? = { nil }

    var current: TerminalSession? { sessions.indices.contains(selectedIndex) ? sessions[selectedIndex] : nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabBar)
        addSubview(content)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        tabBar.addAccessory(symbol: "plus", toolTip: "New Terminal (⌃⇧`)", target: self, action: #selector(newTerminalClicked))
        positionButton = tabBar.addAccessory(symbol: "rectangle.split.2x1", toolTip: "Move Terminal to Right",
                                             target: self, action: #selector(positionClicked))
        hideButton = tabBar.addAccessory(symbol: "chevron.down", toolTip: "Hide Panel (⌃`)", target: self, action: #selector(hideClicked))
        tabBar.onSelect = { [weak self] i in self?.select(i) }
        tabBar.onClose = { [weak self] i in self?.closeSession(at: i) }

        NotificationCenter.default.addObserver(self, selector: #selector(fontSizeChanged),
                                               name: Theme.fontSizeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    @objc private func newTerminalClicked() { newTerminal(in: nil) }
    @objc private func hideClicked() { onHide?() }

    @objc private func positionClicked() { onTogglePosition?() }
    var onHide: (() -> Void)?
    var onTogglePosition: (() -> Void)?
    private var positionButton: NSButton?
    private var hideButton: NSButton?

    /// Updates the panel's buttons to match where it sits.
    func setPosition(onRight: Bool) {
        let symbol = onRight ? "rectangle.split.1x2" : "rectangle.split.2x1"
        let tip = onRight ? "Move Terminal to Bottom" : "Move Terminal to Right"
        positionButton?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        positionButton?.toolTip = tip
        hideButton?.image = NSImage(systemSymbolName: onRight ? "chevron.right" : "chevron.down", accessibilityDescription: "Hide Panel")
    }

    // MARK: Sessions

    func newTerminal(in directory: URL?) {
        let options = TerminalOptions(scrollback: 5_000)
        let term = KenoTerminalView(frame: content.bounds, font: Theme.terminalFont, options: options)
        term.autoresizingMask = [.width, .height]
        term.processDelegate = self
        // Option must stay Option so non-US layouts can type @ { } [ ] | \ ~
        term.optionAsMetaKey = false
        applyColors(to: term)

        let shell = Self.loginShell()
        let shellName = (shell as NSString).lastPathComponent
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Keno"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env.removeValue(forKey: "TERM_SESSION_ID")
        let cwd = (directory ?? defaultDirectory() ?? FileManager.default.homeDirectoryForCurrentUser).path

        let session = TerminalSession(view: term, title: shellName)
        sessions.append(session)
        select(sessions.count - 1)
        // "-zsh" as argv[0] makes it a login shell, so your PATH/profile load like in Terminal.app.
        term.startProcess(executable: shell, args: [], environment: env.map { "\($0.key)=\($0.value)" },
                          execName: "-" + shellName, currentDirectory: cwd)
    }

    private static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    func select(_ index: Int) {
        guard sessions.indices.contains(index) else { return }
        current?.view.removeFromSuperview()
        selectedIndex = index
        let s = sessions[index]
        s.view.frame = content.bounds
        content.addSubview(s.view)
        window?.makeFirstResponder(s.view)
        refreshTabs()
    }

    func focus() {
        if let v = current?.view { window?.makeFirstResponder(v) }
    }

    var containsFirstResponder: Bool {
        guard let fr = window?.firstResponder as? NSView else { return false }
        return fr.isDescendant(of: self)
    }

    func closeSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        let selected = current
        let s = sessions.remove(at: index)
        s.running = false
        s.view.processDelegate = nil
        s.view.terminate()
        s.view.removeFromSuperview()
        if sessions.isEmpty {
            selectedIndex = -1
            refreshTabs()
            onEmpty?()
        } else if let selected, selected !== s, let kept = sessions.firstIndex(where: { $0 === selected }) {
            // A background tab closed: the one you're looking at stays selected and attached.
            selectedIndex = kept
            refreshTabs()
        } else {
            selectedIndex = -1
            select(min(index, sessions.count - 1))
        }
    }

    func closeCurrent() { if selectedIndex >= 0 { closeSession(at: selectedIndex) } }

    func terminateAll() {
        for s in sessions {
            s.view.processDelegate = nil
            s.view.terminate()
        }
        sessions.removeAll()
    }

    func selectNext() { if !sessions.isEmpty { select((selectedIndex + 1) % sessions.count) } }
    func selectPrevious() { if !sessions.isEmpty { select((selectedIndex - 1 + sessions.count) % sessions.count) } }

    private func refreshTabs() {
        tabBar.setTabs(sessions.map { TabBarItem(title: $0.title, toolTip: $0.title) }, selected: selectedIndex)
    }

    // MARK: Appearance

    private func applyColors(to term: LocalProcessTerminalView) {
        let appearance = effectiveAppearance
        term.nativeBackgroundColor = Theme.resolve(Theme.editorBackground, for: appearance)
        term.nativeForegroundColor = Theme.resolve(Theme.editorForeground, for: appearance)
        term.caretColor = Theme.resolve(Theme.editorForeground, for: appearance).withAlphaComponent(0.7)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        sessions.forEach { applyColors(to: $0.view) }
    }

    @objc private func fontSizeChanged() {
        sessions.forEach { $0.view.font = Theme.terminalFont }
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard let s = sessions.first(where: { $0.view === source }), !title.isEmpty else { return }
        s.title = title
        refreshTabs()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let i = self.sessions.firstIndex(where: { $0.view === source }) else { return }
            self.closeSession(at: i)
        }
    }
}

// MARK: - Dictation

extension TerminalPanel: DictationTarget {
    var dictationLabel: String { "Terminal" }
    var dictationStreamsText: Bool { false } // one paste at the end, reviewed before you press Enter
    func dictationPrompt() -> String? { Dictation.vocabularyHint }

    /// Pastes dictated text into the active terminal (bracketed paste, no Enter) and focuses it.
    func insertDictation(_ text: String, newParagraph: Bool) {
        guard let s = current else { NSSound.beep(); return }
        s.view.pasteText(text)
        focus()
    }
}
