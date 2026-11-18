import Foundation
import Testing
@testable import NetdeckCore

/// Synthetic FortiGate captures (see Fixtures/synthetic/fortios/README.md), stripped the way `CLISession` strips live output.
func fortiFixture(_ name: String) throws -> String {
    L10n.language = .en
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/synthetic/fortios"))
    return CLISession.strip(try String(contentsOf: url, encoding: .utf8), dialect: FortiOSDialect())
}

func fortiOutputs(extraConfig: String = "") throws -> FortiOSSnapshot.Outputs {
    var o = FortiOSSnapshot.Outputs()
    o.status = try fortiFixture("fgt60f-get-system-status")
    o.physical = try fortiFixture("fgt60f-interface-physical")
    o.config = try fortiFixture("fgt60f-show") + extraConfig
    o.arp = try fortiFixture("fgt60f-get-system-arp")
    return o
}

@Suite struct FortiOSDialectTests {
    let d = FortiOSDialect()

    @Test func promptKinds() {
        #expect(d.prompt("FW-BRANCH-01 # ") == .operational)
        #expect(d.prompt("FGT60FTEST000001 #") == .operational)
        #expect(d.prompt("fw-01 $ ") == .operational)
        #expect(d.prompt("FW-BRANCH-01 (global) # ") == .configuration)
        #expect(d.prompt("FW-BRANCH-01 (interface) # ") == .configuration)
        #expect(d.prompt("--More-- ") == .pager)
        #expect(d.prompt("FortiGate-60F login: ") == .login)
        #expect(d.prompt("Password: ") == .password)
        #expect(d.prompt("Do you want to continue? (y/n)") == .question)
        #expect(d.prompt("Switch#") == nil)
        #expect(d.prompt("root@host:~#") == nil)
        #expect(d.prompt("        status: up") == nil)
        #expect(d.prompt("#config-version=FGT60F-7.4.8") == nil)
    }

    @Test func contextsAndLeaving() {
        #expect(FortiOSDialect.context("FW-BRANCH-01 (global) # ") == "global")
        #expect(FortiOSDialect.context("FW-BRANCH-01 # ") == nil)
        // `config global` holds no edits: `end`. Any other context (left on a console): `abort`, which saves nothing.
        #expect(d.logout(from: .configuration, line: "FW-BRANCH-01 (global) # ") == "end\r")
        #expect(d.logout(from: .configuration, line: "FW-BRANCH-01 (wan1) # ") == "abort\r")
        #expect(d.advance(from: .configuration) == "abort\r")
        #expect(d.logout(from: .operational, line: "FW-BRANCH-01 # ") == "exit\r")
        #expect(d.logout(from: .question) == "n")
        #expect(d.setupCommands.isEmpty)
    }

    @Test func answeredPagerIsTakenOut() {
        let raw = "FW-BRANCH-01 # get system arp\r\nAddress           Age(min)   Hardware Addr      Interface\r\n--More-- "
            + "\r          \r198.51.100.1      0          00:00:5e:00:53:01 wan1\r\n\r\nFW-BRANCH-01 # "
        #expect(CLISession.strip(raw, dialect: d)
            == "Address           Age(min)   Hardware Addr      Interface\n198.51.100.1      0          00:00:5e:00:53:01 wan1")
        // Taken back with backspaces instead.
        let backspaced = "FW # show\r\nconfig system global\r\n--More-- " + String(repeating: "\u{8}", count: 9) + "    set hostname \"FW\"\r\nend\r\nFW # "
        #expect(CLISession.strip(backspaced, dialect: d) == "config system global\n    set hostname \"FW\"\nend")
        // Not answered yet: the pager stays the last line, so the session answers it.
        let waiting = d.normalize("config system global\r\n--More-- ")
        #expect(d.prompt(CLISession.lastLine(of: JunosCLI.clean(waiting))) == .pager)
    }

    @Test func errors() {
        #expect(d.errors(in: "command parse error before 'virtual-switch'\nCommand fail. Return code -61").count == 2)
        #expect(d.errors(in: "Unknown action 0").count == 1)
        #expect(d.errors(in: "Address  Age(min)  Hardware Addr  Interface").isEmpty)
        #expect(FortiOSDriver.refused("Command fail. Return code -61"))
        // A configuration that only quotes such words further down is not a refusal.
        #expect(!FortiOSDriver.refused("config system global\n    set hostname \"FW\"\nend\nconfig firewall policy\n    edit 1\n        set comments \"Command fail.\"\n    next\nend"))
    }
}

