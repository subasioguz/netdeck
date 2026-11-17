import NetdeckCore
import SwiftUI

/// Selectable parts of the rear panel (§3.4, §5.5).
enum RearItem: Hashable {
    case psu(Int), fan(Int), qsfp(Int), mgmt, con, usb
}

enum RearGeometry {
    static let minX: CGFloat = -2, maxX: CGFloat = 1002, minY: CGFloat = -2, maxY: CGFloat = 120
    static var aspect: CGFloat { (maxX - minX) / (maxY - minY) }

    static func rect(_ item: RearItem) -> CGRect {
        switch item {
        case let .psu(i): return CGRect(x: 14 + CGFloat(i) * 156, y: 12, width: 150, height: 94)
        case let .fan(i): return CGRect(x: 336 + CGFloat(i) * 112, y: 12, width: 104, height: 94)
        case let .qsfp(i): return CGRect(x: 588 + CGFloat(i) * 54, y: 44, width: 46, height: 26)
        case .mgmt: return CGRect(x: 820, y: 47, width: 24, height: 20)
        case .con: return CGRect(x: 868, y: 47, width: 24, height: 20)
        case .usb: return CGRect(x: 912, y: 52, width: 20, height: 9)
        }
    }

    static let items: [RearItem] = [.psu(0), .psu(1), .fan(0), .fan(1), .qsfp(0), .qsfp(1), .qsfp(2), .qsfp(3), .mgmt, .con, .usb]
}

struct RearScale {
    let k: CGFloat
    init(width: CGFloat) { k = width / (RearGeometry.maxX - RearGeometry.minX) }
    func x(_ u: CGFloat) -> CGFloat { (u - RearGeometry.minX) * k }
    func y(_ u: CGFloat) -> CGFloat { (u - RearGeometry.minY) * k }
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: self.x(x), y: self.y(y)) }
    func rect(_ r: CGRect) -> CGRect { CGRect(x: x(r.minX), y: y(r.minY), width: r.width * k, height: r.height * k) }
}

