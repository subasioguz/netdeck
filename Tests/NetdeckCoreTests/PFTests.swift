import Foundation
import Testing
@testable import NetdeckCore

/// Synthetic pfSense / OPNsense output (see Fixtures/synthetic/pfsense/README.md): command output only, no echo or prompt.
func pfFixture(_ name: String, ext: String = "txt") throws -> String {
    L10n.language = .en
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/synthetic/pfsense"))
    return try String(contentsOf: url, encoding: .utf8)
}

func pfOutputs(_ system: String) throws -> PFSnapshot.Outputs {
    var o = PFSnapshot.Outputs()
    o.identity = try pfFixture("\(system)-identity")
    o.ifconfig = try pfFixture("\(system)-ifconfig")
    o.arp = try pfFixture("\(system)-arp")
    o.config = try pfFixture("\(system)-config", ext: "xml")
    return o
}

@Suite struct PFDialectTests {
    let d = PFDialect()

    @Test func promptKinds() {
        #expect(d.prompt("NETDECK> ") == .operational)
        #expect(d.prompt("Enter an option: ") == .question)
        #expect(d.prompt("[2.7.2-RELEASE][admin@fw-edge.home.arpa]/root: ") == .shell)
        #expect(d.prompt("[24.11-RELEASE][admin@fw.home.arpa]/root:") == .shell)
        #expect(d.prompt("root@OPNsense:~ # ") == .shell)
        #expect(d.prompt("netops@fw-core:~ % ") == .shell)
        #expect(d.prompt("$ ") == .shell)
        #expect(d.prompt("login: ") == .login)
        #expect(d.prompt("Password:") == .password)
        #expect(d.prompt("Do you want to proceed [y/n]?") == nil)
        #expect(d.prompt("Proceed? [y/n]") == .question)
        #expect(d.prompt("\tstatus: active") == nil)
        #expect(d.prompt(" 8) Shell") == nil)
    }

    @Test func menuIsLeftOnlyThroughTheShellEntryOnScreen() throws {
        let pf = try pfFixture("pfsense-login-menu")
        let opn = try pfFixture("opnsense-login-menu")
        #expect(PFDialect.menuOption("Shell", on: pf) == "8")
        #expect(PFDialect.menuOption("Shell", on: opn) == "8")
        #expect(PFDialect.menuOption("Logout", on: opn) == "0")
        #expect(d.advance(from: .question, screen: pf) == "8\r")
        #expect(d.advance(from: .question, screen: opn) == "8\r")
        // Wherever the entry is, its own number; none, or two: nothing at all.
        let moved = pf.replacingOccurrences(of: " 8) Shell", with: " 8) Something else\n17) Shell")
        #expect(d.advance(from: .question, screen: moved) == "17\r")
        #expect(d.advance(from: .question, screen: pf.replacingOccurrences(of: " 8) Shell", with: " 8) Console")) == nil)
        #expect(d.advance(from: .question, screen: pf + "\n 9) Shell\n\nEnter an option: ") == nil)
        // "PHP shell" doesn't count, and a question that isn't the menu is never answered during login.
        #expect(PFDialect.menuOption("Shell", on: "12) PHP shell + pfSense tools") == nil)
        #expect(d.advance(from: .question, screen: " 8) Shell\nReset to factory defaults? (y/n)") == nil)
        // From any shell, Netdeck's own /bin/sh.
        #expect(d.advance(from: .shell, screen: "root@OPNsense:~ # ") == PFDialect.shellCommand + "\r")
    }

    @Test func loggingOutWalksBack() {
        #expect(d.logout(from: .operational, line: "NETDECK> ") == "exit\r")
        #expect(d.logout(from: .shell, line: "root@OPNsense:~ # ") == "exit\r")
        #expect(d.logout(from: .question, line: "Enter an option: ") == "0\r")
        #expect(d.logout(from: .question, line: "Proceed? [y/n]") == "n\r")
    }
}

