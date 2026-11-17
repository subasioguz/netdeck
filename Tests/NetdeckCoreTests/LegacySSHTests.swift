import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Security
import Testing
@testable import NetdeckCore

// The embedded SSH client against older algorithms (Diffie-Hellman group 1/14/16, ssh-rsa and rsa-sha2-*,
// AES-CTR/CBC, 3DES-CBC, HMAC-SHA1/SHA2), as older network gear such as Catalyst IOS 12.2/15.x offers them.
// Two independent peers: an in-process NIOSSH server (full login and shell, RSA signatures from
// Security.framework) and the system OpenSSH sshd (a real implementation, up to the password check).

private func tempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("netdeck-legacy-ssh-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Collects what a transport delivers (thread-safe).
private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var reasons: [String?] = []

    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    var closes: [String?] { lock.lock(); defer { lock.unlock() }; return reasons }
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    func close(_ r: String?) { lock.lock(); reasons.append(r); lock.unlock() }

    /// Generous: the suite runs at background priority next to other work.
    func wait(seconds: Double = 30, _ condition: @escaping (Sink) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(self), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    }
}

// MARK: - In-process NIOSSH server

private final class PasswordCheck: NIOSSHServerUserAuthenticationDelegate {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case let .password(p) = request.request, request.username == "admin", p.password == "secret" {
            responsePromise.succeed(.success)
        } else {
            responsePromise.succeed(.failure)
        }
    }
}

/// Accepts the PTY and the shell, prints a prompt and echoes each input chunk back.
private final class Echo: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is SSHChannelRequestEvent.PseudoTerminalRequest, is SSHChannelRequestEvent.ShellRequest:
            context.channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            if event is SSHChannelRequestEvent.ShellRequest { write("Switch>", context) }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case let .byteBuffer(buffer) = unwrapInboundIn(data).data else { return }
        write(String(buffer: buffer), context)
    }

    private func write(_ s: String, _ context: ChannelHandlerContext) {
        let buffer = context.channel.allocator.buffer(string: s)
        context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
    }
}

private struct ServerAlgorithms: @unchecked Sendable {
    var keyExchange: [String]
    var hostKey: NIOSSHPrivateKey
    var schemes: [NIOSSHTransportProtection.Type]
}

private func startServer(_ algorithms: ServerAlgorithms) async throws -> Channel {
    try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                var config = SSHServerConfiguration(hostKeys: [algorithms.hostKey], userAuthDelegate: PasswordCheck(),
                                                    globalRequestDelegate: nil, banner: nil,
                                                    transportProtectionSchemes: algorithms.schemes)
                config.keyExchangeAlgorithms = algorithms.keyExchange
                let ssh = NIOSSHHandler(role: .server(config), allocator: channel.allocator) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                        try child.pipeline.syncOperations.addHandler(Echo())
                    }
                }
                try channel.pipeline.syncOperations.addHandler(ssh)
            }
        }
        .bind(host: "127.0.0.1", port: 0).get()
}

private func rsaKey(bits: Int = 2048) throws -> SecKey {
    let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: bits]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { throw error!.takeRetainedValue() }
    return key
}

/// A transport protection scheme the client doesn't know, to provoke a negotiation failure.
private final class UnknownCipher: NIOSSHTransportProtection {
    static let cipherName = "twofish256-cbc"
    static let macName: String? = "hmac-sha1"
    static let cipherBlockSize = 16
    static let keySizes = ExpectedKeySizes(ivSize: 16, encryptionKeySize: 32, macKeySize: 20)
    var macBytes: Int { 20 }
    var lengthEncrypted: Bool { true }
    init(initialKeys: NIOSSHSessionKeys) throws { throw CancellationError() }  // never negotiated
    func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {}
    func decryptFirstBlock(_ source: inout ByteBuffer) throws {}
    func decryptAndVerifyRemainingPacket(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws -> ByteBuffer { source }
    func encryptPacket(_ destination: inout ByteBuffer, sequenceNumber: UInt32) throws {}
}

/// One serialized suite, so the in-process server and sshd don't compete for the CPU.
@Suite(.serialized) struct LegacySSHTests {}

extension LegacySSHTests {
@Suite(.serialized) struct InProcess {
    /// Logs in, echoes a long line (many cipher blocks over several packets) and checks what was negotiated.
    private func roundTrip(_ algorithms: ServerAlgorithms, expect: SSHAlgorithms, payloadBytes: Int = 64) async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try await startServer(algorithms)
        defer { server.close(promise: nil) }
        let port = try #require(server.localAddress?.port)

