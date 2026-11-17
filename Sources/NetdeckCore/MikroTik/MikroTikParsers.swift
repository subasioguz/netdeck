import Foundation

/// One item of a RouterOS `print terse` listing: `<index> <flags> key=value key=value ...`.
public struct MikroTikRecord: Equatable, Sendable {
    public var index: Int?
    /// Flag letters printed after the index ("X" disabled, "R" running, "D" dynamic...).
    public var flags: String
    public var fields: [String: String]

    public init(index: Int? = nil, flags: String = "", fields: [String: String] = [:]) {
        self.index = index
        self.flags = flags
        self.fields = fields
    }

    public subscript(_ key: String) -> String? { fields[key] }

    public func has(_ flag: Character) -> Bool { flags.contains(flag) }

    /// A comma-separated list field ("ether1,ether2"; `""` is empty).
    public func list(_ key: String) -> [String] { MikroTikParsers.list(fields[key]) }

    /// "yes"/"no" (and "true"/"false") fields.
    public func bool(_ key: String) -> Bool? {
        switch fields[key] {
        case "yes", "true": return true
        case "no", "false": return false
        default: return nil
        }
    }

    /// Disabled either by flag or by a printed `disabled=yes`.
    public var isDisabled: Bool { has("X") || bool("disabled") == true }
}

/// A date and time as the router's clock shows it. Kept as wall-clock fields: the safety-net timer is
/// set in the router's own time, whatever its time zone or however wrong its clock is.
public struct MikroTikClock: Equatable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: Int
    public var minute: Int
    public var second: Int
    /// The router prints dates as `2026-11-17` (current 7.x) rather than `nov/17/2026` (older builds).
    public var isoDates: Bool

    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, isoDates: Bool = true) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.isoDates = isoDates
    }

    static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// The date in the format the router used ("2026-11-17" or "nov/17/2026").
    public var dateString: String {
        if isoDates { return "\(year)-\(Self.pad(month))-\(Self.pad(day))" }
        let name = (1...12).contains(month) ? Self.monthNames[month - 1] : "jan"
        return "\(name)/\(Self.pad(day))/\(year)"
    }

    public var timeString: String { "\(Self.pad(hour)):\(Self.pad(minute)):\(Self.pad(second))" }

    /// Comparable form: year, month, day, hour, minute, second.
    public var sortKey: [Int] { [year, month, day, hour, minute, second] }

    public func isAfter(_ other: MikroTikClock) -> Bool { other.sortKey.lexicographicallyPrecedes(sortKey) }

    /// The clock `minutes` later, rolling over midnight, month and year ends.
    public func adding(minutes: Int) -> MikroTikClock? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let comps = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let start = cal.date(from: comps), let end = cal.date(byAdding: .minute, value: minutes, to: start) else { return nil }
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: end)
        guard let y = c.year, let mo = c.month, let d = c.day, let h = c.hour, let mi = c.minute, let s = c.second else { return nil }
        return MikroTikClock(year: y, month: mo, day: d, hour: h, minute: mi, second: s, isoDates: isoDates)
    }

    /// "2026-11-17" or "nov/17/2026" (any case) → (year, month, day, iso).
    static func parseDate(_ s: String) -> (Int, Int, Int, Bool)? {
        let v = s.trimmingCharacters(in: .whitespaces)
        if v.range(of: #"^\d{4}-\d{1,2}-\d{1,2}$"#, options: .regularExpression) != nil {
            let p = v.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3 else { return nil }
            return (p[0], p[1], p[2], true)
        }
        if v.range(of: #"^[A-Za-z]{3}/\d{1,2}/\d{4}$"#, options: .regularExpression) != nil {
            let p = v.split(separator: "/")
            guard p.count == 3, let m = monthNames.firstIndex(of: p[0].lowercased()), let d = Int(p[1]), let y = Int(p[2]) else { return nil }
            return (y, m + 1, d, false)
        }
        return nil
    }

    /// "10:21:39" (fractions ignored) → (hour, minute, second).
    static func parseTime(_ s: String) -> (Int, Int, Int)? {
        let v = s.trimmingCharacters(in: .whitespaces)
        guard v.range(of: #"^\d{1,2}:\d{2}:\d{2}"#, options: .regularExpression) != nil else { return nil }
        let p = v.prefix(while: { $0 != "." }).split(separator: ":").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return (p[0], p[1], p[2])
    }

    /// A printed moment: "2026-11-17 10:26:39", "nov/17/2026 10:26:39", or a bare time ("10:26:39"),
    /// which the router prints for today.
    public static func parseMoment(_ s: String, today: MikroTikClock) -> MikroTikClock? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        if parts.count >= 2, let d = parseDate(parts[0]), let tm = parseTime(parts[1]) {
            return MikroTikClock(year: d.0, month: d.1, day: d.2, hour: tm.0, minute: tm.1, second: tm.2, isoDates: d.3)
        }
        if parts.count == 1, let tm = parseTime(parts[0]) {
            return MikroTikClock(year: today.year, month: today.month, day: today.day, hour: tm.0, minute: tm.1, second: tm.2,
                                 isoDates: today.isoDates)
        }
        return nil
    }

    private static func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : String(n) }
}

