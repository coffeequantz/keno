import AppKit

struct TabBarItem {
    var title: String
    var toolTip: String?
    var isDirty: Bool = false
}

/// A lightweight VS Code-style tab strip. Used by both the editor area and the terminal panel.
final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let accessoryStack = NSStackView()
    private var buttons: [TabButton] = []
    private(set) var selectedIndex: Int = -1

    static let height: CGFloat = 30

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        let flipped = FlippedClipView()
        flipped.drawsBackground = false
        scrollView.contentView = flipped
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = stack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        accessoryStack.orientation = .horizontal
        accessoryStack.spacing = 2
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accessoryStack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: accessoryStack.leadingAnchor, constant: -4),
            accessoryStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            accessoryStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(equalTo: flipped.topAnchor),
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chromeBackground.setFill()
        bounds.fill()
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    /// Adds a small icon button at the right end of the bar (e.g. "+" for new terminal).
    /// Adds an arbitrary view (e.g. a status label) to the accessory area, left of the buttons.
    func addAccessoryView(_ view: NSView) {
        accessoryStack.addArrangedSubview(view)
    }

    @discardableResult
    func addAccessory(symbol: String, toolTip: String, target: AnyObject, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        let b = NSButton(image: image ?? NSImage(), target: target, action: action)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.toolTip = toolTip
        b.contentTintColor = .secondaryLabelColor
        b.setContentHuggingPriority(.required, for: .horizontal)
        accessoryStack.addArrangedSubview(b)
        return b
    }

    func setTabs(_ items: [TabBarItem], selected: Int) {
        // Reuse existing buttons where possible to avoid churn.
        while buttons.count > items.count { buttons.removeLast().removeFromSuperview() }
        while buttons.count < items.count {
            let b = TabButton()
            b.onClick = { [weak self, weak b] in
                guard let self, let b, let i = self.buttons.firstIndex(where: { $0 === b }) else { return }
                self.onSelect?(i)
            }
            b.onClose = { [weak self, weak b] in
                guard let self, let b, let i = self.buttons.firstIndex(where: { $0 === b }) else { return }
                self.onClose?(i)
            }
            buttons.append(b)
            stack.addArrangedSubview(b)
        }
        for (i, item) in items.enumerated() {
            buttons[i].configure(item: item, selected: i == selected)
        }
        selectedIndex = selected
        if selected >= 0 && selected < buttons.count {
            let b = buttons[selected]
            DispatchQueue.main.async { b.scrollToVisible(b.bounds) }
        }
    }
}

private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

private final class TabButton: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var isSelected = false
    private var isDirty = false
    private var isHovering = false
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: TabBarView.height - 1),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(item: TabBarItem, selected: Bool) {
        label.stringValue = item.title
        toolTip = item.toolTip ?? item.title
        isSelected = selected
        isDirty = item.isDirty
        label.textColor = selected ? .labelColor : .secondaryLabelColor
        updateCloseButton()
        needsDisplay = true
    }

    private func updateCloseButton() {
        let symbol = (isDirty && !isHovering) ? "circle.fill" : "xmark"
        let config = NSImage.SymbolConfiguration(pointSize: isDirty && !isHovering ? 7 : 9, weight: .semibold)
        closeButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Close")?
            .withSymbolConfiguration(config)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.isHidden = !(isSelected || isHovering || isDirty)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true; updateCloseButton(); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovering = false; updateCloseButton(); needsDisplay = true }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() } // middle-click closes, like VS Code
    }

    @objc private func closeClicked() { onClose?() }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            Theme.editorBackground.setFill()
            bounds.fill()
            NSColor.controlAccentColor.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
        } else if isHovering {
            Theme.hoverBackground.setFill()
            bounds.fill()
        }
        Theme.separator.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    override var isFlipped: Bool { true }
}
