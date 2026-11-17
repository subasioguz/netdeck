# MikroTik RouterOS fixtures (synthetic)

These files are **synthetic**. No MikroTik hardware was available when the module was written. They were
composed from the RouterOS documentation (manual.mikrotik.com: console, `print terse`, bridge VLAN
filtering, scheduler) and public console captures (netmiko, forum posts). Replace them with real,
anonymized captures once a router is at hand.

Device: a CRS326-24G-2S+ style switch running RouterOS 7.16.2.

- `ether1`–`ether24` copper, `sfp-sfpplus1`–`sfp-sfpplus2` cages.
- `sfp-sfpplus1` is renamed to `uplink`: a trunk (VLANs 10 and 20 tagged, VLAN 1 untagged through PVID 1).
- One bridge `bridge` with `vlan-filtering=yes`.
- VLAN 1 (dynamic entry, PVID 1 on `ether13`–`ether24` and `uplink`), VLAN 10 (`office` VLAN interface,
  comment "Office LAN", `ether1`–`ether8`), VLAN 20 (comment "Guests", `ether9`–`ether12`), VLAN 99
  (comment "Spare", no members).
- `ether24` is disabled. `sfp-sfpplus2` is a routed port (198.51.100.2/30), not in the bridge.

Each file is the output of one command, without the echoed command and the prompt:

| File | Command |
| --- | --- |
| `identity.txt` | `/system identity print` |
| `resource.txt` | `/system resource print` |
| `routerboard.txt` | `/system routerboard print` |
| `ethernet.txt` | `/interface ethernet print terse without-paging` |
| `interface.txt` | `/interface print terse without-paging` |
| `bridge.txt` | `/interface bridge print terse without-paging` |
| `bridge-port.txt` | `/interface bridge port print terse without-paging` |
| `bridge-vlan.txt` | `/interface bridge vlan print terse without-paging` |
| `interface-vlan.txt` | `/interface vlan print terse without-paging` |
| `bridge-host.txt` | `/interface bridge host print terse without-paging` |
| `ip-neighbor.txt` | `/ip neighbor print terse without-paging` |
| `ip-address.txt` | `/ip address print terse without-paging` |
| `export.txt` | `/export terse` |
| `clock-iso.txt` | `/system clock print` (current 7.x date format, one minute before midnight on Dec 31) |
| `clock-legacy.txt` | `/system clock print` (older 7.x date format `nov/17/2026`) |
| `scheduler.txt` | `/system scheduler print terse without-paging where name=netdeck-revert` (a pending change) |

Documentation values only: addresses from 192.0.2.0/24 and 198.51.100.0/24, MAC addresses with zeros after
the OUI, serial `TEST0000001`, software ID `TEST-0001`. No passwords or secrets.