        let sink = Sink()
        let transport = NIOSSHTransport(host: "127.0.0.1", port: port, username: "admin", password: "secret", knownHostsDirectory: dir)
        try transport.open(onData: sink.append, onClose: sink.close)
        let line = String((0..<payloadBytes).map { _ in "0123456789abcdef".randomElement()! }) + "\r"
        try transport.send(Data(line.utf8))
        try await sink.wait { $0.text.hasSuffix(line) || !$0.closes.isEmpty }
        #expect(sink.closes.isEmpty, "closed: \(String(describing: sink.closes))")
        #expect(sink.text == "Switch>" + line)
        #expect(transport.sshAlgorithms == expect)
        let pinned = try #require(SSHKnownHosts.stored(host: "127.0.0.1", port: port, directory: dir))
        #expect(pinned.type == (expect.hostKey.hasPrefix("rsa-") ? "ssh-rsa" : expect.hostKey))
        transport.close()
    }

    @Test func catalystIOS15Style() async throws {
        // diffie-hellman-group14-sha1, ssh-rsa, aes128-cbc, hmac-sha1: what IOS 15.0 on a 2960 offers.
        let key = try NIOSSHPrivateKey(rsaKey: try rsaKey(), signatureAlgorithm: "ssh-rsa")
        try await roundTrip(
            ServerAlgorithms(keyExchange: ["diffie-hellman-group14-sha1"], hostKey: key,
                             schemes: [NIOSSHCipherMACTransportProtection<AES128CBC, HMACSHA1>.self]),
            expect: SSHAlgorithms(keyExchange: "diffie-hellman-group14-sha1", hostKey: "ssh-rsa", cipher: "aes128-cbc", mac: "hmac-sha1",
                                  legacy: ["diffie-hellman-group14-sha1", "ssh-rsa", "aes128-cbc", "hmac-sha1"]),
            payloadBytes: 40_000)
    }

    @Test func catalystIOS12Style() async throws {
        // diffie-hellman-group1-sha1 and 3des-cbc with a 1024-bit RSA key, as on IOS 12.2.
        let key = try NIOSSHPrivateKey(rsaKey: try rsaKey(bits: 1024), signatureAlgorithm: "ssh-rsa")
        try await roundTrip(
            ServerAlgorithms(keyExchange: ["diffie-hellman-group1-sha1"], hostKey: key,
                             schemes: [NIOSSHCipherMACTransportProtection<TripleDESCBC, HMACSHA1>.self]),
            expect: SSHAlgorithms(keyExchange: "diffie-hellman-group1-sha1", hostKey: "ssh-rsa", cipher: "3des-cbc", mac: "hmac-sha1",
                                  legacy: ["diffie-hellman-group1-sha1", "ssh-rsa", "3des-cbc", "hmac-sha1"]),
            payloadBytes: 5_000)
    }

    @Test func sha2SignaturesAndCTR() async throws {
        let key256 = try NIOSSHPrivateKey(rsaKey: try rsaKey(), signatureAlgorithm: "rsa-sha2-256")
        try await roundTrip(
            ServerAlgorithms(keyExchange: ["diffie-hellman-group14-sha256"], hostKey: key256,
                             schemes: [NIOSSHCipherMACTransportProtection<AES256CTR, HMACSHA256>.self]),
            expect: SSHAlgorithms(keyExchange: "diffie-hellman-group14-sha256", hostKey: "rsa-sha2-256", cipher: "aes256-ctr",
                                  mac: "hmac-sha2-256", legacy: []),
            payloadBytes: 20_000)
        let key512 = try NIOSSHPrivateKey(rsaKey: try rsaKey(), signatureAlgorithm: "rsa-sha2-512")
        try await roundTrip(
            ServerAlgorithms(keyExchange: ["diffie-hellman-group16-sha512"], hostKey: key512,
                             schemes: [NIOSSHCipherMACTransportProtection<AES192CBC, HMACSHA512>.self]),
            expect: SSHAlgorithms(keyExchange: "diffie-hellman-group16-sha512", hostKey: "rsa-sha2-512", cipher: "aes192-cbc",
                                  mac: "hmac-sha2-512", legacy: ["aes192-cbc"]))
    }

