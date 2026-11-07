import AppKit
import CoreServices

final class FileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    weak var parent: FileNode?
    /// nil = not loaded yet (directories are listed lazily on first expand).
    var children: [FileNode]?

    static let excluded: Set<String> = [".git", ".DS_Store", ".svn", ".hg", "CVS", "Thumbs.db"]

    init(url: URL, isDirectory: Bool, parent: FileNode?) {
        self.url = url
        self.isDirectory = isDirectory
        self.parent = parent
    }

    var name: String { url.lastPathComponent }

    func loadedChildren() -> [FileNode] {
        if children == nil { children = list() }
        return children ?? []
    }

    private func list() -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: []) else { return [] }
        var nodes: [FileNode] = []
        nodes.reserveCapacity(urls.count)
        for u in urls where !Self.excluded.contains(u.lastPathComponent) {
            let values = try? u.resourceValues(forKeys: Set(keys))
            var isDir = values?.isDirectory ?? false
            if values?.isSymbolicLink == true {
                var d: ObjCBool = false
                if FileManager.default.fileExists(atPath: u.path, isDirectory: &d) { isDir = d.boolValue }
            }
            nodes.append(FileNode(url: u, isDirectory: isDir, parent: self))
        }
        nodes.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return nodes
    }

    /// Re-lists a loaded directory, keeping existing node objects (and thus their expansion state).
    func refresh() {
        guard isDirectory, let old = children else { return }
        var byPath: [String: FileNode] = [:]
        for n in old { byPath[n.url.path] = n }
        children = list().map { n in
            if let o = byPath[n.url.path], o.isDirectory == n.isDirectory { return o }
            return n
        }
    }

    func refreshRecursively() {
        refresh()
        children?.forEach { $0.refreshRecursively() }
    }
}