@Suite struct PFParserTests {
    @Test func identity() throws {
        let pf = PFParsers.identity(try pfFixture("pfsense-identity"))
        #expect(pf.platform == .pfsense && pf.version == "2.7.2-RELEASE" && pf.hostname == "fw-edge.home.arpa")
        // SMBIOS placeholders are no model or serial.
        #expect(pf.model == nil && pf.serial == nil)
        let opn = PFParsers.identity(try pfFixture("opnsense-identity"))
        #expect(opn.platform == .opnsense && opn.version == "25.1.5_5" && opn.model == "DEC740" && opn.serial == "TEST0001")
        #expect(PFParsers.identity("platform=\nversion=\nopnsense=\nhostname=x").platform == nil)
    }

    @Test func ifconfig() throws {
        let all = PFParsers.ifconfig(try pfFixture("pfsense-ifconfig"))
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        #expect(all.filter(PFParsers.isPort).map(\.name) == ["igb0", "igb1", "igb2", "igb3", "ix0", "ix1"])
        let igb0 = try #require(byName["igb0"])
        #expect(igb0.up && igb0.linkUp && igb0.description == "WAN" && igb0.addresses == ["198.51.100.20/24"])
        #expect(igb0.mac == "00:00:5e:00:53:a0")
        #expect(byName["igb2"]?.up == false && byName["igb2"]?.linkUp == false)
        #expect(byName["igb1.20"]?.vlanTag == 20 && byName["igb1.20"]?.parent == "igb1")
        #expect(byName["lagg0"]?.laggPorts == ["ix0", "ix1"])
        #expect(PFParsers.speed(media: byName["igb0"]?.media) == "1G" && PFParsers.speed(media: byName["ix0"]?.media) == "10G")
        #expect(PFParsers.speed(media: "Ethernet autoselect (2500Base-T <full-duplex>)") == "2.5G")
        #expect(PFParsers.speed(media: "Ethernet autoselect (100baseTX <full-duplex>)") == "100Mbps")
        #expect(PFParsers.speed(media: "Ethernet autoselect") == nil)
        #expect(PFParsers.isCage(media: byName["ix0"]?.media) && !PFParsers.isCage(media: byName["igb0"]?.media))
        #expect(PFParsers.isCage(media: "Ethernet autoselect (1000baseSX <full-duplex>)"))
        #expect(!PFParsers.isCage(media: "Ethernet autoselect (10Gbase-T <full-duplex>)"))
        // A PPPoE link's point-to-point address.
        let opn = PFParsers.ifconfig(try pfFixture("opnsense-ifconfig"))
        #expect(opn.first { $0.name == "pppoe0" }?.addresses == ["203.0.113.5/32"])
        #expect(opn.filter(PFParsers.isPort).map(\.name) == ["igb0", "igb1", "igb2"])
    }

    @Test func arp() throws {
        let entries = PFParsers.arp(try pfFixture("pfsense-arp"))
        // Own addresses (permanent) and incomplete entries are left out; short MAC octets are padded.
        #expect(entries.map(\.ip) == ["198.51.100.1", "192.0.2.10", "192.0.2.11", "192.0.2.70", "192.0.2.140"])
        #expect(entries[2].mac == "00:00:5e:00:53:11" && entries[3].interface == "igb1.20")
    }

