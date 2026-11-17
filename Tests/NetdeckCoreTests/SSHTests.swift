import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing
@testable import NetdeckCore

private func tempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("netdeck-ssh-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct SSHKnownHostsTests {
    @Test func fingerprintMatchesSSHKeygen() throws {
        // A throwaway key; `ssh-keygen -lf` prints SHA256:ygVNRyC7Bg5kKSRW1HVxGMRQfekh0nBoRcTLtxDj+7A for it.
        let entry = try #require(SSHKnownHosts.entry(openSSHKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOq59nu+XXkICGKWrSDdsd8SoFxAIm0DDVMK69q51g43"))
        #expect(entry == .init(type: "ssh-ed25519", fingerprint: "SHA256:ygVNRyC7Bg5kKSRW1HVxGMRQfekh0nBoRcTLtxDj+7A"))
        #expect(SSHKnownHosts.entry(openSSHKey: "not a key!") == nil)
    }

    @Test func firstUseMatchMismatchForget() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let one = SSHKnownHosts.Entry(type: "ssh-ed25519", fingerprint: "SHA256:one")
        let two = SSHKnownHosts.Entry(type: "ecdsa-sha2-nistp256", fingerprint: "SHA256:two")

        #expect(SSHKnownHosts.stored(host: "192.0.2.10", port: 22, directory: dir) == nil)
        #expect(try SSHKnownHosts.check(one, host: "192.0.2.10", port: 22, directory: dir) == .firstUse)
        #expect(try SSHKnownHosts.check(one, host: "192.0.2.10", port: 22, directory: dir) == .matched)
        #expect(SSHKnownHosts.stored(host: "192.0.2.10", port: 22, directory: dir) == one)
        // Another port is another host.
        #expect(try SSHKnownHosts.check(two, host: "192.0.2.10", port: 2222, directory: dir) == .firstUse)

        let error = #expect(throws: SSHKnownHosts.Mismatch.self) {
            try SSHKnownHosts.check(two, host: "192.0.2.10", port: 22, directory: dir)
        }
        let message = try #require(error?.errorDescription)
        #expect(message.hasPrefix("Host key verification failed"))
        #expect(message.contains("SHA256:two") && message.contains("SHA256:one"))
        // The stored key is not replaced by a mismatch.
        #expect(SSHKnownHosts.stored(host: "192.0.2.10", port: 22, directory: dir) == one)

        SSHKnownHosts.forget(host: "192.0.2.10", port: 22, directory: dir)
        #expect(SSHKnownHosts.stored(host: "192.0.2.10", port: 22, directory: dir) == nil)
        #expect(SSHKnownHosts.stored(host: "192.0.2.10", port: 2222, directory: dir) == two)
        #expect(try SSHKnownHosts.check(two, host: "192.0.2.10", port: 22, directory: dir) == .firstUse)
    }

    @Test func systemSSHKnownHostsForget() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("known_hosts")
        try "192.0.2.10 ssh-ed25519 AAAA1\n[192.0.2.10]:2222 ssh-ed25519 AAAA2\n192.0.2.11 ssh-ed25519 AAAA3\n"
            .write(to: file, atomically: true, encoding: .utf8)
        SSHTransport.forgetHostKey(host: "192.0.2.10", port: 22, directory: dir)
        #expect(try String(contentsOf: file, encoding: .utf8)
            == "[192.0.2.10]:2222 ssh-ed25519 AAAA2\n192.0.2.11 ssh-ed25519 AAAA3\n")
    }

    @Test func failureMessagesClassifyLikeOpenSSH() {
        L10n.language = .en
        let ssh = DeviceProfile.Connection.ssh(host: "192.0.2.10", port: 22)
        let mismatch = SSHKnownHosts.Mismatch(host: "192.0.2.10", port: 22, stored: .init(type: "ssh-ed25519", fingerprint: "SHA256:a"),
                                              offered: .init(type: "ssh-ed25519", fingerprint: "SHA256:b"))
        let changed = ConnectionFailure.classify(CLIError.closed(mismatch.errorDescription!), connection: ssh, reading: false, elapsed: 1)
        #expect(changed == .hostKeyChanged(detail: mismatch.errorDescription!))
        #expect(ConnectionFailure.classify(CLIError.closed("Permission denied (password)."), connection: ssh, reading: false, elapsed: 1) == .wrongPassword)
        let refused = NIOSSHTransport.connectFailure(IOError(errnoCode: ECONNREFUSED, reason: "connect"), host: "192.0.2.10", port: 22)
        #expect(refused == "ssh: connect to host 192.0.2.10 port 22: Connection refused")
        #expect(ConnectionFailure.classify(CLIError.closed(refused), connection: ssh, reading: false, elapsed: 1) == .sshUnreachable(detail: refused))
        let timeout = NIOSSHTransport.connectFailure(ChannelError.connectTimeout(.seconds(8)), host: "192.0.2.10", port: 22)
        #expect(timeout.hasSuffix("Operation timed out"))
        #expect(ConnectionFailure.classify(CLIError.closed("ssh: closed"), connection: ssh, reading: true, elapsed: 1) == .droppedWhileReading(detail: "ssh: closed"))
    }

    @Test func transportSelection() {
        let profile = DeviceProfile(name: "sw",
                                    connection: .ssh(host: "192.0.2.10", port: 22), username: "admin")
        #expect(profile.makeTransport(password: "x", systemSSH: false) is NIOSSHTransport)
        #expect(profile.makeTransport(password: "x", systemSSH: true) is SSHTransport)
        #expect((profile.makeTransport(password: "x", username: "admin+ct", systemSSH: false) as? NIOSSHTransport)?.username == "admin+ct")
    }

    @Test func usbAdapterFilter() {
        let paths = ["/dev/cu.Bluetooth-Incoming-Port", "/dev/cu.usbserial-A1", "/dev/cu.wchusbserial110",
                     "/dev/cu.SLAB_USBtoUART", "/dev/cu.usbmodem14201", "/dev/cu.debug-console"]
        #expect(SerialTransport.usbAdapters(in: paths)
            == ["/dev/cu.SLAB_USBtoUART", "/dev/cu.usbmodem14201", "/dev/cu.usbserial-A1", "/dev/cu.wchusbserial110"])
    }
}

