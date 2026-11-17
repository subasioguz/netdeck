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
    /// Where the port sits, in panel units (set by `PanelBuilder.arrange`).
    var frame: CGRect = .zero
    /// Top row (number above the port) or bottom row (number below).
    var top = true
    /// Number printed next to the port.
    var label: String = ""
    /// Copper ports of one block share a metal shield.
    var block = 0
    /// Ports on a removable uplink module share a plate with this title and tag ("4× SFP+ 10G", "PIC 2").
    var plate: PanelPlate?
    var id: String { slotKey }
}

struct PanelPlate: Equatable, Hashable {
    var title: String
    var tag: String
}

/// Front panel geometry in panel units (docs/DESIGN.md §5). The chassis is 1000 units wide (a 19"
/// unit, as on the EX4300-48T) and grows when a model has more ports than fit.
enum FrontGeometry {
    static let minX: CGFloat = -31
    static let minY: CGFloat = -2
    static let chassisHeight: CGFloat = 118
    static let cableDrop: CGFloat = 44
    /// Left edge of the first copper block; the model name, LEDs and hostname label sit left of it.
    static let firstPortX: CGFloat = 100

    static func height(hasCables: Bool) -> CGFloat { chassisHeight - minY + (hasCables ? cableDrop : 4) }

    /// Chassis width for these ports: 1000, or wider when the ports need more room.
    static func chassisWidth(_ ports: [PanelPort]) -> CGFloat {
        max(1000, (ports.map(\.frame.maxX).max() ?? 0) + 27.5)
    }

    static func maxX(_ ports: [PanelPort]) -> CGFloat { chassisWidth(ports) + 31 }

    /// Drawing width ÷ height for these ports.
    static func aspect(_ ports: [PanelPort], hasCables: Bool) -> CGFloat {
        (maxX(ports) - minX) / height(hasCables: hasCables)
    }

    static func rect(for port: PanelPort) -> CGRect { port.frame }

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
    init(width: CGFloat, ports: [PanelPort]) { k = width / (FrontGeometry.maxX(ports) - FrontGeometry.minX) }
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
    /// Ports that shape the chassis: an empty skeleton still shows the EX4300 shields and module plate.
    private var shape: [PanelPort] { ports.isEmpty && skeleton ? BoardStage.skeletonPorts : ports }
    /// The known model's spec, for its console/management/USB ports and ears.
    private var spec: FaceplateSpec? { model.isEmpty ? nil : FaceplateCatalog.spec(forModel: model) }

