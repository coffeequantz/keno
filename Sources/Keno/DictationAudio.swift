import AVFoundation

/// Captures the microphone as 16 kHz mono Float32 (what Whisper wants), entirely in memory.
final class MicRecorder {
    /// Called on the audio thread with converted samples.
    var onSamples: (([Float]) -> Void)?
    /// Called on the main thread if the input device changes or disappears mid-recording.
    var onInterrupted: (() -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let levelLock = NSLock()
    private var _level: Float = 0
    private var configObserver: NSObjectProtocol?
    private var running = false

    static let noInput = NSError(domain: "Keno.Mic", code: 1)

    /// Recent input level, 0…1, for the level meter.
    var level: Float { levelLock.lock(); defer { levelLock.unlock() }; return _level }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: target) else {
            throw MicRecorder.noInput
        }
        self.converter = converter
        let ratio = target.sampleRate / format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.convert(buffer, ratio: ratio)
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.onInterrupted?()
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        levelLock.lock(); _level = 0; levelLock.unlock()
    }

    private func convert(_ buffer: AVAudioPCMBuffer, ratio: Double) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        var sum: Float = 0
        for s in samples { sum += s * s }
        let db = 10 * log10(max(sum / Float(samples.count), 1e-10)) // dBFS of the mean power
        levelLock.lock(); _level = max(0, min(1, (db + 50) / 45)); levelLock.unlock()
        onSamples?(samples)
    }
}

/// Splits a live 16 kHz stream into chunks at natural pauses, so each piece can be transcribed
/// while you keep talking. Pure logic, no audio APIs; use it from one serial queue.
struct SpeechChunker {
    struct Chunk {
        let samples: [Float]
        /// Seconds of silence right before this chunk (a long one suggests a new paragraph).
        let pauseBefore: Double
    }

    static let rate = 16_000
    private static let frame = rate / 10 // 100 ms analysis frames

    private var buffer: [Float] = []
    private var pending: [Float] = []      // less than one frame, waiting for more samples
    private var frames: [Bool] = []        // voiced flag per frame in `buffer`
    private var silentRun = 0              // trailing silent frames
    private var pauseBefore = 0.0          // silence dropped before the current buffer started
    private var noiseFloor: Float = 0.002  // a quiet room; never seeded from the first frame (that may be speech)

    private var voicedFrames: Int { frames.lazy.filter { $0 }.count }
    private var seconds: Double { Double(buffer.count) / Double(Self.rate) }

    /// Adds samples; returns any chunks that are ready.
    mutating func append(_ samples: [Float]) -> [Chunk] {
        pending += samples
        var out: [Chunk] = []
        while pending.count >= Self.frame {
            let f = Array(pending.prefix(Self.frame))
            pending.removeFirst(Self.frame)
            if let c = add(frame: f) { out.append(c) }
        }
        return out
    }

    /// Whatever is left when recording stops.
    mutating func finish() -> Chunk? {
        buffer += pending
        pending = []
        return cut(at: buffer.count, keepingSilence: 0)
    }

    private mutating func add(frame f: [Float]) -> Chunk? {
        var sum: Float = 0
        for s in f { sum += s * s }
        let rms = (sum / Float(f.count)).squareRoot()
        // Track the room's noise floor: drops fast, rises slowly (so speech doesn't raise it much).
        noiseFloor = rms < noiseFloor ? (noiseFloor + rms) / 2 : noiseFloor + (rms - noiseFloor) * 0.002
        let voiced = rms > max(0.006, noiseFloor * 3) // ≈ -44 dBFS: quiet speech still counts

        buffer += f
        frames.append(voiced)
        silentRun = voiced ? 0 : silentRun + 1

        // Nothing said yet: don't pile up silence (keep the last second), just remember how long it was.
        if voicedFrames == 0, frames.count > 10 {
            buffer.removeFirst(Self.frame)
            frames.removeFirst()
            pauseBefore += 0.1
            return nil
        }
        // A 3 s pause ends a thought (and may start a new paragraph), however short the chunk.
        if silentRun >= 30, voicedFrames >= 10 { return cut(at: buffer.count, keepingSilence: silentRun) }
        // Otherwise long pauses inside a short chunk only cost transcription time; keep at most 1 s of them.
        if silentRun > 10, seconds < 6 {
            buffer.removeLast(Self.frame)
            frames.removeLast()
            return nil
        }
        if seconds >= 6, silentRun >= 15 { return cut(at: buffer.count, keepingSilence: silentRun) } // 1.5 s pause
        if seconds >= 15, silentRun >= 6 { return cut(at: buffer.count, keepingSilence: silentRun) } // 0.6 s pause
        if seconds >= 28 { return cut(at: quietestCutPoint(), keepingSilence: 0) }                    // never exceed Whisper's 30 s window
        return nil
    }

    /// Cuts the buffer; the trailing `keepingSilence` frames count as the next chunk's pause.
    private mutating func cut(at sampleIndex: Int, keepingSilence: Int) -> Chunk? {
        let head = Array(buffer.prefix(sampleIndex))
        let headFrames = min(frames.count, (sampleIndex + Self.frame - 1) / Self.frame)
        let voiced = frames.prefix(headFrames).filter { $0 }.count
        let chunk = voiced >= 3 ? Chunk(samples: head, pauseBefore: pauseBefore) : nil // < 0.3 s of speech: noise
        buffer.removeFirst(min(sampleIndex, buffer.count))
        frames.removeFirst(headFrames)
        pauseBefore = Double(keepingSilence) / 10 + (chunk == nil ? pauseBefore : 0)
        if keepingSilence > 0 {
            buffer = []
            frames = []
        }
        silentRun = 0
        return chunk
    }

    /// For forced cuts: the end of the quietest frame in the last 8 s, so words aren't split.
    private func quietestCutPoint() -> Int {
        let lastFrames = min(frames.count, 80)
        let start = frames.count - lastFrames
        var best = frames.count
        for i in stride(from: frames.count - 1, through: start, by: -1) where !frames[i] {
            best = i + 1
            break
        }
        return min(best * Self.frame, buffer.count)
    }
}
