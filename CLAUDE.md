# Netdeck

Native macOS app for managing network devices (switches first; routers, firewalls, storage and
server BMCs later). SwiftUI + Swift 6, built as a SwiftPM package. First fully supported platform:
Juniper Junos (EX series, ELS).

## Language rules
- English everywhere in the repository: code, identifiers, comments, docs, commit messages, fixtures.
- The app's development language is English. Every user-facing string goes through `t("English text")`.
- Translations live only in `Sources/NetdeckCore/Resources/<lang>.lproj/Localizable.strings`
  (currently `tr`). When adding a string, add its Turkish translation there too.
- Pass numbers to `t()` as `String` (all placeholders are `%@`).

## Layout
- `Sources/NetdeckCore`: UI-independent core
  - `Transport/`: serial console (termios) and SSH (`/usr/bin/ssh -tt` + one-shot `SSH_ASKPASS`)
  - `Junos/JunosCLI`: text CLI session: login (console/shell/cli), prompt detection, command framing
  - `Junos/OutputParsers`, `JunosConfig`: `show ...` output and `display set` config → models
  - `Junos/ChangePlanner`: staged edits → `set`/`delete` commands (splits interface ranges)
  - `Junos/JunosDriver`: read, preview, `commit confirmed`, confirm, revert, rollback
  - `Model/DeviceCatalog`: device kinds, platforms, `DeviceDetector` (auto-detect from banners/output)
  - `Session/DeviceSession`: `@Observable` per-device state the UI binds to
  - `Support/`: backups, device store, Keychain, localization
- `Sources/Netdeck`: SwiftUI app
- `Sources/netdeck-probe`: CLI field tool for testing against real hardware (never commits)
- `Tests/NetdeckCoreTests/Fixtures`: real console captures, anonymized (serials, MACs, users, hashes)

## Commands
- Tests: `swift test` (run alone, not in parallel with other heavy jobs)
- App bundle: `scripts/make-app.sh --open` → `build/Netdeck.app`
- Field test: `NETDECK_PASSWORD=... .build/debug/netdeck-probe --serial /dev/cu.usbserial-XXXX --user root snapshot`
  (`preview "cmd; cmd"` loads into the candidate, prints diff + commit check, then `rollback 0`)

## Safety rules (hard)
- Never commit anything to a device without the user's explicit approval. Reading and `preview` are fine.
- Every apply uses `commit confirmed N`; it only becomes permanent through a separate `confirm()`.
- Back up the configuration before applying. Stop if the candidate holds someone else's uncommitted changes.
- Log out of serial consoles when done.
- Never put passwords, hashes or real serials/MACs in fixtures or docs.

## Known quirks
- After a root console login, the shell prompt arrives wrapped in `ESC [row;colH ESC H` sequences;
  `JunosCLI.clean` strips them. Cleaning runs on the whole buffer because sequences split across reads.
- csh mangles nested quotes in `cli -c "..."`; the app enters the CLI and sends commands one by one.
- Uplink-module cages appear as `ge-0/2/N` or `xe-0/2/N` depending on the optic. 25G SFP28 DACs show as 1G.
- EX4300 rear QSFP+ ports are Virtual Chassis ports (`show virtual-chassis vc-port`) and absent from `terse`.
- Fixed-width outputs (`show chassis hardware`, `show lldp neighbors`) are parsed by header column offsets;
  keep column alignment when editing fixtures.
