import Foundation
import Testing
@testable import NetdeckCore

/// Synthetic QNAP answers (see Fixtures/synthetic/api/README.md).
func qnapFixture(_ name: String) throws -> XMLElement {
    L10n.language = .en
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures/synthetic/api"))
    return try #require(QNAPParsers.root(try Data(contentsOf: url)))
}

@Suite struct QNAPParserTests {
    init() { L10n.language = .en }

    func reading() throws -> QNAPParsers.Reading {
        var r = QNAPParsers.Reading()
        r.login = try qnapFixture("qnap-login")
        r.sysinfo = try qnapFixture("qnap-sysinfo")
        r.health = try qnapFixture("qnap-health")
        r.volumes = try qnapFixture("qnap-volumes")
        r.disks = try qnapFixture("qnap-disks")
        return r
    }

    @Test func recognisedAndLoggedIn() throws {
        // `authLogin.cgi` answers without a login with a <QDocRoot>; anything else isn't QNAP.
        #expect(QNAPParsers.root(Data("<html><body>login</body></html>".utf8)) == nil)
        #expect(QNAPParsers.root(Data("{\"data\": 1}".utf8)) == nil)
        #expect(try QNAPParsers.sessionID(try qnapFixture("qnap-login")) == "testsid0001")
        #expect(throws: APIError.unauthorized) { try QNAPParsers.sessionID(try qnapFixture("qnap-login-failed")) }
        #expect(throws: APIError.twoFactorRequired) { try QNAPParsers.sessionID(try qnapFixture("qnap-login-2sv")) }
        #expect(throws: APIError.unauthorized) { try QNAPParsers.sessionID(try qnapFixture("qnap-probe")) }
        #expect(QNAPParsers.sessionEnded(try qnapFixture("qnap-session-ended")))
        #expect(!QNAPParsers.sessionEnded(try qnapFixture("qnap-sysinfo")))
    }

    @Test func snapshot() throws {
        let s = QNAPParsers.snapshot(try reading(), now: apiFixtureNow)
        #expect(s.platform == .qnap && s.kind == .storage && s.power == .on)
        #expect(s.model == "TS-464" && s.hostname == "nas-01" && s.serial == "Q000TEST01")
        #expect(s.osVersion == "QTS 5.1.4.2596")
        #expect(s.firmware.map(\.value) == ["5.1.4.2596 build 20231128", "Q07AR021"])
        #expect(s.uptimeSeconds == 12 * 86_400 + 3 * 3600 + 4 * 60 + 5)
        #expect(s.facts.map(\.label) == ["Processor", "Memory"])

        // A temperature over the NAS's warning limit and a failed fan.
        let system = try #require(s.sensors.first { $0.name == "System" })
        #expect(system.reading == 62 && system.health == .warning)
        #expect(s.sensors.first { $0.name == "CPU" }?.health == .ok)
        #expect(s.sensors.first { $0.name == "SYS FAN 2" }?.health == .critical)
        #expect(s.sensors.filter { $0.kind == .fan }.count == 2)

        let data = try #require(s.pools.first)
        #expect(data.name == "DataVol1" && data.layout == "RAID 5" && data.health == .ok && data.status == "Ready")
        #expect(data.sizeBytes == 11_520_000_000_000 && data.usedBytes == 7_200_000_000_000)
        let second = try #require(s.pools.last)
        #expect(second.name == "Volume 2" && second.health == .warning && second.layout == "Single" && second.sizeBytes == nil)

        #expect(s.disks.map(\.name) == ["Disk 1", "Disk 2", "Disk 3", "Disk 4", "Disk 1:1"])
        let d3 = try #require(s.disks.first { $0.name == "Disk 3" })
        #expect(d3.health == .warning && d3.temperature == 41 && d3.type == "HDD" && d3.serial == "TEST0103")
        #expect(s.disks.last?.type == "SSD" && s.disks.last?.health == .ok)
        #expect(s.disks.first?.sizeBytes == Int64(3.64 * pow(1024, 4)))

        #expect(s.interfaces.map(\.name) == ["Adapter 1", "Adapter 2"])
        #expect(s.interfaces[0].linkUp == true && s.interfaces[0].speedMbps == 2500 && s.interfaces[0].addresses == ["192.0.2.30/24"])
        #expect(s.interfaces[1].linkUp == false && s.interfaces[1].speedMbps == nil && s.interfaces[1].addresses.isEmpty)

        // The failed fan first, then the warnings; the worst health wins.
        #expect(s.alerts == ["SYS FAN 2 status: 0 RPM", "Volume 2 status: code -5", "Disk 3 status: Warning", "System status: 62 °C"])
        #expect(s.health == .critical)
        #expect(s.detection.summary == "QNAP TS-464 · QTS 5.1.4.2596")
    }

    @Test func qutsHeroAndMissingStorage() throws {
        var r = QNAPParsers.Reading()
        let hero = try qnapFixture("qnap-login")
        hero.elements(forName: "hero_model").first?.stringValue = "1"
        r.login = hero
        r.sysinfo = try qnapFixture("qnap-sysinfo")
        let s = QNAPParsers.snapshot(r, now: apiFixtureNow)
        #expect(s.osVersion == "QuTS hero 5.1.4.2596" && s.detection.osLine == "QuTS hero 5.1.4.2596")
        // Without storage answers (an account that can't read them): said so, no pools or disks.
        #expect(s.pools.isEmpty && s.disks.isEmpty)
        #expect(s.alerts.contains { $0.contains("can't read storage information") })
    }

    @Test func helpers() {
        #expect(QNAPParsers.layout("mirror") == "RAID 1" && QNAPParsers.layout("raid6") == "RAID 6" && QNAPParsers.layout("raid10") == "RAID 10")
        #expect(QNAPParsers.layout("jbod") == "JBOD" && QNAPParsers.layout(nil) == nil)
        #expect(QNAPParsers.capacity("931.51 GB") == Int64(931.51 * pow(1024, 3)))
        #expect(QNAPParsers.capacity("--") == nil)
        #expect(QNAPParsers.diskHealth("Abnormal") == .critical && QNAPParsers.diskHealth("Good") == .ok)
        #expect(QNAPParsers.systemHealth("good") == .ok && QNAPParsers.systemHealth(nil) == .unknown && QNAPParsers.systemHealth("error") == .critical)
        #expect(QNAPParsers.diskName("0:12") == "Disk 12" && QNAPParsers.diskName("2:3") == "Disk 2:3")
    }

    @Test func catalog() {
        let p = Platform.qnap
        #expect(p.isAppliance && p.kinds == [.storage] && p.connections == [.api] && p.changeTraits == .readOnly)
        #expect(DriverFactory.supports(p, over: .api) && !DriverFactory.supports(p, over: .ssh))
        #expect(p.displayName == "QNAP QTS")
    }
}