    @Test func modernDevicesKeepModernAlgorithms() async throws {
        // A server with everything: the client's preference must win, nothing legacy.
        let all = NIOSSHAlgorithms.clientTransportProtectionSchemes.reversed().map { $0 as NIOSSHTransportProtection.Type }
        try await roundTrip(
            ServerAlgorithms(keyExchange: NIOSSHAlgorithms.keyExchange.reversed(), hostKey: NIOSSHPrivateKey(ed25519Key: .init()),
                             schemes: all),
            expect: SSHAlgorithms(keyExchange: "ecdh-sha2-nistp384", hostKey: "ssh-ed25519", cipher: "aes256-gcm@openssh.com",
                                  mac: nil, legacy: []))
    }

    @Test func unknownCipherSaysWhatTheDeviceOffers() async throws {
        L10n.language = .en
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try await startServer(ServerAlgorithms(keyExchange: NIOSSHAlgorithms.keyExchange,
                                                            hostKey: NIOSSHPrivateKey(ed25519Key: .init()),
                                                            schemes: [UnknownCipher.self]))
        defer { server.close(promise: nil) }
        let port = try #require(server.localAddress?.port)

        let sink = Sink()
        let transport = NIOSSHTransport(host: "127.0.0.1", port: port, username: "admin", password: "secret", knownHostsDirectory: dir)
        try transport.open(onData: sink.append, onClose: sink.close)
        try await sink.wait { !$0.closes.isEmpty }
        let reason = try #require(sink.closes.first ?? nil)
        #expect(reason == "The device's SSH algorithms aren't supported by the built-in SSH client: "
            + "no matching cipher found. Their offer: twofish256-cbc")
        let failure = ConnectionFailure.classify(CLIError.closed(reason), connection: .ssh(host: "127.0.0.1", port: port),
                                                 reading: false, elapsed: 1)
        #expect(failure == .sshUnreachable(detail: reason))
    }

    @Test func legacyOptionsForTheSystemSSH() {
        // Appended after OpenSSH's defaults, and only names this ssh knows.
        let options = SSHTransport.legacyAlgorithmOptions
        #expect(options.count % 2 == 0 && stride(from: 0, to: options.count, by: 2).allSatisfy { options[$0] == "-o" })
        #expect(options.contains("KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1"))
        #expect(options.contains("HostKeyAlgorithms=+ssh-rsa"))
        #expect(options.contains { $0.hasPrefix("Ciphers=+aes256-cbc") })
    }
}

}

// MARK: - Against the system OpenSSH server

