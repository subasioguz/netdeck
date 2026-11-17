import NetdeckCore
import SwiftUI

// Reusable pieces from docs/DESIGN.md §4.

// MARK: - Pills (§4.4)

enum PillKind { case good, warn, danger, accent, outline, neutral, dark }

struct Pill: View {
    var text: String
    var kind: PillKind = .neutral
    var dot = false
    var icon: String?
    /// 20 high, 11 pt: pills inside list rows (history timeline).
    var small = false

    var body: some View {
        HStack(spacing: small ? 4 : 5) {
            if dot { Circle().fill(dotColor).frame(width: 6, height: 6) }
            if let icon { Image(systemName: icon).font(.system(size: small ? 10 : 10.5, weight: .semibold)) }
            Text(text).lineLimit(1)
        }
        .font(small ? .system(size: 11, weight: .medium) : Typo.chip)
        .foregroundStyle(ink)
        .padding(.horizontal, small ? 7 : 9)
        .frame(height: small ? 20 : 22)
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(line, lineWidth: 1))
        .fixedSize()
    }

    private var fill: Color {
        switch kind {
        case .good: return Theme.goodSoft
        case .warn: return Theme.warnSoft
        case .danger: return Theme.dangerSoft
        case .accent: return Theme.accentSoft
        case .outline: return .clear
        case .neutral: return Theme.surface3
        case .dark: return Theme.primary
        }
    }

    private var ink: Color {
        switch kind {
        case .good: return Theme.goodInk
        case .warn: return Theme.warnInk
        case .danger: return Theme.dangerInk
        case .accent: return Theme.accentInk
        case .outline, .neutral: return Theme.text2
        case .dark: return Theme.onPrimary
        }
    }

    private var line: Color {
        switch kind {
        case .good: return Theme.goodLine
        case .warn: return Theme.warnLine
        case .danger: return Theme.dangerLine
        case .accent: return Theme.accent.opacity(0.25)
        case .outline: return Theme.borderStrong
        case .neutral, .dark: return .clear
        }
    }

    private var dotColor: Color {
        switch kind {
        case .good: return Theme.good
        case .warn: return Theme.warn
        case .danger: return Theme.danger
        case .accent: return Theme.accent
        default: return Theme.text3
        }
    }
}

// MARK: - VLAN chip (§4.3)

struct VLANChip: View {
    var name: String
    var vlanID: Int?
    var color: VLANColor
    var size: Size = .regular
    enum Size { case small, regular, large }

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color.base)
                .frame(width: size == .small ? 8 : 10, height: size == .small ? 8 : 10)
            Text(name).lineLimit(1)
            if let vlanID { Text(String(vlanID)).opacity(0.7).monospacedDigit() }
        }
        .font(.system(size: size == .small ? 11 : 12, weight: .medium))
        .foregroundStyle(color.ink)
        .padding(.horizontal, size == .small ? 7 : 9)
        .frame(height: size == .small ? 20 : (size == .large ? 28 : 24))
        .background(Capsule().fill(color.soft))
        .overlay(Capsule().strokeBorder(color.base.opacity(0.22), lineWidth: 1))
        .fixedSize()
    }
}

// MARK: - Status dot (§4.11)

enum DeviceStatus { case connected, connecting, awaiting, failed, offline, basic }

