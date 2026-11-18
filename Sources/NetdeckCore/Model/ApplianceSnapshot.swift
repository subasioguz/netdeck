import Foundation

/// What Netdeck shows about a device reached over an HTTPS API: a server BMC (iDRAC) or a NAS
/// (Synology DSM, TrueNAS, QNAP). Read-only, except server power commands the user confirmed.
public struct ApplianceSnapshot: Equatable, Sendable {
    public enum Health: String, Sendable, Equatable, Comparable {
        case ok, warning, critical, unknown

        private var rank: Int {
            switch self {
            case .ok: return 0
            case .unknown: return 1
            case .warning: return 2
            case .critical: return 3
            }
        }
        public static func < (a: Health, b: Health) -> Bool { a.rank < b.rank }

        /// Redfish `Status.Health` / `HealthRollup` ("OK", "Warning", "Critical").
        public init(redfish value: String?) {
            switch value?.lowercased() {
            case "ok": self = .ok
            case "warning": self = .warning
            case "critical": self = .critical
            default: self = .unknown
            }
        }
    }

    public enum PowerState: String, Sendable, Equatable { case on, off, unknown }

    /// A server power command (Redfish `ComputerSystem.Reset` `ResetType`), in menu order.
    public enum PowerAction: String, Sendable, CaseIterable {
        case on = "On"
        case gracefulShutdown = "GracefulShutdown"
        case gracefulRestart = "GracefulRestart"
        case forceRestart = "ForceRestart"
        case forceOff = "ForceOff"
        case powerCycle = "PowerCycle"
    }

    /// A label and a value for the summary grid ("Processors" → "2× Intel Xeon Silver 4214").
    public struct Fact: Equatable, Sendable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }
        public init(label: String, value: String) { self.label = label; self.value = value }
    }

    public struct Sensor: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable { case temperature, fan }
        public var name: String
        public var kind: Kind
        /// °C for temperatures, RPM (or percent, see `unit`) for fans.
        public var reading: Double?
        public var unit: String
        public var health: Health
        public var id: String { kind.rawValue + ":" + name }
        public init(name: String, kind: Kind, reading: Double?, unit: String, health: Health) {
            self.name = name; self.kind = kind; self.reading = reading; self.unit = unit; self.health = health
        }
    }

    /// Power supply, controller, battery... anything with a name, a state and one line of detail.
    public struct Component: Equatable, Sendable, Identifiable {
        public var name: String
        public var detail: String?
        public var health: Health
        public var id: String { name }
        public init(name: String, detail: String? = nil, health: Health) { self.name = name; self.detail = detail; self.health = health }
    }

    public struct StoragePool: Equatable, Sendable, Identifiable {
        public var name: String
        /// As the device says it ("ONLINE", "normal", "degraded"...).
        public var status: String
        public var health: Health
        public var sizeBytes: Int64?
        public var usedBytes: Int64?
        /// "RAID 5", "RAIDZ1", "SHR"...
        public var layout: String?
        public var id: String { name }
        public init(name: String, status: String, health: Health, sizeBytes: Int64? = nil, usedBytes: Int64? = nil, layout: String? = nil) {
            self.name = name; self.status = status; self.health = health; self.sizeBytes = sizeBytes; self.usedBytes = usedBytes; self.layout = layout
        }
    }

    public struct Disk: Equatable, Sendable, Identifiable {
        public var name: String
        public var model: String?
        public var serial: String?
        public var sizeBytes: Int64?
        /// "HDD", "SSD", "NVMe"...
        public var type: String?
        public var health: Health
        public var temperature: Double?
        public var pool: String?
        public var id: String { name }
        public init(name: String, model: String? = nil, serial: String? = nil, sizeBytes: Int64? = nil, type: String? = nil,
                    health: Health, temperature: Double? = nil, pool: String? = nil) {
            self.name = name; self.model = model; self.serial = serial; self.sizeBytes = sizeBytes; self.type = type
            self.health = health; self.temperature = temperature; self.pool = pool
        }
    }

    public struct NetInterface: Equatable, Sendable, Identifiable {
        public var name: String
        public var mac: String?
        public var linkUp: Bool?
        public var speedMbps: Int?
        public var addresses: [String]
        public var id: String { name }
        public init(name: String, mac: String? = nil, linkUp: Bool? = nil, speedMbps: Int? = nil, addresses: [String] = []) {
            self.name = name; self.mac = mac; self.linkUp = linkUp; self.speedMbps = speedMbps; self.addresses = addresses
        }
    }

    public var takenAt: Date
    public var platform: Platform
    public var kind: DeviceKind
    public var hostname: String?
    public var model: String?
    public var serial: String?
    /// Software name and version as shown ("DSM 7.2.1-69057", "TrueNAS SCALE 24.10.2", "iDRAC 7.00.00.172").
    public var osVersion: String?
    public var uptimeSeconds: Int?
    public var power: PowerState
    /// Overall health as the device reports it.
    public var health: Health
    public var facts: [Fact]
    /// Firmware and BIOS versions (name → version).
    public var firmware: [Fact]
    public var sensors: [Sensor]
    public var components: [Component]
    public var pools: [StoragePool]
    public var disks: [Disk]
    public var interfaces: [NetInterface]
    /// Current problems the device lists (active alerts, failed checks), newest first.
    public var alerts: [String]
    /// Power commands the server accepts (Redfish BMCs only); empty when Netdeck can't send any.
    public var powerActions: [PowerAction] = []

    public init(takenAt: Date = .now, platform: Platform, kind: DeviceKind, hostname: String? = nil, model: String? = nil,
                serial: String? = nil, osVersion: String? = nil, uptimeSeconds: Int? = nil, power: PowerState = .unknown,
                health: Health = .unknown, facts: [Fact] = [], firmware: [Fact] = [], sensors: [Sensor] = [],
                components: [Component] = [], pools: [StoragePool] = [], disks: [Disk] = [], interfaces: [NetInterface] = [],
                alerts: [String] = [], powerActions: [PowerAction] = []) {
        self.takenAt = takenAt
        self.platform = platform
        self.kind = kind
        self.hostname = hostname
        self.model = model
        self.serial = serial
        self.osVersion = osVersion
        self.uptimeSeconds = uptimeSeconds
        self.power = power
        self.health = health
        self.facts = facts
        self.firmware = firmware
        self.sensors = sensors
        self.components = components
        self.pools = pools
        self.disks = disks
        self.interfaces = interfaces
        self.alerts = alerts
        self.powerActions = powerActions
    }

    /// What the add-device sheet and the device list learn from this reading.
    public var detection: Detection {
        Detection(platform: platform, model: model, osVersion: osVersion, hostname: hostname, kind: kind,
                  uptime: uptimeSeconds.map(Self.uptimeText), serial: serial)
    }

    /// The worst health of everything listed, or the device's own overall health when it is worse.
    public var worstHealth: Health {
        let all = [health] + sensors.map(\.health) + components.map(\.health) + pools.map(\.health) + disks.map(\.health)
        return all.filter { $0 != .unknown }.max() ?? health
    }

    /// "12d 4h", "3h 20m", "45m".
    public static func uptimeText(_ seconds: Int) -> String {
        let d = seconds / 86_400, h = (seconds % 86_400) / 3600, m = (seconds % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
