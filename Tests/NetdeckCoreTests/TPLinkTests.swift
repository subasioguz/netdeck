import Foundation
import Testing
@testable import NetdeckCore

/// Synthetic TP-Link captures (see Fixtures/synthetic/tplink/README.md), stripped the way `CLISession` strips live output.
func tplinkFixture(_ name: String) throws -> String {
    L10n.language = .en
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/synthetic/tplink"))
    return CLISession.strip(try String(contentsOf: url, encoding: .utf8), dialect: TPLinkDialect())
}

func tplinkOutputs(extraConfig: String = "") throws -> TPLinkSnapshotBuilder.Outputs {
    var o = TPLinkSnapshotBuilder.Outputs()
    o.systemInfo = try tplinkFixture("sg3428-show-system-info")
    o.runningConfig = try tplinkFixture("sg3428-running-config") + extraConfig
    o.vlans = try tplinkFixture("sg3428-show-vlan-brief")
    o.interfaceStatus = try tplinkFixture("sg3428-interface-status")
    o.macTable = try tplinkFixture("sg3428-mac-address-table")
    o.lldp = try tplinkFixture("sg3428-lldp-neighbor-information")
    return o
}

func tplinkSnapshot(extraConfig: String = "") throws -> SwitchSnapshot {
    TPLinkSnapshotBuilder.build(try tplinkOutputs(extraConfig: extraConfig))
}

@Suite struct TPLinkDialectTests {
    let d = TPLinkDialect()

    @Test func promptKinds() {
        #expect(d.prompt("SW-EDGE-02>") == .user)
        #expect(d.prompt("SW-EDGE-02#") == .operational)
        #expect(d.prompt("TL-SG3428# ") == .operational)
        #expect(d.prompt("SW-EDGE-02(config)#") == .configuration)
        #expect(d.prompt("SW-EDGE-02(config-if)#") == .configuration)
        #expect(d.prompt("SW-EDGE-02(config-if-range)#") == .configuration)
        #expect(d.prompt("SW-EDGE-02(config-vlan)#") == .configuration)
        #expect(d.prompt("Press any key to continue (Q to quit)") == .pager)
        #expect(d.prompt(" Reboot system in 5 minutes. Continue? (Y/N):") == .question)
        #expect(d.prompt("User:") == .login)
        #expect(d.prompt("Password:") == .password)
        #expect(d.prompt("Enter password:") == .password)
        #expect(d.prompt(" Gi1/0/1   LinkUp      1000M") == nil)
        #expect(d.prompt("#") == nil)
    }

    @Test func answeredPagerIsTakenOut() {
        let erase = "\r\u{0}" + String(repeating: " ", count: 37) + "\r\u{0}"
        let raw = "SW-EDGE-02#show running-config\r\n!SG3428\r\n#\r\nvlan 1\r\nPress any key to continue (Q to quit)" + erase
            + "#\r\nhostname \"SW-EDGE-02\"\r\nend\r\n\r\nSW-EDGE-02#"
        #expect(CLISession.strip(raw, dialect: d) == "!SG3428\n#\nvlan 1\n#\nhostname \"SW-EDGE-02\"\nend")
        // Not answered yet: the pager stays the last line, so the session answers it.
        let waiting = d.normalize("vlan 1\r\nPress any key to continue (Q to quit)")
        #expect(d.prompt(CLISession.lastLine(of: JunosCLI.clean(waiting))) == .pager)
    }

    @Test func errors() {
        #expect(d.errors(in: "Error: Bad command") == ["Error: Bad command"])
        #expect(d.errors(in: "Operation Fail. This command can't work in controller mode.").count == 1)
        #expect(d.errors(in: "Missing parameter data").count == 1)
        #expect(d.errors(in: " Reboot schedule is cancelled.").isEmpty)
        #expect(d.errors(in: "Saving user config, please wait...").isEmpty)
    }
}

@Suite struct TPLinkParserTests {
    init() { L10n.language = .en }

