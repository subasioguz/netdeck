import Foundation

/// Kinds of prompt a text CLI shows. `user` is a limited mode that needs `enable` (IOS `Switch>`).
public enum CLIPrompt: Equatable, Sendable {
    case login, password, shell, user, operational, configuration, pager, question
}

/// What differs between platforms' text CLIs: prompts, login name, terminal setup, how to leave.
public protocol CLIDialect: Sendable {
    /// The kind of prompt `line` is (the last line of output), nil when it isn't one.
    func prompt(_ line: String) -> CLIPrompt?
    /// The login name to send. RouterOS adds terminal options to it ("admin+ct").
    func loginName(_ username: String) -> String
    /// Commands run once logged in, at the operational prompt (paging off, wide terminal).
    var setupCommands: [String] { get }
    /// What to send at `prompt` during login to get to the operational prompt (nil: nothing).
    func advance(from prompt: CLIPrompt) -> String?
    /// What to send at `prompt` to log out (nil: already out).
    func logout(from prompt: CLIPrompt?) -> String?
    /// Key that shows the next page when output stops at a pager prompt.
    var pagerKey: String { get }
    /// Line ending sent after commands.
    var lineEnding: String { get }
    /// Lines at the end of command output that belong to the prompt area (removed from output).
    func isTrailingNoise(_ line: String) -> Bool
    /// Output lines that mean the device rejected a command.
    func errors(in output: String) -> [String]
    /// Text that means the login was refused.
    func isLoginFailure(_ text: String) -> Bool
    /// A line the device prints on its own at any time, such as an IOS console log message
    /// (`*Nov 17 10:01:02.123: %LINK-3-UPDOWN: ...`). It may follow the prompt, so it must not hide it.
    func isAsyncMessage(_ line: String) -> Bool
}

extension CLIDialect {
    public func loginName(_ username: String) -> String { username }
    public var pagerKey: String { " " }
    public var lineEnding: String { "\r" }
    public func isTrailingNoise(_ line: String) -> Bool { false }
    public func isAsyncMessage(_ line: String) -> Bool { false }
    public func isLoginFailure(_ text: String) -> Bool {
        let failures = ["Login incorrect", "Permission denied", "% Login invalid", "% Authentication failed",
                        "Login failed", "incorrect password", "Access denied"]
        return failures.contains { text.contains($0) }
    }
}

