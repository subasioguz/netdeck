import Foundation
import Testing
@testable import NetdeckCore

/// Synthetic Cisco captures (see Fixtures/synthetic/cisco/README.md), with the echoed command and the
/// trailing prompt, stripped the way `CLISession` strips live output.
func ciscoFixture(_ name: String) throws -> String {
    L10n.language = .en
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/synthetic/cisco"))
    return CLISession.strip(try String(contentsOf: url, encoding: .utf8), dialect: CiscoDialect())
}

func ciscoC9300Snapshot() throws -> SwitchSnapshot {
    var o = CiscoSnapshotBuilder.Outputs()
    o.version = try ciscoFixture("c9300-show-version")
    o.inventory = try ciscoFixture("c9300-show-inventory")
    o.runningConfig = try ciscoFixture("c9300-running-config")
    o.interfacesStatus = try ciscoFixture("c9300-interfaces-status")
    o.vlanBrief = try ciscoFixture("c9300-vlan-brief")
    o.macTable = try ciscoFixture("c9300-mac-address-table")
    o.lldp = try ciscoFixture("c9300-lldp-neighbors")
    o.archive = try ciscoFixture("archive-configured")
    return CiscoSnapshotBuilder.build(o)
}

func ciscoC2960XSnapshot() throws -> SwitchSnapshot {
    var o = CiscoSnapshotBuilder.Outputs()
    o.version = try ciscoFixture("2960x-show-version")
    o.inventory = try ciscoFixture("2960x-show-inventory")
    o.runningConfig = try ciscoFixture("2960x-running-config")
    o.interfacesStatus = try ciscoFixture("2960x-interfaces-status")
    o.vlanBrief = try ciscoFixture("2960x-vlan-brief")
    o.lldp = try ciscoFixture("lldp-disabled")
    o.archive = try ciscoFixture("archive-not-configured")
    return CiscoSnapshotBuilder.build(o)
}

// MARK: - Dialect

@Suite struct CiscoDialectTests {
    let d = CiscoDialect()

    @Test func promptKinds() {
        #expect(d.prompt("SW-ACCESS-01>") == .user)
        #expect(d.prompt("SW-ACCESS-01#") == .operational)
        #expect(d.prompt("sw.lab_01#") == .operational)
        #expect(d.prompt("SW-ACCESS-01(config)#") == .configuration)
        #expect(d.prompt("SW-ACCESS-01(config-if)#") == .configuration)
        #expect(d.prompt("SW-ACCESS-01(config-if-range)#") == .configuration)
        #expect(d.prompt("SW-ACCESS-01(config-vlan)#") == .configuration)
        #expect(d.prompt("SW-ACCESS-01(config-archive)#") == .configuration)
        #expect(d.prompt("Username: ") == .login)
        #expect(d.prompt("Password: ") == .password)
        #expect(d.prompt(" --More-- ") == .pager)
        #expect(d.prompt("Proceed with reload? [confirm]") == .question)
        #expect(d.prompt("Would you like to enter the initial configuration dialog? [yes/no]: ") == .question)
        #expect(d.prompt("Destination filename [startup-config]?") == .question)
    }

    @Test func outputLinesAreNotPrompts() {
        #expect(d.prompt(" description Switch#1") == nil)
        #expect(d.prompt("Switch#1") == nil)
        #expect(d.prompt("core sw#") == nil)
        #expect(d.prompt("admin@host>") == nil)
        #expect(d.prompt("show running-config") == nil)
        #expect(d.prompt("Building configuration...") == nil)
        #expect(d.prompt("") == nil)
        #expect(d.prompt(" description [uplink]") == nil)
    }

    @Test func leavingAndAdvancing() {
        #expect(d.advance(from: .configuration) == "end\r")
        #expect(d.logout(from: .configuration) == "end\r")
        #expect(d.logout(from: .operational) == "exit\r")
        #expect(d.logout(from: .user) == "exit\r")
        #expect(d.logout(from: .login) == nil)
        #expect(d.setupCommands == ["terminal length 0", "terminal width 511"])
        #expect(d.pagerKey == " ")
    }

    @Test func errors() {
        let out = """
                                ^
        % Invalid input detected at '^' marker.
        % Incomplete command.
        % Ambiguous command:  "sh"
        % Bad mask /33 for address 192.0.2.1
        %Command rejected: Gi1/0/6 is not a switching port.
        Command rejected: An interface whose trunk encapsulation is "Auto" can not be configured to "trunk" mode.
        *Nov 17 10:00:02.123: %LINK-3-UPDOWN: Interface GigabitEthernet1/0/3, changed state to up
        %LINEPROTO-5-UPDOWN: Line protocol on Interface GigabitEthernet1/0/3, changed state to up
        % Warning: this is only a warning
        Enter configuration commands, one per line.  End with CNTL/Z.
        """
        #expect(d.errors(in: out).count == 6)
        #expect(d.errors(in: "Rollback Confirmed Change: Backing up current running config to flash:netdeck-1").isEmpty)
    }

    @Test func stripsEchoAndConfigPrompt() {
        let raw = " description UPLINK\r\nSW-ACCESS-01(config-if)#"
        #expect(CLISession.strip(raw, dialect: d) == "")
        let paged = "show inventory\r\nNAME: \"1\", DESCR: \"x\"\r\n --More-- \u{8}\u{8}\u{8}\u{8}\u{8}\u{8}\u{8}\u{8}\u{8}\u{8}          \u{8}\u{8}\u{8}\u{8}\u{8}\u{8}\u{8}\u{8}\u{8}\u{8}PID: X\r\nSW1#"
        #expect(CLISession.strip(paged, dialect: d) == "NAME: \"1\", DESCR: \"x\"\nPID: X")
    }
}

// MARK: - Names

