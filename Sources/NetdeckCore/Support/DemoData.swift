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

// MARK: - Layout samples (renders and tests)

extension DemoData {
    /// Snapshots of other models, built from port names only (no captures), to check how the faceplate
    /// lays out ports that aren't an EX4300-48T. Junos models go through the normal Junos port rules.
    public static func layoutSamples() -> [SwitchSnapshot] {
        func junos(_ model: String, _ names: [String], up: Set<Int> = [0, 1, 5]) -> SwitchSnapshot {
            var hw = HardwareInfo()
            hw.model = model
            let statuses = names.enumerated().map { InterfaceStatus(name: $1, adminUp: true, linkUp: up.contains($0)) }
            return SwitchSnapshot(version: VersionInfo(hostname: model.lowercased(), model: model.lowercased(), junos: "23.4R2"),
                                  hardware: hw, config: JunosConfig(), configText: "", statuses: statuses, macTable: [], lldp: [], commits: [])
        }
        func other(_ platform: Platform, _ model: String, _ ports: [(String, SwitchPort.Kind)]) -> SwitchSnapshot {
            var hw = HardwareInfo()
            hw.model = model
            let list = ports.enumerated().map { i, p -> SwitchPort in
                var sp = SwitchPort(slotKey: p.0, name: p.0)
                sp.kind = p.1
                sp.number = Int(p.0.reversed().prefix { $0.isNumber }.reversed().map(String.init).joined()) ?? i
                sp.linkUp = i % 3 == 0
                sp.present = true
                return sp
            }
            return SwitchSnapshot(version: VersionInfo(hostname: model.lowercased(), model: model, junos: nil), hardware: hw,
                                  config: JunosConfig(), configText: "", statuses: [], macTable: [], lldp: [], commits: [],
                                  platform: platform, explicitPorts: list)
        }
        return [
            junos("EX2300-24T", (0..<24).map { "ge-0/0/\($0)" } + (0..<4).map { "xe-0/1/\($0)" }),
            junos("QFX5100-48S-6Q", (0..<48).map { "xe-0/0/\($0)" } + (48..<54).map { "et-0/0/\($0)" }),
            junos("SRX345", (0..<16).map { "ge-0/0/\($0)" }),
            junos("MX204", (0..<4).map { "et-0/0/\($0)" } + (0..<8).map { "xe-0/1/\($0)" }),
            other(.mikrotikRouterOS, "CRS326-24G-2S+", (1...24).map { ("ether\($0)", .copper) } + (1...2).map { ("sfp-sfpplus\($0)", .sfp) }),
            other(.ubiquitiEdgeOS, "EdgeRouter X 5-Port", (0...4).map { ("eth\($0)", .copper) }),
            other(.ciscoIOS, "C9300-48P", (1...48).map { ("GigabitEthernet1/0/\($0)", .copper) } + (1...4).map { ("TenGigabitEthernet1/1/\($0)", .sfp) }),
            junos("EX4100-24T", (0..<24).map { "ge-0/0/\($0)" } + (0..<4).map { "et-0/1/\($0)" } + (0..<4).map { "xe-0/2/\($0)" }),
            junos("SRX300", (0..<8).map { "ge-0/0/\($0)" }),
            other(.ciscoIOS, "WS-C2960X-24TS-L", (1...28).map { ("GigabitEthernet1/0/\($0)", $0 > 24 ? .sfp : .copper) }),
            other(.mikrotikRouterOS, "CCR2004-16G-2S+", (1...16).map { ("ether\($0)", .copper) } + (1...2).map { ("sfp-sfpplus\($0)", .sfp) }),
            other(.mikrotikRouterOS, "RB5009UG+S+", (1...8).map { ("ether\($0)", .copper) } + [("sfp-sfpplus1", .sfp)]),
            other(.mikrotikRouterOS, "RB750Gr3", (1...5).map { ("ether\($0)", .copper) }),
            other(.ubiquitiEdgeOS, "EdgeRouter 4", (0...2).map { ("eth\($0)", .copper) } + [("eth3", .sfp)]),
        ]
    }

