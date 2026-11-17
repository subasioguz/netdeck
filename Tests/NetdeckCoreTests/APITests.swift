import Foundation
import Testing
@testable import NetdeckCore

/// Synthetic API answers (see Fixtures/synthetic/api/README.md), one HTTP body per file.
func apiFixture(_ name: String) throws -> APIJSON {
    L10n.language = .en
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/synthetic/api"))
    let json = APIJSON(data: try Data(contentsOf: url))
    try #require(json.exists)
    return json
}

func apiJSON(_ text: String) -> APIJSON { APIJSON(data: Data(text.utf8)) }

private typealias APIFact = ApplianceSnapshot.Fact
private typealias APISensor = ApplianceSnapshot.Sensor
private typealias APIComponent = ApplianceSnapshot.Component
private typealias APIPool = ApplianceSnapshot.StoragePool
private typealias APIDisk = ApplianceSnapshot.Disk
private typealias APINetInterface = ApplianceSnapshot.NetInterface

/// 2026-11-17 12:00 UTC, the "now" of the fixtures.
let apiFixtureNow = Date(timeIntervalSince1970: 1_794_916_800)

// MARK: - Redfish (Dell iDRAC)

@Suite struct RedfishParserTests {
    func fullReading() throws -> RedfishParsers.Reading {
        var r = RedfishParsers.Reading(system: try apiFixture("redfish-system"))
        r.manager = try apiFixture("redfish-manager")
        r.thermal = try apiFixture("redfish-thermal")
        r.power = try apiFixture("redfish-power")
        r.ethernet = try apiFixture("redfish-ethernet-members").array
        r.managerNIC = try apiFixture("redfish-manager-nic")
        r.controllers = try apiFixture("redfish-storage-members").array
        r.drives = try apiFixture("redfish-drive-members").array
        r.volumes = try apiFixture("redfish-volume-members").array
        r.sel = try apiFixture("redfish-sel")
        return r
    }

    @Test func serviceRoots() throws {
        let dell = try apiFixture("redfish-root-dell")
        #expect(RedfishParsers.isRedfish(dell))
        #expect(RedfishParsers.isDell(root: dell) == true)
        #expect(RedfishParsers.sessionsPath(root: dell) == "/redfish/v1/SessionService/Sessions")

        let hpe = try apiFixture("redfish-root-hpe")
        #expect(RedfishParsers.isRedfish(hpe))
        #expect(RedfishParsers.isDell(root: hpe) == false)

        let legacy = try apiFixture("redfish-root-legacy")
        #expect(RedfishParsers.isDell(root: legacy) == nil)
        #expect(RedfishParsers.sessionsPath(root: legacy) == "/redfish/v1/Sessions")

        #expect(!RedfishParsers.isRedfish(try apiFixture("synology-query")))
    }

