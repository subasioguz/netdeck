import Foundation

/// Juniper model traits that decide how ports are drawn: which PIC sits on the rear, which ports
/// are SFP cages. Covers EX, QFX, SRX and MX; unknown models get the EX rules.
public struct JunosModel: Sendable, Equatable {
    /// Upper-cased model name ("EX4300-48T", "SRX345", "MX204").
    public let model: String

    public init(_ model: String) { self.model = model.uppercased() }

    /// Product line: "EX", "QFX", "SRX", "VSRX", "MX", "PTX", "ACX", or "" when unknown.
    public var series: String {
        for s in ["QFX", "VSRX", "SRX", "EX", "MX", "PTX", "ACX"] where model.hasPrefix(s) { return s }
        return ""
    }

    /// Rear QSFP+ PIC used for Virtual Chassis (EX4300). `nil` when the model has none.
    public var rearPIC: Int? { model.hasPrefix("EX4300") ? 1 : nil }

    /// Juniper MX and PTX are routers: no Ethernet switching, every port is routed.
    public var isRouter: Bool { ["MX", "PTX", "ACX"].contains(series) }

    /// A front-panel port: `ge-`, `xe-`, `mge-` or `et-` with FPC/PIC/port, not on the rear PIC and not
    /// a channelized sub-port (`et-0/0/0:1`).
    public func isFrontPanel(_ name: String) -> Bool {
        guard let (pic, _) = Self.picPort(name), !name.contains(":") else { return false }
        if let rearPIC, pic == rearPIC { return false }
        return true
    }

    /// An SFP/QSFP cage rather than an RJ-45 copper port.
    public func isCage(_ name: String, hasModule: Bool) -> Bool {
        guard let (pic, port) = Self.picPort(name) else { return false }
        if hasModule { return true }
        if name.hasPrefix("mge-") { return false }                      // multi-gigabit copper
        if ["MX", "PTX"].contains(series) { return true }               // optical line cards
        if name.hasPrefix("xe-") || name.hasPrefix("et-") {
            // 10GBASE-T switches (QFX5100-48T, QFX5120-48T) have copper xe- ports.
            if series == "QFX" && pic == 0 && (model.contains("-48T") || model.contains("-24T")) { return false }
            return true
        }
        if pic != 0 { return true }                                     // uplink modules
        if series == "QFX" || model.contains("-32F") || model.contains("-24F") || model.contains("-48F") { return true }
        if series == "SRX", let first = srxFirstSFPPort { return port >= first }
        return false
    }

    /// Empty uplink cages don't appear in `show interfaces terse` on EX; Netdeck lists them from the
    /// hardware inventory instead. Other series list every port.
    public func listsEmptyCages(pic: Int) -> Bool { (series == "EX" || series.isEmpty) && pic >= 1 }

    /// First `ge-0/0/N` port that is an SFP cage on branch SRX models.
    var srxFirstSFPPort: Int? {
        let table: [(String, Int)] = [("SRX300", 6), ("SRX320", 6), ("SRX340", 8), ("SRX345", 8), ("SRX380", 16),
                                      ("SRX550", 6), ("SRX1500", 12), ("SRX1600", 12)]
        return table.first { model.hasPrefix($0.0) }?.1
    }

    /// "ge-0/2/1" → (2, 1); nil for names without FPC/PIC/port.
    static func picPort(_ name: String) -> (pic: Int, port: Int)? {
        let prefixes = ["ge-", "xe-", "mge-", "et-"]
        guard let pfx = prefixes.first(where: { name.hasPrefix($0) }) else { return nil }
        let parts = name.dropFirst(pfx.count).split(separator: "/")
        guard parts.count == 3, let pic = Int(parts[1]), let port = Int(parts[2].prefix { $0.isNumber }) else { return nil }
        return (pic, port)
    }
}
