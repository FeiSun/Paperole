import Foundation

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Talks to `<python> -m paperole.cli rpc` over JSON lines (CONTRACT §7).
/// The engine runs requests one at a time; replies are matched by id. The process is started on the
/// first call and started again on the next call after it exits.
final class EngineClient: @unchecked Sendable {
    /// The checkout this app was built from: the repository root, four levels above this file's path at build time.
    static let checkoutRoot = URL(fileURLWithPath: sourceFile).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    /// The engine's Python unless the `enginePython` setting names another: the venv in that checkout.
    static let defaultPython = checkoutRoot.appendingPathComponent("engine/.venv/bin/python").path

    /// The engine the official app carries (build_app.sh VARIANT=release, by release.sh): Contents/Resources/engine,
    /// holding a snapshot of the paperole package, so engine work in the repo reaches real reviews only with the next
    /// release. nil without it (Paperole Dev, `swift test`, `swift run`): the checkout's live engine (`checkoutEngine`).
    static func bundledEngine(resources: URL? = Bundle.main.resourceURL) -> URL? {
        guard let folder = resources?.appendingPathComponent("engine") else { return nil }
        var isFolder: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: folder.appendingPathComponent("paperole").path, isDirectory: &isFolder)
        return found && isFolder.boolValue ? folder : nil
    }

    /// The engine folder of the checkout this app was built from (engine/, beside mac/, from this file's path at
    /// build time): Paperole Dev, `swift test` and `swift run` run its paperole package, the live engine, with the
    /// venv's Python; a worktree's build runs the worktree's. Nothing is installed in the venv for it. nil when it is not
    /// there.
    static func checkoutEngine(source: String = sourceFile) -> URL? {
        let engine = URL(fileURLWithPath: source).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("engine")
        let found = FileManager.default.fileExists(atPath: engine.appendingPathComponent("paperole/__init__.py").path)
        return found ? engine : nil
    }

    static let sourceFile = #filePath

    /// The engine process's environment: the app's, unbuffered, in UTF-8, the engine's folder first on PYTHONPATH.
    /// For a bundled engine no bytecode is written: nothing ever writes inside the installed bundle (`frozen`); the
    /// checkout's writes its __pycache__ as Python does.
    static func environment(_ base: [String: String], engine: URL?, frozen: Bool = true) -> [String: String] {
        var env = base
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        if let engine {
            env["PYTHONPATH"] = ([engine.path] + [env["PYTHONPATH"] ?? ""].filter { !$0.isEmpty }).joined(separator: ":")
            if frozen { env["PYTHONDONTWRITEBYTECODE"] = "1" }
        }
        return env
    }

    /// The defaults domain `enginePython` is read from: the running bundle's own (each app has its own).
    static var defaultsDomain: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }

    private let queue = DispatchQueue(label: "Paperole.engine")
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var stderrTail = ""
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var replies: [Int: Result<Data, Error>] = [:]  // replies that came before their caller waited for them
    private var progress: [Int: @Sendable (String) -> Void] = [:]  // also: the requests sent and not answered yet

    /// Sends one request (`params` is a JSON object) and returns the JSON of its `result`.
    func call(_ method: String, params: Data,
              progress onProgress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Data {
        try await result(send(method, params: params, progress: onProgress))
    }

    /// Writes one request now, on the caller's thread, and returns its id: requests reach the engine in the order
    /// they were sent. (Written from a Task after a hop off the main actor, two requests sent one after the other
    /// could arrive the other way round.)
    func send(_ method: String, params: Data, progress onProgress: @escaping @Sendable (String) -> Void = { _ in }) -> Int {
        let paramsJSON = String(decoding: params, as: UTF8.self)
        return queue.sync {
            let id = nextID
            nextID += 1
            progress[id] = onProgress
            do {
                try startIfNeeded()
                let line = "{\"id\":\(id),\"method\":\"\(method)\",\"params\":\(paramsJSON)}\n"
                try input?.write(contentsOf: Data(line.utf8))
            } catch {
                finish(id, .failure(EngineError(message: "Could not talk to the engine: \(error.localizedDescription)")))
            }
            return id
        }
    }

    /// The JSON of request `id`'s `result`, once its reply has come.
    func result(_ id: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let r = self.replies.removeValue(forKey: id) { cont.resume(with: r) } else { self.pending[id] = cont }
            }
        }
    }

    /// Lets the process end once it has answered everything sent (its input closes); the next request starts another.
    /// Nothing is cut off: with a request waiting it does nothing.
    func stop() {
        queue.sync {
            guard progress.isEmpty else { return }
            try? input?.close()
            input = nil
            process = nil
        }
    }

    private func finish(_ id: Int, _ r: Result<Data, Error>) {
        progress[id] = nil
        if let cont = pending.removeValue(forKey: id) { cont.resume(with: r) } else { replies[id] = r }
    }

    private func startIfNeeded() throws {
        if process != nil { return }
        let python = UserDefaults.standard.string(forKey: "enginePython") ?? Self.defaultPython
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw EngineError(message: "Engine Python not found at \(python). Set it with: defaults write \(Self.defaultsDomain) enginePython /path/to/python")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-m", "paperole.cli", "rpc"]
        // A neutral working folder: `-m` puts it first on sys.path, before PYTHONPATH's engine folder.
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        let bundled = Self.bundledEngine()
        p.environment = Self.environment(ProcessInfo.processInfo.environment, engine: bundled ?? Self.checkoutEngine(),
                                         frozen: bundled != nil)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            self?.queue.async { self?.consume(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            FileHandle.standardError.write(data)
            self?.queue.async { self?.appendStderr(String(decoding: data, as: UTF8.self)) }
        }
        p.terminationHandler = { [weak self] proc in
            self?.queue.async { self?.exited(proc) }
        }
        try p.run()
        process = p
        input = stdin.fileHandleForWriting
        buffer = Data()
        stderrTail = ""
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(Data(line))
        }
    }

    private func handle(_ line: Data) {
        guard !line.isEmpty else { return }
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let id = obj["id"] as? Int else {
            appendStderr("stdout: " + String(decoding: line, as: UTF8.self) + "\n")
            return
        }
        if obj["event"] as? String == "progress" {
            if let message = obj["message"] as? String { progress[id]?(message) }
            return
        }
        guard progress[id] != nil else { return }
        if let result = obj["result"], let data = try? JSONSerialization.data(withJSONObject: result) {
            finish(id, .success(data))
        } else {
            let message = (obj["error"] as? [String: Any])?["message"] as? String ?? "The engine sent a malformed reply."
            finish(id, .failure(EngineError(message: message)))
        }
    }

    private func appendStderr(_ s: String) {
        stderrTail = String((stderrTail + s).suffix(3000))
    }

    private func exited(_ proc: Process) {
        guard proc === process else { return }
        process = nil
        input = nil
        let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = "The engine stopped (exit code \(proc.terminationStatus))." + (tail.isEmpty ? "" : "\n\n" + tail)
        for id in Array(progress.keys) { finish(id, .failure(EngineError(message: message))) }
    }
}
