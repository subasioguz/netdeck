import Foundation

/// EdgeOS data the change planner needs beyond `JunosConfig`: the `switch0` hardware switch, which
/// ports are its members and their VLAN settings, and the switch0 vifs (VLAN interfaces).
public struct EdgeOSState: Equatable, Sendable {
    /// VLAN settings of one switch0 member port (`switch-port interface ethN vlan pvid N | vid N`).
    public struct SwitchMember: Equatable, Sendable {
        /// Untagged VLAN as configured; nil when the port has no `pvid` (it then uses VLAN 1).
        public var pvid: Int?
        /// Tagged VLANs, in configuration order.
        public var vids: [Int]

        public init(pvid: Int? = nil, vids: [Int] = []) {
            self.pvid = pvid
            self.vids = vids
        }

        /// The untagged VLAN in effect.
        public var untaggedVLAN: Int { pvid ?? EdgeOSState.defaultVLAN }
        /// Untagged VLAN first, then the tagged ones.
        public var vlanIDs: [Int] { [untaggedVLAN] + vids.filter { $0 != untaggedVLAN } }
    }

    /// A switch0 vif (`interfaces switch switch0 vif N`): the router's own interface on VLAN N.
    public struct Vif: Equatable, Sendable {
        public var id: Int
        public var description: String?
        public var addresses: [String]

        public init(id: Int, description: String? = nil, addresses: [String] = []) {
            self.id = id
            self.description = description
            self.addresses = addresses
        }
    }

    /// VLAN of untagged traffic on a vlan-aware switch0 port without a `pvid`.
    public static let defaultVLAN = 1

    public var hasSwitch0: Bool
    /// `interfaces switch switch0 switch-port vlan-aware enable`.
    public var vlanAware: Bool
    /// switch0 member ports by name ("eth1").
    public var members: [String: SwitchMember]
    /// switch0 vifs, sorted by VLAN number.
    public var vifs: [Vif]
    /// `HW model` from `show version` ("EdgeRouter X 5-Port").
    public var model: String?

    public init(hasSwitch0: Bool = false, vlanAware: Bool = false, members: [String: SwitchMember] = [:],
                vifs: [Vif] = [], model: String? = nil) {
        self.hasSwitch0 = hasSwitch0
        self.vlanAware = vlanAware
        self.members = members
        self.vifs = vifs
        self.model = model
    }

    /// Netdeck can set port VLANs: there is a switch0 with vlan-aware switching.
    public var vlansEnabled: Bool { hasSwitch0 && vlanAware }

    public func vif(_ id: Int) -> Vif? { vifs.first { $0.id == id } }

    /// switch0 member ports that carry VLAN `id` (tagged or untagged), in port order. Without
    /// vlan-aware switching every member carries every VLAN.
    public func ports(carrying id: Int) -> [String] {
        let names = members.keys.sorted { EdgeOSParsers.portOrder($0, $1) }
        guard vlanAware else { return names }
        return names.filter { members[$0]?.vlanIDs.contains(id) ?? false }
    }
}

/// Front-panel traits of EdgeRouter models, from `HW model` in `show version`.
public enum EdgeOSModel {
    /// SFP cages by port number. Unknown models count as all copper.
    public static func kind(model: String?, number: Int) -> SwitchPort.Kind {
        let words = (model ?? "").lowercased().split(separator: " ").map(String.init)
        guard words.first == "edgerouter" else { return .copper }
        // EdgeRouter Infinity (ER-8-XG): SFP+ cages only.
        if words.contains("infinity") || words.contains("xg") || words.contains("8-xg") { return .sfp }
        let sfp: Set<Int>
        switch Array(words.dropFirst()) {
        case let rest where rest.contains("x") && rest.contains("sfp"): sfp = [5]   // ER-X-SFP
        case ["4"]: sfp = [3]                                                     // ER-4
        case ["6p"]: sfp = [5]                                                    // ER-6P
        case ["12"], ["12p"]: sfp = [10, 11]                                      // ER-12, ER-12P
        default: sfp = []
        }
        return sfp.contains(number) ? .sfp : .copper
    }
}