/// The EX4300 rear panel, drawn in one Canvas in the same style as `FrontPanelView`.
struct RearPanelView: View {
    var hostname: String
    var psuPresent: [Bool] = [true, false]
    var consoleConnected = true
    var mgmtLink = false
    var qsfpLinks: [Bool] = [false, false, false, false]
    var selected: RearItem?
    var onTap: ((RearItem) -> Void)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let s = RearScale(width: geo.size.width)
            Canvas { ctx, _ in draw(&ctx, s) }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { loc in
                    let u = CGPoint(x: loc.x / s.k + RearGeometry.minX, y: loc.y / s.k + RearGeometry.minY)
                    if let hit = RearGeometry.items.first(where: { RearGeometry.rect($0).insetBy(dx: -3, dy: -4).contains(u) }) { onTap?(hit) }
                }
        }
        .aspectRatio(RearGeometry.aspect, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t("Rear panel"))
    }

    private func lg(_ stops: [(UInt32, CGFloat)], _ a: CGPoint, _ b: CGPoint) -> GraphicsContext.Shading {
        .linearGradient(Gradient(stops: stops.map { .init(color: Color(hex: $0.0), location: $0.1) }), startPoint: a, endPoint: b)
    }

    private func text(_ ctx: inout GraphicsContext, _ s: RearScale, _ str: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat,
                      color: Color = Theme.HW.plateLabel, weight: Font.Weight = .semibold, anchor: UnitPoint = .leading) {
        ctx.draw(Text(str).font(.system(size: size * s.k, weight: weight)).foregroundColor(color), at: s.pt(x, y), anchor: anchor)
    }

    private func led(_ ctx: inout GraphicsContext, _ s: RearScale, _ r: CGRect, _ color: Color, glow: Bool) {
        let p = Path(roundedRect: s.rect(r), cornerRadius: 0.7 * s.k)
        if glow {
            var g = ctx
            g.addFilter(.shadow(color: color, radius: 1.6 * s.k))
            g.fill(p, with: .color(color))
        }
        ctx.fill(p, with: .color(color))
    }

    private func screw(_ ctx: inout GraphicsContext, _ s: RearScale, _ c: CGPoint, r: CGFloat = 3.6) {
        let rect = CGRect(x: s.x(c.x - r), y: s.y(c.y - r), width: 2 * r * s.k, height: 2 * r * s.k)
        ctx.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [Color(hex: 0xE9ECEF), Color(hex: 0x9BA4AC), Color(hex: 0x626B73)]),
                                                                center: CGPoint(x: rect.midX - rect.width * 0.15, y: rect.midY - rect.height * 0.15), startRadius: 0, endRadius: rect.width * 0.6))
        var cross = Path()
        cross.move(to: s.pt(c.x - r * 0.55, c.y)); cross.addLine(to: s.pt(c.x + r * 0.55, c.y))
        cross.move(to: s.pt(c.x, c.y - r * 0.55)); cross.addLine(to: s.pt(c.x, c.y + r * 0.55))
        ctx.stroke(cross, with: .color(Color(hex: 0x4B535B)), lineWidth: 0.7 * s.k)
    }

    private func draw(_ ctx: inout GraphicsContext, _ s: RearScale) {
        // Chassis
        let chassis = Path(roundedRect: s.rect(CGRect(x: 0, y: 0, width: 1000, height: 118)), cornerRadius: 2 * s.k)
        ctx.fill(chassis, with: lg([(0x3B4148, 0), (0x30363C, 0.07), (0x252A2F, 0.6), (0x1B1F23, 1)], s.pt(0, 0), s.pt(0, 118)))
        var brushed = Path()
        var yy: CGFloat = 1.3
        while yy < 118 { brushed.move(to: s.pt(0, yy)); brushed.addLine(to: s.pt(1000, yy)); yy += 1.3 }
        ctx.stroke(brushed, with: .color(.white.opacity(0.028)), lineWidth: 0.45 * s.k)
        ctx.fill(Path(s.rect(CGRect(x: 0, y: 0, width: 1000, height: 1.1))), with: .color(.white.opacity(0.16)))
        ctx.fill(Path(s.rect(CGRect(x: 0, y: 116.8, width: 1000, height: 1.2))), with: .color(.black.opacity(0.55)))
        if scheme == .dark { ctx.stroke(chassis, with: .color(.white.opacity(0.06)), lineWidth: 1) }

        for i in 0..<2 { drawPSU(&ctx, s, i) }
        for i in 0..<2 { drawFan(&ctx, s, i) }
        drawPortBlock(&ctx, s)
        if let sel = selected { drawSelection(&ctx, s, RearGeometry.rect(sel)) }
    }

    private func drawPSU(_ ctx: inout GraphicsContext, _ s: RearScale, _ i: Int) {
        let r = RearGeometry.rect(.psu(i))
        let plate = Path(roundedRect: s.rect(r), cornerRadius: 3 * s.k)
        ctx.fill(plate, with: lg([(0x2E343A, 0), (0x22272C, 1)], s.pt(0, r.minY), s.pt(0, r.maxY)))
        ctx.stroke(plate, with: .color(Color(hex: 0x0F1113)), lineWidth: 1 * s.k)
        guard psuPresent[i] else {
            screw(&ctx, s, CGPoint(x: r.minX + 10, y: r.midY)); screw(&ctx, s, CGPoint(x: r.maxX - 10, y: r.midY))
            text(&ctx, s, "PSU \(i) · EMPTY", r.midX, r.maxY - 9, size: 5.8, color: Theme.HW.plateLabelDim, anchor: .center)
            return
        }
        // Grille: hex holes
        let g = CGRect(x: r.minX + 8, y: r.minY + 9, width: 62, height: 74)
        ctx.fill(Path(roundedRect: s.rect(g), cornerRadius: 2 * s.k), with: .color(Color(hex: 0x15181B)))
        var holes = Path()
        var row = 0
        var hy = g.minY + 3.5
        while hy < g.maxY - 2 {
            var hx = g.minX + 3.5 + (row % 2 == 0 ? 0 : 2.5)
            while hx < g.maxX - 2 { holes.addEllipse(in: s.rect(CGRect(x: hx - 2, y: hy - 1.8, width: 4, height: 3.6))); hx += 5 }
            hy += 4.4; row += 1
        }
        ctx.fill(holes, with: .color(Color(hex: 0x050607)))
        // C14 inlet
        let inlet = CGRect(x: r.minX + 80, y: r.minY + 16, width: 26, height: 20)
        ctx.fill(Path(roundedRect: s.rect(inlet), cornerRadius: 3 * s.k), with: .color(Color(hex: 0x0B0D0F)))
        ctx.stroke(Path(roundedRect: s.rect(inlet), cornerRadius: 3 * s.k), with: .color(Color(hex: 0x4A525A)), lineWidth: 0.8 * s.k)
        for dx in [7.0, 13.0, 19.0] as [CGFloat] {
            ctx.fill(Path(s.rect(CGRect(x: inlet.minX + dx - 0.9, y: inlet.minY + (dx == 13 ? 5 : 9), width: 1.8, height: 6))), with: .color(Color(hex: 0xB9C1C8)))
        }
        // Handle
        var handle = Path()
        handle.move(to: s.pt(r.maxX - 34, r.minY + 50)); handle.addLine(to: s.pt(r.maxX - 34, r.maxY - 12))
        handle.addLine(to: s.pt(r.maxX - 12, r.maxY - 12)); handle.addLine(to: s.pt(r.maxX - 12, r.minY + 50))
        ctx.stroke(handle, with: .color(Color(hex: 0x7E8892)), style: StrokeStyle(lineWidth: 3.2 * s.k, lineCap: .round, lineJoin: .round))
        led(&ctx, s, CGRect(x: r.minX + 80, y: r.minY + 44, width: 5, height: 2.6), Theme.HW.ledGreen, glow: true)
        text(&ctx, s, "AC OK", r.minX + 88, r.minY + 45.3, size: 5.2)
        text(&ctx, s, "PSU \(i) · 350W", r.minX + 8, r.maxY - 5.5, size: 5.8)
    }

    private func drawFan(_ ctx: inout GraphicsContext, _ s: RearScale, _ i: Int) {
        let r = RearGeometry.rect(.fan(i))
        let plate = Path(roundedRect: s.rect(r), cornerRadius: 3 * s.k)
        ctx.fill(plate, with: lg([(0x2E343A, 0), (0x22272C, 1)], s.pt(0, r.minY), s.pt(0, r.maxY)))
        ctx.stroke(plate, with: .color(Color(hex: 0x0F1113)), lineWidth: 1 * s.k)
        let c = CGPoint(x: r.midX, y: r.minY + 42)
        let circle = CGRect(x: c.x - 34, y: c.y - 34, width: 68, height: 68)
        ctx.fill(Path(ellipseIn: s.rect(circle)), with: .color(Color(hex: 0x111417)))
        var holes = Path()
        var row = 0
        var hy = circle.minY + 3
        while hy < circle.maxY - 1 {
            var hx = circle.minX + 3 + (row % 2 == 0 ? 0 : 2.5)
            while hx < circle.maxX - 1 {
                if hypot(hx - c.x, hy - c.y) < 31 && hypot(hx - c.x, hy - c.y) > 9 {
                    holes.addEllipse(in: s.rect(CGRect(x: hx - 2, y: hy - 1.8, width: 4, height: 3.6)))
                }
                hx += 5
            }
            hy += 4.4; row += 1
        }
        ctx.fill(holes, with: .color(Color(hex: 0x030405)))
        ctx.stroke(Path(ellipseIn: s.rect(circle)), with: .color(Color(hex: 0x4A525A)), lineWidth: 0.8 * s.k)
        ctx.fill(Path(ellipseIn: s.rect(CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14))), with: lg([(0x4A525A, 0), (0x2A2F35, 1)], s.pt(0, c.y - 7), s.pt(0, c.y + 7)))
        led(&ctx, s, CGRect(x: r.minX + 6, y: r.minY + 5, width: 5, height: 2.6), Theme.HW.ledGreen, glow: true)
        text(&ctx, s, "FAN \(i)", r.minX + 6, r.maxY - 6, size: 5.6)
        text(&ctx, s, "AFO →", r.maxX - 6, r.maxY - 6, size: 5.6, color: Theme.HW.plateLabelDim, anchor: .trailing)
    }

    private func drawPortBlock(_ ctx: inout GraphicsContext, _ s: RearScale) {
        let plate = CGRect(x: 574, y: 21, width: 410, height: 76)
        let p = Path(roundedRect: s.rect(plate), cornerRadius: 3 * s.k)
        ctx.fill(p, with: lg([(0x2C3137, 0), (0x1F2327, 1)], s.pt(0, plate.minY), s.pt(0, plate.maxY)))
        ctx.stroke(p, with: .color(Color(hex: 0x0F1113)), lineWidth: 1 * s.k)
        text(&ctx, s, "4× QSFP+ 40G · PIC 1", 588, 30, size: 5.8)
        for i in 0..<4 {
            let r = RearGeometry.rect(.qsfp(i))
            let cage = Path(roundedRect: s.rect(r), cornerRadius: 1.5 * s.k)
            ctx.fill(cage, with: lg([(0xB9C1C8, 0), (0x8D969F, 0.5), (0x6B747D, 1)], s.pt(0, r.minY), s.pt(0, r.maxY)))
            ctx.fill(Path(roundedRect: s.rect(r.insetBy(dx: 2.2, dy: 2.2)), cornerRadius: 1 * s.k), with: .color(Color(hex: 0x050607)))
            ctx.fill(Path(s.rect(CGRect(x: r.midX - 4, y: r.maxY - 3.8, width: 8, height: 1.6))), with: .color(Color(hex: 0x8D969F)))
            led(&ctx, s, CGRect(x: r.midX - 2.5, y: 38.6, width: 5, height: 2.6), qsfpLinks[i] ? Theme.HW.ledGreen : Theme.HW.ledOff, glow: qsfpLinks[i])
            var bar = Path()
            bar.move(to: s.pt(r.minX + 2, 75.3)); bar.addLine(to: s.pt(r.maxX - 2, 75.3))
            ctx.stroke(bar, with: .color(Color(hex: 0x8B959E)), style: StrokeStyle(lineWidth: 2.6 * s.k, dash: [2 * s.k, 1.6 * s.k]))
            text(&ctx, s, "1/\(i)", r.midX, 86, size: 7.2, color: selected == .qsfp(i) ? Theme.HW.plateLabelSel : Theme.HW.plateLabel, anchor: .center)
        }
        rj45(&ctx, s, RearGeometry.rect(.mgmt), plug: nil)
        led(&ctx, s, CGRect(x: 821, y: 41.4, width: 4.4, height: 2.6), mgmtLink ? Theme.HW.ledGreen : Theme.HW.ledOff, glow: mgmtLink)
        text(&ctx, s, "MGMT", 832, 86, size: 6.2, anchor: .center)
        rj45(&ctx, s, RearGeometry.rect(.con), plug: consoleConnected ? Color(hex: 0x7FB8E6) : nil)
        text(&ctx, s, "CON", 880, 86, size: 6.2, anchor: .center)
        let usb = RearGeometry.rect(.usb)
        ctx.fill(Path(roundedRect: s.rect(usb), cornerRadius: 1 * s.k), with: lg([(0xB9C1C8, 0), (0x6B747D, 1)], s.pt(0, usb.minY), s.pt(0, usb.maxY)))
        ctx.fill(Path(s.rect(usb.insetBy(dx: 1.6, dy: 1.6))), with: .color(Color(hex: 0x050607)))
        ctx.fill(Path(s.rect(CGRect(x: usb.minX + 3, y: usb.minY + 2, width: usb.width - 6, height: 2.2))), with: .color(Color(hex: 0x2B6CD6)))
        text(&ctx, s, "USB", usb.midX, 86, size: 6.2, anchor: .center)
        screw(&ctx, s, CGPoint(x: 962, y: 40), r: 4.2)
        text(&ctx, s, "⏚", 962, 54, size: 7, anchor: .center)
    }

    private func rj45(_ ctx: inout GraphicsContext, _ s: RearScale, _ r: CGRect, plug: Color?) {
        let mouth = Path(roundedRect: s.rect(r), cornerRadius: 1.2 * s.k)
        ctx.fill(mouth, with: lg([(0x020304, 0), (0x101317, 1)], s.pt(0, r.minY), s.pt(0, r.maxY)))
        ctx.fill(Path(s.rect(CGRect(x: r.midX - 5.5, y: r.minY - 3, width: 11, height: 4))), with: .color(Color(hex: 0x020304)))
        ctx.stroke(mouth, with: .color(.black.opacity(0.7)), lineWidth: 0.6 * s.k)
        if let plug {
            let body = r.insetBy(dx: 1.6, dy: 1.6)
            ctx.fill(Path(roundedRect: s.rect(body), cornerRadius: 1.6 * s.k), with: .color(plug))
            ctx.fill(Path(ellipseIn: s.rect(CGRect(x: r.midX - 4.4, y: r.midY - 4.4, width: 8.8, height: 8.8))), with: .color(Color(hex: 0x4F8FC4)))
        } else {
            var pins = Path()
            for i in 0..<8 {
                let x = r.minX + 5.2 + CGFloat(i) * 1.95
                pins.move(to: s.pt(x, r.maxY - 4.2)); pins.addLine(to: s.pt(x, r.maxY - 1.2))
            }
            ctx.stroke(pins, with: .color(Color(hex: 0xB08E52).opacity(0.55)), lineWidth: 0.65 * s.k)
        }
    }

    private func drawSelection(_ ctx: inout GraphicsContext, _ s: RearScale, _ r: CGRect) {
        let ring = Path(roundedRect: s.rect(r.insetBy(dx: -2.8, dy: -2.8)), cornerRadius: 4 * s.k)
        ctx.stroke(ring, with: .color(Theme.HW.metalAccent.opacity(0.55)), lineWidth: 3.2 * s.k)
        ctx.stroke(ring, with: .color(.white), lineWidth: 1.5 * s.k)
    }
}