@Suite struct FortiOSParserTests {
    @Test func status() throws {
        let text = try fortiFixture("fgt60f-get-system-status")
        #expect(FortiOSParsers.isFortiGate(text))
        let s = FortiOSParsers.status(text)
        #expect(s.model == "FortiGate-60F" && s.version == "7.4.8" && s.build == "2795")
        #expect(s.serial == "FGT60FTEST000001" && s.hostname == "FW-BRANCH-01")
        #expect(!s.vdoms && s.haMode == "standalone" && s.operationMode == "NAT")
        #expect(FortiOSParsers.status(text.replacingOccurrences(of: "configuration: disable", with: "configuration: multiple")).vdoms)
        #expect(FortiOSParsers.status("Version: FortiWiFi-40F v7.2.10,build1706,240918 (GA.M)").model == "FortiWiFi-40F")
        #expect(!FortiOSParsers.isFortiGate("Cisco IOS Software, Version 15.2"))
        #expect(FortiOSParsers.isLoginBanner("\r\nFortiGate-60F login: "))
    }

    @Test func physicalPorts() throws {
        let ports = FortiOSParsers.physical(try fortiFixture("fgt60f-interface-physical"))
        #expect(ports.map(\.name) == ["dmz", "wan1", "wan2", "internal1", "internal2", "internal3", "internal4", "internal5", "a", "b", "npu0_vlink0"])
        let wan1 = try #require(ports.first { $0.name == "wan1" })
        #expect(wan1.linkUp && wan1.speed == "1000Mbps" && wan1.duplex == "full")
        let dmz = try #require(ports.first { $0.name == "dmz" })
        #expect(!dmz.linkUp && dmz.speed == nil)
    }

    @Test func interfaceTables() throws {
        let config = try fortiFixture("fgt60f-show")
        let all = FortiOSParsers.interfaces(config)
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        #expect(byName["dmz"]?.address == "192.0.2.129/26" && byName["dmz"]?.type == "physical")
        #expect(byName["wan1"]?.mode == "dhcp" && byName["wan1"]?.alias == "ISP A" && byName["wan1"]?.addressText == "dhcp")
        #expect(byName["wan2"]?.down == true && byName["wan2"]?.description == "Spare uplink, \"backup\" ISP")
        // The nested `config ipv6` of the hard switch doesn't touch its own settings.
        #expect(byName["internal"]?.type == "hard-switch" && byName["internal"]?.address == "192.0.2.1/26")
        #expect(byName["fortilink"]?.members == ["a", "b"] && byName["fortilink"]?.type == "aggregate")
        #expect(byName["vlan20"]?.isVLAN == true && byName["vlan20"]?.parent == "internal" && byName["vlan20"]?.vlanID == 20)
        #expect(byName["guest"]?.vlanID == 30 && byName["guest"]?.address == nil)
        #expect(byName["ssl.root"]?.type == "tunnel")
        #expect(all.count == 16)
        #expect(FortiOSParsers.virtualSwitches(config) == ["internal": ["internal1", "internal2", "internal3", "internal4", "internal5"]])
        #expect(FortiOSParsers.zones(config) == ["LAN": ["internal", "vlan20"]])
        #expect(FortiOSParsers.softwareSwitches(config).isEmpty)
        // The policy table is read the same way; its comment is just a value.
        #expect(FortiOSParsers.table("firewall policy", in: config).first?.value("comments") == "Command fail. is only a comment here")
    }

    @Test func tokens() {
        #expect(FortiOSParsers.tokens(#"        set member "a" "b""#) == ["set", "member", "a", "b"])
        #expect(FortiOSParsers.tokens(#"set description "say \"hi\" \\ bye""#) == ["set", "description", "say \"hi\" \\ bye"])
        #expect(FortiOSParsers.tokens(#"set alias """#) == ["set", "alias", ""])
        #expect(FortiOSParsers.cidr("192.0.2.1", "255.255.255.0") == "192.0.2.1/24")
        #expect(FortiOSParsers.cidr("0.0.0.0", "0.0.0.0") == nil)
    }

    @Test func arpTables() throws {
        let arp = FortiOSParsers.arp(try fortiFixture("fgt60f-get-system-arp"))
        #expect(arp.count == 6)
        #expect(arp.first == FortiOSARPEntry(ip: "198.51.100.1", mac: "00:00:5e:00:53:01", interface: "wan1"))
        #expect(!arp.contains { $0.mac == "00:00:00:00:00:00" })
        let diag = FortiOSParsers.arp(try fortiFixture("fgt-vdom-diagnose-arp"))
        #expect(diag.map(\.interface) == ["wan1", "internal", "isp-mgmt"])
    }
}

