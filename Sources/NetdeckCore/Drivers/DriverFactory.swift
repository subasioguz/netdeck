import Foundation

/// Creates the driver for a device's platform and connection.
public enum DriverFactory {
    /// Platform used when nothing is known yet. Over a console or SSH it is Junos, which also
    /// recognises other platforms from what they print and hands over (`DeviceSession.connect`).
    /// Over HTTPS it is `.unknown`: the API driver finds out which API answers.
    public static func fallbackPlatform(for connection: ConnectionType) -> Platform {
        connection == .api ? .unknown : .juniperJunos
    }

    /// Netdeck has a driver for this platform over this connection type.
    public static func supports(_ platform: Platform, over connection: ConnectionType) -> Bool {
        switch (platform, connection) {
        case (.juniperJunos, .serial), (.juniperJunos, .ssh): return true
        default: return VendorDrivers.supports(platform, over: connection)
        }
    }

    /// A new, unconnected driver, or nil when the platform has none for this connection. `madeTransport`
    /// receives the byte stream a CLI driver will use (the session reads the SSH algorithms from it).
    public static func make(platform: Platform, profile: DeviceProfile, password: String?,
                            madeTransport: (Transport) -> Void = { _ in }) -> (any DeviceDriver)? {
        switch (platform, profile.connection) {
        case (.juniperJunos, .serial), (.juniperJunos, .ssh):
            return profile.makeTransport(password: password).map { madeTransport($0); return JunosDriver(transport: $0) }
        default:
            return VendorDrivers.make(platform: platform, profile: profile, password: password, madeTransport: madeTransport)
        }
    }
}

/// Drivers of the platforms other than Junos.
enum VendorDrivers {
    static func supports(_ platform: Platform, over connection: ConnectionType) -> Bool {
        switch (platform, connection) {
        case (.mikrotikRouterOS, .serial), (.mikrotikRouterOS, .ssh),
             (.ciscoIOS, .serial), (.ciscoIOS, .ssh),
             (.ubiquitiEdgeOS, .serial), (.ubiquitiEdgeOS, .ssh),
             (.arubaAOSCX, .serial), (.arubaAOSCX, .ssh):
            return true
        case (.dellIDRAC, .api), (.redfish, .api), (.synologyDSM, .api), (.truenas, .api), (.unknown, .api):
            return true
        default:
            return false
        }
    }

    static func make(platform: Platform, profile: DeviceProfile, password: String?,
                     madeTransport: (Transport) -> Void = { _ in }) -> (any DeviceDriver)? {
        guard supports(platform, over: profile.connection.type) else { return nil }
        switch platform {
        case .mikrotikRouterOS:
            return profile.makeTransport(password: password, username: MikroTikDialect.loginName(profile.username))
                .map { madeTransport($0); return MikroTikDriver(transport: $0) }
        case .ciscoIOS:
            return profile.makeTransport(password: password).map { madeTransport($0); return CiscoDriver(transport: $0) }
        case .ubiquitiEdgeOS:
            return profile.makeTransport(password: password).map { madeTransport($0); return EdgeOSDriver(transport: $0) }
        case .arubaAOSCX:
            return profile.makeTransport(password: password).map { madeTransport($0); return AOSCXDriver(transport: $0) }
        case .dellIDRAC, .redfish, .synologyDSM, .truenas, .unknown:
            guard case let .api(url) = profile.connection else { return nil }
            return APIDriver(url: url, platform: platform)
        case .juniperJunos:
            return nil
        }
    }
}