@Suite struct CiscoNamesTests {
    @Test func shortToFull() {
        #expect(CiscoNames.full("Gi1/0/3") == "GigabitEthernet1/0/3")
        #expect(CiscoNames.full("Te1/1/1") == "TenGigabitEthernet1/1/1")
        #expect(CiscoNames.full("Twe1/1/1") == "TwentyFiveGigE1/1/1")
        #expect(CiscoNames.full("Tw1/0/1") == "TwoGigabitEthernet1/0/1")
        #expect(CiscoNames.full("Fo1/1/2") == "FortyGigabitEthernet1/1/2")
        #expect(CiscoNames.full("Hu1/0/49") == "HundredGigE1/0/49")
        #expect(CiscoNames.full("Fi1/0/1") == "FiveGigabitEthernet1/0/1")
        #expect(CiscoNames.full("Fa0/1") == "FastEthernet0/1")
        #expect(CiscoNames.full("Po1") == "Port-channel1")
        #expect(CiscoNames.full("GigabitEthernet1/0/3") == "GigabitEthernet1/0/3")
    }

    @Test func fullToShort() {
        #expect(CiscoNames.short("TenGigabitEthernet1/1/1") == "Te1/1/1")
        #expect(CiscoNames.short("TwentyFiveGigE1/1/1") == "Twe1/1/1")
        #expect(CiscoNames.short("Port-channel1") == "Po1")
        #expect(CiscoNames.short("Gi1/0/1") == "Gi1/0/1")
    }

    @Test func resolvesAgainstKnownNames() {
        let known: Set<String> = ["GigabitEthernet1/0/1", "FortyGigabitEthernet1/1/1"]
        #expect(CiscoNames.resolve("Gi1/0/1", known: known) == "GigabitEthernet1/0/1")
        #expect(CiscoNames.resolve("Fort1/1/1", known: known) == "FortyGigabitEthernet1/1/1")
        #expect(CiscoNames.resolve("Te1/1/9", known: known) == "TenGigabitEthernet1/1/9")
        #expect(CiscoNames.resolve("1", known: ["Vlan1"]) == "1")
    }

    @Test func physicalPorts() {
        #expect(CiscoNames.isPhysical("GigabitEthernet1/0/1"))
        #expect(CiscoNames.isPhysical("TwentyFiveGigE1/1/1"))
        #expect(!CiscoNames.isPhysical("FastEthernet0"))
        #expect(!CiscoNames.isPhysical("AppGigabitEthernet1/0/1"))
        #expect(!CiscoNames.isPhysical("Port-channel1"))
        #expect(!CiscoNames.isPhysical("Vlan10"))
        #expect(!CiscoNames.isPhysical("GigabitEthernet0/0/0.100"))
        #expect(CiscoNames.path("GigabitEthernet1/0/25") == [1, 0, 25])
        #expect(CiscoNames.isModulePort("TenGigabitEthernet1/1/1"))
        #expect(!CiscoNames.isModulePort("GigabitEthernet1/0/1"))
    }
}

// MARK: - Parsers

@Suite struct CiscoParserTests {
    @Test func versionIOSXE() throws {
        let v = CiscoParsers.version(try ciscoFixture("c9300-show-version"))
        #expect(v.isIOS)
        #expect(v.isXE)
        #expect(v.osVersion == "17.09.04a")
        #expect(v.hostname == "SW-ACCESS-01")
        #expect(v.model == "C9300-48P")
        #expect(v.serial == "TEST0000101")
    }

    @Test func versionClassicIOS() throws {
        let v = CiscoParsers.version(try ciscoFixture("2960x-show-version"))
        #expect(v.isIOS)
        #expect(!v.isXE)
        #expect(v.osVersion == "15.2(7)E8")
        #expect(v.hostname == "SW-FLOOR-02")
        #expect(v.model == "WS-C2960X-24TS-L")
        #expect(v.serial == "TEST0000201")
    }

    @Test func versionOfOtherPlatforms() {
        #expect(!CiscoParsers.version("Cisco Nexus Operating System (NX-OS) Software").isIOS)
        #expect(!CiscoParsers.version("Cisco IOS XR Software, Version 7.5.2").isIOS)
        #expect(!CiscoParsers.version("Hostname: sw-01\nJunos: 21.2R3.8").isIOS)
        let router = CiscoParsers.version("Cisco IOS Software, C2900 Software (C2900-UNIVERSALK9-M), Version 15.7(3)M8, RELEASE SOFTWARE (fc1)\nrtr uptime is 2 weeks\ncisco CISCO2911/K9 (revision 1.0) with 491520K/32768K bytes of memory.\nProcessor board ID TEST0000401")
        #expect(router.model == "CISCO2911/K9")
        #expect(router.serial == "TEST0000401")
        #expect(router.osVersion == "15.7(3)M8")
    }

    @Test func inventory() throws {
        let items = CiscoParsers.inventory(try ciscoFixture("c9300-show-inventory"))
        #expect(items.count == 5)
        #expect(items[1] == CiscoInventoryItem(name: "Switch 1", descr: "C9300-48P", pid: "C9300-48P", vid: "V02", serial: "TEST0000101"))
        #expect(items[3].descr == "8x10G Uplink Module")
        #expect(items[4].name == "Te1/1/1")
        #expect(items[4].pid == "SFP-10G-SR")
        #expect(items[4].serial == "TEST0000104")
    }

    @Test func runningConfig() throws {
        let rc = CiscoParsers.runningConfig(try ciscoFixture("c9300-running-config"))
        #expect(rc.hostname == "SW-ACCESS-01")
        #expect(rc.archivePath == "flash:netdeck")
        #expect(!rc.usesTrunkEncapsulation)
        #expect(rc.vlans == [10: "USERS", 20: "VOICE", 30: "PRINTERS", 31: "", 32: "CAMERAS", 40: "GUEST-WIFI", 99: "NATIVE-UNUSED"])

        let trunk = try #require(rc.interface("GigabitEthernet1/0/1"))
        #expect(trunk.mode == .trunk)
        #expect(trunk.allowedVLANs == [10, 20, 30, 31, 32, 40])   // "10,20,30-32" then "add 40"
        #expect(trunk.nativeVLAN == 99)
        #expect(trunk.description == "UPLINK-CORE")

        let access = try #require(rc.interface("GigabitEthernet1/0/2"))
        #expect(access.mode == .access)
        #expect(access.accessVLAN == 10)
        #expect(access.allowedVLANs == nil)

        let shut = try #require(rc.interface("GigabitEthernet1/0/5"))
        #expect(shut.shutdown)

        let routed = try #require(rc.interface("GigabitEthernet1/0/6"))
        #expect(routed.noSwitchport)
        #expect(routed.addresses == ["192.0.2.1/30"])

        #expect(rc.interface("GigabitEthernet1/0/7")?.allowedVLANs == nil)   // trunk carrying all VLANs
        #expect(rc.interface("GigabitEthernet1/0/9")?.description == "A very long description that the switch truncates")
        #expect(rc.interface("GigabitEthernet1/0/10")?.channelGroup == 1)
        #expect(rc.interface("GigabitEthernet0/0")?.vrf == "Mgmt-vrf")
        #expect(rc.interface("GigabitEthernet1/0/11")?.mode == nil)
        #expect(rc.interface("Vlan10")?.addresses == ["192.0.2.129/25"])
    }

