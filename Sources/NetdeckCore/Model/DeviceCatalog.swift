import Foundation

/// What a device is, independent of brand.
public enum DeviceKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case switchDevice = "switch", router, firewall, storage, server, wireless, other
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .switchDevice: return t("Switch")
        case .router: return t("Router")
        case .firewall: return t("Firewall")
        case .storage: return t("Storage")
        case .server: return t("Server")
        case .wireless: return t("Wireless")
        case .other: return t("Other")
        }
    }

    /// SF Symbol used in the sidebar, overview and add-device sheet.
    public var symbol: String {
        switch self {
        case .switchDevice: return "rectangle.connected.to.line.below"
        case .router: return "wifi.router"
        case .firewall: return "shield.lefthalf.filled"
        case .storage: return "externaldrive.connected.to.line.below"
        case .server: return "server.rack"
        case .wireless: return "wifi"
        case .other: return "shippingbox"
        }
    }

    /// One-line hint under the type name in the add-device type picker.
    public var hint: String {
        switch self {
        case .switchDevice: return t("Ports and VLANs")
        case .router: return t("Gateway")
        case .firewall: return t("Security gateway")
        case .storage: return t("NAS")
        case .server: return t("iDRAC / IPMI")
        case .wireless: return t("Access point")
        case .other: return t("Anything else")
        }
    }

    /// How this type can be reached (DESIGN.md §3.10 matrix). Methods a type can't use are shown
    /// disabled, without promising anything.
    public func availability(of connection: ConnectionType) -> ConnectionAvailability {
        switch (self, connection) {
        case (.switchDevice, .api), (.router, .api), (.firewall, .api): return .notAvailable
        case (.switchDevice, _), (.router, _), (.firewall, _): return .available
        case (.storage, .serial), (.wireless, .serial): return .notAvailable
        case (.storage, _), (.wireless, _): return .available
        case (.server, .api): return .available
        case (.server, _): return .notAvailable
        case (.other, .api): return .notAvailable
        case (.other, _): return .available
        }
    }
}

public enum ConnectionAvailability: Sendable, Equatable {
    case available, notAvailable
}

/// Software platform a driver talks to. Brand + OS, not a specific model.
public enum Platform: String, Codable, Sendable, CaseIterable, Identifiable {
    case juniperJunos = "juniper-junos"
    case mikrotikRouterOS = "mikrotik-routeros"
    case ciscoIOS = "cisco-ios"
    case ubiquitiEdgeOS = "ubiquiti-edgeos"
    case arubaAOSCX = "aruba-aos-cx"
    case arubaAOSS = "aruba-aos-s"
    case dellIDRAC = "dell-idrac"
    /// Any other server BMC over standard Redfish (HPE iLO, Supermicro, Lenovo XCC).
    case redfish = "redfish"
    case synologyDSM = "synology-dsm"
    case truenas = "truenas"
    case unknown

    public var id: String { rawValue }

    public enum Support: String, Sendable { case full, basic, planned }

    public var vendor: String {
        switch self {
        case .juniperJunos: return "Juniper"
        case .mikrotikRouterOS: return "MikroTik"
        case .ciscoIOS: return "Cisco"
        case .ubiquitiEdgeOS: return "Ubiquiti"
        case .arubaAOSCX, .arubaAOSS: return "Aruba"
        case .dellIDRAC: return "Dell"
        case .redfish: return "Redfish"
        case .synologyDSM: return "Synology"
        case .truenas: return "TrueNAS"
        case .unknown: return t("Unknown")
        }
    }

    public var osName: String {
        switch self {
        case .juniperJunos: return "Junos"
        case .mikrotikRouterOS: return "RouterOS"
        case .ciscoIOS: return "IOS"
        case .ubiquitiEdgeOS: return "EdgeOS"
        case .arubaAOSCX: return "AOS-CX"
        case .arubaAOSS: return "AOS-S"
        case .dellIDRAC: return "iDRAC"
        case .redfish: return "BMC"
        case .synologyDSM: return "DSM"
        case .truenas: return "TrueNAS"
        case .unknown: return "—"
        }
    }

    public var displayName: String { self == .unknown ? t("Unknown") : "\(vendor) \(osName)" }

    /// Every listed brand has a driver. `unknown` ("Other" in the brand picker) gets the basic info card.
    public var support: Support {
        switch self {
        case .unknown: return .basic
        default: return .full
        }
    }

