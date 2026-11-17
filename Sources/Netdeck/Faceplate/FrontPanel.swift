import NetdeckCore
import SwiftUI

/// Everything the panel needs to draw one port. Built from a snapshot + staged edits.
struct PanelPort: Equatable, Identifiable {
    enum Kind: Equatable { case copper, sfp }
    enum Look: Equatable { case up, down, disabled, empty }

    var slotKey: String
    var name: String
    var kind: Kind
    var index: Int            // copper: port number 0…47, sfp: cage 0…3
    var look: Look
    var vlanBars: [Color]     // one segment per VLAN (trunk = several)
    var warning = false
    var standby = false
    var staged = false
    var onTrial = false
    var hasModule = false     // sfp: something is plugged in
    var isDAC = false         // sfp: a direct-attach copper cable hangs below
    var accessibility: String = ""
    var id: String { slotKey }
}

/// Geometry of an EX4300-48T front panel in panel units (docs/DESIGN.md §5).
enum FrontGeometry {
    static let minX: CGFloat = -31, maxX: CGFloat = 1031
    static let minY: CGFloat = -2
    static let chassisHeight: CGFloat = 118
    static let cableDrop: CGFloat = 44
    static let groupX: [CGFloat] = [100, 272, 444, 616]

    static func height(hasCables: Bool) -> CGFloat { chassisHeight - minY + (hasCables ? cableDrop : 4) }

    static func copperRect(_ n: Int) -> CGRect {
        let g = n / 12, k = n % 12
        let col = k / 2, row = k % 2
        return CGRect(x: groupX[min(g, 3)] + CGFloat(col) * 27, y: row == 0 ? 35 : 60, width: 24, height: 20)
    }

    static func isTopRow(_ n: Int) -> Bool { n % 2 == 0 }

    static func cageRect(_ i: Int) -> CGRect { CGRect(x: 807.5 + CGFloat(i) * 43, y: 47, width: 36, height: 22) }

    static func rect(for port: PanelPort) -> CGRect {
        port.kind == .copper ? copperRect(port.index) : cageRect(port.index)
    }

    /// Larger hit target (port pitch).
    static func hitRect(for port: PanelPort) -> CGRect {
        let r = rect(for: port)
        return r.insetBy(dx: -1.5, dy: port.kind == .copper ? -2.5 : -4)
    }

    /// Where a leader line or wire leaves the panel (chassis edge above/below the port).
    static func anchor(for port: PanelPort, below: Bool) -> CGPoint {
        let r = rect(for: port)
        if port.kind == .sfp { return CGPoint(x: r.midX, y: below ? chassisHeight : 0) }
        return CGPoint(x: r.midX, y: below ? chassisHeight : 0)
    }
}

/// Converts panel units to view points for a given drawing width.
struct PanelScale {
    let k: CGFloat
    init(width: CGFloat) { k = width / (FrontGeometry.maxX - FrontGeometry.minX) }
    func x(_ u: CGFloat) -> CGFloat { (u - FrontGeometry.minX) * k }
    func y(_ u: CGFloat) -> CGFloat { (u - FrontGeometry.minY) * k }
    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: x(p.x), y: y(p.y)) }
    func rect(_ r: CGRect) -> CGRect { CGRect(x: x(r.minX), y: y(r.minY), width: r.width * k, height: r.height * k) }
    func unit(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / k + FrontGeometry.minX, y: p.y / k + FrontGeometry.minY) }
}

struct FrontPanelView: View {
    var model: String
    var vendor: String
    var hostname: String
    var ports: [PanelPort]
    var selected: Set<String> = []
    var hovered: String?
    var skeleton = false
    var showsCables = true
    var onTap: ((PanelPort) -> Void)?
    var onHover: ((PanelPort?) -> Void)?

    @Environment(\.colorScheme) private var scheme

    private var hasCables: Bool { showsCables && ports.contains { $0.isDAC } }