    @Test func trunkAllowedListForms() {
        #expect(CiscoParsers.applyAllowed("10,20,30-32", to: nil) == [10, 20, 30, 31, 32])
        #expect(CiscoParsers.applyAllowed("add 40-41", to: [10]) == [10, 40, 41])
        #expect(CiscoParsers.applyAllowed("add 40", to: nil) == nil)
        #expect(CiscoParsers.applyAllowed("remove 20", to: [10, 20]) == [10])
        #expect(CiscoParsers.applyAllowed("none", to: [10]) == [])
        #expect(CiscoParsers.applyAllowed("all", to: [10]) == nil)
        #expect(CiscoParsers.applyAllowed("1-4094", to: nil) == nil)
        #expect(CiscoParsers.applyAllowed("except 2-4094", to: nil) == [1])
        #expect(CiscoParsers.vlanList("internal allocation policy ascending") == nil)
        #expect(CiscoParsers.compressVLANList([32, 10, 20, 30, 31]) == "10,20,30-32")
        #expect(CiscoParsers.compressVLANList([5]) == "5")
    }

    @Test func configTextDropsVolatileLines() throws {
        let text = CiscoParsers.configText(try ciscoFixture("c9300-running-config"))
        #expect(!text.contains("Current configuration"))
        #expect(!text.contains("Last configuration change"))
        #expect(!text.contains("ntp clock-period"))
        #expect(text.hasPrefix("!"))
        #expect(text.contains("hostname SW-ACCESS-01"))
        #expect(text.hasSuffix("end"))
    }

    @Test func interfacesStatus() throws {
        let rows = CiscoParsers.interfacesStatus(try ciscoFixture("c9300-interfaces-status"))
        #expect(rows.count == 48 + 4 + 8 + 2 + 2 + 3)
        #expect(rows[0] == CiscoPortStatus(port: "Gi1/0/1", name: "UPLINK-CORE", status: "connected", vlan: "trunk",
                                           duplex: "a-full", speed: "a-1000", type: "10/100/1000BaseTX"))
        let empty = try #require(rows.first { $0.port == "Gi1/0/3" })
        #expect(empty.name == "")
        #expect(empty.status == "notconnect")
        #expect(empty.vlan == "20")
        #expect(rows.first { $0.port == "Gi1/0/4" }?.name == "PRINTER 2ND FLOOR")
        #expect(rows.first { $0.port == "Gi1/0/9" }?.name == "A very long descri")
        #expect(rows.first { $0.port == "Gi1/0/8" }?.status == "err-disabled")
        #expect(rows.first { $0.port == "Gi1/0/5" }?.adminUp == false)
        #expect(rows.first { $0.port == "Gi1/0/6" }?.vlan == "routed")
        #expect(rows.first { $0.port == "Te1/1/2" }?.type == "Not Present")
        #expect(rows.first { $0.port == "Te1/1/1" }?.speed == "10G")
        #expect(rows.first { $0.port == "Twe1/1/1" }?.type == "unknown")
        #expect(rows.first { $0.port == "Po1" }?.type == "")
        #expect(CiscoParsers.interfacesStatus("          ^\n% Invalid input detected at '^' marker.").isEmpty)
    }

    @Test func vlanBriefWithWrappedPorts() throws {
        let rows = CiscoParsers.vlanBrief(try ciscoFixture("c9300-vlan-brief"))
        #expect(rows.map(\.id) == [1, 10, 20, 30, 31, 32, 40, 99])
        #expect(rows[0].name == "default")
        #expect(rows[0].status == "active")
        #expect(rows[0].ports.count == 54)
        #expect(rows[0].ports.first == "Gi1/0/11")
        #expect(rows[0].ports.last == "Ap1/0/1")
        #expect(rows[1].ports == ["Gi1/0/2", "Gi1/0/8", "Gi1/0/9"])
        #expect(rows[4].name == "VLAN0031")
        #expect(rows[4].ports.isEmpty)
    }

    @Test func macTableCatalyst() throws {
        let rows = CiscoParsers.macTable(try ciscoFixture("c9300-mac-address-table"))
        #expect(rows.count == 7)   // CPU, "All" and the SVI's own static entry are skipped
        #expect(rows[0] == CiscoMACRow(vlan: "10", mac: "48:a9:8a:00:00:01", type: "dynamic", port: "Gi1/0/2"))
        #expect(rows.contains { $0.port == "Gi1/0/9" && $0.type == "static" })   // port-security address on a front port
        #expect(rows.contains { $0.port == "Po1" })
        #expect(!rows.contains { $0.port == "CPU" || $0.port == "Vl10" })
    }

    @Test func macTableCatalyst6500() throws {
        let rows = CiscoParsers.macTable(try ciscoFixture("cat6500-mac-address-table"))
        #expect(rows == [
            CiscoMACRow(vlan: "10", mac: "48:a9:8a:00:00:11", type: "dynamic", port: "Gi1/1"),
            CiscoMACRow(vlan: "20", mac: "48:a9:8a:00:00:12", type: "dynamic", port: "Gi2/3"),
        ])
    }

    @Test func macTableOldLayout() {
        let text = "Destination Address  Address Type  VLAN  Destination Port\n-------------------  ------------  ----  --------------------\n48a9.8a00.0021       Dynamic          1  FastEthernet0/1"
        #expect(CiscoParsers.macTable(text) == [CiscoMACRow(vlan: "1", mac: "48:a9:8a:00:00:21", type: "dynamic", port: "FastEthernet0/1")])
    }

    @Test func lldpNeighbors() throws {
        let rows = CiscoParsers.lldpNeighbors(try ciscoFixture("c9300-lldp-neighbors"))
        #expect(rows.count == 4)
        #expect(rows[0].systemName == "core-sw-01.example.c")   // cut at 20 characters by the switch
        #expect(rows[0].localInterface == "Gi1/0/1")
        #expect(rows[0].portInfo == "Gi1/0/48")
        #expect(rows[2].systemName == "esxi-01")
        #expect(rows[2].portInfo == "48a9.8a00.0021")
        #expect(CiscoParsers.lldpNeighbors(try ciscoFixture("lldp-disabled")).isEmpty)
    }

    @Test func archive() throws {
        #expect(CiscoParsers.archiveConfigured(try ciscoFixture("archive-configured")))
        #expect(!CiscoParsers.archiveConfigured(try ciscoFixture("archive-not-configured")))
        #expect(!CiscoParsers.archiveConfigured("% Invalid input detected at '^' marker."))
    }
}