    /// Reached over an HTTPS API and shown as an information screen (health, storage, sensors).
    public var isAppliance: Bool { self == .dellIDRAC || self == .redfish || self == .synologyDSM || self == .truenas }

    /// The vendor names the maker. Not for a generic Redfish BMC, whose model string carries the
    /// manufacturer ("HPE ProLiant DL360 Gen10"), nor for an unknown device.
    public var namesVendor: Bool { self != .redfish && self != .unknown }

    /// Second line of a brand tile in the manual picker.
    public var products: String {
        switch self {
        case .juniperJunos: return "Junos"
        case .mikrotikRouterOS: return "RouterOS"
        case .ciscoIOS: return "IOS / IOS-XE"
        case .ubiquitiEdgeOS: return "EdgeOS"
        case .arubaAOSCX: return "AOS-CX (6000–10000)"
        case .arubaAOSS: return "AOS-S, ProCurve (2530–5400R)"
        case .dellIDRAC: return "iDRAC"
        case .redfish: return "iLO, Supermicro, Lenovo"
        case .synologyDSM: return "DSM"
        case .truenas: return "TrueNAS"
        case .unknown: return t("Basic info only")
        }
    }

    /// Product families with their own support level (Juniper: only EX is fully supported).
    public var families: [PlatformFamily] {
        switch self {
        case .juniperJunos:
            return [PlatformFamily(id: "ex", name: "EX", kind: .switchDevice, support: .full),
                    PlatformFamily(id: "srx", name: "SRX", kind: .firewall, support: .full),
                    PlatformFamily(id: "mx", name: "MX", kind: .router, support: .full),
                    PlatformFamily(id: "qfx", name: "QFX", kind: .switchDevice, support: .full, dataCenter: true)]
        default: return []
        }
    }

    /// The family a model name belongs to ("EX4300-48T" → EX), when the platform has families.
    public func family(forModel model: String) -> PlatformFamily? {
        let m = model.lowercased()
        return families.filter { m.hasPrefix($0.id) }.max { $0.id.count < $1.id.count }
    }

    /// Brand name in the manual picker ("Other" for `unknown`).
    public var brand: String { self == .unknown ? t("Other") : vendor }

    /// Netdeck can read and keep this platform's configuration (drives History & backups).
    public var exportsConfig: Bool {
        switch self {
        case .juniperJunos, .mikrotikRouterOS, .ciscoIOS, .ubiquitiEdgeOS, .arubaAOSCX, .arubaAOSS: return true
        default: return false
        }
    }

    /// Device kinds this platform is commonly used for (drives the manual brand list per type).
    public var kinds: [DeviceKind] {
        switch self {
        case .juniperJunos: return [.switchDevice, .router, .firewall]
        case .mikrotikRouterOS: return [.router, .switchDevice, .wireless]
        case .ciscoIOS: return [.switchDevice, .router]
        case .ubiquitiEdgeOS: return [.router]
        case .arubaAOSCX, .arubaAOSS: return [.switchDevice]
        case .dellIDRAC, .redfish: return [.server]
        case .synologyDSM, .truenas: return [.storage]
        case .unknown: return DeviceKind.allCases
        }
    }

    public var connections: [ConnectionType] {
        switch self {
        case .dellIDRAC, .redfish: return [.api]
        case .synologyDSM, .truenas: return [.ssh, .api]
        default: return [.serial, .ssh]
        }
    }
}

public enum ConnectionType: String, Codable, Sendable, CaseIterable {
    case serial, ssh, api

    public var title: String {
        switch self {
        case .serial: return t("Serial console")
        case .ssh: return "SSH"
        case .api: return t("API (HTTPS)")
        }
    }
}

/// A product line of a platform, e.g. Juniper EX. Drives the family row of the manual picker.
public struct PlatformFamily: Sendable, Hashable, Identifiable {
    public var id: String
    /// Series name as printed on the hardware ("EX").
    public var name: String
    public var kind: DeviceKind
    public var support: Platform.Support
    /// QFX: shown as "Data center switch" rather than plain "Switch".
    public var dataCenter = false

    public init(id: String, name: String, kind: DeviceKind, support: Platform.Support, dataCenter: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.support = support
        self.dataCenter = dataCenter
    }

    /// "Switch", "Firewall", "Data center switch"...
    public var role: String { dataCenter ? t("Data center switch") : kind.title }
}