@Suite struct FortiOSSnapshotTests {
    init() { L10n.language = .en }

    @Test func portsCarryWhatRidesOnThem() throws {
        let s = FortiOSSnapshot.build(try fortiOutputs())
        #expect(s.platform == .fortinetFortiOS && s.kind == .firewall)
        #expect(s.model == "FortiGate-60F" && s.osVersion == "7.4.8" && s.hostname == "FW-BRANCH-01")
        #expect(s.hardware.serial == "FGT60FTEST000001")
        #expect(s.ports.map(\.name) == ["dmz", "wan1", "wan2", "internal1", "internal2", "internal3", "internal4", "internal5", "a", "b"])

        let wan1 = try #require(s.port(named: "wan1"))
        #expect(wan1.description == "ISP A" && wan1.linkUp && wan1.speed == "1G")
        #expect(wan1.addresses == ["dhcp", "203.0.113.2/29 (isp-mgmt · VLAN 7)"] && wan1.isRouted)
        // Its own neighbour and the one on the VLAN riding on it.
        #expect(wan1.macs.map(\.mac) == ["00:00:5e:00:53:01", "00:00:5e:00:53:07"])

        let i1 = try #require(s.port(named: "internal1"))
        #expect(i1.description == "srv-01" && i1.zone == "LAN")
        #expect(i1.addresses == ["192.0.2.1/26 (internal)", "192.0.2.65/26 (vlan20 · VLAN 20)"])
        // Five ports share the hardware switch: the firewall can't tell which one a neighbour is on.
        #expect(i1.macs.isEmpty)
        #expect(s.port(named: "internal2")?.speed == "100Mbps")

        let a = try #require(s.port(named: "a"))
        #expect(a.addresses == ["192.0.2.193/26 (fortilink)"] && a.macs.isEmpty)
        let wan2 = try #require(s.port(named: "wan2"))
        #expect(wan2.configDisabled && wan2.state == .disabled && wan2.description == "Spare uplink, \"backup\" ISP")
        #expect(s.port(named: "dmz")?.addresses == ["192.0.2.129/26"])

        // A firewall, not a switch: no VLAN rooms, no MAC table, nothing to change.
        #expect(!s.hasSwitching && s.macTable.isEmpty && s.config.vlans.isEmpty)
        #expect(!s.changeTraits.canChange)
        #expect(s.configText.contains("config system interface"))
        #expect(Planner.plan(snapshot: s, ports: [PortEdit(port: "wan1", description: "x")], vlans: []).isEmpty)
    }

    @Test func softwareSwitchWithOnePortPlacesItsNeighbours() throws {
        let extra = "\nconfig system switch-interface\n    edit \"lab\"\n        set vdom \"root\"\n        set member \"dmz\"\n    next\nend\n"
        var o = try fortiOutputs(extraConfig: extra)
        o.arp += "\n192.0.2.150       0          00:00:5e:00:53:50 lab"
        let s = FortiOSSnapshot.build(o)
        let dmz = try #require(s.port(named: "dmz"))
        #expect(dmz.macs.map(\.mac) == ["00:00:5e:00:53:50"])
    }

    @Test func withoutTheConfigurationThePhysicalListStillShowsPorts() throws {
        var o = try fortiOutputs()
        o.config = ""
        let s = FortiOSSnapshot.build(o)
        #expect(s.ports.count == 10 && s.port(named: "wan1")?.linkUp == true)
        #expect(FortiOSSnapshot.speedLabel("10000Mbps") == "10G" && FortiOSSnapshot.speedLabel("2500Mbps") == "2.5G")
        #expect(FortiOSSnapshot.isCage("x1") && !FortiOSSnapshot.isCage("wan1"))
    }

    @MainActor
    @Test func sessionStagesNothing() throws {
        let s = FortiOSSnapshot.build(try fortiOutputs())
        let profile = DeviceProfile(id: "fw", name: "fw", connection: .serial(path: "/dev/null", baud: 9600), username: "admin")
        let session = DeviceSession(profile: profile, snapshot: s)
        #expect(!session.canStage)
        session.stage(PortEdit(port: "wan1", description: "changed"))
        session.stage(.add(name: "vlan-10", vlanID: 10, description: nil))
        #expect(session.pendingChangeCount == 0 && session.edit(for: "wan1") == nil)
    }
}