    @Test func configXML() throws {
        let pf = PFParsers.config(try pfFixture("pfsense-config", ext: "xml"))
        #expect(pf.hostname == "fw-edge" && pf.domain == "home.arpa")
        #expect(pf.interfaces.map(\.key) == ["wan", "lan", "opt1", "opt2", "opt3"])
        let wan = try #require(pf.interfaces.first)
        #expect(wan.device == "igb0" && wan.enabled && wan.ipaddr == "dhcp" && wan.label == "WAN")
        let dmz = try #require(pf.interfaces.last)
        #expect(!dmz.enabled && dmz.ipaddr == "203.0.113.1" && dmz.subnet == 28)
        #expect(pf.vlans == [PFConfig.VLAN(parent: "igb1", tag: 20, descr: "servers", device: "igb1.20")])
        #expect(pf.laggs == [PFConfig.Lagg(device: "lagg0", members: ["ix0", "ix1"])])

        let opn = PFParsers.config(try pfFixture("opnsense-config", ext: "xml"))
        #expect(opn.interfaces.map(\.device) == ["pppoe0", "igb1", "vlan01"] && opn.interfaces.allSatisfy(\.enabled))
        #expect(opn.vlans.first?.device == "vlan01" && opn.vlans.first?.tag == 30)
        #expect(opn.ppps == [PFConfig.PPP(device: "pppoe0", ports: ["igb0"])])
        // Not XML (a refused `cat`): nothing, no crash.
        #expect(PFParsers.config("cat: /conf/config.xml: Permission denied") == PFConfig())
    }
}

@Suite struct PFSnapshotTests {
    init() { L10n.language = .en }

    @Test func pfSensePorts() throws {
        let s = PFSnapshot.build(try pfOutputs("pfsense"))
        #expect(s.platform == .pfsense && s.kind == .firewall && s.hostname == "fw-edge" && s.osVersion == "2.7.2-RELEASE")
        #expect(s.ports.map(\.name) == ["igb0", "igb1", "igb2", "igb3", "ix0", "ix1"])

        let wan = try #require(s.port(named: "igb0"))
        #expect(wan.description == "WAN" && wan.addresses == ["198.51.100.20/24 (dhcp)"] && wan.speed == "1G")
        #expect(wan.macs.map(\.mac) == ["00:00:5e:00:53:01"])

        let lan = try #require(s.port(named: "igb1"))
        #expect(lan.addresses == ["192.0.2.1/26", "192.0.2.65/26 (SERVERS · VLAN 20)"])
        #expect(lan.macs.map(\.mac) == ["00:00:5e:00:53:10", "00:00:5e:00:53:11", "00:00:5e:00:53:20"])

        let dmz = try #require(s.port(named: "igb2"))
        #expect(dmz.configDisabled && dmz.state == .disabled && dmz.description == "DMZ")
        let spare = try #require(s.port(named: "igb3"))
        // Unassigned and not brought up: shown as off, though nothing in the configuration turns it off.
        #expect(spare.addresses.isEmpty && spare.description == nil && !spare.configDisabled && spare.state == .disabled)

        // LAGG members: the LAGG's interface, as optics; two ports behind it, so no neighbours placed.
        let ix0 = try #require(s.port(named: "ix0"))
        #expect(ix0.kind == .sfp && ix0.speed == "10G" && ix0.description == "STORAGE")
        #expect(ix0.addresses == ["192.0.2.129/26 (lagg0)"] && ix0.macs.isEmpty)

        #expect(!s.hasSwitching && s.macTable.isEmpty && !s.changeTraits.canChange)
        #expect(s.configText.contains("<pfsense>"))
    }

    @Test func opnSensePorts() throws {
        let s = PFSnapshot.build(try pfOutputs("opnsense"))
        #expect(s.platform == .opnsense && s.model == "DEC740" && s.hardware.serial == "TEST0001" && s.hostname == "fw-core")
        #expect(s.ports.map(\.name) == ["igb0", "igb1", "igb2"])
        // PPPoE dials out on igb0.
        #expect(s.port(named: "igb0")?.addresses == ["203.0.113.5/32 (pppoe)"] && s.port(named: "igb0")?.description == "WAN")
        let lan = try #require(s.port(named: "igb1"))
        #expect(lan.speed == "2.5G" && lan.addresses == ["192.0.2.1/26", "192.0.2.193/26 (CAMERAS · VLAN 30)"])
        #expect(lan.macs.map(\.mac) == ["00:00:5e:00:53:10", "00:00:5e:00:53:40"])
    }

