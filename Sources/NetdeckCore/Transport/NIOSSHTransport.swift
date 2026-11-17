import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Interactive SSH session with the embedded client (SwiftNIO SSH), so it works inside the App Sandbox.
///
/// Password authentication only: NIOSSH has no keyboard-interactive method. Host keys are trusted on first
/// use and pinned per "host:port" in `SSHKnownHosts`. `open` returns at once; connecting, authenticating and
/// starting the shell happen in the background. Data sent before the shell is up is queued, and every
/// failure arrives through `onClose` with a message in OpenSSH's words ("Permission denied",
/// "Host key verification failed"...) so `ConnectionFailure.classify` treats both SSH clients alike.
public final class NIOSSHTransport: Transport, @unchecked Sendable {
    public let host: String
    public let port: Int
    public let username: String
    private let password: String?
    /// Replaces the support directory for the known hosts file (tests).
    private let knownHostsDirectory: URL?
    private let connectTimeout: TimeAmount
    private let handshakeTimeout: TimeAmount

    private let lock = NSLock()
    private var connection: Channel?
    private var shell: Channel?
    private var pending: [Data] = []
    private var state: State = .idle
    /// The first error seen on the connection; it becomes the `onClose` reason.
    private var failure: String?
    private var onClose: (@Sendable (String?) -> Void)?

    private enum State { case idle, connecting, ready, closed }