@Suite struct FortiOSDetectionTests {
    @Test func recognisedFromStatusAndPrompt() throws {
        let d = try #require(DeviceDetector.detect(try fortiFixture("fgt60f-get-system-status")))
        #expect(d.platform == .fortinetFortiOS && d.model == "FortiGate-60F" && d.osVersion == "7.4.8")
        #expect(d.kind == .firewall && d.hostname == "FW-BRANCH-01" && d.serial == "FGT60FTEST000001")
        #expect(d.summary == "Fortinet FortiGate-60F · FortiOS 7.4.8")
        #expect(DeviceDetector.foreignPrompt("FW-BRANCH-01 #") == .fortinetFortiOS)
        #expect(DeviceDetector.foreignPrompt("FW-BRANCH-01 (global) #") == .fortinetFortiOS)
        #expect(DeviceDetector.foreignPrompt("Switch#") == .ciscoIOS)
        #expect(DeviceDetector.detect("\r\nFW-BRANCH-01 # ")?.platform == .fortinetFortiOS)
        #expect(DeviceDetector.detect("FortiGate-60F login: ")?.platform == .fortinetFortiOS)
    }

    @Test func catalog() {
        let p = Platform.fortinetFortiOS
        #expect(p.vendor == "Fortinet" && p.osName == "FortiOS" && p.kinds == [.firewall])
        #expect(p.exportsConfig && !p.isAppliance && p.connections == [.serial, .ssh])
        #expect(p.changeTraits == .readOnly)
        #expect(DriverFactory.supports(p, over: .ssh) && DriverFactory.supports(p, over: .serial) && !DriverFactory.supports(p, over: .api))
    }
}

/// A FortiGate CLI: the prompt, `config global` with virtual domains, the `--More--` pager every 25 lines
/// (taken back with CR, blanks, CR), and errors for anything it doesn't know.
final class FortiFake: Transport, @unchecked Sendable {
    let displayName = "fake-fortigate"
    private let lock = NSLock()
    private var onData: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable (String?) -> Void)?
    private var line = ""
    private var global = false
    private var pagerRest: [String]?
    private let vdoms: Bool
    private var log: [String] = []
    private var closed = false
    private let outputs: [String: String]

    init(vdoms: Bool = false) throws {
        self.vdoms = vdoms
        var status = try fortiFixture("fgt60f-get-system-status")
        if vdoms { status = status.replacingOccurrences(of: "configuration: disable", with: "configuration: multiple") }
        outputs = [
            "get system status": status,
            "get system interface physical": try fortiFixture("fgt60f-interface-physical"),
            "get system arp": try fortiFixture("fgt60f-get-system-arp"),
            "diagnose ip arp list": try fortiFixture("fgt-vdom-diagnose-arp"),
            "show": try fortiFixture("fgt60f-show"),
        ]
    }

    var received: [String] { lock.lock(); defer { lock.unlock() }; return log }
    var loggedOut: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func open(onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (String?) -> Void) throws {
        lock.lock(); self.onData = onData; self.onClose = onClose; lock.unlock()
    }

    func send(_ data: Data) throws {
        var out = ""
        lock.lock()
        for ch in String(decoding: data, as: UTF8.self).unicodeScalars {
            if let rest = pagerRest, ch == " " {
                pagerRest = nil
                out += "\r          \r" + page(rest)
            } else if ch == "\r" {
                out += respond(line)
                line = ""
            } else if ch != "\n" {
                line.unicodeScalars.append(ch)
            }
        }
        let deliver = onData
        let close = closed ? onClose : nil
        lock.unlock()
        if !out.isEmpty { deliver?(Data(out.utf8)) }
        close?("closed")
    }

    func close() {}

    private var prompt: String { global ? "FW-BRANCH-01 (global) # " : "FW-BRANCH-01 # " }

    /// Up to 25 lines, then the pager; the rest waits for a space. Called with the lock held.
    private func page(_ lines: [String]) -> String {
        guard lines.count > 25 else { return lines.joined(separator: "\r\n") + "\r\n\r\n" + prompt }
        pagerRest = Array(lines.dropFirst(25))
        return lines.prefix(25).joined(separator: "\r\n") + "\r\n--More-- "
    }

    /// Called with the lock held.
    private func respond(_ cmd: String) -> String {
        if !cmd.isEmpty { log.append(cmd) }
        let echo = cmd + "\r\n"
        var body: String
        switch cmd {
        case "": return "\r\n" + prompt
        case "exit":
            closed = true
            return echo
        case "config global":
            guard vdoms else { body = "command parse error before 'global'\nCommand fail. Return code -61"; break }
            global = true
            return echo + prompt
        case "end":
            global = false
            return echo + prompt
        case "get system interface physical", "diagnose ip arp list":
            // With virtual domains these only work in the global context.
            guard !vdoms || global, cmd != "diagnose ip arp list" || vdoms else {
                body = "Command fail. Return code -61"
                break
            }
            body = outputs[cmd] ?? ""
        case "get system arp":
            body = vdoms ? "command parse error before 'arp'\nCommand fail. Return code -61" : outputs[cmd] ?? ""
        default:
            body = outputs[cmd] ?? "command parse error before '\(cmd)'\nCommand fail. Return code -61"
        }
        return echo + page(body.components(separatedBy: "\n"))
    }
}

