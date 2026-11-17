import Foundation
import Testing
@testable import NetdeckCore

@Suite struct DetectionTests {
    @Test func junosFromShowVersion() throws {
        let d = try #require(DeviceDetector.junos(fromVersion: try fixture("version")))
        #expect(d.platform == .juniperJunos)
        #expect(d.model == "EX4300-48T")
        #expect(d.osVersion == "21.2R3.8")
        #expect(d.kind == .switchDevice)
        #expect(d.summary == "Juniper EX4300-48T · Junos 21.2R3.8")
    }

    @Test func junosKindsByModel() {
        #expect(DeviceDetector.junosKind("EX2300-24T") == .switchDevice)
        #expect(DeviceDetector.junosKind("qfx5100") == .switchDevice)
        #expect(DeviceDetector.junosKind("SRX345") == .firewall)
        #expect(DeviceDetector.junosKind("mx204") == .router)
        #expect(DeviceDetector.junosKind("nfx250") == nil)
    }

    @Test func recognisesOtherVendorsFromBannersAndPrompts() {
        let mikrotik = DeviceDetector.detect("MikroTik 7.14.3 (stable)\nLogin: admin\nPassword:\n[admin@MikroTik] > ")
        #expect(mikrotik?.platform == .mikrotikRouterOS)
        #expect(mikrotik?.osVersion == "7.14.3")
        #expect(mikrotik?.kind == .router)

        #expect(DeviceDetector.detect("Cisco IOS Software, C2960X Software, Version 15.2(7)E8")?.platform == .ciscoIOS)
        #expect(DeviceDetector.detect("Welcome to EdgeOS")?.platform == .ubiquitiEdgeOS)
        #expect(DeviceDetector.detect(#"{"Product":"Integrated Dell Remote Access Controller"}"#)?.kind == .server)
        #expect(DeviceDetector.detect("Synology DiskStation DS920+")?.kind == .storage)
        #expect(DeviceDetector.detect("TrueNAS SCALE 24.04")?.platform == .truenas)
        #expect(DeviceDetector.detect("root@sw-01:RE:0% ")?.platform == .juniperJunos)
        #expect(DeviceDetector.detect("hello") == nil)
    }

    @Test func onlyJunosIsFullySupported() {
        #expect(Platform.juniperJunos.support == .full)
        #expect(Platform.allCases.filter { $0.support == .full } == [.juniperJunos])
        #expect(Platform.dellIDRAC.connections == [.api])
    }

    @Test func onlyJuniperEXIsFullySupported() {
        #expect(Platform.juniperJunos.families.map(\.id) == ["ex", "srx", "mx", "qfx"])
        #expect(Platform.juniperJunos.families.filter { $0.support == .full }.map(\.id) == ["ex"])
        #expect(Platform.unknown.support == .basic)
        #expect(Detection(platform: .juniperJunos, model: "EX4300-48T").support == .full)
        #expect(Detection(platform: .juniperJunos, model: "SRX345").support == .basic)
        #expect(Detection(platform: .juniperJunos, model: "QFX5120-48Y").support == .basic)
        #expect(Detection(platform: .juniperJunos, model: "MX204").support == .basic)
        #expect(Detection(platform: .juniperJunos).support == .full)
        #expect(Detection(platform: .mikrotikRouterOS, model: "RB5009UG+S+").support == .planned)
    }

    @Test func connectionMatrixPerType() {
        #expect(DeviceKind.switchDevice.availability(of: .serial) == .available)
        #expect(DeviceKind.switchDevice.availability(of: .ssh) == .available)
        #expect(DeviceKind.router.availability(of: .api) == .comingSoon)
        #expect(DeviceKind.storage.availability(of: .serial) == .notAvailable)
        #expect(DeviceKind.wireless.availability(of: .ssh) == .available)
        #expect(DeviceKind.server.availability(of: .ssh) == .notAvailable)
        // The matrix allows the API for servers, but Netdeck has no HTTPS client yet.
        #expect(DeviceKind.server.availability(of: .api) == .comingSoon)
        #expect(DeviceKind.other.availability(of: .api) == .notAvailable)
    }
}

@Suite struct LocalizationTests {
    @Test func englishIsTheDefaultAndTurkishTranslates() {
        #expect(L10n.translate("will be disabled", language: .en) == "will be disabled")
        #expect(L10n.translate("description: %@ → %@", ["a", "b"], language: .en) == "description: a → b")
        #expect(L10n.translate("will be disabled", language: .tr) == "kapat\u{0131}lacak")
        #expect(L10n.translate("description: %@ → %@", ["a", "b"], language: .tr) == "a\u{00E7}\u{0131}klama: a → b")
        #expect(L10n.translate("A key with no translation", language: .tr) == "A key with no translation")
    }

    @Test func commitCommentsAreASCII() {
        let s = L10n.asciiComment("Netdeck: ge-0/0/2 a\u{00E7}\u{0131}klamas\u{0131} \u{2192} SRV02 \u{00B7} \u{0130}\u{015F}")
        #expect(s == "Netdeck: ge-0/0/2 aciklamasi -> SRV02 - Is")
        let isASCII = s.allSatisfy { $0.isASCII }
        #expect(isASCII)
    }
}
