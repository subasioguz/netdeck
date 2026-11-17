import Foundation

/// Interactive SSH session through the system `/usr/bin/ssh` with a forced TTY.
/// Password auth goes through a one-shot SSH_ASKPASS helper that reads the password
/// from the child's environment, so it never appears on a command line.
public final class SSHTransport: Transport, @unchecked Sendable {
    public let host: String
    public let port: Int
    public let username: String
    private let password: String?
    private let lock = NSLock()
    private var process: Process?
    private var stdinPipe: Pipe?

    public init(host: String, port: Int = 22, username: String, password: String?) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    public var displayName: String { "\(username)@\(host)" + (port == 22 ? "" : ":\(port)") }

    public func open(
        onData: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (String?) -> Void
    ) throws {
        lock.lock(); defer { lock.unlock() }
        guard process == nil else { return }

        let support = try AppPaths.supportDirectory()
        let knownHosts = support.appendingPathComponent("known_hosts").path
        var args = [
            "-tt",
            "-p", String(port),
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHosts)",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=15",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "LogLevel=ERROR",
        ]
        var env = ProcessInfo.processInfo.environment
        if let password, !password.isEmpty {
            let helper = try Self.askpassHelper(in: support)
            env["SSH_ASKPASS"] = helper.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
            env["NETDECK_SSH_PASSWORD"] = password
            args += ["-o", "PreferredAuthentications=keyboard-interactive,password,publickey"]
        } else {
            args += ["-o", "BatchMode=yes"]
        }
        args.append("\(username)@\(host)")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = outPipe
        // The last bytes ssh printed, so a failed session can say why (refused, host key changed...).
        let tail = OutputTail()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { tail.append(d); onData(d) }
        }
        p.terminationHandler = { proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            let rest = outPipe.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty { tail.append(rest); onData(rest) }
            let code = proc.terminationStatus
            guard code != 0 else { onClose(nil); return }
            let reason = t("The SSH session ended (exit code %@).", String(code))
            onClose(tail.lastLine.map { reason + "\n" + $0 } ?? reason)
        }
        do { try p.run() } catch { throw TransportError.openFailed(error.localizedDescription) }
        process = p
        stdinPipe = inPipe
    }

    public func send(_ data: Data) throws {
        lock.lock(); let pipe = stdinPipe; lock.unlock()
        guard let pipe else { throw TransportError.notOpen }
        do { try pipe.fileHandleForWriting.write(contentsOf: data) } catch {
            throw TransportError.writeFailed(error.localizedDescription)
        }
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        try? stdinPipe?.fileHandleForWriting.close()
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        stdinPipe = nil
    }

    private static func askpassHelper(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("askpass.sh")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$NETDECK_SSH_PASSWORD\"\n"
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try script.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

/// Keeps the last few hundred bytes of a stream (thread-safe).
private final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(d)
        if data.count > 512 { data = data.suffix(512) }
    }

    /// The last non-empty line, without escape sequences.
    var lastLine: String? {
        lock.lock(); defer { lock.unlock() }
        let text = JunosCLI.clean(String(decoding: data, as: UTF8.self))
        return text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }
}