    @Test func iDRAC9SystemAndManager() throws {
        let s = RedfishParsers.snapshot(try fullReading(), now: apiFixtureNow)
        #expect(s.platform == .dellIDRAC)
        #expect(s.kind == .server)
        #expect(s.model == "PowerEdge R740")
        // Service Tag from Oem.Dell.DellSystem, not the board serial in SerialNumber.
        #expect(s.serial == "TEST001")
        #expect(s.hostname == "pve-01")
        #expect(s.power == .on)
        // HealthRollup, not just the system's own Health.
        #expect(s.health == .warning)
        #expect(s.osVersion == "iDRAC 7.00.00.172")
        #expect(s.uptimeSeconds == nil)
        #expect(s.facts == [APIFact(label: "Processors", value: "2× Intel Xeon Silver 4214"),
                            APIFact(label: "Memory", value: "192 GB"),
                            APIFact(label: "Power draw", value: "182 W")])
        #expect(s.firmware == [APIFact(label: "BIOS", value: "2.19.1"), APIFact(label: "iDRAC", value: "7.00.00.172")])
        #expect(s.worstHealth == .critical)
    }

    @Test func iDRAC9Sensors() throws {
        let s = RedfishParsers.snapshot(try fullReading(), now: apiFixtureNow)
        let temps = s.sensors.filter { $0.kind == .temperature }
        let fans = s.sensors.filter { $0.kind == .fan }
        #expect(temps.map(\.name) == ["CPU1 Temp", "CPU2 Temp", "System Board Inlet Temp", "System Board Exhaust Temp"])
        #expect(temps.first == APISensor(name: "CPU1 Temp", kind: .temperature, reading: 48, unit: "°C", health: .ok))
        // The absent Fan6A is left out.
        #expect(fans.count == 3)
        #expect(fans.first == APISensor(name: "System Board Fan1A", kind: .fan, reading: 6840, unit: "RPM", health: .ok))
    }

    @Test func iDRAC9PowerAndControllers() throws {
        let s = RedfishParsers.snapshot(try fullReading(), now: apiFixtureNow)
        #expect(s.components.map(\.name) == ["PS1 Status", "PS2 Status", "PERC H730P Mini", "CPU.1"])
        #expect(s.components[0] == APIComponent(name: "PS1 Status", detail: "750 W · 182 W now", health: .ok))
        #expect(s.components[1] == APIComponent(name: "PS2 Status", detail: "750 W · no input", health: .critical))
        #expect(s.components[2] == APIComponent(name: "PERC H730P Mini", detail: "Firmware 25.5.9.0001", health: .ok))
        #expect(s.components[3].health == .ok)
    }

    @Test func iDRAC9Storage() throws {
        let s = RedfishParsers.snapshot(try fullReading(), now: apiFixtureNow)
        #expect(s.pools == [APIPool(name: "Virtual Disk 0", status: "Online", health: .ok, sizeBytes: 479_559_942_144,
                                  usedBytes: nil, layout: "RAID 1")])
        #expect(s.disks.count == 3)
        #expect(s.disks[0] == APIDisk(name: "Physical Disk 0:1:0", model: "MZ7KH480HAHQ0D3", serial: "TEST0000011",
                                    sizeBytes: 479_559_942_144, type: "SSD", health: .ok, pool: "Virtual Disk 0"))
        #expect(s.disks[1].health == .warning)
        #expect(s.disks[2].type == "NVMe")
        #expect(s.disks[2].pool == nil)
        #expect(s.disks[2].sizeBytes == 1_600_321_314_816)
    }

    @Test func iDRAC9Network() throws {
        let s = RedfishParsers.snapshot(try fullReading(), now: apiFixtureNow)
        #expect(s.interfaces.map(\.name) == ["iDRAC", "NIC.Integrated.1-1-1", "NIC.Integrated.1-2-1"])
        #expect(s.interfaces[0] == APINetInterface(name: "iDRAC", mac: "d0:94:66:00:00:01", linkUp: true, speedMbps: 1000, addresses: ["192.0.2.10/24"]))
        #expect(s.interfaces[1] == APINetInterface(name: "NIC.Integrated.1-1-1", mac: "B0:7B:25:00:00:21", linkUp: true, speedMbps: 10_000))
        #expect(s.interfaces[2].linkUp == false)
        #expect(s.interfaces[2].speedMbps == nil)
    }

    @Test func iDRAC9Alerts() throws {
        let s = RedfishParsers.snapshot(try fullReading(), now: apiFixtureNow)
        // Rollups first, then the event log newest first, one line per message, last 30 days only.
        #expect(s.alerts.count == 4)
        #expect(s.alerts.first == "Power supplies: warning")
        #expect(s.alerts[1].hasSuffix(" · The power input for power supply 2 is lost."))
        #expect(s.alerts[2].hasSuffix(" · Power supply redundancy is lost."))
        #expect(s.alerts[3].contains("predicted to fail"))
        #expect(!s.alerts.contains { $0.contains("Fan 3") })
        #expect(!s.alerts.contains { $0.contains("within range") })
    }

    @Test func iDRAC8ServiceTagFromSKU() throws {
        var r = RedfishParsers.Reading(system: try apiFixture("redfish-system-idrac8"))
        r.thermal = try apiFixture("redfish-thermal-idrac8")
        let s = RedfishParsers.snapshot(r, now: apiFixtureNow)
        #expect(s.serial == "TEST002")
        #expect(s.power == .off)
        #expect(s.health == .ok)
        #expect(s.hostname == nil)
        #expect(s.osVersion == nil)
        // Dell's "GiB" that are really GB / 1.073741824 read as 64 GB.
        #expect(s.facts == [APIFact(label: "Processors", value: "1× Intel Xeon CPU E5-2620 v4"),
                            APIFact(label: "Memory", value: "64 GB")])
        // iDRAC 8 names fans only by FanName.
        #expect(s.sensors.map(\.name) == ["System Board Inlet Temp", "System Board Fan1", "System Board Fan2"])
        #expect(s.sensors.last?.health == .critical)
        #expect(s.alerts.isEmpty)
    }

    @Test func thermalSubsystemFallback() {
        let fans = [apiJSON(#"{"Name": "Fan 1", "SpeedPercent": {"Reading": 42, "SpeedRPM": 7200}, "Status": {"Health": "OK", "State": "Enabled"}}"#),
                    apiJSON(#"{"Name": "Fan 2", "SpeedPercent": {"Reading": 40}, "Status": {"Health": "OK", "State": "Enabled"}}"#)]
        let metrics = apiJSON(#"{"TemperatureReadingsCelsius": [{"DeviceName": "CPU1 Temp", "Reading": 45}]}"#)
        #expect(RedfishParsers.sensors(fans: fans, metrics: metrics) == [
            APISensor(name: "CPU1 Temp", kind: .temperature, reading: 45, unit: "°C", health: .unknown),
            APISensor(name: "Fan 1", kind: .fan, reading: 7200, unit: "RPM", health: .ok),
            APISensor(name: "Fan 2", kind: .fan, reading: 40, unit: "%", health: .ok),
        ])
    }

    @Test func powerSubsystemFallback() {
        L10n.language = .en
        let psu = apiJSON(#"{"Name": "PSU 2", "PowerCapacityWatts": 1100, "LineInputStatus": "LossOfInput", "Status": {"Health": "Critical", "State": "Enabled"}}"#)
        #expect(RedfishParsers.subsystemPowerSupply(psu) == APIComponent(name: "PSU 2", detail: "1100 W · no input", health: .critical))
    }

    @Test func powerStatesAndMemory() {
        #expect(RedfishParsers.powerState("On") == .on)
        #expect(RedfishParsers.powerState("PoweringOff") == .off)
        #expect(RedfishParsers.powerState(nil) == .unknown)
        #expect(RedfishParsers.memoryGiB(192) == 192)
        #expect(RedfishParsers.memoryGiB(238.4185791015625) == 256)
        #expect(RedfishParsers.raidLayout("RAID10") == "RAID 10")
        #expect(RedfishParsers.raidLayout("Mirrored") == "Mirrored")
    }

    @Test func eventLogPaging() throws {
        let oldestFirst = apiJSON(#"{"Members@odata.count": 120, "Members": [{"Created": "2026-01-01T00:00:00Z"}, {"Created": "2026-02-01T00:00:00Z"}]}"#)
        #expect(RedfishParsers.selSkipToNewest(oldestFirst) == 118)
        let newestFirst = apiJSON(#"{"Members@odata.count": 120, "Members": [{"Created": "2026-02-01T00:00:00Z"}, {"Created": "2026-01-01T00:00:00Z"}]}"#)
        #expect(RedfishParsers.selSkipToNewest(newestFirst) == nil)
        #expect(RedfishParsers.selSkipToNewest(try apiFixture("redfish-sel")) == nil)
    }
    @Test func iDRAC9PowerActions() throws {
        let s = RedfishParsers.snapshot(try fullReading(), now: apiFixtureNow)
        // Nmi and PushPowerButton are left out; menu order, not the BMC's.
        #expect(s.powerActions == [.on, .gracefulShutdown, .gracefulRestart, .forceRestart, .forceOff, .powerCycle])
        #expect(RedfishParsers.resetTarget(try apiFixture("redfish-system")) == "/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset")
        // iDRAC 8 fixture lists no Reset action: nothing to offer.
        #expect(RedfishParsers.powerActions(try apiFixture("redfish-system-idrac8")).isEmpty)
    }

    @Test func powerActionLists() {
        let target = #""target": "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset""#
        // A target without a list: the four every service supports.
        #expect(RedfishParsers.powerActions(apiJSON(##"{"Actions": {"#ComputerSystem.Reset": {\##(target)}}}"##))
                == [.on, .gracefulShutdown, .gracefulRestart, .forceOff])
        #expect(RedfishParsers.powerActions(apiJSON(##"{"Actions": {"#ComputerSystem.Reset": {\##(target), "ResetType@Redfish.AllowableValues": ["Nmi"]}}}"##)).isEmpty)
        #expect(RedfishParsers.powerActions(apiJSON(##"{"Actions": {"#ComputerSystem.Reset": {\##(target), "ResetType@Redfish.AllowableValues": ["ForceOff", "On"]}}}"##))
                == [.on, .forceOff])
        // No target, no commands, whatever is listed.
        #expect(RedfishParsers.powerActions(apiJSON(##"{"Actions": {"#ComputerSystem.Reset": {"ResetType@Redfish.AllowableValues": ["On"]}}}"##)).isEmpty)
        #expect(RedfishParsers.powerActions(apiJSON("{}")).isEmpty)
    }
}

// MARK: - Redfish (other vendors)

@Suite struct RedfishGenericTests {
    func hpeReading() throws -> RedfishParsers.Reading {
        var r = RedfishParsers.Reading(system: try apiFixture("redfish-hpe-system"))
        r.isDell = false
        r.manager = try apiFixture("redfish-hpe-manager")
        r.thermal = try apiFixture("redfish-hpe-thermal")
        r.power = try apiFixture("redfish-hpe-power")
        r.ethernet = try apiFixture("redfish-hpe-ethernet-members").array
        r.managerNIC = try apiFixture("redfish-hpe-manager-nic")
        r.sel = try apiFixture("redfish-hpe-iml")
        return r
    }

    @Test func resourcePaths() throws {
        let hpe = try apiFixture("redfish-hpe-system")
        #expect(RedfishParsers.managerLink(hpe).map(RedfishParsers.trimmed) == "/redfish/v1/Managers/1")
        #expect(RedfishParsers.chassisLink(hpe).map(RedfishParsers.trimmed) == "/redfish/v1/Chassis/1")
        #expect(RedfishParsers.trimmed("/redfish/v1/Systems/1/") == "/redfish/v1/Systems/1")
        #expect(RedfishParsers.trimmed("/") == "/")
        let root = try apiFixture("redfish-root-hpe")
        #expect(RedfishParsers.collectionPath(root, "Systems") == "/redfish/v1/Systems/")
        #expect(RedfishParsers.collectionPath(root, "Managers") == "/redfish/v1/Managers")
        // A Dell system without links falls back to the collections (the client's job): none here.
        #expect(RedfishParsers.managerLink(try apiFixture("redfish-system-idrac8")) == nil)
    }

    @Test func hpeILO5System() throws {
        let s = RedfishParsers.snapshot(try hpeReading(), now: apiFixtureNow)
        #expect(s.platform == .redfish)
        #expect(s.kind == .server)
        #expect(s.model == "HPE ProLiant DL360 Gen10")
        #expect(s.serial == "TEST0000003")
        #expect(s.hostname == "esx-01")
        #expect(s.power == .on)
        #expect(s.health == .ok)
        // The product name in front of the firmware version is not repeated.
        #expect(s.osVersion == "iLO 5 2.72")
        #expect(s.firmware == [APIFact(label: "BIOS", value: "U32 v2.68 (07/14/2022)"), APIFact(label: "iLO 5", value: "2.72")])
        #expect(s.facts.map(\.label) == ["Processors", "Memory", "Power draw"])
        #expect(s.facts.last?.value == "214 W")
        #expect(s.powerActions == [.on, .gracefulShutdown, .gracefulRestart, .forceRestart, .forceOff])
        // The vendor is in the model, not printed twice.
        #expect(s.detection.summary == "HPE ProLiant DL360 Gen10 · iLO 5 2.72")
        #expect(s.detection.osLine == "iLO 5 2.72")
    }

    @Test func hpeILO5SensorsAndPower() throws {
        let s = RedfishParsers.snapshot(try hpeReading(), now: apiFixtureNow)
        #expect(s.sensors.filter { $0.kind == .temperature }.map(\.name) == ["01-Inlet Ambient", "02-CPU 1", "03-CPU 2"])
        #expect(s.sensors.filter { $0.kind == .fan } == [APISensor(name: "Fan 1", kind: .fan, reading: 23, unit: "%", health: .ok),
                                                         APISensor(name: "Fan 2", kind: .fan, reading: 25, unit: "%", health: .ok)])
        #expect(s.components == [APIComponent(name: "Power Supply 1", detail: "500 W · 107 W now", health: .ok),
                                 APIComponent(name: "Power Supply 2", detail: "500 W · 107 W now", health: .ok)])
        #expect(s.worstHealth == .ok)
    }

    @Test func hpeILO5NetworkAndLog() throws {
        let s = RedfishParsers.snapshot(try hpeReading(), now: apiFixtureNow)
        // The iLO's own port first, named after the BMC.
        #expect(s.interfaces.map(\.name) == ["iLO 5", "1", "2"])
        #expect(s.interfaces[0] == APINetInterface(name: "iLO 5", mac: "94:40:c9:00:00:10", linkUp: true, speedMbps: 1000, addresses: ["192.0.2.40/24"]))
        #expect(s.interfaces[2].linkUp == false)
        #expect(s.interfaces[2].speedMbps == nil)
        // IML: the recent warning only; the critical entry is older than 30 days and OK entries are not alerts.
        #expect(s.alerts.count == 1)
        #expect(s.alerts.first?.hasSuffix(" · Network Adapter Link Down (Slot 0, Port 2)") == true)
    }

    @Test func supermicroSystem() throws {
        var r = RedfishParsers.Reading(system: try apiFixture("redfish-supermicro-system"))
        r.isDell = false
        r.manager = apiJSON(#"{"@odata.id": "/redfish/v1/Managers/1", "FirmwareVersion": "01.73.12", "Model": ""}"#)
        let s = RedfishParsers.snapshot(r, now: apiFixtureNow)
        #expect(s.platform == .redfish)
        #expect(s.model == "Supermicro SYS-1029P-WTR")
        // A blank SerialNumber falls back to SKU.
        #expect(s.serial == "TEST0000005")
        #expect(s.hostname == nil)
        #expect(s.power == .off)
        // No manager model: plain "BMC".
        #expect(s.osVersion == "BMC 01.73.12")
        #expect(s.firmware.last == APIFact(label: "BMC", value: "01.73.12"))
        // Reset types only behind an ActionInfo link: the four every service supports.
        #expect(s.powerActions == [.on, .gracefulShutdown, .gracefulRestart, .forceOff])
        #expect(s.facts.first == APIFact(label: "Processors", value: "1× Intel Xeon Silver 4210"))
    }

    @Test func vendorAndModelNames() {
        #expect(RedfishParsers.vendorModel(apiJSON(#"{"Manufacturer": "Lenovo", "Model": "ThinkSystem SR650"}"#)) == "Lenovo ThinkSystem SR650")
        #expect(RedfishParsers.vendorModel(apiJSON(#"{"Manufacturer": "Supermicro", "Model": "Supermicro X11DPi-NT"}"#)) == "Supermicro X11DPi-NT")
        #expect(RedfishParsers.vendorModel(apiJSON(#"{"Model": "Super Server"}"#)) == "Super Server")
        #expect(RedfishParsers.bmcVersion(apiJSON(#"{"FirmwareVersion": "7.00.00.172"}"#), name: "iDRAC") == "7.00.00.172")
        #expect(RedfishParsers.bmcVersion(apiJSON(#"{"FirmwareVersion": "v1.10"}"#), name: "BMC") == "1.10")
        #expect(RedfishParsers.bmcName(apiJSON(#"{"Model": "XClarity Controller"}"#)) == "XClarity Controller")
    }

    @Test func platformNaming() {
        #expect(Platform.redfish.kinds == [.server])
        #expect(Platform.redfish.connections == [.api])
        #expect(Platform.redfish.isAppliance)
        #expect(Platform.redfish.changeTraits == .readOnly)
        #expect(!Platform.redfish.namesVendor && !Platform.unknown.namesVendor && Platform.dellIDRAC.namesVendor)
        #expect(DriverFactory.supports(.redfish, over: .api))
        #expect(!DriverFactory.supports(.redfish, over: .ssh))
        // Without a model the summary falls back to the platform name, never "Redfish" alone.
        #expect(Detection(platform: .redfish, osVersion: "iLO 5 2.72").summary == "Redfish BMC · iLO 5 2.72")
        #expect(Detection(platform: .dellIDRAC, model: "PowerEdge R740", osVersion: "iDRAC 7.00.00.172").summary
                == "Dell PowerEdge R740 · iDRAC 7.00.00.172")
    }
}

