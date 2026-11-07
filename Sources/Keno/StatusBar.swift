import AppKit

/// Bar along the bottom of the window. Left: cursor position, word count (click to cycle
/// words / characters / reading time), language. Right: dictation (mic, timer, level, target).
final class StatusBar: NSView {
    static let height: CGFloat = 24

    /// The document whose stats are shown (the editor's active tab).
    var document: () -> Document? = { nil }
    /// Start/stop dictation (routed through the window controller, which picks the target).
    var onDictate: (() -> Void)?

    // Left
    private let positionLabel = StatusBar.label()
    private let countButton = NSButton(title: "", target: nil, action: nil)
    private let languageLabel = StatusBar.label()
    // Right
    private let dot = NSView()
    private let voiceLabel = StatusBar.label()
    private let meter = LevelMeterView()
    private let spinner = NSProgressIndicator()
    private let progress = NSProgressIndicator()
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    private let micButton = NSButton(title: "", target: nil, action: nil)

    private var countTimer: Timer?
    private var docCount = TextStats.Count()
    private weak var countedDoc: Document?
    private var animationTimer: Timer?
    private var tick = 0

    private enum CountMode: Int { case words, characters, readingTime }
    private var countMode: CountMode {
        get { CountMode(rawValue: UserDefaults.standard.integer(forKey: "statusCountMode")) ?? .words }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "statusCountMode") }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        countButton.isBordered = false
        countButton.font = Self.font
        countButton.contentTintColor = .secondaryLabelColor
        countButton.target = self
        countButton.action = #selector(cycleCountMode)
        countButton.refusesFirstResponder = true

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 3.5
        // AppKit's middle truncation kicks in even when this text fits; we shorten long names ourselves instead.
        voiceLabel.lineBreakMode = .byClipping
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small

        for b in [cancelButton, micButton] {
            b.isBordered = false
            b.font = Self.font
            b.imagePosition = .imageLeading
            b.target = self
            b.refusesFirstResponder = true // clicking must not move focus away from where text goes
        }
        cancelButton.image = Self.symbol("xmark.circle.fill", color: .tertiaryLabelColor)
        cancelButton.imagePosition = .imageOnly
        cancelButton.action = #selector(cancelClicked)
        cancelButton.toolTip = "Discard this dictation"
        micButton.action = #selector(micClicked)

        let left = NSStackView(views: [positionLabel, countButton, languageLabel])
        left.spacing = 16
        let right = NSStackView(views: [dot, voiceLabel, meter, spinner, progress, cancelButton, micButton])
        right.spacing = 8
        right.setCustomSpacing(5, after: dot)
        right.setCustomSpacing(12, after: cancelButton)
        for s in [left, right] {
            s.orientation = .horizontal
            s.alignment = .centerY
            s.translatesAutoresizingMaskIntoConstraints = false
            addSubview(s)
        }
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [dot, meter, progress] { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 16),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            meter.widthAnchor.constraint(equalToConstant: 60),
            meter.heightAnchor.constraint(equalToConstant: 12),
            progress.widthAnchor.constraint(equalToConstant: 100),
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(updateDictation), name: Dictation.didChange, object: nil)
        nc.addObserver(self, selector: #selector(selectionChanged(_:)), name: Document.selectionDidChange, object: nil)
        nc.addObserver(self, selector: #selector(textChanged(_:)), name: Document.textDidChange, object: nil)
        updateDictation()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        countTimer?.invalidate()
        animationTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chromeBackground.setFill()
        dirtyRect.intersection(bounds).fill()
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override var isFlipped: Bool { false }

    // MARK: Document stats

    /// Call when the active tab changes.
    func documentChanged() {
        countTimer?.invalidate()
        recountDocument()
    }

    @objc private func selectionChanged(_ n: Notification) {
        guard let doc = n.object as? Document, doc === document() else { return }
        updateStats()
    }

    @objc private func textChanged(_ n: Notification) {
        guard let doc = n.object as? Document, doc === document() else { return }
        // Recount once typing pauses; big files would otherwise cost a scan per keystroke.
        countTimer?.invalidate()
        countTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in self?.recountDocument() }
        updatePosition()
    }

    private func recountDocument() {
        countedDoc = document()
        if let doc = countedDoc, !doc.isViewer {
            let ns = doc.textView.string as NSString
            docCount = TextStats.count(ns, in: NSRange(location: 0, length: ns.length))
        } else {
            docCount = TextStats.Count()
        }
        updateStats()
    }

    private func updateStats() {
        guard let doc = document() else {
            positionLabel.stringValue = ""
            countButton.isHidden = true
            languageLabel.stringValue = ""
            return
        }
        if doc !== countedDoc { recountDocument(); return }
        if let viewer = doc.viewer {
            positionLabel.stringValue = viewer.infoText
            countButton.isHidden = true
            languageLabel.stringValue = ""
            return
        }
        updatePosition()
        countButton.isHidden = false
        languageLabel.stringValue = doc.languageName

        let ns = doc.textView.string as NSString
        let sel = doc.textView.selectedRange()
        let selCount = sel.length > 0 ? TextStats.count(ns, in: sel) : nil
        countButton.attributedTitle = NSAttributedString(string: countText(selCount), attributes: [
            .font: Self.font, .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let total = docCount
        countButton.toolTip = "\(Self.number(total.words)) words · \(Self.number(total.characters)) characters · "
            + "\(Self.readingTime(total.words)) read\nClick to switch between words, characters and reading time"
    }

    private func updatePosition() {
        guard let doc = document(), !doc.isViewer else { return }
        let sel = doc.textView.selectedRange()
        let line = doc.lines.line(of: sel.location)
        let col = sel.location - doc.lines.starts[min(line, doc.lines.starts.count - 1)] + 1
        positionLabel.stringValue = "Ln \(line + 1), Col \(col)"
    }

    private func countText(_ sel: TextStats.Count?) -> String {
        let total = docCount
        switch countMode {
        case .words:
            let unit = total.words == 1 ? "word" : "words"
            return sel.map { "\(Self.number($0.words)) of \(Self.number(total.words)) \(unit)" }
                ?? "\(Self.number(total.words)) \(unit)"
        case .characters:
            let unit = total.characters == 1 ? "character" : "characters"
            return sel.map { "\(Self.number($0.characters)) of \(Self.number(total.characters)) \(unit)" }
                ?? "\(Self.number(total.characters)) \(unit)"
        case .readingTime:
            return sel.map { "\(Self.readingTime($0.words)) of \(Self.readingTime(total.words)) read" }
                ?? "\(Self.readingTime(total.words)) read"
        }
    }

    @objc private func cycleCountMode() {
        countMode = CountMode(rawValue: (countMode.rawValue + 1) % 3) ?? .words
        updateStats()
    }

    private static func readingTime(_ words: Int) -> String {
        words == 0 ? "0 min" : words < 115 ? "<1 min" : "\(Int((Double(words) / 230).rounded())) min" // ~230 wpm
    }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static func number(_ n: Int) -> String { formatter.string(from: NSNumber(value: n)) ?? "\(n)" }

    // MARK: Dictation

    @objc private func micClicked() { onDictate?() }
    @objc private func cancelClicked() { Dictation.shared.cancel() }

    /// Whether this window's bar shows the current dictation (another window may own it).
    private var ownsDictation: Bool {
        let w = Dictation.shared.window
        return w == nil || w === window
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDictation()
    }

    @objc func updateDictation() {
        let d = Dictation.shared
        let state = ownsDictation ? d.state : .idle
        var recording = false
        switch state {
        case .idle:
            let msg = ownsDictation ? d.message : nil
            voiceLabel.stringValue = msg ?? ""
            voiceLabel.textColor = .labelColor
            setMic(title: "Dictate", symbol: "mic", color: .secondaryLabelColor, enabled: !d.isBusy || !ownsDictation,
                   tip: "Dictate into the editor or terminal, wherever your cursor is (⌥⌘R)")
            show(spinner: false, meter: false, progress: false, cancel: false, dot: false)
        case .recording:
            recording = true
            voiceLabel.stringValue = "\(d.statusText ?? "")  →  \(Self.short(d.targetLabel))"
            voiceLabel.textColor = .labelColor
            setMic(title: "Stop", symbol: "stop.circle.fill", color: .systemRed, enabled: true,
                   tip: "Stop and transcribe (⌥⌘R)")
            show(spinner: false, meter: true, progress: false, cancel: true, dot: true)
        case .finishing:
            voiceLabel.stringValue = "Transcribing…  →  \(Self.short(d.targetLabel))"
            voiceLabel.textColor = .labelColor
            setMic(title: "Dictate", symbol: "mic", color: .tertiaryLabelColor, enabled: false, tip: nil)
            show(spinner: true, meter: false, progress: false, cancel: true, dot: false)
        case .downloading(let p):
            voiceLabel.stringValue = d.statusText ?? ""
            voiceLabel.textColor = .labelColor
            progress.doubleValue = p
            setMic(title: "Dictate", symbol: "mic", color: .tertiaryLabelColor, enabled: false, tip: nil)
            show(spinner: false, meter: false, progress: true, cancel: true, dot: false)
        }
        recording ? startAnimating() : stopAnimating()
    }

    private func setMic(title: String, symbol: String, color: NSColor, enabled: Bool, tip: String?) {
        micButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Self.font, .foregroundColor: enabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
        ])
        micButton.image = Self.symbol(symbol, color: color)
        micButton.isEnabled = enabled
        micButton.toolTip = tip
    }

    private func show(spinner s: Bool, meter m: Bool, progress p: Bool, cancel c: Bool, dot d: Bool) {
        spinner.isHidden = !s
        s ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        meter.isHidden = !m
        progress.isHidden = !p
        cancelButton.isHidden = !c
        dot.isHidden = !d
        voiceLabel.isHidden = voiceLabel.stringValue.isEmpty
        if !m { meter.reset() }
    }

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
        let d = Dictation.shared
        meter.push(d.inputLevel)
        dot.alphaValue = 0.35 + 0.65 * CGFloat((sin(Double(tick) / 20 * 2 * .pi / 1.2) + 1) / 2) // 1.2 s pulse
        if tick % 5 == 0, case .recording = d.state {
            voiceLabel.stringValue = "\(d.statusText ?? "")  →  \(Self.short(d.targetLabel))"
        }
    }

    // MARK: Helpers

    private static let font = NSFont.systemFont(ofSize: 11)

    /// "a-very-long-file-name.md" → "a-very-lo…name.md", so the bar never overflows.
    private static func short(_ name: String, max: Int = 32) -> String {
        guard name.count > max else { return name }
        return String(name.prefix(max / 2 - 1)) + "…" + String(name.suffix(max / 2))
    }

    private static func label() -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        l.textColor = .secondaryLabelColor
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    private static func symbol(_ name: String, color: NSColor) -> NSImage? {
        // Borderless buttons ignore contentTintColor for some symbols, so bake the color in.
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: name.hasSuffix(".fill") ? [.white, color] : [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}

/// Fast word and character counts over an NSString range (one pass, no allocations per word).
enum TextStats {
    struct Count { var words = 0; var characters = 0 }

    static func count(_ ns: NSString, in range: NSRange) -> Count {
        var c = Count()
        var inWord = false
        var buffer = [unichar](repeating: 0, count: 16_384)
        var loc = range.location
        let end = NSMaxRange(range)
        while loc < end {
            let n = min(buffer.count, end - loc)
            ns.getCharacters(&buffer, range: NSRange(location: loc, length: n))
            for i in 0..<n {
                let ch = buffer[i]
                let space = ch <= 0x20 || ch == 0xA0 || ch == 0x3000 || ch == 0x2028 || ch == 0x2029
                if !space, !inWord { c.words += 1 }
                inWord = !space
                // Characters as people count them: no line breaks, emoji/surrogate pairs count once.
                if ch != 0x0A, ch != 0x0D, !(0xDC00...0xDFFF).contains(ch) { c.characters += 1 }
            }
            loc += n
        }
        return c
    }
}

/// Scrolling bar meter of recent microphone levels.
final class LevelMeterView: NSView {
    private var levels = [CGFloat](repeating: 0, count: 20)

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
