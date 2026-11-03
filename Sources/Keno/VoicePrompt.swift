import AppKit
import AVFoundation

/// Dictate a prompt into the terminal: record the mic, transcribe locally with whisper.cpp
/// (`whisper-cli`), and paste the text into the active terminal without pressing Enter.
/// Nothing runs and nothing is loaded until you start a recording.
final class VoicePrompt: NSObject, AVAudioRecorderDelegate, URLSessionDownloadDelegate {
    enum State: Equatable {
        case idle
        case recording(since: Date)
        case transcribing
        case downloading(progress: Double)
    }

    static let shared = VoicePrompt()
    static let didChange = Notification.Name("KenoVoicePromptDidChange")

    private(set) var state: State = .idle { didSet { notify() } }
    /// A short message shown next to the mic for a few seconds ("No speech detected", …).
    private(set) var message: String? { didSet { notify() } }
    /// The terminal panel that started the recording and receives the text.
    private(set) weak var target: TerminalPanel?

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var whisperProcess: Process?
    private var ticker: Timer?
    private var cancelled = false

    /// "auto" (detect), or a language code such as "en" or "de".
    var language: String {
        get { UserDefaults.standard.string(forKey: "voiceLanguage") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceLanguage") }
    }

    // MARK: Public

    func toggle(for panel: TerminalPanel) {
        switch state {
        case .idle: start(for: panel)
        case .recording: stop()
        case .transcribing, .downloading: NSSound.beep()
        }
    }

    /// Stops without transcribing (or abandons a running transcription / download).
    func cancel() {
        cancelled = true
        switch state {
        case .recording: recorder?.stop()
        case .transcribing: whisperProcess?.terminate()
        case .downloading: downloadTask?.cancel()
        case .idle: break
        }
    }

    var isBusy: Bool { state != .idle }

    #if DEBUG
    /// Test hook for rendering the UI in each state.
    func debugSet(state: State, message: String? = nil) { self.message = message; self.state = state }
    #endif

    /// Current microphone level, 0…1 (for the level meter while recording).
    var inputLevel: Float {
        guard let r = recorder, r.isRecording else { return 0 }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0) // -160…0 dBFS
        return max(0, min(1, (db + 50) / 45))
    }

    // MARK: Starting

