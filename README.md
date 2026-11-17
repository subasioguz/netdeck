# Netdeck

**See your network gear the way it looks on the rack, and change it without fear.**

Netdeck is a native macOS app for managing switches and other network devices. It connects over a
serial console or SSH, draws the device's real front and rear panels, shows what is plugged into every
port, and turns your edits into a reviewed, time-boxed change that the device rolls back on its own if
you don't confirm it.

> **Status: early development.** The device core (connection, parsing, change planning, safe apply) is
> working and tested against real hardware. The macOS interface is being built now.

---

## Why

Most small teams and homelab owners manage switches by pasting CLI commands from notes. A typo in the
wrong `interface-range`, or one forgotten `commit`, takes a server off the network, and the person who
made the change is often the one locked out of fixing it.

Netdeck keeps the device's own safety net in place and puts a clear picture on top of it:

- **Know what you have.** Every port, its VLAN, link state, the module in each cage, and the MAC
  addresses and LLDP neighbours behind it, drawn on a faithful faceplate.
- **Say what you want, not how.** "Open port 3 for the management cable" becomes the right `set`
  and `delete` statements, including splitting the disabled-ports range it belongs to.
- **Apply without fear.** Changes go out with `commit confirmed`. If something breaks and you can't
  confirm, the device returns to its previous configuration by itself.

## Features

| | Status |
|---|---|
| Serial console (USB) and SSH connections | Done |
| Login handling for console, shell and CLI prompts | Done |
| Ports, VLANs, MAC table, LLDP, hardware, optics, commit history | Done |
| Plain-language change plan (edit ports and VLANs) | Done |
| Device's own diff and `commit check` before anything is applied | Done |
| `commit confirmed` apply, one-click confirm or revert, rollback to any version | Done |
| Automatic config backups before every change | Done |
| Device auto-detection (vendor, model, OS) | Done |
| Visual front and rear panels, "who is connected" view, VLAN rooms view | In progress |
| Multiple devices grouped by location, global "awaiting confirmation" banner | In progress |
| English and Turkish interface | In progress |

## Supported devices

| Platform | Devices | Support |
|---|---|---|
| Juniper Junos (ELS) | EX switches, tested on EX4300-48T with Junos 21.2 | Full |
| Juniper Junos | SRX, MX, QFX | Detected, full support planned |
| MikroTik RouterOS | Routers and switches | Detected, planned |
| Cisco IOS / IOS-XE | Switches and routers | Detected, planned |
| Ubiquiti EdgeOS | Routers | Detected, planned |
| Dell iDRAC (Redfish) | Server management controllers | Detected, planned |
| Synology DSM, TrueNAS | Storage | Detected, planned |

"Detected" means Netdeck recognises the device when it connects and shows basic information.

## Safety model

Netdeck is built so that a mistake costs you minutes, never a site visit.

1. **Read-only by default.** Connecting, refreshing and previewing never change the device.
2. **Preview on the device itself.** Your edits are loaded into the candidate configuration, the device
   reports its own diff and `commit check` result, and the candidate is discarded again.
3. **Timed apply.** Changes are committed with `commit confirmed 3/5/10`. Until you press *Confirm*, the
   device will undo them on its own when the timer runs out, even if Netdeck or your connection dies.
4. **Backups first.** The current configuration is saved locally before every apply or rollback.
5. **Hands off other people's work.** If the device already holds uncommitted changes from another
   session, Netdeck stops and shows them instead of building on top of them.
6. **Clean exits.** Serial console sessions are logged out when Netdeck disconnects.

## Requirements

- macOS 15 or later
- Xcode 16 or later (Swift 6 toolchain) to build from source
- A USB serial console cable, or SSH access to the device's management interface

## Build and run

```sh
git clone <this repository>
cd netdeck
swift test                     # run the test suite
scripts/make-app.sh --open     # build build/Netdeck.app and open it
```

### Field tool

`netdeck-probe` exercises the same core from the terminal. It is useful for checking a new device or
firmware before using the app. It never commits.

```sh
swift build --product netdeck-probe

# Read everything Netdeck shows
NETDECK_PASSWORD=... .build/debug/netdeck-probe --serial /dev/cu.usbserial-XXXX --user root snapshot

# Ask the device what a change would do, then throw it away
NETDECK_PASSWORD=... .build/debug/netdeck-probe --ssh 192.0.2.10 --user admin \
  preview "set interfaces ge-0/0/2 description uplink"
```

## How it works

```
Sources/
  NetdeckCore/            UI-independent core (fully unit-tested)
    Transport/            Serial console (termios) and SSH (system ssh with a forced TTY)
    Junos/                CLI session, output parsers, config model, change planner, driver
    Model/                Snapshot, ports, device kinds and platforms, auto-detection
    Session/              Observable per-device state for the UI
    Support/              Backups, device list, Keychain, localization
  Netdeck/                SwiftUI app
  netdeck-probe/          Command-line field tool
Tests/
  NetdeckCoreTests/       Parser, planner, session and detection tests
    Fixtures/             Real console captures (anonymized)
```

Netdeck talks to devices the same way you would: through their CLI. It reads with `show` commands,
parses the text (including fixed-width tables), and writes with plain `set`/`delete` statements, so
every change is visible as the exact commands the device received.

## Privacy

- Device passwords are stored in the macOS Keychain, never on disk.
- Netdeck only connects to the devices you add. There is no telemetry and no account.
- Backups and device settings stay in `~/Library/Application Support/Netdeck`.

## Localization

English is the development language. Every user-facing string is looked up with `t("English text")`,
and translations live in `Sources/NetdeckCore/Resources/<language>.lproj/Localizable.strings`.
Turkish is included. To add a language, copy `tr.lproj`, translate the values, and add the code to
`CFBundleLocalizations` in `Resources/Info.plist`.

## Contributing

Bug reports with console output are very welcome, especially from devices and firmware versions not
listed above. When sharing captures, remove passwords and hashes, and replace serial numbers and MAC
addresses (keep column alignment in fixed-width tables). See `Tests/NetdeckCoreTests/Fixtures` for
examples.

## License

Copyright 2026 Oğuzhan Subaşı.

Licensed under the [Apache License, Version 2.0](LICENSE). You may use, modify and distribute Netdeck,
including commercially, under the terms of that license. The license does not grant rights to the
Netdeck name or logo.