// MARK: - Synology DSM

@Suite struct SynologyParserTests {
    func reading() throws -> SynologyParsers.Reading {
        var r = SynologyParsers.Reading()
        r.info = try apiFixture("synology-dsm-info")["data"]
        r.system = try apiFixture("synology-core-system")["data"]
        r.storage = try apiFixture("synology-storage")["data"]
        r.network = try apiFixture("synology-network")["data"]
        return r
    }

    @Test func discovery() throws {
        let query = try apiFixture("synology-query")
        #expect(SynologyParsers.isSynology(query))
        #expect(!SynologyParsers.isSynology(try apiFixture("redfish-root-dell")))
        let apis = SynologyParsers.apis(query["data"])
        #expect(apis["SYNO.API.Auth"] == SynologyParsers.API(path: "entry.cgi", minVersion: 1, maxVersion: 7))
        #expect(apis["SYNO.API.Auth"]?.version(7) == 7)
        #expect(apis["SYNO.DSM.Info"]?.version() == 2)
        #expect(apis["SYNO.Storage.CGI.Storage"]?.version(3) == 1)
    }

    @Test func loginErrors() throws {
        let answer = try apiFixture("synology-login-2fa")
        #expect(answer["success"].bool == false)
        #expect(SynologyParsers.loginError(code: answer["error"]["code"].int) == .twoFactorRequired)
        #expect(SynologyParsers.loginError(code: 400) == .unauthorized)
        #expect(SynologyParsers.loginError(code: 402) == .unauthorized)
        #expect(SynologyParsers.loginError(code: 406) == .twoFactorRequired)
        #expect(SynologyParsers.loginError(code: 407) == .blocked)
        #expect(SynologyParsers.loginError(code: 410) == .passwordChangeRequired)
    }

