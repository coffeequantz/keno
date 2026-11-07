import AppKit

/// Tab strip + the active document's text view.
final class EditorArea: NSView {
    private let tabBar = TabBarView()
    private let content = NSView()
    private let emptyLabel = NSTextField(labelWithString: "")

    private(set) var documents: [Document] = []
    private(set) var selectedIndex = -1
    private var untitledCounter = 0

    /// Called whenever the active document, its name or dirty state changes.
    var onChange: (() -> Void)?

    var current: Document? { documents.indices.contains(selectedIndex) ? documents[selectedIndex] : nil }

    var wordWrap: Bool = UserDefaults.standard.bool(forKey: "wordWrap") {
        didSet {
            UserDefaults.standard.set(wordWrap, forKey: "wordWrap")
            documents.forEach { $0.setWordWrap(wordWrap) }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabBar)
        addSubview(content)

        emptyLabel.stringValue = "Open a file from the explorer\n\n⌘O  Open File or Folder\n⌘N  New File\n⌃`  Toggle Terminal\n⌘B  Toggle Sidebar"
        emptyLabel.alignment = .center
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        tabBar.onSelect = { [weak self] i in self?.select(i) }
        tabBar.onClose = { [weak self] i in _ = self?.close(at: i) }

        NotificationCenter.default.addObserver(self, selector: #selector(fontSizeChanged),
                                               name: Theme.fontSizeDidChange, object: nil)
        refreshTabs()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    @objc private func fontSizeChanged() { documents.forEach { $0.applyFont() } }

    // MARK: Opening

    /// Opens `url` (or focuses it if already open). `preview` tabs get replaced by the next preview.
    @discardableResult
    func open(url: URL, preview: Bool = false) -> Document? {
        let url = url.standardizedFileURL
        if let i = documents.firstIndex(where: { $0.url?.standardizedFileURL == url }) {
            if !preview { documents[i].isPreview = false }
            select(i)
            return documents[i]
        }
        let doc: Document
        do {
            doc = try makeFileViewer(for: url).map { Document.openViewer($0, url: url) }
                ?? Document.open(url: url, wordWrap: wordWrap)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            return nil
        }
        doc.isPreview = preview
        // Replace an existing (clean) preview tab instead of piling up tabs.
        if preview, let pi = documents.firstIndex(where: { $0.isPreview && !$0.isDirty }) {
            documents[pi].contentView.removeFromSuperview()
            documents[pi] = doc
            attach(doc)
            select(pi)
        } else {
            let insertAt = selectedIndex >= 0 ? selectedIndex + 1 : documents.count
            documents.insert(doc, at: insertAt)
            attach(doc)
            select(insertAt)
        }
        return doc
    }

    func newUntitled() {
        untitledCounter += 1
        let doc = Document(url: nil, text: "", wordWrap: wordWrap)
        doc.untitledNumber = untitledCounter
        let insertAt = selectedIndex >= 0 ? selectedIndex + 1 : documents.count
        documents.insert(doc, at: insertAt)
        attach(doc)
        select(insertAt)
    }

    private func attach(_ doc: Document) {
        doc.onStateChange = { [weak self] in
            self?.refreshTabs()
            self?.onChange?()
        }
    }

    // MARK: Selection

    func select(_ index: Int) {
        guard documents.indices.contains(index) else { return }
        let previous = current
        selectedIndex = index
        let doc = documents[index]
        if previous !== doc { previous?.contentView.removeFromSuperview() }
        let view = doc.contentView
        if view.superview == nil {
            view.frame = content.bounds
            view.autoresizingMask = [.width, .height]
            content.addSubview(view)
            if !doc.isViewer { doc.setWordWrap(wordWrap) } // re-sync container width with the visible size
        }
        if !doc.isViewer { doc.didBecomeVisible() }
        emptyLabel.isHidden = true
        window?.makeFirstResponder(doc.focusView)
        refreshTabs()
        onChange?()
    }

    func selectNext() { if !documents.isEmpty { select((selectedIndex + 1) % documents.count) } }
    func selectPrevious() { if !documents.isEmpty { select((selectedIndex - 1 + documents.count) % documents.count) } }

    func focus() {
        if let doc = current { window?.makeFirstResponder(doc.focusView) }
    }

    private func refreshTabs() {
        let items = documents.map { doc -> TabBarItem in
            var title = doc.displayName
            // Disambiguate same-named files with their parent folder.
            if let url = doc.url, documents.contains(where: { $0 !== doc && $0.displayName == doc.displayName }) {
                title += " — " + url.deletingLastPathComponent().lastPathComponent
            }
            if doc.isPreview { title = "◦ " + title }
            return TabBarItem(title: title, toolTip: doc.url?.path ?? doc.displayName, isDirty: doc.isDirty)
        }
        tabBar.setTabs(items, selected: selectedIndex)
    }

    // MARK: Closing

    /// Returns false if the user cancelled.
    @discardableResult
    func close(at index: Int) -> Bool {
        guard documents.indices.contains(index) else { return true }
        let doc = documents[index]
        if doc.isDirty {
            select(index)
            switch askToSave([doc]) {
            case .save: if !save(doc) { return false }
            case .discard: break
            case .cancel: return false
            }
        }
        doc.contentView.removeFromSuperview()
        documents.remove(at: index)
        if documents.isEmpty {
            selectedIndex = -1
            emptyLabel.isHidden = false
            refreshTabs()
            onChange?()
        } else {
            // Like VS Code: focus the tab to the left of the closed one, if it was active.
            var next: Int
            if index == selectedIndex { next = max(index - 1, 0) }
            else if index < selectedIndex { next = selectedIndex - 1 }
            else { next = selectedIndex }
            selectedIndex = -1
            select(min(next, documents.count - 1))
        }
        return true
    }

    func closeCurrent() -> Bool { selectedIndex >= 0 ? close(at: selectedIndex) : true }

    /// Prompts for all dirty documents at once. Returns false if the user cancelled.
    func confirmCloseAll() -> Bool {
        let dirty = documents.filter { $0.isDirty }
        guard !dirty.isEmpty else { return true }
        switch askToSave(dirty) {
        case .save: return dirty.allSatisfy { save($0) }
        case .discard: return true
        case .cancel: return false
        }
    }

    private enum SaveChoice { case save, discard, cancel }

    private func askToSave(_ docs: [Document]) -> SaveChoice {
        let alert = NSAlert()
        if docs.count == 1 {
            alert.messageText = "Do you want to save the changes you made to “\(docs[0].displayName)”?"
        } else {
            alert.messageText = "Do you want to save the changes to \(docs.count) files?"
            alert.informativeText = docs.map(\.displayName).joined(separator: "\n")
        }
        if docs.count == 1 { alert.informativeText = "Your changes will be lost if you don’t save them." }
        alert.addButton(withTitle: docs.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        let discard = alert.addButton(withTitle: "Don’t Save")
        discard.hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    // MARK: Saving

    @discardableResult
    func save(_ doc: Document) -> Bool {
        if doc.isViewer { return true }
        guard let url = doc.url else { return saveAs(doc) }
        do {
            try doc.write(to: url)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    @discardableResult
    func saveAs(_ doc: Document) -> Bool {
        if doc.isViewer { return true }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = doc.url?.lastPathComponent ?? "Untitled.txt"
        if let dir = doc.url?.deletingLastPathComponent() ?? defaultSaveDirectory { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try doc.write(to: url)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    var defaultSaveDirectory: URL?

    func saveAll() { documents.filter { $0.isDirty }.forEach { save($0) } }

    // MARK: External changes

    func reloadChangedFiles() { documents.forEach { $0.reloadIfChangedOnDisk() } }

    /// Keeps open tabs pointing at the right file after a rename/move in the explorer.
    func itemMoved(from old: URL, to new: URL) {
        let oldPath = old.standardizedFileURL.path
        for doc in documents {
            guard let path = doc.url?.standardizedFileURL.path else { continue }
            if path == oldPath {
                doc.url = new
            } else if path.hasPrefix(oldPath + "/") {
                doc.url = URL(fileURLWithPath: new.path + path.dropFirst(oldPath.count))
            }
        }
        refreshTabs()
        onChange?()
    }
}
