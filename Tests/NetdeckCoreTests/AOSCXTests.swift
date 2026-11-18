import Foundation
import Testing
@testable import NetdeckCore

/// Synthetic AOS-CX captures (see Fixtures/synthetic/aoscx/README.md), stripped the way `CLISession` strips live output.
func aoscxFixture(_ name: String) throws -> String {
    L10n.language = .en
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/synthetic/aoscx"))
    return CLISession.strip(try String(contentsOf: url, encoding: .utf8), dialect: AOSCXDialect())
}

func aoscx6300Snapshot() throws -> SwitchSnapshot {
    var o = AOSCXSnapshotBuilder.Outputs()
    o.version = try aoscxFixture("6300m-show-version")
    o.system = try aoscxFixture("6300m-show-system")
    o.runningConfig = try aoscxFixture("6300m-running-config")
    o.interfaceBrief = try aoscxFixture("6300m-interface-brief")
    o.vlans = try aoscxFixture("6300m-show-vlan")
    o.macTable = try aoscxFixture("6300m-mac-address-table")
    o.lldp = try aoscxFixture("6300m-lldp-neighbor-info")
    return AOSCXSnapshotBuilder.build(o)
}

@Suite struct AOSCXDialectTests {
    let d = AOSCXDialect()

    @Test func promptKinds() {
        #expect(d.prompt("sw-cx-01# ") == .operational)
        #expect(d.prompt("switch>") == .user)
        #expect(d.prompt("switch(config)#") == .configuration)
        #expect(d.prompt("switch(config-if)# ") == .configuration)
        #expect(d.prompt("switch(config-vlan-100)#") == .configuration)
        #expect(d.prompt("switch(config-lag-if)#") == .configuration)
        #expect(d.prompt("-- MORE --, next page: Space, next line: Enter, quit: q") == .pager)
        #expect(d.prompt("switch login:") == .login)
        #expect(d.prompt("Password:") == .password)
        #expect(d.prompt("Do you want to continue (y/n)?") == .question)
        // The auto checkpoint reminder lands on the prompt line.
        #expect(d.prompt("sw-cx-01# WARNING") == .operational)
    }

    @Test func outputLinesAreNotPrompts() {
        #expect(d.prompt("    description Switch#1") == nil)
        #expect(d.prompt("Version      : FL.10.13.1101") == nil)
        #expect(d.prompt("1/1/1      10      access 1GbT") == nil)
    }

    @Test func errorsAndAsyncMessages() {
        #expect(d.errors(in: "Invalid input: vlan-acces") == ["Invalid input: vlan-acces"])
        #expect(d.errors(in: "% Command incomplete.") == ["% Command incomplete."])
        #expect(d.errors(in: "Error: Checkpoint auto timer is already ON") == ["Error: Checkpoint auto timer is already ON"])
        #expect(d.errors(in: "VLAN 40 doesn't exist") == ["VLAN 40 doesn't exist"])
        #expect(d.errors(in: "Success\nAuto checkpoint mode expires in 5 minute(s)").isEmpty)
        #expect(d.isAsyncMessage("WARNING"))
        #expect(d.isAsyncMessage("Please \"checkpoint auto confirm\" within 2 minutes"))
        #expect(d.isAsyncMessage("WARNING: Restoring configuration. Do NOT add any new configuration."))
        #expect(!d.isAsyncMessage("1/1/1      10      access"))
        // A reminder after the prompt doesn't hide it, and leaves no trace in the next output.
        let text = "show vlan\nVLAN  Name\nsw-cx-01# WARNING\nPlease \"checkpoint auto confirm\" within 2 minutes\n"
        #expect(d.prompt(CLISession.lastPromptCandidate(of: text, dialect: d)) == .operational)
        #expect(CLISession.strip(text, dialect: d) == "VLAN  Name")
    }

    @Test func leaving() {
        #expect(d.logout(from: .configuration) == "end\r")
        #expect(d.logout(from: .operational) == "exit\r")
        #expect(d.setupCommands == ["no page"])
    }
}

