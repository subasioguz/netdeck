import Foundation
import Testing
@testable import NetdeckCore

// MARK: - Fixtures

func mikrotikFixture(_ name: String) throws -> String {
    L10n.language = .en
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/synthetic/mikrotik"))
    return try String(contentsOf: url, encoding: .utf8)
}

func mikrotikOutputs() throws -> MikroTikOutputs {
    var o = MikroTikOutputs()
    o.identity = try mikrotikFixture("identity")
    o.resource = try mikrotikFixture("resource")
    o.routerboard = try mikrotikFixture("routerboard")
    o.ethernet = try mikrotikFixture("ethernet")
    o.interfaces = try mikrotikFixture("interface")
    o.bridges = try mikrotikFixture("bridge")
    o.bridgePorts = try mikrotikFixture("bridge-port")
    o.bridgeVLANs = try mikrotikFixture("bridge-vlan")
    o.vlanInterfaces = try mikrotikFixture("interface-vlan")
    o.hosts = try mikrotikFixture("bridge-host")
    o.neighbors = try mikrotikFixture("ip-neighbor")
    o.addresses = try mikrotikFixture("ip-address")
    o.export = try mikrotikFixture("export")
    return o
}

func mikrotikSnapshot(_ change: (inout MikroTikOutputs) -> Void = { _ in }) throws -> SwitchSnapshot {
    var o = try mikrotikOutputs()
    change(&o)
    return MikroTikSnapshotBuilder.build(o)
}

// MARK: - Parsers

@Suite struct MikroTikParserTests {
    @Test func terseLineWithFlagsQuotesAndSpaces() throws {
        let lines = MikroTikParsers.terse(try mikrotikFixture("interface"))
        let ether1 = try #require(lines.first { $0["name"] == "ether1" })
        #expect(ether1.index == 0)
        #expect(ether1.has("R"))
        #expect(ether1.has("S"))
        #expect(ether1["comment"] == "Server rack A")
        #expect(ether1["last-link-up-time"] == "2026-11-17 08:12:40")
        #expect(ether1["last-link-down-time"] == "2026-11-17 08:12:31")
        #expect(ether1["link-downs"] == "1")
        let disabled = try #require(lines.first { $0["name"] == "ether24" })
        #expect(disabled.isDisabled)
        #expect(!disabled.has("R"))
    }

    @Test func unquotedValueWithSpacesRunsToNextKey() throws {
        let ether3 = try #require(MikroTikParsers.terse(try mikrotikFixture("ethernet")).first { $0["default-name"] == "ether3" })
        #expect(ether3["comment"] == "AP lobby")
        #expect(ether3["name"] == "ether3")
    }

    @Test func quotedValuesAndEscapes() throws {
        let r = try #require(MikroTikParsers.record(#" 3 X  comment="say \"hi\" \$5 \3F gr\C3\BCn" name=x empty="" list=a,b"#))
        #expect(r.index == 3)
        #expect(r.flags == "X")
        #expect(r["comment"] == "say \"hi\" $5 ? grün")
        #expect(r["name"] == "x")
        #expect(r["empty"] == "")
        #expect(r.list("list") == ["a", "b"])
        #expect(r.list("empty").isEmpty)
        #expect(MikroTikParsers.record("Flags: X - DISABLED") == nil)
    }

    @Test func neighborsKeepQuotedSpaces() throws {
        let n = MikroTikParsers.terse(try mikrotikFixture("ip-neighbor"))
        #expect(n.count == 2)
        #expect(n[0]["version"] == "7.16.2 (stable)")
        #expect(n[0]["system-description"] == "MikroTik RouterOS 7.16.2 (stable) CCR2004-1G-12S+2XS")
        #expect(n[0]["identity"] == "core-rtr")
        #expect(n[1]["platform"] == "")
        #expect(n[1]["interface"] == "ether3,bridge")
    }

    @Test func schedulerEntry() throws {
        let s = try #require(MikroTikParsers.terse(try mikrotikFixture("scheduler")).first)
        #expect(s["name"] == "netdeck-revert")
        #expect(s["on-event"] == "/system script run netdeck-undo")
        #expect(s["next-run"] == "2026-11-17 10:26:39")
        #expect(s["comment"] == "Netdeck: ether3")
    }

    @Test func resourceAndRouterboard() throws {
        let r = MikroTikParsers.keyValues(try mikrotikFixture("resource"))
        #expect(r["version"] == "7.16.2 (stable)")
        #expect(r["board-name"] == "CRS326-24G-2S+")
        #expect(r["uptime"] == "12d4h3m10s")
        #expect(r["build-time"] == "2024-11-26 13:52:37")
        #expect(r["platform"] == "MikroTik")
        let b = MikroTikParsers.keyValues(try mikrotikFixture("routerboard"))
        #expect(b["routerboard"] == "yes")
        #expect(b["model"] == "CRS326-24G-2S+")
        #expect(b["serial-number"] == "TEST0000001")
        #expect(MikroTikParsers.keyValues(try mikrotikFixture("identity"))["name"] == "sw-core-01")
    }

