import Foundation
import Testing
@testable import NetdeckCore

/// Synthetic AOS-S captures (see Fixtures/synthetic/aoss/README.md), stripped the way `CLISession` strips live output.
func aossFixture(_ name: String) throws -> String {
    CLISession.strip(try aossRaw(name), dialect: AOSSDialect())
}

func aossRaw(_ name: String) throws -> String {
    L10n.language = .en
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/synthetic/aoss"))
    return try String(contentsOf: url, encoding: .utf8)
}

func aoss2930Snapshot(revision: String? = nil) throws -> SwitchSnapshot {
    var o = AOSSSnapshotBuilder.Outputs()
    o.version = try aossFixture("2930m-show-version")
    o.system = try aossFixture("2930m-show-system")
    if let revision { o.system = o.system.replacingOccurrences(of: "WC.16.11.0028", with: revision) }
    o.modules = try aossFixture("2930m-show-modules")
    o.runningConfig = try aossFixture("2930m-running-config")
    o.interfacesBrief = try aossFixture("2930m-interfaces-brief")
    o.vlans = try aossFixture("2930m-show-vlans")
    o.macTable = try aossFixture("2930m-mac-address")
    o.lldp = try aossFixture("2930m-lldp-remote-device")
    return AOSSSnapshotBuilder.build(o)
}

@Suite struct AOSSDialectTests {
    let d = AOSSDialect()

    @Test func promptKinds() {
        #expect(d.prompt("SW-ACCESS-01# ") == .operational)
        #expect(d.prompt("ProCurve Switch 2650# ") == .operational)
        #expect(d.prompt("HP-2920-24G>") == .user)
        #expect(d.prompt("SW-ACCESS-01(config)# ") == .configuration)
        #expect(d.prompt("SW-ACCESS-01(eth-A1)#") == .configuration)
        #expect(d.prompt("SW-ACCESS-01(eth-1-4)#") == .configuration)
        #expect(d.prompt("SW-ACCESS-01(vlan-10)#") == .configuration)
        #expect(d.prompt("Press any key to continue") == .pager)
        #expect(d.prompt("-- MORE --, next page: Space, next line: Enter, quit: Control-C") == .pager)
        #expect(d.prompt("Do you want to log out [y/n]? ") == .question)
        #expect(d.prompt("Do you want to save current configuration [y/n/^C]? ") == .question)
        #expect(d.prompt("Continue (y/n)? ") == .question)
        #expect(d.prompt("Username:") == .login)
        #expect(d.prompt("  Port  Type       | Alert     Enabled Status Mode") == nil)
    }

    @Test func loggingOutNeverSaves() {
        #expect(d.logout(from: .configuration, line: "SW(config)#") == "exit\r")
        #expect(d.logout(from: .operational, line: "SW#") == "logout\r")
        #expect(d.logout(from: .question, line: "Do you want to log out [y/n]? ") == "y\r")
        #expect(d.logout(from: .question, line: "Do you want to save current configuration [y/n/^C]? ") == "n\r")
        #expect(d.setupCommands == ["no page", "terminal width 511"])
    }

    @Test func errors() {
        #expect(d.errors(in: "Invalid input: vlam") == ["Invalid input: vlam"])
        #expect(d.errors(in: "Module not present for port or invalid port: 99") == ["Module not present for port or invalid port: 99"])
        #expect(d.errors(in: "Successfully applied configuration 'netdeck' to running configuration.").isEmpty)
    }

    @Test func terminalScrollsBecomeLineBreaks() throws {
        // AOS-S sends no line break between the echo of a command without output and the prompt.
        let raw = try aossRaw("raw-no-output-command")
        #expect(JunosCLI.clean(raw).contains("no pageSW-ACCESS-01#"))
        let cleaned = JunosCLI.clean(d.normalize(raw))
        #expect(d.prompt(CLISession.lastPromptCandidate(of: cleaned, dialect: d)) == .operational)
        #expect(CLISession.strip(raw, dialect: d) == "")
        let config = try aossRaw("raw-config-command")
        let line = CLISession.lastPromptCandidate(of: JunosCLI.clean(d.normalize(config)), dialect: d)
        #expect(d.prompt(line) == .configuration)
    }
}

