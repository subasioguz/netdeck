import NetdeckCore
import SwiftUI

enum PanelFace: Hashable { case front, rear }
enum PortsMode: Hashable { case ports, rooms }

struct PortsScreen: View {
    @Environment(AppModel.self) private var model
    var device: DeviceProfile
    var session: DeviceSession
    @State private var hovered: String?

    private var state: Binding<PortsViewState> {
        Binding(get: { model.portsState[device.id] ?? PortsViewState() }, set: { model.portsState[device.id] = $0 })
    }
    private var selected: String? { state.wrappedValue.selected }
    private var face: PanelFace { state.wrappedValue.face }
    private var mode: PortsMode { state.wrappedValue.mode }
    private var showsList: Bool { state.wrappedValue.list }

    var body: some View {
        if let snap = session.snapshot {
            let colors = model.colors(for: device.id)
            VStack(spacing: 0) {
                header(snap)
                if face == .rear {
                    RearBoard(session: session, snapshot: snap, selected: state.rear)
                } else if showsList {
                    PortTable(snapshot: snap, session: session, colors: colors, selected: state.selected)
                        .frame(maxHeight: .infinity)
                    Rectangle().fill(Theme.border).frame(height: 1)
                    PortsInspectorHost(device: device, snapshot: snap, session: session, colors: colors, selected: state.selected)
                        .frame(height: 300)
                } else if mode == .rooms {
                    RoomsStage(snapshot: snap, session: session, colors: colors, selected: state.selected, editing: state.roomEditing) {
                        state.wrappedValue.selected = $0; state.wrappedValue.mode = .ports; state.wrappedValue.roomEditing = nil
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                } else {
                    FrontStage(device: device, snapshot: snap, session: session, colors: colors, selected: state.selected, hovered: $hovered)
                        .padding(.horizontal, 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .card()
            .background {
                if !RenderMode.active { ArrowKeyMonitor { move($0, snapshot: snap, colors: colors) } }
            }
        }
    }

    /// ←/→/↑/↓ (§6.9): moves the selection on the front or rear panel, or up and down the port list.
    private func move(_ key: ArrowKey, snapshot snap: SwitchSnapshot, colors: VLANColorMap) -> Bool {
        if face == .rear {
            guard let next = RearGeometry.neighbor(of: state.wrappedValue.rear, key) else { return key == .left || key == .right }
            state.wrappedValue.rear = next
            return true
        }
        if showsList {
            guard key == .up || key == .down else { return false }
            let keys = snap.ports.map(\.slotKey)
            let i = selected.flatMap { keys.firstIndex(of: $0) }
            let j = i.map { key == .down ? min($0 + 1, keys.count - 1) : max($0 - 1, 0) } ?? 0
            if keys.indices.contains(j) { state.wrappedValue.selected = keys[j] }
            return true
        }
        guard mode == .ports else { return false }
        let ports = PanelBuilder.ports(snapshot: snap, session: session, colors: colors)
        if let next = FrontGeometry.neighbor(of: selected, in: ports, key) {
            withAnimation(.easeOut(duration: 0.2)) { state.wrappedValue.selected = next }
        }
        return true
    }

    private func header(_ snap: SwitchSnapshot) -> some View {
        let stats = PortStats(snap)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(face == .front ? t("Front panel") : t("Rear panel")).font(Typo.cardTitle).foregroundStyle(Theme.text1)
                Text(face == .front ? t("48 copper ports (1G) · 4 SFP+ slots (10G)") : t("4 QSFP+ (40G) · management · console · power · fans"))
                    .font(Typo.caption).foregroundStyle(Theme.text3).lineLimit(1)
            }
            .layoutPriority(1)
            ViewThatFits(in: .horizontal) {
                pills(stats, all: true)
                pills(stats, all: false)
                Color.clear.frame(width: 0, height: 0)
            }
            Spacer(minLength: 8)
            Segmented(options: [(PanelFace.front, t("Front"), nil), (.rear, t("Rear"), nil)], selection: state.face, compact: true)
            Segmented(options: [(PortsMode.ports, t("Ports"), nil), (.rooms, t("Rooms"), "square.3.layers.3d")], selection: state.mode, compact: true)
                .disabled(face == .rear || showsList).opacity(face == .rear || showsList ? 0.5 : 1)
            Button { state.wrappedValue.list.toggle() } label: { Image(systemName: "list.bullet") }
                .buttonStyle(ToggleIconStyle(on: showsList)).help(t("List"))
                .disabled(face == .rear)
        }
        .padding(.horizontal, 16).frame(height: 54)
    }

    @ViewBuilder
    private func pills(_ s: PortStats, all: Bool) -> some View {
        HStack(spacing: 6) {
            if face == .front {
                Pill(text: t("%@ up", String(s.up)), kind: .good, dot: true)
                Pill(text: t("%@ no link", String(s.noLink)), kind: .outline)
                if all { Pill(text: t("%@ disabled", String(s.disabled)), kind: .outline) }
                if s.warnings > 0 {
                    Pill(text: Format.plural(s.warnings, t("%@ warning", "1"), t("%@ warnings", String(s.warnings))), kind: .warn,
                         icon: "exclamationmark.triangle.fill")
                }
            } else {
                Pill(text: t("%@ QSFP+ · no module", String(session.snapshot?.rearPorts.filter { !$0.linkUp }.count ?? 4)), kind: .outline)
                Pill(text: t("Console connected"), kind: .accent, icon: "terminal")
                if all { Pill(text: t("Power and fans OK"), kind: .good, dot: true) }
            }
        }
    }
}

struct ToggleIconStyle: ButtonStyle {
    var on: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(on ? Theme.onPrimary : Theme.text2)
            .frame(width: 30, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Theme.primary : Theme.surface3))
            .contentShape(Rectangle())
    }
}

