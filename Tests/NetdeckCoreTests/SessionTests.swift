import Foundation
import Testing
@testable import NetdeckCore

@MainActor
@Suite struct SessionTests {
    func session() throws -> DeviceSession {
        let s = SwitchSnapshot(
            version: OutputParsers.version(try fixture("version")),
            hardware: OutputParsers.chassisHardware(try fixture("chassis-hardware")),
            config: SetConfigParser.parse(try fixture("config-set")),
            configText: try fixture("config-set"),
            statuses: OutputParsers.interfacesTerse(try fixture("interfaces-terse")),
            macTable: OutputParsers.macTable(try fixture("ethernet-switching-table")),
            lldp: [], commits: [], vcPorts: OutputParsers.vcPorts(try fixture("vc-port")))
        let profile = DeviceProfile(id: "test", name: "sw-01", connection: .serial(path: "/dev/null", baud: 9600), username: "root")
        return DeviceSession(profile: profile, snapshot: s)
    }

    @Test func stagingMergesAndCounts() throws {
        let s = try session()
        s.stage(PortEdit(port: "ge-0/0/2", description: "SRV02-IDRAC"))
        s.stage(PortEdit(port: "ge-0/0/3", enabled: true))
        s.stage(PortEdit(port: "ge-0/0/3", vlans: ["cust-01"]))
        #expect(s.pendingChangeCount == 2)
        #expect(s.edit(for: "ge-0/0/3")?.enabled == true)
        #expect(s.edit(for: "ge-0/0/3")?.vlans == ["cust-01"])
        #expect(s.plan.commands.first == "set interfaces ge-0/0/2 description SRV02-IDRAC")
    }

    @Test func revertingAnEditToCurrentValueDropsIt() throws {
        let s = try session()
        s.stage(PortEdit(port: "ge-0/0/2", description: "X"))
        #expect(s.pendingChangeCount == 1)
        s.stage(PortEdit(port: "ge-0/0/2", description: "R640-PVE-01"))
        #expect(s.pendingChangeCount == 0)
        #expect(s.edit(for: "ge-0/0/2") == nil)
    }

    @Test func discardClearsEverything() throws {
        let s = try session()
        s.stage(PortEdit(port: "ge-0/0/24", enabled: false))
        s.stage(.add(name: "lab", vlanID: 200, description: nil))
        #expect(s.pendingChangeCount == 2)
        s.discardStaged()
        #expect(s.pendingChangeCount == 0)
    }

    @Test func offlinePendingOnlyOnOfflineSessions() throws {
        let s = try session()
        #expect(s.isOffline)
        let now = Date()
        s.setOfflinePending(.init(comment: "c", appliedAt: now, deadline: now.addingTimeInterval(300), summary: ["ge-0/0/2: x"]))
        #expect(s.pending?.deadline == now.addingTimeInterval(300))
        s.setOfflinePending(nil)
        #expect(s.pending == nil)
    }

    @Test func commitCommentUsesNoteOrSubjects() throws {
        let s = try session()
        s.stage(PortEdit(port: "ge-0/0/2", description: "SRV02-IDRAC"))
        #expect(DeviceSession.commitComment(for: s.plan, note: nil) == "Netdeck: ge-0/0/2")
        #expect(DeviceSession.commitComment(for: s.plan, note: "  iDRAC rename ") == "Netdeck: iDRAC rename")
    }

    @Test func aliasIconIsStoredAndOldProfilesStillDecode() throws {
        let s = try session()
        s.setAlias("Server 1 iDRAC", icon: "server.rack", for: "B0:7B:25:00:00:0B")
        #expect(s.alias(for: "b0:7b:25:00:00:0b") == "Server 1 iDRAC")
        #expect(s.aliasIcon(for: "b0:7b:25:00:00:0b") == "server.rack")
        let data = try JSONEncoder().encode(s.profile)
        let back = try JSONDecoder().decode(DeviceProfile.self, from: data)
        #expect(back.aliasIcons["b0:7b:25:00:00:0b"] == "server.rack")
        // A profile saved before icons existed has no "aliasIcons" key.
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["aliasIcons"] = nil
        let old = try JSONDecoder().decode(DeviceProfile.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.aliasIcons.isEmpty)
        #expect(old.aliases["b0:7b:25:00:00:0b"] == "Server 1 iDRAC")
    }
}
