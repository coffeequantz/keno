import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controllers: [MainWindowController] = []
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(recentDelegate: self)
        installKeyMonitor()

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controllers.forEach { $0.editor.reloadChangedFiles() } }
        }

        // Files/folders passed by Finder or `open -a` arrive via application(_:open:) before this.
        if controllers.isEmpty {
            let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
            let cwd = FileManager.default.currentDirectoryPath
            let urls = args.map { URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if !urls.isEmpty {
                open(urls: urls, preferring: nil)
            } else {
                let c = makeWindow()
                if let last = UserDefaults.standard.string(forKey: "lastFolder"),
                   FileManager.default.fileExists(atPath: last) {
                    c.setFolder(URL(fileURLWithPath: last))
                    c.restoreSession()
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        open(urls: urls, preferring: nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for c in controllers where !c.editor.confirmCloseAll() { return .terminateCancel }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Save the key window last so it becomes "lastFolder".
        let key = controllers.first { $0.window?.isKeyWindow == true }
        controllers.filter { $0 !== key }.forEach { $0.saveSession() }
        key?.saveSession()
        controllers.forEach { $0.terminal.terminateAll() }
        VoicePrompt.shared.cancel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Windows

    @discardableResult
    func makeWindow() -> MainWindowController {
        let c = MainWindowController()
        c.onClose = { [weak self] closed in self?.controllers.removeAll { $0 === closed } }
        if let last = controllers.last?.window {
            c.window?.setFrameTopLeftPoint(last.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        }
        controllers.append(c)
        c.showWindow(nil)
        return c
    }

    private var frontController: MainWindowController? {
        controllers.first { $0.window?.isKeyWindow == true } ?? controllers.first { $0.window?.isMainWindow == true } ?? controllers.last
    }

    /// Folders open in a window (reusing an empty one); files open as tabs in the front window.
    func open(urls: [URL], preferring preferred: MainWindowController?) {
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let target = url.resolvingSymlinksInPath().standardizedFileURL
                if let existing = controllers.first(where: { $0.folderURL == target }) {
                    existing.window?.makeKeyAndOrderFront(nil)
                    continue
                }
                let candidate = preferred ?? frontController
                let c: MainWindowController
                if let candidate, candidate.folderURL == nil, candidate.editor.documents.isEmpty {
                    c = candidate
                } else {
                    c = makeWindow()
                }
                c.setFolder(target)
                c.restoreSession()
                c.window?.makeKeyAndOrderFront(nil)
            } else {
                let c = preferred ?? frontController ?? makeWindow()
                c.editor.open(url: url)
                c.window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    @objc func newWindow(_ sender: Any?) { makeWindow() }

    @objc func openRecentFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        open(urls: [url], preferring: nil)
    }

    @objc func clearRecentFolders(_ sender: Any?) { RecentFolders.clear() }

    /// Populates File ▸ Open Recent each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for url in RecentFolders.all {
            let title = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
            let item = menu.addItem(withTitle: title, action: #selector(openRecentFolder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: "No Recent Folders", action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Recent", action: #selector(clearRecentFolders(_:)), keyEquivalent: "").target = self
    }

    // MARK: Keyboard shortcuts that menus can't express reliably on every keyboard layout

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.control), !flags.contains(.command), !flags.contains(.option),
                  let c = self?.frontController else { return event }
            switch event.keyCode {
            case 50, 10: // the ` key (ANSI) / key left of 1 (ISO, e.g. German ^)
                if flags.contains(.shift) { c.newTerminal(nil) } else { c.toggleTerminal(nil) }
                return nil
            case 48: // Tab
                if flags.contains(.shift) { c.previousTab(nil) } else { c.nextTab(nil) }
                return nil
            default:
                return event
            }
        }
    }
}