    @Test func withoutTheConfigurationIfconfigStillShowsPorts() throws {
        var o = try pfOutputs("pfsense")
        o.config = ""
        let s = PFSnapshot.build(o)
        #expect(s.ports.count == 6)
        // VLANs and LAGG members come from ifconfig then.
        #expect(s.port(named: "igb1")?.addresses == ["192.0.2.1/26", "192.0.2.65/26 (SERVERS · VLAN 20)"])
        #expect(s.port(named: "ix0")?.addresses == ["192.0.2.129/26 (lagg0)"])
        #expect(s.port(named: "ix0")?.macs.isEmpty == true && s.port(named: "igb0")?.description == "WAN")
    }
}

@Suite struct PFDetectionTests {
    @Test func recognised() throws {
        let pf = try #require(DeviceDetector.detect(try pfFixture("pfsense-login-menu")))
        #expect(pf.platform == .pfsense && pf.osVersion == "2.7.2-RELEASE" && pf.kind == .firewall)
        let opn = try #require(DeviceDetector.detect(try pfFixture("opnsense-login-menu")))
        #expect(opn.platform == .opnsense && opn.osVersion == "25.1.5_5")
        #expect(DeviceDetector.detect("*** Welcome to Netgate pfSense Plus 24.11-RELEASE (amd64) on fw ***")?.osVersion == "24.11-RELEASE")
        #expect(DeviceDetector.foreignPrompt("Enter an option:") == .pfsense)
        #expect(DeviceDetector.foreignPrompt("[2.7.2-RELEASE][admin@fw.home.arpa]/root:") == .pfsense)
        // "OPNsense 25.1.5_5" alone when the hardware is unknown; the model first when it is.
        #expect(Detection(platform: .opnsense, osVersion: "25.1.5_5").summary == "OPNsense 25.1.5_5")
        #expect(Detection(platform: .opnsense, model: "DEC740", osVersion: "25.1.5_5").summary == "DEC740 · OPNsense 25.1.5_5")
        #expect(Platform.pfsense.displayName == "pfSense" && Platform.juniperJunos.displayName == "Juniper Junos")
    }

    @Test func catalog() {
        for p in [Platform.pfsense, .opnsense] {
            #expect(p.kinds == [.firewall, .router] && p.exportsConfig && p.changeTraits == .readOnly)
            #expect(DriverFactory.supports(p, over: .ssh) && !DriverFactory.supports(p, over: .api))
        }
    }
}

/// pfSense or OPNsense over SSH: the menu, the root shell, Netdeck's /bin/sh, and the reading commands. Records every
/// line it gets; a menu number other than Shell or Logout is recorded as typed and does nothing.
final class PFFake: Transport, @unchecked Sendable {
    enum State { case menu, rootShell, sh, closed }
    let displayName = "fake-pf"
    private let lock = NSLock()
    private var onData: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable (String?) -> Void)?
    private var line = ""
    private var state = State.menu
    private var log: [String] = []
    private let system: String
    private let menu: String
    private let outputs: [String: String]

    init(_ system: String, menu: String? = nil) throws {
        self.system = system
        self.menu = try menu ?? pfFixture("\(system)-login-menu")
        outputs = [
            PFParsers.identityCommand: try pfFixture("\(system)-identity"),
            "ifconfig -a": try pfFixture("\(system)-ifconfig"),
            "arp -an": try pfFixture("\(system)-arp"),
            "cat /conf/config.xml": try pfFixture("\(system)-config", ext: "xml"),
        ]
    }

    var received: [String] { lock.lock(); defer { lock.unlock() }; return log }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return state == .closed }

    func open(onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (String?) -> Void) throws {
        lock.lock(); self.onData = onData; self.onClose = onClose; lock.unlock()
    }

    func send(_ data: Data) throws {
        var out = ""
        lock.lock()
        for ch in String(decoding: data, as: UTF8.self).unicodeScalars {
            if ch == "\r" {
                out += respond(line)
                line = ""
            } else if ch != "\n" {
                line.unicodeScalars.append(ch)
            }
        }
        let deliver = onData
        let close = state == .closed ? onClose : nil
        lock.unlock()
        if !out.isEmpty { deliver?(Data(out.utf8)) }
        close?("closed")
    }

    func close() {}

    private var rootPrompt: String { system == "pfsense" ? "[2.7.2-RELEASE][admin@fw-edge.home.arpa]/root: " : "root@fw-core:~ # " }

    private func crlf(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "\r\n") }

    /// Called with the lock held.
    private func respond(_ cmd: String) -> String {
        log.append(cmd)
        let echo = cmd + "\r\n"
        switch state {
        case .closed:
            return ""
        case .menu:
            if cmd == "8" { state = .rootShell; return echo + rootPrompt }
            if cmd == "0" { state = .closed; return echo }
            // An empty line (or anything else) redraws the menu.
            return echo + crlf(menu)
        case .rootShell:
            if cmd == PFDialect.shellCommand { state = .sh; return echo + PFDialect.prompt }
            if cmd == "exit" { state = .menu; return echo + crlf(menu) }
            return echo + rootPrompt
        case .sh:
            if cmd == "exit" { state = .rootShell; return echo + rootPrompt }
            if cmd.isEmpty { return "\r\n" + PFDialect.prompt }
            let body = outputs[cmd] ?? "sh: \(cmd.split(separator: " ").first ?? ""): not found\n"
            return echo + crlf(body) + PFDialect.prompt
        }
    }
}

