import SwiftUI

/// The Netdeck mark ("Patch N"): the letter N drawn as one patch cable with an RJ-45 plug at each end.
/// Geometry comes from docs/brand/netdeck-mark.svg (1024-unit grid, glyph box 444 x 568 at 290, 228).
/// It is a plain `Shape`, so it stays crisp at any size and takes any fill.
struct BrandMark: Shape {
    enum Detail {
        /// Heavier cable and no plug contacts. Use below 24 pt (sidebar logo, menu bar).
        case small
        /// Plug contacts cut out. Use at 24 pt and up.
        case full
    }

    var detail: Detail = .small

    static let box = CGRect(x: 290, y: 228, width: 444, height: 568)
    static let aspectRatio = box.width / box.height

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / Self.box.width, rect.height / Self.box.height)
        let size = CGSize(width: Self.box.width * scale, height: Self.box.height * scale)
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        let transform = CGAffineTransform(translationX: origin.x, y: origin.y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -Self.box.minX, y: -Self.box.minY)
        return Self.markPath(detail).applying(transform)
    }

    /// The mark in its own 1024-unit coordinates.
    static func markPath(_ detail: Detail) -> Path {
        // One stroke: up the left stem, 45° run down to the right, up the right stem. Bend radius 118.
        var cable = Path()
        cable.move(to: CGPoint(x: 360, y: 662))
        cable.addLine(to: CGPoint(x: 360, y: 480))
        cable.addQuadCurve(to: CGPoint(x: 443.44, y: 445.44), control: CGPoint(x: 360, y: 362))
        cable.addLine(to: CGPoint(x: 580.56, y: 578.56))
        cable.addQuadCurve(to: CGPoint(x: 664, y: 544), control: CGPoint(x: 664, y: 662))
        cable.addLine(to: CGPoint(x: 664, y: 362))
        let width: CGFloat = detail == .small ? 104 : 96
        var mark = cable.strokedPath(StrokeStyle(lineWidth: width, lineCap: .butt, lineJoin: .round))

        // Boots (strain reliefs) and plug bodies at both ends.
        var parts = Path()
        parts.addRoundedRect(in: CGRect(x: 302, y: 660, width: 116, height: 34), cornerSize: CGSize(width: 6, height: 6))
        parts.addRoundedRect(in: CGRect(x: 606, y: 330, width: 116, height: 34), cornerSize: CGSize(width: 6, height: 6))
        mark = mark.union(parts)
        var plugs = Path()
        plugs.addRoundedRect(in: CGRect(x: 290, y: 692, width: 140, height: 104), cornerSize: CGSize(width: 20, height: 20), style: .continuous)
        plugs.addRoundedRect(in: CGRect(x: 594, y: 228, width: 140, height: 104), cornerSize: CGSize(width: 20, height: 20), style: .continuous)
        mark = mark.union(plugs)

        guard detail == .full else { return mark }
        // Eight contacts near the tip of each plug.
        var contacts = Path()
        for (cx, top) in [(CGFloat(360), CGFloat(762)), (664, 238)] {
            for k in 0..<8 {
                let x = cx - 47.5 + CGFloat(k) * 13.6
                contacts.addRoundedRect(in: CGRect(x: x, y: top, width: 6, height: 24), cornerSize: CGSize(width: 3, height: 3))
            }
        }
        return mark.subtracting(contacts)
    }
}

/// The 28 pt sidebar logo (§2): the mark on a rounded `primary` square, inverted in dark mode.
struct BrandLogo: View {
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 8 / 28, style: .continuous)
            .fill(Theme.primary)
            .frame(width: size, height: size)
            .overlay(
                BrandMark(detail: size >= 40 ? .full : .small)
                    .fill(Theme.onPrimary)
                    .frame(width: size * 0.6 * BrandMark.aspectRatio, height: size * 0.6)
            )
            .accessibilityHidden(true)
    }
}