// MARK: - Front stage: faceplate, callouts, legend, inspector with notch

struct FrontStage: View {
    @Environment(AppModel.self) private var model
    var device: DeviceProfile
    var snapshot: SwitchSnapshot
    var session: DeviceSession
    var colors: VLANColorMap
    @Binding var selected: String?
    @Binding var hovered: String?

    private let above: CGFloat = 74, below: CGFloat = 54, legend: CGFloat = 44, side: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let stageW = geo.size.width
            let panelW = stageW - side * 2
            let s = PanelScale(width: panelW)
            let ports = PanelBuilder.ports(snapshot: snapshot, session: session, colors: colors)
            let panelH = panelW * FrontGeometry.height(hasCables: ports.contains { $0.isDAC }) / (FrontGeometry.maxX - FrontGeometry.minX)
            let stageH = above + panelH + below + legend
            let notchX: CGFloat? = selected.flatMap { key in ports.first { $0.slotKey == key } }
                .map { side + s.x(FrontGeometry.rect(for: $0).midX) }
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    StageBackground()
                    FloorShadow().frame(width: panelW * 0.9, height: 18)
                        .position(x: stageW / 2, y: above + s.y(FrontGeometry.chassisHeight) - 4)
                    FrontPanelView(model: snapshot.model, vendor: "Juniper", hostname: device.name, ports: ports,
                                   selected: Set([selected].compactMap { $0 }), hovered: hovered,
                                   onTap: { p in withAnimation(.easeOut(duration: 0.2)) { selected = selected == p.slotKey ? nil : p.slotKey } },
                                   onHover: { hovered = $0?.slotKey })
                        .frame(width: panelW, height: panelH)
                        .offset(x: side, y: above)
                    Callouts(snapshot: snapshot, session: session, ports: ports, s: s, origin: CGPoint(x: side, y: above),
                             stageWidth: stageW, selected: selected, hovered: hovered) { key in
                        withAnimation(.easeOut(duration: 0.2)) { selected = key }
                    }
                    Legend(snapshot: snapshot, session: session, colors: colors)
                        .frame(width: stageW - 32, height: legend)
                        .offset(x: 16, y: stageH - legend)
                    if let notchX {
                        Notch().fill(Theme.surface)
                            .overlay(Notch(open: true).stroke(Theme.border, lineWidth: 1))
                            .frame(width: 26, height: 10)
                            .offset(x: notchX - 13, y: stageH - 10)
                            .animation(.easeOut(duration: 0.2), value: notchX)
                    }
                }
                .frame(height: stageH)
                PortsInspectorHost(device: device, snapshot: snapshot, session: session, colors: colors, selected: $selected)
                    .padding(.horizontal, -12)
            }
        }
    }
}

struct PortsInspectorHost: View {
    var device: DeviceProfile
    var snapshot: SwitchSnapshot
    var session: DeviceSession
    var colors: VLANColorMap
    @Binding var selected: String?

    var body: some View {
        GeometryReader { geo in
            NDScroll {
                if let p = session.pending {
                    TrialInspector(session: session, pending: p)
                } else if let key = selected, let port = snapshot.ports.first(where: { $0.slotKey == key }) {
                    PortInspector(device: device, port: port, session: session, colors: colors, snapshot: snapshot, compact: geo.size.width < 1100)
                } else {
                    NothingSelected(snapshot: snapshot, session: session) { selected = $0 }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Rotated-square notch (§2), drawn as the upper half so it pokes into the stage.
struct Notch: Shape {
    var open = false
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX - 2, y: r.minY + 1))
        p.addQuadCurve(to: CGPoint(x: r.midX + 2, y: r.minY + 1), control: CGPoint(x: r.midX, y: r.minY - 1))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        if !open { p.closeSubpath() }
        return p
    }
}

struct FloorShadow: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Ellipse().fill(Color.black.opacity(scheme == .dark ? 0.7 : 0.22)).blur(radius: 14)
    }
}

