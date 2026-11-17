import NetdeckCore
import SwiftUI

/// VLAN → palette color, stored per device by Netdeck (never written to the switch). §1.2
struct VLANColorMap: Equatable {
    var indexByName: [String: Int]   // index into VLANColor.palette; -1 = slate

    func color(_ vlan: String) -> VLANColor {
        guard let i = indexByName[vlan] else { return .slate }
        return i < 0 || i >= VLANColor.palette.count ? .slate : VLANColor.palette[i]
    }

    /// Assigns colors in VLAN-ID order, skipping colors already taken; "default" (VLAN 1) is slate.
    static func `default`(for snapshot: SwitchSnapshot, existing: [String: Int] = [:]) -> VLANColorMap {
        var map = existing
        var used = Set(map.values)
        let known: [Int: Int] = [100: 0, 150: 1, 10: 2, 20: 3, 30: 4, 40: 5]   // matches the design's sample mapping
        for v in snapshot.config.vlans.sorted(by: { ($0.vlanID ?? 0) < ($1.vlanID ?? 0) }) where map[v.name] == nil {
            if v.vlanID == 1 || v.name == "default" { map[v.name] = -1; continue }
            if let id = v.vlanID, let pref = known[id], !used.contains(pref) {
                map[v.name] = pref
            } else {
                map[v.name] = (0..<VLANColor.palette.count).first { !used.contains($0) } ?? 0
            }
            used.insert(map[v.name]!)
        }
        map["default"] = -1
        return VLANColorMap(indexByName: map)
    }
}

enum PanelBuilder {
    @MainActor
    static func ports(snapshot: SwitchSnapshot, session: DeviceSession?, colors: VLANColorMap) -> [PanelPort] {
        let trial = Set(session?.pending?.summary.compactMap { $0.split(separator: ":").first.map(String.init) } ?? [])
        return snapshot.ports.map { p in
            let edit = session?.edit(for: p.name)
            let vlans = edit?.vlans ?? p.vlans
            let enabled = edit?.enabled ?? !(p.configDisabled || !p.adminUp)
            var look: PanelPort.Look
            switch p.state {
            case .up: look = .up
            case .down, .warning: look = .down
            case .disabled: look = .disabled
            case .empty: look = .empty
            }
            if edit?.enabled != nil { look = enabled ? (p.linkUp ? .up : .down) : .disabled }
            let index = p.kind == .copper ? p.number : (InterfaceName.portNumber(p.name) ?? 0)
            let desc = (p.transceiver?.description ?? "").uppercased()
            var port = PanelPort(
                slotKey: p.slotKey, name: p.name, kind: p.kind == .copper ? .copper : .sfp, index: index, look: look,
                vlanBars: vlans.map { colors.color($0).base },
                warning: p.warning != nil, staged: edit != nil, onTrial: trial.contains(p.name),
                hasModule: p.transceiver != nil, isDAC: desc.contains("-CU") || desc.contains("DAC"))
            port.accessibility = accessibilityLabel(p, vlans: vlans)
            return port
        }
    }

    static func accessibilityLabel(_ p: SwitchPort, vlans: [String]) -> String {
        var parts = [t("Port %@", String(p.number))]
        switch p.state {
        case .up: parts.append(t("up"))
        case .down: parts.append(t("no link"))
        case .disabled: parts.append(t("disabled"))
        case .warning: parts.append(t("warning"))
        case .empty: parts.append(t("empty slot"))
        }
        if !vlans.isEmpty { parts.append("VLAN " + vlans.joined(separator: ", ")) }
        if let d = p.description { parts.append(d) }
        return parts.joined(separator: ", ")
    }
}