    @Test func systemInfo() throws {
        let s = SynologyParsers.snapshot(try reading(), now: apiFixtureNow)
        #expect(s.platform == .synologyDSM)
        #expect(s.kind == .storage)
        #expect(s.power == .on)
        #expect(s.model == "DS920+")
        #expect(s.serial == "TEST0000002")
        #expect(s.osVersion == "DSM 7.2.1-69057 Update 5")
        #expect(s.uptimeSeconds == 1_036_800)
        #expect(s.hostname == "nas-01")
        #expect(s.facts == [APIFact(label: "Processor", value: "Intel Celeron J4125 · 4 cores"),
                            APIFact(label: "Memory", value: "4 GB"),
                            APIFact(label: "Temperature", value: "41 °C")])
    }

    @Test func volumesAndDisks() throws {
        let s = SynologyParsers.snapshot(try reading(), now: apiFixtureNow)
        #expect(s.pools == [
            APIPool(name: "Volume 1", status: "normal", health: .ok, sizeBytes: 3_830_251_552_768, usedBytes: 2_104_119_017_472, layout: "SHR"),
            // The volume says "normal", its storage pool is degraded.
            APIPool(name: "Volume 2", status: "degraded", health: .warning, sizeBytes: 3_830_251_552_768, usedBytes: 958_062_575_616, layout: "RAID 1"),
        ])
        #expect(s.disks.map(\.name) == ["Drive 1", "Drive 2", "Drive 3", "Drive 4", "M.2 Drive 1"])
        #expect(s.disks[0] == APIDisk(name: "Drive 1", model: "ST4000VN008-2DR166", serial: "TEST0000021", sizeBytes: 4_000_787_030_016,
                                    type: "HDD", health: .ok, temperature: 34, pool: "Volume 1"))
        #expect(s.disks[3].health == .critical)
        #expect(s.disks[3].pool == "Volume 2")
        #expect(s.disks[4].type == "NVMe")
        #expect(s.disks[4].pool == nil)
        #expect(s.disks[4].temperature == nil)
        #expect(s.alerts == ["Drive 4 status: crashed", "Volume 2 status: degraded"])
        #expect(s.health == .critical)
    }

    @Test func network() throws {
        let s = SynologyParsers.snapshot(try reading(), now: apiFixtureNow)
        #expect(s.interfaces == [APINetInterface(name: "eth0", mac: "00:11:32:00:00:01", addresses: ["192.0.2.20/24"]),
                                 APINetInterface(name: "eth1", mac: "00:11:32:00:00:02")])
    }

    @Test func storageNeedsAdministrator() throws {
        let denied = try apiFixture("synology-storage-denied")
        #expect(denied["error"]["code"].int == 105)
        var r = SynologyParsers.Reading()
        r.info = try apiFixture("synology-dsm-info")["data"]
        r.storageDenied = true
        let s = SynologyParsers.snapshot(r, now: apiFixtureNow)
        #expect(s.model == "DS920+")
        #expect(s.pools.isEmpty)
        #expect(s.facts.map(\.label) == ["Memory", "Temperature"])
        #expect(s.alerts == ["This account can't read storage information. Use an administrator account to see volumes and disks."])
        #expect(s.health == .unknown)
    }

    @Test func helpers() {
        #expect(SynologyParsers.uptime("288:0:0") == 1_036_800)
        #expect(SynologyParsers.uptime("1:02:03:04") == 93_784)
        #expect(SynologyParsers.uptime("soon") == nil)
        #expect(SynologyParsers.layout("shr_without_disk_protect") == "SHR")
        #expect(SynologyParsers.layout("shr_2") == "SHR-2")
        #expect(SynologyParsers.layout("raid_5") == "RAID 5")
        #expect(SynologyParsers.layout("raid_f1") == "RAID F1")
        #expect(SynologyParsers.osVersion("7.2.1-69057") == "DSM 7.2.1-69057")
        #expect(SynologyParsers.health("crashed") == .critical)
        #expect(SynologyParsers.health("background") == .unknown)
    }
}

