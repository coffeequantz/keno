import Foundation
import whisper

/// whisper.cpp, in-process (statically linked into Keno). One instance per dictation: the model is
/// loaded when recording starts and freed when the dictation ends, so it costs no memory while idle.
/// Not thread-safe: use it from one serial queue. Only `abortFlag` may be touched from elsewhere.
final class Transcriber {
    enum Failure: Error { case modelLoadFailed, transcriptionFailed }

    /// Set from any thread to abort a running transcription at the next checkpoint.
    let abortFlag = AbortFlag()
    private let ctx: OpaquePointer

    static func silenceLogs() {
        #if !DEBUG
        whisper_log_set({ _, _, _ in }, nil)
        #endif
    }

    init(model: URL) throws {
        var cparams = whisper_context_default_params()
        // Metal is fast on Apple Silicon. On Intel Macs the GPU path produces garbage; the CPU (AVX2) is reliable.
        #if arch(arm64)
        cparams.use_gpu = true
        #else
        cparams.use_gpu = false
        #endif
        guard let ctx = whisper_init_from_file_with_params(model.path, cparams) else { throw Failure.modelLoadFailed }
        self.ctx = ctx
    }

    deinit { whisper_free(ctx) }

    /// Transcribes 16 kHz mono samples. `language` is a code or "auto"; `prompt` is context that
    /// steers spelling and style (previous text, or a vocabulary hint). Returns raw segment text.
    func transcribe(_ samples: [Float], language: String, prompt: String?) throws -> String {
        guard !samples.isEmpty else { return "" }
        // Same decoding as whisper-cli's defaults (beam search, 5 beams): noticeably better on short audio.
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.beam_search.beam_size = 5
        params.greedy.best_of = 5
        params.n_threads = Int32(Self.threadCount)
        params.no_timestamps = true
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        let flag = Unmanaged.passUnretained(abortFlag).toOpaque()
        params.abort_callback = { ud in ud.map { Unmanaged<AbortFlag>.fromOpaque($0).takeUnretainedValue().isSet } ?? false }
        params.abort_callback_user_data = flag
        params.encoder_begin_callback = { _, _, ud in
            !(ud.map { Unmanaged<AbortFlag>.fromOpaque($0).takeUnretainedValue().isSet } ?? false)
        }
        params.encoder_begin_callback_user_data = flag

        let status: Int32 = language.withCString { lang in
            (prompt ?? "").withCString { hint in
                params.language = lang
                params.initial_prompt = prompt == nil ? nil : hint
                return samples.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
            }
        }
        if abortFlag.isSet { return "" }
        guard status == 0 else { throw Failure.transcriptionFailed }

        var lines: [String] = []
        for i in 0..<whisper_full_n_segments(ctx) {
            if let text = whisper_full_get_segment_text(ctx, i) { lines.append(String(cString: text)) }
        }
        return lines.joined(separator: "\n")
    }

    /// The language whisper used for the last transcription (useful after "auto").
    var lastLanguage: String? {
        let id = whisper_full_lang_id(ctx)
        guard id >= 0, let s = whisper_lang_str(id) else { return nil }
        return String(cString: s)
    }

    /// Physical cores, capped: more threads than that only slows whisper down.
    private static var threadCount: Int {
        max(2, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))
    }
}

/// A thread-safe boolean for cancelling from the main thread while whisper runs elsewhere.
final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}
