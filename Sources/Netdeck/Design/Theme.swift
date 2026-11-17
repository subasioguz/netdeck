import AppKit
import SwiftUI

// Design tokens from docs/DESIGN.md §1. Every color adapts to light/dark through NSColor's
// dynamic provider, so views only ever reference `Theme.*`.

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    static func dynamic(_ light: Color, _ dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        .dynamic(Color(hex: light), Color(hex: dark))
    }
}

enum Theme {
    // 1.1 Surfaces and text
    static let frame = Color.dynamic(0xEBEBEE, 0x0E0F11)
    static let surface = Color.dynamic(0xFFFFFF, 0x17181B)
    static let surface2 = Color.dynamic(0xF7F7F8, 0x1D1E22)
    static let surface3 = Color.dynamic(0xF0F0F2, 0x25262B)
    static let border = Color.dynamic(0xE4E4E8, 0x2A2B31)
    static let borderStrong = Color.dynamic(0xD5D5DB, 0x3A3B42)
    static let text1 = Color.dynamic(0x111114, 0xF3F3F5)
    static let text2 = Color.dynamic(0x55555F, 0xA6A6B0)
    static let text3 = Color.dynamic(0x8C8C96, 0x74747E)
    static let text4 = Color.dynamic(0xB9B9C1, 0x4E4E57)

    static let accent = Color.dynamic(0x2F6BFF, 0x5B8CFF)
    static let accentSoft = Color.dynamic(Color(hex: 0xEAF0FF), Color(hex: 0x5B8CFF, opacity: 0.14))
    static let accentInk = Color.dynamic(0x1F4FD1, 0x9DB8FF)
    static let primary = Color.dynamic(0x111114, 0xF3F3F5)
    static let onPrimary = Color.dynamic(0xFFFFFF, 0x111114)

    static let good = Color.dynamic(0x16A34A, 0x3DD68C)
    static let goodSoft = Color.dynamic(Color(hex: 0xE7F7EC), Color(hex: 0x3DD68C, opacity: 0.12))
    static let goodLine = Color.dynamic(Color(hex: 0xBDE7CA), Color(hex: 0x3DD68C, opacity: 0.28))
    static let goodInk = Color.dynamic(0x157A3B, 0x6EE3A6)

    static let warn = Color.dynamic(0xF59E0B, 0xFFB224)
    static let warnSoft = Color.dynamic(Color(hex: 0xFFF5E1), Color(hex: 0xFFB224, opacity: 0.12))
    static let warnLine = Color.dynamic(Color(hex: 0xF8DBA6), Color(hex: 0xFFB224, opacity: 0.30))
    static let warnInk = Color.dynamic(0xA2560A, 0xFFC95C)

    static let danger = Color.dynamic(0xE5484D, 0xFF6369)
    static let dangerSoft = Color.dynamic(Color(hex: 0xFDECEC), Color(hex: 0xFF6369, opacity: 0.12))
    static let dangerLine = Color.dynamic(Color(hex: 0xF6C7C8), Color(hex: 0xFF6369, opacity: 0.30))
    static let dangerInk = Color.dynamic(0xC02F35, 0xFF8F93)

    static let stagedBar = Color.dynamic(0x121215, 0xF3F3F5)
    static let onStagedBar = Color.dynamic(0xFFFFFF, 0x111114)
    static let darkTile = Color.dynamic(0x1F2328, 0xF3F3F5)
    static let onDarkTile = Color.dynamic(0xFFFFFF, 0x111114)

    // Stage gradient (§2)
    static let stageCenter = Color.dynamic(0xFFFFFF, 0x24262B)
    static let stageMid = Color.dynamic(0xF6F6F8, 0x1A1B1F)
    static let stageEdge = Color.dynamic(0xEFEFF2, 0x141518)

    // Hardware (same in both modes)
    enum HW {
        static let ledGreen = Color(hex: 0x3BE37A)
        static let ledAmber = Color(hex: 0xFFB020)
        static let ledAmberDim = Color(hex: 0xC98A1A)
        static let ledOff = Color(hex: 0x1A1E22)
        static let plateLabel = Color(hex: 0xA3ACB5)
        static let plateLabelDim = Color(hex: 0x5C656D)
        static let plateLabelSel = Color.white
        static let metalAccent = Color(hex: 0x3B76FF)
    }
}

// MARK: - VLAN palette (§1.2)

struct VLANColor: Equatable, Hashable {
    let name: String
    let base: Color
    let soft: Color
    let ink: Color

    init(_ name: String, base: UInt32, softLight: UInt32, inkLight: UInt32, darkSoftOpacity: Double, inkDark: UInt32) {
        self.name = name
        self.base = Color(hex: base)
        self.soft = .dynamic(Color(hex: softLight), Color(hex: base, opacity: darkSoftOpacity))
        self.ink = .dynamic(inkLight, inkDark)
    }