/// The left sidebar: a VS Code-style folder tree.
final class FileExplorer: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onOpenFile: ((URL, _ preview: Bool) -> Void)?
    var onItemMoved: ((URL, URL) -> Void)?
    var onOpenTerminal: ((URL) -> Void)?

    private(set) var rootURL: URL?
    private var root: FileNode?

    private let header = NSTextField(labelWithString: "NO FOLDER OPENED")
    private let outline = ExplorerOutlineView()
    private let scroll = NSScrollView()
    private let openFolderButton = NSButton(title: "Open Folder", target: nil, action: #selector(MainWindowController.openFolder(_:)))
    private var stream: FSEventStreamRef?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingTail
        header.translatesAutoresizingMaskIntoConstraints = false
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 4
        buttons.translatesAutoresizingMaskIntoConstraints = false
        for (symbol, tip, action) in [
            ("doc.badge.plus", "New File", #selector(newFileAtRoot)),
            ("folder.badge.plus", "New Folder", #selector(newFolderAtRoot)),
            ("arrow.clockwise", "Refresh", #selector(refreshAll)),
            ("rectangle.compress.vertical", "Collapse All", #selector(collapseAll)),
        ] {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.isBordered = false
            b.toolTip = tip
            b.contentTintColor = .secondaryLabelColor
            b.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            buttons.addArrangedSubview(b)
        }

        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.rowHeight = 22
        outline.indentationPerLevel = 12
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .regular
        outline.focusRingType = .none
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.doubleAction = #selector(rowDoubleClicked)
        outline.explorer = self
        // Drag files out to other apps: a browser in the Dock, Finder, Mail, a chat window…
        // Copy only, so a drop on Finder never moves the file out of the project.
        outline.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        openFolderButton.bezelStyle = .rounded
        openFolderButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(buttons)
        addSubview(scroll)
        addSubview(openFolderButton)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.centerYAnchor.constraint(equalTo: topAnchor, constant: TabBarView.height / 2),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: header.trailingAnchor, constant: 6),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            buttons.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: TabBarView.height),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            openFolderButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            openFolderButton.topAnchor.constraint(equalTo: topAnchor, constant: 60),
        ])
        buttons.isHidden = true
        self.buttonsView = buttons
    }

    private var buttonsView: NSView?

    required init?(coder: NSCoder) { fatalError() }

    deinit { stopWatching() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.sidebarBackground.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    // MARK: Root

    func setRoot(_ url: URL?) {
        stopWatching()
        rootURL = url?.resolvingSymlinksInPath().standardizedFileURL
        if let rootURL {
            root = FileNode(url: rootURL, isDirectory: true, parent: nil)
            header.stringValue = rootURL.lastPathComponent.uppercased()
            header.toolTip = rootURL.path
            startWatching(rootURL)
        } else {
            root = nil
            header.stringValue = "NO FOLDER OPENED"
        }
        openFolderButton.isHidden = url != nil
        buttonsView?.isHidden = url == nil
        outline.reloadData()
    }

    // MARK: Reveal

    /// Expands the tree to `url` and selects it (used when switching editor tabs).
    func reveal(_ url: URL?) {
        guard let url = url?.standardizedFileURL, let root, url.path.hasPrefix(root.url.path + "/") else {
            outline.deselectAll(nil)
            return
        }
        let rel = url.path.dropFirst(root.url.path.count + 1).split(separator: "/")
        var node = root
        for (i, comp) in rel.enumerated() {
            guard let next = node.loadedChildren().first(where: { $0.name == comp }) else { return }
            if i < rel.count - 1 { outline.expandItem(next) }
            node = next
        }
        let row = outline.row(forItem: node)
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = (item as? FileNode) ?? root else { return 0 }
        return node.loadedChildren().count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = (item as? FileNode) ?? root!
        return node.loadedChildren()[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeCell(id)
        cell.textField?.stringValue = node.name
        cell.imageView?.image = node.isDirectory ? Self.folderIcon
            : ImagePreviewView.canOpen(node.url) ? Self.imageIcon
            : PDFPreviewView.canOpen(node.url) ? Self.pdfIcon : Self.fileIcon
        cell.imageView?.contentTintColor = node.isDirectory ? .controlAccentColor : .secondaryLabelColor
        return cell
    }

    private static let folderIcon = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")!
        .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
    private static let imageIcon = NSImage(systemSymbolName: "photo", accessibilityDescription: "Image")!
        .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
    private static let pdfIcon = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: "PDF")!
        .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
    private static let fileIcon = NSImage(systemSymbolName: "doc", accessibilityDescription: "File")!
        .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 12.5)
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Dragging out

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FileNode)?.url as NSURL?
    }

    // MARK: Clicks

    private var clickedNode: FileNode? { outline.item(atRow: outline.clickedRow) as? FileNode }
    private var selectedNode: FileNode? { outline.item(atRow: outline.selectedRow) as? FileNode }

    @objc private func rowClicked() {
        guard let node = clickedNode else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            onOpenFile?(node.url, true)
        }
    }

    @objc private func rowDoubleClicked() {
        guard let node = clickedNode, !node.isDirectory else { return }
        onOpenFile?(node.url, false)
    }

    fileprivate func openSelected(preview: Bool) {
        guard let node = selectedNode else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            onOpenFile?(node.url, preview)
        }
    }

    fileprivate func trashSelected() {
        if let node = selectedNode { trash(node) }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard rootURL != nil else { return }
        let node = clickedNode
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node
        }
        add("New File…", #selector(menuNewFile(_:)))
        add("New Folder…", #selector(menuNewFolder(_:)))
        menu.addItem(.separator())
        add("Open in Integrated Terminal", #selector(menuOpenTerminal(_:)))
        add("Reveal in Finder", #selector(menuReveal(_:)))
        if node != nil {
            menu.addItem(.separator())
            add("Copy Path", #selector(menuCopyPath(_:)))
            add("Copy Relative Path", #selector(menuCopyRelativePath(_:)))
            menu.addItem(.separator())
            add("Rename…", #selector(menuRename(_:)))
            add("Move to Trash", #selector(menuTrash(_:)))
        }
    }

    /// The directory a "new" action should target for a given clicked node.
    private func targetDirectory(for node: FileNode?) -> FileNode? {
        guard let node else { return root }
        return node.isDirectory ? node : (node.parent ?? root)
    }

    @objc private func newFileAtRoot() { createItem(in: root, directory: false) }
    @objc private func newFolderAtRoot() { createItem(in: root, directory: true) }
    @objc private func menuNewFile(_ sender: NSMenuItem) { createItem(in: targetDirectory(for: sender.representedObject as? FileNode), directory: false) }
    @objc private func menuNewFolder(_ sender: NSMenuItem) { createItem(in: targetDirectory(for: sender.representedObject as? FileNode), directory: true) }

    @objc private func menuOpenTerminal(_ sender: NSMenuItem) {
        if let dir = targetDirectory(for: sender.representedObject as? FileNode) { onOpenTerminal?(dir.url) }
    }

    @objc private func menuReveal(_ sender: NSMenuItem) {
        let url = (sender.representedObject as? FileNode)?.url ?? rootURL
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func menuCopyPath(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        copyToPasteboard(node.url.path)
    }

    @objc private func menuCopyRelativePath(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode, let rootURL else { return }
        copyToPasteboard(String(node.url.path.dropFirst(rootURL.path.count + 1)))
    }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc private func menuRename(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        guard let name = prompt(title: "Rename", message: "New name for “\(node.name)”:", initial: node.name),
              !name.isEmpty, name != node.name else { return }
        let dest = node.url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: node.url, to: dest)
            onItemMoved?(node.url, dest)
            node.parent?.refresh()
            reloadPreservingState()
            reveal(dest)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func menuTrash(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? FileNode { trash(node) }
    }

    private func trash(_ node: FileNode) {
        let alert = NSAlert()
        alert.messageText = "Move “\(node.name)” to the Trash?"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            node.parent?.refresh()
            reloadPreservingState()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func createItem(in dir: FileNode?, directory: Bool) {
        guard let dir else { return }
        guard let name = prompt(title: directory ? "New Folder" : "New File",
                                message: "Name (in \(dir.name)):", initial: ""), !name.isEmpty else { return }
        let url = dir.url.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError,
                              userInfo: [NSLocalizedDescriptionKey: "“\(name)” already exists."])
            }
            if directory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: url)
            }
            dir.refresh()
            reloadPreservingState()
            reveal(url)
            if !directory { onOpenFile?(url, false) }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func prompt(title: String, message: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        // Pre-select the name without its extension, like Finder.
        DispatchQueue.main.async {
            if let editor = field.currentEditor() {
                let base = (initial as NSString).deletingPathExtension
                editor.selectedRange = NSRange(location: 0, length: (base as NSString).length)
            }
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Refresh

    @objc func refreshAll() {
        root?.refreshRecursively()
        reloadPreservingState()
    }

    @objc private func collapseAll() {
        outline.collapseItem(nil, collapseChildren: true)
    }

    private func reloadPreservingState() {
        var expanded = Set<String>()
        for row in 0..<outline.numberOfRows {
            if let n = outline.item(atRow: row) as? FileNode, outline.isItemExpanded(n) { expanded.insert(n.url.path) }
        }
        let selected = selectedNode?.url.path
        outline.reloadData()
        func restore(_ nodes: [FileNode]) {
            for n in nodes where n.isDirectory && expanded.contains(n.url.path) {
                outline.expandItem(n)
                restore(n.children ?? [])
            }
        }
        restore(root?.children ?? [])
        if let selected, let n = findNode(path: selected) {
            let row = outline.row(forItem: n)
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        }
    }

    /// Finds an already-loaded node by path (never triggers disk IO).
    private func findNode(path: String) -> FileNode? {
        guard let root else { return nil }
        if path == root.url.path { return root }
        guard path.hasPrefix(root.url.path + "/") else { return nil }
        var node = root
        for comp in path.dropFirst(root.url.path.count + 1).split(separator: "/") {
            guard let next = node.children?.first(where: { $0.name == comp }) else { return nil }
            node = next
        }
        return node
    }

    // MARK: FSEvents

    private func startWatching(_ url: URL) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let explorer = Unmanaged<FileExplorer>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { explorer.filesChanged(list) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    private func stopWatching() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    private func filesChanged(_ paths: [String]) {
        var changed = false
        for p in paths {
            if p.contains("/.git/") || p.hasSuffix("/.git") { continue }
            let path = URL(fileURLWithPath: p).standardizedFileURL.path
            if let node = findNode(path: path), node.children != nil {
                node.refresh()
                changed = true
            }
        }
        if changed { reloadPreservingState() }
    }
}

private final class ExplorerOutlineView: NSOutlineView {
    weak var explorer: FileExplorer?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: explorer?.openSelected(preview: false) // Return / Enter
        case 49: explorer?.openSelected(preview: true)      // Space
        case 51 where event.modifierFlags.contains(.command): explorer?.trashSelected() // ⌘⌫
        default: super.keyDown(with: event)
        }
    }
}