// MARK: - Snapshot

@Suite struct CiscoSnapshotTests {
    @Test func catalyst9300() throws {
        let s = try ciscoC9300Snapshot()
        #expect(s.platform == .ciscoIOS)
        #expect(s.readKind == .switchDevice)
        #expect(s.hostname == "SW-ACCESS-01")
        #expect(s.model == "C9300-48P")
        #expect(s.hardware.serial == "TEST0000101")
        #expect(s.osVersion == "17.09.04a")
        #expect(s.commits.isEmpty)
        #expect(s.hasSwitching)
        #expect(s.config.vlans.map(\.name) == ["default", "USERS", "VOICE", "PRINTERS", "VLAN0031", "CAMERAS", "GUEST-WIFI", "NATIVE-UNUSED"])
        #expect(s.config.vlan(named: "CAMERAS")?.vlanID == 32)

        // 48 copper ports, then the 8 cages of the installed 8x10G module. The management port,
        // the app-hosting port and the module variants that aren't installed are not shown.
        let ports = s.ports
        #expect(ports.count == 56)
        #expect(ports.prefix(48).allSatisfy { $0.kind == .copper && $0.name.hasPrefix("GigabitEthernet1/0/") })
        #expect(ports.suffix(8).allSatisfy { $0.kind == .sfp && $0.name.hasPrefix("TenGigabitEthernet1/1/") })
        #expect(!ports.contains { $0.name == "GigabitEthernet0/0" || $0.name.hasPrefix("AppGigabitEthernet") })
        #expect(!ports.contains { $0.name.hasPrefix("GigabitEthernet1/1/") || $0.name.hasPrefix("FortyGigabitEthernet") || $0.name.hasPrefix("TwentyFiveGigE") })

        let p1 = try #require(s.port(named: "GigabitEthernet1/0/1"))
        #expect(p1.slotKey == "GigabitEthernet1/0/1")
        #expect(p1.number == 1)
        #expect(p1.label == "1")
        #expect(p1.mode == .trunk)
        #expect(p1.vlans == ["USERS", "VOICE", "PRINTERS", "VLAN0031", "CAMERAS", "GUEST-WIFI"])
        #expect(p1.nativeVlanID == 99)
        #expect(p1.linkUp)
        #expect(p1.speed == "1000Mbps")
        #expect(p1.macs.count == 2)
        #expect(p1.lldp.first?.systemName == "core-sw-01.example.c")

        let p2 = try #require(s.port(named: "GigabitEthernet1/0/2"))
        #expect(p2.mode == .access)
        #expect(p2.vlans == ["USERS"])
        #expect(p2.description == "AP-FLOOR1")
        #expect(p2.macs.map(\.mac) == ["48:a9:8a:00:00:01"])
        #expect(p2.macs.first?.vlan == "USERS")

        let p3 = try #require(s.port(named: "GigabitEthernet1/0/3"))
        #expect(p3.description == nil)
        #expect(p3.vlans == ["VOICE"])
        #expect(p3.state == .down)

        let p5 = try #require(s.port(named: "GigabitEthernet1/0/5"))
        #expect(p5.configDisabled)
        #expect(!p5.adminUp)
        #expect(p5.state == .disabled)

        let p6 = try #require(s.port(named: "GigabitEthernet1/0/6"))
        #expect(p6.isRouted)
        #expect(p6.mode == nil)
        #expect(p6.vlans.isEmpty)
        #expect(p6.addresses == ["192.0.2.1/30"])

        #expect(s.port(named: "GigabitEthernet1/0/7")?.vlans.count == 8)   // trunk with every VLAN
        #expect(s.port(named: "GigabitEthernet1/0/8")?.state == .warning)   // err-disabled
        #expect(s.port(named: "GigabitEthernet1/0/9")?.description == "A very long description that the switch truncates")
        #expect(s.port(named: "GigabitEthernet1/0/11")?.mode == .access)
        #expect(s.port(named: "GigabitEthernet1/0/11")?.vlans == ["default"])

        let te1 = try #require(s.port(named: "TenGigabitEthernet1/1/1"))
        #expect(te1.number == 1)
        #expect(te1.present)
        #expect(te1.transceiver?.partNumber == "SFP-10G-SR")
        #expect(te1.transceiver?.description == "SFP-10GBase-SR")
        #expect(te1.vlans == ["USERS", "VOICE"])
        #expect(te1.lldp.first?.systemName == "dist-sw-01")
        #expect(te1.speed == "10G")
        #expect(s.port(named: "TenGigabitEthernet1/1/2")?.present == false)
        #expect(s.port(named: "TenGigabitEthernet1/1/2")?.state == .empty)

        #expect(s.macTable.contains { $0.interface == "Port-channel1" })
        #expect(s.statuses.contains { $0.name == "AppGigabitEthernet1/0/1" })
        #expect(!s.configText.contains("Current configuration"))

        guard case let .cisco(state) = s.vendor else { Issue.record("no Cisco state"); return }
        #expect(state.archiveConfigured)
        #expect(state.ports["GigabitEthernet1/0/10"]?.channelGroup == 1)
        #expect(state.ports["GigabitEthernet1/0/6"]?.switchport == false)
        #expect(state.ports["GigabitEthernet1/0/1"]?.allowedVLANs == [10, 20, 30, 31, 32, 40])
    }