    @Test func names() {
        #expect(TPLinkParsers.shortName("gigabitEthernet 1/0/5") == "Gi1/0/5")
        #expect(TPLinkParsers.shortName("ten-gigabitEthernet 1/0/25") == "Te1/0/25")
        #expect(TPLinkParsers.shortName("two-gigabitEthernet 1/0/1") == "Tw1/0/1")
        #expect(TPLinkParsers.shortName("GigabitEthernet1/0/2") == "Gi1/0/2")
        #expect(TPLinkParsers.shortName("port-channel 1") == "Po1")
        #expect(TPLinkParsers.longName("Gi1/0/5") == "gigabitEthernet 1/0/5")
        #expect(TPLinkParsers.longName("Te1/0/25") == "ten-gigabitEthernet 1/0/25")
        #expect(TPLinkParsers.longName("Tw1/0/1") == "two-gigabitEthernet 1/0/1")
        #expect(TPLinkParsers.vlanList("10,20-22,30") == [10, 20, 21, 22, 30])
        #expect(TPLinkParsers.vlanListString([30, 21, 10, 20, 22]) == "10,20-22,30")
    }

    @Test func systemInfo() throws {
        let info = TPLinkParsers.system(try tplinkFixture("sg3428-show-system-info"))
        #expect(info.model == "TL-SG3428" && info.name == "SW-EDGE-02" && info.serial == "TEST00000002")
        #expect(info.firmware == "2.0.13 Build 20240417 Rel.62342")
        #expect(info.uptime == "12 day - 7 hour - 1 min - 25 sec")
        // Stackable T-series: "Device Name", and the versions under "Unit 1".
        let stack = TPLinkParsers.system(" Device Name          - T1700G-28TQ\n MAC                  - 00-00-5E-00-53-10\nDevice Info\nUnit 1\n Hardware Version           - T1700G-28TQ 3.0\n Firmware Version           - 3.0.0 Build 20190108 Rel.62365(s)\n Serial Number              -\n")
        #expect(stack.model == "T1700G-28TQ" && stack.name == "T1700G-28TQ" && stack.firmware == "3.0.0 Build 20190108 Rel.62365(s)" && stack.serial == nil)
        #expect(TPLinkParsers.isTPLink(" Hardware Version     - TL-SG2424 1.0\n Software Version     - 1.0.2 Build 20150114 Rel.48216"))
        #expect(!TPLinkParsers.isTPLink("Cisco IOS Software, C2960X Software"))
    }

    @Test func runningConfig() throws {
        let rc = TPLinkParsers.runningConfig(try tplinkFixture("sg3428-running-config"))
        #expect(rc.model == "SG3428" && rc.hostname == "SW-EDGE-02" && !rc.controllerManaged)
        #expect(rc.vlans == [1: "System-VLAN", 10: "users", 20: "voice", 30: "cameras", 99: "mgmt"])
        #expect(rc.interfaces["Gi1/0/1"]?.tagged == [10, 20, 30, 99] && rc.interfaces["Gi1/0/1"]?.description == "uplink core")
        let p2 = try #require(rc.interfaces["Gi1/0/2"])
        #expect(p2.untagged == [10] && p2.pvid == 10 && p2.removedVLAN1)
        #expect(rc.interfaces["Gi1/0/5"]?.shutdown == true)
        #expect(rc.interfaces["Gi1/0/23"]?.channelGroup == 1 && rc.interfaces["Po1"]?.tagged == [10, 20])
        #expect(rc.interfaces["vlan 99"] != nil && !TPLinkParsers.isFrontPort("vlan 99"))
        #expect(TPLinkParsers.runningConfig("!SG3452\n#\nsdm prefer omada\n#\nend").controllerManaged)
    }

    @Test func tables() throws {
        let rows = TPLinkParsers.interfaceStatus(try tplinkFixture("sg3428-interface-status"))
        #expect(rows.count == 28 && rows[0] == TPLinkPortRow(port: "Gi1/0/1", linkUp: true, speed: "1000M", medium: "Copper"))
        #expect(rows[4].linkUp == false && rows[4].speed == nil && rows[27].medium == "Fiber")
        #expect(TPLinkParsers.vlans(try tplinkFixture("sg3428-show-vlan-brief")).map(\.id) == [1, 10, 20, 30, 99])
        let macs = TPLinkParsers.macTable(try tplinkFixture("sg3428-mac-address-table"))
        #expect(macs.count == 5 && macs[0].port == "Gi1/0/1" && macs[0].vlan == 99 && macs.last?.port == "Po1")
        let lldp = TPLinkParsers.lldpNeighbors(try tplinkFixture("sg3428-lldp-neighbor-information"))
        #expect(lldp.count == 2)
        #expect(lldp[0].localInterface == "Gi1/0/1" && lldp[0].systemName == "SW-CORE-01" && lldp[0].portInfo == "GigabitEthernet1/0/48")
        #expect(lldp[1].localInterface == "Gi1/0/3" && lldp[1].systemName == "SIP-PHONE-03")
    }