    public init(host: String, port: Int = 22, username: String, password: String?,
                knownHostsDirectory: URL? = nil, connectTimeout: TimeAmount = .seconds(8),
                handshakeTimeout: TimeAmount = .seconds(20)) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.knownHostsDirectory = knownHostsDirectory
        self.connectTimeout = connectTimeout
        self.handshakeTimeout = handshakeTimeout
    }

    public var displayName: String { "\(username)@\(host)" + (port == 22 ? "" : ":\(port)") }

    public func open(
        onData: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (String?) -> Void
    ) throws {
        lock.lock()
        guard state == .idle else { lock.unlock(); return }
        state = .connecting
        self.onClose = onClose
        lock.unlock()

        let user = username, pass = password ?? "", host = host, port = port, dir = knownHostsDirectory
        let fail: @Sendable (String) -> Void = { [weak self] in self?.record($0) }
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(connectTimeout)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let config = SSHClientConfiguration(
                        userAuthDelegate: PasswordAuthDelegate(username: user, password: pass, onReject: fail),
                        serverAuthDelegate: HostKeyDelegate(host: host, port: port, directory: dir, onReject: fail))
                    let ssh = NIOSSHHandler(role: .client(config), allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandlers([ssh, ErrorRecorder(onError: fail)])
                }
            }

        bootstrap.connect(host: host, port: port).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                self.finish(reason: Self.connectFailure(error, host: host, port: port))
            case let .success(channel):
                self.attach(channel, onData: onData)
            }
        }
    }

    public func send(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .idle, .closed: throw TransportError.notOpen
        case .connecting: pending.append(data)
        case .ready: shell.map { Self.write(data, to: $0) }
        }
    }

    public func close() {
        lock.lock()
        guard state != .closed else { lock.unlock(); return }
        state = .closed
        let channel = connection
        connection = nil
        shell = nil
        pending = []
        onClose = nil // closed on purpose: nothing to report
        lock.unlock()
        channel?.close(promise: nil)
    }

    // MARK: Connection steps

    private func attach(_ channel: Channel, onData: @escaping @Sendable (Data) -> Void) {
        lock.lock()
        guard state == .connecting else { lock.unlock(); channel.close(promise: nil); return }
        connection = channel
        lock.unlock()

        channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); let reason = self.failure; self.lock.unlock()
            self.finish(reason: reason ?? t("The SSH connection was closed by the device."))
        }
        // Login and shell must be done in time, or the device is not answering SSH properly.
        channel.eventLoop.scheduleTask(in: handshakeTimeout) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let waiting = self.state == .connecting; self.lock.unlock()
            if waiting {
                self.record(t("Connection timed out during the SSH handshake with %@.", SSHKnownHosts.key(host: self.host, port: self.port)))
                channel.close(promise: nil)
            }
        }

        let ready: @Sendable (Channel) -> Void = { [weak self] in self?.shellReady($0) }
        let exited: @Sendable (Int) -> Void = { [weak self] code in
            if code != 0 { self?.record(t("The SSH session ended (exit code %@).", String(code))) }
        }
        let rejected: @Sendable (String) -> Void = { [weak self] in self?.record($0) }
        channel.eventLoop.execute {
            do {
                let ssh = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                let promise = channel.eventLoop.makePromise(of: Channel.self)
                promise.futureResult.whenFailure { error in
                    rejected(t("The device refused the SSH shell: %@", String(describing: error)))
                    channel.close(promise: nil)
                }
                ssh.createChannel(promise, channelType: .session) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                        try child.pipeline.syncOperations.addHandler(
                            ShellHandler(onData: onData, onReady: ready, onExit: exited, onReject: rejected))
                    }
                }
            } catch {
                rejected(String(describing: error))
                channel.close(promise: nil)
            }
        }
    }

    private func shellReady(_ child: Channel) {
        lock.lock(); defer { lock.unlock() }
        guard state == .connecting else { return }
        state = .ready
        shell = child
        // Same order as `send` was called; later sends queue behind these on the event loop.
        for data in pending { Self.write(data, to: child) }
        pending = []
        // When the shell ends, take the connection down so `onClose` fires.
        let connection = connection
        child.closeFuture.whenComplete { _ in connection?.close(promise: nil) }
    }

    private func record(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        if failure == nil { failure = message }
    }

    /// Reports the end of the stream once. `reason` is dropped after a clean shell exit.
    private func finish(reason: String) {
        lock.lock()
        let callback = onClose
        let wasReady = state == .ready
        let clean = wasReady && failure == nil
        onClose = nil
        state = .closed
        connection = nil
        shell = nil
        pending = []
        lock.unlock()
        callback?(clean ? nil : reason)
    }

    private static func write(_ data: Data, to channel: Channel) {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
    }

    /// OpenSSH-style wording for a failed TCP connect ("ssh: connect to host ... port 22: Connection refused").
    static func connectFailure(_ error: Error, host: String, port: Int) -> String {
        let detail: String
        if let channelError = error as? ChannelError, case .connectTimeout = channelError {
            detail = "Operation timed out"
        } else if let io = error as? IOError {
            detail = String(cString: strerror(io.errnoCode))
        } else if let e = error as? NIOConnectionError {
            if let dns = e.dnsAAAAError ?? e.dnsAError { detail = "Could not resolve hostname (\(dns))" }
            else if let first = e.connectionErrors.first?.error { return connectFailure(first, host: host, port: port) }
            else { detail = "Could not resolve hostname" }
        } else {
            detail = String(describing: error)
        }
        return "ssh: connect to host \(host) port \(port): \(detail)"
    }
}

// MARK: - Pipeline pieces

/// Offers the password once; a second request means the server rejected it.
private final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private var password: String?
    private let onReject: @Sendable (String) -> Void

    init(username: String, password: String, onReject: @escaping @Sendable (String) -> Void) {
        self.username = username
        self.password = password
        self.onReject = onReject
    }

    private func refuse(_ message: String, _ promise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        onReject(message)
        promise.fail(SSHAuthError(message: message))
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard availableMethods.contains(.password) else {
            refuse("Permission denied (the device doesn't accept password authentication).", nextChallengePromise)
            return
        }
        guard let pass = password else {
            refuse("Permission denied (password).", nextChallengePromise)
            return
        }
        password = nil
        nextChallengePromise.succeed(.init(username: username, serviceName: "", offer: .password(.init(password: pass))))
    }
}