    @Test func catalyst2960X() throws {
        let s = try ciscoC2960XSnapshot()
        #expect(s.model == "WS-C2960X-24TS-L")
        #expect(s.osVersion == "15.2(7)E8")
        #expect(s.hostname == "SW-FLOOR-02")
        let ports = s.ports
        #expect(ports.count == 28)
        #expect(ports.prefix(24).allSatisfy { $0.kind == .copper })
        #expect(ports.suffix(4).allSatisfy { $0.kind == .sfp })
        #expect(ports.map(\.number) == Array(1...28))
        #expect(!ports.contains { $0.name == "FastEthernet0" })
        let p25 = try #require(s.port(named: "GigabitEthernet1/0/25"))
        #expect(p25.transceiver?.partNumber == "GLC-SX-MMD")
        #expect(p25.vlans == ["default", "SERVERS", "LAB"])
        #expect(p25.speed == "1000Mbps")
        #expect(s.port(named: "GigabitEthernet1/0/26")?.present == false)
        #expect(s.port(named: "GigabitEthernet1/0/24")?.vlans == ["SERVERS", "LAB"])
        #expect(s.port(named: "GigabitEthernet1/0/1")?.vlans == ["SERVERS"])
        #expect(s.lldp.isEmpty)
        guard case let .cisco(state) = s.vendor else { Issue.record("no Cisco state"); return }
        #expect(!state.archiveConfigured)
    }

    @Test func routerWithoutSwitchPorts() {
        var o = CiscoSnapshotBuilder.Outputs()
        o.version = """
        Cisco IOS XE Software, Version 17.06.05
        Cisco IOS Software [Bengaluru], ISR Software (X86_64_LINUX_IOSD-UNIVERSALK9-M), Version 17.6.5, RELEASE SOFTWARE (fc2)
        rtr-01 uptime is 3 weeks, 2 days, 1 hour, 4 minutes
        cisco ISR4331/K9 (1RU) processor with 1795999K/6147K bytes of memory.
        Processor board ID TEST0000301
        """
        o.runningConfig = """
        hostname rtr-01
        !
        interface GigabitEthernet0/0/0
         description WAN
         ip address 203.0.113.2 255.255.255.252
        !
        interface GigabitEthernet0/0/1
         ip address 192.0.2.1 255.255.255.0
        !
        interface GigabitEthernet0/0/2
         no ip address
         shutdown
        !
        interface GigabitEthernet0
         vrf forwarding Mgmt-intf
         no ip address
        !
        end
        """
        o.interfacesStatus = "                        ^\n% Invalid input detected at '^' marker."
        o.vlanBrief = o.interfacesStatus
        let s = CiscoSnapshotBuilder.build(o)
        #expect(s.readKind == .router)
        #expect(!s.hasSwitching)
        #expect(s.model == "ISR4331/K9")
        #expect(s.ports.map(\.name) == ["GigabitEthernet0/0/0", "GigabitEthernet0/0/1", "GigabitEthernet0/0/2"])
        #expect(s.ports.allSatisfy { $0.kind == .copper && !$0.switching })
        #expect(s.port(named: "GigabitEthernet0/0/0")?.isRouted == true)
        #expect(s.port(named: "GigabitEthernet0/0/2")?.configDisabled == true)
    }
}

// MARK: - Planner

@Suite struct CiscoPlannerTests {
    let s: SwitchSnapshot

    init() throws { s = try ciscoC9300Snapshot() }

    func plan(_ ports: [PortEdit] = [], _ vlans: [VLANEdit] = []) -> ChangePlan {
        Planner.plan(snapshot: s, ports: ports, vlans: vlans)
    }

