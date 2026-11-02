import AppKit

/// "Format Document" by piping the buffer through a standard CLI formatter, if one is installed.
enum Formatter {
    struct Tool {
        let executable: String
        let args: (_ path: String) -> [String]
    }

    /// Candidates per file type, in order of preference. The first one found on PATH is used.
    private static func candidates(for url: URL) -> [Tool] {
        let prettier = Tool(executable: "prettier") { ["--stdin-filepath", $0] }
        switch url.pathExtension.lowercased() {
        case "swift":
            return [Tool(executable: "swift-format") { ["format", "--assume-filename", $0, "-"] }]
        case "js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx", "css", "scss", "less", "html", "htm", "vue",
             "svelte", "md", "markdown", "mdx", "yml", "yaml", "graphql":
            return [prettier]
        case "json", "jsonc", "json5":
            return [prettier, Tool(executable: "jq") { _ in ["--indent", "2", "."] }]
        case "py", "pyi":
            return [Tool(executable: "ruff") { ["format", "--stdin-filename", $0, "-"] },
                    Tool(executable: "black") { ["-q", "--stdin-filename", $0, "-"] }]
        case "go":
            return [Tool(executable: "gofmt") { _ in [] }]
        case "rs":
            return [Tool(executable: "rustfmt") { _ in ["--edition", "2021"] }]
        case "c", "h", "m", "mm", "cpp", "cc", "cxx", "hpp", "hh", "cs", "java", "proto":
            return [Tool(executable: "clang-format") { ["--assume-filename=\($0)"] }]
        case "sh", "bash", "zsh":
            return [Tool(executable: "shfmt") { _ in ["-i", "4"] }]
        case "xml", "plist", "svg":
            return [Tool(executable: "xmllint") { _ in ["--format", "-"] }]
        case "rb":
            return [Tool(executable: "rubocop") { ["-a", "--stderr", "--stdin", $0] }]
        case "toml":
            return [Tool(executable: "taplo") { _ in ["fmt", "-"] }]
        case "sql":
            return [Tool(executable: "sql-formatter") { _ in [] }]
        default:
            return []
        }
    }

    // MARK: Locating tools

    /// PATH from the user's login shell (GUI apps get a minimal PATH), resolved once.
    private static let loginPath: String = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        var path = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let s = String(data: data, encoding: .utf8), !s.isEmpty { path = s }
        }
        return path + ":" + NSHomeDirectory() + "/.cargo/bin"
    }()

    private static func locate(_ name: String, projectRoot: URL?) -> String? {
        var dirs: [String] = []
        if let root = projectRoot { dirs.append(root.appendingPathComponent("node_modules/.bin").path) }
        dirs += loginPath.split(separator: ":").map(String.init)
        for d in dirs {
            let candidate = (d as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        if name == "swift-format" { // ships with Xcode
            let xcode = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-format"
            if FileManager.default.isExecutableFile(atPath: xcode) { return xcode }
        }
        return nil
    }

    // MARK: Running

    enum Outcome {
        case formatted(String)
        case unchanged
        case noFormatter([String])
        case failed(String)
    }

    /// Runs off the main thread; `completion` is called on the main thread.
    static func format(text: String, url: URL, projectRoot: URL?, completion: @escaping (Outcome) -> Void) {
        let tools = candidates(for: url)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Outcome
            if let (tool, path) = tools.lazy.compactMap({ t in locate(t.executable, projectRoot: projectRoot).map { (t, $0) } }).first {
                outcome = run(path: path, args: tool.args(url.path), input: text,
                              cwd: projectRoot ?? url.deletingLastPathComponent())
            } else {
                outcome = .noFormatter(tools.map(\.executable))
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    private static func run(path: String, args: [String], input: String, cwd: URL) -> Outcome {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginPath
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return .failed(error.localizedDescription) }

        // Write stdin and drain stdout/stderr concurrently so large files can't deadlock on pipe buffers.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        inPipe.fileHandleForWriting.write(Data(input.utf8))
        try? inPipe.fileHandleForWriting.close()

        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timer)
        p.waitUntilExit()
        group.wait()
        timer.cancel()

        guard p.terminationStatus == 0, let out = String(data: outData, encoding: .utf8), !out.isEmpty else {
            let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tool = (path as NSString).lastPathComponent
            return .failed(err.isEmpty ? "\(tool) exited with status \(p.terminationStatus)." : String(err.prefix(1500)))
        }
        return out == input ? .unchanged : .formatted(out)
    }
}

extension Document {
    /// Replaces the whole buffer as one undoable edit, keeping the caret on the same line/column.
    func applyFormatted(_ text: String) {
        let tv = textView
        let ns = tv.string as NSString
        let caret = tv.selectedRange().location
        let line = lines.line(of: caret)
        let column = caret - lines.starts[line]
        let origin = scrollView.contentView.bounds.origin

        let full = NSRange(location: 0, length: ns.length)
        guard tv.shouldChangeText(in: full, replacementString: text) else { return }
        tv.textStorage?.replaceCharacters(in: full, with: NSAttributedString(string: text, attributes: tv.typingAttributes))
        tv.didChangeText()

        let newLine = min(line, lines.count - 1)
        let lineRange = lines.range(ofLine: newLine)
        let maxCol = max(0, lineRange.length - (newLine < lines.count - 1 ? 1 : 0))
        tv.setSelectedRange(NSRange(location: lineRange.location + min(column, maxCol), length: 0))
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
