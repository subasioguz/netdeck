import Foundation
import Testing
@testable import NetdeckCore

/// Synthetic EdgeOS captures (see Fixtures/synthetic/edgeos/README.md), with the echoed command and the
/// trailing prompt, stripped the way `CLISession.run` strips them.
func edgeosFixture(_ name: String) throws -> String {
    L10n.language = .en
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/synthetic/edgeos"))
    return CLISession.strip(try String(contentsOf: url, encoding: .utf8), dialect: EdgeOSDialect())
}

/// EdgeRouter X: eth0 routed WAN, eth1-eth4 in a vlan-aware switch0.
func edgeosSnapshot() throws -> SwitchSnapshot {
    try EdgeOSSnapshot.build(
        version: edgeosFixture("show-version"), config: edgeosFixture("show-configuration-commands"),
        interfaces: edgeosFixture("show-interfaces"), arp: edgeosFixture("show-arp"),
        lldp: edgeosFixture("show-lldp-neighbors"), commits: edgeosFixture("show-system-commit"))
}

@Suite struct EdgeOSDialectTests {
    let d = EdgeOSDialect()

    @Test func promptKinds() {
        #expect(d.prompt("ubnt@er-x-lab:~$ ") == .operational)
        #expect(d.prompt("ubnt@er-x-lab:/config$") == .operational)
        #expect(d.prompt("root@er-x-lab:~#") == .operational)
        #expect(d.prompt("ubnt@er-x-lab# ") == .configuration)
        #expect(d.prompt("er-x-lab login: ") == .login)
        #expect(d.prompt("Password: ") == .password)
        #expect(d.prompt("Proceed? [yes][y]") == .question)
        #expect(d.prompt("Proceed? ") == .question)
        #expect(d.prompt("Proceed with reboot? [confirm][y]") == .question)
        #expect(d.prompt("Discard changes? (y/n)") == .question)
        #expect(d.prompt(":") == .pager)
        #expect(d.prompt("[edit]") == nil)
        #expect(d.prompt("set interfaces ethernet eth1 description 'Office desk'") == nil)
        #expect(d.prompt("Type 'confirm' to stop reboot") == nil)
        #expect(d.prompt("") == nil)
    }

    @Test func promptAfterTerminalTitle() {
        // ESC ] 0;title BEL before the prompt; cleaning leaves the title text and the BEL.
        let cleaned = JunosCLI.clean("\u{1B}]0;ubnt@er-x-lab: ~\u{7}ubnt@er-x-lab:~$ ")
        #expect(d.prompt(cleaned) == .operational)
    }

    @Test func editLinesAreTrailingNoise() {
        #expect(d.isTrailingNoise("[edit]"))
        #expect(d.isTrailingNoise("[edit interfaces ethernet eth1]"))
        #expect(!d.isTrailingNoise("+description Printer"))
    }

