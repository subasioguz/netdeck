import Foundation
import Testing
@testable import NetdeckCore

/// Rear QSFP+ roles (EX4300) and how other Juniper models are read.
@Suite struct RearPortRoleTests {
    @Test func roleChangeIsAnUntimedOperationalCommand() throws {
        L10n.language = .en
        let snap = DemoData.snapshot()
        let port = try #require(snap.rearPorts.first)
        #expect(port.role == .virtualChassis)
        #expect(port.networkName == "et-0/1/0")

        let plan = Planner.plan(snapshot: snap, ports: [PortEdit(port: "ge-0/0/2", description: "SRV02")], vlans: [],
                                rear: [RearPortEdit(pic: 1, port: 0, role: .network)])
        #expect(plan.commands == ["set interfaces ge-0/0/2 description SRV02"])
        #expect(plan.operationalCommands == ["request virtual-chassis vc-port delete pic-slot 1 port 0"])
        #expect(plan.hasUntimedPart)
        let row = try #require(plan.changes.first { $0.kind == .rearPort })
        #expect(row.subject == "QSFP+ 1/0")
        #expect(row.outsideTimer)
        #expect(row.summary == "role: Virtual Chassis port → network port (et-0/1/0)")
    }

    @MainActor @Test func stagingTheCurrentRoleStagesNothing() {
        let s = DeviceSession(profile: DemoData.profile(), snapshot: DemoData.snapshot())
        s.stage(RearPortEdit(pic: 1, port: 2, role: .network))
        #expect(s.rearEdits.count == 1)
        #expect(s.plan.operationalCommands == ["request virtual-chassis vc-port delete pic-slot 1 port 2"])
        s.stage(RearPortEdit(pic: 1, port: 2, role: .virtualChassis))
        #expect(s.rearEdits.isEmpty)
        #expect(s.plan.isEmpty)
    }

    @Test func rearEditsSurviveARestart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StagedEditsStore(directory: dir)
        try store.save(StagedEdits(rear: [RearPortEdit(pic: 1, port: 3, role: .network)]), deviceID: "sw")
        #expect(store.load(deviceID: "sw").rear == [RearPortEdit(pic: 1, port: 3, role: .network)])
    }

    @Test func modelsWithoutARearPanelHaveNoRearPorts() throws {
        let samples = DemoData.layoutSamples()
        let ex2300 = try #require(samples.first { $0.model == "EX2300-24T" })
        #expect(ex2300.rearPorts.isEmpty)
        // EX2300 uplinks on PIC 1 are front-panel cages there.
        #expect(ex2300.ports.filter { $0.kind == .sfp }.map(\.name) == ["xe-0/1/0", "xe-0/1/1", "xe-0/1/2", "xe-0/1/3"])
        #expect(ex2300.ports.filter { $0.kind == .copper }.count == 24)
    }
}

@Suite struct JuniperFamilyTests {
    @Test func qfxPortsAreCages() throws {
        let qfx = try #require(DemoData.layoutSamples().first { $0.model == "QFX5100-48S-6Q" })
        #expect(qfx.ports.count == 54)
        #expect(qfx.ports.allSatisfy { $0.kind == .sfp })
        #expect(qfx.kind == .switchDevice)
    }

    @Test func srxBranchHasCopperThenSFP() throws {
        let srx = try #require(DemoData.layoutSamples().first { $0.model == "SRX345" })
        #expect(srx.ports.filter { $0.kind == .copper }.map(\.number) == Array(0...7))
        #expect(srx.ports.filter { $0.kind == .sfp }.map(\.number) == Array(8...15))
        #expect(srx.kind == .firewall)
    }

    @Test func mxIsARouterWithoutSwitching() throws {
        let mx = try #require(DemoData.layoutSamples().first { $0.model == "MX204" })
        #expect(mx.kind == .router)
        #expect(!mx.hasSwitching)
        #expect(mx.ports.count == 12)
    }

    @Test func srxZonesAndRoutedPorts() {
        let cfg = SetConfigParser.parse("""
        set interfaces ge-0/0/0 unit 0 family inet address 203.0.113.2/30
        set interfaces ge-0/0/1 unit 0 family ethernet-switching interface-mode access
        set interfaces ge-0/0/1 unit 0 family ethernet-switching vlan members trust
        set security zones security-zone untrust interfaces ge-0/0/0.0 host-inbound-traffic system-services ping
        set security zones security-zone trust interfaces irb.0
        set vlans trust vlan-id 10
        """)
        #expect(cfg.zones["ge-0/0/0"] == "untrust")
        #expect(cfg.zones["irb"] == "trust")
        var hw = HardwareInfo()
        hw.model = "SRX300"
        let snap = SwitchSnapshot(version: VersionInfo(hostname: "fw", model: "srx300", junos: "23.4R2"), hardware: hw, config: cfg,
                                  configText: "", statuses: [InterfaceStatus(name: "ge-0/0/0", adminUp: true, linkUp: true),
                                                             InterfaceStatus(name: "ge-0/0/1", adminUp: true, linkUp: false)],
                                  macTable: [], lldp: [], commits: [])
        let wan = snap.ports.first { $0.name == "ge-0/0/0" }
        #expect(wan?.isRouted == true)
        #expect(wan?.zone == "untrust")
        #expect(wan?.addresses == ["203.0.113.2/30"])
        #expect(snap.ports.first { $0.name == "ge-0/0/1" }?.isRouted == false)
        #expect(snap.hasSwitching)
    }

