import NetdeckCore
import SwiftUI

/// What is plugged into a port, as shown in callouts, rooms and the inspector.
struct PortPeer: Equatable {
    var name: String
    var named: Bool          // a user alias or an LLDP name, not just a MAC
    var sub: String
    var symbol: String
    var avatar: Avatar
    var mac: String?
    var macCount: Int
    var lldp: String?

    @MainActor
    static func of(_ port: SwitchPort, session: DeviceSession) -> PortPeer? {
        guard port.linkUp || !port.macs.isEmpty else { return nil }
        let macs = port.macs.map(\.mac)
        let anyAlias = macs.lazy.compactMap { session.alias(for: $0) }.first
        let lldp = port.lldp.first?.systemName
        // Several MACs on one port means something with devices behind it (modem, another switch):
        // name it by the port, not by one of the MACs behind it.
        let many = macs.count >= 4
        let alias = many ? nil : anyAlias
        let name = alias ?? lldp ?? port.description ?? macs.first ?? port.name
        let lower = name.lowercased()
        var symbol: String
        var avatar: Avatar
        if lower.contains("mac") && alias != nil { symbol = "laptopcomputer"; avatar = .lavender }
        else if macs.count >= 4 { symbol = "wifi.router"; avatar = .peach }
        else if lower.contains("idrac") || lower.contains("ipmi") || lower.contains("srv") || lower.contains("server") {
            symbol = "server.rack"; avatar = lower.contains("2") ? .mint : .sky
        } else { symbol = "desktopcomputer"; avatar = .slate }
        // An icon picked in Connected devices wins over the guess.
        if !many, let mac = macs.first(where: { session.alias(for: $0) != nil }), let picked = session.aliasIcon(for: mac) {
            symbol = picked
            avatar = DeviceIcon.avatar(for: picked, name: alias)
        }
        var subParts = [port.name]
        if macs.count > 1 { subParts.append(t("%@ MACs", String(macs.count))) }
        else if let d = port.description, d != name { subParts.append(d) }
        return PortPeer(name: name, named: alias != nil || lldp != nil, sub: subParts.joined(separator: " · "), symbol: symbol,
                        avatar: avatar, mac: macs.first, macCount: macs.count, lldp: lldp)
    }
}

/// Port counts used by the board header, the overview metrics and the summary.
struct PortStats {
    var up = 0, noLink = 0, disabled = 0, warnings = 0, enabled = 0, total = 0, devicesSeen = 0

    init(_ snap: SwitchSnapshot) {
        for p in snap.ports {
            total += 1
            switch p.state {
            case .up: up += 1
            case .down: noLink += 1
            case .disabled: disabled += 1
            case .warning: warnings += 1
            case .empty: break
            }
            if p.state != .disabled && p.state != .empty { enabled += 1 }
        }
        devicesSeen = Set(snap.macTable.map(\.mac)).count
    }
}

extension SwitchPort {
    var isEnabled: Bool { !(configDisabled || !adminUp) }
    var speedText: String {
        guard linkUp else { return "—" }
        if let speed, !speed.isEmpty { return speed }   // as the device reports it
        return kind == .copper ? t("%@ · full duplex", "1 Gbps") : "1 Gbps"
    }
    var isTopRow: Bool { kind == .copper && number % 2 == 0 }
}

func statusPill(_ p: SwitchPort, enabled: Bool) -> Pill {
    if !enabled { return Pill(text: t("Disabled"), kind: .outline) }
    switch p.state {
    case .up: return Pill(text: t("Up"), kind: .good, dot: true)
    case .warning: return Pill(text: t("Warning"), kind: .warn, icon: "exclamationmark.triangle.fill")
    case .disabled: return Pill(text: t("Disabled"), kind: .outline)
    case .down, .empty: return Pill(text: t("No link"), kind: .outline)
    }
}

/// Elbow leader line (§4.6): out from the panel, horizontal halfway, into the card; corners r 6.
func elbowPath(from a: CGPoint, to b: CGPoint, radius: CGFloat = 6) -> Path {
    var p = Path()
    p.move(to: a)
    let dx = b.x - a.x
    guard abs(dx) > 1 else { p.addLine(to: b); return p }
    let midY = (a.y + b.y) / 2
    let r = min(radius, abs(dx) / 2, abs(b.y - a.y) / 2)
    let sy: CGFloat = b.y > a.y ? 1 : -1, sx: CGFloat = dx > 0 ? 1 : -1
    p.addLine(to: CGPoint(x: a.x, y: midY - sy * r))
    p.addQuadCurve(to: CGPoint(x: a.x + sx * r, y: midY), control: CGPoint(x: a.x, y: midY))
    p.addLine(to: CGPoint(x: b.x - sx * r, y: midY))
    p.addQuadCurve(to: CGPoint(x: b.x, y: midY + sy * r), control: CGPoint(x: b.x, y: midY))
    p.addLine(to: b)
    return p
}

/// Spreads cards of width `w` along one row so they keep `gap` apart and stay inside `bounds`.
func spread(_ centers: [CGFloat], width w: CGFloat, gap: CGFloat, bounds: ClosedRange<CGFloat>) -> [CGFloat] {
    let order = centers.indices.sorted { centers[$0] < centers[$1] }
    var xs = order.map { centers[$0] }
    for i in xs.indices {
        xs[i] = max(xs[i], bounds.lowerBound + w / 2)
        if i > 0 { xs[i] = max(xs[i], xs[i - 1] + w + gap) }
    }
    for i in xs.indices.reversed() {
        xs[i] = min(xs[i], bounds.upperBound - w / 2)
        if i < xs.count - 1 { xs[i] = min(xs[i], xs[i + 1] - w - gap) }
    }
    var out = centers
    for (k, i) in order.enumerated() { out[i] = xs[k] }
    return out
}

/// The studio stage background (§2).
struct StageBackground: View {
    var radius: CGFloat = 14
    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(RadialGradient(stops: [.init(color: Theme.stageCenter, location: 0), .init(color: Theme.stageMid, location: 0.62),
                                             .init(color: Theme.stageEdge, location: 1)],
                                     center: .center, startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.6))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        }
    }
}