@Suite struct AOSCXParserTests {
    @Test func versionAndSystem() throws {
        let v = try aoscxFixture("6300m-show-version")
        #expect(AOSCXParsers.isAOSCX(v))
        #expect(AOSCXParsers.osVersion(v) == "FL.10.13.1101")
        #expect(AOSCXParsers.release("FL.10.13.1101")?.major == 10 && AOSCXParsers.release("FL.10.13.1101")?.minor == 13)
        #expect(AOSCXParsers.osVersion("Version : PL.10.10.1090") == "PL.10.10.1090")
        let s = AOSCXParsers.system(try aoscxFixture("6300m-show-system"))
        #expect(s == AOSCXSystem(hostname: "sw-cx-01", productName: "JL661A 6300M 48G CL4 PoE 4SFP56 Swch", serial: "TEST0CX0001",
                                 version: "FL.10.13.1101"))
        #expect(AOSCXParsers.model(fromProduct: s.productName!) == "JL661A 6300M 48G CL4 PoE 4SFP56")
        #expect(!AOSCXParsers.isAOSCX("Cisco IOS XE Software, Version 17.09.04a"))
    }

    @Test func runningConfig() throws {
        let rc = AOSCXParsers.runningConfig(try aoscxFixture("6300m-running-config"))
        #expect(rc.hostname == "sw-cx-01")
        #expect(Set(rc.vlans.keys) == [1, 10, 20, 30, 99])
        #expect(rc.vlans[10] == AOSCXVLANConfig(name: "Servers"))
        #expect(rc.vlans[20] == AOSCXVLANConfig(name: "Voice", description: "IP phones"))
        #expect(rc.vlans[99] == AOSCXVLANConfig())
        let byName = Dictionary(uniqueKeysWithValues: rc.interfaces.map { ($0.name, $0) })
        #expect(byName["lag1"]?.trunkAllowed == [1, 10, 20, 30] && byName["lag1"]?.routing == false)
        #expect(byName["1/1/1"] == AOSCXInterfaceConfig(name: "1/1/1", description: "srv-01", shutdown: false, routing: false, accessVLAN: 10))
        #expect(byName["1/1/3"]?.trunkNative == 30 && byName["1/1/3"]?.trunkAllowed == [20, 30])
        #expect(byName["1/1/4"]?.shutdown == true)
        #expect(byName["1/1/45"]?.allowedAll == true && byName["1/1/45"]?.trunkAllowed == nil)
        #expect(byName["1/1/46"]?.addresses == ["192.0.2.2/30"] && byName["1/1/46"]?.routing == nil)
        #expect(byName["1/1/51"]?.lag == 1)
        #expect(byName["vlan1"]?.addresses == ["192.0.2.10/24"])
        #expect(byName["mgmt"] != nil)
        #expect(AOSCXParsers.interfaceName("lag 7 multi-chassis static") == "lag7")
    }

    @Test func configTextDropsHeader() throws {
        let text = AOSCXParsers.configText(try aoscxFixture("6300m-running-config"))
        #expect(text.hasPrefix("!\n!Version ArubaOS-CX FL.10.13.1101"))
        #expect(!text.contains("Current configuration:"))
    }

    @Test func interfaceBrief() throws {
        let rows = AOSCXParsers.interfaceBrief(try aoscxFixture("6300m-interface-brief"))
        #expect(rows.count == 54)
        let byPort = Dictionary(uniqueKeysWithValues: rows.map { ($0.port, $0) })
        #expect(byPort["1/1/1"] == AOSCXInterfaceRow(port: "1/1/1", nativeVLAN: 10, mode: "access", type: "1GbT", enabled: true, up: true,
                                                     reason: "", speed: 1000, description: "srv-01"))
        #expect(byPort["1/1/2"]?.description == nil)
        #expect(byPort["1/1/4"]?.reason == "Administratively down" && byPort["1/1/4"]?.enabled == false)
        #expect(byPort["1/1/46"]?.mode == "routed" && byPort["1/1/46"]?.nativeVLAN == nil)
        #expect(byPort["1/1/50"]?.type == "--" && byPort["1/1/50"]?.reason == "No XCVR installed" && byPort["1/1/50"]?.speed == nil)
        #expect(byPort["lag1"]?.description == "uplink-core")
    }

    @Test func vlansMacsAndLLDP() throws {
        let vlans = AOSCXParsers.vlans(try aoscxFixture("6300m-show-vlan"))
        #expect(vlans.map(\.id) == [1, 10, 20, 30, 99])
        #expect(vlans.map(\.name) == ["DEFAULT_VLAN_1", "Servers", "Voice", "Guests", "VLAN99"])
        let macs = AOSCXParsers.macTable(try aoscxFixture("6300m-mac-address-table"))
        #expect(macs.count == 7)
        #expect(macs.first?.mac == "48:a9:8a:00:10:01" && macs.first?.vlan == 10 && macs.first?.port == "1/1/1")
        let lldp = AOSCXParsers.lldpNeighbors(try aoscxFixture("6300m-lldp-neighbor-info"))
        #expect(lldp.count == 4)
        #expect(lldp[0] == LLDPNeighbor(localInterface: "1/1/3", chassisID: "48:a9:8a:00:30:03", portInfo: "LAN Port", systemName: "SEP48A98A003003"))
        #expect(lldp[2] == LLDPNeighbor(localInterface: "1/1/51", chassisID: "48:a9:8a:00:fe:01", portInfo: "1/1/12", systemName: "core sw 01"))
    }
}

