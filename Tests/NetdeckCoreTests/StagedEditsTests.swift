import Foundation
import Testing
@testable import NetdeckCore

@MainActor
@Suite struct StagedEditsTests {
    private func tempStore() -> (StagedEditsStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("netdeck-staged-\(UUID().uuidString)", isDirectory: true)
        return (StagedEditsStore(directory: dir), dir)
    }

    private func snapshot() throws -> SwitchSnapshot {
        SwitchSnapshot(
            version: OutputParsers.version(try fixture("version")),
            hardware: OutputParsers.chassisHardware(try fixture("chassis-hardware")),
            config: SetConfigParser.parse(try fixture("config-set")),
            configText: try fixture("config-set"),
            statuses: OutputParsers.interfacesTerse(try fixture("interfaces-terse")),
            macTable: OutputParsers.macTable(try fixture("ethernet-switching-table")),
            lldp: [], commits: [], vcPorts: OutputParsers.vcPorts(try fixture("vc-port")))
    }

    private let profile = DeviceProfile(id: "test-sw/01", name: "sw-01", connection: .serial(path: "/dev/null", baud: 9600), username: "root")

    @Test func roundTripKeepsEveryKindOfEdit() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let edits = StagedEdits(
            ports: [PortEdit(port: "ge-0/0/2", description: "SRV02-IDRAC", enabled: true),
                    PortEdit(port: "ge-0/0/3", mode: .trunk, vlans: ["cust-01", "cust-02"], nativeVlanID: .some(10)),
                    PortEdit(port: "ge-0/0/4", nativeVlanID: .some(nil))],
            vlans: [.add(name: "lab", vlanID: 200, description: "Lab"), .update(name: "cust-01", vlanID: nil, description: "Customer 1"),
                    .rename(from: "cust-01-oob", to: "cust-01-ipmi"), .delete(name: "old")])
        try store.save(edits, deviceID: profile.id)
        let loaded = store.load(deviceID: profile.id)
        #expect(loaded == edits)
        // `.some(nil)` (remove the native VLAN) must not collapse into "unchanged".
        #expect(loaded.ports[2].nativeVlanID == .some(nil))
        #expect(loaded.ports[0].nativeVlanID == nil)
        // Nothing staged: the file goes away.
        try store.save(StagedEdits(), deviceID: profile.id)
        #expect(try !FileManager.default.fileExists(atPath: store.fileURL(deviceID: profile.id).path))
        #expect(store.load(deviceID: profile.id).isEmpty)
    }

    @Test func sessionSavesOnEveryChangeAndRestores() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snap = try snapshot()
        let first = DeviceSession(profile: profile, snapshot: snap, stagedStore: store)
        first.stage(PortEdit(port: "ge-0/0/2", description: "SRV02-IDRAC"))
        first.stage(PortEdit(port: "ge-0/0/24", enabled: false))
        first.stage(.add(name: "lab", vlanID: 200, description: nil))
        #expect(store.load(deviceID: profile.id).ports.count == 2)
        first.unstage(port: "ge-0/0/24")
        #expect(store.load(deviceID: profile.id).ports.map(\.port) == ["ge-0/0/2"])

        // A new session for the same device (next launch) brings them back.
        let second = DeviceSession(profile: profile, snapshot: snap, stagedStore: store)
        #expect(second.edit(for: "ge-0/0/2")?.description == "SRV02-IDRAC")
        #expect(second.vlanEdits == [.add(name: "lab", vlanID: 200, description: nil)])
        #expect(second.pendingChangeCount == 2)

        // Without a snapshot yet (not read since launch) the badge counts the stored edits.
        let unread = DeviceSession(profile: profile, snapshot: snap, stagedStore: store)
        unread.setOfflineSnapshot(nil)
        #expect(unread.snapshot == nil)
        #expect(unread.stagedCount == 2)

        second.discardStaged()
        #expect(store.load(deviceID: profile.id).isEmpty)
        // The sample switch and previews keep nothing on disk.
        let sample = DeviceSession(profile: profile, snapshot: snap)
        sample.stage(PortEdit(port: "ge-0/0/2", description: "X"))
        #expect(store.load(deviceID: profile.id).isEmpty)
    }

    @Test func restoredEditsThatAreAlreadyLiveAreDropped() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // ge-0/0/2 already carries this description on the switch: nothing left to apply.
        try store.save(StagedEdits(ports: [PortEdit(port: "ge-0/0/2", description: "R640-PVE-01")]), deviceID: profile.id)
        let s = DeviceSession(profile: profile, snapshot: try snapshot(), stagedStore: store)
        #expect(s.pendingChangeCount == 0)
        #expect(store.load(deviceID: profile.id).isEmpty)
    }

    @Test func expiredTimerEndsTheTrialLocally() throws {
        let s = DeviceSession(profile: profile, snapshot: try snapshot())
        let now = Date()
        s.setOfflinePending(.init(comment: "c", appliedAt: now, deadline: now.addingTimeInterval(300), summary: ["ge-0/0/2: x"]))
        #expect(!s.expireTrial(now: now.addingTimeInterval(200)))
        #expect(s.pending != nil)
        #expect(s.expireTrial(now: now.addingTimeInterval(306)))
        #expect(s.pending == nil)
        #expect(s.trialEnd == .timedOut(deadline: now.addingTimeInterval(300), restaged: 0))
        s.clearTrialEnd()
        #expect(s.trialEnd == nil)
    }

    @Test func dacNameFromChassisHardware() throws {
        let hw = OutputParsers.chassisHardware(try fixture("chassis-hardware"))
        #expect(hw.transceivers.map(\.shortName) == ["25G DAC", "25G DAC"])
        let juniper = HardwareInfo.Transceiver(fpc: 0, pic: 2, port: 0, partNumber: "740-030076", serial: "X", description: "SFP+-10G-CU1M")
        #expect(juniper.shortName == "Juniper 10G DAC")
        let unknown = HardwareInfo.Transceiver(fpc: 0, pic: 2, port: 0, partNumber: "NON-JNPR", serial: "X", description: "UNKNOWN")
        #expect(unknown.shortName == nil)
    }
}