    @Test func vlanIDLists() {
        #expect(MikroTikParsers.vlanIDs("10") == [10])
        #expect(MikroTikParsers.vlanIDs("10,20,100-103") == [10, 20, 100, 101, 102, 103])
        #expect(MikroTikParsers.vlanIDs("").isEmpty)
        #expect(MikroTikParsers.vlanIDString([10, 20, 21, 22]) == "10,20-22")
        #expect(MikroTikParsers.vlanIDString([30, 10, 11]) == "10,11,30")
    }

    @Test func trailingNumbers() {
        #expect(MikroTikParsers.trailingNumber("ether12") == 12)
        #expect(MikroTikParsers.trailingNumber("sfp-sfpplus2") == 2)
        #expect(MikroTikParsers.trailingNumber("bridge") == nil)
        let lane = MikroTikSnapshotBuilder.numberAndLabel("qsfp28-1-3")
        #expect(lane.number == 1)
        #expect(lane.label == "1-3")
        #expect(MikroTikSnapshotBuilder.numberAndLabel("ether7").label == nil)
    }
}

// MARK: - Snapshot

@Suite struct MikroTikSnapshotTests {
    @Test func portsFromCRS326() throws {
        let s = try mikrotikSnapshot()
        #expect(s.platform == .mikrotikRouterOS)
        #expect(s.readKind == .switchDevice)
        #expect(s.hostname == "sw-core-01")
        #expect(s.hardware.model == "CRS326-24G-2S+")
        #expect(s.hardware.serial == "TEST0000001")
        #expect(s.osVersion == "7.16.2")
        #expect(s.commits.isEmpty)
        // The export's time stamp is dropped, so unchanged configurations don't make new backups.
        #expect(s.configText.hasPrefix("# by RouterOS 7.16.2\n# software id = TEST-0001"))
        #expect(s.configText.contains("/interface bridge add admin-mac=48:A9:8A:00:00:00 auto-mac=no comment=defconf name=bridge vlan-filtering=yes"))

        let ports = s.ports
        #expect(ports.count == 26)
        #expect(ports.prefix(24).allSatisfy { $0.kind == .copper })
        #expect(ports.suffix(2).allSatisfy { $0.kind == .sfp })
        #expect(ports.first?.slotKey == "ether1")
        #expect(Array(ports.map(\.number).prefix(3)) == [1, 2, 3])
        #expect(ports.suffix(2).map(\.number) == [1, 2])
    }

    @Test func renamedPortKeepsDefaultName() throws {
        let s = try mikrotikSnapshot()
        let uplink = try #require(s.ports.first { $0.slotKey == "sfp-sfpplus1" })
        #expect(uplink.name == "uplink")
        #expect(uplink.defaultName == "sfp-sfpplus1")
        #expect(uplink.description == "Core uplink")
        #expect(uplink.linkUp)
        #expect(uplink.mode == .trunk)
        #expect(uplink.vlans == ["default", "office", "vlan20"])
        #expect(uplink.nativeVlanID == 1)
        #expect(uplink.lldp.first?.systemName == "core-rtr")
        #expect(uplink.lldp.first?.portInfo == "sfp-sfpplus1")
        #expect(uplink.macs.count == 2)
    }

    @Test func accessPortsAndVLANNames() throws {
        let s = try mikrotikSnapshot()
        let ether1 = try #require(s.port(named: "ether1"))
        #expect(ether1.mode == .access)
        #expect(ether1.vlans == ["office"])
        #expect(ether1.description == "Server rack A")
        #expect(ether1.switching)
        #expect(ether1.macs.map(\.mac) == ["00:0c:29:00:00:01"])
        #expect(ether1.macs.first?.vlan == "office")
        let ether9 = try #require(s.port(named: "ether9"))
        #expect(ether9.vlans == ["vlan20"])
        let ether13 = try #require(s.port(named: "ether13"))
        #expect(ether13.vlans == ["default"])
        let ether3 = try #require(s.port(named: "ether3"))
        #expect(ether3.lldp.first?.systemName == "ap-lobby")
        let ether24 = try #require(s.port(named: "ether24"))
        #expect(ether24.configDisabled)
        #expect(!ether24.adminUp)
        #expect(ether24.state == .disabled)

        #expect(s.config.vlans.map(\.name) == ["default", "office", "vlan20", "vlan99"])
        #expect(s.config.vlans.compactMap(\.vlanID) == [1, 10, 20, 99])
        #expect(s.config.vlan(named: "office")?.description == "Office LAN")
        #expect(s.config.vlan(named: "office")?.l3Interface == "office")
        #expect(s.config.vlan(named: "vlan20")?.description == "Guests")
    }

