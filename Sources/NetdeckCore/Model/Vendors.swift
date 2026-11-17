import Foundation

/// Tiny offline OUI table. Only prefixes we are confident about; unknown stays unknown
/// (the user can give any MAC a friendly name instead).
public enum Vendors {
    static let table: [String: String] = [
        // Dell (seen on this site's iDRACs and rNDCs)
        "b0:7b:25": "Dell", "78:ac:44": "Dell",
        // MikroTik
        "48:8f:5a": "MikroTik", "64:d1:54": "MikroTik", "6c:3b:6b": "MikroTik", "74:4d:28": "MikroTik",
        "c4:ad:34": "MikroTik", "cc:2d:e0": "MikroTik", "dc:2c:6e": "MikroTik", "e4:8d:8c": "MikroTik",
        "d4:01:c3": "MikroTik", "18:fd:74": "MikroTik", "2c:c8:1b": "MikroTik", "08:55:31": "MikroTik",
        // Juniper
        "00:05:85": "Juniper",
        // Supermicro
        "00:25:90": "Supermicro", "ac:1f:6b": "Supermicro", "3c:ec:ef": "Supermicro",
        // Intel NICs
        "a0:36:9f": "Intel", "3c:fd:fe": "Intel", "b4:96:91": "Intel", "40:a6:b7": "Intel",
        // Ubiquiti
        "f0:9f:c2": "Ubiquiti", "24:5a:4c": "Ubiquiti", "78:8a:20": "Ubiquiti", "74:83:c2": "Ubiquiti",
        // Proxmox VE default VM MAC prefix
        "bc:24:11": "Proxmox VM",
    ]

    public static func lookup(_ mac: String) -> String? {
        let m = mac.lowercased()
        guard m.count >= 8 else { return nil }
        if let v = table[String(m.prefix(8))] { return v }
        // Locally administered (randomized) addresses: second hex digit is 2, 6, a or e.
        let second = m[m.index(after: m.startIndex)]
        if "26ae".contains(second) { return t("Randomized MAC") }
        return nil
    }
}