    @Test func otherPlatformsKeepTheirOwnPorts() throws {
        let crs = try #require(DemoData.layoutSamples().first { $0.platform == .mikrotikRouterOS })
        #expect(crs.ports.count == 26)
        #expect(crs.ports.last?.name == "sfp-sfpplus2")
        #expect(crs.ports.last?.number == 2)
        #expect(crs.rearPorts.isEmpty)
        #expect(crs.junosModel == nil)
    }
}

@Suite struct FaceplateCatalogTests {
    @Test func namePatternsExpand() {
        #expect(FaceplateCatalog.expand("ge-0/0/0..3") == ["ge-0/0/0", "ge-0/0/1", "ge-0/0/2", "ge-0/0/3"])
        #expect(FaceplateCatalog.expand("ether1..3, sfp-sfpplus1") == ["ether1", "ether2", "ether3", "sfp-sfpplus1"])
        #expect(FaceplateCatalog.expand("GigabitEthernet1/0/47..48") == ["GigabitEthernet1/0/47", "GigabitEthernet1/0/48"])
        #expect(FaceplateCatalog.expand("eth0") == ["eth0"])
    }

    @Test func longestPrefixWins() {
        let a = FaceplateSpec(model: "EX4300-48T", match: ["EX4300-48"], groups: [])
        let b = FaceplateSpec(model: "EX4300-48MP", match: ["EX4300-48MP"], groups: [])
        #expect(FaceplateCatalog.spec(forModel: "ex4300-48mp", in: [a, b])?.model == "EX4300-48MP")
        #expect(FaceplateCatalog.spec(forModel: "EX4300-48P", in: [a, b])?.model == "EX4300-48T")
        #expect(FaceplateCatalog.spec(forModel: "EX2300-24T", in: [a, b]) == nil)
    }

    @Test func bundledSpecsAreComplete() {
        #expect(FaceplateCatalog.all.count > 60)
        #expect(FaceplateCatalog.all.allSatisfy { !$0.match.isEmpty && !$0.groups.isEmpty })
    }

    @Test func knownModelsResolve() {
        // EX4300-24T/48T keep the reference drawing of DESIGN.md §5 (no spec on purpose).
        #expect(FaceplateCatalog.spec(forModel: "EX4300-48T") == nil)
        #expect(FaceplateCatalog.spec(forModel: "EX2300-24P")?.model == "EX2300-24T")
        #expect(FaceplateCatalog.spec(forModel: "SRX345")?.model == "SRX340")
        #expect(FaceplateCatalog.spec(forModel: "CRS326-24G-2S+")?.groups.contains { $0.order == .bottomFirst } == true)
        #expect(FaceplateCatalog.spec(forModel: "C9300-48P")?.groups.contains { $0.isModuleSlot } == true)
        #expect(FaceplateCatalog.spec(forModel: "EdgeRouter X SFP 6-Port")?.model == "EdgeRouter X SFP 6-Port")
    }
}

@Suite struct CLISessionFramingTests {
    @Test func logMessagesAfterThePromptDontHideIt() {
        let d = CiscoDialect()
        #expect(d.isAsyncMessage("*Nov 17 10:01:02.123: %LINK-3-UPDOWN: Interface GigabitEthernet1/0/3, changed state to up"))
        #expect(d.isAsyncMessage("%LINEPROTO-5-UPDOWN: Line protocol on Interface GigabitEthernet1/0/3, changed state to up"))
        #expect(d.isAsyncMessage("000123: *Nov 17 10:01:02: %SYS-5-CONFIG_I: Configured from console by admin on vty0"))
        #expect(!d.isAsyncMessage("% Invalid input detected at '^' marker."))
        #expect(!d.isAsyncMessage(" description %LINK-3-UPDOWN: looks like a log"))
        let text = "no shutdown\nsw1(config-if)#\n*Nov 17 10:01:02.123: %LINK-3-UPDOWN: Interface Gi1/0/3, changed state to up\n"
        #expect(CLISession.lastPromptCandidate(of: text, dialect: d) == "sw1(config-if)#")
        #expect(CLISession.strip("show clock\n10:01:02.123 UTC Mon Nov 17 2026\n%SYS-5-CONFIG_I: Configured\nsw1#", dialect: d)
                == "10:01:02.123 UTC Mon Nov 17 2026")
    }
}