    @Test func descriptionEdits() {
        let p = plan([PortEdit(port: "GigabitEthernet1/0/3", description: "CAMERA-01")])
        #expect(p.commands == ["interface GigabitEthernet1/0/3", " description CAMERA-01", "exit"])
        #expect(p.changes.first?.summary == "description: — → CAMERA-01")
        #expect(p.warnings.isEmpty)
        #expect(plan([PortEdit(port: "GigabitEthernet1/0/2", description: "")]).commands
                == ["interface GigabitEthernet1/0/2", " no description", "exit"])
        #expect(!plan([PortEdit(port: "GigabitEthernet1/0/2", description: "what?")]).warnings.isEmpty)
    }

    @Test func shutdownAndNoShutdown() {
        let on = plan([PortEdit(port: "GigabitEthernet1/0/5", enabled: true)])
        #expect(on.commands == ["interface GigabitEthernet1/0/5", " no shutdown", "exit"])
        #expect(on.changes.first?.summary == "will be enabled")
        let off = plan([PortEdit(port: "GigabitEthernet1/0/3", description: "X", enabled: false)])
        #expect(off.commands == ["interface GigabitEthernet1/0/3", " shutdown", " description X", "exit"])
        // Enabling comes after the VLAN, so the port comes up in the right network.
        let both = plan([PortEdit(port: "GigabitEthernet1/0/5", enabled: true, vlans: ["USERS"])])
        #expect(both.commands == ["interface GigabitEthernet1/0/5", " switchport mode access", " switchport access vlan 10", " no shutdown", "exit"])
    }

    @Test func accessVLAN() {
        let p = plan([PortEdit(port: "GigabitEthernet1/0/3", vlans: ["USERS"])])
        #expect(p.commands == ["interface GigabitEthernet1/0/3", " switchport access vlan 10", "exit"])
        #expect(p.changes.first?.summary == "VLAN: VOICE → USERS")
        // No mode configured (DTP): the mode is pinned along with the VLAN.
        let dynamic = plan([PortEdit(port: "GigabitEthernet1/0/11", vlans: ["USERS"])])
        #expect(dynamic.commands == ["interface GigabitEthernet1/0/11", " switchport mode access", " switchport access vlan 10", "exit"])
    }

    @Test func trunkAllowedList() {
        let p = plan([PortEdit(port: "GigabitEthernet1/0/1", vlans: ["USERS", "VOICE", "CAMERAS"])])
        #expect(p.commands == ["interface GigabitEthernet1/0/1", " switchport trunk allowed vlan 10,20,32", "exit"])
        let none = plan([PortEdit(port: "GigabitEthernet1/0/1", vlans: [])])
        #expect(none.commands == ["interface GigabitEthernet1/0/1", " switchport trunk allowed vlan none", "exit"])
    }

    @Test func accessToTrunk() {
        let p = plan([PortEdit(port: "GigabitEthernet1/0/3", mode: .trunk, vlans: ["USERS", "VOICE"])])
        #expect(p.commands == ["interface GigabitEthernet1/0/3", " switchport mode trunk", " switchport trunk allowed vlan 10,20", "exit"])
        #expect(p.changes.first?.summary == "mode: single network (access) → multiple networks (trunk) · VLAN: VOICE → USERS, VOICE")
        // Same VLAN list as shown, but a new trunk would carry every VLAN: the list is still sent.
        let same = plan([PortEdit(port: "GigabitEthernet1/0/3", mode: .trunk, vlans: ["VOICE"])])
        #expect(same.commands == ["interface GigabitEthernet1/0/3", " switchport mode trunk", " switchport trunk allowed vlan 20", "exit"])
        let back = plan([PortEdit(port: "GigabitEthernet1/0/1", mode: .access, vlans: ["USERS"])])
        #expect(back.commands == ["interface GigabitEthernet1/0/1", " switchport mode access", " switchport access vlan 10", "exit"])
    }

    @Test func trunkEncapsulationWhereNeeded() throws {
        var isl = s
        guard case let .cisco(state) = s.vendor else { Issue.record("no Cisco state"); return }
        isl.vendor = .cisco(CiscoState(ports: state.ports, archiveConfigured: true, needsTrunkEncapsulation: true))
        let p = Planner.plan(snapshot: isl, ports: [PortEdit(port: "GigabitEthernet1/0/3", mode: .trunk)], vlans: [])
        #expect(p.commands == ["interface GigabitEthernet1/0/3", " switchport trunk encapsulation dot1q", " switchport mode trunk", "exit"])
    }

    @Test func nativeVLAN() {
        let set = plan([PortEdit(port: "GigabitEthernet1/0/1", nativeVlanID: .some(10))])
        #expect(set.commands == ["interface GigabitEthernet1/0/1", " switchport trunk native vlan 10", "exit"])
        #expect(set.changes.first?.summary == "untagged VLAN: 99 → 10")
        #expect(set.warnings.isEmpty)
        let remove = plan([PortEdit(port: "GigabitEthernet1/0/1", nativeVlanID: .some(nil))])
        #expect(remove.commands == ["interface GigabitEthernet1/0/1", " no switchport trunk native vlan", "exit"])
        #expect(remove.changes.first?.summary == "untagged VLAN will be removed")
        let notMember = plan([PortEdit(port: "TenGigabitEthernet1/1/1", nativeVlanID: .some(30))])
        #expect(notMember.warnings == ["TenGigabitEthernet1/1/1: untagged VLAN 30 (PRINTERS) must also be a member."])
    }

    @Test func unchangedEditsPlanNothing() {
        let p = plan([
            PortEdit(port: "GigabitEthernet1/0/2", description: "AP-FLOOR1", enabled: true, mode: .access, vlans: ["USERS"]),
            PortEdit(port: "GigabitEthernet1/0/1", nativeVlanID: .some(99)),
            PortEdit(port: "GigabitEthernet1/0/7", vlans: ["default", "USERS", "VOICE", "PRINTERS", "VLAN0031", "CAMERAS", "GUEST-WIFI", "NATIVE-UNUSED"]),
        ])
        #expect(p.changes.isEmpty)
    }

    @Test func warnings() {
        let routed = plan([PortEdit(port: "GigabitEthernet1/0/6", vlans: ["USERS"])])
        #expect(routed.commands.isEmpty)
        #expect(routed.warnings == ["GigabitEthernet1/0/6 is a routed port (no switchport). Netdeck doesn't change VLANs on routed ports."])
        let unknown = plan([PortEdit(port: "GigabitEthernet1/0/3", vlans: ["NOPE"])])
        #expect(unknown.warnings == ["GigabitEthernet1/0/3: there is no VLAN named 'NOPE'."])
        let two = plan([PortEdit(port: "GigabitEthernet1/0/3", vlans: ["USERS", "VOICE"])])
        #expect(two.warnings == ["GigabitEthernet1/0/3: an access port can carry only one VLAN."])
        let member = plan([PortEdit(port: "GigabitEthernet1/0/10", vlans: ["USERS"])])
        #expect(member.warnings.count == 1)
        #expect(member.commands.isEmpty)
    }

    @Test func vlanAddedAndUsedInOnePlan() {
        let p = plan([PortEdit(port: "GigabitEthernet1/0/3", vlans: ["SERVERS"])],
                     [.add(name: "SERVERS", vlanID: 50, description: nil)])
        #expect(p.commands == ["vlan 50", " name SERVERS", "exit", "interface GigabitEthernet1/0/3", " switchport access vlan 50", "exit"])
        #expect(p.warnings.isEmpty)
        #expect(p.changes.first?.summary == "VLAN 50 'SERVERS' will be added")
    }

    @Test func vlanAddWarnings() {
        #expect(plan([], [.add(name: "USERS2", vlanID: 10, description: nil)]).warnings == ["VLAN 10 is already used by 'USERS'."])
        #expect(plan([], [.add(name: "USERS", vlanID: 50, description: nil)]).warnings == ["A VLAN named 'USERS' already exists."])
        #expect(plan([], [.add(name: "X", vlanID: 1003, description: nil)]).warnings == ["VLANs 1002–1005 are reserved on Cisco switches."])
        #expect(plan([], [.add(name: "X", vlanID: 5000, description: nil)]).warnings == ["The VLAN number must be between 1 and 4094."])
        #expect(plan([], [.add(name: "My VLAN", vlanID: 70, description: nil)]).warnings.count == 1)
        #expect(plan([], [.add(name: "Y", vlanID: 71, description: "Lab")]).warnings == ["IOS VLANs have no description. Leave it empty."])
    }

    @Test func vlanRename() {
        let p = plan([], [.rename(from: "CAMERAS", to: "CCTV")])
        #expect(p.commands == ["vlan 32", " name CCTV", "exit"])
        #expect(p.changes.first?.summary == "VLAN 'CAMERAS' will be renamed to 'CCTV'")
        #expect(p.warnings.isEmpty)
        #expect(plan([], [.rename(from: "default", to: "MAIN")]).warnings == ["The default VLAN (1) can't be renamed or deleted."])
        #expect(plan([], [.rename(from: "CAMERAS", to: "USERS")]).warnings == ["A VLAN named 'USERS' already exists."])
    }

    @Test func vlanDelete() {
        let p = plan([], [.delete(name: "PRINTERS")])
        #expect(p.commands == ["no vlan 30"])
        #expect(p.changes.first?.summary == "VLAN 'PRINTERS' will be deleted")
        #expect(p.warnings == ["'PRINTERS' is used on Gi1/0/4. Move those ports to another VLAN first."])
        // Only trunks carry GUEST-WIFI: they keep the number in their list harmlessly.
        #expect(plan([], [.delete(name: "GUEST-WIFI")]).warnings.isEmpty)
        // The port is moved in the same plan.
        let moved = plan([PortEdit(port: "GigabitEthernet1/0/4", vlans: ["USERS"])], [.delete(name: "PRINTERS")])
        #expect(moved.warnings.isEmpty)
        #expect(plan([], [.delete(name: "NOPE")]).warnings == ["There is no VLAN named 'NOPE'."])
    }

    @Test func vlanNumberCannotChange() {
        let p = plan([], [.update(name: "VOICE", vlanID: 21, description: nil)])
        #expect(p.commands.isEmpty)
        #expect(p.changes.first?.summary == "VLAN 'VOICE': number: 20 → 21")
        #expect(p.warnings == ["IOS can't change a VLAN's number. Add a VLAN with the new number and move the ports to it."])
        #expect(plan([], [.update(name: "VOICE", vlanID: 20, description: nil)]).changes.isEmpty)
    }

    @Test func previewDiff() {
        #expect(CiscoDriver.diff(["interface GigabitEthernet1/0/3", " description X", "exit", "no vlan 30"])
                == "+ interface GigabitEthernet1/0/3\n+  description X\n+ no vlan 30")
        #expect(CiscoDriver.saysNothingPending("%No Rollback Confirmed Change pending"))
        #expect(!CiscoDriver.saysNothingPending(""))
    }
}