@Suite struct AOSSParserTests {
    @Test func portLists() {
        #expect(AOSSParsers.ports("1-4,7,A1-A3,Trk1,1/1-1/3") == ["1", "2", "3", "4", "7", "A1", "A2", "A3", "Trk1", "1/1", "1/2", "1/3"])
        #expect(AOSSParsers.compress(["1", "2", "3", "7", "A1", "A2", "Trk1"]) == "1-3,7,A1-A2,Trk1")
    }

    @Test func versionSystemModules() throws {
        let v = try aossFixture("2930m-show-version")
        #expect(AOSSParsers.isAOSS(v) && AOSSParsers.softwareRevision(v) == "WC.16.11.0028")
        #expect(!AOSSParsers.isAOSS("Cisco IOS XE Software, Version 17.09.04a"))
        let s = AOSSParsers.system(try aossFixture("2930m-show-system"), modules: try aossFixture("2930m-show-modules"))
        #expect(s == AOSSSystem(name: "SW-ACCESS-01", softwareRevision: "WC.16.11.0028", serial: "TEST0AS001",
                                model: "2930M-48G-PoE+", productNumber: "JL322A"))
        #expect(AOSSParsers.release("K.15.18.0013")?.major == 15)
    }

    @Test func runningConfig() throws {
        let rc = AOSSParsers.runningConfig(try aossFixture("2930m-running-config"))
        #expect(rc.hostname == "SW-ACCESS-01" && rc.productNumber == "JL322A")
        #expect(rc.trunkOf == ["A3": "Trk1", "A4": "Trk1"])
        #expect(rc.vlans[1]?.untagged.count == 44)
        #expect(rc.vlans[1]?.untagged.contains("Trk1") == true && rc.vlans[1]?.untagged.contains("1") == false)
        #expect(rc.vlans[20] == AOSSVLANConfig(name: "Voice", untagged: ["47"], tagged: ["3", "45", "Trk1"]))
        #expect(rc.vlans[99]?.name == "Lab VLAN")
        #expect(rc.interfaces["3"] == AOSSInterfaceConfig(name: "phone desk 3"))
        #expect(rc.interfaces["4"]?.disabled == true)
        #expect(AOSSParsers.configText(try aossFixture("2930m-running-config")).hasPrefix("; JL322A Configuration Editor"))
    }

    @Test func tables() throws {
        let rows = AOSSParsers.interfacesBrief(try aossFixture("2930m-interfaces-brief"))
        #expect(rows.count == 52)
        #expect(rows[0] == AOSSPortRow(port: "1", trunk: nil, type: "100/1000T", enabled: true, up: true, mode: "1000FDx"))
        #expect(rows.first { $0.port == "A2" }?.type == "")
        #expect(rows.first { $0.port == "A3" }?.trunk == "Trk1")
        #expect(rows.first { $0.port == "48" }?.enabled == false)
        let vlans = AOSSParsers.vlans(try aossFixture("2930m-show-vlans"))
        #expect(vlans.map(\.id) == [1, 10, 20, 30, 99] && vlans.last?.name == "Lab VLAN")
        let macs = AOSSParsers.macTable(try aossFixture("2930m-mac-address"))
        #expect(macs.count == 7 && macs[0].mac == "48:a9:8a:00:10:01" && macs[0].vlan == 10 && macs.last?.port == "Trk1")
        let lldp = AOSSParsers.lldpNeighbors(try aossFixture("2930m-lldp-remote-device"))
        #expect(lldp == [
            LLDPNeighbor(localInterface: "3", chassisID: "48:a9:8a:00:30:03", portInfo: "LAN Port", systemName: "SEP48A98A003003"),
            LLDPNeighbor(localInterface: "A3", chassisID: "48:a9:8a:00:fe:01", portInfo: "1/1/12", systemName: "core-sw-01"),
            LLDPNeighbor(localInterface: "A4", chassisID: "48:a9:8a:00:fe:01", portInfo: "1/1/13", systemName: "core-sw-01"),
        ])
    }
}