    @Test func sameConfigurationIgnoresPadding() {
        #expect(TPLinkParsers.sameConfiguration("!SG3428\n#\nvlan 10\n name \"a\"\n#\n#\nend", "!SG3428\n#\nvlan 10\n name \"a\"  \n#\nend\n"))
        #expect(!TPLinkParsers.sameConfiguration("vlan 10\nend", "vlan 20\nend"))
        #expect(!TPLinkParsers.sameConfiguration("", ""))
    }
}

@Suite struct TPLinkSnapshotTests {
    init() { L10n.language = .en }

    @Test func ports() throws {
        let s = try tplinkSnapshot()
        #expect(s.platform == .tplinkOmada && s.kind == .switchDevice)
        #expect(s.hardware.model == "TL-SG3428" && s.version.hostname == "SW-EDGE-02" && s.version.junos == "2.0.13 Build 20240417 Rel.62342")
        #expect(s.ports.count == 28 && s.ports.first?.name == "Gi1/0/1" && s.ports.last?.name == "Gi1/0/28")
        #expect(s.ports.filter { $0.kind == .sfp }.map(\.number) == [25, 26, 27, 28])

        let p1 = try #require(s.port(named: "Gi1/0/1"))
        #expect(p1.mode == .trunk && p1.nativeVlanID == 1 && p1.vlans == ["System-VLAN", "users", "voice", "cameras", "mgmt"])
        #expect(p1.description == "uplink core" && p1.speed == "1G" && p1.lldp.first?.systemName == "SW-CORE-01")
        let p2 = try #require(s.port(named: "Gi1/0/2"))
        #expect(p2.mode == .access && p2.vlans == ["users"] && p2.macs.count == 1)
        let p3 = try #require(s.port(named: "Gi1/0/3"))
        #expect(p3.mode == .trunk && p3.nativeVlanID == 10 && p3.vlans == ["users", "voice"] && p3.speed == "100Mbps")
        let p5 = try #require(s.port(named: "Gi1/0/5"))
        #expect(p5.configDisabled && p5.mode == .access && p5.vlans == ["System-VLAN"])
        // LAG members carry the port-channel's VLANs and its MAC entries.
        let p23 = try #require(s.port(named: "Gi1/0/23"))
        #expect(p23.mode == .trunk && p23.vlans == ["System-VLAN", "users", "voice"] && p23.macs.count == 1)

        guard case let .tplink(state) = s.vendor else { Issue.record("no TP-Link state"); return }
        #expect(state.ports["Gi1/0/4"]?.unusual == true && state.ports["Gi1/0/4"]?.summary == "untagged 1,30 · PVID 30")
        #expect(state.ports["Gi1/0/23"]?.lag == "Po1" && !state.controllerManaged)
        #expect(s.configText.hasPrefix("!SG3428") && !s.configText.contains("#\n#"))
    }

    @Test func speeds() {
        #expect(TPLinkSnapshotBuilder.speedLabel("1000M") == "1G")
        #expect(TPLinkSnapshotBuilder.speedLabel("100M") == "100Mbps")
        #expect(TPLinkSnapshotBuilder.speedLabel("2500M") == "2.5G")
        #expect(TPLinkSnapshotBuilder.speedLabel("10G") == "10G")
    }

    @Test func detection() throws {
        let found = try #require(DeviceDetector.detect(try tplinkFixture("sg3428-show-system-info")))
        #expect(found.platform == .tplinkOmada && found.model == "TL-SG3428" && found.osVersion == "2.0.13 Build 20240417 Rel.62342")
        #expect(found.serial == "TEST00000002" && found.kind == .switchDevice)
        #expect(Platform.tplinkOmada.displayName == "TP-Link Omada")
        // Other platforms' outputs stay theirs.
        #expect(DeviceDetector.detect(try aossFixture("2930m-show-system"))?.platform == .arubaAOSS)
    }
}

