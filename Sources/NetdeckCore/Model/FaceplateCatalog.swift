import Foundation

/// How a known model's front panel looks: port groups from left to right, how the numbers alternate
/// between rows, and the non-network ports (console, management, USB). Models without a spec get the
/// generic layout. Specs live in `Resources/Faceplates/faceplates.json`.
public struct FaceplateSpec: Codable, Sendable, Equatable {
    public enum Order: String, Codable, Sendable {
        /// 0 or 1 on top, the next number below it (Juniper "top-even", Cisco "top-odd").
        case topEven = "top-even", topOdd = "top-odd"
        /// The first number at the bottom, the next above it (MikroTik CRS/CCR).
        case bottomFirst = "bottom-first"
        /// Top row holds the first half, bottom row the second half.
        case topFirstHalf = "top-first-half"
        case singleRow = "single-row"
    }

    public struct Group: Codable, Sendable, Equatable {
        /// Network ports: rj45, combo, sfp, sfp+, sfp28, qsfp+, qsfp28. Other parts of the panel:
        /// console-rj45, console-usb, console-db9, mgmt-rj45, usb, reset, power-dc, sfp-aux (a cage
        /// that isn't a network port, e.g. HA control), aux, and module-slot (uplink/expansion module:
        /// ports the other groups don't name go there).
        public var kind: String
        /// Interface names, e.g. "ge-0/0/0..23", "ether1..24", "GigabitEthernet1/0/1..48".
        public var names: String?
        /// Numbers or words printed next to each port, one per name.
        public var labels: [String]?
        public var rows: Int?
        public var order: Order?
        /// Ports per visual block (a gap between blocks); 0 = one block.
        public var block: Int?
        /// Uneven blocks, e.g. [8, 16] (EX4100-24T).
        public var blockSizes: [Int]?
        /// left, center or right part of the panel.
        public var position: String?
        /// Text printed by a non-network part ("CONSOLE", "RESET") or a module slot's module name.
        public var label: String?

        public init(kind: String, names: String? = nil, labels: [String]? = nil, rows: Int? = nil, order: Order? = nil,
                    block: Int? = nil, blockSizes: [Int]? = nil, position: String? = nil, label: String? = nil) {
            self.kind = kind; self.names = names; self.labels = labels; self.rows = rows; self.order = order
            self.block = block; self.blockSizes = blockSizes; self.position = position; self.label = label
        }

        public var isNetwork: Bool { names != nil }
        public var isModuleSlot: Bool { kind == "module-slot" }
        public var isCage: Bool { kind.hasPrefix("sfp") || kind.hasPrefix("qsfp") }
        public var isWide: Bool { kind.hasPrefix("qsfp") }
    }

    public var model: String
    /// Model name prefixes (case-insensitive) that share this panel.
    public var match: [String]
    public var vendor: String?
    /// 1U-19in, desktop...
    public var form: String?
    public var groups: [Group]

    public init(model: String, match: [String], vendor: String? = nil, form: String? = nil, groups: [Group]) {
        self.model = model
        self.match = match
        self.vendor = vendor
        self.form = form
        self.groups = groups
    }

    /// Rack units have mounting ears; desktop units have none.
    public var hasEars: Bool { !(form ?? "").hasPrefix("desktop") }
}

public enum FaceplateCatalog {
    /// All bundled specs (loaded once).
    public static let all: [FaceplateSpec] = {
        guard let url = Bundle.module.url(forResource: "faceplates", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([FaceplateSpec].self, from: data)) ?? []
    }()

    /// The spec for a model: the longest matching prefix wins ("EX4300-48MP" over "EX4300-48").
    public static func spec(forModel model: String, in specs: [FaceplateSpec] = all) -> FaceplateSpec? {
        let m = model.uppercased()
        var best: (spec: FaceplateSpec, length: Int)?
        for s in specs {
            for prefix in s.match where m.hasPrefix(prefix.uppercased()) && prefix.count > (best?.length ?? 0) {
                best = (s, prefix.count)
            }
        }
        return best?.spec
    }

    /// "ge-0/0/0..23" → ge-0/0/0 … ge-0/0/23; "ether1..24" → ether1 … ether24; a plain name → itself;
    /// several ranges separated by commas.
    public static func expand(_ pattern: String) -> [String] {
        pattern.split(separator: ",").flatMap { part -> [String] in
            let p = part.trimmingCharacters(in: .whitespaces)
            guard let dots = p.range(of: "..") else { return [p] }
            let head = p[..<dots.lowerBound], tail = p[dots.upperBound...]
            let digits = head.reversed().prefix { $0.isNumber }
            guard !digits.isEmpty, let a = Int(String(digits.reversed())), let b = Int(tail) else { return [p] }
            let prefix = head.dropLast(digits.count)
            return (min(a, b)...max(a, b)).map { "\(prefix)\($0)" }
        }
    }
}