@Suite struct AOSSSnapshotTests {
    @Test func aruba2930M() throws {
        let s = try aoss2930Snapshot()
        #expect(s.platform == .arubaAOSS && s.kind == .switchDevice)
        #expect(s.hostname == "SW-ACCESS-01" && s.model == "2930M-48G-PoE+" && s.hardware.serial == "TEST0AS001")
        #expect(s.osVersion == "WC.16.11.0028")
        #expect(s.config.vlans.map(\.name) == ["DEFAULT_VLAN", "Servers", "Voice", "Guests", "Lab VLAN"])
        let ports = s.ports
        #expect(ports.count == 52)
        #expect(ports.prefix(48).allSatisfy { $0.kind == .copper } && ports.suffix(4).allSatisfy { $0.kind == .sfp })
        #expect(ports.suffix(4).map(\.name) == ["A1", "A2", "A3", "A4"])
        func port(_ n: String) throws -> SwitchPort { try #require(s.port(named: n)) }
        let p1 = try port("1")
        #expect(p1.mode == .access && p1.vlans == ["Servers"] && p1.description == "srv-01" && p1.speed == "1G")
        #expect(p1.macs.first?.vlan == "Servers")
        let p3 = try port("3")
        #expect(p3.mode == .trunk && p3.vlans == ["Voice", "Guests"] && p3.nativeVlanID == 30 && p3.description == "phone desk 3")
        #expect(p3.lldp.first?.portInfo == "LAN Port")
        let p4 = try port("4")
        #expect(p4.configDisabled && p4.vlans == ["Lab VLAN"])
        #expect(try port("45").vlans == ["Servers", "Voice", "Guests"])
        #expect(!(try port("A2")).present)
        let a3 = try port("A3")
        #expect(a3.mode == .trunk && a3.vlans == ["DEFAULT_VLAN", "Servers", "Voice", "Guests"] && a3.nativeVlanID == 1 && a3.speed == "10G")
        guard case let .aoss(state) = s.vendor else { Issue.record("no AOS-S state"); return }
        #expect(state.ports["A3"] == AOSSPortConfig(untagged: 1, tagged: [10, 20, 30], trunk: "Trk1"))
        #expect(state.canRestoreWithoutReboot)
        #expect(!AOSSState(softwareRevision: "K.15.18.0013").canRestoreWithoutReboot)
        #expect(!AOSSState(softwareRevision: "KB.16.04.0016").canRestoreWithoutReboot)
        #expect(AOSSState(softwareRevision: "YA.16.05.0007").canRestoreWithoutReboot)
    }
}

@Suite struct AOSSPlannerTests {
    let snap: SwitchSnapshot

    init() throws {
        L10n.language = .en
        snap = try aoss2930Snapshot()
    }

    func plan(_ ports: [PortEdit] = [], _ vlans: [VLANEdit] = [], on s: SwitchSnapshot? = nil) -> ChangePlan {
        AOSSPlanner.plan(snapshot: s ?? snap, ports: ports, vlans: vlans)
    }

    @Test func nameAndState() {
        #expect(plan([PortEdit(port: "2", description: "srv 02", enabled: false)]).changes[0].commands
            == ["interface 2", "   disable", "   name \"srv 02\"", "   exit"])
        #expect(plan([PortEdit(port: "48", enabled: true)]).changes[0].commands == ["interface 48", "   enable", "   exit"])
        #expect(plan([PortEdit(port: "1", description: "")]).changes[0].commands == ["interface 1", "   no name", "   exit"])
        #expect(plan([PortEdit(port: "1", description: "a\"b")]).changes[0].warnings.count == 1)
    }

