import Foundation

public enum CLIError: Error, LocalizedError, Equatable {
    case timeout(String)
    case closed(String)
    case authenticationFailed
    /// The device answered, but not with a Junos prompt. Carries what it sent (for detection).
    case unrecognizedPrompt(String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let tail):
            return t("The device did not respond in time.") + (tail.isEmpty ? "" : " " + t("Last output: %@", tail))
        case .closed(let reason): return reason
        case .authenticationFailed: return t("Wrong username or password.")
        case .unrecognizedPrompt: return t("The device answered, but its prompt was not recognised.")
        }
    }
}

/// Text-mode Junos CLI session over any byte transport. Handles login (console or SSH),
/// shell → CLI, prompt detection and command/response framing.
public actor JunosCLI {
    public enum PromptKind: Equatable, Sendable { case login, password, shell, operational, configuration, pager, question }

    private let transport: Transport
    /// Raw bytes since the last reset. Decoded and cleaned on read, so escape sequences
    /// and multi-byte characters split across chunks are handled correctly.
    private var raw = Data()
    private var buffer: String { Self.clean(String(decoding: raw, as: UTF8.self)) }
    private var lastDataAt = ContinuousClock.now
    private var closedReason: String?
    private var readerTask: Task<Void, Never>?
    private var isOpen = false

    public init(transport: Transport) {
        self.transport = transport
    }

    // MARK: Lifecycle

    public func open() throws {
        guard !isOpen else { return }
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        try transport.open(
            onData: { continuation.yield($0) },
            onClose: { reason in
                continuation.yield(Data("\u{0}CLOSED:\(reason ?? t("The connection closed."))".utf8))
                continuation.finish()
            }
        )
        isOpen = true
        readerTask = Task { [weak self] in
            for await chunk in stream { await self?.ingest(chunk) }
        }
    }

    /// Logs in if needed and leaves the session at the operational (`>`) prompt with paging off.
    public func login(username: String, password: String?) async throws {
        try open()
        var sentUser = false, sentPassword = false
        try send("\r")
        _ = try? await waitUntil(idle: .seconds(2), timeout: .seconds(4)) { _ in false }

        for _ in 0..<20 {
            let kind = Self.promptKind(lastLine)
            switch kind {
            case .operational:
                try await configureTerminal()
                return
            case .login:
                if sentUser && sentPassword { throw CLIError.authenticationFailed }
                raw = Data()
                try send(username + "\r")
                sentUser = true
                sentPassword = false
                _ = try await waitForPrompt(timeout: .seconds(10))
            case .password:
                if sentPassword { throw CLIError.authenticationFailed }
                raw = Data()
                try send((password ?? "") + "\r")
                sentPassword = true
                _ = try await waitForPrompt(timeout: .seconds(20))
            case .shell:
                raw = Data()
                try send("cli\r")
                _ = try await waitForPrompt(timeout: .seconds(15))
            case .configuration:
                raw = Data()
                try send("exit configuration-mode\r")
                _ = try await waitForPrompt(timeout: .seconds(10))
            case .pager:
                raw = Data()
                try send("q")
                _ = try? await waitForPrompt(timeout: .seconds(5))
            case .question:
                raw = Data()
                try send("yes\r")
                _ = try? await waitForPrompt(timeout: .seconds(10))
            case nil:
                if buffer.contains("Login incorrect") || buffer.contains("Permission denied") {
                    throw CLIError.authenticationFailed
                }
                try send("\r")
                _ = try? await waitForPrompt(timeout: .seconds(4))
            }
        }
        throw CLIError.unrecognizedPrompt(String(buffer.suffix(4000)))
    }

    /// Leaves the console logged out (important for a shared physical console).
    public func logout() async {
        for _ in 0..<3 {
            let kind = Self.promptKind(lastLine)
            if kind == .login || closedReason != nil { break }
            raw = Data()
            switch kind {
            case .configuration: try? send("exit configuration-mode\r")
            case .question: try? send("yes\r")
            case .pager: try? send("q")
            default: try? send("exit\r")
            }
            _ = try? await waitForPrompt(timeout: .seconds(4))
        }
        close()
    }

    public func close() {
        readerTask?.cancel()
        readerTask = nil
        transport.close()
        isOpen = false
    }

    // MARK: Commands

    /// Runs one CLI command and returns its output without the echoed command and trailing prompt.
    /// `idle` is how long we wait without any new byte (serial consoles are slow but steady).
    public func run(_ command: String, idle: Duration = .seconds(20), timeout: Duration = .seconds(240)) async throws -> String {
        try ensureOpen()
        raw = Data()
        try send(command + "\r")
        let raw = try await waitUntil(idle: idle, timeout: timeout) { text in
            Self.endsWithCommandPrompt(text)
        }
        return Self.stripEchoAndPrompt(raw)
    }

    public var currentPrompt: PromptKind? { Self.promptKind(lastLine) }

    // MARK: Internals

    private func configureTerminal() async throws {
        _ = try await run("set cli screen-length 0", idle: .seconds(10))
        _ = try await run("set cli screen-width 0", idle: .seconds(10))
        _ = try await run("set cli complete-on-space off", idle: .seconds(10))
    }

    private func ensureOpen() throws {
        if let closedReason { throw CLIError.closed(closedReason) }
        guard isOpen else { throw TransportError.notOpen }
    }

    private func send(_ s: String) throws {
        try ensureOpen()
        try transport.send(Data(s.utf8))
    }

    private func ingest(_ chunk: Data) {
        if chunk.first == 0, let s = String(data: chunk, encoding: .utf8), s.hasPrefix("\u{0}CLOSED:") {
            closedReason = String(s.dropFirst("\u{0}CLOSED:".count))
            return
        }
        raw.append(chunk)
        lastDataAt = .now
    }

    private var lastLine: String {
        let trimmed = buffer.hasSuffix("\n") ? String(buffer.dropLast()) : buffer
        return trimmed.components(separatedBy: "\n").last ?? ""
    }

    private func waitForPrompt(timeout: Duration) async throws -> String {
        try await waitUntil(idle: timeout, timeout: timeout) { text in
            let last = text.components(separatedBy: "\n").last ?? ""
            return Self.promptKind(last) != nil
        }
    }

    /// Polls the buffer until `done` matches. Fails if no byte arrives for `idle` or the total exceeds `timeout`.
    private func waitUntil(idle: Duration, timeout: Duration, _ done: (String) -> Bool) async throws -> String {
        let start = ContinuousClock.now
        lastDataAt = start
        while true {
            if done(buffer) { return buffer }
            if let closedReason { throw CLIError.closed(closedReason) }
            let now = ContinuousClock.now
            if now - lastDataAt > idle || now - start > timeout {
                throw CLIError.timeout(String(lastLine.suffix(80)))
            }
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    // MARK: Text helpers (static so they can be unit-tested)

    static let userAtHost = #"[A-Za-z0-9_.\-]+@[A-Za-z0-9_.\-]+"#

    public static func promptKind(_ line: String) -> PromptKind? {
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.hasSuffix("login:") { return .login }
        if l.hasSuffix("Password:") || l.hasSuffix("password:") { return .password }
        if l.hasPrefix("---(more") { return .pager }
        if l.range(of: #"\[yes,no\]( \((yes|no)\))?\s*$"#, options: .regularExpression) != nil { return .question }
        if l.range(of: "^" + userAtHost + #":[A-Za-z0-9]+:[0-9]+%$"#, options: .regularExpression) != nil { return .shell }
        if l.range(of: "^" + userAtHost + "%$", options: .regularExpression) != nil { return .shell }
        if l.range(of: "^" + userAtHost + ">$", options: .regularExpression) != nil { return .operational }
        if l.range(of: "^" + userAtHost + "#$", options: .regularExpression) != nil { return .configuration }
        return nil
    }

    static func endsWithCommandPrompt(_ text: String) -> Bool {
        let t = text.hasSuffix("\n") ? String(text.dropLast()) : text
        guard let last = t.components(separatedBy: "\n").last else { return false }
        switch promptKind(last) {
        case .operational, .configuration, .shell, .question: return true
        default: return false
        }
    }

    /// Removes \r, ANSI escape sequences, backspace pairs and NULs.
    public static func clean(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\r", with: "")
        out = out.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\u{1B}[()][A-Za-z0-9]", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\u{1B}[\\x40-\\x5F]", with: "", options: .regularExpression)  // ESC H (tab set) etc.
        out = out.replacingOccurrences(of: "\u{0}", with: "")
        while let r = out.range(of: ".\u{8}", options: .regularExpression) { out.removeSubrange(r) }
        return out.replacingOccurrences(of: "\u{8}", with: "")
    }

    public static func stripEchoAndPrompt(_ raw: String) -> String {
        var lines = clean(raw).components(separatedBy: "\n")
        if !lines.isEmpty { lines.removeFirst() }  // echoed command
        while let last = lines.last {
            let t = last.trimmingCharacters(in: .whitespaces)
            let isNoise = t.isEmpty
                || promptKind(t) != nil
                || t.range(of: #"^\{[^}]*\}(\[edit[^\]]*\])?$"#, options: .regularExpression) != nil
                || t.range(of: #"^\[edit[^\]]*\]$"#, options: .regularExpression) != nil
            if isNoise { lines.removeLast() } else { break }
        }
        return lines.joined(separator: "\n")
    }
}