    var body: some View {
        GeometryReader { geo in
            let s = PanelScale(width: geo.size.width)
            Canvas { ctx, _ in
                draw(&ctx, s)
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                if let p = port(at: location, s) { onTap?(p) }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location): onHover?(port(at: location, s))
                case .ended: onHover?(nil)
                }
            }
            .accessibilityElement(children: .contain)
            .overlay {
                // Invisible accessibility targets, one per port.
                ForEach(ports) { p in
                    let r = s.rect(FrontGeometry.hitRect(for: p))
                    Color.clear
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .accessibilityElement()
                        .accessibilityLabel(p.accessibility)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { onTap?(p) }
                        .allowsHitTesting(false)
                }
            }
        }
        .aspectRatio((FrontGeometry.maxX - FrontGeometry.minX) / FrontGeometry.height(hasCables: hasCables), contentMode: .fit)
    }

    private func port(at location: CGPoint, _ s: PanelScale) -> PanelPort? {
        let u = s.unit(location)
        return ports.first { FrontGeometry.hitRect(for: $0).contains(u) }
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, _ s: PanelScale) {
        let k = s.k
        drawEars(&ctx, s)

        // Chassis body
        let chassis = Path(roundedRect: s.rect(CGRect(x: 0, y: 0, width: 1000, height: 118)), cornerRadius: 2 * k)
        ctx.fill(chassis, with: .linearGradient(
            Gradient(stops: [.init(color: Color(hex: 0x3B4148), location: 0), .init(color: Color(hex: 0x30363C), location: 0.07),
                             .init(color: Color(hex: 0x252A2F), location: 0.6), .init(color: Color(hex: 0x1B1F23), location: 1)]),
            startPoint: s.point(CGPoint(x: 0, y: 0)), endPoint: s.point(CGPoint(x: 0, y: 118))))
        // Brushed metal
        var brushed = Path()
        var yy: CGFloat = 1.3
        while yy < 117 {
            brushed.addRect(s.rect(CGRect(x: 0, y: yy, width: 1000, height: 0.45)))
            yy += 1.3
        }
        ctx.fill(brushed, with: .color(.white.opacity(0.028)))
        // Edges
        ctx.fill(Path(s.rect(CGRect(x: 0, y: 0, width: 1000, height: 1.1))), with: .color(.white.opacity(0.16)))
        ctx.fill(Path(s.rect(CGRect(x: 0, y: 116.8, width: 1000, height: 1.2))), with: .color(.black.opacity(0.55)))
        ctx.fill(Path(s.rect(CGRect(x: 0, y: 0, width: 1, height: 118))), with: .color(.black.opacity(0.5)))
        ctx.fill(Path(s.rect(CGRect(x: 999, y: 0, width: 1, height: 118))), with: .color(.black.opacity(0.5)))
        if scheme == .dark {
            ctx.stroke(chassis, with: .color(.white.opacity(0.06)), lineWidth: 1)
        }

        drawLeftSection(&ctx, s)
        for g in FrontGeometry.groupX {
            drawShield(&ctx, s, CGRect(x: g - 4.5, y: 31.5, width: 168, height: 52))
        }
        if ports.contains(where: { $0.kind == .sfp }) || skeleton { drawModulePlate(&ctx, s) }

        // Cables first so cages and numbers sit on top of them.
        if hasCables {
            for p in ports where p.isDAC { drawDAC(&ctx, s, p) }
        }
        for p in ports {
            if p.kind == .copper { drawCopper(&ctx, s, p) } else { drawCage(&ctx, s, p) }
        }
        _ = k
    }

    private func drawEars(_ ctx: inout GraphicsContext, _ s: PanelScale) {
        let k = s.k
        for x0 in [CGFloat(-30), 999] {
            let ear = Path(roundedRect: s.rect(CGRect(x: x0, y: 0, width: 31, height: 118)), cornerRadius: 2.5 * k)
            ctx.fill(ear, with: .linearGradient(Gradient(colors: [Color(hex: 0x363C42), Color(hex: 0x202428)]),
                                                startPoint: s.point(CGPoint(x: x0, y: 0)), endPoint: s.point(CGPoint(x: x0, y: 118))))
            for slotY in [CGFloat(17), 91] {
                let slot = CGRect(x: x0 + 5.5, y: slotY, width: 20, height: 10)
                ctx.fill(Path(roundedRect: s.rect(slot), cornerRadius: 5 * k), with: .color(Color(hex: 0x0E1012)))
                let c = s.point(CGPoint(x: slot.midX, y: slot.midY))
                let screw = Path(ellipseIn: CGRect(x: c.x - 5.6 * k, y: c.y - 5.6 * k, width: 11.2 * k, height: 11.2 * k))
                ctx.fill(screw, with: .radialGradient(Gradient(colors: [Color(hex: 0xE9ECEF), Color(hex: 0x9BA4AC), Color(hex: 0x626B73)]),
                                                      center: CGPoint(x: c.x - 1.5 * k, y: c.y - 1.5 * k), startRadius: 0, endRadius: 6.5 * k))
                var cross = Path()
                cross.move(to: CGPoint(x: c.x - 3 * k, y: c.y)); cross.addLine(to: CGPoint(x: c.x + 3 * k, y: c.y))
                cross.move(to: CGPoint(x: c.x, y: c.y - 3 * k)); cross.addLine(to: CGPoint(x: c.x, y: c.y + 3 * k))
                ctx.stroke(cross, with: .color(Color(hex: 0x4B535B)), lineWidth: 1.1 * k)
            }
        }
    }

    private func drawLeftSection(_ ctx: inout GraphicsContext, _ s: PanelScale) {
        let k = s.k
        text(&ctx, s, model.uppercased(), at: CGPoint(x: 16, y: 21), size: 8.4, weight: .bold, color: Color(hex: 0xD2D8DE), tracking: 0.4)
        text(&ctx, s, vendor.uppercased(), at: CGPoint(x: 16, y: 31), size: 5.6, weight: .semibold, color: Color(hex: 0x7F8A94), tracking: 1.1)
        let leds: [(String, Bool)] = [("SYS", !skeleton), ("ALM", false), ("MST", !skeleton)]
        for (i, led) in leds.enumerated() {
            let r = CGRect(x: 16, y: 45 + CGFloat(i) * 10, width: 5, height: 3)
            drawLED(&ctx, s, r, color: led.1 ? Theme.HW.ledGreen : Theme.HW.ledOff, glow: led.1)
            text(&ctx, s, led.0, at: CGPoint(x: 25, y: r.maxY), size: 5.6, weight: .semibold, color: Color(hex: 0x7F8A94))
        }
        let label = s.rect(CGRect(x: 15, y: 82, width: 54, height: 15))
        ctx.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.45), radius: 0.6 * k, x: 0, y: 1.2 * k))
            l.fill(Path(roundedRect: label, cornerRadius: 1.6 * k), with: .color(Color(hex: 0xF4F2EA)))
        }
        ctx.draw(Text(hostname).font(.system(size: 8.2 * k, weight: .bold)).foregroundStyle(Color(hex: 0x16181B)),
                 at: CGPoint(x: label.midX, y: label.midY), anchor: .center)
    }

    private func drawShield(_ ctx: inout GraphicsContext, _ s: PanelScale, _ r: CGRect) {
        let k = s.k
        let path = Path(roundedRect: s.rect(r), cornerRadius: 2.4 * k)
        ctx.fill(path, with: .linearGradient(Gradient(colors: [Color(hex: 0x5D666F), Color(hex: 0x4A525A), Color(hex: 0x3D444B)]),
                                             startPoint: s.point(CGPoint(x: r.minX, y: r.minY)), endPoint: s.point(CGPoint(x: r.minX, y: r.maxY))))
        ctx.stroke(path, with: .color(Color(hex: 0x69727B)), lineWidth: 0.5 * k)
        ctx.fill(Path(s.rect(CGRect(x: r.minX + 1.2, y: r.minY + 0.3, width: r.width - 2.4, height: 0.6))), with: .color(.white.opacity(0.22)))
    }

    private func mouthPath(_ r: CGRect, top: Bool, _ s: PanelScale) -> Path {
        // 24 × 20 opening with an 11 × 4 latch notch in the middle of the latch side.
        let notchX = r.minX + (r.width - 11) / 2
        var p = Path()
        let pts: [CGPoint]
        if top {
            pts = [CGPoint(x: r.minX, y: r.minY + 4), CGPoint(x: notchX, y: r.minY + 4), CGPoint(x: notchX, y: r.minY),
                   CGPoint(x: notchX + 11, y: r.minY), CGPoint(x: notchX + 11, y: r.minY + 4), CGPoint(x: r.maxX, y: r.minY + 4),
                   CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        } else {
            pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY - 4),
                   CGPoint(x: notchX + 11, y: r.maxY - 4), CGPoint(x: notchX + 11, y: r.maxY), CGPoint(x: notchX, y: r.maxY),
                   CGPoint(x: notchX, y: r.maxY - 4), CGPoint(x: r.minX, y: r.maxY - 4)]
        }
        p.addLines(pts.map(s.point))
        p.closeSubpath()
        return p
    }

    private func drawCopper(_ ctx: inout GraphicsContext, _ s: PanelScale, _ port: PanelPort) {
        let k = s.k
        let r = FrontGeometry.copperRect(port.index)
        let top = FrontGeometry.isTopRow(port.index)
        let mouth = mouthPath(r, top: top, s)
        let isSelected = selected.contains(port.slotKey)
        let look: PanelPort.Look = skeleton ? .down : port.look

        if look == .disabled {
            ctx.fill(mouth, with: .color(Color(hex: 0x1E2226)))
            ctx.drawLayer { l in
                l.clip(to: mouth)
                var hatch = Path()
                var d: CGFloat = -24
                while d < 24 {
                    hatch.move(to: s.point(CGPoint(x: r.minX + d, y: r.maxY)))
                    hatch.addLine(to: s.point(CGPoint(x: r.minX + d + 20, y: r.minY)))
                    d += 3
                }
                l.stroke(hatch, with: .color(Color(hex: 0x2B3036)), lineWidth: 1 * k)
            }
        } else {
            ctx.fill(mouth, with: .linearGradient(Gradient(colors: [Color(hex: 0x020304), Color(hex: 0x101317)]),
                                                  startPoint: s.point(CGPoint(x: r.midX, y: top ? r.minY : r.maxY)),
                                                  endPoint: s.point(CGPoint(x: r.midX, y: top ? r.maxY : r.minY))))
        }
        ctx.stroke(mouth, with: .color(.black.opacity(0.7)), lineWidth: 0.6 * k)

        if look == .up || port.standby {
            // Plug inserted
            let body = CGRect(x: r.minX + 1.6, y: top ? r.minY + 5.6 : r.minY + 1.6, width: r.width - 3.2, height: r.height - 7.2)
            let bodyPath = Path(roundedRect: s.rect(body), cornerRadius: 1.6 * k)
            ctx.fill(bodyPath, with: .linearGradient(Gradient(colors: [Color(hex: 0xE6EAEE), Color(hex: 0xAEB7C0)]),
                                                     startPoint: s.point(CGPoint(x: body.midX, y: body.minY)), endPoint: s.point(CGPoint(x: body.midX, y: body.maxY))))
            ctx.stroke(bodyPath, with: .color(Color(hex: 0x7F8993)), lineWidth: 0.5 * k)
            let latch = CGRect(x: r.midX - 4.5, y: top ? r.minY + 0.6 : r.maxY - 4.6, width: 9, height: 4)
            ctx.fill(Path(roundedRect: s.rect(latch), cornerRadius: 0.8 * k), with: .color(Color(hex: 0xC3CAD1)))
            let c = s.point(CGPoint(x: body.midX, y: body.midY))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4.4 * k, y: c.y - 4.4 * k, width: 8.8 * k, height: 8.8 * k)),
                     with: .radialGradient(Gradient(colors: [Color(hex: 0xF6F7F8), Color(hex: 0xB4BCC4)]), center: c, startRadius: 0, endRadius: 4.4 * k))
        } else if look == .down {
            var pins = Path()
            for i in 0..<8 {
                let px = r.minX + 5.2 + CGFloat(i) * 1.95
                let y0 = top ? r.maxY - 4.2 : r.minY + 1.2
                pins.move(to: s.point(CGPoint(x: px, y: y0)))
                pins.addLine(to: s.point(CGPoint(x: px, y: y0 + 3)))
            }
            ctx.stroke(pins, with: .color(Color(hex: 0xB08E52).opacity(0.55)), lineWidth: 0.65 * k)
        }

        // LEDs
        if look != .disabled {
            let ly = top ? r.minY + 0.6 : r.minY + 16.8
            let left = CGRect(x: r.minX + 1, y: ly, width: 4.4, height: 2.6)
            let right = CGRect(x: r.minX + 18.6, y: ly, width: 4.4, height: 2.6)
            if port.standby {
                drawLED(&ctx, s, left, color: Theme.HW.ledAmberDim, glow: false)
            } else {
                drawLED(&ctx, s, left, color: look == .up ? Theme.HW.ledGreen : Theme.HW.ledOff, glow: look == .up)
            }
            drawLED(&ctx, s, right, color: port.warning ? Theme.HW.ledAmber : Theme.HW.ledOff, glow: port.warning)
        }

        // VLAN bar
        if look != .disabled && !port.vlanBars.isEmpty && !skeleton {
            drawVLANBar(&ctx, s, CGRect(x: r.minX + 0.5, y: top ? 27.6 : 85, width: 23, height: 2.6), port.vlanBars)
        }

        // Number
        let numberColor = isSelected ? Theme.HW.plateLabelSel : (look == .disabled ? Theme.HW.plateLabelDim : Theme.HW.plateLabel)
        ctx.draw(Text(String(port.index)).font(.system(size: 7.2 * k, weight: isSelected ? .bold : .semibold)).foregroundStyle(numberColor),
                 at: s.point(CGPoint(x: r.midX, y: top ? 21.8 : 93)), anchor: .center)

        // Selection / hover rings
        if isSelected {
            ctx.stroke(Path(roundedRect: s.rect(r.insetBy(dx: -4.4, dy: -4.4)), cornerRadius: 5.5 * k), with: .color(Theme.HW.metalAccent.opacity(0.55)), lineWidth: 3.2 * k)
            ctx.stroke(Path(roundedRect: s.rect(r.insetBy(dx: -2.8, dy: -2.8)), cornerRadius: 4 * k), with: .color(.white), lineWidth: 1.5 * k)
        } else if hovered == port.slotKey {
            ctx.stroke(Path(roundedRect: s.rect(r.insetBy(dx: -2.8, dy: -2.8)), cornerRadius: 4 * k), with: .color(.white.opacity(0.4)), lineWidth: 1 * k)
        }

        // Badges on the latch-side outer corner
        let corner = CGPoint(x: r.maxX, y: top ? r.minY : r.maxY)
        if port.onTrial {
            badge(&ctx, s, at: corner, fill: Theme.HW.ledAmber, symbol: "clock", symbolColor: Color(hex: 0x1B1F23))
        } else if port.staged {
            badge(&ctx, s, at: corner, fill: Theme.HW.metalAccent, symbol: "pencil", symbolColor: .white)
        } else if port.warning {
            warningTriangle(&ctx, s, at: corner)
        }
    }

    private func drawModulePlate(_ ctx: inout GraphicsContext, _ s: PanelScale) {
        let k = s.k
        let plate = CGRect(x: 789, y: 21, width: 202, height: 76)
        let path = Path(roundedRect: s.rect(plate), cornerRadius: 3 * k)
        ctx.fill(path, with: .linearGradient(Gradient(colors: [Color(hex: 0x2C3137), Color(hex: 0x1F2327)]),
                                             startPoint: s.point(CGPoint(x: 0, y: plate.minY)), endPoint: s.point(CGPoint(x: 0, y: plate.maxY))))
        ctx.stroke(path, with: .color(Color(hex: 0x0F1113)), lineWidth: 1 * k)
        for sx in [CGFloat(797.5), 982.5] {
            let c = s.point(CGPoint(x: sx, y: 59))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3.6 * k, y: c.y - 3.6 * k, width: 7.2 * k, height: 7.2 * k)),
                     with: .radialGradient(Gradient(colors: [Color(hex: 0xC9CFD5), Color(hex: 0x6E777F)]), center: c, startRadius: 0, endRadius: 3.6 * k))
        }
        text(&ctx, s, t("4× SFP+ 10G"), at: CGPoint(x: 807, y: 33.5), size: 5.8, weight: .semibold, color: Color(hex: 0x8C969F), tracking: 0.6)
        ctx.draw(Text("PIC 2").font(.system(size: 5.8 * k, weight: .semibold)).foregroundStyle(Color(hex: 0x8C969F)),
                 at: s.point(CGPoint(x: 983, y: 31.5)), anchor: .trailing)
    }

    private func drawCage(_ ctx: inout GraphicsContext, _ s: PanelScale, _ port: PanelPort) {
        let k = s.k
        let r = FrontGeometry.cageRect(port.index)
        let isSelected = selected.contains(port.slotKey)
        let cage = Path(roundedRect: s.rect(r), cornerRadius: 1.4 * k)
        ctx.fill(cage, with: .linearGradient(Gradient(colors: [Color(hex: 0xB9C1C8), Color(hex: 0x8D969F), Color(hex: 0x6B747D)]),
                                             startPoint: s.point(CGPoint(x: 0, y: r.minY)), endPoint: s.point(CGPoint(x: 0, y: r.maxY))))
        let mouthR = r.insetBy(dx: 2.2, dy: 2.2)
        ctx.fill(Path(roundedRect: s.rect(mouthR), cornerRadius: 0.8 * k), with: .color(Color(hex: 0x050607)))
        ctx.fill(Path(s.rect(CGRect(x: r.midX - 4, y: r.maxY - 1.6, width: 8, height: 1.6))), with: .color(Color(hex: 0x5A636C)))

        if port.hasModule && !skeleton {
            let plug = mouthR.insetBy(dx: 1.4, dy: 1.6)
            ctx.fill(Path(roundedRect: s.rect(plug), cornerRadius: 1 * k),
                     with: .linearGradient(Gradient(colors: [Color(hex: 0xD3D8DD), Color(hex: 0x8C959E)]),
                                           startPoint: s.point(CGPoint(x: 0, y: plug.minY)), endPoint: s.point(CGPoint(x: 0, y: plug.maxY))))
            for rx in [plug.minX + 3, plug.maxX - 4] {
                ctx.fill(Path(s.rect(CGRect(x: rx, y: plug.minY + 1, width: 1, height: plug.height - 2))), with: .color(.black.opacity(0.18)))
            }
            if port.isDAC {
                let c = s.point(CGPoint(x: plug.midX, y: plug.midY))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5.6 * k, y: c.y - 5.6 * k, width: 11.2 * k, height: 11.2 * k)), with: .color(Color(hex: 0x121417)))
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 5.6 * k, y: c.y - 5.6 * k, width: 11.2 * k, height: 11.2 * k)), with: .color(.white.opacity(0.13)), lineWidth: 0.7 * k)
            }
        }

        // LED above the cage
        let ledR = CGRect(x: r.minX + 15.5, y: 41.4, width: 5, height: 2.6)
        if port.warning && !skeleton {
            drawLED(&ctx, s, ledR, color: Theme.HW.ledAmber, glow: true)
        } else {
            drawLED(&ctx, s, ledR, color: port.look == .up && !skeleton ? Theme.HW.ledGreen : Theme.HW.ledOff, glow: port.look == .up && !skeleton)
        }
        if !port.vlanBars.isEmpty && port.look != .disabled && !skeleton {
            drawVLANBar(&ctx, s, CGRect(x: r.minX + 1, y: 72.2, width: 34, height: 2.6), port.vlanBars)
        }
        // Number with a chassis-colored outline so it reads over a hanging cable.
        let numberColor = isSelected ? Theme.HW.plateLabelSel : Theme.HW.plateLabel
        let np = s.point(CGPoint(x: r.midX, y: 81.6))
        for (dx, dy) in [(-1.1, 0.0), (1.1, 0.0), (0.0, -1.1), (0.0, 1.1)] {
            ctx.draw(Text(String(port.index)).font(.system(size: 7.2 * k, weight: .semibold)).foregroundStyle(Color(hex: 0x23282D)),
                     at: CGPoint(x: np.x + dx * k, y: np.y + dy * k), anchor: .center)
        }
        ctx.draw(Text(String(port.index)).font(.system(size: 7.2 * k, weight: isSelected ? .bold : .semibold)).foregroundStyle(numberColor),
                 at: np, anchor: .center)

        if isSelected {
            ctx.stroke(Path(roundedRect: s.rect(r.insetBy(dx: -4.4, dy: -4.4)), cornerRadius: 5.5 * k), with: .color(Theme.HW.metalAccent.opacity(0.55)), lineWidth: 3.2 * k)
            ctx.stroke(Path(roundedRect: s.rect(r.insetBy(dx: -2.8, dy: -2.8)), cornerRadius: 4 * k), with: .color(.white), lineWidth: 1.5 * k)
        } else if hovered == port.slotKey {
            ctx.stroke(Path(roundedRect: s.rect(r.insetBy(dx: -2.8, dy: -2.8)), cornerRadius: 4 * k), with: .color(.white.opacity(0.4)), lineWidth: 1 * k)
        }
        let corner = CGPoint(x: r.maxX, y: r.minY)
        if port.onTrial {
            badge(&ctx, s, at: corner, fill: Theme.HW.ledAmber, symbol: "clock", symbolColor: Color(hex: 0x1B1F23))
        } else if port.staged {
            badge(&ctx, s, at: corner, fill: Theme.HW.metalAccent, symbol: "pencil", symbolColor: .white)
        } else if port.warning && !skeleton {
            warningTriangle(&ctx, s, at: corner)
        }
    }

    private func drawDAC(_ ctx: inout GraphicsContext, _ s: PanelScale, _ port: PanelPort) {
        let k = s.k
        let r = FrontGeometry.cageRect(port.index)
        let start = CGPoint(x: r.midX, y: r.midY + 1.5)
        let endX = port.index % 2 == 0 ? r.midX - 14 : r.midX + 10
        let end = CGPoint(x: endX, y: FrontGeometry.chassisHeight + FrontGeometry.cableDrop)
        var cable = Path()
        cable.move(to: s.point(start))
        cable.addCurve(to: s.point(end), control1: s.point(CGPoint(x: start.x, y: start.y + 40)), control2: s.point(CGPoint(x: end.x, y: end.y - 26)))
        ctx.stroke(cable, with: .color(Color(hex: 0x121417)), style: StrokeStyle(lineWidth: 8.5 * k, lineCap: .round))
        ctx.stroke(cable.offsetBy(dx: -2.2 * k, dy: 0), with: .color(.white.opacity(0.13)), style: StrokeStyle(lineWidth: 1.4 * k, lineCap: .round))
    }

    // MARK: Helpers

    private func drawLED(_ ctx: inout GraphicsContext, _ s: PanelScale, _ r: CGRect, color: Color, glow: Bool) {
        let path = Path(roundedRect: s.rect(r), cornerRadius: 0.7 * s.k)
        if glow {
            ctx.drawLayer { l in
                l.addFilter(.shadow(color: color, radius: 1.6 * s.k))
                l.fill(path, with: .color(color))
            }
        } else {
            ctx.fill(path, with: .color(color))
        }
    }

    private func drawVLANBar(_ ctx: inout GraphicsContext, _ s: PanelScale, _ r: CGRect, _ colors: [Color]) {
        let k = s.k
        let gap: CGFloat = colors.count > 1 ? 1 : 0
        let w = (r.width - gap * CGFloat(colors.count - 1)) / CGFloat(colors.count)
        for (i, c) in colors.enumerated() {
            let seg = CGRect(x: r.minX + CGFloat(i) * (w + gap), y: r.minY, width: w, height: r.height)
            ctx.fill(Path(roundedRect: s.rect(seg), cornerRadius: 1.3 * k), with: .color(c))
        }
    }

    private func badge(_ ctx: inout GraphicsContext, _ s: PanelScale, at u: CGPoint, fill: Color, symbol: String, symbolColor: Color) {
        let k = s.k
        let c = s.point(u)
        let circle = Path(ellipseIn: CGRect(x: c.x - 5 * k, y: c.y - 5 * k, width: 10 * k, height: 10 * k))
        ctx.fill(circle, with: .color(fill))
        ctx.stroke(circle, with: .color(Color(hex: 0x252A2F)), lineWidth: 1.5 * k)
        ctx.draw(Text(Image(systemName: symbol)).font(.system(size: 5.6 * k, weight: .bold)).foregroundStyle(symbolColor), at: c, anchor: .center)
    }

    private func warningTriangle(_ ctx: inout GraphicsContext, _ s: PanelScale, at u: CGPoint) {
        let k = s.k
        let c = s.point(u)
        ctx.draw(Text(Image(systemName: "exclamationmark.triangle.fill")).font(.system(size: 10.8 * k)).foregroundStyle(Color(hex: 0x1B1F23)),
                 at: CGPoint(x: c.x, y: c.y + 0.4 * k), anchor: .center)
        ctx.draw(Text(Image(systemName: "exclamationmark.triangle.fill")).font(.system(size: 9.4 * k)).foregroundStyle(Theme.HW.ledAmber),
                 at: c, anchor: .center)
    }

    private func text(_ ctx: inout GraphicsContext, _ s: PanelScale, _ str: String, at baseline: CGPoint, size: CGFloat, weight: Font.Weight,
                      color: Color, tracking: CGFloat = 0) {
        let k = s.k
        let t = Text(str).font(.system(size: size * k, weight: weight)).tracking(tracking * k).foregroundStyle(color)
        ctx.draw(t, at: s.point(CGPoint(x: baseline.x, y: baseline.y - size * 0.36)), anchor: .leading)
    }
}
