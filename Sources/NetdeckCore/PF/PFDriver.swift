import Foundation

/// pfSense / OPNsense over a text CLI session (SSH or console). Read only, like FortiGate: a firewall mistake
/// can cut off the connection that would undo it, and neither system has a timer that puts a configuration
/// back on its own. The change operations keep the protocol defaults and throw `DriverError.notSupported`.
///
/// Netdeck leaves the console menu through its "Shell" entry only (see `PFDialect`) and sends nothing but
/// reading commands: the identity line, `ifconfig -a`, `arp -an` and `cat /conf/config.xml`.
public actor PFDriver: DeviceDriver {
    private let cli: CLISession
    private let expected: Platform

    /// `platform` is what the user picked or Netdeck detected; the identity command has the last word.
    public init(transport: Transport, platform: Platform) {
        cli = CLISession(transport: transport, dialect: PFDialect())
        expected = platform
    }

    // MARK: Session

    public func connect(username: String, password: String?) async throws {
        try await cli.login(username: username, password: password)
        let id = PFParsers.identity(try await cli.run(PFParsers.identityCommand, idle: .seconds(30)))
        guard let found = id.platform else { throw DriverError.notSupported }
        // OPNsense picked but pfSense found (or the other way round): hand over, so the device is saved as what it is.
        if found != expected { throw CLIError.unrecognizedPrompt(found == .opnsense ? "OPNsense" : "pfSense") }
    }

    public func disconnect() async {
        await cli.logout()
    }

    // MARK: Read

    public func read(progress: @Sendable (LoadStep) -> Void) async throws -> DeviceReading {
        let steps = [t("Reading device info"), t("Reading port status"), t("Reading MAC table"), t("Reading configuration")]
        func step(_ i: Int) { progress(LoadStep(index: i, total: steps.count, title: steps[i])) }

        var o = PFSnapshot.Outputs()
        step(0); o.identity = try await cli.run(PFParsers.identityCommand, idle: .seconds(30))
        step(1); o.ifconfig = try await cli.run("ifconfig -a", idle: .seconds(30))
        step(2); o.arp = try await cli.run("arp -an", idle: .seconds(30))
        step(3)
        // Only root can read it on some releases; without it the ports still come from ifconfig.
        let config = try await cli.run("cat /conf/config.xml", idle: .seconds(60), timeout: .seconds(900))
        o.config = config.contains("</pfsense>") || config.contains("</opnsense>") ? config : ""
        return .network(PFSnapshot.build(o))
    }
}