struct Callouts: View {
    var snapshot: SwitchSnapshot
    var session: DeviceSession
    var ports: [PanelPort]
    var s: PanelScale
    var origin: CGPoint
    var stageWidth: CGFloat
    var selected: String?
    var hovered: String?
    var onSelect: (String) -> Void

    private let cw: CGFloat = 196, ch: CGFloat = 40

    struct Item { var key: String; var peer: PortPeer; var anchor: CGPoint; var top: Bool; var warning: Bool }

    var body: some View {
        let all = items()
        let dense = all.count > 6
        let shown = dense ? all.filter { $0.key == selected || $0.key == hovered } : all
        let topRow = shown.filter(\.top), bottomRow = shown.filter { !$0.top && !$0.warning }
        let bounds = (14 + 0)...(stageWidth - 14)
        let topX = spread(topRow.map(\.anchor.x), width: cw, gap: 12, bounds: bounds)
        let botX = spread(bottomRow.map(\.anchor.x), width: cw, gap: 12, bounds: bounds)
        let panelTop = origin.y, panelBottom = origin.y + s.y(FrontGeometry.chassisHeight)
        ZStack(alignment: .topLeading) {
            if dense {
                ForEach(all.filter { item in !shown.contains { $0.key == item.key } }, id: \.key) { item in
                    Circle().fill(item.peer.avatar.ink.opacity(0.8)).frame(width: 8, height: 8)
                        .position(x: item.anchor.x, y: item.top ? panelTop - 8 : panelBottom + 8)
                }
            }
            ForEach(Array(topRow.enumerated()), id: \.element.key) { i, item in
                callout(item, center: CGPoint(x: topX[i], y: panelTop - 64 + ch / 2), from: CGPoint(x: item.anchor.x, y: panelTop))
            }
            ForEach(Array(bottomRow.enumerated()), id: \.element.key) { i, item in
                callout(item, center: CGPoint(x: botX[i], y: panelBottom + 16 + ch / 2), from: CGPoint(x: item.anchor.x, y: panelBottom))
            }
            dacCallout(panelBottom: panelBottom)
        }
        .frame(width: stageWidth, alignment: .topLeading)
    }

    private func items() -> [Item] {
        ports.compactMap { pp -> Item? in
            guard pp.kind == .copper, let sp = snapshot.ports.first(where: { $0.slotKey == pp.slotKey }),
                  let peer = PortPeer.of(sp, session: session) else { return nil }
            let top = FrontGeometry.isTopRow(pp.index)
            let a = FrontGeometry.anchor(for: pp, below: !top)
            return Item(key: pp.slotKey, peer: peer, anchor: CGPoint(x: origin.x + s.x(a.x), y: origin.y + s.y(a.y)), top: top, warning: false)
        }
    }

    private func callout(_ item: Item, center: CGPoint, from a: CGPoint) -> some View {
        let isSel = item.key == selected
        let edge = CGPoint(x: center.x, y: item.top ? center.y + ch / 2 : center.y - ch / 2)
        return ZStack(alignment: .topLeading) {
            elbowPath(from: a, to: edge).stroke(isSel ? Theme.accent : Theme.borderStrong, lineWidth: 1.2)
            Circle().strokeBorder(isSel ? Theme.accent : Theme.borderStrong, lineWidth: 1.2).background(Circle().fill(Theme.surface))
                .frame(width: 6, height: 6).position(a)
            Button { onSelect(item.key) } label: {
                CalloutCard(peer: item.peer, selected: isSel).frame(width: cw, height: ch)
            }
            .buttonStyle(.plain)
            .position(center)
        }
    }

    @ViewBuilder
    private func dacCallout(panelBottom: CGFloat) -> some View {
        let dacs = ports.filter { $0.isDAC }
        if !dacs.isEmpty {
            let warn = dacs.contains { $0.warning }
            let xs = dacs.map { origin.x + s.x(FrontGeometry.cageRect($0.index).midX) }
            let cableEnd = origin.y + s.y(FrontGeometry.chassisHeight + FrontGeometry.cableDrop)
            let cx = min(xs.reduce(0, +) / CGFloat(xs.count), stageWidth - 14 - 110)
            let names = dacs.compactMap { d in snapshot.ports.first { $0.slotKey == d.slotKey }?.name }
            let title = Self.dacTitle(dacs.compactMap { d in snapshot.ports.first { $0.slotKey == d.slotKey }?.transceiver })
            HStack(spacing: 8) {
                AvatarCircle(symbol: "cable.connector", avatar: .slate, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text1)
                    Text(names.joined(separator: ", ")).font(Typo.micro).foregroundStyle(Theme.text3)
                }
                .lineLimit(1)
                if warn { Pill(text: t("Warning"), kind: .warn) }
            }
            .padding(.horizontal, 8).frame(height: ch)
            .card(radius: 12, raised: true)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(warn ? Theme.warnLine : .clear, lineWidth: 1))
            .fixedSize()
            .position(x: cx, y: cableEnd + 4 + ch / 2)
        }
    }
}