// MARK: - Against an in-process SSH server on 127.0.0.1

/// Collects what a transport delivers (thread-safe).
private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var reasons: [String?] = []

    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    var closes: [String?] { lock.lock(); defer { lock.unlock() }; return reasons }
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    func close(_ r: String?) { lock.lock(); reasons.append(r); lock.unlock() }

    func wait(_ condition: @escaping (Sink) -> Bool) async throws {
        for _ in 0..<200 where !condition(self) { try await Task.sleep(for: .milliseconds(25)) }
    }
}

private final class ServerAuth: NIOSSHServerUserAuthenticationDelegate {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case let .password(p) = request.request, request.username == "admin", p.password == "secret" {
            responsePromise.succeed(.success)
        } else {
            responsePromise.succeed(.failure)
        }
    }
}

/// Accepts the PTY and the shell, prints a prompt, echoes input and ends with exit status 0 on "exit".
private final class EchoShell: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let pty as SSHChannelRequestEvent.PseudoTerminalRequest:
            if pty.term == "vt100" && pty.terminalCharacterWidth == 511 {
                context.channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            } else {
                context.channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
            }
        case is SSHChannelRequestEvent.ShellRequest:
            context.channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            write("switch> ", context)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case let .byteBuffer(buffer) = unwrapInboundIn(data).data else { return }
        let text = String(buffer: buffer)
        if text == "exit\r" {
            context.channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0), promise: nil)
            context.close(promise: nil)
        } else {
            write("echo:" + text, context)
        }
    }

    private func write(_ s: String, _ context: ChannelHandlerContext) {
        let buffer = context.channel.allocator.buffer(string: s)
        context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
    }
}

private func startServer() async throws -> Channel {
    let key = Curve25519.Signing.PrivateKey()
    return try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                let config = SSHServerConfiguration(hostKeys: [NIOSSHPrivateKey(ed25519Key: key)], userAuthDelegate: ServerAuth())
                let ssh = NIOSSHHandler(role: .server(config), allocator: channel.allocator) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                        try child.pipeline.syncOperations.addHandler(EchoShell())
                    }
                }
                try channel.pipeline.syncOperations.addHandler(ssh)
            }
        }
        .bind(host: "127.0.0.1", port: 0).get()
}