@Suite struct TPLinkPlannerTests {
    let snap: SwitchSnapshot

    init() throws {
        L10n.language = .en
        snap = try tplinkSnapshot()
    }

    func plan(_ ports: [PortEdit] = [], _ vlans: [VLANEdit] = [], on s: SwitchSnapshot? = nil) -> ChangePlan {
        TPLinkPlanner.plan(snapshot: s ?? snap, ports: ports, vlans: vlans)
    }

    @Test func nameAndState() {
        #expect(plan([PortEdit(port: "Gi1/0/6", description: "printer", enabled: false)]).changes[0].commands
            == ["interface gigabitEthernet 1/0/6", "  shutdown", "  description \"printer\"", "  exit"])
        #expect(plan([PortEdit(port: "Gi1/0/5", enabled: true)]).changes[0].commands == ["interface gigabitEthernet 1/0/5", "  no shutdown", "  exit"])
        #expect(plan([PortEdit(port: "Gi1/0/2", description: "")]).changes[0].commands == ["interface gigabitEthernet 1/0/2", "  no description", "  exit"])
        #expect(plan([PortEdit(port: "Gi1/0/6", description: "a much too long text")]).changes[0].warnings.count == 1)
        #expect(plan([PortEdit(port: "Gi1/0/6", description: "pc (2)")]).changes[0].warnings.count == 1)
    }

    @Test func membership() {
        #expect(plan([PortEdit(port: "Gi1/0/6", vlans: ["users"])]).changes[0].commands
            == ["interface gigabitEthernet 1/0/6", "  switchport general allowed vlan 10 untagged", "  switchport pvid 10",
                "  no switchport general allowed vlan 1", "  exit"])
        #expect(plan([PortEdit(port: "Gi1/0/2", mode: .trunk, vlans: ["users", "voice"], nativeVlanID: .some(10))]).changes[0].commands
            == ["interface gigabitEthernet 1/0/2", "  switchport general allowed vlan 20 tagged", "  exit"])
        #expect(plan([PortEdit(port: "Gi1/0/3", mode: .access, vlans: ["users"])]).changes[0].commands
            == ["interface gigabitEthernet 1/0/3", "  no switchport general allowed vlan 20", "  exit"])
        // The new untagged VLAN becomes the PVID; the old untagged one stays as tagged.
        #expect(plan([PortEdit(port: "Gi1/0/1", nativeVlanID: .some(99))]).changes[0].commands
            == ["interface gigabitEthernet 1/0/1", "  switchport general allowed vlan 99 untagged", "  switchport pvid 99",
                "  switchport general allowed vlan 1 tagged", "  exit"])
        #expect(plan([PortEdit(port: "Gi1/0/2", vlans: ["users"])]).changes.isEmpty)
    }

    @Test func warnings() throws {
        let unusual = plan([PortEdit(port: "Gi1/0/4", vlans: ["cameras"])]).changes[0]
        #expect(unusual.commands.isEmpty && unusual.warnings.first?.contains("untagged 1,30 · PVID 30") == true)
        let member = plan([PortEdit(port: "Gi1/0/23", vlans: ["users"])]).changes[0]
        #expect(member.commands.isEmpty && member.warnings.first?.contains("Po1") == true)
        #expect(plan([PortEdit(port: "Gi1/0/2", vlans: [])]).changes[0].warnings.contains { $0.contains("at least one VLAN") })
        #expect(plan([PortEdit(port: "Gi1/0/2", vlans: ["users", "voice"])]).changes[0].warnings.contains { $0.contains("only one VLAN") })
        let adopted = try tplinkSnapshot(extraConfig: "\nsdm prefer omada")
        #expect(plan([PortEdit(port: "Gi1/0/6", vlans: ["users"])], on: adopted).changes[0].warnings.contains { $0.contains("Omada controller") })
    }

    @Test func vlans() {
        #expect(plan([], [.add(name: "lab", vlanID: 40, description: nil)]).changes[0].commands == ["vlan 40", "  name \"lab\"", "  exit"])
        #expect(plan([], [.add(name: "a-name-of-17-char", vlanID: 41, description: nil)]).changes[0].warnings.count == 1)
        #expect(plan([], [.add(name: "a&b", vlanID: 42, description: nil)]).changes[0].warnings.count == 1)
        #expect(plan([], [.rename(from: "users", to: "staff")]).changes[0].commands == ["vlan 10", "  name \"staff\"", "  exit"])
        #expect(plan([], [.rename(from: "System-VLAN", to: "base")]).changes[0].warnings.contains { $0.contains("default VLAN") })
        let del = plan([], [.delete(name: "users")]).changes[0]
        #expect(del.commands == ["no vlan 10"] && del.warnings.first?.contains("Gi1/0/2") == true)
        let cams = plan([], [.delete(name: "cameras")]).changes[0]
        #expect(cams.commands == ["no vlan 30"] && cams.warnings.isEmpty)
    }

    @Test func restoreCommands() throws {
        let target = TPLinkParsers.runningConfig(try tplinkFixture("sg3428-running-config"))
        var current = target
        current.vlans[40] = "lab"
        current.vlans[10] = "staff"
        current.interfaces["Gi1/0/6"] = TPLinkInterfaceConfig(description: "x", untagged: [10], removedVLAN1: true, pvid: 10)
        #expect(TPLinkPlanner.restore(from: current, to: target)
            == ["vlan 10", "  name \"users\"", "  exit",
                "interface gigabitEthernet 1/0/6", "  no description", "  switchport general allowed vlan 1 untagged",
                "  switchport pvid 1", "  no switchport general allowed vlan 10", "  exit",
                "no vlan 40"])
        #expect(TPLinkPlanner.restore(from: target, to: target).isEmpty)
    }
}