/// Text-mode CLI session over any byte transport, for every platform except Junos (which keeps its
/// field-tested `JunosCLI`). Handles login (console or SSH), `enable`, paging and command framing; the
/// platform differences come from a `CLIDialect`.
public actor CLISession {
    public let dialect: any CLIDialect
    private let transport: Transport
    private var raw = Data()
    private var buffer: String { JunosCLI.clean(String(decoding: raw, as: UTF8.self)) }
    private var lastDataAt = ContinuousClock.now
    private var closedReason: String?
    private var readerTask: Task<Void, Never>?
    private var isOpen = false
    /// Login ended in a limited mode because `enable` was refused (IOS `>`).
    public private(set) var isLimited = false

    public init(transport: Transport, dialect: any CLIDialect) {
        self.transport = transport
        self.dialect = dialect
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

    /// Logs in if needed, enters privileged mode when the platform has one, and leaves the session at
    /// the operational prompt with paging off. A refused `enable` leaves it in user mode (`isLimited`).
    public func login(username: String, password: String?) async throws {
        try open()
        let le = dialect.lineEnding
        var sentUser = false, sentPassword = false, sentEnable = false, sentEnablePassword = false
        try send(le)
        _ = try? await waitUntil(idle: .seconds(2), timeout: .seconds(4)) { _ in false }

        for _ in 0..<20 {
            let kind = dialect.prompt(lastLine)
            switch kind {
            case .operational:
                isLimited = false
                try await setup()
                return
            case .user:
                if sentEnable {
                    isLimited = true
                    try await setup()
                    return
                }
                raw = Data()
                try send("enable" + le)
                sentEnable = true
                _ = try? await waitForPrompt(timeout: .seconds(10))
            case .login:
                if sentUser && sentPassword { throw CLIError.authenticationFailed }
                raw = Data()
                try send(dialect.loginName(username) + le)
                sentUser = true
                sentPassword = false
                _ = try await waitForPrompt(timeout: .seconds(10))
            case .password:
                raw = Data()
                if sentEnable {
                    // The enable secret: try the login password once, then give up on enable.
                    try send((sentEnablePassword ? "" : (password ?? "")) + le)
                    sentEnablePassword = true
                    _ = try? await waitForPrompt(timeout: .seconds(10))
                } else {
                    if sentPassword { throw CLIError.authenticationFailed }
                    try send((password ?? "") + le)
                    sentPassword = true
                    _ = try await waitForPrompt(timeout: .seconds(20))
                }
            case .shell, .configuration, .pager, .question:
                guard let step = kind.flatMap(dialect.advance(from:)) else { throw CLIError.unrecognizedPrompt(String(buffer.suffix(4000))) }
                raw = Data()
                try send(step)
                _ = try? await waitForPrompt(timeout: .seconds(10))
            case nil:
                if dialect.isLoginFailure(buffer) && !sentEnable { throw CLIError.authenticationFailed }
                try send(le)
                _ = try? await waitForPrompt(timeout: .seconds(4))
            }
        }
        throw CLIError.unrecognizedPrompt(String(buffer.suffix(4000)))
    }

    /// Leaves the session logged out (important for a shared physical console), then closes.
    public func logout() async {
        for _ in 0..<3 {
            let line = lastLine
            let kind = dialect.prompt(line)
            if kind == .login || closedReason != nil || DeviceDetector.isLoginPrompt(line) { break }
            guard let step = dialect.logout(from: kind) else { break }
            raw = Data()
            try? send(step)
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

    /// Runs one command and returns its output without the echoed command and the trailing prompt.
    /// Pager prompts are answered on the way. `idle` is how long we wait without any new byte.
    public func run(_ command: String, idle: Duration = .seconds(20), timeout: Duration = .seconds(240)) async throws -> String {
        try ensureOpen()
        raw = Data()
        try send(command + dialect.lineEnding)
        let start = ContinuousClock.now
        lastDataAt = start
        var pagedAt = -1
        while true {
            let text = buffer
            let last = Self.lastPromptCandidate(of: text, dialect: dialect)
            switch dialect.prompt(last) {
            case .operational, .configuration, .user, .question, .shell:
                return stripEchoAndPrompt(text)
            case .pager:
                // Answer each pager prompt once (the buffer keeps growing past it).
                if text.count != pagedAt {
                    pagedAt = text.count
                    try send(dialect.pagerKey)
                }
            default: break
            }
            if let closedReason { throw CLIError.closed(closedReason) }
            let now = ContinuousClock.now
            if now - lastDataAt > idle || now - start > timeout { throw CLIError.timeout(String(last.suffix(80))) }
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    /// Sends raw bytes without waiting (control characters such as RouterOS Ctrl-X).
    public func sendRaw(_ s: String) throws { try send(s) }

    public var currentPrompt: CLIPrompt? { dialect.prompt(lastLine) }

    // MARK: Internals

    private func setup() async throws {
        for c in dialect.setupCommands { _ = try await run(c, idle: .seconds(10)) }
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

    private var lastLine: String { Self.lastLine(of: buffer) }

    /// The last line, looking past empty lines and log messages printed after the prompt.
    static func lastPromptCandidate(of text: String, dialect: any CLIDialect) -> String {
        var lines = text.components(separatedBy: "\n")
        while lines.count > 1, let l = lines.last,
              l.trimmingCharacters(in: .whitespaces).isEmpty || dialect.isAsyncMessage(l.trimmingCharacters(in: .whitespaces)) {
            lines.removeLast()
        }
        return lines.last ?? ""
    }

    static func lastLine(of text: String) -> String {
        let trimmed = text.hasSuffix("\n") ? String(text.dropLast()) : text
        return trimmed.components(separatedBy: "\n").last ?? ""
    }

    private func waitForPrompt(timeout: Duration) async throws -> String {
        try await waitUntil(idle: timeout, timeout: timeout) { [dialect] text in
            dialect.prompt(Self.lastLine(of: text)) != nil
        }
    }

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

    /// Removes the echoed command (first line), pager remnants and the trailing prompt lines.
    public nonisolated func stripEchoAndPrompt(_ text: String) -> String {
        Self.strip(text, dialect: dialect)
    }

    public static func strip(_ text: String, dialect: any CLIDialect) -> String {
        var lines = JunosCLI.clean(text).components(separatedBy: "\n")
        if !lines.isEmpty { lines.removeFirst() }
        lines = lines.filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return dialect.prompt(t) != .pager && !dialect.isAsyncMessage(t)
        }
        while let last = lines.last {
            let t = last.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || dialect.prompt(t) != nil || dialect.isTrailingNoise(t) { lines.removeLast() } else { break }
        }
        return lines.joined(separator: "\n")
    }
}