/// What the app learned about a device on connect.
public struct Detection: Codable, Sendable, Equatable, Hashable {
    public var platform: Platform
    public var model: String?
    public var osVersion: String?
    public var hostname: String?
    public var kind: DeviceKind?
    /// As printed by the device (e.g. "12d4h3m"), when it showed one.
    public var uptime: String?
    public var serial: String?

    public init(platform: Platform, model: String? = nil, osVersion: String? = nil, hostname: String? = nil, kind: DeviceKind? = nil,
                uptime: String? = nil, serial: String? = nil) {
        self.platform = platform
        self.model = model
        self.osVersion = osVersion
        self.hostname = hostname
        self.kind = kind
        self.uptime = uptime
        self.serial = serial
    }

    /// Support for what was found: the platform's level, narrowed by the model's family when known
    /// (a Juniper SRX gets basic support even though Junos itself is supported).
    public var support: Platform.Support {
        if let model, let family = platform.family(forModel: model) { return family.support }
        return platform.support
    }

    /// "Juniper EX4300-48T · Junos 21.2R3.8"; "HPE ProLiant DL360 Gen10 · iLO 5 2.72" for a generic
    /// Redfish BMC, whose model already names the maker.
    public var summary: String {
        var parts = [platform.namesVendor ? platform.vendor + (model.map { " " + $0 } ?? "") : model ?? platform.displayName]
        if let osLine { parts.append(osLine) }
        return parts.joined(separator: " · ")
    }

    /// "Junos 21.2R3.8"; API drivers already put the product name in the version ("iDRAC 7.00").
    public var osLine: String? {
        guard let osVersion else { return nil }
        return osVersion.hasPrefix(platform.osName) || platform == .unknown || platform == .redfish ? osVersion : "\(platform.osName) \(osVersion)"
    }
}