/// A TP-Link stand-in that keeps a real running configuration: VLANs, general-port membership, PVID,
/// descriptions and `shutdown`, rendered the way the switch prints it (with the pager in the middle).
final class TPLinkFake: Transport, @unchecked Sendable {
    struct Port: Equatable {
        var untagged: Set<Int> = [1]
        var tagged: Set<Int> = []
        var pvid = 1
        var description: String?
        var shutdown = false
    }

    let displayName = "fake-tplink"
    private let lock = NSLock()
    private var onData: (@Sendable (Data) -> Void)?
    private var line = ""
    private var context = "user"
    private var vlans: [Int: String] = [1: "System-VLAN", 10: "users", 20: "voice"]
    private var ports: [Int: Port] = Dictionary(uniqueKeysWithValues: (1...8).map { ($0, Port()) })
    private var startup = ""
    private var restartIn: Int?
    private var question: String?
    private var pagerRest: String?
    private let reject: Set<String>
    private let controller: Bool
    private var log: [String] = []

    init(reject: Set<String> = [], unsaved: Bool = false, controller: Bool = false) {
        self.reject = reject
        self.controller = controller
        ports[2] = Port(untagged: [10], pvid: 10, description: "pc 02")
        startup = render()
        if unsaved { ports[3]?.description = "not saved" }
    }

    var received: [String] { lock.lock(); defer { lock.unlock() }; return log }
    var restartScheduled: Int? { lock.lock(); defer { lock.unlock() }; return restartIn }
    var saved: Bool { lock.lock(); defer { lock.unlock() }; return render() == startup }
    var startupConfig: String { lock.lock(); defer { lock.unlock() }; return startup }

    func open(onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (String?) -> Void) throws {
        lock.lock(); self.onData = onData; lock.unlock()
    }

    func send(_ data: Data) throws {
        var out = ""
        lock.lock()
        // Scalars, not characters: "\r\n" is a single Character.
        for ch in String(decoding: data, as: UTF8.self).unicodeScalars {
            if let rest = pagerRest, ch == " " {
                pagerRest = nil
                out += "\r\u{0}" + String(repeating: " ", count: 37) + "\r\u{0}" + rest
            } else if ch == "\r" {
                out += respond(line)
                line = ""
            } else if ch != "\n" {
                line.unicodeScalars.append(ch)
            }
        }
        let deliver = onData
        lock.unlock()
        if !out.isEmpty { deliver?(Data(out.utf8)) }
    }

    func close() {}

    private var prompt: String {
        switch context {
        case "user": return "SW-EDGE-02>"
        case "priv": return "SW-EDGE-02#"
        case "config": return "SW-EDGE-02(config)#"
        case let c where c.hasPrefix("vlan"): return "SW-EDGE-02(config-vlan)#"
        default: return "SW-EDGE-02(config-if)#"
        }
    }