    @Test func routedPortOutsideTheBridge() throws {
        let s = try mikrotikSnapshot()
        let p = try #require(s.ports.first { $0.slotKey == "sfp-sfpplus2" })
        #expect(!p.switching)
        #expect(p.mode == nil)
        #expect(p.addresses == ["198.51.100.2/30"])
        #expect(p.isRouted)
        #expect(p.speed == "10G-baseCR")
        #expect(p.description == "to firewall")
    }

    @Test func macTableSkipsLocalEntries() throws {
        let s = try mikrotikSnapshot()
        #expect(s.macTable.count == 6)
        #expect(!s.macTable.contains { $0.mac == "48:a9:8a:00:00:00" })
    }

    @Test func withoutVLANFilteringTheBridgeIsOneNetwork() throws {
        let s = try mikrotikSnapshot { $0.bridges = $0.bridges.replacingOccurrences(of: "vlan-filtering=yes", with: "vlan-filtering=no") }
        #expect(s.config.vlans.map(\.name) == ["default"])
        let ether2 = try #require(s.port(named: "ether2"))
        #expect(ether2.vlans == ["default"])
        let uplink = try #require(s.ports.first { $0.slotKey == "sfp-sfpplus1" })
        #expect(uplink.mode == .access)
        // Still a CRS: a switch.
        #expect(s.readKind == .switchDevice)
    }
}

// MARK: - Planner

@Suite struct MikroTikPlannerTests {
    let snap: SwitchSnapshot

    init() throws { snap = try mikrotikSnapshot() }

    func plan(_ ports: [PortEdit], _ vlans: [VLANEdit] = []) -> ChangePlan {
        Planner.plan(snapshot: snap, ports: ports, vlans: vlans)
    }

    @Test func descriptionChange() {
        let p = plan([PortEdit(port: "ether3", description: "Printer")])
        #expect(p.commands == [#"/interface ethernet set [find default-name=ether3] comment="Printer""#])
        #expect(p.undoCommands == [#"/interface ethernet set [find default-name=ether3] comment="AP lobby""#])
        #expect(p.changes.first?.summary == "description: AP lobby → Printer")
        #expect(p.warnings.isEmpty)
    }

    @Test func renamedPortIsFoundByDefaultName() {
        let p = plan([PortEdit(port: "uplink", description: "")])
        #expect(p.commands == [#"/interface ethernet set [find default-name=sfp-sfpplus1] comment="""#])
        #expect(p.undoCommands == [#"/interface ethernet set [find default-name=sfp-sfpplus1] comment="Core uplink""#])
        #expect(p.changes.first?.subject == "uplink")
    }

    @Test func disableAndEnable() {
        let off = plan([PortEdit(port: "ether5", enabled: false)])
        #expect(off.commands == ["/interface ethernet set [find default-name=ether5] disabled=yes"])
        #expect(off.undoCommands == ["/interface ethernet set [find default-name=ether5] disabled=no"])
        #expect(off.changes.first?.summary == "will be disabled")
        let on = plan([PortEdit(port: "ether24", enabled: true)])
        #expect(on.commands == ["/interface ethernet set [find default-name=ether24] disabled=no"])
        #expect(on.undoCommands == ["/interface ethernet set [find default-name=ether24] disabled=yes"])
    }

    @Test func unchangedEditsPlanNothing() {
        #expect(plan([PortEdit(port: "ether2", enabled: true, mode: .access, vlans: ["office"])]).isEmpty)
        #expect(plan([PortEdit(port: "ether1", description: "Server rack A")]).changes.isEmpty)
    }