// MARK: - TrueNAS

@Suite struct TrueNASParserTests {
    @Test func apiKeyDetection() {
        #expect(TrueNASParsers.looksLikeAPIKey("1-" + String(repeating: "aB3", count: 22)))
        #expect(TrueNASParsers.looksLikeAPIKey("12-" + String(repeating: "x", count: 64)))
        #expect(!TrueNASParsers.looksLikeAPIKey("correct horse battery staple"))
        #expect(!TrueNASParsers.looksLikeAPIKey("12-short"))
        #expect(!TrueNASParsers.looksLikeAPIKey("x-" + String(repeating: "a", count: 64)))
        #expect(!TrueNASParsers.looksLikeAPIKey("1-" + String(repeating: "a", count: 63) + "!"))
    }

    @Test func versions() {
        #expect(TrueNASParsers.osVersion("TrueNAS-SCALE-24.10.2") == "TrueNAS SCALE 24.10.2")
        #expect(TrueNASParsers.osVersion("TrueNAS-13.0-U6.1") == "TrueNAS 13.0-U6.1")
        #expect(TrueNASParsers.osVersion("25.04.2.1") == "TrueNAS 25.04.2.1")
        #expect(TrueNASParsers.osVersion("TrueNAS-25.10.0") == "TrueNAS 25.10.0")
        #expect(TrueNASParsers.isSystemState(apiJSON(#""READY""#)))
        #expect(!TrueNASParsers.isSystemState(apiJSON("{}")))
    }