    /// The running configuration as the switch prints it. Called with the lock held.
    private func render() -> String {
        var l = ["!SG3428", "#"]
        if controller { l += ["sdm prefer omada", "#"] }
        for (id, name) in vlans.sorted(by: { $0.key < $1.key }) { l += ["vlan \(id)", " name \"\(name)\"", "#"] }
        l += ["hostname \"SW-EDGE-02\"", "#"]
        for (n, p) in ports.sorted(by: { $0.key < $1.key }) {
            l.append("interface gigabitEthernet 1/0/\(n)")
            if let d = p.description { l.append("  description \"\(d)\"") }
            if p.shutdown { l.append("  shutdown") }
            let u = p.untagged.subtracting([1])
            if !u.isEmpty { l.append("  switchport general allowed vlan \(TPLinkParsers.vlanListString(Array(u))) untagged") }
            if !p.tagged.isEmpty { l.append("  switchport general allowed vlan \(TPLinkParsers.vlanListString(Array(p.tagged))) tagged") }
            if p.pvid != 1 { l.append("  switchport pvid \(p.pvid)") }
            if !p.untagged.contains(1) && !p.tagged.contains(1) { l.append("  no switchport general allowed vlan 1") }
            l += ["  ", "#"]
        }
        l.append("end")
        return l.joined(separator: "\r\n")
    }

    /// Prints a configuration with the pager after its fifth line, as the switch does on a long one.
    private func paged(_ text: String) -> String {
        let lines = text.components(separatedBy: "\r\n")
        pagerRest = lines.dropFirst(5).joined(separator: "\r\n") + "\r\n\r\n" + prompt
        return lines.prefix(5).joined(separator: "\r\n") + "\r\nPress any key to continue (Q to quit)"
    }

