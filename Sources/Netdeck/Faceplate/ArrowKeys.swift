import AppKit
import SwiftUI

/// Keyboard navigation on the faceplate (§6.9): ←/→ along a row, ↑/↓ between rows.
enum ArrowKey { case left, right, up, down }

extension FrontGeometry {
    /// The port the arrow key moves to: ←/→ the nearest port along the same row (continuing from the
    /// copper block into the uplink cages and back), ↑/↓ the port right above or below. With nothing
    /// selected, the first port.
    static func neighbor(of key: String?, in ports: [PanelPort], _ dir: ArrowKey) -> String? {
        guard let cur = key.flatMap({ k in ports.first { $0.slotKey == k } }) else { return ports.first?.slotKey }
        let c = rect(for: cur)
        let others = ports.filter { $0.slotKey != cur.slotKey }.map { (key: $0.slotKey, r: rect(for: $0)) }
        let dx = { (r: CGRect) in abs(r.midX - c.midX) }, dy = { (r: CGRect) in abs(r.midY - c.midY) }
        switch dir {
        case .left, .right:
            let sign: CGFloat = dir == .right ? 1 : -1
            let ahead = others.filter { ($0.r.midX - c.midX) * sign > 1 }
            if let p = ahead.filter({ dy($0.r) < 4 }).min(by: { dx($0.r) < dx($1.r) }) { return p.key }
            return ahead.min { (dx($0.r), dy($0.r)) < (dx($1.r), dy($1.r)) }?.key
        case .up, .down:
            let sign: CGFloat = dir == .down ? 1 : -1
            return others.filter { ($0.r.midY - c.midY) * sign > 4 && dx($0.r) < 14 }.min { dy($0.r) < dy($1.r) }?.key
        }
    }
}

extension RearGeometry {
    /// Rear panel parts sit in one row: ←/→ walk power supplies, fans, QSFP+ ports, management and console.
    static func neighbor(of item: RearItem?, _ dir: ArrowKey) -> RearItem? {
        let order = items.filter { $0 != .usb }
        guard let item, let i = order.firstIndex(of: item) else { return order.first }
        switch dir {
        case .left: return i > 0 ? order[i - 1] : nil
        case .right: return i + 1 < order.count ? order[i + 1] : nil
        case .up, .down: return nil
        }
    }
}

/// Delivers plain arrow keys pressed in this view's window to `onArrow` (return true to consume).
/// Ignored while a text field is being edited (its field editor is first responder), while a sheet or
/// popover has the keys, or with modifier keys held. Not installed in renders.
struct ArrowKeyMonitor: NSViewRepresentable {
    var onArrow: (ArrowKey) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let v = MonitorView()
        v.onArrow = onArrow
        return v
    }

    func updateNSView(_ v: MonitorView, context: Context) { v.onArrow = onArrow }

    final class MonitorView: NSView {
        var onArrow: ((ArrowKey) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) == true }
                return handled ? nil : event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil,
                  !(window.firstResponder is NSText),
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
            let key: ArrowKey
            switch event.keyCode {
            case 123: key = .left
            case 124: key = .right
            case 125: key = .down
            case 126: key = .up
            default: return false
            }
            return onArrow?(key) ?? false
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
