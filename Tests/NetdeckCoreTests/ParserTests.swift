import Foundation
import Testing
@testable import NetdeckCore

/// Fixtures are raw console captures from a real EX4300-48T (Junos 21.2R3.8), including the echoed
/// command and trailing prompt, exactly as `JunosCLI` receives them. Serials, MACs and user names are anonymized.
func fixture(_ name: String) throws -> String {
    L10n.language = .en
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
    return JunosCLI.stripEchoAndPrompt(try String(contentsOf: url, encoding: .utf8))
}

@Suite struct CLITextTests {
    @Test func promptKinds() {
        #expect(JunosCLI.promptKind("root@sw-01> ") == .operational)
        #expect(JunosCLI.promptKind("root@sw-01#") == .configuration)
        #expect(JunosCLI.promptKind("root@sw-01:RE:0%") == .shell)
        #expect(JunosCLI.promptKind("login:") == .login)
        #expect(JunosCLI.promptKind("Password:") == .password)
        #expect(JunosCLI.promptKind("---(more 100%)---") == .pager)
        #expect(JunosCLI.promptKind("Exit with uncommitted changes? [yes,no] (yes) ") == .question)
        #expect(JunosCLI.promptKind("set interfaces ge-0/0/2 description x") == nil)
        #expect(JunosCLI.promptKind("{master:0}") == nil)
    }

    @Test func stripsEchoPromptAndAnsi() {
        let raw = "show version \r\nHostname: sw-01\r\n\u{1B}[24;9HModel: ex4300-48t\r\n\r\n{master:0}\r\nroot@sw-01> "
        #expect(JunosCLI.stripEchoAndPrompt(raw) == "Hostname: sw-01\nModel: ex4300-48t")
    }

    @Test func shellBannerAfterRootLoginIsRecognised() {
        // Exact bytes the EX4300 console sends after a root login: clear tabs, then 9× (move cursor, ESC H).
        var banner = "--- JUNOS 21.2R3.8 built 2022-03-10 06:53:23 UTC\r\n\u{1B}[3g"
        for col in stride(from: 9, through: 73, by: 8) { banner += "\u{1B}[24;\(col)H\u{1B}H" }
        banner += "root@sw-01:RE:0% "
        let cleaned = JunosCLI.clean(banner)
        let last = cleaned.components(separatedBy: "\n").last ?? ""
        #expect(last == "root@sw-01:RE:0% ")
        #expect(JunosCLI.promptKind(last) == .shell)
    }

    @Test func stripsConfigModePrompt() {
        let raw = "show | compare\n[edit interfaces ge-0/0/2]\n+   description X;\n\n{master:0}[edit]\nroot@sw-01# "
        #expect(JunosCLI.stripEchoAndPrompt(raw) == "[edit interfaces ge-0/0/2]\n+   description X;")
    }

    @Test func detectsCommandPromptAtEnd() {
        #expect(JunosCLI.endsWithCommandPrompt("x\n{master:0}\nroot@sw-01> "))
        #expect(!JunosCLI.endsWithCommandPrompt("show interfaces terse "))
    }
}

@Suite struct ConfigParserTests {
    @Test func parsesRealConfig() throws {
        let cfg = SetConfigParser.parse(try fixture("config-set"))
        #expect(cfg.hostname == "sw-01")
        #expect(cfg.vlans.count == 6)  // "default" (VLAN 1) is implicit, not in the config
        #expect(cfg.vlan(named: "cust-01")?.vlanID == 100)
        #expect(cfg.vlan(named: "firstboot")?.description == "Firstboot VPS platform")
        #expect(cfg.vlan(named: "cust-01-oob")?.description == "Customer 1 out-of-band")

        let ge2 = cfg.effective("ge-0/0/2")
        #expect(ge2.description == "R640-PVE-01")
        #expect(ge2.mode == .access)
        #expect(ge2.vlanMembers == ["cust-01"])
        #expect(!ge2.disabled)

        let unused = try #require(cfg.ranges.first { $0.name == "UNUSED" })
        #expect(unused.contains("ge-0/0/3"))
        #expect(unused.contains("ge-0/0/23"))
        #expect(!unused.contains("ge-0/0/2"))
        #expect(!unused.contains("ge-0/0/24"))
        #expect(unused.contains("ge-0/0/47"))

        let ge5 = cfg.effective("ge-0/0/5")
        #expect(ge5.disabled)
        #expect(ge5.description == "Unused - disabled")

        #expect(cfg.effective("me0").inetAddresses == ["192.168.1.228/24"])
        #expect(cfg.rstpEdge.contains("ge-0/0/2"))
        #expect(cfg.bpduBlockOnEdge)
        #expect(!cfg.lines.contains { $0.contains("$1$") })
    }

    @Test func tokenizesQuotedValues() {
        #expect(SetConfigParser.tokenize(#"set vlans cust-01 description "Customer 1""#)
            == ["set", "vlans", "cust-01", "description", "Customer 1"])
        #expect(SetConfigParser.tokenize(#"set system x """#) == ["set", "system", "x", ""])
        #expect(SetConfigParser.quote("SRV02-IDRAC") == "SRV02-IDRAC")
        #expect(SetConfigParser.quote("Customer 1") == "\"Customer 1\"")
    }
}