@Suite struct FortiOSDriverTests {
    init() { L10n.language = .en }

    static let readCommands: Set<String> = ["get system status", "get system interface physical", "get system arp",
                                            "diagnose ip arp list", "show", "config global", "end", "exit"]

    @Test func readsThroughThePagerWithShowCommandsOnly() async throws {
        let fw = try FortiFake()
        let driver = FortiOSDriver(transport: fw)
        try await driver.connect(username: "admin", password: nil)
        guard case let .network(s) = try await driver.read(progress: { _ in }) else {
            Issue.record("expected a network reading")
            return
        }
        #expect(s.ports.count == 10 && s.port(named: "wan1")?.macs.count == 2)
        // The configuration came through several pages without "--More--" left in it.
        #expect(s.configText.contains("config system virtual-switch") && !s.configText.contains("--More--"))
        #expect(s.port(named: "internal1")?.zone == "LAN")
        let sent = fw.received
        #expect(Set(sent).isSubset(of: Self.readCommands))
        #expect(!sent.contains("config global"))

        await #expect(throws: DriverError.notSupported) { try await driver.apply(ChangePlan(changes: []), confirmMinutes: 5, comment: "c") }
        await #expect(throws: DriverError.notSupported) { try await driver.confirm(comment: "c") }
        await driver.disconnect()
        #expect(fw.received.last == "exit" && fw.loggedOut)
    }

    @Test func virtualDomainsAreReadInsideConfigGlobal() async throws {
        let fw = try FortiFake(vdoms: true)
        let driver = FortiOSDriver(transport: fw)
        try await driver.connect(username: "admin", password: nil)
        guard case let .network(s) = try await driver.read(progress: { _ in }) else {
            Issue.record("expected a network reading")
            return
        }
        #expect(s.ports.count == 10 && s.port(named: "wan1")?.macs.map(\.mac) == ["00:00:5e:00:53:01", "00:00:5e:00:53:07"])
        let sent = fw.received
        let enter = try #require(sent.firstIndex(of: "config global"))
        let physical = try #require(sent.firstIndex(of: "get system interface physical"))
        let arp = try #require(sent.firstIndex(of: "diagnose ip arp list"))
        let leave = try #require(sent.firstIndex(of: "end"))
        let show = try #require(sent.firstIndex(of: "show"))
        #expect(enter < physical && physical < arp && arp < leave && leave < show)
        #expect(!sent.contains("get system arp") && Set(sent).isSubset(of: Self.readCommands))
        await driver.disconnect()
        #expect(fw.loggedOut)
    }

    @Test func anotherVendorIsNotTakenForAFortiGate() async throws {
        let fake = ScriptedCLI(prompt: "FW-BRANCH-01 # ", answers: ["get system status": "Cisco IOS Software, Version 15.2"])
        let driver = FortiOSDriver(transport: fake)
        await #expect(throws: DriverError.notSupported) { try await driver.connect(username: "admin", password: nil) }
    }
}

/// A minimal CLI answering fixed commands at a fixed prompt.
final class ScriptedCLI: Transport, @unchecked Sendable {
    let displayName = "scripted"
    private let lock = NSLock()
    private var onData: (@Sendable (Data) -> Void)?
    private var line = ""
    private let prompt: String
    private let answers: [String: String]

    init(prompt: String, answers: [String: String]) {
        self.prompt = prompt
        self.answers = answers
    }

    func open(onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (String?) -> Void) throws {
        lock.lock(); self.onData = onData; lock.unlock()
    }

    func send(_ data: Data) throws {
        var out = ""
        lock.lock()
        for ch in String(decoding: data, as: UTF8.self).unicodeScalars {
            if ch == "\r" {
                out += line.isEmpty ? "\r\n" + prompt : line + "\r\n" + (answers[line] ?? "") + "\r\n" + prompt
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
}