/// Pure parsers for RouterOS console output.
public enum MikroTikParsers {
    // MARK: print terse

    /// Every item of a `print terse` listing. Lines that don't start with an index are ignored.
    public static func terse(_ text: String) -> [MikroTikRecord] {
        text.components(separatedBy: "\n").compactMap(record)
    }

    /// One `print terse` line: index, flag column, then `key=value` pairs. Values may be quoted (with
    /// RouterOS escapes) or bare; bare values may contain spaces ("jan/02/1970 08:44:57"), so a bare
    /// value runs until the next ` key=`.
    public static func record(_ line: String) -> MikroTikRecord? {
        let c = Array(line.replacingOccurrences(of: "\r", with: ""))
        var i = 0
        while i < c.count, c[i] == " " { i += 1 }
        var digits = ""
        while i < c.count, c[i].isASCII, c[i].isNumber { digits.append(c[i]); i += 1 }
        guard !digits.isEmpty, i < c.count, c[i] == " " else { return nil }

        var flags = ""
        var start = c.count
        while i < c.count {
            while i < c.count, c[i] == " " { i += 1 }
            guard i < c.count else { break }
            if isKeyStart(c, i) { start = i; break }
            var j = i
            while j < c.count, c[j] != " " { j += 1 }
            flags += String(c[i..<j]).filter { $0.isLetter }
            i = j
        }
        return MikroTikRecord(index: Int(digits), flags: flags, fields: pairs(c, from: start))
    }

    /// `key=value` pairs of a terse line from `start`.
    static func pairs(_ c: [Character], from start: Int) -> [String: String] {
        var out: [String: String] = [:]
        let n = c.count
        var i = start
        while i < n {
            while i < n, c[i] == " " { i += 1 }
            guard i < n else { break }
            guard isKeyStart(c, i) else {
                // A stray word (not key=value): skip it.
                while i < n, c[i] != " " { i += 1 }
                continue
            }
            var k = i
            while k < n, c[k] != "=" { k += 1 }
            let key = String(c[i..<k])
            let v = k + 1
            if v < n, c[v] == "\"" {
                var j = v + 1
                var raw = ""
                while j < n, c[j] != "\"" {
                    if c[j] == "\\", j + 1 < n {
                        raw.append(c[j]); raw.append(c[j + 1]); j += 2
                    } else {
                        raw.append(c[j]); j += 1
                    }
                }
                out[key] = unescape(raw)
                i = min(j + 1, n)
            } else {
                var j = v
                while j < n {
                    if c[j] == " ", isKeyStart(c, j + 1) { break }
                    j += 1
                }
                let value = v < j ? String(c[v..<j]).trimmingCharacters(in: .whitespaces) : ""
                out[key] = value.contains("\\") ? unescape(value) : value
                i = j
            }
        }
        return out
    }

    /// `c[i...]` starts with `key=`: lowercase letters, digits, dashes and dots, then "=".
    static func isKeyStart(_ c: [Character], _ i: Int) -> Bool {
        guard i < c.count, c[i].isASCII, c[i].isLowercase || c[i] == "." else { return false }
        var j = i
        while j < c.count, c[j].isASCII, c[j].isLowercase || c[j].isNumber || c[j] == "-" || c[j] == "." { j += 1 }
        return j < c.count && c[j] == "="
    }

    // MARK: key: value blocks

