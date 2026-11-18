# FortiGate fixtures (synthetic)

These captures are **synthetic**. No FortiGate was available when the module was written. They follow the
public raw captures in the ntc-templates test suite (`get system status` of a FortiGate-60F on 7.4.8,
`get system interface physical` on 7.4, `get system arp`), FortiOS configuration syntax as printed by `show`,
and Netmiko's FortiOS driver (prompt, VDOM detection through "Virtual domain configuration", `config global`).
Replace them with real, anonymized captures once a unit is available.

Each file is what `CLISession` sees for one command after escape sequences are removed: the echoed command, the
output and the prompt (`FW-BRANCH-01 # `, `FW-BRANCH-01 (global) # ` with virtual domains).

| File | Command | Notes |
| --- | --- | --- |
| `fgt60f-get-system-status.txt` | `get system status` | "Version: FortiGate-60F v7.4.8,build2795,...", "Virtual domain configuration: disable" |
| `fgt60f-interface-physical.txt` | `get system interface physical` | the `== [onboard]` group header, one `==[port]` block per port, an NP link (`npu0_vlink0`) that is not a front port |
| `fgt60f-show.txt` | `show` | `config system interface` (DHCP WAN with an alias, a port that is down, the `internal` hard switch with a nested `config ipv6`, the `fortilink` aggregate of `a` and `b`, VLANs on `internal` and `wan1`, a tunnel), `config system virtual-switch` with its `config port` members, a zone, and a firewall policy whose comment quotes an error text |
| `fgt60f-get-system-arp.txt` | `get system arp` | entries on a port, on the hard switch, on VLANs and on the aggregate; an incomplete entry (all-zero MAC) |
| `fgt-vdom-diagnose-arp.txt` | `diagnose ip arp list` | the form read inside `config global` when virtual domains are on |

The raw pager (`--More-- `, taken back with a carriage return, blanks and a carriage return) is built in
`FortiOSTests` by a fake unit. The erase bytes are an assumption: FortiOS may also use backspaces, which the
cleaning removes as well.

Assumptions a real unit should confirm: the prompt keeps the blank before `#` (`FGT60F # `) and shows contexts in
brackets; `get system interface physical` lists the ports of the hardware switch one by one; with virtual domains
on, `get system interface physical` and `diagnose ip arp list` work inside `config global` and `show` at the top
level prints the whole configuration; `abort` leaves a configuration context without saving.

Only documentation values are used: addresses from 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24 and
2001:db8::/32, MAC addresses from 00:00:5e:00:53:xx (RFC 7042), serial `FGT60FTEST000001`, no passwords, hashes
or keys.