/// A throwaway `sshd` on 127.0.0.1 run as the current user, offering only the given algorithms. Without root
/// it can't check passwords, so a login ends in "Permission denied", which arrives over the encrypted
/// transport: key exchange, host key signature, cipher and MAC all worked by then.
private final class LocalSSHD {
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd") && FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen")
    }

    let port: Int
    let directory: URL
    private let process: Process

    init(keyType: String, bits: Int? = nil, options: [String]) async throws {
        directory = try tempDirectory()
        let key = directory.appendingPathComponent("host_key")
        try await Self.run("/usr/bin/ssh-keygen", ["-q", "-t", keyType] + (bits.map { ["-b", String($0)] } ?? []) + ["-N", "", "-f", key.path])

        // A port nobody listens on.
        let probe = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
        port = try #require(probe.localAddress?.port)
        try await probe.close()

        let config = directory.appendingPathComponent("sshd_config")
        let lines = ["HostKey \(key.path)", "ListenAddress 127.0.0.1", "Port \(port)", "PidFile none", "UsePAM no",
                     "PasswordAuthentication yes", "KbdInteractiveAuthentication no", "PubkeyAuthentication no",
                     "PerSourcePenalties no"] + options
        try lines.joined(separator: "\n").appending("\n").write(to: config, atomically: true, encoding: .utf8)

        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        process.arguments = ["-D", "-e", "-f", config.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        // Wait until it accepts connections.
        for _ in 0..<100 {
            if let channel = try? await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connect(host: "127.0.0.1", port: port).get() {
                try? await channel.close()
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        await stop()
        Issue.record("sshd did not start")
    }

    func stop() async {
        if process.isRunning { process.terminate() }
        await Self.waitForExit(process)
        try? FileManager.default.removeItem(at: directory)
    }

    private static func run(_ path: String, _ arguments: [String]) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        await waitForExit(p)
        guard p.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    }

    /// `waitUntilExit` can hang on a Swift concurrency thread; poll instead.
    private static func waitForExit(_ p: Process) async {
        for _ in 0..<600 where p.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
    }
}

extension LegacySSHTests {
@Suite(.serialized, .enabled(if: LocalSSHD.isAvailable)) struct AgainstOpenSSH {
    private func handshake(keyType: String, bits: Int? = nil, kex: String, hostKey: String, cipher: String, mac: String,
                           legacy: [String]) async throws {
        let sshd = try await LocalSSHD(keyType: keyType, bits: bits, options: [
            "KexAlgorithms \(kex)", "HostKeyAlgorithms \(hostKey)", "Ciphers \(cipher)", "MACs \(mac)",
        ])
        do {
            try await check(sshd, kex: kex, hostKey: hostKey, cipher: cipher, mac: mac, legacy: legacy)
        } catch {
            await sshd.stop()
            throw error
        }
        await sshd.stop()
    }

    private func check(_ sshd: LocalSSHD, kex: String, hostKey: String, cipher: String, mac: String, legacy: [String]) async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sink = Sink()
        let transport = NIOSSHTransport(host: "127.0.0.1", port: sshd.port, username: "netdeck-test", password: "not-a-password",
                                        knownHostsDirectory: dir)
        try transport.open(onData: sink.append, onClose: sink.close)
        try await sink.wait { !$0.closes.isEmpty }
        let reason = try #require(sink.closes.first ?? nil)
        #expect(reason.contains("Permission denied"), "\(kex) \(hostKey) \(cipher) \(mac): \(reason)")
        #expect(transport.sshAlgorithms == SSHAlgorithms(keyExchange: kex, hostKey: hostKey, cipher: cipher, mac: mac, legacy: legacy))
        let pinned = try #require(SSHKnownHosts.stored(host: "127.0.0.1", port: sshd.port, directory: dir))
        // The same fingerprint `ssh-keygen -lf` prints for the host key.
        let pub = try String(contentsOf: sshd.directory.appendingPathComponent("host_key.pub"), encoding: .utf8)
        #expect(pinned == SSHKnownHosts.entry(openSSHKey: pub))
    }

    @Test func ios12StyleGroup1TripleDES() async throws {
        try await handshake(keyType: "rsa", bits: 1024, kex: "diffie-hellman-group1-sha1", hostKey: "ssh-rsa",
                            cipher: "3des-cbc", mac: "hmac-sha1",
                            legacy: ["diffie-hellman-group1-sha1", "ssh-rsa", "3des-cbc", "hmac-sha1"])
    }

    @Test func ios15StyleGroup14AESCBC() async throws {
        try await handshake(keyType: "rsa", bits: 2048, kex: "diffie-hellman-group14-sha1", hostKey: "ssh-rsa",
                            cipher: "aes128-cbc", mac: "hmac-sha1",
                            legacy: ["diffie-hellman-group14-sha1", "ssh-rsa", "aes128-cbc", "hmac-sha1"])
    }

    @Test func rsaSHA2AndCTR() async throws {
        try await handshake(keyType: "rsa", bits: 3072, kex: "diffie-hellman-group14-sha256", hostKey: "rsa-sha2-256",
                            cipher: "aes256-ctr", mac: "hmac-sha2-256", legacy: [])
        try await handshake(keyType: "rsa", bits: 2048, kex: "diffie-hellman-group16-sha512", hostKey: "rsa-sha2-512",
                            cipher: "aes192-cbc", mac: "hmac-sha2-512", legacy: ["aes192-cbc"])
    }

    @Test func longKeysAfterSHA256Exchange() async throws {
        // hmac-sha2-512 needs a 64-byte key from a SHA-256 exchange: RFC 4253 §7.2 key extension.
        try await handshake(keyType: "ed25519", kex: "curve25519-sha256", hostKey: "ssh-ed25519",
                            cipher: "aes128-ctr", mac: "hmac-sha2-512", legacy: [])
    }
}
}

// MARK: - Arithmetic and signature checks

private func bytes(_ hex: String) -> [UInt8] {
    var out = [UInt8]()
    var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        out.append(UInt8(hex[i..<j], radix: 16)!)
        i = j
    }
    return out
}