// MARK: - Driver against a scripted IOS

/// A tiny IOS stand-in: echoes each line, answers the commands the driver uses and tracks the mode,
/// the archive and the revert timer.
final class CiscoFakeIOS: Transport, @unchecked Sendable {
    let displayName = "fake-ios"
    private let lock = NSLock()
    private var onData: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable (String?) -> Void)?
    private var line = ""
    private var mode = "exec"
    private var archive: Bool
    private let revertTimer: Bool
    private let reject: Set<String>
    private var armed = false
    private var log: [String] = []

    init(archive: Bool = true, revertTimer: Bool = true, reject: Set<String> = []) {
        self.archive = archive
        self.revertTimer = revertTimer
        self.reject = reject
    }

    var received: [String] { lock.lock(); defer { lock.unlock() }; return log }
    var timerArmed: Bool { lock.lock(); defer { lock.unlock() }; return armed }

    func open(onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (String?) -> Void) throws {
        lock.lock()
        self.onData = onData
        self.onClose = onClose
        lock.unlock()
    }

    func send(_ data: Data) throws {
        var out = ""
        var closing = false
        lock.lock()
        for ch in String(decoding: data, as: UTF8.self) {
            if ch == "\r" {
                let (text, close) = respond(line)
                out += text
                closing = closing || close
                line = ""
            } else {
                line.append(ch)
            }
        }
        let deliver = onData, closer = onClose
        lock.unlock()
        if !out.isEmpty { deliver?(Data(out.utf8)) }
        if closing { closer?(nil) }
    }

    func close() {}

    private var prompt: String {
        switch mode {
        case "exec": return "SW1#"
        case "config": return "SW1(config)#"
        default: return "SW1(config-\(mode))#"
        }
    }

    /// Called with the lock held.
    private func respond(_ command: String) -> (String, Bool) {
        log.append(command)
        let c = command.trimmingCharacters(in: .whitespaces)
        var body = ""
        if reject.contains(command) {
            body = "                ^\r\n% Invalid input detected at '^' marker.\r\n\r\n"
        } else if mode == "exec" {
            switch c {
            case "show version": body = "Cisco IOS XE Software, Version 17.09.04a\r\nSW1 uptime is 1 week\r\n"
            case "show archive":
                body = archive ? "The next archive file will be named flash:netdeck-Nov-17-10-15-02.517-1\r\n" : "Archive feature not enabled\r\n"
            case "configure terminal":
                mode = "config"
                body = "Enter configuration commands, one per line.  End with CNTL/Z.\r\n"
            case let x where x.hasPrefix("configure terminal revert timer "):
                if revertTimer {
                    armed = true
                    mode = "config"
                    body = "Rollback Confirmed Change: Backing up current running config to flash:netdeck-Nov-17-10-15-02.517-1\r\nEnter configuration commands, one per line.  End with CNTL/Z.\r\n"
                } else {
                    body = "                             ^\r\n% Invalid input detected at '^' marker.\r\n\r\n"
                }
            case "configure confirm", "configure revert now":
                if armed { armed = false } else { body = "%No Rollback Confirmed Change pending\r\n" }
            case "write memory": body = "Building configuration...\r\n[OK]\r\n"
            case "exit": return (command + "\r\n", true)
            default: break
            }
        } else {
            switch c {
            case "end": mode = "exec"
            case "exit": mode = mode == "config" ? "exec" : "config"
            case "archive": mode = "archive"
            case let x where x.hasPrefix("path "): archive = true
            case let x where x.hasPrefix("interface "): mode = "if"
            case let x where x.hasPrefix("vlan "): mode = "vlan"
            default: break
            }
        }
        return (command + "\r\n" + body + prompt, false)
    }
}