@Suite struct PFDriverTests {
    init() { L10n.language = .en }

    @Test func pfSenseIsReadThroughTheShellEntryAndLeftThroughLogout() async throws {
        let fw = try PFFake("pfsense")
        let driver = PFDriver(transport: fw, platform: .pfsense)
        try await driver.connect(username: "admin", password: nil)
        guard case let .network(s) = try await driver.read(progress: { _ in }) else {
            Issue.record("expected a network reading")
            return
        }
        #expect(s.ports.count == 6 && s.port(named: "igb1")?.macs.count == 3)
        #expect(s.configText.contains("</pfsense>"))
        await #expect(throws: DriverError.notSupported) { try await driver.apply(ChangePlan(changes: []), confirmMinutes: 5, comment: "c") }
        await driver.disconnect()
        #expect(fw.isClosed)

        // The only menu numbers ever typed: Shell to get in, Logout to get out.
        let sent = fw.received
        let digits = sent.filter { $0.range(of: #"^\d+$"#, options: .regularExpression) != nil }
        #expect(digits == ["8", "0"])
        let reading: Set<String> = [PFParsers.identityCommand, "ifconfig -a", "arp -an", "cat /conf/config.xml"]
        let inShell = sent.drop { $0 != PFDialect.shellCommand }.dropFirst().prefix { $0 != "exit" }
        #expect(Set(inShell).isSubset(of: reading.union([""])))
        #expect(sent.suffix(3) == ["exit", "exit", "0"])
    }

    @Test func opnSenseFoundWhenPfSenseWasPickedHandsOver() async throws {
        let fw = try PFFake("opnsense")
        let driver = PFDriver(transport: fw, platform: .pfsense)
        do {
            try await driver.connect(username: "root", password: nil)
            Issue.record("connect should hand over")
        } catch let CLIError.unrecognizedPrompt(text) {
            #expect(DeviceDetector.detect(text)?.platform == .opnsense)
        }
        await driver.disconnect()
        #expect(fw.isClosed)
    }

    @Test func aMenuWithoutAShellEntryIsNotTouched() async throws {
        let menu = try pfFixture("pfsense-login-menu").replacingOccurrences(of: " 8) Shell", with: " 8) Console")
        let fw = try PFFake("pfsense", menu: menu)
        let driver = PFDriver(transport: fw, platform: .pfsense)
        await #expect(throws: CLIError.self) { try await driver.connect(username: "admin", password: nil) }
        #expect(!fw.received.contains { $0.range(of: #"^\d+$"#, options: .regularExpression) != nil })
    }
}