    @Test func membership() {
        #expect(plan([PortEdit(port: "2", vlans: ["Voice"])]).changes[0].commands == ["vlan 20 untagged 2"])
        #expect(plan([PortEdit(port: "2", mode: .trunk, vlans: ["Servers", "Voice"], nativeVlanID: .some(10))]).changes[0].commands
            == ["vlan 20 tagged 2"])
        #expect(plan([PortEdit(port: "3", vlans: ["Servers", "Guests"])]).changes[0].commands == ["vlan 10 tagged 3", "no vlan 20 tagged 3"])
        // The tagged VLAN becomes the untagged one; the old untagged one is kept as tagged.
        #expect(plan([PortEdit(port: "3", nativeVlanID: .some(20))]).changes[0].commands
            == ["no vlan 20 tagged 3", "vlan 20 untagged 3", "vlan 30 tagged 3"])
        #expect(plan([PortEdit(port: "45", mode: .access, vlans: ["Servers"])]).changes[0].commands
            == ["no vlan 10 tagged 45", "vlan 10 untagged 45", "no vlan 20 tagged 45"])
        #expect(plan([PortEdit(port: "2", vlans: ["Servers"])]).changes.isEmpty)
    }

    @Test func warnings() throws {
        let trunkMember = plan([PortEdit(port: "A3", vlans: ["Servers"])]).changes[0]
        #expect(trunkMember.commands.isEmpty && trunkMember.warnings.first?.contains("Trk1") == true)
        #expect(plan([PortEdit(port: "2", vlans: [])]).changes[0].warnings.contains { $0.contains("at least one VLAN") })
        #expect(plan([PortEdit(port: "2", vlans: ["Servers", "Voice"])]).changes[0].warnings.contains { $0.contains("only one VLAN") })
        let old = try aoss2930Snapshot(revision: "K.15.18.0013")
        let blocked = plan([PortEdit(port: "2", vlans: ["Voice"])], on: old).changes[0]
        #expect(blocked.warnings.contains { $0.contains("K.15.18.0013") && $0.contains("16.05") })
    }

    @Test func vlans() {
        #expect(plan([], [.add(name: "Cam Net", vlanID: 40, description: nil)]).changes[0].commands == ["vlan 40", "   name \"Cam Net\"", "   exit"])
        #expect(plan([], [.add(name: "Cams", vlanID: 41, description: "CCTV")]).changes[0].warnings.contains { $0.contains("no description") })
        #expect(plan([], [.rename(from: "Guests", to: "Visitors")]).changes[0].commands == ["vlan 30", "   name \"Visitors\"", "   exit"])
        let del = plan([], [.delete(name: "Servers")]).changes[0]
        #expect(del.commands == ["no vlan 10"] && del.warnings.first?.contains("1, 2, A1") == true)
        #expect(plan([], [.delete(name: "Lab VLAN")]).changes[0].warnings.first?.contains("4") == true)
        #expect(plan([], [.add(name: "x\"y", vlanID: 42, description: nil)]).changes[0].warnings.count == 1)
    }
}

/// A tiny AOS-S stand-in: echoes each line, tracks the context, flash configuration files, the alias and the job.
final class AOSSFake: Transport, @unchecked Sendable {
    let displayName = "fake-aoss"
    private let lock = NSLock()
    private var onData: (@Sendable (Data) -> Void)?
    private var line = ""
    private var context = "manager"
    private var files: Set<String> = ["config"]
    private var job = false
    private var restoring = false
    private let revision: String
    private let reject: Set<String>
    private var log: [String] = []

    init(revision: String = "WC.16.11.0028", jobAlreadyThere: Bool = false, reject: Set<String> = []) {
        self.revision = revision
        self.job = jobAlreadyThere
        self.reject = reject
    }

    var received: [String] { lock.lock(); defer { lock.unlock() }; return log }
    var jobScheduled: Bool { lock.lock(); defer { lock.unlock() }; return job }