private struct SSHAuthError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Trust on first use against `SSHKnownHosts`.
private final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    let host: String
    let port: Int
    let directory: URL?
    let onReject: @Sendable (String) -> Void

    init(host: String, port: Int, directory: URL?, onReject: @escaping @Sendable (String) -> Void) {
        self.host = host
        self.port = port
        self.directory = directory
        self.onReject = onReject
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        guard let offered = SSHKnownHosts.entry(openSSHKey: String(openSSHPublicKey: hostKey)) else {
            let message = "Host key verification failed: unreadable key."
            onReject(message)
            validationCompletePromise.fail(SSHAuthError(message: message))
            return
        }
        do {
            try SSHKnownHosts.check(offered, host: host, port: port, directory: directory)
            validationCompletePromise.succeed(())
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            onReject(message)
            validationCompletePromise.fail(error)
        }
    }
}

/// Records the first error on the connection and closes it.
private final class ErrorRecorder: ChannelInboundHandler {
    typealias InboundIn = Any
    let onError: @Sendable (String) -> Void

    init(onError: @escaping @Sendable (String) -> Void) { self.onError = onError }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(Self.describe(error))
        context.close(promise: nil)
    }

    static func describe(_ error: Error) -> String {
        if let auth = error as? SSHAuthError { return auth.message }
        if let mismatch = error as? SSHKnownHosts.Mismatch { return mismatch.errorDescription ?? "Host key verification failed." }
        if let ssh = error as? NIOSSHError {
            switch ssh.type {
            case .keyExchangeNegotiationFailure, .unsupportedVersion:
                return t("The device's SSH algorithms aren't supported by the built-in SSH client: %@", String(describing: ssh))
            default:
                return "ssh: " + String(describing: ssh)
            }
        }
        if let io = error as? IOError { return "ssh: " + String(cString: strerror(io.errnoCode)) }
        return "ssh: " + String(describing: error)
    }
}

/// The session channel: asks for a PTY and a shell, then passes the output on.
private final class ShellHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let onData: @Sendable (Data) -> Void
    private let onReady: @Sendable (Channel) -> Void
    private let onExit: @Sendable (Int) -> Void
    private let onReject: @Sendable (String) -> Void
    /// Replies still expected, in request order: PTY, then shell.
    private var awaiting: [String] = []

    init(onData: @escaping @Sendable (Data) -> Void, onReady: @escaping @Sendable (Channel) -> Void,
         onExit: @escaping @Sendable (Int) -> Void, onReject: @escaping @Sendable (String) -> Void) {
        self.onData = onData
        self.onReady = onReady
        self.onExit = onExit
        self.onReject = onReject
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { requestShell(context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        requestShell(context)
        context.fireChannelActive()
    }

    private func requestShell(_ context: ChannelHandlerContext) {
        guard awaiting.isEmpty else { return }
        awaiting = ["pty", "shell"]
        // Wide and tall, so the device neither wraps long lines nor pages output.
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "vt100", terminalCharacterWidth: 511, terminalRowHeight: 200,
            terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:]))
        context.triggerUserOutboundEvent(pty, promise: nil)
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case let .byteBuffer(buffer) = message.data, buffer.readableBytes > 0 else { return }
        onData(Data(buffer.readableBytesView))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            guard !awaiting.isEmpty else { return }
            if awaiting.removeFirst() == "shell" { onReady(context.channel) }
        case is ChannelFailureEvent:
            guard !awaiting.isEmpty else { return }
            // A refused PTY still leaves a usable shell; a refused shell does not.
            if awaiting.removeFirst() == "shell" {
                onReject(t("The device refused to start an SSH shell."))
                context.close(promise: nil)
            }
        case let status as SSHChannelRequestEvent.ExitStatus:
            onExit(status.exitStatus)
        case let event as ChannelEvent where event == .inputClosed:
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onReject(ErrorRecorder.describe(error))
        context.close(promise: nil)
    }
}