@Suite struct AOSCXSnapshotTests {
    @Test func aruba6300M() throws {
        let s = try aoscx6300Snapshot()
        #expect(s.platform == .arubaAOSCX)
        #expect(s.hostname == "sw-cx-01")
        #expect(s.model == "JL661A 6300M 48G CL4 PoE 4SFP56")
        #expect(s.hardware.serial == "TEST0CX0001")
        #expect(s.osVersion == "FL.10.13.1101")
        #expect(s.kind == .switchDevice)
        #expect(s.config.vlans.map(\.name) == ["DEFAULT_VLAN_1", "Servers", "Voice", "Guests", "VLAN99"])
        #expect(s.config.vlans.first { $0.name == "Voice" }?.description == "IP phones")

        let ports = s.ports
        #expect(ports.count == 52)
        #expect(ports.prefix(48).allSatisfy { $0.kind == .copper })
        #expect(ports.suffix(4).allSatisfy { $0.kind == .sfp })
        func port(_ n: String) throws -> SwitchPort { try #require(s.port(named: n)) }

        let p1 = try port("1/1/1")
        #expect(p1.mode == .access && p1.vlans == ["Servers"] && p1.description == "srv-01" && p1.linkUp && p1.speed == "1G")
        #expect(p1.macs.map(\.mac) == ["48:a9:8a:00:10:01"] && p1.macs.first?.vlan == "Servers")
        let p3 = try port("1/1/3")
        #expect(p3.mode == .trunk && p3.vlans == ["Voice", "Guests"] && p3.nativeVlanID == 30 && p3.speed == "100Mbps")
        #expect(p3.lldp.first?.systemName == "SEP48A98A003003")
        let p4 = try port("1/1/4")
        #expect(p4.configDisabled && !p4.adminUp && p4.vlans == ["VLAN99"])
        #expect(try port("1/1/45").vlans == ["DEFAULT_VLAN_1", "Servers", "Voice", "Guests", "VLAN99"])
        let p46 = try port("1/1/46")
        #expect(!p46.switching && p46.addresses == ["192.0.2.2/30"] && p46.mode == nil)
        let p50 = try port("1/1/50")
        #expect(p50.kind == .sfp && !p50.present)
        // LAG members carry the LAG's VLANs.
        let p51 = try port("1/1/51")
        #expect(p51.mode == .trunk && p51.vlans == ["DEFAULT_VLAN_1", "Servers", "Voice", "Guests"] && p51.speed == "10G")
        #expect(p51.lldp.first?.systemName == "core sw 01")

        guard case let .aoscx(state) = s.vendor else { Issue.record("no AOS-CX state"); return }
        #expect(state.version == "FL.10.13.1101")
        #expect(state.ports["1/1/51"] == AOSCXPortConfig(mode: .trunk, allowedVLANs: [1, 10, 20, 30], lag: 1))
        #expect(state.ports["1/1/46"]?.routed == true)
        #expect(s.configText.contains("interface 1/1/3"))
        #expect(s.changeTraits.canChange && !s.changeTraits.devicePreview)
    }
}

@Suite struct AOSCXPlannerTests {
    let snap: SwitchSnapshot

