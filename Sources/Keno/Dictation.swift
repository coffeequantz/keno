import AppKit
import AVFoundation

/// Something dictated text can go into: an editor document or the terminal.
protocol DictationTarget: AnyObject {
    /// Shown in the status bar while recording ("notes.md", "Terminal").
    var dictationLabel: String { get }
    /// Editor documents get text live, piece by piece; the terminal gets one paste at the end,
    /// so you can review the whole prompt before pressing Enter.
    var dictationStreamsText: Bool { get }
    /// Context that steers Whisper's spelling and style: the text before the cursor, or a vocabulary hint.
    func dictationPrompt() -> String?
    /// Inserts transcribed text. `newParagraph` follows a long pause after a finished sentence.
    func insertDictation(_ text: String, newParagraph: Bool)
}

/// Local dictation with whisper.cpp: records the mic in memory, cuts it at natural pauses and
/// transcribes each piece while you keep talking, so long dictations finish moments after you stop.
/// Nothing is loaded until you start; audio never touches the disk.
final class Dictation: NSObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case idle
        case recording(since: Date)
        case finishing
        case downloading(progress: Double)
    }

    /// A downloadable Whisper model. All of them are multilingual.
    struct Model {
        let file: String
        let name: String
        let size: String
        let note: String
    }

    /// Fastest first. Large v3 Turbo is the most accurate but only fast with a GPU (Apple Silicon).
    static let catalog = [
        Model(file: "ggml-base.bin", name: "Base", size: "148 MB", note: "fastest"),
        Model(file: "ggml-small.bin", name: "Small", size: "488 MB", note: "balanced"),
        Model(file: "ggml-large-v3-turbo-q5_0.bin", name: "Large v3 Turbo", size: "574 MB", note: "most accurate"),
    ]

    /// What we suggest on first use: the best model that still feels instant on this Mac.
    static var recommendedModel: Model {
        #if arch(arm64)
        catalog[2]
        #else
        catalog[1]
        #endif
    }

    /// Biases Whisper toward spelling code terms correctly (used for terminal prompts).
    static let vocabularyHint =
        "A prompt for an AI coding assistant about software development: functions, variables, API, JSON, Git, "
        + "commit, refactor, TypeScript, Swift, Python, SQL, README, terminal."

    static let maxDuration: TimeInterval = 60 * 60

    static let shared = Dictation()
    static let didChange = Notification.Name("KenoDictationDidChange")

    private(set) var state: State = .idle { didSet { notify() } }
    /// A short message shown in the status bar for a few seconds ("No speech detected", …).
    private(set) var message: String? { didSet { notify() } }
    /// The window whose status bar shows progress.
    private(set) weak var window: NSWindow?
    /// Where the text goes.
    private(set) weak var target: DictationTarget?
    private(set) var targetLabel = ""

    private var session: Session?
    private var stopTimer: Timer?
    private var ticker: Timer?
    private var cancelled = false

    override init() {
        super.init()
        Transcriber.silenceLogs()
    }

    /// "auto" (detect), or a language code such as "en" or "de".
    var language: String {
        get { UserDefaults.standard.string(forKey: "voiceLanguage") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceLanguage") }
    }

    /// File name of the chosen model; nil until the user picks or downloads one.
    private var chosenModel: String? {
        get { UserDefaults.standard.string(forKey: "voiceModel") }
        set { UserDefaults.standard.set(newValue, forKey: "voiceModel") }
    }

    var isBusy: Bool { state != .idle }
    var isRecording: Bool { if case .recording = state { return true } else { return false } }

    #if DEBUG
    /// Test hook for rendering the status bar in each state.
    func debugSet(state: State, target: String = "", message: String? = nil) {
        targetLabel = target
        self.message = message
        self.state = state
    }
    #endif

    /// Current microphone level, 0…1 (for the level meter while recording).
    var inputLevel: Float { session?.mic.level ?? 0 }

    // MARK: Start / stop

    /// Starts dictating into `target`, or stops (and finishes) a running dictation.
    func toggle(target: DictationTarget, window: NSWindow?) {
        switch state {
        case .idle: start(target: target, window: window)
        case .recording: stop()
        case .finishing, .downloading: NSSound.beep()
        }
    }

    /// If no model is installed yet, offers the download (progress shows in `window`) and returns true.
    func offerModelIfMissing(window: NSWindow?) -> Bool {
        guard Self.modelFile() == nil else { return false }
        self.window = window
        offerModelDownload()
        return true
    }

    /// Stops without inserting anything (or abandons a download).
    func cancel() {
        cancelled = true
        switch state {
        case .recording, .finishing:
            endSession()
            state = .idle
        case .downloading: downloadTask?.cancel()
        case .idle: break
        }
    }

    private func start(target: DictationTarget, window: NSWindow?) {
        self.window = window
        guard let model = Self.modelFile() else {
            offerModelDownload()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin(target: target, model: model)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    granted ? self.begin(target: target, model: model) : self.flash("Microphone access denied")
                }
            }
        default:
            let alert = NSAlert()
            alert.messageText = "Keno doesn’t have access to the microphone."
            alert.informativeText = "Allow it in System Settings ▸ Privacy & Security ▸ Microphone."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func begin(target: DictationTarget, model: URL) {
        guard state == .idle else { return }
        let s = Session(target: target, model: model, language: language, prompt: target.dictationPrompt())
        s.onText = { [weak self, weak s] text, newParagraph in
            guard let self, let s, self.session === s else { return }
            self.deliver(text, newParagraph: newParagraph, session: s)
        }
        s.onFailure = { [weak self, weak s] message in
            guard let self, let s, self.session === s else { return }
            self.endSession()
            self.state = .idle
            self.flash(message)
        }
        do {
            try s.start()
        } catch {
            flash((error as NSError) == MicRecorder.noInput ? "No microphone found" : "Couldn’t start recording")
            return
        }
        s.mic.onInterrupted = { [weak self] in self?.stop() } // e.g. headphones unplugged: keep what we have
        session = s
        self.target = target
        targetLabel = target.dictationLabel
        cancelled = false
        message = nil
        state = .recording(since: Date())
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.notify() }
        stopTimer = Timer.scheduledTimer(withTimeInterval: Self.maxDuration, repeats: false) { [weak self] _ in self?.stop() }
    }

    private func stop() {
        guard isRecording, let s = session else { return }
        stopTimers()
        state = .finishing
        s.finish { [weak self, weak s] in
            guard let self, let s, self.session === s else { return }
            if !s.streams {
                let text = s.collected.joined(separator: " ")
                if !text.isEmpty { self.deliverFinal(text) }
            }
            let empty = s.collected.isEmpty
            self.endSession()
            self.state = .idle
            if empty { self.flash("No speech detected") }
        }
    }

    private func endSession() {
        stopTimers()
        session?.cancel()
        session = nil
    }

    private func stopTimers() {
        ticker?.invalidate()
        ticker = nil
        stopTimer?.invalidate()
        stopTimer = nil
    }

    // MARK: Delivering text

    private func deliver(_ text: String, newParagraph: Bool, session s: Session) {
        guard s.streams else { return } // the terminal gets everything in one paste at the end
        guard let target else {
            copyToClipboard(text, note: "Document closed — dictation copied to the clipboard")
            return
        }
        target.insertDictation(text, newParagraph: newParagraph)
    }

    private func deliverFinal(_ text: String) {
        guard let target else {
            copyToClipboard(text, note: "Terminal closed — dictation copied to the clipboard")
            return
        }
        target.insertDictation(text, newParagraph: false)
    }

    private func copyToClipboard(_ text: String, note: String) {
        let pb = NSPasteboard.general
        // Append to what we already copied during this dictation.
        let previous = clipboardCarry
        clipboardCarry = previous.isEmpty ? text : previous + " " + text
        pb.clearContents()
        pb.setString(clipboardCarry, forType: .string)
        flash(note)
    }
    private var clipboardCarry = ""

    /// Joins Whisper's segment lines and drops non-speech markers like [BLANK_AUDIO] or (keyboard clicking).
    static func clean(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        let lines = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        s = lines.filter { line in
            !(line.hasPrefix("(") && line.hasSuffix(")")) && !(line.hasPrefix("*") && line.hasSuffix("*"))
        }.joined(separator: " ")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Models

    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keno/models", isDirectory: true)
    }

    /// Model files in the models folder, including any ggml model the user dropped in.
    static func installedModels() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path)) ?? []
        return files.filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }.sorted()
    }

    static func isInstalled(_ file: String) -> Bool {
        FileManager.default.fileExists(atPath: modelsDirectory.appendingPathComponent(file).path)
    }

    /// The model used for transcription: the chosen one, else the most accurate installed one.
    static func modelFile() -> URL? {
        activeModelName().map { modelsDirectory.appendingPathComponent($0) }
    }

    static func activeModelName() -> String? {
        if let chosen = shared.chosenModel, isInstalled(chosen) { return chosen }
        let installed = installedModels()
        let preference = ["ggml-large-v3-turbo-q5_0.bin", "ggml-large-v3-turbo.bin", "ggml-medium.bin",
                          "ggml-small.bin", "ggml-small.en.bin", "ggml-base.bin", "ggml-base.en.bin",
                          "ggml-tiny.bin", "ggml-tiny.en.bin"]
        return preference.first(where: installed.contains) ?? installed.first
    }

    /// Picks a model from the Dictation Model menu, downloading it first if needed.
    func chooseModel(_ file: String, window: NSWindow?) {
        self.window = window
        if Self.isInstalled(file) {
            chosenModel = file
            flash("Dictation model: \(Self.displayName(file))")
            return
        }
        guard !isBusy else { NSSound.beep(); return }
        download(file)
    }

    static func displayName(_ file: String) -> String {
        catalog.first { $0.file == file }?.name ?? file
    }

    // MARK: Model download

    private var downloadTask: URLSessionDownloadTask?
    private(set) var downloadName = ""

    private func offerModelDownload() {
        let recommended = Self.recommendedModel
        let fastest = Self.catalog[0]
        let alert = NSAlert()
        alert.messageText = "Download a speech model?"
        alert.informativeText = "Keno transcribes on this Mac, nothing is sent anywhere. It needs a Whisper model "
            + "(free, one-time download) that understands all major languages.\n\n"
            + "\(recommended.name) is the best fit for this Mac; \(fastest.name) is smaller and faster. "
            + "You can switch any time under Edit ▸ Dictation Model."
        alert.addButton(withTitle: "\(recommended.name) · \(recommended.size)")
        alert.addButton(withTitle: "\(fastest.name) · \(fastest.size)")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: download(recommended.file)
        case .alertSecondButtonReturn: download(fastest.file)
        default: break
        }
    }

    private func download(_ file: String) {
        guard let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)") else { return }
        downloadName = file
        cancelled = false
        message = nil
        let urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        downloadTask = urlSession.downloadTask(with: url)
        downloadTask?.resume()
        state = .downloading(progress: 0)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        state = .downloading(progress: Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let ok = (downloadTask.response as? HTTPURLResponse)?.statusCode == 200
        let dest = Self.modelsDirectory.appendingPathComponent(downloadName)
        do {
            guard ok else { throw NSError(domain: "Keno", code: 2) }
            try FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            chosenModel = downloadName
            message = "\(Self.displayName(downloadName)) ready — press ⌥⌘R to dictate"
        } catch {
            message = "Model download failed"
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        downloadTask = nil
        session.finishTasksAndInvalidate()
        state = .idle
        if error != nil, !cancelled { flash("Model download failed") }
        else if let msg = message { flash(msg) }
    }

    // MARK: Helpers

    private func flash(_ text: String) {
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.message == text { self?.message = nil }
        }
    }

    private func notify() {
        if state == .idle { clipboardCarry = "" }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Text for the status bar.
    var statusText: String? {
        switch state {
        case .recording(let since):
            let s = Int(Date().timeIntervalSince(since))
            return String(format: "%d:%02d", s / 60, s % 60)
        case .finishing: return "Transcribing…"
        case .downloading(let p): return "Downloading \(Self.displayName(downloadName)) model \(Int(p * 100))%"
        case .idle: return message
        }
    }
}