    /// `print` output of single-item menus (`/system resource`, `/system routerboard`, `/system clock`,
    /// `/system identity`): right-aligned `key: value` lines.
    public static func keyValues(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            let l = line.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespaces)
            let key: String, value: String
            if let r = l.range(of: ": ") {
                key = String(l[..<r.lowerBound])
                value = String(l[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if l.hasSuffix(":") {
                key = String(l.dropLast())
                value = ""
            } else {
                continue
            }
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) else { continue }
            if out[key] == nil {
                out[key] = value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"")
                    ? unescape(String(value.dropFirst().dropLast())) : value
            }
        }
        return out
    }

    /// `/system clock print` → the router's current date and time.
    public static func clock(_ text: String) -> MikroTikClock? {
        let kv = keyValues(text)
        guard let date = kv["date"].flatMap(MikroTikClock.parseDate), let time = kv["time"].flatMap(MikroTikClock.parseTime) else { return nil }
        return MikroTikClock(year: date.0, month: date.1, day: date.2, hour: time.0, minute: time.1, second: time.2, isoDates: date.3)
    }

    // MARK: Values

    /// "ether1,ether2" → ["ether1", "ether2"]; nil or "" → [].
    public static func list(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `vlan-ids` as printed ("10", "10,20", "100-103") → [10, 20] / [100, 101, 102, 103].
    public static func vlanIDs(_ value: String?) -> [Int] {
        var out: [Int] = []
        for item in list(value) {
            if item.contains("-") {
                let ends = item.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if ends.count == 2, ends[0] <= ends[1], ends[0] >= 1, ends[1] <= 4094 { out += Array(ends[0]...ends[1]) }
            } else if let n = Int(item) {
                out.append(n)
            }
        }
        var seen = Set<Int>()
        return out.filter { seen.insert($0).inserted }
    }

    /// IDs back to `vlan-ids` form, ranges for runs: [10, 20, 21, 22] → "10,20-22".
    public static func vlanIDString(_ ids: [Int]) -> String {
        let sorted = Array(Set(ids)).sorted()
        var parts: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1 { j += 1 }
            parts.append(j > i + 1 ? "\(sorted[i])-\(sorted[j])" : (j == i + 1 ? "\(sorted[i]),\(sorted[j])" : "\(sorted[i])"))
            i = j + 1
        }
        return parts.joined(separator: ",")
    }

    /// Resolves RouterOS string escapes: `\"`, `\\`, `\$`, `\?`, `\_`, `\n`, `\r`, `\t`, `\a`, `\b`, `\f`,
    /// `\v` and `\XX` (a byte in hex; non-ASCII text is printed as its UTF-8 bytes).
    public static func unescape(_ s: String) -> String {
        let c = Array(s.unicodeScalars)
        var bytes: [UInt8] = []
        func append(_ u: Unicode.Scalar) { bytes.append(contentsOf: Array(String(u).utf8)) }
        func hex(_ u: Unicode.Scalar) -> UInt8? {
            switch u.value {
            case 0x30...0x39: return UInt8(u.value - 0x30)
            case 0x41...0x46: return UInt8(u.value - 0x41 + 10)
            case 0x61...0x66: return UInt8(u.value - 0x61 + 10)
            default: return nil
            }
        }
        var i = 0
        while i < c.count {
            let u = c[i]
            guard u == "\\", i + 1 < c.count else { append(u); i += 1; continue }
            let next = c[i + 1]
            switch next {
            case "n": bytes.append(10)
            case "r": bytes.append(13)
            case "t": bytes.append(9)
            case "a": bytes.append(7)
            case "b": bytes.append(8)
            case "f": bytes.append(12)
            case "v": bytes.append(11)
            case "_": bytes.append(32)
            default:
                if i + 2 < c.count, let high = hex(next), let low = hex(c[i + 2]) {
                    bytes.append(high << 4 | low)
                    i += 3
                    continue
                }
                append(next)
            }
            i += 2
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Trailing number of an interface name: "ether12" → 12, "sfp-sfpplus2" → 2, "qsfp28-1-1" → 1.
    public static func trailingNumber(_ name: String) -> Int? {
        let digits = String(name.reversed().prefix { $0.isASCII && $0.isNumber }.reversed())
        return Int(digits)
    }

    /// `/export` output without the time stamp of its first line, so an unchanged configuration reads the
    /// same every time (local backups are only kept when it changes):
    /// "# 2026-11-17 10:00:00 by RouterOS 7.16.2" → "# by RouterOS 7.16.2".
    public static func stableExport(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.hasPrefix("# ") && $0.contains(" by RouterOS") }),
           let r = lines[i].range(of: " by RouterOS") {
            lines[i] = "#" + String(lines[i][r.lowerBound...])
        }
        return lines.joined(separator: "\n")
    }

    /// First number in the last line that is only a number (`:put` output).
    public static func number(in text: String) -> Int? {
        text.components(separatedBy: "\n").reversed()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
            .flatMap { Int($0) }
    }
}

/// RouterOS command-line quoting.
public enum MikroTikQuote {
    private static let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:/+,@")

    /// A value as written in a command: bare when it only has safe characters, else quoted.
    public static func value(_ s: String) -> String {
        !s.isEmpty && s.allSatisfy { safe.contains($0) } ? s : quoted(s)
    }

    /// Always double-quoted.
    public static func quoted(_ s: String) -> String { "\"" + escape(s) + "\"" }

    /// A comma-separated member list; `""` when empty.
    public static func list(_ names: [String]) -> String {
        names.isEmpty ? "\"\"" : value(names.joined(separator: ","))
    }

    /// Escapes text for the inside of a double-quoted string. `"`, `\` and `$` get a backslash. `?`
    /// opens the console help when typed, so it is sent as its hex code, like control characters
    /// and non-ASCII text (as UTF-8 bytes): the console then only ever receives plain ASCII.
    public static func escape(_ s: String) -> String {
        let hexDigits = Array("0123456789ABCDEF")
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "$": out += "\\$"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u == "?" || u.value < 0x20 || u.value >= 0x7F {
                    for b in String(u).utf8 {
                        out += "\\" + String(hexDigits[Int(b >> 4)]) + String(hexDigits[Int(b & 0x0F)])
                    }
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out
    }
}