extension LegacySSHTests {
@Suite struct Arithmetic {
    /// (base, exponent, modulus, base^exponent mod modulus), computed with Python's pow().
    static let vectors: [(String, String, String, String)] = [
        ("23cce3b43b30cb34265ec95759642f93b4edc3c930124a73e8fabfd877312cddf62d94a290e765a8a85400aa947ae104f3d9fcda5672fa6adcfde0730694e7bf940adcbbb9f2d5376b9698b3d2ce7c34b0fdfac1596087822ea1af1244489590b03608f7d1110c13b2c828ca4d5e30d5678a447bf340d446bf13fdd0fd85850c54e79c92251442b585f2774b737c9d632d98cc5f25194b6a294a4821e38b60620e60f12a7ae6e4d6f1fce6b60aa1c12c8cbb2e93cfcbe3f80481210f2b6353c57371a5cfd48dc2a4cd97bb92187acfc8324d7bbabeca5027f969aa30b271b703bd3d375e6206e2db648aca5f8b10a733a329a71143cc238078f835981acb7ac2",
         "8030c46c798c709fa3d3f6b69dd3f917d04de0576bb88d27a3ac740d87eb231ee135e5dfae920e36d5730f4c9d940263b7319291456bec5969325df32541b8a6",
         "c62ad0f2603592fcdcc4b91b66cecc5dd6ab400a273a49209f1f057aed3a600a4164dcd38f6473b2f564a4f7d1ecdc98fa99bb152e36c5907701fc0de62708d6db8f1beb0d1f76f63756725d6d5a2f467e7ee6e81b69ad943b5b9776954adb2536e9715e24e6b6dd63e75ae1355ab40284adf59ceba72d50f1de610d91ecd56018b291c1be526d5f5b066d68468070b7355034c9019d85955ebb54ad0db2c5208b2de277fdb6c5533aae19f800e0004adf85a2b5ad5d25a637a2c26a2a48979db3a20b6c6c6b0b41b40b03947ea321be50eb3506619cd31d39a03de804a199ebc0a89b830ba3f10b130e888e57c723ac34296a83d4a8142aa7f8c874e6b9197d",
         "b0636997d1dd609b214eec11fa55bc88dd908176f788aee8217cfacc23fa0b3fe767dcd00b3634ee2643918207a20198837d8b88d1f6aedf10aa8d9212921b6287a593ffc14fd2afb9c2b49df19a6fb23fb1abf87bcd3a1e9c320254e6ac66786bbd5c2c8267e446ba3b67307eb81ab558cf72d731f36e401ef051b00273d2db2b08d1020f22aa330ca491846cbefffc3482a528bf14278bd8944bf470ca5e02fe1e7c8862606594ddcb4cf981b9e838a2e24b251eeef440343fe1bac414970e6fd8539d59c464e04c0661b69408e0a37c1cc10b204164210d48cb832d73bf1d10abce3dcdce341a0a069717b88537cb022d0af5151eb324937f5b0a415b3c54"),
        ("7d21b6dae21fcf95a57964aaae59920f3ec2699089d3380d6b1b4b1c6b62b4988334df99987c0ed0ee56b35b653c96f6be5d82381f02501339e97642870648143bd2c0afb656d127970ec4963615aec271490cf0e747f5f32896edfdee2ad080916f0a553a0e747ea93abc4078bb1992c7adea881ae595a205fd242cf6c5f877db4bc72ea959118bab970e295455f6e3b11a870fef5def71f9173d378a123603c0b710204f680207c8debda2604c224b311b84069d1403aabc4f72fe411f76c444fb9ec2683d9193e47b0d032b8a17aeb2e0e4bcdde63f93d3dc7c4f8f101f4e5c69c66de265c499e7ef302a25b7ff54f6c88bdef581f30ff354ae88d414b8d3",
         "01a9b7045cf9fc33d76cfecf89d25ce1e5f47ada1523ea6e0da623142a7304edee71fbdba16937ed8a76f37bb028960d04566f1600a7fcf0122d05803c2dba0461cf8c77b3cdee207e2e88db75b85e729d912f6f123de8ad3d16aedd2bc3d5021270fa1a61c6e98e553d143289175affbe0eaa28d048b7941e426a7fa1ca9aaf2c62326765f19c6da9d115d21af7368860c7bb2dbec709432b7b0527fb198f9e52051cf8c922cd84531c122a1d5b0502514a9e11946c7421c5f8c064bd02cc3fff4f4f2f9fc512ac5010b4f4992591488eff15dbdf4471d462a95a722cece8e84b2d2d312871124438a0d81b80ca35654924a8f37bb63ca8ebe555a6e9564784",
         "c62ad0f2603592fcdcc4b91b66cecc5dd6ab400a273a49209f1f057aed3a600a4164dcd38f6473b2f564a4f7d1ecdc98fa99bb152e36c5907701fc0de62708d6db8f1beb0d1f76f63756725d6d5a2f467e7ee6e81b69ad943b5b9776954adb2536e9715e24e6b6dd63e75ae1355ab40284adf59ceba72d50f1de610d91ecd56018b291c1be526d5f5b066d68468070b7355034c9019d85955ebb54ad0db2c5208b2de277fdb6c5533aae19f800e0004adf85a2b5ad5d25a637a2c26a2a48979db3a20b6c6c6b0b41b40b03947ea321be50eb3506619cd31d39a03de804a199ebc0a89b830ba3f10b130e888e57c723ac34296a83d4a8142aa7f8c874e6b9197d",
         "0f3e38304f3e120862c4c1c5fa9fbd1edbefe7710bb9fd4cb8a3e57dfeec68a3f8354576265fb649b45dfe4839e805242ae44bea03baeeca0c29eaf4496d1838c3a5930765c9ef3f8f55518d7b0d6360ce3de97349822f060c2407b682364a155b1edde2c1f057a1daf30828ca349f53c4b842d6072beacac5cbc7aba72fbdcc66ffece325ae387ced517d4d58da7e3f576c70bb63e01a9b49a002754d50b02af3d05a824d6a1281217aa454f0cf76dd7ebc8c09d0e48668752d639cb6cabc11f013d0db4a8a51f960da60facc4d3ef39ea3f0644471c2ad75f113a4eaea92272ed41723a5255855b405eeb57df2cac3aca832c8cceb47efb5080d45091000d1"),
        ("02",
         "fb0a624be91ba9604b45c33ebf4f1c396ebad576b8645e68f4ca0d68c74c6f1925dfd9040252bf7ae1aa3f3910404ea79fefad1c6cf403522fa3898808f3ee71",
         "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3be39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa051015728e5a8aaac42dad33170d04507a33a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864d87602733ec86a64521f2b18177b200cbbe117577a615d6c770988c0bad946e208e24fa074e5ab3143db5bfce0fd108e4b82d120a92108011a723c12a787e6d788719a10bdba5b2699c327186af4e23c1a946834b6150bda2583e9ca2ad44ce8dbbbc2db04de8ef92e8efc141fbecaa6287c59474e6bc05d99b2964fa090c3a2233ba186515be7ed1f612970cee2d7afb81bdd762170481cd0069127d5b05aa993b4ea988d8fddc186ffb7dc90a6c08f4df435c934063199ffffffffffffffff",
         "f90f65d8beced547d91d8dcfa2ec024a2e5cbc64f8c1398f2bf260a2dd8755e33cebd4329e55f134672013fcc5d324f5b259dae9b0d13d001075af784ccb5551358be36045b52e7a8091952ac943e45b8f3f967ab0c532734109a4b18b1d77a536011e7b414d201110571ad2079a74427e03f982e750e448e2deaf763a5a4ad7da40976abec54198f209f7bfd70f626d0e2898fd79335c511110dc9652342a7450862c40090719df6f3817292c0ac85696371671c708ba0d878878c638d94304ad74ff3a48c5409f930cc375d7dbca8bf2e951ac28002672fd9115a7dd521b813b0657d448045352717b565c1ee4856e5ce786d45059a44bcb3750670fdece4fa84b6d024d45743b51b4809e102168d752cf466af4e7f1a4ad13301b95b61b34b5d5a80af511d6d07776049d89279efea62177f9170b177f4f20791d0fc4013fce01550f5c42145e5f38a1ba355631d2634297d3cc80ac08157875b1b70b708eaf5005e7dabd740e9e1a42cfc01d11d2adf052e66be99bd9130149b77cc0e7d4661ed25ff922120fb01dbaa91e007753c4291fc2140ba7631774dfea37632c62bac7395e356513ec085db1f476292fb1e0893dfc6e38c11b285336ff2d0452433c8e0b01476e4340d758decbc2a0c9ee29072af7fd528ce233d579136a04c15d0ffbcc07905da98ad2370713674193c29d8ded42fb4d3020ecf2d687d6792b71"),
        ("135c1a2df195c2656bb84bbe2535b52288e5bffd697792ebdcfcd51ae6d9504e79a23af3770bf1662f71957916c12e5f0aa044196400723b2ba75e03847299ef76d8766c104af9e01ed4df32c13df111477a4bb3f3ce4745cb0cce9f3d15720dd52f914adb49846806ed6ec2e180373c4653a2df4f8ebf5377df89d80b20e7e5214e44da14c2d9abb44ecfd1560e0048c209301ca65ec836937ced5e12cab9932d8f0fab12130b08a32bf937e5c1b508ac51d5877308592b58671f2f94345febec139a84bf594e14b5a55c1581b54dab5b75578321ef72db37919f768d5a4fa2eb066ca525035c50bb6878aefe42e61d610e5163b27fda44900ac4e01496977c",
         "00",
         "c62ad0f2603592fcdcc4b91b66cecc5dd6ab400a273a49209f1f057aed3a600a4164dcd38f6473b2f564a4f7d1ecdc98fa99bb152e36c5907701fc0de62708d6db8f1beb0d1f76f63756725d6d5a2f467e7ee6e81b69ad943b5b9776954adb2536e9715e24e6b6dd63e75ae1355ab40284adf59ceba72d50f1de610d91ecd56018b291c1be526d5f5b066d68468070b7355034c9019d85955ebb54ad0db2c5208b2de277fdb6c5533aae19f800e0004adf85a2b5ad5d25a637a2c26a2a48979db3a20b6c6c6b0b41b40b03947ea321be50eb3506619cd31d39a03de804a199ebc0a89b830ba3f10b130e888e57c723ac34296a83d4a8142aa7f8c874e6b9197d",
         "01"),
        ("00",
         "3039",
         "c62ad0f2603592fcdcc4b91b66cecc5dd6ab400a273a49209f1f057aed3a600a4164dcd38f6473b2f564a4f7d1ecdc98fa99bb152e36c5907701fc0de62708d6db8f1beb0d1f76f63756725d6d5a2f467e7ee6e81b69ad943b5b9776954adb2536e9715e24e6b6dd63e75ae1355ab40284adf59ceba72d50f1de610d91ecd56018b291c1be526d5f5b066d68468070b7355034c9019d85955ebb54ad0db2c5208b2de277fdb6c5533aae19f800e0004adf85a2b5ad5d25a637a2c26a2a48979db3a20b6c6c6b0b41b40b03947ea321be50eb3506619cd31d39a03de804a199ebc0a89b830ba3f10b130e888e57c723ac34296a83d4a8142aa7f8c874e6b9197d",
         "00"),
        ("01",
         "03cf0adcb056de6088d9297e699df54d61cf4d0c17b4375c5f4901c954a31fabaa2a702d8b01",
         "c62ad0f2603592fcdcc4b91b66cecc5dd6ab400a273a49209f1f057aed3a600a4164dcd38f6473b2f564a4f7d1ecdc98fa99bb152e36c5907701fc0de62708d6db8f1beb0d1f76f63756725d6d5a2f467e7ee6e81b69ad943b5b9776954adb2536e9715e24e6b6dd63e75ae1355ab40284adf59ceba72d50f1de610d91ecd56018b291c1be526d5f5b066d68468070b7355034c9019d85955ebb54ad0db2c5208b2de277fdb6c5533aae19f800e0004adf85a2b5ad5d25a637a2c26a2a48979db3a20b6c6c6b0b41b40b03947ea321be50eb3506619cd31d39a03de804a199ebc0a89b830ba3f10b130e888e57c723ac34296a83d4a8142aa7f8c874e6b9197d",
         "01"),
        ("02",
         "05",
         "03",
         "02"),
        ("d80e93e48209a9a4",
         "ff69b2dfb15337ec",
         "ffffffffffffffc5",
         "359a93b4fa05a2eb"),
        ("822cfd75ae8cc2ff",
         "0252fb196591ce8ca78a6ecb724a468359",
         "01000000000000000d",
         "2bedeb04bd13ccfe"),
        ("ffffffffffffffffffffffffffffff60",
         "b01de67aba3ad136e4a00b7fe7b9e7fa",
         "ffffffffffffffffffffffffffffff61",
         "01"),
        ("ffffffffffffffffffffffffffffff5f",
         "010001",
         "ffffffffffffffffffffffffffffff61",
         "0c9cc5304ac4ce7f6ec2c5b54c62b955"),    ]