struct StatusDot: View {
    var status: DeviceStatus
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .background(Circle().fill(color.opacity(status == .offline ? 0 : 0.22)).frame(width: 14, height: 14))
            .frame(width: 14, height: 14)
    }
    private var color: Color {
        switch status {
        case .connected: return Theme.good
        case .connecting: return Theme.accent
        case .awaiting: return Theme.warn
        case .failed: return Theme.danger
        case .offline, .basic: return Theme.text4
        }
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onPrimary)
            .padding(.horizontal, large ? 18 : 14)
            .frame(height: large ? 40 : 32)
            .background(RoundedRectangle(cornerRadius: large ? 10 : 8, style: .continuous).fill(Theme.primary))
            .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.35)
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var large = false
    var destructive = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(destructive ? Theme.dangerInk : Theme.text1)
            .padding(.horizontal, large ? 16 : 12)
            .frame(height: large ? 40 : 32)
            .background(RoundedRectangle(cornerRadius: large ? 10 : 8, style: .continuous).fill(configuration.isPressed ? Theme.surface3 : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: large ? 10 : 8, style: .continuous)
                .strokeBorder(destructive ? Theme.dangerLine : Theme.borderStrong, lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

struct PlainLinkStyle: ButtonStyle {
    var color: Color = Theme.accentInk
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(color)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text2)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(configuration.isPressed ? Theme.surface3 : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

// MARK: - Segmented control (custom, §1.5 radii)

struct Segmented<Value: Hashable>: View {
    var options: [(Value, String, String?)]   // value, label, optional SF symbol
    @Binding var selection: Value
    var compact = false
    /// Fills the available width with equal segments (Speed in Add device).
    var stretch = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.0 == selection
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option.0 }
                } label: {
                    HStack(spacing: 6) {
                        if let icon = option.2 { Image(systemName: icon).font(.system(size: 11.5, weight: .medium)) }
                        Text(option.1).lineLimit(1)
                    }
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.text1 : Theme.text2)
                    .padding(.horizontal, compact ? 10 : 14)
                    .frame(maxWidth: stretch ? .infinity : nil)
                    .frame(height: compact ? 24 : 28)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface)
                                .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surface3))
        .fixedSize(horizontal: !stretch, vertical: true)
    }
}

// MARK: - Option card with radio (§4.7)

struct OptionCard<Trailing: View>: View {
    var title: String
    var subtitle: String?
    var selected: Bool
    var disabled = false
    var action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Radio(selected: selected).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Typo.bodyStrong).foregroundStyle(disabled ? Theme.text4 : Theme.text1)
                    if let subtitle {
                        Text(subtitle).font(Typo.caption).foregroundStyle(disabled ? Theme.text4 : Theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                trailing()
            }
            .padding(12)
            // Fills the height it is offered: side-by-side pairs (in a vertically fixed-size HStack) stay
            // equally tall when one title wraps and the other doesn't (longer Turkish labels).
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Theme.text1 : Theme.borderStrong, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

extension OptionCard where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, selected: Bool, disabled: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, selected: selected, disabled: disabled, action: action) { EmptyView() }
    }
}

struct Radio: View {
    var selected: Bool
    var body: some View {
        ZStack {
            Circle().strokeBorder(selected ? Theme.text1 : Theme.borderStrong, lineWidth: selected ? 5 : 1.5)
        }
        .frame(width: 16, height: 16)
    }
}

// MARK: - Toggle (§4.7 switch row)

struct NDSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.good : Theme.borderStrong)
                Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            }
            .frame(width: 34, height: 20)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? t("On") : t("Off"))
    }
}

// MARK: - Value row (§4.7)

struct ValueRow: View {
    var label: String
    var value: String
    var mono = false
    var body: some View {
        HStack(spacing: 12) {
            // Long labels (German compounds) shrink a little instead of wrapping mid-word.
            Text(label).font(Typo.body).foregroundStyle(Theme.text3).lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 8)
            Text(value).font(mono ? Typo.mono : .system(size: 13, weight: .medium)).foregroundStyle(Theme.text1)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .frame(height: 32)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

// MARK: - Field label and text field

struct FieldLabel: View {
    var text: String
    var body: some View { Text(text).font(Typo.captionStrong).foregroundStyle(Theme.text2) }
}

struct NDTextField: View {
    var placeholder: String
    @Binding var text: String
    var changed = false
    var secure = false
    var mono = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if RenderMode.active {
                // ImageRenderer draws AppKit text fields as placeholders; show the value instead.
                Text(text.isEmpty ? placeholder : (secure ? String(repeating: "•", count: text.count) : text))
                    .foregroundStyle(text.isEmpty ? Theme.text4 : Theme.text1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(mono ? Typo.mono : Typo.body)
        .focused($focused)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(changed ? Theme.accentSoft.opacity(0.55) : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(focused || changed ? Theme.accent.opacity(focused ? 1 : 0.55) : Theme.borderStrong, lineWidth: 1))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.accent.opacity(focused ? 0.22 : 0), lineWidth: 3).padding(-1.5))
    }
}

// MARK: - Type tile (§1.3) and avatar

struct TypeTile: View {
    var kind: DeviceKind
    var size: CGFloat = 32
    var dark = false
    var body: some View {
        RoundedRectangle(cornerRadius: size >= 40 ? 11 : 9, style: .continuous)
            .fill(dark ? Theme.darkTile : Theme.surface3)
            .frame(width: size, height: size)
            .overlay(Image(systemName: kind.symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(dark ? Theme.onDarkTile : Theme.text1))
    }
}

struct AvatarCircle: View {
    var symbol: String
    var avatar: Avatar
    var size: CGFloat = 24
    var body: some View {
        Circle().fill(avatar.fill).frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.48, weight: .medium)).foregroundStyle(avatar.ink))
    }
}

