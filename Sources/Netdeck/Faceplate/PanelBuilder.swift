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
        let junos = snapshot.junosModel
        let ports: [PanelPort] = snapshot.ports.map { p in
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
            let index = p.number
            let desc = (p.transceiver?.description ?? "").uppercased()
            var port = PanelPort(
                slotKey: p.slotKey, name: p.name, kind: p.kind == .copper ? .copper : .sfp, index: index, look: look,
                vlanBars: vlans.map { colors.color($0).base },
                warning: p.warning != nil, staged: edit != nil, onTrial: trial.contains(p.name),
                hasModule: p.transceiver != nil, isDAC: desc.contains("-CU") || desc.contains("DAC"))
            port.accessibility = accessibilityLabel(p, vlans: vlans)
            port.label = p.label ?? String(p.number)
            return port
        }
        if let spec = FaceplateCatalog.spec(forModel: snapshot.model) { return arrange(ports, spec: spec, junos: junos) }
        return arrange(ports, junos: junos)
    }

    /// Cage group of a port: Junos PIC and media ("2/xe"), else the name without its digits ("sfp-sfpplus").
    static func group(_ name: String) -> String {
        let media = String(name.prefix { !$0.isNumber })
        let parts = name.split(separator: "/")
        return parts.count == 3 ? "\(parts[1])/" + media.replacingOccurrences(of: "ge-", with: "xe-") : media
    }

    /// Places ports on the panel (§5): copper first, in blocks of 12 on two rows with the first port on
    /// top (eight or fewer copper ports sit in one row), then each group of cages in a row, or two rows
    /// when there are more than eight. EX4300-48T comes out exactly as in the design; a model with more
    /// ports than fit gets a wider chassis.
    static func arrange(_ ports: [PanelPort], junos: JunosModel?) -> [PanelPort] {
        var out = ports
        let copper = out.indices.filter { out[$0].kind == .copper }
        var x = FrontGeometry.firstPortX
        if !copper.isEmpty {
            if copper.count <= 8 {
                for (i, idx) in copper.enumerated() {
                    out[idx].frame = CGRect(x: x + CGFloat(i) * 27, y: 47, width: 24, height: 20)
                    out[idx].top = true
                    out[idx].block = 0
                }
            } else {
                for (i, idx) in copper.enumerated() {
                    let b = i / 12, k = i % 12, col = k / 2, row = k % 2
                    out[idx].frame = CGRect(x: x + CGFloat(b) * 172 + CGFloat(col) * 27, y: row == 0 ? 35 : 60, width: 24, height: 20)
                    out[idx].top = row == 0
                    out[idx].block = b
                }
            }
            x = copper.map { out[$0].frame.maxX }.max() ?? x
        }

        var groups: [(key: String, indices: [Int])] = []
        for idx in out.indices where out[idx].kind == .sfp {
            let key = group(out[idx].name)
            if let g = groups.firstIndex(where: { $0.key == key }) { groups[g].indices.append(idx) } else { groups.append((key, [idx])) }
        }
        var first = copper.isEmpty
        for g in groups {
            let plate = plate(for: g.key, count: g.indices.count, junos: junos)
            x += first ? 0 : (plate != nil ? 32.5 : 24)
            first = false
            if g.indices.count <= 8 {
                for (i, idx) in g.indices.enumerated() {
                    out[idx].frame = CGRect(x: x + CGFloat(i) * 43, y: 47, width: 36, height: 22)
                    out[idx].top = false
                    out[idx].plate = plate
                }
            } else {
                for (i, idx) in g.indices.enumerated() {
                    let col = i / 2, row = i % 2, b = i / 12
                    out[idx].frame = CGRect(x: x + CGFloat(col) * 40 + CGFloat(b) * 8, y: row == 0 ? 30 : 64, width: 36, height: 22)
                    out[idx].top = row == 0
                    out[idx].plate = plate
                }
            }
            x = g.indices.map { out[$0].frame.maxX }.max() ?? x
            if plate != nil { x += 18.5 }
        }
        return out
    }

    /// EX4300 uplink module (PIC 2) gets a plate; built-in cages don't.
    static func plate(for groupKey: String, count: Int, junos: JunosModel?) -> PanelPlate? {
        guard let junos, junos.rearPIC != nil, groupKey.hasPrefix("2/") else { return nil }
        return PanelPlate(title: count == 4 ? t("4× SFP+ 10G") : "\(count)× SFP+", tag: "PIC 2")
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

// MARK: - Known models (FaceplateCatalog)

/// A part of the panel that isn't a network port: console, management, USB, reset, DC input, an
/// auxiliary cage, or an empty module slot.
struct PanelDecoration: Equatable {
    var kind: String
    var frame: CGRect
    var label: String
}

/// Where everything of a known model sits, computed from its spec alone so it doesn't depend on which
/// ports a reading happened to list. Ports the spec doesn't name go into the first module slot.
struct SpecLayout {
    struct Slot { var frame: CGRect; var top: Bool; var block: Int; var label: String; var cage: Bool }
    var slots: [String: Slot] = [:]
    var decorations: [PanelDecoration] = []
    /// Module slots (the plate rectangle) and the module name printed on it.
    var modules: [(rect: CGRect, title: String)] = []
    var endX: CGFloat = FrontGeometry.firstPortX
}

extension PanelBuilder {
    static let decorationSizes: [String: CGSize] = [
        "console-rj45": CGSize(width: 24, height: 20), "mgmt-rj45": CGSize(width: 24, height: 20), "aux": CGSize(width: 24, height: 20),
        "console-usb": CGSize(width: 12, height: 7), "console-db9": CGSize(width: 30, height: 14), "usb": CGSize(width: 20, height: 9),
        "reset": CGSize(width: 6, height: 6), "power-dc": CGSize(width: 14, height: 14), "sfp-aux": CGSize(width: 36, height: 22),
    ]
    /// Module slot plate: room for 4 cages in a row or 8 on two rows (as the EX4300 uplink module).
    static let moduleSize = CGSize(width: 202, height: 76)

    /// One group laid out from x = 0.
    private struct Piece {
        var group: FaceplateSpec.Group
        var width: CGFloat
        var slots: [(name: String, slot: SpecLayout.Slot)] = []
    }

    static func layout(_ spec: FaceplateSpec) -> SpecLayout {
        var blockID = 0
        var pieces: [Piece] = spec.groups.map { g in
            if g.isModuleSlot { return Piece(group: g, width: moduleSize.width) }
            guard let pattern = g.names else { return Piece(group: g, width: (decorationSizes[g.kind] ?? CGSize(width: 24, height: 20)).width) }
            let names = FaceplateCatalog.expand(pattern)
            let labels = (g.labels?.count == names.count ? g.labels : nil)
                ?? names.map { n in String(n.reversed().prefix { $0.isNumber }.reversed()) }
            let rows = max(1, min(2, g.rows ?? (names.count > 8 ? 2 : 1)))
            let order = rows == 1 ? .singleRow : (g.order ?? .topEven)
            let size = g.isCage ? (g.isWide ? CGSize(width: 44, height: 24) : CGSize(width: 36, height: 22)) : CGSize(width: 24, height: 20)
            let pitch: CGFloat = g.isCage ? (g.isWide ? 50 : (rows == 2 ? 40 : 43)) : 27
            let gap: CGFloat = g.isCage ? 8 : 10
            let half = (names.count + 1) / 2
            // Block of each column: from blockSizes (in ports), else every `block` ports.
            func blockOf(column col: Int) -> Int {
                let port = col * rows
                if let sizes = g.blockSizes, !sizes.isEmpty {
                    var end = 0
                    for (b, n) in sizes.enumerated() { end += n; if port < end { return b } }
                    return sizes.count - 1
                }
                let per = g.block ?? (g.isCage ? 0 : 12)
                return per > 0 ? port / per : 0
            }
            var piece = Piece(group: g, width: 0)
            for (i, name) in names.enumerated() {
                let (row, col): (Int, Int)
                switch order {
                case .topEven, .topOdd: (row, col) = (i % 2, i / 2)
                case .bottomFirst: (row, col) = (1 - i % 2, i / 2)
                case .topFirstHalf: (row, col) = i < half ? (0, i) : (1, i - half)
                case .singleRow: (row, col) = (0, i)
                }
                let b = blockOf(column: col)
                let x = CGFloat(col) * pitch + CGFloat(b) * gap
                let y: CGFloat = rows == 1 ? (g.isCage ? 47 : 47) : (g.isCage ? (row == 0 ? 30 : 64) : (row == 0 ? 35 : 60))
                let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
                piece.slots.append((name, .init(frame: frame, top: rows == 1 ? !g.isCage : row == 0, block: blockID + b, label: labels[i], cage: g.isCage)))
                piece.width = max(piece.width, frame.maxX)
            }
            blockID += 100
            return piece
        }

        // Left, center and right parts of the panel, each in spec order.
        func zone(_ p: Piece) -> Int { p.group.position == "right" ? 2 : (p.group.position == "center" ? 1 : 0) }
        let gap: CGFloat = 20
        func width(_ z: Int) -> CGFloat {
            let ps = pieces.filter { zone($0) == z }
            return ps.map(\.width).reduce(0, +) + gap * CGFloat(max(0, ps.count - 1))
        }
        let leftEnd = FrontGeometry.firstPortX + width(0)
        let centerStart = width(1) == 0 ? leftEnd : max(leftEnd + gap, 500 - width(1) / 2)
        let centerEnd = centerStart + width(1)
        let rightStart = width(2) == 0 ? centerEnd : max(centerEnd + gap, (1000 - 27.5) - width(2))
        var cursor = [FrontGeometry.firstPortX, centerStart, rightStart]

        var out = SpecLayout()
        for k in pieces.indices {
            let p = pieces[k], z = zone(p), x0 = cursor[z]
            cursor[z] += p.width + gap
            if p.group.isModuleSlot {
                out.modules.append((CGRect(x: x0, y: 21, width: moduleSize.width, height: moduleSize.height), p.group.label ?? ""))
            } else if p.group.isNetwork {
                for (name, var slot) in p.slots {
                    slot.frame.origin.x += x0
                    out.slots[name] = slot
                }
            } else {
                let size = decorationSizes[p.group.kind] ?? CGSize(width: 24, height: 20)
                let label: String = {
                    switch p.group.kind {
                    case "console-rj45", "console-usb", "console-db9": return "CON"
                    case "mgmt-rj45": return "MGMT"
                    case "usb": return "USB"
                    case "reset": return "RST"
                    case "power-dc": return "DC"
                    default: return (p.group.label ?? "").uppercased()
                    }
                }()
                out.decorations.append(PanelDecoration(kind: p.group.kind, frame: CGRect(x: x0, y: 57 - size.height / 2, width: size.width, height: size.height), label: label))
            }
            out.endX = max(out.endX, x0 + p.width)
        }
        pieces.removeAll()
        return out
    }

    /// "GigabitEthernet1/0/3" → "1/0/3", "xe-0/2/1" → "0/2/1"; nil for names without slashes.
    static func pathKey(_ name: String) -> String? {
        guard name.contains("/") else { return nil }
        return String(name.drop { !$0.isNumber })
    }

    /// Places ports of a known model by its spec. Ports the spec doesn't name go onto the first module
    /// slot (uplink modules), or after everything else when the model has none.
    static func arrange(_ ports: [PanelPort], spec: FaceplateSpec, junos: JunosModel?) -> [PanelPort] {
        let l = layout(spec)
        var out = ports
        var rest: [Int] = []
        for i in out.indices {
            let p = out[i]
            // Exact name; for Junos the same FPC/PIC/port under another media prefix (ge-/xe-/et-);
            // elsewhere the same slot path when the kind matches (Te1/1/1 on a -4X model for Gi1/1/1).
            let slot = l.slots[p.name] ?? l.slots[p.slotKey] ?? l.slots.first { name, s in
                if junos != nil { return name.contains("-") && SwitchSnapshot.slotKey(name) == p.slotKey }
                return pathKey(name) != nil && pathKey(name) == pathKey(p.name) && s.cage == (p.kind == .sfp)
            }?.value
            guard let slot else { rest.append(i); continue }
            // Keep the spec's position; the size follows what the port really is.
            let size = p.kind == .copper ? CGSize(width: 24, height: 20) : (slot.frame.width >= 44 ? CGSize(width: 44, height: 24) : CGSize(width: 36, height: 22))
            out[i].frame = CGRect(x: slot.frame.midX - size.width / 2, y: slot.frame.midY - size.height / 2, width: size.width, height: size.height)
            out[i].top = slot.top
            out[i].block = slot.block
            out[i].label = slot.label
        }
        guard !rest.isEmpty else { return out }
        if let module = l.modules.first {
            let plate = PanelPlate(title: module.title.isEmpty ? "\(rest.count)×" : module.title, tag: "")
            let twoRows = rest.count > 4
            for (k, i) in rest.prefix(8).enumerated() {
                let col = twoRows ? k / 2 : k, row = twoRows ? k % 2 : 0
                out[i].frame = CGRect(x: module.rect.minX + 18.5 + CGFloat(col) * 43, y: twoRows ? (row == 0 ? 30 : 64) : 47, width: 36, height: 22)
                out[i].top = twoRows && row == 0
                out[i].block = 9000
                out[i].plate = plate
            }
            rest = Array(rest.dropFirst(8))
            guard !rest.isEmpty else { return out }
        }
        var extras = arrange(rest.map { out[$0] }, junos: junos)
        let shift = (l.endX + 24) - (extras.map(\.frame.minX).min() ?? l.endX)
        for k in extras.indices { extras[k].frame.origin.x += shift; extras[k].block += 1000; extras[k].plate = nil }
        for (k, i) in rest.enumerated() { out[i] = extras[k] }
        return out
    }
}