@Suite struct OutputParserTests {
    @Test func terse() throws {
        let s = OutputParsers.interfacesTerse(try fixture("interfaces-terse"))
        let ge0 = try #require(s.first { $0.name == "ge-0/0/0" })
        #expect(ge0.adminUp && ge0.linkUp)
        let ge3 = try #require(s.first { $0.name == "ge-0/0/3" })
        #expect(!ge3.adminUp && !ge3.linkUp)
        #expect(s.contains { $0.name == "ge-0/2/0" })
        #expect(!s.contains { $0.name.contains(".") })
    }

    @Test func macTable() throws {
        let m = OutputParsers.macTable(try fixture("ethernet-switching-table"))
        #expect(m.count >= 3)
        #expect(m.contains { $0.mac == "b0:7b:25:00:00:0b" && $0.interface == "ge-0/0/1" && $0.vlan == "cust-01" })
        #expect(m.allSatisfy { !$0.interface.contains(".") })
    }

    @Test func lldpEmptyAndSample() throws {
        #expect(OutputParsers.lldpNeighbors(try fixture("lldp-neighbors")).isEmpty)
        let sample = """
        Local Interface    Parent Interface    Chassis Id          Port info          System Name
        ge-0/0/1           -                   b0:7b:25:00:00:0b   NIC.Integrated.1-3 pve-01
        xe-0/2/0.0         -                   78:ac:44:00:00:01   enp59s0f0          pve-01
        """
        let n = OutputParsers.lldpNeighbors(sample)
        #expect(n.count == 2)
        #expect(n[0].localInterface == "ge-0/0/1")
        #expect(n[0].chassisID == "b0:7b:25:00:00:0b")
        #expect(n[0].portInfo == "NIC.Integrated.1-3")
        #expect(n[0].systemName == "pve-01")
        #expect(n[1].localInterface == "xe-0/2/0")
    }

    @Test func chassis() throws {
        let h = OutputParsers.chassisHardware(try fixture("chassis-hardware"))
        #expect(h.model == "EX4300-48T")
        #expect(h.serial == "PE0000000001")
        #expect(h.transceivers.count == 2)
        #expect(h.transceivers[0].pic == 2 && h.transceivers[0].port == 0)
        #expect(h.transceivers[0].description == "SFP28-25G-BASE-CU-1M")
        #expect(h.pics.contains { $0.pic == 2 && $0.portCount == 4 && $0.isSFP })
    }

    @Test func commits() throws {
        let c = OutputParsers.commitHistory(try fixture("system-commit"))
        #expect(c.first?.index == 0)
        #expect(c.first?.comment == "confirm ge-0/0/2")
        #expect(c[1].confirmed)
        #expect(c[1].comment == "open ge-0/0/2 for proxmox")
        #expect(c.contains { $0.isRescue })
        #expect(c.contains { $0.client == "junoscript" && $0.comment == "Modified via JWeb EZsetup" })
    }

    @Test func versionAndCount() throws {
        let v = OutputParsers.version(try fixture("version"))
        #expect(v.hostname == "sw-01")
        #expect(v.junos == "21.2R3.8")
        #expect(OutputParsers.count("Count: 12 lines") == 12)
        #expect(OutputParsers.errors(in: "error: syntax error: foo\nok").count == 1)
    }
}

@Suite struct SnapshotTests {
    func snapshot() throws -> SwitchSnapshot {
        SwitchSnapshot(
            version: OutputParsers.version(try fixture("version")),
            hardware: OutputParsers.chassisHardware(try fixture("chassis-hardware")),
            config: SetConfigParser.parse(try fixture("config-set")),
            configText: try fixture("config-set"),
            statuses: OutputParsers.interfacesTerse(try fixture("interfaces-terse")),
            macTable: OutputParsers.macTable(try fixture("ethernet-switching-table")),
            lldp: [],
            commits: OutputParsers.commitHistory(try fixture("system-commit")),
            vcPorts: OutputParsers.vcPorts(try fixture("vc-port"))
        )
    }

    @Test func frontPanel() throws {
        let s = try snapshot()
        let ports = s.ports
        #expect(ports.filter { $0.kind == .copper }.count == 48)
        #expect(ports.filter { $0.kind == .sfp }.count == 4)
        #expect(ports.first?.name == "ge-0/0/0")

        let ge0 = try #require(s.port(named: "ge-0/0/0"))
        #expect(ge0.state == .up)
        #expect(ge0.vlans == ["cust-01"])
        #expect(ge0.macs.count >= 1)

        #expect(s.port(named: "ge-0/0/7")?.state == .disabled)
        #expect(s.port(named: "ge-0/0/7")?.disabledByRange == "UNUSED")
        #expect(s.port(named: "ge-0/0/24")?.state == .down)

        let cage0 = try #require(s.port(named: "xe-0/2/0"))
        #expect(cage0.state == .warning)
        #expect(cage0.transceiver?.description == "SFP28-25G-BASE-CU-1M")
        #expect(s.port(named: "xe-0/2/3")?.state == .empty)
    }

    @Test func rearPanel() throws {
        let s = try snapshot()
        let rear = s.rearPorts
        #expect(rear.count == 4)
        #expect(rear.allSatisfy { $0.role == .virtualChassis && $0.statusText == "Absent" && !$0.linkUp })
        #expect(rear.first?.name == "1/0")
        let mgmt = try #require(s.managementPort)
        #expect(!mgmt.linkUp)
        #expect(mgmt.addresses == ["192.168.1.228/24"])
    }
}