    init() throws {
        L10n.language = .en
        snap = try aoscx6300Snapshot()
    }

    func plan(_ ports: [PortEdit] = [], _ vlans: [VLANEdit] = []) -> ChangePlan {
        AOSCXPlanner.plan(snapshot: snap, ports: ports, vlans: vlans)
    }

    @Test func descriptionAndShutdown() {
        let c = plan([PortEdit(port: "1/1/2", description: "srv-02", enabled: false)]).changes[0]
        #expect(c.commands == ["interface 1/1/2", "    shutdown", "    description srv-02", "exit"])
        let up = plan([PortEdit(port: "1/1/4", description: "", enabled: true)]).changes
        #expect(up.isEmpty || up[0].commands.last == "exit")
        let on = plan([PortEdit(port: "1/1/48", enabled: true)]).changes[0]
        #expect(on.commands == ["interface 1/1/48", "    no shutdown", "exit"])
    }

    @Test func accessVLAN() {
        let c = plan([PortEdit(port: "1/1/2", vlans: ["Voice"])]).changes[0]
        #expect(c.commands == ["interface 1/1/2", "    vlan access 20", "exit"])
        #expect(c.warnings.isEmpty)
        #expect(plan([PortEdit(port: "1/1/2", vlans: ["Servers"])]).changes.isEmpty)
    }

    @Test func accessToTrunkSetsNativeThenTheList() {
        let c = plan([PortEdit(port: "1/1/2", mode: .trunk, vlans: ["Servers", "Voice"], nativeVlanID: .some(10))]).changes[0]
        #expect(c.commands == ["interface 1/1/2", "    vlan trunk native 10", "    vlan trunk allowed 10,20", "exit"])
        #expect(c.warnings.isEmpty)
    }

    @Test func trunkListAddsBeforeRemoving() {
        let c = plan([PortEdit(port: "1/1/3", vlans: ["Servers", "Guests"])]).changes[0]
        #expect(c.commands == ["interface 1/1/3", "    vlan trunk allowed 10", "    no vlan trunk allowed 20", "exit"])
    }

    @Test func nativeChangeSetsTheListAgain() {
        // `vlan trunk native` allows every VLAN, so the current list follows it.
        let c = plan([PortEdit(port: "1/1/3", nativeVlanID: .some(20))]).changes[0]
        #expect(c.commands == ["interface 1/1/3", "    vlan trunk native 20", "    vlan trunk allowed 20,30", "exit"])
        #expect(c.summary.contains("untagged VLAN: 30 → 20"))
    }

    @Test func trunkWithAllVLANsGetsAList() {
        let c = plan([PortEdit(port: "1/1/45", vlans: ["Voice", "Guests"])]).changes[0]
        #expect(c.commands == ["interface 1/1/45", "    vlan trunk allowed 20,30", "exit"])
    }

