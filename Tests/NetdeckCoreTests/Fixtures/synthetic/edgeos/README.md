# EdgeOS fixtures (synthetic)

These captures are **synthetic**. No EdgeRouter was available, so they were written from Ubiquiti's
EdgeRouter help articles, the Vyatta/VyOS configuration-management sources EdgeOS derives from, and
public captures (ntc-templates). Replace them with real, anonymized captures once a device is at hand.

Each file holds what `CLISession` receives for one command: the echoed command on the first line, the
output, and the trailing prompt (`ubnt@er-x-lab:~$` in operational mode, `[edit]` plus
`ubnt@er-x-lab#` in configuration mode). Tests strip them with `CLISession.strip(_:dialect:)`.

The device is an EdgeRouter X: eth0 is the routed WAN port, eth1-eth4 are members of a vlan-aware
`switch0` (eth1 access VLAN 10, eth2 trunk with untagged 10 and tagged 20 and 30, eth3 and eth4 in
VLAN 1, eth4 disabled). VLANs 10 and 20 have switch0 vifs with descriptions; VLAN 30 has none.

| File | Command |
| --- | --- |
| `show-version.txt` | `show version` |
| `show-configuration-commands.txt` | `show configuration commands` |
| `show-interfaces.txt` | `show interfaces` |
| `show-arp.txt` | `show arp` |
| `show-lldp-neighbors.txt` | `show lldp neighbors`, table form (VyOS format, unverified on EdgeOS) |
| `show-lldp-neighbors-lldpd.txt` | `show lldp neighbors`, lldpd detail form |
| `show-system-commit.txt` | `show system commit` |
| `commit-confirm.txt` | `commit-confirm 5` in configuration mode (text from Ubiquiti's help article) |
| `compare.txt` | `compare` in configuration mode with one uncommitted change |

Only documentation values are used: addresses from 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24 and
2001:db8::/32, MAC addresses with zeros after the OUI (48:a9:8a:00:00:xx) and serial `TEST0000001`.
No passwords or hashes.