    @Test func modularPowerMatchesPython() {
        for (b, e, m, r) in Self.vectors {
            let result = _NIOSSHLegacyTesting.modularPower(base: bytes(b), exponent: bytes(e), modulus: bytes(m))
            #expect(result == Array(bytes(r).drop(while: { $0 == 0 })), "\(b.prefix(16))... ^ \(e.prefix(16))... mod \(m.prefix(16))...")
        }
        // Montgomery needs an odd modulus and a reduced base.
        #expect(_NIOSSHLegacyTesting.modularPower(base: [2], exponent: [3], modulus: [10]) == nil)
        #expect(_NIOSSHLegacyTesting.modularPower(base: [11], exponent: [3], modulus: [11]) == nil)
    }

    @Test func diffieHellmanValuesOutOfRangeAreRefused() throws {
        for kex in ["diffie-hellman-group1-sha1", "diffie-hellman-group14-sha256", "diffie-hellman-group16-sha512"] {
            let p = try #require(_NIOSSHLegacyTesting.diffieHellmanPrime(kex))
            #expect(p.count * 8 == [1024, 2048, 4096][["diffie-hellman-group1-sha1", "diffie-hellman-group14-sha256",
                                                        "diffie-hellman-group16-sha512"].firstIndex(of: kex)!])
            // p ends in ...FFFF, so p-1 and p-2 only change the last byte. The top bit is set: mpints need a 0 in front.
            let pMinus1 = [0] + p.dropLast() + [p.last! - 1]
            let pMinus2 = [0] + p.dropLast() + [p.last! - 2]
            #expect(_NIOSSHLegacyTesting.acceptsDiffieHellmanValue([2], keyExchange: kex))
            #expect(_NIOSSHLegacyTesting.acceptsDiffieHellmanValue(pMinus2, keyExchange: kex))
            for refused in [[], [0], [1], [0, 1], pMinus1, [0] + p, [0x80, 1]] as [[UInt8]] {
                #expect(!_NIOSSHLegacyTesting.acceptsDiffieHellmanValue(refused, keyExchange: kex), "\(kex): \(refused.prefix(4))")
            }
        }
    }

    @Test func rsaSignaturesAreReallyChecked() throws {
        let secKey = try rsaKey()
        let key = try NIOSSHPrivateKey(rsaKey: secKey, signatureAlgorithm: "rsa-sha2-256").publicKey
        #expect(String(openSSHPublicKey: key).hasPrefix("ssh-rsa AAAA"))
        let modulus = try #require(_NIOSSHLegacyTesting.rsaModulus(key))
        let message = Array("exchange hash".utf8)
        let algorithms: [(String, SecKeyAlgorithm)] = [("ssh-rsa", .rsaSignatureMessagePKCS1v15SHA1),
                                                       ("rsa-sha2-256", .rsaSignatureMessagePKCS1v15SHA256),
                                                       ("rsa-sha2-512", .rsaSignatureMessagePKCS1v15SHA512)]
        for (name, secAlgorithm) in algorithms {
            let signature = try #require(SecKeyCreateSignature(secKey, secAlgorithm, Data(message) as CFData, nil) as Data?)
            let sig = Array(signature)
            func valid(_ s: [UInt8], _ alg: String = name, _ m: [UInt8] = message) -> Bool {
                _NIOSSHLegacyTesting.isValidRSASignature(publicKey: key, algorithm: alg, signature: s, message: m)
            }
            #expect(valid(sig), "\(name)")
            #expect(!valid(sig, name, message + [0]), "\(name): other message")
            var flipped = sig
            flipped[flipped.count / 2] ^= 0x01
            #expect(!valid(flipped), "\(name): flipped bit")
            for other in algorithms.map(\.0) where other != name {
                #expect(!valid(sig, other), "\(name) signature labelled \(other)")
            }
            #expect(!valid(Array(sig.dropLast())), "\(name): truncated")
            #expect(!valid([0] + sig + [0]), "\(name): longer than the modulus")
            #expect(!valid(modulus), "\(name): s = n")
            #expect(!valid([]), "\(name): empty")
        }
    }
}
}