    @Test func warnings() {
        let empty = plan([PortEdit(port: "1/1/3", vlans: [])]).changes[0]
        #expect(empty.warnings.contains { $0.contains("at least one VLAN") })
        #expect(!empty.commands.contains { $0.contains("no vlan trunk allowed") })
        #expect(plan([PortEdit(port: "1/1/46", vlans: ["Servers"])]).changes[0].warnings.first?.contains("routed port") == true)
        let lag = plan([PortEdit(port: "1/1/51", vlans: ["Servers"])]).changes[0]
        #expect(lag.warnings.first?.contains("lag1") == true && lag.commands.isEmpty)
        #expect(plan([PortEdit(port: "1/1/2", vlans: ["Nope"])]).changes[0].warnings.contains { $0.contains("no VLAN named 'Nope'") })
        #expect(plan([PortEdit(port: "1/1/2", vlans: ["Servers", "Voice"])]).changes[0].warnings.contains { $0.contains("only one VLAN") })
        let native = plan([PortEdit(port: "1/1/3", nativeVlanID: .some(10))]).changes[0]
        #expect(native.warnings.contains { $0.contains("must also be a member") })
    }

    @Test func vlans() {
        let add = plan([], [.add(name: "Cameras", vlanID: 40, description: "CCTV")]).changes[0]
        #expect(add.commands == ["vlan 40", "    name Cameras", "    description CCTV", "exit"] && add.warnings.isEmpty)
        #expect(plan([], [.add(name: "bad name", vlanID: 41, description: nil)]).changes[0].warnings.contains { $0.contains("AOS-CX VLAN names") })
        #expect(plan([], [.add(name: "Servers", vlanID: 10, description: nil)]).changes[0].warnings.count == 2)
        #expect(plan([], [.rename(from: "Guests", to: "Visitors")]).changes[0].commands == ["vlan 30", "    name Visitors", "exit"])
        let desc = plan([], [.update(name: "Voice", vlanID: nil, description: "")]).changes[0]
        #expect(desc.commands == ["vlan 20", "    no description", "exit"])
        let number = plan([], [.update(name: "Voice", vlanID: 21, description: nil)]).changes[0]
        #expect(number.commands.isEmpty && number.warnings.count == 1)
        let del = plan([], [.delete(name: "Servers")]).changes[0]
        #expect(del.commands == ["no vlan 10"])
        #expect(del.warnings.first?.contains("1/1/1, 1/1/2, 1/1/49") == true)
        // Moving the ports away in the same plan clears the warning.
        let moved = plan([PortEdit(port: "1/1/1", vlans: ["Voice"]), PortEdit(port: "1/1/2", vlans: ["Voice"]),
                          PortEdit(port: "1/1/49", vlans: ["Voice"])], [.delete(name: "Servers")]).changes[0]
        #expect(moved.warnings.isEmpty)
        #expect(plan([], [.delete(name: "DEFAULT_VLAN_1")]).changes[0].warnings.contains { $0.contains("default VLAN") })
    }
}

/// A tiny AOS-CX stand-in: echoes each line, answers the commands the driver uses and tracks the mode,
/// Netdeck's checkpoint and the auto checkpoint timer.
final class AOSCXFake: Transport, @unchecked Sendable {
    let displayName = "fake-aoscx"
    private let lock = NSLock()
    private var onData: (@Sendable (Data) -> Void)?
    private var line = ""
    private var config = false
    private var checkpoints: Set<String> = []
    private var autoOn: Bool
    private let version: String
    private let reject: Set<String>
    private var log: [String] = []

    init(version: String = "FL.10.13.1101", autoAlreadyOn: Bool = false, reject: Set<String> = []) {
        self.version = version
        self.autoOn = autoAlreadyOn
        self.reject = reject
    }

    var received: [String] { lock.lock(); defer { lock.unlock() }; return log }
    var autoCheckpointOn: Bool { lock.lock(); defer { lock.unlock() }; return autoOn }
    var savedCheckpoints: Set<String> { lock.lock(); defer { lock.unlock() }; return checkpoints }

    func open(onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (String?) -> Void) throws {
        lock.lock(); self.onData = onData; lock.unlock()
    }