    @Test func scaleSnapshot() throws {
        var r = TrueNASParsers.Reading(info: try apiFixture("truenas-system-info-scale"))
        r.pools = try apiFixture("truenas-pool-scale")
        r.disks = try apiFixture("truenas-disk")
        r.interfaces = try apiFixture("truenas-interface")
        r.alerts = try apiFixture("truenas-alert-list")
        let s = TrueNASParsers.snapshot(r, now: apiFixtureNow)
        #expect(s.platform == .truenas)
        #expect(s.kind == .storage)
        #expect(s.hostname == "truenas")
        // system_product is the hardware; `model` is the CPU.
        #expect(s.model == "X570D4U")
        #expect(s.serial == "TEST0000003")
        #expect(s.osVersion == "TrueNAS SCALE 24.10.2")
        #expect(s.uptimeSeconds == 1_051_200)
        #expect(s.facts == [APIFact(label: "Processor", value: "AMD Ryzen 5 PRO 4650G with Radeon Graphics · 12 cores"),
                            APIFact(label: "Memory", value: "63 GB ECC"),
                            APIFact(label: "Manufacturer", value: "ASRockRack")])
        #expect(s.pools == [
            APIPool(name: "tank", status: "ONLINE", health: .ok, sizeBytes: 11_991_548_690_432, usedBytes: 4_398_046_511_104, layout: "RAIDZ1"),
            APIPool(name: "fast", status: "DEGRADED", health: .warning, sizeBytes: 996_432_412_672, usedBytes: 214_748_364_800, layout: "MIRROR"),
        ])
        #expect(s.health == .critical)
    }

    @Test func scaleDisks() throws {
        var r = TrueNASParsers.Reading(info: try apiFixture("truenas-system-info-scale"))
        r.pools = try apiFixture("truenas-pool-scale")
        r.disks = try apiFixture("truenas-disk")
        let s = TrueNASParsers.snapshot(r, now: apiFixtureNow)
        #expect(s.disks.map(\.name) == ["sda", "sdb", "sdc", "nvme0n1", "nvme1n1", "sdd"])
        #expect(s.disks[0] == APIDisk(name: "sda", model: "WDC WD40EFZX-68AWUN0", serial: "TEST0000031", sizeBytes: 4_000_787_030_016,
                                    type: "HDD", health: .ok, pool: "tank"))
        // Checksum errors on an ONLINE member.
        #expect(s.disks[2].health == .warning)
        #expect(s.disks[4].health == .critical)
        #expect(s.disks[4].pool == "fast")
        #expect(s.disks[4].type == "NVMe")
        // Not in a data pool's topology; the disk entry names its pool itself.
        #expect(s.disks[5].pool == "boot-pool")
        #expect(s.disks[5].health == .unknown)
    }

    @Test func scaleInterfacesAndAlerts() throws {
        var r = TrueNASParsers.Reading(info: try apiFixture("truenas-system-info-scale"))
        r.interfaces = try apiFixture("truenas-interface")
        r.alerts = try apiFixture("truenas-alert-list")
        let s = TrueNASParsers.snapshot(r, now: apiFixtureNow)
        // The VLAN without an address is left out; the bridge carries the static address.
        #expect(s.interfaces.map(\.name) == ["enp5s0", "enp6s0", "br0"])
        #expect(s.interfaces[0] == APINetInterface(name: "enp5s0", mac: "a8:a1:59:00:00:01", linkUp: true, speedMbps: 1000, addresses: ["192.0.2.30/24"]))
        #expect(s.interfaces[1].linkUp == false)
        #expect(s.interfaces[1].addresses.isEmpty)
        #expect(s.interfaces[2].addresses == ["198.51.100.5/24"])
        // Newest first; dismissed and INFO alerts are left out; HTML is stripped.
        #expect(s.alerts == ["Device: /dev/sdc [SAT], 8 Currently unreadable (pending) sectors. See Disks.",
                             "Pool fast state is DEGRADED: One or more devices has been removed by the administrator."])
        #expect(s.health == .critical)
    }

    @Test func coreWithoutPoolSizes() throws {
        var r = TrueNASParsers.Reading(info: try apiFixture("truenas-system-info-core"))
        r.pools = try apiFixture("truenas-pool-core")
        let s = TrueNASParsers.snapshot(r, now: apiFixtureNow)
        #expect(s.osVersion == "TrueNAS 13.0-U6.1")
        #expect(s.model == "X11SSH-F")
        // Board filler text is not a serial.
        #expect(s.serial == nil)
        #expect(s.facts.first == APIFact(label: "Processor", value: "Intel Xeon CPU E3-1230 v6 · 8 cores"))
        #expect(s.facts.dropFirst().first == APIFact(label: "Memory", value: "32 GB ECC"))
        #expect(s.pools == [APIPool(name: "tank", status: "ONLINE", health: .ok, sizeBytes: nil, usedBytes: nil, layout: "2× MIRROR")])
        #expect(s.health == .ok)
    }

    @Test func linkSpeedFromMediaText() {
        #expect(TrueNASParsers.speed(apiJSON(#"{"active_media_subtype": "10Gbase-T <full-duplex>"}"#)) == 10_000)
        #expect(TrueNASParsers.speed(apiJSON(#"{"active_media_subtype": "1000baseT <full-duplex>"}"#)) == 1000)
        #expect(TrueNASParsers.speed(apiJSON(#"{"active_media_subtype": "2500Mb/s Twisted Pair"}"#)) == 2500)
        #expect(TrueNASParsers.speed(apiJSON(#"{"speed": 25000, "active_media_subtype": "Unknown"}"#)) == 25_000)
        #expect(TrueNASParsers.speed(apiJSON(#"{"active_media_subtype": "autoselect"}"#)) == nil)
    }

    @Test func poolHealth() {
        #expect(TrueNASParsers.poolHealth(status: "ONLINE", healthy: true) == .ok)
        #expect(TrueNASParsers.poolHealth(status: "ONLINE", healthy: false) == .warning)
        #expect(TrueNASParsers.poolHealth(status: "DEGRADED", healthy: false) == .warning)
        #expect(TrueNASParsers.poolHealth(status: "FAULTED", healthy: false) == .critical)
        #expect(TrueNASParsers.poolHealth(status: "UNAVAIL", healthy: nil) == .critical)
    }
}

