import Foundation
import Testing
@testable import NetdeckCore

@Suite struct HistoryTests {
    @Test func compareOutputBecomesSetLines() throws {
        let d = ConfigCompare.setDiff(fromCompare: try fixture("rollback-compare-2-0"))
        #expect(d.removed == ["set interfaces interface-range UNUSED member-range ge-0/0/2 to ge-0/0/23"])
        #expect(d.added.contains("set interfaces interface-range UNUSED member-range ge-0/0/3 to ge-0/0/23"))
        #expect(d.added.contains("set interfaces ge-0/0/2 description R640-PVE-01"))
        #expect(d.added.contains("set interfaces ge-0/0/2 unit 0 family ethernet-switching interface-mode access"))
        #expect(d.added.contains("set interfaces ge-0/0/2 unit 0 family ethernet-switching vlan members cust-01"))
        #expect(d.added.contains("set protocols rstp interface ge-0/0/2 edge"))
        #expect(d.added.count == 5)
        #expect(ConfigCompare.setDiff(fromCompare: try fixture("rollback-compare-1-0")) == SetDiff.Result(removed: [], added: []))
    }

    @Test func leafListsAndNewContainers() {
        let text = """
        [edit vlans]
        +   lab {
        +       vlan-id 200;
        +   }
        [edit interfaces ge-0/0/5 unit 0 family ethernet-switching vlan]
        -       members [ cust-01 mgmt ];
        +       members infra;
        """
        let d = ConfigCompare.setDiff(fromCompare: text)
        #expect(d.added == ["set vlans lab vlan-id 200", "set interfaces ge-0/0/5 unit 0 family ethernet-switching vlan members infra"])
        #expect(d.removed == ["set interfaces ge-0/0/5 unit 0 family ethernet-switching vlan members cust-01",
                              "set interfaces ge-0/0/5 unit 0 family ethernet-switching vlan members mgmt"])
    }

    @Test func summaryOfTheSampleCommitInPlainWords() throws {
        let config = SetConfigParser.parse(try fixture("config-set"))
        let items = DiffSummary.items(ConfigCompare.setDiff(fromCompare: try fixture("rollback-compare-2-0")), current: config)
        #expect(items == [
            .init(sign: .changed, kind: .leftDisabledRange(port: "ge-0/0/2", range: "UNUSED")),
            .init(sign: .added, kind: .description(port: "ge-0/0/2", value: "R640-PVE-01")),
            .init(sign: .added, kind: .accessVLAN(port: "ge-0/0/2", vlan: "cust-01")),
            .init(sign: .added, kind: .edge(port: "ge-0/0/2")),
        ])
        // Going back to #2 does the opposite.
        let back = DiffSummary.items(DiffSummary.reversed(ConfigCompare.setDiff(fromCompare: try fixture("rollback-compare-2-0"))), current: config)
        #expect(back.contains(.init(sign: .changed, kind: .joinedDisabledRange(port: "ge-0/0/2", range: "UNUSED"))))
        #expect(back.contains(.init(sign: .removed, kind: .descriptionRemoved(port: "ge-0/0/2"))))
        #expect(back.contains(.init(sign: .removed, kind: .leftVLAN(port: "ge-0/0/2", vlan: "cust-01"))))
        #expect(back.contains(.init(sign: .removed, kind: .notEdge(port: "ge-0/0/2"))))
        #expect(back.count == 4)
    }

    @Test func unknownStatementsStayVisible() {
        let d = SetDiff.Result(removed: ["set system ntp server 192.0.2.1"], added: ["set system ntp server 192.0.2.2", "set snmp location rack-1"])
        let items = DiffSummary.items(d, current: nil)
        #expect(items.contains(.init(sign: .changed, kind: .other(subject: "system", statement: "ntp server 192.0.2.2"))))
        #expect(items.contains(.init(sign: .added, kind: .other(subject: "snmp", statement: "location rack-1"))))
        #expect(!items.contains { if case .other(_, "ntp server 192.0.2.1") = $0.kind { return true }; return false })
    }

    @Test func commitTimerAndDate() throws {
        let c = OutputParsers.commitHistory(try fixture("system-commit"))
        #expect(c[1].confirmMinutes == 5)
        #expect(c[0].confirmMinutes == nil)
        let date = try #require(c[0].date)   // 2026-10-30 05:37:08 EET
        #expect(date == ISO8601DateFormatter().date(from: "2026-10-30T03:37:08Z"))
    }

    @Test func failuresAreClassifiedForTheErrorCards() {
        let serial = DeviceProfile.Connection.serial(path: "/dev/cu.usbserial-1410", baud: 9600)
        let ssh = DeviceProfile.Connection.ssh(host: "192.0.2.10", port: 22)
        let exists: (String) -> Bool = { _ in true }, missing: (String) -> Bool = { _ in false }
        #expect(ConnectionFailure.classify(CLIError.authenticationFailed, connection: serial, reading: false, elapsed: 3, fileExists: exists) == .wrongPassword)
        #expect(ConnectionFailure.classify(TransportError.openFailed("No such file or directory"), connection: serial, reading: false, elapsed: 0, fileExists: missing)
                == .cableNotFound(path: "/dev/cu.usbserial-1410"))
        #expect(ConnectionFailure.classify(TransportError.openFailed(t("The port is in use by another app.")), connection: serial, reading: false, elapsed: 0, fileExists: exists)
                == .portBusy(path: "/dev/cu.usbserial-1410"))
        #expect(ConnectionFailure.classify(CLIError.unrecognizedPrompt(""), connection: serial, reading: false, elapsed: 15.2, fileExists: exists) == .notResponding(seconds: 15))
        #expect(ConnectionFailure.classify(CLIError.timeout(""), connection: serial, reading: true, elapsed: 9, fileExists: exists)
                == .droppedWhileReading(detail: CLIError.timeout("").errorDescription!))
        let refused = "The SSH session ended (exit code 255).\nssh: connect to host 192.0.2.10 port 22: Connection refused"
        #expect(ConnectionFailure.classify(CLIError.closed(refused), connection: ssh, reading: false, elapsed: 1) == .sshUnreachable(detail: refused))
        #expect(ConnectionFailure.classify(CLIError.closed("not supported"), connection: .api(url: "https://192.0.2.5"), reading: false, elapsed: 0)
                == .other("not supported"))
        let hostKey = "The SSH session ended (exit code 255).\nHost key verification failed."
        #expect(ConnectionFailure.classify(CLIError.closed(hostKey), connection: ssh, reading: false, elapsed: 1) == .hostKeyChanged(detail: hostKey))
    }

    @Test func mikrotikUptimeAndSerial() {
        let d = DeviceDetector.detect("MikroTik 7.16\n  uptime: 12d4h3m\n  board-name: RB5009UG+S+\n  serial-number: HEX0000001\n[admin@gw] > ")
        #expect(d?.uptime == "12d4h3m")
        #expect(d?.serial == "HEX0000001")
        #expect(d?.model == "RB5009UG+S+")
    }
}
