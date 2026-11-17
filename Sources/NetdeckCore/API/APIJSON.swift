import Foundation

/// Loosely typed view of decoded JSON. Device APIs differ between firmware versions, so every lookup is
/// optional: a missing or mistyped field reads as nil instead of failing the whole reading.
struct APIJSON {
    let value: Any?

    init(_ value: Any?) { self.value = value }

    init(data: Data) {
        value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    subscript(key: String) -> APIJSON { APIJSON((value as? [String: Any])?[key]) }

    subscript(index: Int) -> APIJSON {
        guard let a = value as? [Any], a.indices.contains(index) else { return APIJSON(nil) }
        return APIJSON(a[index])
    }

    var exists: Bool { value != nil && !(value is NSNull) }
    var isObject: Bool { value is [String: Any] }
    var array: [APIJSON] { (value as? [Any])?.map { APIJSON($0) } ?? [] }
    var keys: [String] { (value as? [String: Any]).map { Array($0.keys) } ?? [] }

    /// A non-empty, trimmed string. Numbers are not converted (see `text`).
    var string: String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A string, or a number written out ("4", "3.5").
    var text: String? {
        if let s = string { return s }
        if let d = double { return APIFormat.number(d) }
        return nil
    }

    /// NSNumber that isn't a JSON boolean.
    private var number: NSNumber? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n
    }

    /// A number, or a string holding one (Synology sends sizes as strings).
    var double: Double? {
        if let n = number { return n.doubleValue }
        if let s = string, let d = Double(s), d.isFinite { return d }
        return nil
    }

    var int64: Int64? {
        if let s = string, let i = Int64(s) { return i }
        guard let d = double, d.isFinite, abs(d) < 9.2e18 else { return nil }
        return Int64(d)
    }

    var int: Int? { int64.map { Int($0) } }

    var bool: Bool? {
        if let n = value as? NSNumber { return n.boolValue }
        switch string?.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    /// Redfish link (`{"@odata.id": "/redfish/v1/..."}`).
    var odataID: String? { self["@odata.id"].string }
}

/// Small text helpers shared by the parsers. Units stay untranslated ("GB", "W", "°C").
enum APIFormat {
    /// "182", "3.5".
    static func number(_ v: Double) -> String {
        if v.rounded() == v, abs(v) < 9.2e18 { return String(Int64(v)) }
        return String(format: "%.1f", v)
    }

    /// Memory size from GiB: "192 GB", "7.5 GB", "512 MB" (memory is sold in binary units).
    static func memory(gib: Double) -> String {
        guard gib > 0 else { return "0 GB" }
        if gib < 1 { return "\(Int((gib * 1024).rounded())) MB" }
        if gib >= 10 || abs(gib - gib.rounded()) < 0.05 { return "\(Int(gib.rounded())) GB" }
        return String(format: "%.1f GB", gib)
    }

    static func memory(bytes: Int64) -> String { memory(gib: Double(bytes) / 1_073_741_824) }
    static func memory(megabytes: Double) -> String { memory(gib: megabytes / 1024) }

    /// "Intel(R) Xeon(R) Silver 4214 CPU @ 2.20GHz" → "Intel Xeon Silver 4214".
    static func cpuName(_ raw: String) -> String {
        var s = raw
        for mark in ["(R)", "(r)", "(TM)", "(tm)"] { s = s.replacingOccurrences(of: mark, with: "") }
        if let at = s.range(of: " @ ") { s = String(s[..<at.lowerBound]) }
        s = s.split(separator: " ").joined(separator: " ")
        for suffix in [" CPU", " Processor"] where s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// "255.255.255.0" → 24. Also accepts a prefix length given as text ("24").
    static func prefixLength(_ mask: String) -> Int? {
        if let n = Int(mask), (0...128).contains(n) { return n }
        let parts = mask.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        return parts.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    /// "192.0.2.10" + "255.255.255.0" → "192.0.2.10/24".
    static func address(_ ip: String, mask: String?) -> String {
        guard let mask, let len = prefixLength(mask) else { return ip }
        return "\(ip)/\(len)"
    }

    /// Alert texts sometimes carry HTML links.
    static func plainText(_ s: String) -> String {
        s.replacingOccurrences(of: "<(br|p|/p|li)\\s*/?>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The worst health that is known; `.unknown` when none is.
    static func worst(_ all: [ApplianceSnapshot.Health]) -> ApplianceSnapshot.Health {
        all.filter { $0 != .unknown }.max() ?? .unknown
    }

    /// Names must be unique in the lists the UI shows (they are the identity); repeats get " (2)", " (3)".
    static func uniqued<T>(_ items: [T], _ name: WritableKeyPath<T, String>) -> [T] {
        var seen: [String: Int] = [:]
        return items.map { original in
            var item = original
            let key = item[keyPath: name]
            let n = (seen[key] ?? 0) + 1
            seen[key] = n
            if n > 1 { item[keyPath: name] = key + " (\(n))" }
            return item
        }
    }

    /// Short local date for alert lines ("2026-11-14").
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
