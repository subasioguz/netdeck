import Foundation

/// A sample EX4300-48T built from anonymized console captures, for trying Netdeck without hardware
/// and for rendering screenshots.
public enum DemoData {
    static func text(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: "demo-\(name)", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return JunosCLI.stripEchoAndPrompt(raw)
    }

    public static func snapshot() -> SwitchSnapshot {
        let config = text("config-set")
        return SwitchSnapshot(
            version: OutputParsers.version(text("version")),
            hardware: OutputParsers.chassisHardware(text("chassis-hardware")),
            config: SetConfigParser.parse(config),
            configText: config,
            statuses: OutputParsers.interfacesTerse(text("interfaces-terse")),
            macTable: OutputParsers.macTable(text("ethernet-switching-table")),
            lldp: OutputParsers.lldpNeighbors(text("lldp-neighbors")),
            commits: OutputParsers.commitHistory(text("system-commit")),
            vcPorts: OutputParsers.vcPorts(text("vc-port"))
        )
    }

    public static var sampleDiff: String { text("rollback-compare-2-0") }

    /// The captures come from a switch whose clock ran about 18 days behind, with NTP off: its newest
    /// commit (#0) was made right before the capture, on 17 Nov 2026 by the Mac's clock.
    public static let sampleClockBehindDays = 18

    public static func profile() -> DeviceProfile {
        DeviceProfile(id: "demo-sw-01", name: "sw-01", kind: .switchDevice, platform: .juniperJunos, location: "Home",
                      connection: .serial(path: "/dev/cu.usbserial-1410", baud: 9600), username: "root",
                      // 64:4b:f0:00:00:08 is shown as "This Mac" by the app itself (translated), not by an alias.
                      aliases: ["b0:7b:25:00:00:0b": "Server 1 iDRAC", "b0:7b:25:00:00:0c": "Server 2 iDRAC"])
    }
}