    @Test func accessVLANChange() {
        let p = plan([PortEdit(port: "ether2", vlans: ["vlan20"])])
        #expect(p.commands == [
            "/interface bridge port set [find interface=ether2] pvid=20",
            "/interface bridge vlan set [find bridge=bridge vlan-ids=10] untagged=ether1,ether3,ether4,ether5,ether6,ether7,ether8",
            "/interface bridge vlan set [find bridge=bridge vlan-ids=20] untagged=ether2,ether9,ether10,ether11,ether12",
        ])
        #expect(p.undoCommands == [
            "/interface bridge vlan set [find bridge=bridge vlan-ids=20] untagged=ether9,ether10,ether11,ether12",
            "/interface bridge vlan set [find bridge=bridge vlan-ids=10] untagged=ether1,ether2,ether3,ether4,ether5,ether6,ether7,ether8",
            "/interface bridge port set [find interface=ether2] pvid=10",
        ])
        #expect(p.changes.first?.summary == "VLAN: office → vlan20")
        #expect(p.warnings.isEmpty)
    }

    @Test func accessPortLeavesDefaultVLAN() {
        let p = plan([PortEdit(port: "ether13", vlans: ["office"])])
        #expect(p.commands == [
            "/interface bridge port set [find interface=ether13] pvid=10 frame-types=admit-only-untagged-and-priority-tagged",
            "/interface bridge vlan set [find bridge=bridge vlan-ids=10] untagged=ether1,ether2,ether3,ether4,ether5,ether6,ether7,ether8,ether13",
        ])
        #expect(p.undoCommands == [
            "/interface bridge vlan set [find bridge=bridge vlan-ids=10] untagged=ether1,ether2,ether3,ether4,ether5,ether6,ether7,ether8",
            "/interface bridge port set [find interface=ether13] pvid=1 frame-types=admit-all",
        ])
    }

    @Test func accessPortToTrunkWithCompleteTaggedLists() {
        let p = plan([PortEdit(port: "ether13", mode: .trunk, vlans: ["default", "office", "vlan20"], nativeVlanID: .some(1))])
        #expect(p.commands == [
            "/interface bridge vlan set [find bridge=bridge vlan-ids=10] tagged=bridge,ether13,uplink",
            "/interface bridge vlan set [find bridge=bridge vlan-ids=20] tagged=ether13,uplink",
        ])
        #expect(p.undoCommands == [
            "/interface bridge vlan set [find bridge=bridge vlan-ids=20] tagged=uplink",
            "/interface bridge vlan set [find bridge=bridge vlan-ids=10] tagged=bridge,uplink",
        ])
        #expect(p.changes.first?.summary
            == "mode: single network (access) → multiple networks (trunk) · VLAN: default → default, office, vlan20 · untagged VLAN: — → 1")
        #expect(p.warnings.isEmpty)
    }

    @Test func trunkDropsVLANAndNative() {
        let p = plan([PortEdit(port: "uplink", vlans: ["office"], nativeVlanID: .some(nil))])
        #expect(p.commands == [
            "/interface bridge port set [find interface=uplink] frame-types=admit-only-vlan-tagged",
            #"/interface bridge vlan set [find bridge=bridge vlan-ids=20] tagged="""#,
        ])
        #expect(p.undoCommands == [
            "/interface bridge vlan set [find bridge=bridge vlan-ids=20] tagged=uplink",
            "/interface bridge port set [find interface=uplink] frame-types=admit-all",
        ])
        #expect(p.changes.first?.summary == "VLAN: default, office, vlan20 → office · untagged VLAN will be removed")
    }

    @Test func twoPortsOnOneEntryUseUpdatedLists() throws {
        let p = plan([PortEdit(port: "ether13", vlans: ["vlan20"]), PortEdit(port: "ether14", vlans: ["vlan20"])])
        #expect(p.commands.contains("/interface bridge vlan set [find bridge=bridge vlan-ids=20] untagged=ether9,ether10,ether11,ether12,ether13"))
        #expect(p.commands.contains("/interface bridge vlan set [find bridge=bridge vlan-ids=20] untagged=ether9,ether10,ether11,ether12,ether13,ether14"))
        // Undo runs newest first: back to ether13's list, then to the original.
        let back = try #require(p.undoCommands.firstIndex(of: "/interface bridge vlan set [find bridge=bridge vlan-ids=20] untagged=ether9,ether10,ether11,ether12,ether13"))
        let original = try #require(p.undoCommands.firstIndex(of: "/interface bridge vlan set [find bridge=bridge vlan-ids=20] untagged=ether9,ether10,ether11,ether12"))
        #expect(back < original)
    }

    @Test func unknownVLANAndTwoVLANsOnAccessWarn() {
        let p = plan([PortEdit(port: "ether2", vlans: ["nope"]), PortEdit(port: "ether4", vlans: ["office", "vlan20"])])
        #expect(p.warnings.contains("ether2: there is no VLAN named 'nope'."))
        #expect(p.warnings.contains("ether4: an access port can carry only one VLAN."))
    }

    @Test func addVLANAndUseIt() {
        let p = plan([PortEdit(port: "ether14", vlans: ["cameras"])], [.add(name: "cameras", vlanID: 30, description: nil)])
        #expect(p.commands == [
            #"/interface bridge vlan add bridge=bridge vlan-ids=30 comment="cameras""#,
            "/interface bridge port set [find interface=ether14] pvid=30 frame-types=admit-only-untagged-and-priority-tagged",
            "/interface bridge vlan set [find bridge=bridge vlan-ids=30] untagged=ether14",
        ])
        #expect(p.undoCommands == [
            #"/interface bridge vlan set [find bridge=bridge vlan-ids=30] untagged="""#,
            "/interface bridge port set [find interface=ether14] pvid=1 frame-types=admit-all",
            "/interface bridge vlan remove [find bridge=bridge vlan-ids=30]",
        ])
        #expect(p.changes.first?.summary == "VLAN 30 'cameras' will be added")
        #expect(p.warnings.isEmpty)
    }

    @Test func addVLANChecks() {
        let p = plan([], [.add(name: "office", vlanID: 20, description: "x")])
        #expect(p.warnings.contains("A VLAN named 'office' already exists."))
        #expect(p.warnings.contains("VLAN 20 is already used by 'vlan20'."))
    }

    @Test func deleteUnusedVLANReAddsItOnUndo() {
        let p = plan([], [.delete(name: "vlan99")])
        #expect(p.commands == ["/interface bridge vlan remove [find bridge=bridge vlan-ids=99]"])
        #expect(p.undoCommands == [
            #":if ([:len [/interface bridge vlan find bridge=bridge vlan-ids=99]] = 0) do={/interface bridge vlan add bridge=bridge vlan-ids=99 comment="Spare"}"#,
        ])
        #expect(p.warnings.isEmpty)
        #expect(p.changes.first?.summary == "VLAN 'vlan99' will be deleted")
    }

    @Test func deleteUsedVLANWarns() {
        let p = plan([], [.delete(name: "vlan20")])
        #expect(p.warnings == ["'vlan20' is used on ether9, ether10, ether11, ether12, uplink. Move those ports to another VLAN first."])
        #expect(p.undoCommands.first?.contains("tagged=uplink untagged=ether9,ether10,ether11,ether12 comment=\"Guests\"") == true)
        let office = plan([], [.delete(name: "office")])
        #expect(office.warnings.contains("VLAN 'office' has the VLAN interface 'office' on the router. Remove that interface first."))
    }

    @Test func deleteAfterMovingPortsInSamePlan() {
        let moves = (9...12).map { PortEdit(port: "ether\($0)", vlans: ["office"]) } + [PortEdit(port: "uplink", vlans: ["default", "office"])]
        let p = plan(moves, [.delete(name: "vlan20")])
        #expect(p.warnings.isEmpty)
        #expect(p.changes.last?.commands == ["/interface bridge vlan remove [find bridge=bridge vlan-ids=20]"])
        // The re-added entry gets the lists it had right before the removal: all moved away.
        #expect(p.changes.last?.undo == [
            #":if ([:len [/interface bridge vlan find bridge=bridge vlan-ids=20]] = 0) do={/interface bridge vlan add bridge=bridge vlan-ids=20 comment="Guests"}"#,
        ])
    }

    @Test func updateVLANDescriptionAndNumber() {
        let p = plan([], [.update(name: "vlan20", vlanID: 25, description: "Visitors")])
        #expect(p.commands == [
            "/interface bridge vlan set [find bridge=bridge vlan-ids=20] vlan-ids=25",
            "/interface bridge port set [find interface=ether9] pvid=25",
            "/interface bridge port set [find interface=ether10] pvid=25",
            "/interface bridge port set [find interface=ether11] pvid=25",
            "/interface bridge port set [find interface=ether12] pvid=25",
            #"/interface bridge vlan set [find bridge=bridge vlan-ids=25] comment="Visitors""#,
        ])
        #expect(p.undoCommands == [
            #"/interface bridge vlan set [find bridge=bridge vlan-ids=25] comment="Guests""#,
            "/interface bridge port set [find interface=ether12] pvid=20",
            "/interface bridge port set [find interface=ether11] pvid=20",
            "/interface bridge port set [find interface=ether10] pvid=20",
            "/interface bridge port set [find interface=ether9] pvid=20",
            "/interface bridge vlan set [find bridge=bridge vlan-ids=25] vlan-ids=20",
        ])
        #expect(p.changes.first?.summary == "VLAN 'vlan20': number: 20 → 25 · description: Guests → Visitors")
    }

    @Test func renameNeedsAVLANInterface() {
        let p = plan([], [.rename(from: "office", to: "staff")])
        #expect(p.commands == ["/interface vlan set [find name=office] name=staff"])
        #expect(p.undoCommands == ["/interface vlan set [find name=staff] name=office"])
        let q = plan([], [.rename(from: "vlan20", to: "guests")])
        #expect(q.commands.isEmpty)
        #expect(q.warnings.count == 1)
    }

    @Test func sharedEntryNeedsSplit() throws {
        let shared = try mikrotikSnapshot { o in
            o.bridgeVLANs = """
             0   bridge=bridge vlan-ids=10,20 tagged=bridge,uplink untagged="" current-tagged=bridge,uplink current-untagged=""
             1 D bridge=bridge vlan-ids=1 tagged="" untagged="" current-tagged="" current-untagged=bridge,ether13,ether14,uplink
            """
        }
        let split = Planner.plan(snapshot: shared, ports: [PortEdit(port: "ether13", mode: .trunk, vlans: ["default", "office"], nativeVlanID: .some(1))], vlans: [])
        #expect(split.warnings == ["VLANs 10,20 share one bridge VLAN entry on the router. Split it into one entry per VLAN first."])
        let both = Planner.plan(snapshot: shared, ports: [PortEdit(port: "ether14", mode: .trunk, vlans: ["default", "office", "vlan20"], nativeVlanID: .some(1))], vlans: [])
        #expect(both.warnings.isEmpty)
        #expect(both.commands == ["/interface bridge vlan set [find bridge=bridge vlan-ids=10,20] tagged=bridge,ether14,uplink"])
    }

    @Test func taggingIntoVLANWithoutStaticEntryAddsOne() {
        let p = plan([PortEdit(port: "ether15", mode: .trunk, vlans: ["default", "office"], nativeVlanID: .some(nil))])
        // VLAN 1 only exists dynamically: tagging into it needs a static entry; undo removes it again.
        #expect(p.commands == [
            "/interface bridge port set [find interface=ether15] frame-types=admit-only-vlan-tagged",
            "/interface bridge vlan set [find bridge=bridge vlan-ids=10] tagged=bridge,ether15,uplink",
            "/interface bridge vlan add bridge=bridge vlan-ids=1 tagged=ether15",
        ])
        #expect(p.undoCommands.first == "/interface bridge vlan remove [find bridge=bridge vlan-ids=1]")
    }

    @Test func withoutVLANFilteringOnlyVLANEditsAreBlocked() throws {
        let flat = try mikrotikSnapshot { $0.bridges = $0.bridges.replacingOccurrences(of: "vlan-filtering=yes", with: "vlan-filtering=no") }
        let p = Planner.plan(snapshot: flat, ports: [PortEdit(port: "ether2", description: "Desk", vlans: ["vlan20"])], vlans: [])
        #expect(p.commands == [#"/interface ethernet set [find default-name=ether2] comment="Desk""#])
        #expect(p.warnings == ["ether2: VLANs on RouterOS need bridge VLAN filtering. Add the port to the bridge and turn on vlan-filtering first."])
        let v = Planner.plan(snapshot: flat, ports: [], vlans: [.add(name: "cameras", vlanID: 30, description: nil)])
        #expect(v.commands.isEmpty)
        #expect(v.warnings == ["VLANs on RouterOS need bridge VLAN filtering. Turn on vlan-filtering on the bridge first."])
        let routed = Planner.plan(snapshot: try mikrotikSnapshot(), ports: [PortEdit(port: "sfp-sfpplus2", vlans: ["office"])], vlans: [])
        #expect(routed.warnings.count == 1)
        #expect(routed.commands.isEmpty)
    }

    @Test func quotingOfComments() {
        let p = plan([PortEdit(port: "ether6", description: #"Desk "A" $5 \ ok? Şube"#)])
        #expect(p.commands == [#"/interface ethernet set [find default-name=ether6] comment="Desk \"A\" \$5 \\ ok\3F \C5\9Eube""#])
    }
}

// MARK: - Safety net

@Suite struct MikroTikSafetyNetTests {
    @Test func escaping() {
        #expect(MikroTikQuote.escape(#"a"b\c$d?e Ş"#) == #"a\"b\\c\$d\3Fe \C5\9E"#)
        #expect(MikroTikQuote.escape("line\nnext\ttab") == #"line\nnext\ttab"#)
        #expect(MikroTikQuote.value("ether1,ether2") == "ether1,ether2")
        #expect(MikroTikQuote.value("my port") == #""my port""#)
        #expect(MikroTikQuote.value("") == #""""#)
        #expect(MikroTikParsers.unescape(MikroTikQuote.escape(#"a"b\c$d?e Ş"#)) == #"a"b\c$d?e Ş"#)
    }

    @Test func undoScriptSource() {
        let source = MikroTikSafetyNet.undoSource([#"/interface ethernet set [find default-name=ether3] comment="a\"b""#])
        #expect(source == #":do {/interface ethernet set [find default-name=ether3] comment="a\"b"} on-error={}; :log warning "Netdeck: previous settings restored"; /system scheduler remove [find name=netdeck-revert]; /system script remove [find name=netdeck-undo]"#)
        let cmds = MikroTikSafetyNet.scriptCommands(source: source, chunk: 10_000)
        #expect(cmds == [#"/system script add name=netdeck-undo policy=read,write source=":do {/interface ethernet set [find default-name=ether3] comment=\"a\\\"b\"} on-error={}; :log warning \"Netdeck: previous settings restored\"; /system scheduler remove [find name=netdeck-revert]; /system script remove [find name=netdeck-undo]""#])
    }

    @Test func longScriptIsSentInPiecesThatJoinUp() {
        let undo = (1...40).map { #"/interface ethernet set [find default-name=ether\#($0)] comment="Raum \#($0) ? Ünite""# }
        let source = MikroTikSafetyNet.undoSource(undo)
        let pieces = MikroTikSafetyNet.escapedChunks(source, limit: 120)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.count <= 120 })
        #expect(pieces.map(MikroTikParsers.unescape).joined() == source)
        let cmds = MikroTikSafetyNet.scriptCommands(source: source)
        #expect(cmds.first?.hasPrefix("/system script add name=netdeck-undo policy=read,write source=\"") == true)
        #expect(cmds.dropFirst().allSatisfy { $0.hasPrefix("/system script set [find name=netdeck-undo] source=([/system script get [find name=netdeck-undo] source] . \"") })
        #expect(cmds.allSatisfy { $0.count <= MikroTikSafetyNet.maxCommandLength })
        // Only ASCII is typed on the console.
        #expect(cmds.allSatisfy { $0.allSatisfy(\.isASCII) && !$0.contains("?") })
    }

    @Test func clockISOMidnightAndYearRollover() throws {
        let now = try #require(MikroTikParsers.clock(try mikrotikFixture("clock-iso")))
        #expect(now == MikroTikClock(year: 2026, month: 12, day: 31, hour: 23, minute: 58, second: 30, isoDates: true))
        let deadline = try #require(now.adding(minutes: 5))
        #expect(deadline.dateString == "2027-01-01")
        #expect(deadline.timeString == "00:03:30")
        #expect(deadline.isAfter(now))
    }

    @Test func clockLegacyFormat() throws {
        let now = try #require(MikroTikParsers.clock(try mikrotikFixture("clock-legacy")))
        #expect(!now.isoDates)
        #expect(now.dateString == "nov/17/2026")
        let deadline = try #require(now.adding(minutes: 5))
        #expect(deadline.dateString == "nov/17/2026")
        #expect(deadline.timeString == "10:26:39")
        let lateFebruary = MikroTikClock(year: 2026, month: 2, day: 28, hour: 23, minute: 57, second: 0, isoDates: false)
        #expect(lateFebruary.adding(minutes: 10)?.dateString == "mar/01/2026")
        #expect(lateFebruary.adding(minutes: 10)?.timeString == "00:07:00")
        let leap = MikroTikClock(year: 2028, month: 2, day: 28, hour: 23, minute: 59, second: 0)
        #expect(leap.adding(minutes: 3)?.dateString == "2028-02-29")
    }

    @Test func schedulerCommandAndArmedCheck() throws {
        let now = try #require(MikroTikParsers.clock(try mikrotikFixture("clock-legacy")))
        let deadline = try #require(now.adding(minutes: 5))
        #expect(MikroTikSafetyNet.schedulerAdd(deadline: deadline, comment: "Netdeck: ether3 → Şube")
            == #"/system scheduler add name=netdeck-revert start-date=nov/17/2026 start-time=10:26:39 interval=0s policy=read,write on-event="/system script run netdeck-undo" comment="Netdeck: ether3 -> Sube""#)

        let entry = try #require(MikroTikParsers.terse(try mikrotikFixture("scheduler")).first)
        #expect(MikroTikSafetyNet.isArmed(entry, now: now, deadline: deadline))
        let later = MikroTikClock(year: 2026, month: 11, day: 17, hour: 10, minute: 30, second: 0)
        #expect(!MikroTikSafetyNet.isArmed(entry, now: later, deadline: deadline))
        #expect(!MikroTikSafetyNet.hasRun(entry))
        var ran = entry
        ran.fields["run-count"] = "1"
        #expect(MikroTikSafetyNet.hasRun(ran))
        var disabled = entry
        disabled.flags = "X"
        #expect(!MikroTikSafetyNet.isArmed(disabled, now: now, deadline: deadline))
        // A bare time past midnight is the deadline's time.
        let lateNow = MikroTikClock(year: 2026, month: 12, day: 31, hour: 23, minute: 58, second: 30)
        let lateDeadline = try #require(lateNow.adding(minutes: 5))
        let bare = MikroTikRecord(index: 0, flags: "", fields: ["name": "netdeck-revert", "next-run": "00:03:30"])
        #expect(MikroTikSafetyNet.isArmed(bare, now: lateNow, deadline: lateDeadline))
    }

    @Test func pendingChangeDescription() throws {
        let entry = try #require(MikroTikParsers.terse(try mikrotikFixture("scheduler")).first)
        let text = MikroTikSafetyNet.describe(entry, source: ":do {/interface ethernet set [find default-name=ether3] comment=\"AP lobby\"} on-error={}; /system scheduler remove [find name=netdeck-revert]")
        #expect(text.hasPrefix("# Netdeck: ether3\n# Undo runs at 2026-11-17 10:26:39 (router time)\n"))
        #expect(text.hasSuffix("/system scheduler remove [find name=netdeck-revert]"))
    }
}

// MARK: - Dialect

@Suite struct MikroTikDialectTests {
    @Test func prompts() {
        L10n.language = .en
        #expect(MikroTikDialect.promptKind("[admin@MikroTik] > ") == .operational)
        #expect(MikroTikDialect.promptKind("[admin@MikroTik] /interface> ") == .operational)
        #expect(MikroTikDialect.promptKind("[admin@MikroTik] <SAFE> ") == .operational)
        #expect(MikroTikDialect.promptKind("[admin@My Router] /ip address> ") == .operational)
        #expect(MikroTikDialect.promptKind("[admin@MikroTik] /ip/address> ") == .operational)
        #expect(MikroTikDialect.promptKind("\u{1B}7[admin@sw-core-01] > ") == .operational)
        #expect(MikroTikDialect.promptKind("MikroTik Login: ") == .login)
        #expect(MikroTikDialect.promptKind("Password: ") == .password)
        #expect(MikroTikDialect.promptKind("new password> ") == .shell)
        #expect(MikroTikDialect.promptKind("Do you want to see the software license? [Y/n]: ") == .question)
        #expect(MikroTikDialect.promptKind("Please press \"Enter\" to continue!") == .pager)
        #expect(MikroTikDialect.promptKind(#"To remove this default configuration type "r" or hit any other key to continue."#) == .question)
        #expect(MikroTikDialect.promptKind("  name: sw-core-01") == nil)
        #expect(MikroTikDialect.promptKind("[admin@MikroTik] > /system identity print") == nil)
        #expect(MikroTikDialect.promptKind(" 0 R  name=ether1 default-name=ether1") == nil)
    }

    @Test func loginAndAnswers() {
        let d = MikroTikDialect()
        #expect(MikroTikDialect.loginName("admin") == "admin+ct511w4098h")
        #expect(d.loginName("admin") == "admin+ct511w4098h")
        #expect(MikroTikDialect.loginName("admin+ct80w") == "admin+ct80w")
        #expect(d.setupCommands.isEmpty)
        #expect(d.advance(from: .question) == "n")
        #expect(d.advance(from: .pager) == "\r")
        #expect(d.advance(from: .shell) == nil)
        #expect(d.logout(from: .operational) == "/quit\r")
        #expect(d.logout(from: .shell) == nil)
        #expect(MikroTikDialect.asksForNewPassword("Change your password\n\nnew password> "))
        #expect(d.isLoginFailure("Login failed, incorrect username or password"))
    }

    @Test func errorLines() {
        let out = "syntax error (line 1 column 9)\nfailure: already have such entry\ninput does not match any value of interface\nname: x"
        #expect(MikroTikDialect.errorLines(out).count == 3)
        #expect(MikroTikDialect.errorLines("  name: sw-core-01\n").isEmpty)
    }

    @Test func outputWithoutEchoAndMarker() {
        let sent = "/system identity print" + MikroTikDialect.markerSuffix
        // The first echo line is gone (CLISession); a redrawn rest of the echo is still there.
        let text = "ty print; :put (\"netdeck-\" . \"done\")\n  name: sw-core-01\nnetdeck-done\n\n[admin@sw-core-01] > "
        let r = MikroTikDialect.output(text, sent: sent, marker: true)
        #expect(r.output == "  name: sw-core-01")
        #expect(r.confirmed)
        let failed = MikroTikDialect.output("syntax error (line 1 column 9)\n[admin@sw-core-01] > ", sent: sent, marker: true)
        #expect(!failed.confirmed)
        #expect(failed.output == "syntax error (line 1 column 9)")
    }

    @Test func sessionStripUsesDialect() {
        let raw = "[admin@sw] > /system identity print\r\n  name: sw\r\n\r\n[admin@sw] > "
        #expect(CLISession.strip(raw, dialect: MikroTikDialect()) == "  name: sw")
    }
}