extension Callouts {
    /// Title of the cable callout from the plugged-in modules (§9 "2× MikroTik 25G DAC" pattern):
    /// "2× 25G DAC" when they match, "25G DAC, 10G DAC" when they differ, the part description
    /// when it can't be shortened, "DAC" when nothing is known.
    static func dacTitle(_ modules: [HardwareInfo.Transceiver]) -> String {
        let names = modules.map { $0.shortName ?? $0.description }.filter { !$0.isEmpty }
        guard let first = names.first else { return "DAC" }
        let distinct = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if distinct.count == 1 { return names.count == 1 ? first : t("%@× %@", String(names.count), first) }
        return distinct.map { n in
            let c = names.filter { $0 == n }.count
            return c == 1 ? n : t("%@× %@", String(c), n)
        }.joined(separator: ", ")
    }
}

struct CalloutCard: View {
    var peer: PortPeer
    var selected: Bool
    var body: some View {
        HStack(spacing: 8) {
            AvatarCircle(symbol: peer.symbol, avatar: peer.avatar, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text1)
                Text(peer.sub).font(Typo.micro).foregroundStyle(Theme.text3)
            }
            .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(radius: 12, raised: true)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5))
        .help(peer.name + " · " + peer.sub)
    }
}

// MARK: - Legend (§4.5)

struct Legend: View {
    var snapshot: SwitchSnapshot
    var session: DeviceSession
    var colors: VLANColorMap

    var body: some View {
        let used = Set(snapshot.ports.filter { $0.isEnabled }.flatMap(\.vlans))
        let vlans = snapshot.config.vlans.filter { used.contains($0.name) }.sorted { ($0.vlanID ?? 0) < ($1.vlanID ?? 0) }
        HStack(spacing: 10) {
            Text(t("VLAN")).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text3)
            ViewThatFits(in: .horizontal) {
                chips(vlans, max: vlans.count)
                chips(vlans, max: 4)
                chips(vlans, max: 2)
            }
            Rectangle().fill(Theme.border).frame(width: 1, height: 16)
            glyph(.up, t("Up")); glyph(.down, t("No link")); glyph(.disabled, t("Disabled")); glyph(.warning, t("Warning"))
            HStack(spacing: 5) {
                Circle().fill(session.pending != nil ? Theme.HW.ledAmber : Theme.HW.metalAccent).frame(width: 12, height: 12)
                    .overlay(Image(systemName: session.pending != nil ? "clock" : "pencil").font(.system(size: 6.5, weight: .bold)).foregroundStyle(.white))
                Text(session.pending != nil ? t("On trial") : t("Change staged"))
            }
            Spacer(minLength: 6)
            Text(t("Top row even, bottom row odd numbers")).foregroundStyle(Theme.text3).lineLimit(1).layoutPriority(-1)
        }
        .font(.system(size: 11.5)).foregroundStyle(Theme.text2)
    }

    private func chips(_ vlans: [JunosConfig.VLAN], max: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(vlans.prefix(max)) { v in VLANChip(name: v.name, vlanID: nil, color: colors.color(v.name), size: .small) }
            if vlans.count > max { Text("+\(vlans.count - max)").foregroundStyle(Theme.text3) }
        }
    }

    enum Glyph { case up, down, disabled, warning }

    private func glyph(_ g: Glyph, _ label: String) -> some View {
        HStack(spacing: 5) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 2).fill(g == .disabled ? Color(hex: 0x4A525A) : Color(hex: 0x0A0C0E))
                if g == .disabled {
                    Canvas { ctx, size in
                        var p = Path()
                        stride(from: -size.height, to: size.width, by: 3).forEach { x in
                            p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0))
                        }
                        ctx.stroke(p, with: .color(Color(hex: 0x2B3036)), lineWidth: 1.4)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                if g == .up { RoundedRectangle(cornerRadius: 0.8).fill(Theme.HW.ledGreen).frame(width: 4, height: 2.5).offset(x: 1.5, y: 1.5) }
                if g == .warning { RoundedRectangle(cornerRadius: 0.8).fill(Theme.HW.ledAmber).frame(width: 4, height: 2.5).offset(x: 10.5, y: 1.5) }
            }
            .frame(width: 16, height: 12)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.borderStrong, lineWidth: 0.5))
            Text(label)
        }
        .fixedSize()
    }
}