    @Test func stripsEchoEditAndConfigPrompt() throws {
        #expect(try edgeosFixture("commit-confirm") == """
            commit-confirm will automatically reboot in 5 minutes unless confirmed
            Proceed? [yes][y]
            Type 'confirm' to stop reboot
            """)
        #expect(try edgeosFixture("compare") == "[edit interfaces ethernet eth3]\n+description Printer")
        let raw = "set interfaces ethernet eth3 description Printer\r\n[edit]\r\nubnt@er-x-lab# "
        #expect(CLISession.strip(raw, dialect: d) == "")
    }

    @Test func leavingNeverAnswersYes() {
        #expect(d.logout(from: .configuration) == "exit discard\r")
        #expect(d.logout(from: .operational) == "exit\r")
        #expect(d.logout(from: .question) == "\u{3}")
        #expect(d.logout(from: .login) == nil)
        #expect(d.advance(from: .configuration) == "exit discard\r")
        #expect(d.setupCommands == ["set terminal length 0", "set terminal width 512"])
    }

    @Test func rejectedCommands() {
        let out = "  Configuration path: [interfaces ethernet eth9] is not valid\n  Set failed"
        #expect(d.errors(in: out) == ["Configuration path: [interfaces ethernet eth9] is not valid", "Set failed"])
        #expect(d.errors(in: "  Invalid command: set [foo]").count == 1)
        #expect(d.errors(in: "  Value validation failed\n  Set failed").count == 2)
        #expect(d.errors(in: "").isEmpty)
    }
}

@Suite struct EdgeOSParserTests {
    @Test func tokenizesSingleAndDoubleQuotes() {
        #expect(EdgeOSParsers.tokenize("set interfaces ethernet eth0 description 'WAN uplink'")
                == ["set", "interfaces", "ethernet", "eth0", "description", "WAN uplink"])
        #expect(EdgeOSParsers.tokenize(#"set x description 'it'\''s'"#) == ["set", "x", "description", "it's"])
        #expect(EdgeOSParsers.tokenize(#"set x description "say \"hi\"""#) == ["set", "x", "description", #"say "hi""#])
        #expect(EdgeOSParsers.tokenize("set x description ''") == ["set", "x", "description", ""])
        #expect(EdgeOSParsers.tokenize("set  x   y") == ["set", "x", "y"])
    }

    @Test func quotesValues() {
        #expect(EdgeOSParsers.quote("Printer") == "Printer")
        #expect(EdgeOSParsers.quote("192.0.2.1/24") == "192.0.2.1/24")
        #expect(EdgeOSParsers.quote("Front desk") == "'Front desk'")
        #expect(EdgeOSParsers.quote("Café") == "'Café'")
        #expect(EdgeOSParsers.quote("") == "''")
        #expect(EdgeOSParsers.quote("it's $5") == #""it's \$5""#)
        for v in ["Front desk", "it's", "a \"b\""] {
            #expect(EdgeOSParsers.tokenize("set x " + EdgeOSParsers.quote(v)).last == v)
        }
    }

    @Test func parsesConfigCommands() throws {
        let cfg = EdgeOSParsers.config(try edgeosFixture("show-configuration-commands"))
        #expect(cfg.hostname == "er-x-lab")
        #expect(cfg.hasSwitch0)
        #expect(cfg.vlanAware)
        #expect(cfg.members["eth1"] == EdgeOSState.SwitchMember(pvid: 10))
        #expect(cfg.members["eth2"] == EdgeOSState.SwitchMember(pvid: 10, vids: [20, 30]))
        #expect(cfg.members["eth3"] == EdgeOSState.SwitchMember())
        #expect(cfg.members["eth0"] == nil)
        #expect(cfg.switchVifs[10]?.description == "Staff LAN")
        #expect(cfg.switchVifs[10]?.addresses == ["198.51.100.1/25"])
        #expect(cfg.switchVifs[20]?.description == "Guest")
        #expect(cfg.switchAddresses == ["192.0.2.1/24"])
        #expect(cfg.ethernet["eth0"]?.addresses == ["203.0.113.10/24", "2001:db8::10/64"])
        #expect(cfg.ethernet["eth0"]?.description == "WAN uplink")
        #expect(cfg.ethernet["eth3"] != nil)
        #expect(cfg.ethernet["eth4"]?.disabled == true)
        #expect(cfg.ethernet["eth4"]?.description == "Spare")
        #expect(cfg.lines.count == 56)
    }

    @Test func parsesRoutedVifsAndPPPoE() {
        let cfg = EdgeOSParsers.config("""
            set interfaces ethernet eth0 vif 7 description 'ISP VLAN'
            set interfaces ethernet eth0 vif 7 pppoe 0 user-id customer
            set interfaces ethernet eth1 address dhcp
            set interfaces ethernet eth1 vif 100 address 198.51.100.1/24
            set interfaces switch switch0 switch-port vlan-aware disable
            """)
        #expect(cfg.ethernet["eth0"]?.vifs[7]?.description == "ISP VLAN")
        #expect(cfg.ethernet["eth0"]?.vifs[7]?.pppoe == [0])
        #expect(!cfg.vlanAware)
        #expect(cfg.ethernet["eth0"].map { EdgeOSSnapshot.routedAddresses(port: "eth0", $0) } == ["pppoe0 (eth0.7)"])
        #expect(cfg.ethernet["eth1"].map { EdgeOSSnapshot.routedAddresses(port: "eth1", $0) } == ["dhcp", "198.51.100.1/24 (eth1.100)"])
    }

    @Test func parsesShowInterfaces() throws {
        let rows = EdgeOSParsers.interfaces(try edgeosFixture("show-interfaces"))
        #expect(rows.map(\.name) == ["eth0", "eth1", "eth2", "eth3", "eth4", "lo", "switch0", "switch0.10", "switch0.20"])
        let eth0 = try #require(rows.first { $0.name == "eth0" })
        #expect(eth0.addresses == ["203.0.113.10/24", "2001:db8::10/64"])
        #expect(eth0.adminUp && eth0.linkUp)
        #expect(eth0.description == "WAN uplink")
        let eth3 = try #require(rows.first { $0.name == "eth3" })
        #expect(eth3.adminUp && !eth3.linkUp)
        #expect(eth3.description == nil)
        let eth4 = try #require(rows.first { $0.name == "eth4" })
        #expect(!eth4.adminUp && !eth4.linkUp)
        #expect(rows.first { $0.name == "lo" }?.addresses == ["127.0.0.1/8", "::1/128"])
        #expect(rows.first { $0.name == "switch0.10" }?.description == "Staff LAN")
    }

    @Test func parsesShowVersion() throws {
        let text = try edgeosFixture("show-version")
        let v = EdgeOSParsers.version(text)
        #expect(v.version == "v2.0.9-hotfix.7")
        #expect(v.buildID == "5611704")
        #expect(v.model == "EdgeRouter X 5-Port")
        #expect(v.serial == "TEST0000001")
        #expect(v.uptime?.hasPrefix("10:42:31 up 12 days") == true)
        #expect(EdgeOSParsers.isEdgeOS(text))
        #expect(!EdgeOSParsers.isEdgeOS("Version:          VyOS 1.4.0\nHW model:     KVM\nCopyright:    VyOS maintainers"))
        #expect(!EdgeOSParsers.isEdgeOS("Hostname: sw-01\nModel: ex4300-48t\nJunos: 21.2R3.8"))
    }

    @Test func parsesShowArp() throws {
        let arp = EdgeOSParsers.arp(try edgeosFixture("show-arp"))
        #expect(arp.count == 4)
        #expect(arp.first == EdgeOSParsers.ARPEntry(address: "203.0.113.1", mac: "48:a9:8a:00:00:01", flags: "C", interface: "eth0"))
        #expect(arp.map(\.interface) == ["eth0", "switch0.10", "switch0.20", "switch0"])
    }

    @Test func parsesLLDPTable() throws {
        let n = EdgeOSParsers.lldpNeighbors(try edgeosFixture("show-lldp-neighbors"))
        #expect(n == [LLDPNeighbor(localInterface: "eth2", chassisID: "", portInfo: "eth0", systemName: "office-ap")])
    }

    @Test func parsesLLDPDetailBlocks() throws {
        let n = EdgeOSParsers.lldpNeighbors(try edgeosFixture("show-lldp-neighbors-lldpd"))
        #expect(n == [
            LLDPNeighbor(localInterface: "eth2", chassisID: "48:a9:8a:00:00:20", portInfo: "eth0", systemName: "office-ap"),
            LLDPNeighbor(localInterface: "eth0", chassisID: "48:a9:8a:00:00:01", portInfo: "ge-0/0/1", systemName: "isp-gw"),
        ])
        #expect(EdgeOSParsers.lldpNeighbors("Invalid command: show lldp [neighbors]").isEmpty)
        #expect(EdgeOSParsers.lldpNeighbors("").isEmpty)
    }

    @Test func parsesCommitHistory() throws {
        let c = EdgeOSParsers.commitHistory(try edgeosFixture("show-system-commit"))
        #expect(c.count == 3)
        #expect(c[0].index == 0)
        #expect(c[0].timestamp == "2024-03-01 10:00:00")
        #expect(c[0].user == "ubnt")
        #expect(c[0].client == "cli")
        #expect(c[0].comment == nil)
        #expect(c[1].comment == "Guest VLAN")
        #expect(c[2].user == "root")
        #expect(c[2].client == "init")
        #expect(c[0].date != nil)
        #expect(EdgeOSParsers.commitHistory("Invalid command: show system [commit]").isEmpty)
    }

    @Test func classifiesCommitConfirm() throws {
        #expect(EdgeOSParsers.commitConfirmResult(try edgeosFixture("commit-confirm"), answered: false) == .armed)
        // Asked, answered with y; the scheduling message itself may be cut off with the echoed answer.
        #expect(EdgeOSParsers.commitConfirmResult("commit-confirm will automatically reboot in 5 minutes unless confirmed\nProceed? [yes][y]\n",
                                                  answered: true) == .armed)
        #expect(EdgeOSParsers.commitConfirmResult("Type 'confirm' to stop reboot\nCommit failed", answered: true) == .commitFailed)
        #expect(EdgeOSParsers.commitConfirmResult("No configuration changes to commit", answered: false) == .notArmed(nil))
        #expect(EdgeOSParsers.commitConfirmResult("commit-confirm canceled.", answered: true) == .notArmed(nil))
        #expect(EdgeOSParsers.commitConfirmResult("", answered: false) == .notArmed(nil))
        for refusal in ["commit-revisions is not configured.", "Another confirm is pending.", "Invalid command: [commit-confirm]"] {
            guard case let .notArmed(reason) = EdgeOSParsers.commitConfirmResult(refusal, answered: false) else {
                Issue.record("\(refusal) should not arm the timer")
                continue
            }
            #expect(reason != nil)
        }
    }

    @Test func confirmSaveAndCompareOutputs() throws {
        #expect(EdgeOSParsers.nothingPending("No confirm pending."))
        #expect(!EdgeOSParsers.nothingPending("Reboot timer stopped."))
        #expect(!EdgeOSParsers.nothingPending(""))
        #expect(EdgeOSParsers.saveSucceeded("Saving configuration to '/config/config.boot'...\nDone"))
        #expect(!EdgeOSParsers.saveSucceeded("Save failed"))
        #expect(EdgeOSParsers.commitSucceeded("No configuration changes to commit"))
        #expect(!EdgeOSParsers.commitSucceeded("Commit failed"))
        #expect(EdgeOSParsers.compareShowsChanges(try edgeosFixture("compare")))
        #expect(!EdgeOSParsers.compareShowsChanges("No changes between working and active configurations."))
        #expect(!EdgeOSParsers.compareShowsChanges(""))
        #expect(EdgeOSParsers.savedState("No changes between working and saved configurations.") == .same)
        #expect(EdgeOSParsers.savedState("[edit system]\n+host-name er-x-lab") == .differs)
        #expect(EdgeOSParsers.savedState("Invalid command: compare [saved]") == .unknown)
        // An EdgeOS without `compare saved` may compare working with active instead: not proof of anything.
        #expect(EdgeOSParsers.savedState("No changes between working and active configurations.") == .unknown)
    }

    @Test func modelsWithCages() {
        #expect(EdgeOSModel.kind(model: "EdgeRouter X 5-Port", number: 4) == .copper)
        #expect(EdgeOSModel.kind(model: "EdgeRouter X SFP 6-Port", number: 5) == .sfp)
        #expect(EdgeOSModel.kind(model: "EdgeRouter X SFP 6-Port", number: 4) == .copper)
        #expect(EdgeOSModel.kind(model: "EdgeRouter 4", number: 3) == .sfp)
        #expect(EdgeOSModel.kind(model: "EdgeRouter 4", number: 2) == .copper)
        #expect(EdgeOSModel.kind(model: "EdgeRouter 6P", number: 5) == .sfp)
        #expect(EdgeOSModel.kind(model: "EdgeRouter 12", number: 11) == .sfp)
        #expect(EdgeOSModel.kind(model: "EdgeRouter 12P", number: 10) == .sfp)
        #expect(EdgeOSModel.kind(model: "EdgeRouter 10X", number: 9) == .copper)
        #expect(EdgeOSModel.kind(model: "EdgeRouter Infinity", number: 0) == .sfp)
        #expect(EdgeOSModel.kind(model: nil, number: 5) == .copper)
    }
}

@Suite struct EdgeOSSnapshotTests {
    @Test func buildsERXPorts() throws {
        let s = try edgeosSnapshot()
        #expect(s.platform == .ubiquitiEdgeOS)
        #expect(s.readKind == .router)
        #expect(s.hostname == "er-x-lab")
        #expect(s.model == "EdgeRouter X 5-Port")
        #expect(s.osVersion == "v2.0.9-hotfix.7")
        #expect(s.hardware.serial == "TEST0000001")
        #expect(s.hasSwitching)
        #expect(s.ports.map(\.name) == ["eth0", "eth1", "eth2", "eth3", "eth4"])
        #expect(s.ports.allSatisfy { $0.kind == .copper && $0.slotKey == $0.name && $0.label == String($0.number) })

        let wan = try #require(s.port(named: "eth0"))
        #expect(wan.addresses == ["203.0.113.10/24", "2001:db8::10/64"])
        #expect(wan.isRouted)
        #expect(!wan.switching)
        #expect(wan.mode == nil)
        #expect(wan.description == "WAN uplink")
        #expect(wan.state == .up)

        let eth1 = try #require(s.port(named: "eth1"))
        #expect(eth1.switching)
        #expect(eth1.mode == .access)
        #expect(eth1.vlans == ["Staff LAN"])
        #expect(eth1.nativeVlanID == nil)

        let eth2 = try #require(s.port(named: "eth2"))
        #expect(eth2.mode == .trunk)
        #expect(eth2.vlans == ["Staff LAN", "Guest", "vlan30"])
        #expect(eth2.nativeVlanID == 10)
        #expect(eth2.lldp.first?.systemName == "office-ap")

        let eth3 = try #require(s.port(named: "eth3"))
        #expect(eth3.vlans == ["default"])
        #expect(eth3.state == .down)

        let eth4 = try #require(s.port(named: "eth4"))
        #expect(eth4.configDisabled)
        #expect(!eth4.adminUp)
        #expect(eth4.state == .disabled)
        #expect(eth4.description == "Spare")
    }

    @Test func namesVLANsFromVifDescriptions() throws {
        let s = try edgeosSnapshot()
        #expect(s.config.vlans == [
            JunosConfig.VLAN(name: "Staff LAN", vlanID: 10, l3Interface: "switch0.10"),
            JunosConfig.VLAN(name: "Guest", vlanID: 20, l3Interface: "switch0.20"),
            JunosConfig.VLAN(name: "vlan30", vlanID: 30),
        ])
        #expect(s.config.interfaces["eth2"]?.vlanMembers == ["Staff LAN", "Guest", "vlan30"])
        #expect(s.config.interfaces["eth0"]?.inetAddresses.count == 2)
        guard case let .edgeos(state) = s.vendor else { Issue.record("no EdgeOS state"); return }
        #expect(state.vlansEnabled)
        #expect(state.members.count == 4)
        #expect(state.vifs.map(\.id) == [10, 20])
        #expect(state.ports(carrying: 10) == ["eth1", "eth2"])
        #expect(state.ports(carrying: 1) == ["eth3", "eth4"])
    }

    @Test func duplicateAndMissingVifDescriptions() {
        let s = EdgeOSSnapshot.build(version: "", config: """
            set interfaces switch switch0 switch-port interface eth1 vlan pvid 40
            set interfaces switch switch0 switch-port vlan-aware enable
            set interfaces switch switch0 vif 10 description Office
            set interfaces switch switch0 vif 20 description Office
            set interfaces switch switch0 vif 30 description vlan40
            set interfaces switch switch0 vif 50 description default
            """, interfaces: "", arp: "", lldp: "", commits: "")
        #expect(s.config.vlans.map(\.name) == ["Office", "vlan20", "vlan30", "vlan40", "vlan50"])
        #expect(s.ports.map(\.name) == ["eth1"])
        #expect(s.ports.first?.vlans == ["vlan40"])
    }

    @Test func arpBecomesMACTableWhereThePortIsKnown() throws {
        let s = try edgeosSnapshot()
        // switch0.10 and switch0 are carried by two ports each, so those entries can't be placed.
        #expect(s.macTable == [
            MACEntry(vlan: "—", mac: "48:a9:8a:00:00:01", flags: "C", interface: "eth0"),
            MACEntry(vlan: "Guest", mac: "48:a9:8a:00:00:20", flags: "C", interface: "eth2"),
        ])
        #expect(s.port(named: "eth2")?.macs.count == 1)
    }

    @Test func routerWithoutSwitchHasNoMACTable() {
        let s = EdgeOSSnapshot.build(version: "", config: """
            set interfaces ethernet eth0 address dhcp
            set interfaces ethernet eth1 address 192.0.2.1/24
            set interfaces ethernet eth2
            """, interfaces: "", arp: "192.0.2.10  ether  48:a9:8a:00:00:10  C  eth1", lldp: "", commits: "")
        #expect(s.ports.map(\.name) == ["eth0", "eth1", "eth2"])
        #expect(s.macTable.isEmpty)
        #expect(!s.hasSwitching)
        #expect(s.port(named: "eth0")?.isRouted == true)
    }

    @Test func cagesComeAfterCopper() {
        let s = EdgeOSSnapshot.build(version: "Version: v2.0.9\nHW model: EdgeRouter X SFP 6-Port",
                                     config: (0...5).map { "set interfaces ethernet eth\($0) duplex auto" }.joined(separator: "\n"),
                                     interfaces: "", arp: "", lldp: "", commits: "")
        #expect(s.ports.map(\.name) == ["eth0", "eth1", "eth2", "eth3", "eth4", "eth5"])
        #expect(s.ports.last?.kind == .sfp)
        #expect(s.ports.filter { $0.kind == .copper }.count == 5)
    }
}

@Suite struct EdgeOSPlannerTests {
    let snap: SwitchSnapshot
    let sp = "interfaces switch switch0 switch-port interface"

    init() throws { snap = try edgeosSnapshot() }

    func plan(_ ports: [PortEdit] = [], vlans: [VLANEdit] = []) -> ChangePlan {
        EdgeOSPlanner.plan(snapshot: snap, ports: ports, vlans: vlans)
    }

    @Test func dispatchesThroughPlanner() {
        let p = Planner.plan(snapshot: snap, ports: [PortEdit(port: "eth3", description: "Printer")], vlans: [])
        #expect(p.commands == ["set interfaces ethernet eth3 description Printer"])
    }

    @Test func descriptionEdits() {
        let p = plan([PortEdit(port: "eth3", description: "Printer")])
        #expect(p.commands == ["set interfaces ethernet eth3 description Printer"])
        #expect(p.changes.first?.summary == "description: — → Printer")
        #expect(plan([PortEdit(port: "eth3", description: "Front desk")]).commands == ["set interfaces ethernet eth3 description 'Front desk'"])
        let removed = plan([PortEdit(port: "eth1", description: "")])
        #expect(removed.commands == ["delete interfaces ethernet eth1 description"])
        #expect(removed.changes.first?.summary == "description: Office desk → —")
    }

    @Test func disableAndEnable() {
        let off = plan([PortEdit(port: "eth3", enabled: false)])
        #expect(off.commands == ["set interfaces ethernet eth3 disable"])
        #expect(off.changes.first?.summary == "will be disabled")
        let on = plan([PortEdit(port: "eth4", enabled: true)])
        #expect(on.commands == ["delete interfaces ethernet eth4 disable"])
        #expect(on.changes.first?.summary == "will be enabled")
    }

    @Test func unchangedEditsPlanNothing() {
        let p = plan([
            PortEdit(port: "eth1", description: "Office desk", enabled: true, mode: .access, vlans: ["Staff LAN"]),
            PortEdit(port: "eth2", mode: .trunk, vlans: ["Staff LAN", "Guest", "vlan30"]),
            PortEdit(port: "eth3", vlans: ["default"]),
            PortEdit(port: "eth0", description: "WAN uplink"),
        ])
        #expect(p.changes.isEmpty)
    }

    @Test func accessVLANChangeSetsPvid() {
        let p = plan([PortEdit(port: "eth1", vlans: ["Guest"])])
        #expect(p.commands == ["set \(sp) eth1 vlan pvid 20"])
        #expect(p.changes.first?.summary == "VLAN: Staff LAN → Guest")
        #expect(p.warnings.isEmpty)
    }

    @Test func trunkListReplacesVids() {
        let p = plan([PortEdit(port: "eth2", vlans: ["Staff LAN", "Guest"])])
        #expect(p.commands == ["delete \(sp) eth2 vlan vid", "set \(sp) eth2 vlan vid 20"])
        #expect(p.changes.first?.summary == "VLAN: Staff LAN, Guest, vlan30 → Staff LAN, Guest")
    }

    @Test func accessToTrunkAddsVids() {
        let p = plan([PortEdit(port: "eth3", mode: .trunk, vlans: ["default", "Staff LAN", "Guest"])])
        #expect(p.commands == ["set \(sp) eth3 vlan vid 10", "set \(sp) eth3 vlan vid 20"])
        #expect(p.changes.first?.summary
                == "mode: single network (access) → multiple networks (trunk) · VLAN: default → default, Staff LAN, Guest")
    }

    @Test func trunkToAccessDropsVids() {
        let p = plan([PortEdit(port: "eth2", mode: .access, vlans: ["Staff LAN"])])
        #expect(p.commands == ["delete \(sp) eth2 vlan vid"])
        #expect(p.changes.first?.summary.hasPrefix("mode: multiple networks (trunk) → single network (access)") == true)
    }

    @Test func trunkWithoutItsUntaggedVLANFallsBackToVLAN1() {
        let p = plan([PortEdit(port: "eth2", vlans: ["Guest", "vlan30"])])
        #expect(p.commands == ["delete \(sp) eth2 vlan pvid"])
        #expect(p.changes.first?.summary == "VLAN: Staff LAN, Guest, vlan30 → default, Guest, vlan30 · untagged VLAN will be removed")
    }

    @Test func nativeVLANChangeOnTrunk() {
        let p = plan([PortEdit(port: "eth2", nativeVlanID: .some(20))])
        #expect(p.commands == ["delete \(sp) eth2 vlan vid", "set \(sp) eth2 vlan pvid 20", "set \(sp) eth2 vlan vid 10", "set \(sp) eth2 vlan vid 30"])
        #expect(p.changes.first?.summary.contains("untagged VLAN: Staff LAN → Guest") == true)
    }

    @Test func portWarnings() {
        let unknown = plan([PortEdit(port: "eth1", vlans: ["nope"])])
        #expect(unknown.warnings == ["eth1: there is no VLAN named 'nope'."])
        let two = plan([PortEdit(port: "eth1", mode: .access, vlans: ["Staff LAN", "Guest"])])
        #expect(two.warnings == ["eth1: an access port can carry only one VLAN."])
        let routed = plan([PortEdit(port: "eth0", mode: .access, vlans: ["Staff LAN"])])
        #expect(routed.commands.isEmpty)
        #expect(routed.warnings.count == 1)
        #expect(routed.warnings.first?.hasPrefix("eth0 is not a VLAN-aware switch0 port.") == true)
    }

    @Test func addVLAN() {
        let p = plan(vlans: [.add(name: "iot", vlanID: 40, description: nil)])
        #expect(p.commands == ["set interfaces switch switch0 vif 40 description iot"])
        #expect(p.changes.first?.summary == "VLAN 40 'iot' will be added")
        #expect(p.warnings.isEmpty)
        #expect(plan(vlans: [.add(name: "Door cams", vlanID: 41, description: nil)]).commands
                == ["set interfaces switch switch0 vif 41 description 'Door cams'"])
        #expect(plan(vlans: [.add(name: "vlan42", vlanID: 42, description: nil)]).commands == ["set interfaces switch switch0 vif 42"])
    }

    @Test func addedVLANCanBeUsedOnAPort() {
        let p = plan([PortEdit(port: "eth3", vlans: ["iot"])], vlans: [.add(name: "iot", vlanID: 40, description: nil)])
        #expect(p.commands == ["set interfaces switch switch0 vif 40 description iot", "set \(sp) eth3 vlan pvid 40"])
        #expect(p.warnings.isEmpty)
    }

    @Test func addVLANWarnings() {
        let dup = plan(vlans: [.add(name: "Guest", vlanID: 20, description: nil)])
        #expect(dup.warnings == ["A VLAN named 'Guest' already exists.", "VLAN 20 is already used by 'Guest'."])
        #expect(plan(vlans: [.add(name: "cams", vlanID: 30, description: nil)]).warnings == ["VLAN 30 is already used by 'vlan30'."])
        #expect(plan(vlans: [.add(name: "big", vlanID: 5000, description: nil)]).warnings == ["The VLAN number must be between 1 and 4094."])
    }

    @Test func renameVLANChangesVifDescription() {
        let p = plan(vlans: [.rename(from: "Guest", to: "Visitors")])
        #expect(p.commands == ["set interfaces switch switch0 vif 20 description Visitors"])
        #expect(p.changes.first?.summary == "VLAN 'Guest' will be renamed to 'Visitors'")
        #expect(p.warnings.isEmpty)
        // VLAN 30 has no vif yet: naming it creates one.
        #expect(plan(vlans: [.rename(from: "vlan30", to: "cams")]).commands == ["set interfaces switch switch0 vif 30 description cams"])
        #expect(plan(vlans: [.rename(from: "Guest", to: "vlan20")]).commands == ["delete interfaces switch switch0 vif 20 description"])
        #expect(plan(vlans: [.rename(from: "Guest", to: "Staff LAN")]).warnings == ["A VLAN named 'Staff LAN' already exists."])
    }

    @Test func renamedVLANResolvesOnPorts() {
        let p = plan([PortEdit(port: "eth1", vlans: ["Visitors"])], vlans: [.rename(from: "Guest", to: "Visitors")])
        #expect(p.commands.last == "set \(sp) eth1 vlan pvid 20")
        #expect(p.warnings.isEmpty)
    }

    @Test func deleteVLAN() {
        let used = plan(vlans: [.delete(name: "Guest")])
        #expect(used.commands == ["delete interfaces switch switch0 vif 20"])
        #expect(used.changes.first?.summary == "VLAN 'Guest' will be deleted")
        #expect(used.warnings == ["'Guest' is used on eth2. Move those ports to another VLAN first."])

        let moved = plan([PortEdit(port: "eth2", vlans: ["Staff LAN", "vlan30"])], vlans: [.delete(name: "Guest")])
        #expect(moved.warnings.isEmpty)
        #expect(moved.commands.first == "delete interfaces switch switch0 vif 20")

        let portOnly = plan(vlans: [.delete(name: "vlan30")])
        #expect(portOnly.commands.isEmpty)
        #expect(portOnly.warnings.count == 1)

        #expect(plan(vlans: [.delete(name: "nope")]).warnings == ["There is no VLAN named 'nope'."])
    }

    @Test func vlanNumberAndDescriptionCantBeEdited() {
        let p = plan(vlans: [.update(name: "Guest", vlanID: 25, description: nil)])
        #expect(p.commands.isEmpty)
        #expect(p.warnings.count == 1)
        #expect(plan(vlans: [.update(name: "Guest", vlanID: 20, description: "")]).changes.isEmpty)
        #expect(plan(vlans: [.update(name: "Guest", vlanID: nil, description: "Visitors")]).warnings.count == 1)
    }

    @Test func vlansNeedVlanAwareSwitch0() {
        let plain = EdgeOSSnapshot.build(version: "", config: """
            set interfaces ethernet eth1 duplex auto
            set interfaces ethernet eth2 duplex auto
            set interfaces switch switch0 switch-port interface eth1
            set interfaces switch switch0 switch-port interface eth2
            set interfaces switch switch0 vif 10 description Staff
            """, interfaces: "", arp: "", lldp: "", commits: "")
        #expect(plain.port(named: "eth1")?.vlans == ["default"])
        let port = EdgeOSPlanner.plan(snapshot: plain, ports: [PortEdit(port: "eth1", vlans: ["Staff"])], vlans: [])
        #expect(port.commands.isEmpty)
        #expect(port.warnings.first?.hasPrefix("eth1 is not a VLAN-aware switch0 port.") == true)
        let add = EdgeOSPlanner.plan(snapshot: plain, ports: [], vlans: [.add(name: "iot", vlanID: 40, description: nil)])
        #expect(add.warnings == ["VLANs on EdgeOS need the switch0 interface with vlan-aware enabled. Set that up on the router first."])
    }
}