    func send(_ data: Data) throws {
        var out = ""
        lock.lock()
        for ch in String(decoding: data, as: UTF8.self) {
            if ch == "\r" {
                out += respond(line)
                line = ""
            } else {
                line.append(ch)
            }
        }
        let deliver = onData
        lock.unlock()
        if !out.isEmpty { deliver?(Data(out.utf8)) }
    }

    func close() {}

    /// Called with the lock held.
    private func respond(_ command: String) -> String {
        log.append(command)
        let c = command.trimmingCharacters(in: .whitespaces)
        var body = ""
        if reject.contains(c) {
            body = "Invalid input: \(c.split(separator: " ").last ?? "")\r\n"
        } else if !config {
            switch c {
            case "show version":
                body = "-----------------------------------------------------------------------------\r\nArubaOS-CX\r\n(c) Copyright 2017-2025 Hewlett Packard Enterprise Development LP\r\n-----------------------------------------------------------------------------\r\nVersion      : \(version)\r\n"
            case let x where x.hasPrefix("erase checkpoint "):
                checkpoints.remove(String(x.dropFirst("erase checkpoint ".count)))
            case let x where x.hasPrefix("copy running-config checkpoint "):
                checkpoints.insert(String(x.dropFirst("copy running-config checkpoint ".count)))
                body = "Success\r\n"
            case let x where x.hasPrefix("checkpoint auto ") && x != "checkpoint auto confirm":
                if autoOn {
                    body = "Error: Checkpoint auto timer is already ON\r\n"
                } else {
                    autoOn = true
                    body = "Auto checkpoint mode expires in \(x.dropFirst("checkpoint auto ".count)) minute(s)\r\n"
                }
            case "checkpoint auto confirm":
                if autoOn {
                    autoOn = false
                    body = "checkpoint AUTO20261118101500 created\r\n"
                } else {
                    body = "Error: Not in auto checkpoint mode\r\n"
                }
            case let x where x.hasPrefix("checkpoint rollback "):
                body = checkpoints.contains(String(x.dropFirst("checkpoint rollback ".count))) ? "Success\r\n" : "Error: Checkpoint doesn't exist\r\n"
            case "write memory": body = "Success\r\n"
            case "configure terminal": config = true
            default: break
            }
        } else if c == "end" {
            config = false
        }
        return command + "\r\n" + body + (config ? "sw-cx-01(config)# " : "sw-cx-01# ")
    }
}

@Suite struct AOSCXDriverTests {
    let plan = ChangePlan(changes: [PlannedChange(kind: .port, subject: "1/1/2", summary: "",
                                                  commands: ["interface 1/1/2", "    description srv-02", "exit"])])

    init() { L10n.language = .en }

    @Test func appliesUnderTheAutoCheckpointAndSavesOnlyAfterConfirm() async throws {
        let sw = AOSCXFake()
        let driver = AOSCXDriver(transport: sw)
        try await driver.connect(username: "admin", password: nil)
        let r = try await driver.apply(plan, confirmMinutes: 5, comment: "Netdeck: test")
        #expect(r.confirmMinutes == 5)
        #expect(sw.autoCheckpointOn)
        #expect(sw.savedCheckpoints == [AOSCXDriver.beforeCheckpoint])
        let sent = sw.received
        let saved = try #require(sent.firstIndex(of: "copy running-config checkpoint netdeck-before-change"))
        let armed = try #require(sent.firstIndex(of: "checkpoint auto 5"))
        let first = try #require(sent.firstIndex(of: "interface 1/1/2"))
        #expect(saved < armed && armed < first)
        #expect(sent.last == "end")
        #expect(!sent.contains("write memory"))

        try await driver.confirm(comment: "c")
        #expect(!sw.autoCheckpointOn)
        #expect(sw.savedCheckpoints.isEmpty)
        let after = sw.received
        let confirm = try #require(after.firstIndex(of: "checkpoint auto confirm"))
        let write = try #require(after.firstIndex(of: "write memory"))
        #expect(confirm < write)
        await #expect(throws: DriverError.nothingPending) { try await driver.confirm(comment: "again") }
    }