// MARK: - Session

/// One dictation: mic → chunker (audio queue) → whisper (its own serial queue) → main thread.
private final class Session {
    let mic = MicRecorder()
    let streams: Bool
    /// Cleaned text of every transcribed chunk, in order (main thread).
    private(set) var collected: [String] = []

    var onText: ((String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    private let model: URL
    private let audioQueue = DispatchQueue(label: "keno.dictation.audio")
    private let whisperQueue = DispatchQueue(label: "keno.dictation.whisper", qos: .userInitiated)
    private var chunker = SpeechChunker()        // audioQueue only
    private var transcriber: Transcriber?        // whisperQueue only
    private var language: String                 // whisperQueue only
    private var context: String                  // whisperQueue only: recent text, steers the next chunk
    private var lastEndsSentence: Bool           // whisperQueue only
    private let abort = AbortFlag()

    init(target: DictationTarget, model: URL, language: String, prompt: String?) {
        self.model = model
        self.streams = target.dictationStreamsText
        self.language = language
        self.context = prompt ?? ""
        let trimmed = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.lastEndsSentence = trimmed.isEmpty || ".!?:".contains(trimmed.last!)
    }

    func start() throws {
        // Load the model while the user starts talking; the first chunk simply waits for it.
        whisperQueue.async { [model] in
            do {
                self.transcriber = try Transcriber(model: model)
            } catch {
                DispatchQueue.main.async { self.onFailure?("Couldn’t load the speech model") }
            }
        }
        mic.onSamples = { [weak self] samples in
            self?.audioQueue.async {
                guard let self else { return }
                for chunk in self.chunker.append(samples) { self.transcribe(chunk) }
            }
        }
        try mic.start()
    }

    /// Stops recording, transcribes what's left, then calls `done` on the main thread.
    func finish(_ done: @escaping () -> Void) {
        mic.stop()
        audioQueue.async {
            if let rest = self.chunker.finish() { self.transcribe(rest) }
            self.whisperQueue.async {
                self.transcriber = nil // free the model now; nothing else is queued
                DispatchQueue.main.async(execute: done)
            }
        }
    }

    func cancel() {
        abort.set(true)
        mic.stop()
        whisperQueue.async { self.transcriber = nil }
    }

    private func transcribe(_ chunk: SpeechChunker.Chunk) {
        whisperQueue.async {
            guard !self.abort.isSet, let t = self.transcriber else { return }
            let prompt = self.context.isEmpty ? nil : String(self.context.suffix(220))
            let raw = (try? t.transcribe(chunk.samples, language: self.language, prompt: prompt)) ?? ""
            if self.abort.isSet { return }
            let text = Dictation.clean(raw)
            guard !text.isEmpty else { return }
            // Stick with the detected language, so a short chunk can't flip it.
            if self.language == "auto", let detected = t.lastLanguage { self.language = detected }
            let newParagraph = chunk.pauseBefore >= 3 && self.lastEndsSentence && !self.context.isEmpty
            self.context += " " + text
            self.lastEndsSentence = ".!?".contains(text.last!)
            DispatchQueue.main.async {
                guard !self.abort.isSet else { return }
                self.collected.append(text)
                self.onText?(text, newParagraph)
            }
        }
    }
}