@Suite(.serialized) struct NIOSSHTransportTests {
    @Test func shellSessionEchoesInOrderAndPinsTheKey() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try await startServer()
        defer { server.close(promise: nil) }
        let port = try #require(server.localAddress?.port)

        let sink = Sink()
        let transport = NIOSSHTransport(host: "127.0.0.1", port: port, username: "admin", password: "secret", knownHostsDirectory: dir)
        try transport.open(onData: sink.append, onClose: sink.close)
        // Sent before the shell is up: queued and delivered in order.
        try transport.send(Data("one\r".utf8))
        try transport.send(Data("two\r".utf8))
        try await sink.wait { $0.text.contains("echo:two") }
        #expect(sink.text == "switch> echo:one\recho:two\r")
        let pinned = try #require(SSHKnownHosts.stored(host: "127.0.0.1", port: port, directory: dir))
        #expect(pinned.type == "ssh-ed25519" && pinned.fingerprint.hasPrefix("SHA256:"))

        try transport.send(Data("exit\r".utf8))
        try await sink.wait { !$0.closes.isEmpty }
        #expect(sink.closes == [nil])
        #expect(throws: TransportError.notOpen) { try transport.send(Data("x".utf8)) }
    }

    @Test func wrongPasswordIsPermissionDenied() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try await startServer()
        defer { server.close(promise: nil) }
        let port = try #require(server.localAddress?.port)

        let sink = Sink()
        let transport = NIOSSHTransport(host: "127.0.0.1", port: port, username: "admin", password: "wrong", knownHostsDirectory: dir)
        try transport.open(onData: sink.append, onClose: sink.close)
        try await sink.wait { !$0.closes.isEmpty }
        let reason = try #require(sink.closes.first ?? nil)
        #expect(reason.contains("Permission denied"))
        let failure = ConnectionFailure.classify(CLIError.closed(reason), connection: .ssh(host: "127.0.0.1", port: port), reading: false, elapsed: 1)
        #expect(failure == .wrongPassword)
    }

    @Test func changedHostKeyIsRefusedUntilForgotten() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try await startServer()
        defer { server.close(promise: nil) }
        let port = try #require(server.localAddress?.port)
        try SSHKnownHosts.check(.init(type: "ssh-ed25519", fingerprint: "SHA256:old"), host: "127.0.0.1", port: port, directory: dir)

        let sink = Sink()
        let transport = NIOSSHTransport(host: "127.0.0.1", port: port, username: "admin", password: "secret", knownHostsDirectory: dir)
        try transport.open(onData: sink.append, onClose: sink.close)
        try await sink.wait { !$0.closes.isEmpty }
        let reason = try #require(sink.closes.first ?? nil)
        let failure = ConnectionFailure.classify(CLIError.closed(reason), connection: .ssh(host: "127.0.0.1", port: port), reading: false, elapsed: 1)
        #expect(failure == .hostKeyChanged(detail: reason))
        #expect(sink.text.isEmpty)

        SSHKnownHosts.forget(host: "127.0.0.1", port: port, directory: dir)
        let again = Sink()
        let second = NIOSSHTransport(host: "127.0.0.1", port: port, username: "admin", password: "secret", knownHostsDirectory: dir)
        try second.open(onData: again.append, onClose: again.close)
        try await again.wait { $0.text.contains("switch> ") }
        #expect(again.text == "switch> ")
        second.close()
    }

    @Test func refusedPortReportsUnreachable() async throws {
        // Bind and close a listener to get a local port nobody listens on.
        let probe = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
        let port = try #require(probe.localAddress?.port)
        try await probe.close()

        let sink = Sink()
        let transport = NIOSSHTransport(host: "127.0.0.1", port: port, username: "admin", password: "secret", knownHostsDirectory: try tempDirectory())
        try transport.open(onData: sink.append, onClose: sink.close)
        try await sink.wait { !$0.closes.isEmpty }
        let reason = try #require(sink.closes.first ?? nil)
        #expect(reason.contains("Connection refused"))
        let failure = ConnectionFailure.classify(CLIError.closed(reason), connection: .ssh(host: "127.0.0.1", port: port), reading: false, elapsed: 1)
        #expect(failure == .sshUnreachable(detail: reason))
    }
}
