# Cisco IOS / IOS-XE fixtures (synthetic)

These captures are **synthetic**. No Cisco hardware was available when the Cisco module was written.
They were put together from Cisco documentation and public captures (Cisco configuration guides,
community posts, ntc-templates test data) and follow the vendor formats column for column. Replace
them with real, anonymized console captures once a switch is available.

Each file is what `CLISession` receives for one command: the echoed command on the first line, the
output, and the prompt on the last line.

| File | Command | Device |
| --- | --- | --- |
| `c9300-show-version.txt` | `show version` | Catalyst C9300-48P, IOS-XE 17.9 |
| `c9300-show-inventory.txt` | `show inventory` | C9300-48P with a C9300-NM-8X module, one SFP+ |
| `c9300-running-config.txt` | `show running-config` | access, trunk (`allowed vlan` with ranges and `add`), native VLAN, routed port, shutdown, port-channel member, VLAN names, archive |
| `c9300-interfaces-status.txt` | `show interfaces status` | lists every network-module variant (Gi/Te/Fo/Twe 1/1/x), as a C9300 does |
| `c9300-vlan-brief.txt` | `show vlan brief` | wrapped port lists, VLANs 1002–1005 |
| `c9300-mac-address-table.txt` | `show mac address-table` | Catalyst 2960/3850/9000 layout |
| `c9300-lldp-neighbors.txt` | `show lldp neighbors` | Device ID cut at 20 characters |
| `cat6500-mac-address-table.txt` | `show mac address-table` | Catalyst 4500/6500 layout |
| `2960x-*.txt` | same commands | WS-C2960X-24TS-L, IOS 15.2(7)E8, 24 copper + 4 SFP |
| `lldp-disabled.txt` | `show lldp neighbors` | LLDP turned off |
| `archive-configured.txt` / `archive-not-configured.txt` | `show archive` | with and without an archive path |

Only documentation values are used: addresses from 192.0.2.0/24, 198.51.100.0/24 and 203.0.113.0/24,
MAC addresses `48:a9:8a:00:…`, serial numbers `TEST…`, no passwords or hashes.

The long fixed-width files were generated with a small script so that the columns line up exactly
as on the device. Keep column alignment when editing them: the parsers locate columns from the header.