/// Recognises a device from whatever text it sent (login banner, prompt, version output).
public enum DeviceDetector {
    public static func detect(_ text: String) -> Detection? {
        let s = text
        if s.contains("JUNOS") || s.contains("Junos:") || s.range(of: #"@[\w.\-]+:RE:\d+%"#, options: .regularExpression) != nil {
            return junos(fromVersion: s) ?? Detection(platform: .juniperJunos)
        }
        if s.contains("MikroTik") || s.range(of: #"\[[\w.\-]+@[^\]]+\]\s*>"#, options: .regularExpression) != nil {
            var d = Detection(platform: .mikrotikRouterOS, kind: .router)
            if let r = s.range(of: #"RouterOS (\d+\.\d+(\.\d+)?)"#, options: .regularExpression) {
                d.osVersion = String(s[r].dropFirst("RouterOS ".count))
            } else if let r = s.range(of: #"MikroTik (\d+\.\d+(\.\d+)?)"#, options: .regularExpression) {
                d.osVersion = String(s[r].dropFirst("MikroTik ".count))
            }
            if let r = s.range(of: #"board-name: (\S+)"#, options: .regularExpression) {
                d.model = String(s[r].dropFirst("board-name: ".count))
            }
            if let r = s.range(of: #"uptime: (\S+)"#, options: .regularExpression) {
                d.uptime = String(s[r].dropFirst("uptime: ".count))
            }
            if let r = s.range(of: #"serial-number: (\S+)"#, options: .regularExpression) {
                d.serial = String(s[r].dropFirst("serial-number: ".count))
            }
            return d
        }
        if s.contains("Cisco IOS") || s.contains("IOS-XE") || s.contains("Cisco Systems") {
            var d = Detection(platform: .ciscoIOS)
            if let r = s.range(of: #"Version ([\w.()]+)"#, options: .regularExpression) {
                d.osVersion = String(s[r].dropFirst("Version ".count))
            }
            return d
        }
        // AOS-S / ProCurve: the SSH banner ("Aruba JL322A 2930M-48G-PoE+ Switch", "Software revision WC.16.11.0028",
        // "Press any key to continue"), `show version` ("Image stamp:") or `show system`.
        if s.contains("ProCurve") || s.contains("Press any key to continue") || AOSSParsers.isAOSS(s)
            || s.range(of: #"Software revision\s*:?\s*[A-Z]{1,3}\.1\d\."#, options: .regularExpression) != nil {
            let model = CiscoParsers.capture(#"(?:Aruba|HPE?|ProCurve) J[A-Z]?\d{3,4}[A-Z] (\S+)"#, in: s)?.first
            return Detection(platform: .arubaAOSS, model: model, osVersion: AOSSParsers.softwareRevision(s), kind: .switchDevice)
        }
        // AOS-CX: "ArubaOS-CX" in `show version`, or its login lines ("User "admin" has logged in 12 times in the past 30 days").
        if AOSCXParsers.isAOSCX(s) || s.range(of: #"has logged in \d+ times in the past"#, options: .regularExpression) != nil {
            return Detection(platform: .arubaAOSCX, model: AOSCXParsers.system(s).productName.map(AOSCXParsers.model(fromProduct:)),
                             osVersion: AOSCXParsers.osVersion(s), kind: .switchDevice)
        }
        if s.contains("EdgeOS") || s.contains("EdgeRouter") {
            return Detection(platform: .ubiquitiEdgeOS, kind: .router)
        }
        if s.contains("Integrated Dell Remote Access Controller") || s.contains("iDRAC") {
            return Detection(platform: .dellIDRAC, kind: .server)
        }
        if s.contains("Synology") || s.contains("DiskStation") {
            return Detection(platform: .synologyDSM, kind: .storage)
        }
        if s.contains("TrueNAS") || s.contains("FreeNAS") {
            return Detection(platform: .truenas, kind: .storage)
        }
        if s.contains("User Access Verification") {
            return Detection(platform: .ciscoIOS)
        }
        // Nothing in the banner: go by the prompt the device left us at.
        let last = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
        if let p = foreignPrompt(last), p != .unknown { return Detection(platform: p) }
        return nil
    }

    /// A prompt (or login prompt) that isn't Junos: the platform it most likely belongs to, `.unknown`
    /// for a generic shell prompt, or nil when the line isn't a recognisable prompt at all.
    public static func foreignPrompt(_ line: String) -> Platform? {
        let l = line.trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty, l.count < 120 else { return nil }
        // [admin@MikroTik] >   [admin@MikroTik] /interface>   [admin@MikroTik] <SAFE>
        if l.range(of: #"^\[[^\]@\s]+@[^\]]+\]\s*(<SAFE>\s*)?(/[\w/\-]*)?>?$"#, options: .regularExpression) != nil,
           l.hasSuffix(">") { return .mikrotikRouterOS }
        if l.hasSuffix("Login:"), l.contains("MikroTik") { return .mikrotikRouterOS }
        // ubnt@edge:~$   admin@nas:/$   root@host:~#
        if l.range(of: #"^[\w.\-]+@[\w.\-]+:[^\s]*[$#]$"#, options: .regularExpression) != nil { return .unknown }
        // Switch>   Switch#   Switch(config-if)#   (no "@": Junos prompts always have one)
        if l.range(of: #"^[A-Za-z0-9][\w.\-]*(\([\w\-]+\))?[>#]$"#, options: .regularExpression) != nil { return .ciscoIOS }
        if l.hasSuffix("Username:") { return .ciscoIOS }
        return nil
    }

    /// A login prompt of any platform ("login:", "MikroTik Login:", "Username:").
    public static func isLoginPrompt(_ line: String) -> Bool {
        let l = line.trimmingCharacters(in: .whitespaces)
        return l.hasSuffix("login:") || l.hasSuffix("Login:") || l.hasSuffix("Username:")
    }

    /// Parses Junos `show version`: "Model: ex4300-48t", "Junos: 21.2R3.8", "Hostname: sw-01".
    public static func junos(fromVersion text: String) -> Detection? {
        let v = OutputParsers.version(text)
        guard v.model != nil || v.junos != nil else { return nil }
        let model = v.model?.uppercased()
        return Detection(platform: .juniperJunos, model: model, osVersion: v.junos, hostname: v.hostname,
                         kind: model.map(junosKind) ?? nil)
    }

    /// EX/QFX → switch, SRX → firewall, MX/PTX/ACX → router.
    public static func junosKind(_ model: String) -> DeviceKind? {
        let m = model.lowercased()
        if m.hasPrefix("ex") || m.hasPrefix("qfx") { return .switchDevice }
        if m.hasPrefix("srx") || m.hasPrefix("vsrx") { return .firewall }
        if m.hasPrefix("mx") || m.hasPrefix("ptx") || m.hasPrefix("acx") { return .router }
        return nil
    }
}
