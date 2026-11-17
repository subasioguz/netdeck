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

    @Test func everyListedBrandIsSupported() {
        #expect(Platform.allCases.filter { $0.support != .full } == [.unknown])
        #expect(Platform.unknown.support == .basic)
        #expect(Platform.dellIDRAC.connections == [.api])
        #expect(Platform.juniperJunos.families.map(\.id) == ["ex", "srx", "mx", "qfx"])
        #expect(Platform.juniperJunos.families.allSatisfy { $0.support == .full })
        #expect(Detection(platform: .juniperJunos, model: "SRX345").support == .full)
        #expect(Detection(platform: .mikrotikRouterOS, model: "RB5009UG+S+").support == .full)
    }

    @Test func connectionMatrixPerType() {
        #expect(DeviceKind.switchDevice.availability(of: .serial) == .available)
        #expect(DeviceKind.switchDevice.availability(of: .ssh) == .available)
        #expect(DeviceKind.router.availability(of: .api) == .notAvailable)
        #expect(DeviceKind.storage.availability(of: .serial) == .notAvailable)
        #expect(DeviceKind.wireless.availability(of: .ssh) == .available)
        #expect(DeviceKind.server.availability(of: .ssh) == .notAvailable)
        #expect(DeviceKind.server.availability(of: .api) == .available)
        #expect(DeviceKind.other.availability(of: .api) == .notAvailable)
    }

    @Test func foreignPromptsHandOverFromTheJunosLogin() {
        #expect(DeviceDetector.foreignPrompt("[admin@MikroTik] > ") == .mikrotikRouterOS)
        #expect(DeviceDetector.foreignPrompt("[admin@rb5009] <SAFE> ") == .mikrotikRouterOS)
        #expect(DeviceDetector.foreignPrompt("[admin@rb5009] /interface> ") == .mikrotikRouterOS)
        #expect(DeviceDetector.foreignPrompt("MikroTik Login: ") == .mikrotikRouterOS)
        #expect(DeviceDetector.foreignPrompt("Switch#") == .ciscoIOS)
        #expect(DeviceDetector.foreignPrompt("core-sw1>") == .ciscoIOS)
        #expect(DeviceDetector.foreignPrompt("Switch(config-if)#") == .ciscoIOS)
        #expect(DeviceDetector.foreignPrompt("Username: ") == .ciscoIOS)
        #expect(DeviceDetector.foreignPrompt("ubnt@edge:~$ ") == .unknown)
        // Junos prompts are never foreign.
        #expect(DeviceDetector.foreignPrompt("root@sw-01> ") == nil)
        #expect(DeviceDetector.foreignPrompt("root@sw-01:RE:0%") == nil)
        #expect(DeviceDetector.foreignPrompt("{master:0}") == nil)
        #expect(DeviceDetector.foreignPrompt("Hostname: sw-01") == nil)
        // A bare prompt is enough to pick the driver.
        #expect(DeviceDetector.detect("\r\nSwitch>")?.platform == .ciscoIOS)
        #expect(DeviceDetector.detect("User Access Verification\n\nUsername: ")?.platform == .ciscoIOS)
        #expect(DeviceDetector.isLoginPrompt("MikroTik Login: "))
        #expect(DeviceDetector.isLoginPrompt("Username:"))
    }

    @Test func junosModelTraits() {
        let ex = JunosModel("ex4300-48t")
        #expect(ex.rearPIC == 1)
        #expect(!ex.isFrontPanel("et-0/1/0"))
        #expect(ex.isFrontPanel("ge-0/0/12"))
        #expect(!ex.isCage("ge-0/0/12", hasModule: false))
        #expect(ex.isCage("xe-0/2/0", hasModule: false))
        #expect(ex.isCage("ge-0/2/1", hasModule: false))

        let qfx = JunosModel("QFX5100-48S-6Q")
        #expect(qfx.rearPIC == nil)
        #expect(qfx.isCage("xe-0/0/0", hasModule: false))
        #expect(qfx.isCage("et-0/0/48", hasModule: false))
        #expect(!JunosModel("QFX5100-48T-6Q").isCage("xe-0/0/3", hasModule: false))

        let srx = JunosModel("SRX345")
        #expect(!srx.isCage("ge-0/0/7", hasModule: false))
        #expect(srx.isCage("ge-0/0/8", hasModule: false))
        #expect(JunosModel("SRX300").isCage("ge-0/0/6", hasModule: false))

        let mx = JunosModel("MX204")
        #expect(mx.isRouter)
        #expect(mx.isCage("xe-0/1/3", hasModule: false))
        #expect(mx.isFrontPanel("et-0/0/0"))
        #expect(!mx.isFrontPanel("et-0/0/0:1"))
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