// MARK: - Countdown ring (§3.9)

struct CountdownRing: View {
    var remaining: TimeInterval
    var total: TimeInterval
    var size: CGFloat = 72
    var showText = true

    var body: some View {
        let critical = remaining <= 60
        let color = critical ? Theme.danger : Theme.warn
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: size > 40 ? 6 : 3.5)
            Circle().trim(from: 0, to: max(0, min(1, remaining / max(total, 1))))
                .stroke(color, style: StrokeStyle(lineWidth: size > 40 ? 6 : 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showText {
                Text(Format.countdown(remaining)).font(size > 40 ? Typo.countdownRing : .system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(critical ? Theme.dangerInk : Theme.warnInk)
            }
        }
        .frame(width: size, height: size)
    }
}

enum Format {
    static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale))
    }

    /// Plural forms are separate strings (§8): pass both, already translated ("1 port" / "3 ports").
    static func plural(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? one : many }

    static func relativeDay(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return t("Today %@", time(date)) }
        if Calendar.current.isDateInYesterday(date) { return t("Yesterday %@", time(date)) }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))
    }
}

// MARK: - Menus

/// A `Menu` whose label is drawn by us. `ImageRenderer` can't draw AppKit menus, so renders
/// show only the label.
struct NDMenu<Label: View, Content: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label

    var body: some View {
        if RenderMode.active {
            label()
        } else {
            Menu(content: content, label: label)
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
        }
    }
}

/// Picker-looking field (`.sel-in` / `.input` in the mockups): icon, value or placeholder, up-down chevron.
struct PickerField: View {
    var icon: String?
    var text: String
    var placeholder = false
    var mono = false
    var body: some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text3) }
            Text(text).font(mono ? .system(size: 12.5, design: .monospaced) : .system(size: 12.5, weight: .medium))
                .foregroundStyle(placeholder ? Theme.text4 : Theme.text1).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

// MARK: - Section heading

struct MicroHeading: View {
    var text: String
    var body: some View {
        Text(text.uppercased(with: L10n.locale)).font(Typo.microHeading).tracking(0.6).foregroundStyle(Theme.text3)
    }
}

// MARK: - Render-safe containers

/// `ImageRenderer` draws AppKit-backed views (ScrollView, drag and drop) as placeholders. While
/// `SnapshotRenderer` runs, these helpers fall back to plain SwiftUI so the renders show real content.
enum RenderMode {
    @MainActor static var active = false
}

struct NDScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if RenderMode.active {
            // minHeight 0: take the offered height and clip like a scroll view would, instead of growing to the
            // content's full height and pushing the rest of the window out (long lists such as the port table).
            VStack(spacing: 0) { content() }.frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped()
        } else {
            ScrollView(.vertical) { content() }.scrollIndicators(.automatic)
        }
    }
}

extension View {
    /// Drag a device ID (sidebar rows); skipped in renders.
    @ViewBuilder func deviceDrag(_ id: String) -> some View {
        if RenderMode.active { self } else { self.draggable(id) }
    }

    /// Drop device IDs (location groups); skipped in renders.
    @ViewBuilder func deviceDrop(_ action: @escaping ([String]) -> Bool) -> some View {
        if RenderMode.active { self } else { self.dropDestination(for: String.self) { ids, _ in action(ids) } }
    }
}
