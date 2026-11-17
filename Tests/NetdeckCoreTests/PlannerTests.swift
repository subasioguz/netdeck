import Foundation
import Testing
@testable import NetdeckCore

@Suite struct PlannerTests {
    let cfg: JunosConfig

    init() throws { cfg = SetConfigParser.parse(try fixture("config-set")) }

    @Test func descriptionChange() {
        let plan = ChangePlanner.plan(ports: [PortEdit(port: "ge-0/0/2", description: "SRV02-IDRAC")], vlans: [], config: cfg)
        #expect(plan.commands == ["set interfaces ge-0/0/2 description SRV02-IDRAC"])
        #expect(plan.changes.first?.summary == "description: R640-PVE-01 → SRV02-IDRAC")
    }

    @Test func enablingFirstPortOfRangeShrinksIt() {
        let plan = ChangePlanner.plan(ports: [PortEdit(port: "ge-0/0/3", enabled: true)], vlans: [], config: cfg)
        #expect(plan.commands == [
            "delete interfaces interface-range UNUSED member-range ge-0/0/3",
            "set interfaces interface-range UNUSED member-range ge-0/0/4 to ge-0/0/23",
        ])
    }

    @Test func enablingMiddlePortSplitsRange() {
        let plan = ChangePlanner.plan(ports: [PortEdit(port: "ge-0/0/10", enabled: true)], vlans: [], config: cfg)
        #expect(plan.commands == [
            "delete interfaces interface-range UNUSED member-range ge-0/0/3",
            "set interfaces interface-range UNUSED member-range ge-0/0/3 to ge-0/0/9",
            "set interfaces interface-range UNUSED member-range ge-0/0/11 to ge-0/0/23",
        ])
    }

    @Test func enablingTwoPortsOfSameRangeUsesUpdatedRange() {
        let plan = ChangePlanner.plan(
            ports: [PortEdit(port: "ge-0/0/3", enabled: true), PortEdit(port: "ge-0/0/4", enabled: true)],
            vlans: [], config: cfg)
        #expect(plan.commands == [
            "delete interfaces interface-range UNUSED member-range ge-0/0/3",
            "set interfaces interface-range UNUSED member-range ge-0/0/4 to ge-0/0/23",
            "delete interfaces interface-range UNUSED member-range ge-0/0/4",
            "set interfaces interface-range UNUSED member-range ge-0/0/5 to ge-0/0/23",
        ])
    }

    @Test func singlePortLeftBecomesMember() {
        let r = JunosConfig.InterfaceRange(name: "R", memberRanges: [.init(start: "ge-0/0/46", end: "ge-0/0/47")])
        #expect(ChangePlanner.removeFromRange(port: "ge-0/0/46", range: r) == [
            "delete interfaces interface-range R member-range ge-0/0/46",
            "set interfaces interface-range R member ge-0/0/47",
        ])
    }

    @Test func openPortIntoVLAN() {
        let plan = ChangePlanner.plan(
            ports: [PortEdit(port: "ge-0/0/3", description: "SW01-MGMT", enabled: true, vlans: ["cust-01"])],
            vlans: [], config: cfg)
        #expect(plan.commands.contains("set interfaces ge-0/0/3 description SW01-MGMT"))
        #expect(plan.commands.contains("set interfaces ge-0/0/3 unit 0 family ethernet-switching interface-mode access"))
        #expect(plan.commands.contains("set interfaces ge-0/0/3 unit 0 family ethernet-switching vlan members cust-01"))
        #expect(plan.warnings.isEmpty)
    }

    @Test func disablePort() {
        let plan = ChangePlanner.plan(ports: [PortEdit(port: "ge-0/0/24", enabled: false)], vlans: [], config: cfg)
        #expect(plan.commands == ["set interfaces ge-0/0/24 disable"])
        #expect(plan.changes.first?.summary == "will be disabled")
    }

    @Test func trunkWithNativeVLAN() {
        let plan = ChangePlanner.plan(
            ports: [PortEdit(port: "ge-0/0/2", mode: .trunk, vlans: ["cust-01", "infra"], nativeVlanID: .some(100))],
            vlans: [], config: cfg)
        #expect(plan.commands == [
            "set interfaces ge-0/0/2 unit 0 family ethernet-switching interface-mode trunk",
            "delete interfaces ge-0/0/2 unit 0 family ethernet-switching vlan members",
            "set interfaces ge-0/0/2 unit 0 family ethernet-switching vlan members cust-01",
            "set interfaces ge-0/0/2 unit 0 family ethernet-switching vlan members infra",
            "set interfaces ge-0/0/2 native-vlan-id 100",
        ])
        #expect(plan.warnings.isEmpty)
    }

    @Test func noOpEditProducesNothing() {
        let plan = ChangePlanner.plan(ports: [PortEdit(port: "ge-0/0/2", description: "R640-PVE-01", enabled: true)], vlans: [], config: cfg)
        #expect(plan.isEmpty)
    }

    @Test func unknownVLANWarns() {
        let plan = ChangePlanner.plan(ports: [PortEdit(port: "ge-0/0/2", vlans: ["nope"])], vlans: [], config: cfg)
        #expect(plan.warnings.contains { $0.contains("nope") })
    }

    @Test func vlanAddRenameDelete() {
        let plan = ChangePlanner.plan(ports: [], vlans: [
            .add(name: "lab", vlanID: 200, description: "Home lab"),
            .rename(from: "cust-01", to: "internet"),
            .delete(name: "mgmt"),
        ], config: cfg)
        #expect(plan.commands.contains("set vlans lab vlan-id 200"))
        #expect(plan.commands.contains(#"set vlans lab description "Home lab""#))
        #expect(plan.commands.contains("rename vlans cust-01 to internet"))
        #expect(plan.commands.contains("delete interfaces ge-0/0/0 unit 0 family ethernet-switching vlan members cust-01"))
        #expect(plan.commands.contains("set interfaces ge-0/0/0 unit 0 family ethernet-switching vlan members internet"))
        #expect(plan.commands.contains("delete vlans mgmt"))
        #expect(plan.warnings.contains { $0.contains("ge-0/0/44") })
    }

    @Test func duplicateVLANIDWarns() {
        let plan = ChangePlanner.plan(ports: [], vlans: [.add(name: "x", vlanID: 100, description: nil)], config: cfg)
        #expect(plan.warnings.contains { $0.contains("cust-01") })
    }
}

@Suite(.serialized) struct BackupTests {
    @Test func dedupesIdenticalConfigs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("netdeck-test-\(UUID().uuidString)")
        setenv("NETDECK_HOME", dir.path, 1)
        defer { unsetenv("NETDECK_HOME"); try? FileManager.default.removeItem(at: dir) }

        let store = BackupStore(deviceID: "sw-01")
        let a = try store.save(configText: "set system host-name sw-01\n", reason: "on connect", date: Date(timeIntervalSince1970: 1_000))
        let b = try store.save(configText: "set system host-name sw-01\n", reason: "on connect", date: Date(timeIntervalSince1970: 2_000))
        #expect(a.url == b.url)
        _ = try store.save(configText: "set system host-name sw-02\n", reason: "before change", date: Date(timeIntervalSince1970: 3_000))
        let list = try store.list()
        #expect(list.count == 2)
        #expect(list.first?.reason == "before change")
        #expect(try store.read(try #require(list.first)) == "set system host-name sw-02\n")

        let d = SetDiff.diff(old: "set a\nset b\n", new: "set b\nset c\n")
        #expect(d.removed == ["set a"] && d.added == ["set c"])
    }
}