    static let palette: [VLANColor] = [
        VLANColor("Violet", base: 0x8E62F8, softLight: 0xF0EAFE, inkLight: 0x5F35C9, darkSoftOpacity: 0.18, inkDark: 0xBBA0FF),
        VLANColor("Orange", base: 0xF7893B, softLight: 0xFEEEE2, inkLight: 0xB2541A, darkSoftOpacity: 0.16, inkDark: 0xFFB283),
        VLANColor("Sky", base: 0x2AA9E0, softLight: 0xE2F4FC, inkLight: 0x12729C, darkSoftOpacity: 0.16, inkDark: 0x7CCDF0),
        VLANColor("Teal", base: 0x22B39B, softLight: 0xE0F6F2, inkLight: 0x137767, darkSoftOpacity: 0.16, inkDark: 0x6FD8C6),
        VLANColor("Mustard", base: 0xE0AE2A, softLight: 0xFBF3DA, inkLight: 0x8A6611, darkSoftOpacity: 0.16, inkDark: 0xF0CB68),
        VLANColor("Orchid", base: 0xD45BC9, softLight: 0xFAE8F8, inkLight: 0x9C3092, darkSoftOpacity: 0.16, inkDark: 0xEC97E3),
        VLANColor("Cobalt", base: 0x4F6EF7, softLight: 0xE9EDFE, inkLight: 0x2E46C2, darkSoftOpacity: 0.18, inkDark: 0xA3B4FF),
        VLANColor("Pink", base: 0xF06292, softLight: 0xFDE8EF, inkLight: 0xB7335F, darkSoftOpacity: 0.16, inkDark: 0xF89DBC),
        VLANColor("Lime", base: 0x8CC63F, softLight: 0xEEF7E1, inkLight: 0x557A1E, darkSoftOpacity: 0.16, inkDark: 0xB7E07D),
    ]
    static let slate = VLANColor("Slate", base: 0x8A94A6, softLight: 0xEEF0F4, inkLight: 0x4E5868, darkSoftOpacity: 0.16, inkDark: 0xB7C0CF)
}

// MARK: - Pastel avatars (§1.3)

enum Avatar: String, CaseIterable, Codable {
    case lavender, mint, sky, peach, rose, butter, slate

    var fill: Color {
        switch self {
        case .lavender: return .dynamic(Color(hex: 0xEEE9FE), Color(hex: 0x8E62F8, opacity: 0.20))
        case .mint: return .dynamic(Color(hex: 0xE2F5EA), Color(hex: 0x3DD68C, opacity: 0.16))
        case .sky: return .dynamic(Color(hex: 0xE1F0FC), Color(hex: 0x2AA9E0, opacity: 0.18))
        case .peach: return .dynamic(Color(hex: 0xFDEADB), Color(hex: 0xF7893B, opacity: 0.18))
        case .rose: return .dynamic(Color(hex: 0xFCE6EE), Color(hex: 0xF06292, opacity: 0.18))
        case .butter: return .dynamic(Color(hex: 0xFAF1D2), Color(hex: 0xE0AE2A, opacity: 0.18))
        case .slate: return .dynamic(Color(hex: 0xECEEF2), Color(hex: 0x8A94A6, opacity: 0.18))
        }
    }

    var ink: Color {
        switch self {
        case .lavender: return .dynamic(0x6A48DB, 0xC3AEFF)
        case .mint: return .dynamic(0x1F8650, 0x7FE3B0)
        case .sky: return .dynamic(0x1E6CB3, 0x8AD3F3)
        case .peach: return .dynamic(0xBC5E1C, 0xFFB98A)
        case .rose: return .dynamic(0xBF386A, 0xF89DBC)
        case .butter: return .dynamic(0x93700F, 0xF0CB68)
        case .slate: return .dynamic(0x5A6372, 0xC1C8D4)
        }
    }
}

// MARK: - Typography (§1.4)

enum Typo {
    static let title1 = Font.system(size: 22, weight: .semibold)
    static let portTitle = Font.system(size: 20, weight: .semibold)
    static let sheetTitle = Font.system(size: 18, weight: .semibold)
    static let banner = Font.system(size: 16, weight: .semibold).monospacedDigit()
    static let cardTitle = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyStrong = Font.system(size: 13, weight: .semibold)
    static let callout = Font.system(size: 12.5)
    static let caption = Font.system(size: 12)
    static let captionStrong = Font.system(size: 12, weight: .semibold)
    static let chip = Font.system(size: 11.5, weight: .medium)
    static let micro = Font.system(size: 11)
    static let microHeading = Font.system(size: 11, weight: .semibold)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let countdownRing = Font.system(size: 19, weight: .bold).monospacedDigit()
    static let percent = Font.system(size: 26, weight: .bold).monospacedDigit()
}

// MARK: - Shadows (§1.5)

struct CardStyle: ViewModifier {
    var radius: CGFloat = 16
    var raised = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(Theme.surface))
            .overlay(shape.strokeBorder(scheme == .dark ? Color.white.opacity(raised ? 0.06 : 0.05) : Color.black.opacity(0.035), lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? (raised ? 0.45 : 0) : (raised ? 0.08 : 0.04)),
                    radius: raised ? (scheme == .dark ? 15 : 12) : 1, y: raised ? (scheme == .dark ? 10 : 8) : 1)
            .shadow(color: .black.opacity(scheme == .dark || !raised ? 0 : 0.05), radius: 1, y: 1)
    }
}

extension View {
    func card(radius: CGFloat = 16, raised: Bool = false) -> some View { modifier(CardStyle(radius: radius, raised: raised)) }
}