// MARK: - Certificate pins, addresses, encoding

@Suite struct APIPinTests {
    func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("netdeck-pins-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func trustOnFirstUse() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = APIPins.fingerprint(of: Data("certificate one".utf8))
        let second = APIPins.fingerprint(of: Data("certificate two".utf8))

        #expect(APIPins.pinned(host: "192.0.2.10", port: 443, directory: dir) == nil)
        #expect(try APIPins.check(fingerprint: first, host: "192.0.2.10", port: 443, directory: dir) == .firstUse)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("api_pins.json").path))
        #expect(APIPins.pinned(host: "192.0.2.10", port: 443, directory: dir) == first)
        #expect(try APIPins.check(fingerprint: first.uppercased(), host: "192.0.2.10", port: 443, directory: dir) == .matched)

        #expect(throws: APIError.certificateChanged(host: "192.0.2.10")) {
            try APIPins.check(fingerprint: second, host: "192.0.2.10", port: 443, directory: dir)
        }
        // The refused certificate did not replace the stored one.
        #expect(APIPins.pinned(host: "192.0.2.10", port: 443, directory: dir) == first)

        // Another port is another service with its own certificate.
        #expect(try APIPins.check(fingerprint: second, host: "192.0.2.10", port: 5001, directory: dir) == .firstUse)