    var body: some View {
        GeometryReader { geo in
            let s = PanelScale(width: geo.size.width, ports: shape)
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
        .aspectRatio(FrontGeometry.aspect(shape, hasCables: hasCables), contentMode: .fit)
    }

    private func port(at location: CGPoint, _ s: PanelScale) -> PanelPort? {
        let u = s.unit(location)
        return ports.first { FrontGeometry.hitRect(for: $0).contains(u) }
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, _ s: PanelScale) {
        let k = s.k
        let cw = FrontGeometry.chassisWidth(shape)
        if spec?.hasEars ?? true { drawEars(&ctx, s, chassisWidth: cw) }

        // Chassis body
        let chassis = Path(roundedRect: s.rect(CGRect(x: 0, y: 0, width: cw, height: 118)), cornerRadius: 2 * k)
        ctx.fill(chassis, with: .linearGradient(
            Gradient(stops: [.init(color: Color(hex: 0x3B4148), location: 0), .init(color: Color(hex: 0x30363C), location: 0.07),
                             .init(color: Color(hex: 0x252A2F), location: 0.6), .init(color: Color(hex: 0x1B1F23), location: 1)]),
            startPoint: s.point(CGPoint(x: 0, y: 0)), endPoint: s.point(CGPoint(x: 0, y: 118))))
        // Brushed metal
        var brushed = Path()
        var yy: CGFloat = 1.3
        while yy < 117 {
            brushed.addRect(s.rect(CGRect(x: 0, y: yy, width: cw, height: 0.45)))
            yy += 1.3
        }
        ctx.fill(brushed, with: .color(.white.opacity(0.028)))
        // Edges
        ctx.fill(Path(s.rect(CGRect(x: 0, y: 0, width: cw, height: 1.1))), with: .color(.white.opacity(0.16)))
        ctx.fill(Path(s.rect(CGRect(x: 0, y: 116.8, width: cw, height: 1.2))), with: .color(.black.opacity(0.55)))
        ctx.fill(Path(s.rect(CGRect(x: 0, y: 0, width: 1, height: 118))), with: .color(.black.opacity(0.5)))
        ctx.fill(Path(s.rect(CGRect(x: cw - 1, y: 0, width: 1, height: 118))), with: .color(.black.opacity(0.5)))
        if scheme == .dark {
            ctx.stroke(chassis, with: .color(.white.opacity(0.06)), lineWidth: 1)
        }

        drawLeftSection(&ctx, s)
        for shield in Self.shields(shape) { drawShield(&ctx, s, shield) }
        for plate in Self.plates(shape) { drawModulePlate(&ctx, s, plate.rect, plate.plate) }
        if let spec, !skeleton {
            let l = PanelBuilder.layout(spec)
            for d in l.decorations { drawDecoration(&ctx, s, d) }
            // A module slot with nothing in it gets a blank cover plate.
            for m in l.modules where !ports.contains(where: { $0.plate != nil && m.rect.insetBy(dx: -2, dy: -30).contains($0.frame.origin) }) {
                drawModulePlate(&ctx, s, m.rect, PanelPlate(title: m.title, tag: ""))
            }
        }

        // Cables first so cages and numbers sit on top of them.
        if hasCables {
            for p in ports where p.isDAC { drawDAC(&ctx, s, p) }
        }
        for p in ports {
            if p.kind == .copper { drawCopper(&ctx, s, p) } else { drawCage(&ctx, s, p) }
        }
        _ = k
    }

    /// One shield per copper block: the block's ports plus a 4.5 × 3.5 unit margin.
    static func shields(_ ports: [PanelPort]) -> [CGRect] {
        let copper = ports.filter { $0.kind == .copper }
        return Dictionary(grouping: copper, by: \.block).sorted { $0.key < $1.key }.map { _, ps in
            ps.map(\.frame).reduce(ps[0].frame) { $0.union($1) }.insetBy(dx: -4.5, dy: -3.5)
        }
    }

    /// Module plates around the cages that share one (EX4300 uplink module).
    static func plates(_ ports: [PanelPort]) -> [(rect: CGRect, plate: PanelPlate)] {
        let onPlates = ports.filter { $0.plate != nil }
        return Dictionary(grouping: onPlates, by: { $0.plate! }).map { plate, ps in
            let u = ps.map(\.frame).reduce(ps[0].frame) { $0.union($1) }
            return (CGRect(x: u.minX - 18.5, y: u.minY - 26, width: u.width + 37, height: u.height + 54), plate)
        }.sorted { $0.rect.minX < $1.rect.minX }
    }

    /// Console, management, USB, reset, DC input and auxiliary cages of a known model, each with its
    /// printed label. Nothing here is selectable: Netdeck doesn't manage these ports.
    private func drawDecoration(_ ctx: inout GraphicsContext, _ s: PanelScale, _ d: PanelDecoration) {
        let k = s.k
        let r = d.frame
        let rim = Color(hex: 0x7F8993)
        switch d.kind {
        case "usb", "console-usb":
            ctx.fill(Path(roundedRect: s.rect(r), cornerRadius: 1 * k), with: .color(Color(hex: 0x0B0D0F)))
            ctx.stroke(Path(roundedRect: s.rect(r), cornerRadius: 1 * k), with: .color(rim), lineWidth: 0.8 * k)
            ctx.fill(Path(s.rect(r.insetBy(dx: r.width * 0.2, dy: r.height * 0.3))), with: .color(Color(hex: 0x3A4148)))
        case "reset":
            let c = s.point(CGPoint(x: r.midX, y: r.midY))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3 * k, y: c.y - 3 * k, width: 6 * k, height: 6 * k)), with: .color(Color(hex: 0x050607)))
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 3 * k, y: c.y - 3 * k, width: 6 * k, height: 6 * k)), with: .color(rim), lineWidth: 0.6 * k)
        case "power-dc":
            let c = s.point(CGPoint(x: r.midX, y: r.midY))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 7 * k, y: c.y - 7 * k, width: 14 * k, height: 14 * k)),
                     with: .radialGradient(Gradient(colors: [Color(hex: 0x050607), Color(hex: 0x2B3036)]), center: c, startRadius: 0, endRadius: 7 * k))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.6 * k, y: c.y - 1.6 * k, width: 3.2 * k, height: 3.2 * k)), with: .color(Color(hex: 0xB9C1C8)))
        case "console-db9":
            var p = Path()
            p.addLines([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX - 3, y: r.maxY), CGPoint(x: r.minX + 3, y: r.maxY)].map(s.point))
            p.closeSubpath()
            ctx.fill(p, with: .color(Color(hex: 0x050607)))
            ctx.stroke(p, with: .color(rim), lineWidth: 0.8 * k)
        case "sfp-aux":
            let cage = Path(roundedRect: s.rect(r), cornerRadius: 1.4 * k)
            ctx.fill(cage, with: .linearGradient(Gradient(colors: [Color(hex: 0xB9C1C8), Color(hex: 0x6B747D)]),
                                                 startPoint: s.point(CGPoint(x: 0, y: r.minY)), endPoint: s.point(CGPoint(x: 0, y: r.maxY))))
            ctx.fill(Path(roundedRect: s.rect(r.insetBy(dx: 2.2, dy: 2.2)), cornerRadius: 0.8 * k), with: .color(Color(hex: 0x050607)))
        default:   // console-rj45, mgmt-rj45, aux
            let mouth = mouthPath(r, top: true, s)
            ctx.fill(mouth, with: .color(Color(hex: 0x050607)))
            ctx.stroke(mouth, with: .color(d.kind.hasPrefix("console") ? Theme.HW.metalAccent.opacity(0.7) : Color.black.opacity(0.7)), lineWidth: 0.8 * k)
        }
        let label = d.label.count > 8 ? String(d.label.prefix(8)) : d.label
        ctx.draw(Text(label).font(.system(size: 5.4 * k, weight: .semibold)).foregroundStyle(Color(hex: 0x8C969F)),
                 at: s.point(CGPoint(x: r.midX, y: r.minY - 6)), anchor: .center)
    }

    /// Port labels longer than a number ("SFP+1", "PoE in") get a smaller font so they fit the port.
    private func labelSize(_ label: String, width: CGFloat) -> CGFloat {
        min(7.2, (width + 4) / (0.6 * CGFloat(max(1, label.count))))
    }

    private func drawEars(_ ctx: inout GraphicsContext, _ s: PanelScale, chassisWidth cw: CGFloat) {
        let k = s.k
        for x0 in [CGFloat(-30), cw - 1] {
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
        // Long hostnames get a smaller font so they stay on the label (about 0.62 em per character).
        let size = min(8.2, 50 / (0.62 * CGFloat(max(1, hostname.count))))
        ctx.draw(Text(hostname).font(.system(size: size * k, weight: .bold)).foregroundStyle(Color(hex: 0x16181B)),
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
        let r = port.frame
        let top = port.top
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
            drawVLANBar(&ctx, s, CGRect(x: r.minX + 0.5, y: top ? r.minY - 7.4 : r.maxY + 5, width: 23, height: 2.6), port.vlanBars)
        }

        // Number
        let numberColor = isSelected ? Theme.HW.plateLabelSel : (look == .disabled ? Theme.HW.plateLabelDim : Theme.HW.plateLabel)
        ctx.draw(Text(port.label).font(.system(size: labelSize(port.label, width: r.width) * k, weight: isSelected ? .bold : .semibold)).foregroundStyle(numberColor),
                 at: s.point(CGPoint(x: r.midX, y: top ? r.minY - 13.2 : r.maxY + 13)), anchor: .center)

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

    private func drawModulePlate(_ ctx: inout GraphicsContext, _ s: PanelScale, _ plate: CGRect, _ info: PanelPlate) {
        let k = s.k
        let path = Path(roundedRect: s.rect(plate), cornerRadius: 3 * k)
        ctx.fill(path, with: .linearGradient(Gradient(colors: [Color(hex: 0x2C3137), Color(hex: 0x1F2327)]),
                                             startPoint: s.point(CGPoint(x: 0, y: plate.minY)), endPoint: s.point(CGPoint(x: 0, y: plate.maxY))))
        ctx.stroke(path, with: .color(Color(hex: 0x0F1113)), lineWidth: 1 * k)
        for sx in [plate.minX + 8.5, plate.maxX - 8.5] {
            let c = s.point(CGPoint(x: sx, y: plate.midY))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3.6 * k, y: c.y - 3.6 * k, width: 7.2 * k, height: 7.2 * k)),
                     with: .radialGradient(Gradient(colors: [Color(hex: 0xC9CFD5), Color(hex: 0x6E777F)]), center: c, startRadius: 0, endRadius: 3.6 * k))
        }
        text(&ctx, s, info.title, at: CGPoint(x: plate.minX + 18, y: plate.minY + 12.5), size: 5.8, weight: .semibold, color: Color(hex: 0x8C969F), tracking: 0.6)
        ctx.draw(Text(info.tag).font(.system(size: 5.8 * k, weight: .semibold)).foregroundStyle(Color(hex: 0x8C969F)),
                 at: s.point(CGPoint(x: plate.maxX - 8, y: plate.minY + 10.5)), anchor: .trailing)
    }

    private func drawCage(_ ctx: inout GraphicsContext, _ s: PanelScale, _ port: PanelPort) {
        let k = s.k
        let r = port.frame
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

        // LED above the cage (inside its top edge for a top-row cage, whose number sits above)
        let ledR = port.top ? CGRect(x: r.maxX - 6.5, y: r.minY + 0.6, width: 4.4, height: 1.8)
                            : CGRect(x: r.minX + 15.5, y: r.minY - 5.6, width: 5, height: 2.6)
        if port.warning && !skeleton {
            drawLED(&ctx, s, ledR, color: Theme.HW.ledAmber, glow: true)
        } else {
            drawLED(&ctx, s, ledR, color: port.look == .up && !skeleton ? Theme.HW.ledGreen : Theme.HW.ledOff, glow: port.look == .up && !skeleton)
        }
        if !port.vlanBars.isEmpty && port.look != .disabled && !skeleton {
            drawVLANBar(&ctx, s, CGRect(x: r.minX + 1, y: port.top ? r.minY - 4.4 : r.maxY + 3.2, width: r.width - 2, height: 2.6), port.vlanBars)
        }
        // Number with a chassis-colored outline so it reads over a hanging cable.
        let numberColor = isSelected ? Theme.HW.plateLabelSel : Theme.HW.plateLabel
        let np = s.point(CGPoint(x: r.midX, y: port.top ? r.minY - 10.6 : r.maxY + 12.6))
        let size = labelSize(port.label, width: r.width)
        for (dx, dy) in [(-1.1, 0.0), (1.1, 0.0), (0.0, -1.1), (0.0, 1.1)] {
            ctx.draw(Text(port.label).font(.system(size: size * k, weight: .semibold)).foregroundStyle(Color(hex: 0x23282D)),
                     at: CGPoint(x: np.x + dx * k, y: np.y + dy * k), anchor: .center)
        }
        ctx.draw(Text(port.label).font(.system(size: size * k, weight: isSelected ? .bold : .semibold)).foregroundStyle(numberColor),
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
        let r = port.frame
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