// MARK: - Rear board: stage with callouts, plus the inspector

struct RearBoard: View {
    var session: DeviceSession
    var snapshot: SwitchSnapshot
    @Binding var selected: RearItem?

    private struct Note { var item: RearItem; var title: String; var sub: String; var top: Bool; var pill: (String, PillKind)?; var symbol: String }

    var body: some View {
        let notes = callouts()
        VStack(spacing: 0) {
            GeometryReader { geo in
                let W = geo.size.width, panelW = W - 40
                let s = RearScale(width: panelW)
                let panelH = panelW / RearGeometry.aspect
                let y0: CGFloat = 74
                ZStack(alignment: .topLeading) {
                    StageBackground()
                    FloorShadow().frame(width: panelW * 0.9, height: 18).position(x: W / 2, y: y0 + panelH - 6)
                    RearPanelView(hostname: session.profile.name, qsfpLinks: snapshot.rearPorts.prefix(4).map(\.linkUp) + Array(repeating: false, count: max(0, 4 - snapshot.rearPorts.count)),
                                  selected: selected, onTap: { selected = $0 })
                        .frame(width: panelW, height: panelH).offset(x: 20, y: y0)
                    let tops = notes.filter(\.top), bots = notes.filter { !$0.top }
                    let ax: (Note) -> CGFloat = { n in 20 + s.x(n.item == .qsfp(0) ? 690 : RearGeometry.rect(n.item).midX) }
                    let tx = spread(tops.map(ax), width: Self.noteWidth, gap: 12, bounds: 14...(W - 14))
                    let bx = spread(bots.map(ax), width: Self.noteWidth, gap: 12, bounds: 14...(W - 14))
                    ForEach(Array(tops.enumerated()), id: \.offset) { i, n in
                        note(n, center: CGPoint(x: tx[i], y: y0 - 44), anchor: CGPoint(x: ax(n), y: y0 + s.y(0)))
                    }
                    ForEach(Array(bots.enumerated()), id: \.offset) { i, n in
                        note(n, center: CGPoint(x: bx[i], y: y0 + panelH + 36), anchor: CGPoint(x: ax(n), y: y0 + s.y(118)))
                    }
                    Text(t("Seen from the back: power, fans, ports from left to right")).font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                        .position(x: W / 2, y: geo.size.height - 18)
                }
            }
            .frame(height: 296)
            .padding(.horizontal, 12)
            Rectangle().fill(Theme.border).frame(height: 1).padding(.top, 12)
            RearInspector(session: session, snapshot: snapshot, item: selected ?? .qsfp(0))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Fixed callout width; room for the longer Turkish lines (§2: ±35%), truncated with a tooltip beyond that.
    private static let noteWidth: CGFloat = 240

    private func note(_ n: Note, center: CGPoint, anchor: CGPoint) -> some View {
        let isSel = selected == n.item || (n.item == .qsfp(0) && { if case .qsfp = selected { return true }; return false }())
        let edge = CGPoint(x: center.x, y: n.top ? center.y + 20 : center.y - 20)
        return ZStack(alignment: .topLeading) {
            elbowPath(from: anchor, to: edge).stroke(isSel ? Theme.accent : Theme.borderStrong, lineWidth: 1.2)
            Circle().strokeBorder(isSel ? Theme.accent : Theme.borderStrong, lineWidth: 1.2).background(Circle().fill(Theme.surface))
                .frame(width: 6, height: 6).position(anchor)
            Button { selected = n.item } label: {
                HStack(spacing: 8) {
                    AvatarCircle(symbol: n.symbol, avatar: .slate, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(n.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text1)
                        Text(n.sub).font(Typo.micro).foregroundStyle(Theme.text3)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    if let pill = n.pill { Pill(text: pill.0, kind: pill.1) }
                }
                .padding(.horizontal, 8).frame(width: Self.noteWidth, height: 40)
                .card(radius: 12, raised: true)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isSel ? Theme.accent : .clear, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .help(n.title + " · " + n.sub)
            .position(center)
        }
    }

    private func callouts() -> [Note] {
        let mgmt = snapshot.managementPort
        let addr = mgmt?.addresses.first ?? "—"
        let baud: String = { if case let .serial(_, b) = session.profile.connection { return String(b) }; return "9600" }()
        return [
            Note(item: .psu(1), title: t("Power supply %@", "1"), sub: t("Slot empty · optional spare"), top: true, pill: nil, symbol: "bolt"),
            Note(item: .qsfp(0), title: t("4× QSFP+ · Virtual Chassis"), sub: t("1/0–1/3 · no module"), top: true, pill: nil, symbol: "square.stack.3d.up"),
            Note(item: .con, title: t("Console"), sub: t("%@ baud", baud), top: true, pill: (t("Active"), .accent), symbol: "terminal"),
            Note(item: .psu(0), title: t("Power supply %@", "0"), sub: t("%@ · working", "JPSU-350-AC-AFO-A"), top: false, pill: nil, symbol: "bolt"),
            Note(item: .fan(0), title: t("Fans 0 and 1"), sub: t("Normal · airflow out (AFO)"), top: false, pill: nil, symbol: "fan"),
            Note(item: .mgmt, title: t("Management port · me0"), sub: mgmt?.linkUp == true ? addr : t("%@ · no cable", addr), top: false, pill: nil, symbol: "cable.connector"),
        ]
    }
}

struct RearInspector: View {
    var session: DeviceSession
    var snapshot: SwitchSnapshot
    var item: RearItem

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            identity.frame(width: 280, alignment: .leading).padding(.horizontal, 20)
            Rectangle().fill(Theme.border).frame(width: 1).frame(maxHeight: .infinity)
            middle.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
            Rectangle().fill(Theme.border).frame(width: 1).frame(maxHeight: .infinity)
            right.frame(width: 300, alignment: .leading).padding(.horizontal, 20)
        }
        .padding(.vertical, 18)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch item {
            case let .qsfp(i):
                let port = snapshot.rearPorts.indices.contains(i) ? snapshot.rearPorts[i] : nil
                title(t("QSFP+ %@", "1/\(i)"), Pill(text: port?.linkUp == true ? t("Up") : t("No link"), kind: port?.linkUp == true ? .good : .outline, dot: port?.linkUp == true),
                      t("Rear panel · 40G · PIC 1, port %@", String(i)))
                VStack(spacing: 0) {
                    ValueRow(label: t("Current role"), value: port?.role == .network ? t("Network port") : t("Virtual Chassis port"))
                    ValueRow(label: t("Status"), value: port?.linkUp == true ? t("Working") : t("No module or cable"))
                    ValueRow(label: t("Name as a network port"), value: "et-0/1/\(i)", mono: true)
                    ValueRow(label: t("Speed"), value: "40G QSFP+")
                }
            case .mgmt:
                let m = snapshot.managementPort
                title(t("Management port · me0"), Pill(text: m?.linkUp == true ? t("Up") : t("No link"), kind: m?.linkUp == true ? .good : .outline), "MGMT")
                VStack(spacing: 0) {
                    ValueRow(label: t("IP"), value: m?.addresses.first ?? "—", mono: true)
                    ValueRow(label: t("Status"), value: m?.linkUp == true ? t("Working") : t("No cable"))
                }
            case .con:
                title(t("Console"), Pill(text: t("Active"), kind: .accent), "CON")
                Text(t("Netdeck is connected through this port") + " · " + t("%@ baud", "9600")).font(Typo.callout).foregroundStyle(Theme.text2)
            case let .psu(i):
                title(t("Power supply %@", String(i)), i == 0 ? Pill(text: t("Working"), kind: .good, dot: true) : Pill(text: t("Slot empty · optional spare"), kind: .outline), "PSU \(i)")
                if i == 0 { ValueRow(label: t("Model"), value: "JPSU-350-AC-AFO-A") }
            case .fan:
                title(t("Fans 0 and 1"), Pill(text: t("Working"), kind: .good, dot: true), t("Normal · airflow out (AFO)"))
            case .usb:
                title("USB", Pill(text: t("No module or cable"), kind: .outline), "USB")
            }
        }
    }

    private func title(_ text: String, _ pill: Pill, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) { Text(text).font(Typo.portTitle).tracking(-0.3).foregroundStyle(Theme.text1).lineLimit(1); pill }
            Text(sub).font(Typo.caption).foregroundStyle(Theme.text3).lineLimit(1)
        }
    }

    @ViewBuilder
    private var middle: some View {
        if case let .qsfp(i) = item {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    FieldLabel(text: t("What should this port be used for?"))
                    Pill(text: t("Coming soon"), kind: .neutral)
                }
                HStack(spacing: 10) {
                    OptionCard(title: t("Virtual Chassis (stacking)"), subtitle: t("To run as one device with another EX switch. There is no second switch today."),
                               selected: true) {}
                    // Role changes need an operational command outside commit confirmed; the core does not stage them yet.
                    OptionCard(title: t("Network port"), subtitle: t("Becomes a normal 40G port (%@). Connect a server or an uplink and pick a VLAN.", "et-0/1/\(i)"),
                               selected: false, disabled: true) {}
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t("The safety timer can't undo this change")).font(Typo.bodyStrong).foregroundStyle(Theme.warnInk)
                        Text(t("The role is changed by a separate command, not by a commit (request virtual-chassis vc-port). Review asks you to confirm it separately."))
                            .font(Typo.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.warnSoft))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.warnLine, lineWidth: 1))
                Text(t("Each of the four ports can have its own role. If you don't plan a second switch, \"Network port\" makes sense."))
                    .font(Typo.micro).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(text: t("Status"))
                Text(item == .mgmt ? t("Plug a cable into MGMT to manage the switch over SSH; it is much faster than the console.")
                                   : t("Information only. Nothing here can be changed from Netdeck."))
                    .font(Typo.callout).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var right: some View {
        if case .qsfp = item {
            VStack(alignment: .leading, spacing: 10) {
                FieldLabel(text: t("Connected device"))
                HStack(spacing: 10) {
                    AvatarCircle(symbol: "cable.connector.slash", avatar: .slate, size: 40)
                    Text(t("This slot is empty")).font(Typo.bodyStrong).foregroundStyle(Theme.text2)
                }
                Text(t("When a QSFP+ module or DAC is plugged in, its model, speed and far end show here."))
                    .font(Typo.caption).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Color.clear.frame(height: 1)
        }
    }
}