    func open(onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (String?) -> Void) throws {
        lock.lock(); self.onData = onData; lock.unlock()
    }

    func send(_ data: Data) throws {
        var out = ""
        lock.lock()
        for ch in String(decoding: data, as: UTF8.self) {
            if ch == "\r" { out += respond(line); line = "" } else { line.append(ch) }
        }
        let deliver = onData
        lock.unlock()
        if !out.isEmpty { deliver?(Data(out.utf8)) }
    }

    func close() {}

    private var prompt: String {
        switch context {
        case "manager": return "SW-ACCESS-01# "
        case "config": return "SW-ACCESS-01(config)# "
        default: return "SW-ACCESS-01(\(context))# "
        }
    }

    /// Called with the lock held.
    private func respond(_ command: String) -> String {
        log.append(command)
        let c = command.trimmingCharacters(in: .whitespaces)
        var body = ""
        if restoring {
            restoring = false
            if c == "y" {
                job = false
                body = "Configuration restore is in progress, configuration changes are temporarily disabled.\r\nSuccessfully applied configuration 'netdeck' to running configuration.\r\n"
            }
        } else if reject.contains(c) {
            body = "Invalid input: \(c.split(separator: " ").last ?? "")\r\n"
        } else {
            switch c {
            case "show version": body = "Image stamp:\r\n /ws/swbuildm/x\r\n                \(revision)\r\n                530\r\nBoot Image:     Secondary\r\n"
            case "configure terminal": context = "config"
            case "exit": context = context == "config" ? "manager" : (context == "manager" ? "manager" : "config")
            case "show job netdeck-rollback":
                body = job ? " Job Information\r\n  Job Name    : netdeck-rollback\r\n  Runs At     : delay\r\n  Job Status  : Enabled\r\n  Run Count   : 0\r\n" : " Job 'netdeck-rollback' not found.\r\n"
            case "cfg-backup running-config config netdeck": files.insert("netdeck")
            case "show config files":
                body = " Configuration files:\r\n id | act pri sec | name\r\n ---+-------------+--------\r\n" + files.sorted().enumerated().map { "  \($0.offset + 1) |             | \($0.element)\r\n" }.joined()
            case let x where x.hasPrefix("job \"netdeck-rollback\" delay "): job = true
            case "no job \"netdeck-rollback\"": if job { job = false } else { body = "Job not found.\r\n" }
            case "cfg-restore flash netdeck":
                restoring = true
                return command + "\r\nCurrent running-configuration will be replaced with 'netdeck'.\r\nContinue (y/n)? "
            case let x where x.hasPrefix("interface "): context = "eth-\(x.dropFirst("interface ".count))"
            case let x where x.hasPrefix("vlan ") && !x.contains("tagged"): context = "vlan-\(x.dropFirst("vlan ".count))"
            default: break
            }
        }
        return command + "\r\n" + body + prompt
    }
}

@Suite struct AOSSDriverTests {
    let plan = ChangePlan(changes: [PlannedChange(kind: .port, subject: "2", summary: "",
                                                  commands: ["interface 2", "   name \"srv 02\"", "   exit", "vlan 20 untagged 2"])])

    init() { L10n.language = .en }

    @Test func appliesUnderTheRollbackJobAndSavesOnlyAfterConfirm() async throws {
        let sw = AOSSFake()
        let driver = AOSSDriver(transport: sw)
        try await driver.connect(username: "manager", password: nil)
        let r = try await driver.apply(plan, confirmMinutes: 5, comment: "c")
        #expect(r.confirmMinutes == 5 && sw.jobScheduled)
        let sent = sw.received
        let backup = try #require(sent.firstIndex(of: "cfg-backup running-config config netdeck"))
        let alias = try #require(sent.firstIndex(of: "alias \"netdeck-restore\" \"cfg-restore flash netdeck\""))
        let job = try #require(sent.firstIndex(of: "job \"netdeck-rollback\" delay 00:00:05 \"netdeck-restore\" count 1"))
        let first = try #require(sent.firstIndex(of: "interface 2"))
        #expect(backup < alias && alias < job && job < first)
        #expect(sent[(job + 1)...].contains("show job netdeck-rollback"))
        #expect(sent.last == "exit" && !sent.contains("write memory"))

        try await driver.confirm(comment: "c")
        #expect(!sw.jobScheduled)
        let after = sw.received
        let drop = try #require(after.lastIndex(of: "no job \"netdeck-rollback\""))
        let save = try #require(after.lastIndex(of: "write memory"))
        #expect(drop < save)
        await #expect(throws: DriverError.nothingPending) { try await driver.confirm(comment: "again") }
    }