@Suite struct CiscoDriverTests {
    let plan = ChangePlan(changes: [PlannedChange(kind: .port, subject: "GigabitEthernet1/0/3", summary: "",
                                                  commands: ["interface GigabitEthernet1/0/3", " description X", "exit"])])

    init() { L10n.language = .en }

    @Test func appliesUnderTheRevertTimerAndSavesOnlyAfterConfirm() async throws {
        let ios = CiscoFakeIOS()
        let driver = CiscoDriver(transport: ios)
        try await driver.connect(username: "admin", password: nil)
        let r = try await driver.apply(plan, confirmMinutes: 5, comment: "Netdeck: test")
        #expect(r.confirmMinutes == 5)
        #expect(ios.timerArmed)
        let sent = ios.received
        let timer = try #require(sent.firstIndex(of: "configure terminal revert timer 5"))
        let first = try #require(sent.firstIndex(of: "interface GigabitEthernet1/0/3"))
        #expect(timer < first)
        #expect(sent.last == "end")
        #expect(!sent.contains("archive"))
        #expect(!sent.contains("write memory"))

        try await driver.confirm(comment: "Netdeck: test (confirmed)")
        #expect(!ios.timerArmed)
        let after = ios.received
        let confirm = try #require(after.firstIndex(of: "configure confirm"))
        let save = try #require(after.firstIndex(of: "write memory"))
        #expect(confirm < save)
    }

    @Test func rejectedCommandRevertsAtOnce() async throws {
        let ios = CiscoFakeIOS(reject: [" description X"])
        let driver = CiscoDriver(transport: ios)
        try await driver.connect(username: "admin", password: nil)
        do {
            _ = try await driver.apply(plan, confirmMinutes: 5, comment: "c")
            Issue.record("apply should have failed")
        } catch let DriverError.rejected(lines) {
            #expect(lines.first?.contains("% Invalid input detected") == true)
        }
        let sent = ios.received
        let end = try #require(sent.lastIndex(of: "end"))
        let revert = try #require(sent.lastIndex(of: "configure revert now"))
        #expect(end < revert)
        #expect(!ios.timerArmed)
        #expect(!sent.contains("exit"))   // nothing after the rejected line
    }

    @Test func noRevertTimerMeansNoChange() async throws {
        let ios = CiscoFakeIOS(revertTimer: false)
        let driver = CiscoDriver(transport: ios)
        try await driver.connect(username: "admin", password: nil)
        do {
            _ = try await driver.apply(plan, confirmMinutes: 5, comment: "c")
            Issue.record("apply should have failed")
        } catch let DriverError.safetyNetUnavailable(why) {
            #expect(why.contains("no revert timer"))
        }
        #expect(!ios.received.contains("interface GigabitEthernet1/0/3"))
    }

    @Test func setsUpTheArchiveFirst() async throws {
        let ios = CiscoFakeIOS(archive: false)
        let driver = CiscoDriver(transport: ios)
        try await driver.connect(username: "admin", password: nil)
        _ = try await driver.apply(plan, confirmMinutes: 3, comment: "c")
        let sent = ios.received
        let path = try #require(sent.firstIndex(of: " path flash:netdeck"))
        let timer = try #require(sent.firstIndex(of: "configure terminal revert timer 3"))
        #expect(path < timer)
        #expect(sent.contains(" maximum 5"))
        let preview = try await driver.preview(plan)
        #expect(preview.checkPassed)
        #expect(preview.diff == "+ interface GigabitEthernet1/0/3\n+  description X")
    }

    @Test func revertWithNothingPending() async throws {
        let ios = CiscoFakeIOS()
        let driver = CiscoDriver(transport: ios)
        try await driver.connect(username: "admin", password: nil)
        await #expect(throws: DriverError.nothingPending) { try await driver.revertPending(expectedComment: "c") }
        await #expect(throws: DriverError.nothingPending) { try await driver.confirm(comment: "c") }
        #expect(!ios.received.contains("write memory"))
    }
}

@Suite struct CiscoCDPTests {
    static let cdp = """
    Capability Codes: R - Router, T - Trans Bridge, B - Source Route Bridge
                      S - Switch, H - Host, I - IGMP, r - Repeater, P - Phone,
                      D - Remote, C - CVTA, M - Two-port Mac Relay

    Device ID        Local Intrfce     Holdtme    Capability  Platform  Port ID
    core-sw.example.test
                     Gig 1/0/1         150             S I    WS-C3850- Ten 1/1/1
    R1               Gig 1/0/2         163              R B S I ISR4331/K Gig 0/0/0
    AP01             Gig 1/0/5         122             T B I  AIR-AP280 Gig 0

    Total cdp entries displayed : 3
    """

    @Test func parsesRowsAndWrappedDeviceIDs() {
        let n = CiscoParsers.cdpNeighbors(Self.cdp)
        #expect(n.count == 3)
        #expect(n[0].systemName == "core-sw.example.test")
        #expect(n[0].localInterface == "Gig1/0/1")
        #expect(n[0].portInfo == "Ten 1/1/1")
        #expect(n[1].systemName == "R1")
        #expect(n[1].chassisID.contains("ISR4331"))
        #expect(CiscoParsers.cdpNeighbors("% CDP is not enabled").isEmpty)
    }

    @Test func cdpFillsPortsWithoutLLDP() {
        var o = CiscoSnapshotBuilder.Outputs()
        o.runningConfig = "hostname sw1\n!\ninterface GigabitEthernet1/0/1\n!\ninterface GigabitEthernet1/0/2\n!\nend"
        o.cdp = Self.cdp
        let snap = CiscoSnapshotBuilder.build(o)
        #expect(snap.lldp.map(\.localInterface).contains("GigabitEthernet1/0/1"))
        #expect(snap.lldp.first { $0.localInterface == "GigabitEthernet1/0/2" }?.systemName == "R1")
    }
}
