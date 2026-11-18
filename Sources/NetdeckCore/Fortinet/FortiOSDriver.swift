import Foundation

/// FortiGate / FortiWiFi over a text CLI session (SSH or console). Read only.
///
/// A mistake on a firewall can cut off the very connection (often a VPN through it) that would undo it,
/// and FortiOS has no timer that puts a configuration back without a restart. Netdeck reads FortiGates and
/// keeps their configuration in History & backups; the change operations keep the protocol defaults and
/// throw `DriverError.notSupported`.
///
/// Only `get`, `show` and `diagnose ... list` commands are sent. With virtual domains on, the interface
/// list and the ARP table are read inside `config global`, which Netdeck leaves with `end`; it never
/// `edit`s anything (`edit` on a missing name creates it).
public actor FortiOSDriver: DeviceDriver {
    private let cli: CLISession
    private var vdoms = false

    public init(transport: Transport) {
        cli = CLISession(transport: transport, dialect: FortiOSDialect())
    }

    // MARK: Session

    public func connect(username: String, password: String?) async throws {
        try await cli.login(username: username, password: password)
        let status = try await cli.run("get system status", idle: .seconds(30))
        guard FortiOSParsers.isFortiGate(status) else { throw DriverError.notSupported }
        vdoms = FortiOSParsers.status(status).vdoms
    }

    public func disconnect() async {
        await cli.logout()
    }

    // MARK: Read

    public func read(progress: @Sendable (LoadStep) -> Void) async throws -> DeviceReading {
        let steps = [
            t("Reading device info"),
            t("Reading port status"),
            t("Reading MAC table"),
            t("Reading configuration"),
        ]
        func step(_ i: Int) { progress(LoadStep(index: i, total: steps.count, title: steps[i])) }

        var o = FortiOSSnapshot.Outputs()
        step(0)
        await leaveGlobal()
        o.status = try await cli.run("get system status", idle: .seconds(30))
        vdoms = FortiOSParsers.status(o.status).vdoms

        step(1)
        if vdoms { try await enterGlobal() }
        o.physical = try await shown("get system interface physical")
        step(2)
        if vdoms {
            // Every VDOM's neighbours, with the interface they were seen on.
            o.arp = try await shown("diagnose ip arp list")
            await leaveGlobal()
        } else {
            o.arp = try await shown("get system arp")
        }

        step(3)
        // The whole configuration: History & backups keeps it, and the interface tables come from it.
        o.config = try await shown("show", idle: .seconds(60), timeout: .seconds(900))
        return .network(FortiOSSnapshot.build(o))
    }

    // MARK: Internals

    /// A command's output, or "" when FortiOS refused it (a profile without access, an older release).
    /// A refusal is a line or two, so only the start is checked: a configuration may quote such words.
    private func shown(_ command: String, idle: Duration = .seconds(30), timeout: Duration = .seconds(240)) async throws -> String {
        let out = try await cli.run(command, idle: idle, timeout: timeout)
        return Self.refused(out) ? "" : out
    }

    static func refused(_ output: String) -> Bool {
        let head = output.components(separatedBy: "\n").prefix(3).joined(separator: "\n")
        return !FortiOSParsers.errors(in: head).isEmpty
    }

    private func enterGlobal() async throws {
        _ = try await cli.run("config global", idle: .seconds(30))
        guard await cli.currentPrompt == .configuration else {
            throw CLIError.unrecognizedPrompt(await cli.promptLine)
        }
    }

    /// Back to the top level from `config global` (it holds no edits, so `end` saves nothing).
    private func leaveGlobal() async {
        guard await cli.currentPrompt == .configuration else { return }
        if FortiOSDialect.context(await cli.promptLine) == "global" {
            _ = try? await cli.run("end", idle: .seconds(10))
        }
    }
}