    /// A Dell server read over Redfish, for renders.
    public static func sampleServer() -> ApplianceSnapshot {
        ApplianceSnapshot(
            platform: .dellIDRAC, kind: .server, hostname: "pve-01", model: "PowerEdge R640", serial: "TEST001",
            osVersion: "iDRAC 7.00.00.172", power: .on, health: .ok,
            facts: [.init(label: t("Processors"), value: "2× Intel Xeon Silver 4214"), .init(label: t("Memory"), value: "256 GB")],
            firmware: [.init(label: "BIOS", value: "2.19.1"), .init(label: "iDRAC", value: "7.00.00.172")],
            sensors: [.init(name: "CPU1 Temp", kind: .temperature, reading: 48, unit: "°C", health: .ok),
                      .init(name: "CPU2 Temp", kind: .temperature, reading: 51, unit: "°C", health: .ok),
                      .init(name: "System Board Inlet Temp", kind: .temperature, reading: 23, unit: "°C", health: .ok),
                      .init(name: "System Board Fan1", kind: .fan, reading: 6840, unit: "RPM", health: .ok),
                      .init(name: "System Board Fan2", kind: .fan, reading: 6720, unit: "RPM", health: .ok)],
            components: [.init(name: "PS1 Status", detail: "750 W · 182 W now", health: .ok),
                         .init(name: "PS2 Status", detail: "750 W · no input", health: .warning)],
            disks: [.init(name: "Disk 0 in Backplane 1", model: "MZ7KH480HAHQ0D3", sizeBytes: 480_103_981_056, type: "SSD", health: .ok),
                    .init(name: "Disk 1 in Backplane 1", model: "MZ7KH480HAHQ0D3", sizeBytes: 480_103_981_056, type: "SSD", health: .ok)],
            interfaces: [.init(name: "NIC.Integrated.1-1-1", mac: "B0:7B:25:00:00:21", linkUp: true, speedMbps: 10_000),
                         .init(name: "NIC.Integrated.1-2-1", mac: "B0:7B:25:00:00:22", linkUp: false, speedMbps: nil)],
            alerts: ["The power input for power supply 2 is lost."],
            powerActions: [.gracefulShutdown, .gracefulRestart, .forceRestart, .forceOff])
    }

    /// A Synology NAS read over its Web API, for renders.
    public static func sampleNAS() -> ApplianceSnapshot {
        ApplianceSnapshot(
            platform: .synologyDSM, kind: .storage, hostname: "nas-01", model: "DS920+", serial: "TEST0000002",
            osVersion: "DSM 7.2.1-69057 Update 5", uptimeSeconds: 1_036_800, health: .ok,
            facts: [.init(label: t("Memory"), value: "20 GB"), .init(label: t("Temperature"), value: "41 °C")],
            pools: [.init(name: "Volume 1", status: "normal", health: .ok, sizeBytes: 15_985_000_000_000, usedBytes: 9_420_000_000_000, layout: "SHR")],
            disks: (1...4).map { .init(name: "Drive \($0)", model: "WD80EFZZ", sizeBytes: 8_001_563_222_016, type: "HDD", health: .ok, temperature: 36, pool: "Volume 1") },
            interfaces: [.init(name: "LAN 1", mac: "00:11:32:00:00:01", linkUp: true, speedMbps: 1000, addresses: ["192.0.2.20/24"]),
                         .init(name: "LAN 2", mac: "00:11:32:00:00:02", linkUp: false)])
    }

    /// A FortiGate read over SSH (read only), for renders.
    public static func sampleFirewall() -> SwitchSnapshot {
        func block(_ name: String, up: Bool, speed: String = "1000Mbps (Duplex: full)") -> String {
            "    ==[\(name)]\n        status: \(up ? "up" : "down")\n        speed: \(up ? speed : "n/a")"
        }
        var o = FortiOSSnapshot.Outputs()
        o.status = """
        Version: FortiGate-60F v7.4.8,build2795,250523 (GA.M)
        Serial-Number: FGT60FTEST000001
        Hostname: fw-01
        Virtual domain configuration: disable
        Current HA mode: standalone
        """
        o.physical = (["== [onboard]", block("dmz", up: false), block("wan1", up: true), block("wan2", up: false)]
            + (1...5).map { block("internal\($0)", up: $0 != 3 && $0 != 4, speed: $0 == 2 ? "100Mbps (Duplex: full)" : "1000Mbps (Duplex: full)") }
            + [block("a", up: true), block("b", up: false)]).joined(separator: "\n")
        o.config = """
        config system interface
            edit "dmz"
                set ip 192.0.2.129 255.255.255.192
                set type physical
            next
            edit "wan1"
                set mode dhcp
                set type physical
                set alias "ISP A"
            next
            edit "wan2"
                set status down
                set type physical
            next
            edit "internal1"
                set type physical
                set alias "pve-01"
            next
            edit "internal"
                set ip 192.0.2.1 255.255.255.192
                set type hard-switch
            next
            edit "fortilink"
                set ip 192.0.2.193 255.255.255.192
                set type aggregate
                set member "a" "b"
            next
            edit "servers"
                set ip 192.0.2.65 255.255.255.192
                set interface "internal"
                set vlanid 20
            next
        end
        config system virtual-switch
            edit "internal"
                config port
                    edit "internal1"
                    next
                    edit "internal2"
                    next
                    edit "internal3"
                    next
                    edit "internal4"
                    next
                    edit "internal5"
                    next
                end
            next
        end
        config system zone
            edit "LAN"
                set interface "internal" "servers"
            next
        end
        """
        o.arp = "198.51.100.1      0          00:00:5e:00:53:01 wan1"
        return FortiOSSnapshot.build(o)
    }
}