    private func start(for panel: TerminalPanel) {
        guard Self.whisperExecutable() != nil else {
            Self.showInstallHelp()
            return
        }
        guard Self.modelFile() != nil else {
            offerModelDownload()
            return
        }
        target = panel
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { granted ? self.beginRecording() : self.flash("Microphone access denied") }
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

    private func beginRecording() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keno-voice-\(UUID().uuidString).wav")
        // Whisper wants 16 kHz mono 16-bit PCM; AVAudioRecorder converts from the mic for us.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.delegate = self
            r.isMeteringEnabled = true
            guard r.record(forDuration: 300) else { throw NSError(domain: "Keno", code: 1) } // 5 min cap
            recorder = r
            recordingURL = url
            cancelled = false
            message = nil
            state = .recording(since: Date())
            ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.notify() }
        } catch {
            flash("Couldn’t start recording")
        }
    }

    private func stop() { recorder?.stop() }

    // MARK: AVAudioRecorderDelegate

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        ticker?.invalidate()
        ticker = nil
        self.recorder = nil
        guard let url = recordingURL else { state = .idle; return }
        recordingURL = nil
        if cancelled || !flag {
            try? FileManager.default.removeItem(at: url)
            state = .idle
            return
        }
        transcribe(url)
    }

    // MARK: Transcription

    /// Biases Whisper toward spelling code terms correctly.
    private static let vocabularyHint =
        "A prompt for an AI coding assistant about software development: functions, variables, API, JSON, Git, "
        + "commit, refactor, TypeScript, Swift, Python, SQL, README, terminal."

    private func transcribe(_ wav: URL) {
        guard let whisper = Self.whisperExecutable(), let model = Self.modelFile() else {
            try? FileManager.default.removeItem(at: wav)
            state = .idle
            return
        }
        state = .transcribing
        let threads = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))
        let args = ["-m", model.path, "-f", wav.path, "-l", language, "-t", String(threads),
                    "-nt", "-np", "--prompt", Self.vocabularyHint]
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = whisper
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            var text = ""
            if (try? p.run()) != nil {
                DispatchQueue.main.async { self.whisperProcess = p }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus == 0 { text = Self.clean(String(decoding: data, as: UTF8.self)) }
            }
            try? FileManager.default.removeItem(at: wav) // never keep recordings around
            DispatchQueue.main.async {
                self.whisperProcess = nil
                self.state = .idle
                if self.cancelled { return }
                if text.isEmpty {
                    self.flash(p.terminationStatus == 0 ? "No speech detected" : "Transcription failed")
                } else {
                    self.target?.insertDictation(text)
                }
            }
        }
    }

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

    // MARK: Locating whisper.cpp and models

    static func whisperExecutable() -> URL? {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for d in dirs {
            let path = (d as NSString).appendingPathComponent("whisper-cli")
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keno/models", isDirectory: true)
    }

    /// Best installed model, most accurate first. Drop any ggml model into the models folder to use it.
    static func modelFile() -> URL? {
        let preference = ["ggml-large-v3-turbo-q5_0.bin", "ggml-large-v3-turbo.bin", "ggml-medium.bin",
                          "ggml-small.bin", "ggml-small.en.bin", "ggml-base.bin", "ggml-base.en.bin",
                          "ggml-tiny.bin", "ggml-tiny.en.bin"]
        for name in preference {
            let url = modelsDirectory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func showInstallHelp() {
        let alert = NSAlert()
        alert.messageText = "Voice prompts need whisper.cpp"
        alert.informativeText = "It’s free and runs locally. Install it with Homebrew:\n\n    brew install whisper.cpp\n\nthen try again."
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("brew install whisper.cpp", forType: .string)
        }
    }

    // MARK: Model download (one-time)

    private var downloadTask: URLSessionDownloadTask?
    private var downloadName = ""

    private func offerModelDownload() {
        let alert = NSAlert()
        alert.messageText = "Download a speech model?"
        alert.informativeText = "Whisper needs a model file (one-time download, free). It’s stored in "
            + "~/Library/Application Support/Keno/models and only loaded while transcribing.\n\n"
            + "Small understands technical terms and mixed languages noticeably better; Base is faster."
        alert.addButton(withTitle: "Small · 466 MB")
        alert.addButton(withTitle: "Base · 142 MB")
        alert.addButton(withTitle: "Cancel")
        let name: String
        switch alert.runModal() {
        case .alertFirstButtonReturn: name = "ggml-small.bin"
        case .alertSecondButtonReturn: name = "ggml-base.bin"
        default: return
        }
        guard let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(name)") else { return }
        downloadName = name
        cancelled = false
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        downloadTask = session.downloadTask(with: url)
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
            message = "Speech model ready — press ⌥⌘R to dictate"
        } catch {
            message = "Model download failed"
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        downloadTask = nil
        session.finishTasksAndInvalidate()
        state = .idle
        if error != nil, !cancelled { flash("Model download failed") }
        if let msg = message { flash(msg) }
    }

    // MARK: Helpers

    private func flash(_ text: String) {
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.message == text { self?.message = nil }
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Text for the status label next to the mic button.
    var statusText: String? {
        switch state {
        case .recording(let since):
            let s = Int(Date().timeIntervalSince(since))
            return String(format: "Recording  %d:%02d", s / 60, s % 60)
        case .transcribing: return "Transcribing…"
        case .downloading(let p): return "Downloading model \(Int(p * 100))%"
        case .idle: return message
        }
    }
}
