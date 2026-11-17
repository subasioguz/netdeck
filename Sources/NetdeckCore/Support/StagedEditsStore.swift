import Foundation

/// Edits staged on one device and not yet applied.
public struct StagedEdits: Equatable, Sendable {
    public var ports: [PortEdit]
    public var vlans: [VLANEdit]
    public var rear: [RearPortEdit]

    public init(ports: [PortEdit] = [], vlans: [VLANEdit] = [], rear: [RearPortEdit] = []) {
        self.ports = ports
        self.vlans = vlans
        self.rear = rear
    }

    public var isEmpty: Bool { ports.isEmpty && vlans.isEmpty && rear.isEmpty }
}

/// Staged edits kept on this Mac, one JSON file per device, so they survive a restart (§6.1).
/// Files live in `<Application Support>/Netdeck/staged/`. An empty set removes the device's file.
public struct StagedEditsStore: Sendable {
    private let directory: URL?

    /// `directory: nil` uses the app's support folder (`AppPaths`); tests pass a temporary folder.
    public init(directory: URL? = nil) { self.directory = directory }

    func fileURL(deviceID: String) throws -> URL {
        let dir = try directory ?? AppPaths.supportDirectory().appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = String(deviceID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" })
        return dir.appendingPathComponent(safe.isEmpty ? "_" : safe).appendingPathExtension("json")
    }

    /// The device's staged edits, or an empty set when nothing (readable) is stored.
    public func load(deviceID: String) -> StagedEdits {
        guard let url = try? fileURL(deviceID: deviceID), let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return StagedEdits() }
        return StagedEdits(ports: file.ports.map(\.edit), vlans: file.vlans.compactMap(\.edit), rear: file.rear ?? [])
    }

    public func save(_ edits: StagedEdits, deviceID: String) throws {
        let url = try fileURL(deviceID: deviceID)
        guard !edits.isEmpty else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        let file = File(ports: edits.ports.map(StoredPort.init), vlans: edits.vlans.map(StoredVLAN.init),
                        rear: edits.rear.isEmpty ? nil : edits.rear)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(file).write(to: url, options: .atomic)
    }

    public func remove(deviceID: String) {
        guard let url = try? fileURL(deviceID: deviceID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: File format (version 1)

    private struct File: Codable {
        var version = 1
        var ports: [StoredPort]
        var vlans: [StoredVLAN]
        /// Rear QSFP+ roles; absent in files written before they existed.
        var rear: [RearPortEdit]?
    }

    private struct StoredPort: Codable {
        var port: String
        var description: String?
        var enabled: Bool?
        var mode: PortMode?
        var vlans: [String]?
        /// `nativeVlanID` is a double optional: `.some(nil)` (remove the native VLAN) is stored as this flag.
        var nativeVlanID: Int?
        var removeNativeVlan: Bool?

        init(_ e: PortEdit) {
            port = e.port
            description = e.description
            enabled = e.enabled
            mode = e.mode
            vlans = e.vlans
            switch e.nativeVlanID {
            case .none: break
            case .some(.none): removeNativeVlan = true
            case let .some(.some(id)): nativeVlanID = id
            }
        }

        var edit: PortEdit {
            let native: Int?? = removeNativeVlan == true ? .some(nil) : nativeVlanID.map { .some($0) }
            return PortEdit(port: port, description: description, enabled: enabled, mode: mode, vlans: vlans, nativeVlanID: native)
        }
    }

    private struct StoredVLAN: Codable {
        var action: String
        var name: String
        var vlanID: Int?
        var description: String?
        var newName: String?

        init(_ e: VLANEdit) {
            switch e {
            case let .add(name, id, d): action = "add"; self.name = name; vlanID = id; description = d
            case let .update(name, id, d): action = "update"; self.name = name; vlanID = id; description = d
            case let .rename(from, to): action = "rename"; name = from; newName = to
            case let .delete(name): action = "delete"; self.name = name
            }
        }

        var edit: VLANEdit? {
            switch action {
            case "add": return vlanID.map { .add(name: name, vlanID: $0, description: description) }
            case "update": return .update(name: name, vlanID: vlanID, description: description)
            case "rename": return newName.map { .rename(from: name, to: $0) }
            case "delete": return .delete(name: name)
            default: return nil
            }
        }
    }
}