    @Test func rejectedCommandRollsBackAtOnce() async throws {
        let sw = AOSCXFake(reject: ["description srv-02"])
        let driver = AOSCXDriver(transport: sw)
        try await driver.connect(username: "admin", password: nil)
        do {
            _ = try await driver.apply(plan, confirmMinutes: 5, comment: "c")
            Issue.record("apply should have failed")
        } catch let DriverError.rejected(lines) {
            #expect(lines.first?.contains("Invalid input") == true)
        }
        let sent = sw.received
        let end = try #require(sent.lastIndex(of: "end"))
        let rollback = try #require(sent.lastIndex(of: "checkpoint rollback netdeck-before-change"))
        let confirm = try #require(sent.lastIndex(of: "checkpoint auto confirm"))
        #expect(end < rollback && rollback < confirm)
        #expect(!sw.autoCheckpointOn)
        #expect(!sent.contains("write memory"))
        #expect(!sent.contains("exit"))
    }

    @Test func revertNowPutsTheCheckpointBack() async throws {
        let sw = AOSCXFake()
        let driver = AOSCXDriver(transport: sw)
        try await driver.connect(username: "admin", password: nil)
        _ = try await driver.apply(plan, confirmMinutes: 3, comment: "c")
        try await driver.revertPending(expectedComment: "c")
        let sent = sw.received
        let rollback = try #require(sent.lastIndex(of: "checkpoint rollback netdeck-before-change"))
        let confirm = try #require(sent.lastIndex(of: "checkpoint auto confirm"))
        #expect(rollback < confirm)
        #expect(!sw.autoCheckpointOn && !sent.contains("write memory"))
    }

    @Test func someoneElsesCheckpointStopsTheChange() async throws {
        let sw = AOSCXFake(autoAlreadyOn: true)
        let driver = AOSCXDriver(transport: sw)
        try await driver.connect(username: "admin", password: nil)
        do {
            _ = try await driver.apply(plan, confirmMinutes: 5, comment: "c")
            Issue.record("apply should have failed")
        } catch let DriverError.safetyNetUnavailable(why) {
            #expect(why.contains("already waiting for confirmation"))
        }
        #expect(!sw.received.contains("configure terminal"))
    }

    @Test func oldReleasesAreNotChanged() async throws {
        let sw = AOSCXFake(version: "FL.10.04.0001")
        let driver = AOSCXDriver(transport: sw)
        try await driver.connect(username: "admin", password: nil)
        do {
            _ = try await driver.apply(plan, confirmMinutes: 5, comment: "c")
            Issue.record("apply should have failed")
        } catch let DriverError.safetyNetUnavailable(why) {
            #expect(why.contains("10.06"))
        }
        #expect(!sw.received.contains { $0.hasPrefix("checkpoint") || $0 == "configure terminal" })
    }

    @Test func detectionAndHandOverFromCisco() async throws {
        let banner = "Last login: 2026-11-18 10:12:01 from 192.0.2.50\nUser \"admin\" has logged in 12 times in the past 30 days\nsw-cx-01# "
        #expect(DeviceDetector.detect(banner)?.platform == .arubaAOSCX)
        let version = try aoscxFixture("6300m-show-version")
        let found = try #require(DeviceDetector.detect(version))
        #expect(found.platform == .arubaAOSCX && found.osVersion == "FL.10.13.1101")
        // The prompt alone looks like IOS; the Cisco driver hands over once `show version` says AOS-CX.
        #expect(DeviceDetector.foreignPrompt("sw-cx-01#") == .ciscoIOS)
        let cisco = CiscoDriver(transport: AOSCXFake())
        await #expect(throws: CLIError.self) { try await cisco.connect(username: "admin", password: nil) }
        #expect(Platform.arubaAOSCX.displayName == "Aruba AOS-CX")
        #expect(DriverFactory.supports(.arubaAOSCX, over: .ssh) && !DriverFactory.supports(.arubaAOSCX, over: .api))
    }
}