    private func port(_ c: String) -> Int? {
        CiscoParsers.capture(#"gigabitEthernet 1/0/(\d+)$"#, in: c).flatMap { Int($0[0]) }
    }

    /// Called with the lock held.
    private func respond(_ command: String) -> String {
        log.append(command)
        let c = command.trimmingCharacters(in: .whitespaces)
        var body = ""
        if let q = question {
            question = nil
            if q.hasPrefix("reboot-schedule in "), c == "Y" { restartIn = Int(q.dropFirst("reboot-schedule in ".count)) }
            return command + "\r\n" + prompt
        }
        if reject.contains(c) {
            return command + "\r\nError: Bad command\r\n" + prompt
        }
        switch (context, c) {
        case ("user", "enable"): context = "priv"
        case (_, "show system-info"):
            body = " System Description   - JetStream 8-Port Gigabit L2+ Managed Switch\r\n System Name          - SW-EDGE-02\r\n Hardware Version     - TL-SG3428 2.0\r\n Software Version     - 2.0.13 Build 20240417 Rel.62342\r\n"
        case ("priv", "show running-config"): return command + "\r\n" + paged(render())
        case ("priv", "show startup-config"): return command + "\r\n" + paged(startup)
        case ("priv", "configure"):
            if controller { body = "Operation Fail. This command can't work in controller mode.\r\n" } else { context = "config" }
        case ("priv", "copy running-config startup-config"):
            startup = render()
            body = "Saving user config, please wait...\r\n"
        case ("priv", "logout"): return command + "\r\n"
        case (let x, "end") where x != "user" && x != "priv": context = "priv"
        case ("config", let x) where x.hasPrefix("reboot-schedule in "):
            question = x
            return command + "\r\n Reboot system in \(x.dropFirst("reboot-schedule in ".count)) minutes. Continue? (Y/N):"
        case ("config", "reboot-schedule cancel"): restartIn = nil; body = " Reboot schedule is cancelled.\r\n"
        case ("config", let x) where x.hasPrefix("vlan "):
            guard let id = Int(x.dropFirst(5)) else { break }
            if vlans[id] == nil { vlans[id] = String(format: "VLAN%04d", id) }
            context = "vlan\(id)"
        case ("config", let x) where x.hasPrefix("no vlan "):
            if let id = Int(x.dropFirst(8)) {
                vlans[id] = nil
                for k in ports.keys { ports[k]?.untagged.remove(id); ports[k]?.tagged.remove(id) }
            }
        case ("config", let x) where x.hasPrefix("interface "):
            if let n = port(x) { context = "if\(n)" } else { body = "Error: Invalid port number.\r\n" }
        case (let v, let x) where v.hasPrefix("vlan") && x.hasPrefix("name "):
            if let id = Int(v.dropFirst(4)) { vlans[id] = x.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        case (let v, "exit") where v.hasPrefix("vlan") || v.hasPrefix("if"): context = "config"
        case (let i, let x) where i.hasPrefix("if"):
            guard let n = Int(i.dropFirst(2)) else { break }
            if x == "shutdown" { ports[n]?.shutdown = true }
            else if x == "no shutdown" { ports[n]?.shutdown = false }
            else if x == "no description" { ports[n]?.description = nil }
            else if x.hasPrefix("description ") { ports[n]?.description = x.dropFirst(12).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            else if let m = CiscoParsers.capture(#"^switchport general allowed vlan ([\d,\-]+) (untagged|tagged)$"#, in: x) {
                let ids = TPLinkParsers.vlanList(m[0])
                if ids.contains(where: { vlans[$0] == nil }) { body = "Error: Invalid parameter.\r\n"; break }
                for id in ids {
                    if m[1] == "untagged" { ports[n]?.untagged.insert(id); ports[n]?.tagged.remove(id) }
                    else { ports[n]?.tagged.insert(id); ports[n]?.untagged.remove(id) }
                }
            } else if let m = CiscoParsers.capture(#"^no switchport general allowed vlan ([\d,\-]+)$"#, in: x) {
                for id in TPLinkParsers.vlanList(m[0]) { ports[n]?.untagged.remove(id); ports[n]?.tagged.remove(id) }
            } else if let m = CiscoParsers.capture(#"^switchport pvid (\d+)$"#, in: x), let id = Int(m[0]) {
                ports[n]?.pvid = id
            } else {
                body = "Error: Bad command\r\n"
            }
        case (_, ""): break
        default: body = "Error: Bad command\r\n"
        }
        return command + "\r\n" + body + "\r\n" + prompt
    }
}

@Suite struct TPLinkDriverTests {
    let plan = ChangePlan(changes: [PlannedChange(kind: .port, subject: "Gi1/0/5", summary: "",
                                                  commands: ["interface gigabitEthernet 1/0/5", "  description \"cam 05\"",
                                                             "  switchport general allowed vlan 10 untagged", "  switchport pvid 10",
                                                             "  no switchport general allowed vlan 1", "  exit"])])

    init() { L10n.language = .en }

    @Test func appliesUnderTheRestartTimerAndSavesOnlyAfterConfirm() async throws {
        let sw = TPLinkFake()
        let driver = TPLinkDriver(transport: sw)
        try await driver.connect(username: "admin", password: nil)
        let r = try await driver.apply(plan, confirmMinutes: 5, comment: "c")
        #expect(r.confirmMinutes == 5 && sw.restartScheduled == 5 && !sw.saved)
        let sent = sw.received
        let compare = try #require(sent.firstIndex(of: "show startup-config"))
        let arm = try #require(sent.firstIndex(of: "reboot-schedule in 5"))
        let first = try #require(sent.firstIndex(of: "interface gigabitEthernet 1/0/5"))
        #expect(compare < arm && sent[arm + 1] == "Y" && arm < first)
        #expect(sent.contains("description \"cam 05\"") && !sent.contains("  description \"cam 05\""))
        #expect(!sent.contains("copy running-config startup-config"))

        try await driver.confirm(comment: "c")
        let after = sw.received
        let cancel = try #require(after.lastIndex(of: "reboot-schedule cancel"))
        let save = try #require(after.lastIndex(of: "copy running-config startup-config"))
        #expect(cancel < save && sw.restartScheduled == nil && sw.saved && sw.startupConfig.contains("cam 05"))
        await #expect(throws: DriverError.nothingPending) { try await driver.confirm(comment: "again") }
    }

    @Test func unsavedChangesStopTheChange() async throws {
        let sw = TPLinkFake(unsaved: true)
        let driver = TPLinkDriver(transport: sw)
        try await driver.connect(username: "admin", password: nil)
        do {
            _ = try await driver.apply(plan, confirmMinutes: 5, comment: "c")
            Issue.record("apply should have failed")
        } catch let DriverError.safetyNetUnavailable(why) {
            #expect(why.contains("aren't saved"))
        }
        #expect(!sw.received.contains("configure") && sw.restartScheduled == nil)
    }

    @Test func refusedFirstCommandCancelsTheRestart() async throws {
        let sw = TPLinkFake(reject: ["interface gigabitEthernet 1/0/5"])
        let driver = TPLinkDriver(transport: sw)
        try await driver.connect(username: "admin", password: nil)
        do {
            _ = try await driver.apply(plan, confirmMinutes: 5, comment: "c")
            Issue.record("apply should have failed")
        } catch let DriverError.rejected(lines) {
            #expect(lines.count == 1 && lines[0].contains("Bad command"))
        }
        #expect(sw.restartScheduled == nil && sw.saved && sw.received.contains("reboot-schedule cancel"))
    }

    @Test func refusedLaterCommandIsUndoneWithoutRestart() async throws {
        let withVLAN = ChangePlan(changes: [
            PlannedChange(kind: .vlan, subject: "lab", summary: "", commands: ["vlan 40", "  name \"lab\"", "  exit"]),
            PlannedChange(kind: .port, subject: "Gi1/0/5", summary: "",
                          commands: ["interface gigabitEthernet 1/0/5", "  switchport general allowed vlan 40 untagged",
                                     "  switchport pvid 40", "  exit"]),
        ])
        let sw = TPLinkFake(reject: ["switchport pvid 40"])
        let driver = TPLinkDriver(transport: sw)
        try await driver.connect(username: "admin", password: nil)
        do {
            _ = try await driver.apply(withVLAN, confirmMinutes: 5, comment: "c")
            Issue.record("apply should have failed")
        } catch let DriverError.rejected(lines) {
            #expect(lines.count == 1)
        }
        let sent = sw.received
        #expect(sent.contains("no switchport general allowed vlan 40") && sent.contains("no vlan 40"))
        #expect(sw.saved && sw.restartScheduled == nil && !sent.contains("copy running-config startup-config"))
    }

    @Test func undoNowWithoutRestart() async throws {
        let sw = TPLinkFake()
        let driver = TPLinkDriver(transport: sw)
        try await driver.connect(username: "admin", password: nil)
        _ = try await driver.apply(plan, confirmMinutes: 3, comment: "c")
        #expect(sw.restartScheduled == 3)
        try await driver.revertPending(expectedComment: "c")
        #expect(sw.saved && sw.restartScheduled == nil && !sw.received.contains("copy running-config startup-config"))
        await #expect(throws: DriverError.nothingPending) { try await driver.revertPending(expectedComment: "c") }
    }

    @Test func controllerManagedSwitchIsReadOnly() async throws {
        let sw = TPLinkFake(controller: true)
        let driver = TPLinkDriver(transport: sw)
        try await driver.connect(username: "admin", password: nil)
        do {
            _ = try await driver.apply(plan, confirmMinutes: 5, comment: "c")
            Issue.record("apply should have failed")
        } catch let DriverError.safetyNetUnavailable(why) {
            #expect(why.contains("Omada controller"))
        }
        #expect(!sw.received.contains { $0.hasPrefix("reboot-schedule") })
    }

    @Test func readsThroughThePager() async throws {
        let sw = TPLinkFake()
        let driver = TPLinkDriver(transport: sw)
        try await driver.connect(username: "admin", password: nil)
        guard case let .network(s) = try await driver.read(progress: { _ in }) else { Issue.record("not a switch"); return }
        #expect(s.ports.count == 8 && s.port(named: "Gi1/0/2")?.vlans == ["users"] && s.port(named: "Gi1/0/2")?.description == "pc 02")
        #expect(s.config.vlans.map(\.name) == ["System-VLAN", "users", "voice"])
    }

    @Test func ciscoHandsOverFromSystemInfo() async throws {
        // "SW-EDGE-02>" looks like IOS; the Cisco driver finds no `show version` and hands over.
        let cisco = CiscoDriver(transport: TPLinkFake())
        do {
            try await cisco.connect(username: "admin", password: nil)
            Issue.record("connect should have handed over")
        } catch let CLIError.unrecognizedPrompt(text) {
            #expect(DeviceDetector.detect(text)?.platform == .tplinkOmada)
        }
    }
}