    @Test func rejectedCommandRestoresAtOnce() async throws {
        let sw = AOSSFake(reject: ["vlan 20 untagged 2"])
        let driver = AOSSDriver(transport: sw)
        try await driver.connect(username: "manager", password: nil)
        do {
            _ = try await driver.apply(plan, confirmMinutes: 5, comment: "c")
            Issue.record("apply should have failed")
        } catch let DriverError.rejected(lines) {
            #expect(lines.first?.contains("Invalid input") == true)
        }
        let sent = sw.received
        let restore = try #require(sent.lastIndex(of: "cfg-restore flash netdeck"))
        #expect(sent[restore + 1] == "y")
        #expect(!sw.jobScheduled && !sent.contains("write memory"))
    }

    @Test func undoNow() async throws {
        let sw = AOSSFake()
        let driver = AOSSDriver(transport: sw)
        try await driver.connect(username: "manager", password: nil)
        _ = try await driver.apply(plan, confirmMinutes: 3, comment: "c")
        try await driver.revertPending(expectedComment: "c")
        #expect(sw.received.contains("cfg-restore flash netdeck") && !sw.jobScheduled && !sw.received.contains("write memory"))
        await #expect(throws: DriverError.nothingPending) { try await driver.revertPending(expectedComment: "c") }
    }

    @Test func pendingJobOrOldFirmwareStopsTheChange() async throws {
        let busy = AOSSFake(jobAlreadyThere: true)
        let d1 = AOSSDriver(transport: busy)
        try await d1.connect(username: "manager", password: nil)
        await #expect(throws: DriverError.self) { _ = try await d1.apply(plan, confirmMinutes: 5, comment: "c") }
        #expect(!busy.received.contains { $0.hasPrefix("cfg-backup") || $0 == "interface 2" })

        let old = AOSSFake(revision: "K.15.18.0013")
        let d2 = AOSSDriver(transport: old)
        try await d2.connect(username: "manager", password: nil)
        do {
            _ = try await d2.apply(plan, confirmMinutes: 5, comment: "c")
            Issue.record("apply should have failed")
        } catch let DriverError.safetyNetUnavailable(why) {
            #expect(why.contains("16.05"))
        }
        #expect(!old.received.contains("configure terminal"))
    }

    @Test func detection() async throws {
        let banner = "Aruba JL322A 2930M-48G-PoE+ Switch\nSoftware revision WC.16.11.0028\n\n (C) Copyright 2025 Hewlett Packard Enterprise Development LP\nPress any key to continue"
        let found = try #require(DeviceDetector.detect(banner))
        #expect(found.platform == .arubaAOSS && found.model == "2930M-48G-PoE+" && found.osVersion == "WC.16.11.0028")
        #expect(DeviceDetector.detect(try aossFixture("2930m-show-version"))?.platform == .arubaAOSS)
        #expect(DeviceDetector.detect("ProCurve J4899B Switch 2650")?.platform == .arubaAOSS)
        // "SW-ACCESS-01#" looks like IOS; the Cisco driver hands over from `show version`.
        let cisco = CiscoDriver(transport: AOSSFake())
        await #expect(throws: CLIError.self) { try await cisco.connect(username: "manager", password: nil) }
        #expect(Platform.arubaAOSS.displayName == "Aruba AOS-S")
    }
}
