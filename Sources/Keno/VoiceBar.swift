import AppKit

/// Slim bar under the terminal: a Record/Stop button plus live feedback
/// (pulsing dot, timer, input level meter, spinner while transcribing).
final class VoiceBar: NSView {
    /// Start/stop (routed through the window controller so the terminal opens if needed).
    var onToggle: (() -> Void)?
    /// Whether this bar belongs to the panel that owns the current recording.
    var ownsVoice: () -> Bool = { true }

    static let height: CGFloat = 32

    private let recordButton = NSButton(title: "Record", target: nil, action: nil)
    private let dot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let meter = LevelMeterView()
    private let spinner = NSProgressIndicator()
    private let progress = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var animationTimer: Timer?
    private var tick = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        recordButton.bezelStyle = .rounded
        recordButton.controlSize = .small
        recordButton.font = .systemFont(ofSize: 11, weight: .medium)
        recordButton.imagePosition = .imageLeading
        recordButton.target = self
        recordButton.action = #selector(toggleClicked)
        recordButton.toolTip = "Dictate a prompt into the terminal (⌥⌘R)"

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small

        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.font = .systemFont(ofSize: 11)
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.toolTip = "Discard this recording"

        let stack = NSStackView(views: [recordButton, dot, spinner, statusLabel, meter, progress, cancelButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.setCustomSpacing(6, after: dot)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for v in [dot, meter, progress] { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            meter.widthAnchor.constraint(equalToConstant: 120),
            meter.heightAnchor.constraint(equalToConstant: 16),
            progress.widthAnchor.constraint(equalToConstant: 140),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(update),
                                               name: VoicePrompt.didChange, object: nil)
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        animationTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chromeBackground.setFill()
        dirtyRect.intersection(bounds).fill()
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func cancelClicked() { VoicePrompt.shared.cancel() }

    // MARK: State → UI

    @objc func update() {
        let voice = VoicePrompt.shared
        let state = ownsVoice() ? voice.state : .idle

        var recording = false
        switch state {
        case .idle:
            setButton(title: "Record", symbol: "record.circle", tint: .systemRed, enabled: true)
            let msg = ownsVoice() ? voice.message : nil
            statusLabel.stringValue = msg ?? "⌥⌘R · speak a prompt, it’s pasted into the terminal for you to review"
            statusLabel.textColor = msg != nil ? .labelColor : .tertiaryLabelColor
            show(spinner: false, meter: false, progress: false, cancel: false, dot: false)
        case .recording:
            recording = true
            setButton(title: "Stop", symbol: "stop.circle.fill", tint: .systemRed, enabled: true)
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = voice.statusText ?? ""
            show(spinner: false, meter: true, progress: false, cancel: true, dot: true)
        case .transcribing:
            setButton(title: "Record", symbol: "record.circle", tint: .tertiaryLabelColor, enabled: false)
            statusLabel.stringValue = "Transcribing…"
            statusLabel.textColor = .labelColor
            show(spinner: true, meter: false, progress: false, cancel: true, dot: false)
        case .downloading(let p):
            setButton(title: "Record", symbol: "record.circle", tint: .tertiaryLabelColor, enabled: false)
            statusLabel.stringValue = "Downloading speech model \(Int(p * 100))%"
            statusLabel.textColor = .labelColor
            progress.doubleValue = p
            show(spinner: false, meter: false, progress: true, cancel: true, dot: false)
        }
        recording ? startAnimating() : stopAnimating()
    }

    private func setButton(title: String, symbol: String, tint: NSColor, enabled: Bool) {
        recordButton.title = title
        // Push buttons ignore contentTintColor, so bake the color into the symbol.
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: symbol.hasSuffix(".fill") ? [.white, tint] : [tint]))
        recordButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(config)
        recordButton.isEnabled = enabled
    }

    private func show(spinner s: Bool, meter m: Bool, progress p: Bool, cancel c: Bool, dot d: Bool) {
        spinner.isHidden = !s
        s ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        meter.isHidden = !m
        progress.isHidden = !p
        cancelButton.isHidden = !c
        dot.isHidden = !d
        if !m { meter.reset() }
    }

    // MARK: Live animation (only while recording)

    private func startAnimating() {
        guard animationTimer == nil else { return }
        tick = 0
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.animate() }
        RunLoop.main.add(t, forMode: .common)
        animationTimer = t
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        dot.alphaValue = 1
    }

    private func animate() {
        tick += 1
        let voice = VoicePrompt.shared
        meter.push(voice.inputLevel)
        // Gentle pulse: 1.2 s cycle.
        dot.alphaValue = 0.35 + 0.65 * CGFloat((sin(Double(tick) / 20 * 2 * .pi / 1.2) + 1) / 2)
        if tick % 5 == 0 { statusLabel.stringValue = voice.statusText ?? "" }
    }
}

/// Scrolling bar meter of recent microphone levels.
final class LevelMeterView: NSView {
    private var levels = [CGFloat](repeating: 0, count: 30)

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(CGFloat(max(0, min(1, level))))
        needsDisplay = true
    }

    func reset() {
        levels = [CGFloat](repeating: 0, count: levels.count)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let barWidth = bounds.width / CGFloat(levels.count)
        NSColor.systemRed.withAlphaComponent(0.85).setFill()
        for (i, level) in levels.enumerated() {
            let h = max(2, level * bounds.height)
            let rect = NSRect(x: CGFloat(i) * barWidth + 1, y: (bounds.height - h) / 2,
                              width: max(1, barWidth - 2), height: h)
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
    }
}