        APIPins.forget(host: "192.0.2.10", port: 443, directory: dir)
        #expect(APIPins.pinned(host: "192.0.2.10", port: 443, directory: dir) == nil)
        #expect(APIPins.pinned(host: "192.0.2.10", port: 5001, directory: dir) == second)
        #expect(try APIPins.check(fingerprint: second, host: "192.0.2.10", port: 443, directory: dir) == .firstUse)
    }

    @Test func forgetByProfileAddress() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try APIPins.check(fingerprint: "aa", host: "nas.example.com", port: 443, directory: dir)
        try APIPins.check(fingerprint: "bb", host: "nas.example.com", port: 5001, directory: dir)
        APIPins.forget(url: "nas.example.com", directory: dir)
        #expect(APIPins.pinned(host: "nas.example.com", port: 443, directory: dir) == nil)
        #expect(APIPins.pinned(host: "nas.example.com", port: 5001, directory: dir) == nil)
    }

    @Test func fingerprintAndKeys() {
        #expect(APIPins.fingerprint(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(APIPins.key(host: "NAS.Example.com", port: 5001) == "nas.example.com:5001")
        #expect(APIPins.key(host: "2001:db8::1", port: 443) == "[2001:db8::1]:443")
        #expect(APIPins.key(host: "[2001:db8::1]", port: 443) == "[2001:db8::1]:443")
    }
}

@Suite struct APIEndpointTests {
    @Test func onlyHTTPS() {
        #expect(throws: APIError.httpNotAllowed) { try APIEndpoint("http://192.0.2.10") }
        #expect(throws: APIError.httpNotAllowed) { try APIEndpoint("HTTP://nas.local:5000") }
        #expect(throws: APIError.invalidURL("")) { try APIEndpoint("  ") }
        #expect(throws: APIError.invalidURL("https://")) { try APIEndpoint(" https:// ") }
        #expect(throws: APIError.invalidURL("ftp://nas.local")) { try APIEndpoint("ftp://nas.local") }
    }

    @Test func missingSchemeMeansHTTPS() throws {
        let e = try APIEndpoint("192.0.2.10")
        #expect(e.host == "192.0.2.10")
        #expect(e.port == 443)
        #expect(!e.explicitPort)
        #expect(e.base == "https://192.0.2.10")
        #expect(e.url("/redfish/v1/")?.absoluteString == "https://192.0.2.10/redfish/v1/")

        let withPort = try APIEndpoint("192.0.2.10:8443")
        #expect(withPort.port == 8443)
        #expect(withPort.explicitPort)
        #expect(withPort.base == "https://192.0.2.10:8443")
    }

    @Test func portKeptPathDropped() throws {
        let e = try APIEndpoint("https://NAS.example.com:5001/webman/index.cgi")
        #expect(e.host == "nas.example.com")
        #expect(e.port == 5001)
        #expect(e.explicitPort)
        #expect(e.base == "https://nas.example.com:5001")
        #expect(e.url("/webapi/query.cgi?api=SYNO.API.Info")?.absoluteString == "https://nas.example.com:5001/webapi/query.cgi?api=SYNO.API.Info")
        // Links the device sends are re-based on the endpoint; fragments are dropped.
        #expect(e.url("https://198.51.100.9/redfish/v1/SessionService/Sessions/7")?.absoluteString
                == "https://nas.example.com:5001/redfish/v1/SessionService/Sessions/7")
        #expect(e.url("/redfish/v1/Chassis/System.Embedded.1/Power#/PowerSupplies/0")?.absoluteString
                == "https://nas.example.com:5001/redfish/v1/Chassis/System.Embedded.1/Power")
        #expect(e.webSocketURL("/api/current")?.absoluteString == "wss://nas.example.com:5001/api/current")
    }

    @Test func encoding() {
        #expect(APIHTTP.form([("account", "admin"), ("passwd", "p&ss=w+rd ü")]) == "account=admin&passwd=p%26ss%3Dw%2Brd%20%C3%BC")
        #expect(APIHTTP.basicAuth("root", "secret") == "Basic cm9vdDpzZWNyZXQ=")
    }

    @Test func jsonHelpers() {
        let j = apiJSON(#"{"size": "4000787030016", "n": 3.5, "flag": true, "zero": 0, "empty": "  ", "list": [1, 2]}"#)
        #expect(j["size"].int64 == 4_000_787_030_016)
        #expect(j["n"].double == 3.5)
        #expect(j["n"].text == "3.5")
        #expect(j["flag"].bool == true)
        #expect(j["flag"].int == nil)
        #expect(j["zero"].bool == false)
        #expect(j["empty"].string == nil)
        #expect(j["list"].array.count == 2)
        #expect(j["missing"]["deeper"][3].exists == false)
        #expect(APIFormat.cpuName("Intel(R) Xeon(R) Silver 4214 CPU @ 2.20GHz") == "Intel Xeon Silver 4214")
        #expect(APIFormat.memory(gib: 0.5) == "512 MB")
        #expect(APIFormat.memory(gib: 7.5) == "7.5 GB")
        #expect(APIFormat.address("192.0.2.1", mask: "255.255.254.0") == "192.0.2.1/23")
    }

    @Test func errorTexts() {
        L10n.language = .en
        #expect(APIError.http(503).errorDescription == "The device answered with HTTP error 503.")
        #expect(APIError.unauthorized.errorDescription == "Wrong username or password.")
        #expect(APIError.certificateChanged(host: "192.0.2.10").errorDescription?.contains("192.0.2.10") == true)
    }
}
