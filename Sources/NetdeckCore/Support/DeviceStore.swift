import Foundation
import Security

public struct DeviceProfile: Codable, Sendable, Identifiable, Equatable, Hashable {
    public enum Connection: Codable, Sendable, Equatable, Hashable {
        case serial(path: String, baud: Int)
        case ssh(host: String, port: Int)
        case api(url: String)

        public var type: ConnectionType {
            switch self {
            case .serial: return .serial
            case .ssh: return .ssh
            case .api: return .api
            }
        }
    }

    public var id: String
    public var name: String
    public var kind: DeviceKind
    /// `nil` = detect automatically on connect.
    public var platform: Platform?
    /// Last thing we learned on connect (model, OS version...).
    public var detected: Detection?
    /// Sidebar group, e.g. "Home", "Datacenter". `nil` = ungrouped.
    public var location: String?
    public var connection: Connection
    public var username: String
    /// Friendly names for MAC addresses ("b0:7b:25:00:00:0b" → "Server 1 iDRAC").
    public var aliases: [String: String]
    /// Icon picked for a named MAC (an SF Symbol name), keyed like `aliases`. Stored only on this Mac.
    public var aliasIcons: [String: String] = [:]

    public init(id: String = UUID().uuidString, name: String, kind: DeviceKind = .switchDevice, platform: Platform? = nil,
                location: String? = nil, connection: Connection, username: String, aliases: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.platform = platform
        self.location = location
        self.connection = connection
        self.username = username
        self.aliases = aliases
    }

    /// Platform in effect: chosen by the user, else last detected.
    public var effectivePlatform: Platform? { platform ?? detected?.platform }

    public var serialPath: String? {
        if case let .serial(path, _) = connection { return path }
        return nil
    }

    /// `UserDefaults` key: true makes SSH go through `/usr/bin/ssh` (`SSHTransport`) instead of the
    /// embedded client. Ignored inside the App Sandbox, where the system ssh can't run.
    public static let useSystemSSHKey = "netdeck.useSystemSSH"

    /// Whether SSH connections use the system ssh command (see `useSystemSSHKey`).
    public static func usesSystemSSH(defaults: UserDefaults = .standard) -> Bool {
        !AppPaths.isSandboxed && defaults.bool(forKey: useSystemSSHKey)
    }

    /// The byte stream to the device. `username` overrides the login name sent to SSH (RouterOS
    /// takes terminal options in it: "admin+ct").
    public func makeTransport(password: String?, username: String? = nil, systemSSH: Bool = DeviceProfile.usesSystemSSH()) -> Transport? {
        switch connection {
        case let .serial(path, baud): return SerialTransport(path: path, baud: baud)
        case let .ssh(host, port):
            let user = username ?? self.username
            if systemSSH { return SSHTransport(host: host, port: port, username: user, password: password) }
            return NIOSSHTransport(host: host, port: port, username: user, password: password)
        case .api: return nil
        }
    }

    public var connectionLabel: String {
        switch connection {
        case let .serial(path, baud): return t("Serial · %@ · %@ baud", (path as NSString).lastPathComponent, String(baud))
        case let .ssh(host, _): return t("SSH · %@", host)
        case let .api(url): return t("API · %@", URL(string: url)?.host ?? url)
        }
    }
}

/// Profiles saved before a field existed still decode: newer fields fall back to their defaults.
extension DeviceProfile {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(DeviceKind.self, forKey: .kind)
        platform = try c.decodeIfPresent(Platform.self, forKey: .platform)
        detected = try c.decodeIfPresent(Detection.self, forKey: .detected)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        connection = try c.decode(Connection.self, forKey: .connection)
        username = try c.decode(String.self, forKey: .username)
        aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        aliasIcons = try c.decodeIfPresent([String: String].self, forKey: .aliasIcons) ?? [:]
    }
}

public struct DeviceStore: Sendable {
    public init() {}

    func fileURL() throws -> URL { try AppPaths.supportDirectory().appendingPathComponent("devices.json") }

    public func load() -> [DeviceProfile] {
        guard let url = try? fileURL(), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([DeviceProfile].self, from: data)) ?? []
    }

    public func save(_ devices: [DeviceProfile]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(devices).write(to: try fileURL(), options: .atomic)
    }
}

/// Passwords live in the login keychain, never on disk.
public enum Keychain {
    static let service = "tech.odbs.netdeck"

    public static func setPassword(_ password: String, for deviceID: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: deviceID]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrLabel as String] = "Netdeck"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: t("Could not save the password to the Keychain (%@).", String(status))])
        }
    }

    public static func password(for deviceID: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: deviceID,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func deletePassword(for deviceID: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: deviceID]
        SecItemDelete(q as CFDictionary)
    }
}
