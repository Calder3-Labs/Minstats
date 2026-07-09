# StatsMenu

A minimalist macOS menu bar app for the vitals that matter: **temperature, CPU, and RAM** — at a glance, without the clutter.

<p align="center">
  <img src="docs/screenshots/panel.png" alt="StatsMenu panel" width="320">
</p>

Most system monitors try to show you everything. StatsMenu shows you the vital few, beautifully. One clean temperature reading in the menu bar; a quiet dropdown with the details when you want them. No graphs you'll never read, no configuration marathon.

## Features

- **Live temperature, CPU, and RAM** in the menu bar — compact, monospaced, jitter-free
- **Headline die temperature** — the hottest CPU/SoC sensor, the number that actually tells you if your Mac is hot
- **Top processes** by CPU and by memory, grouped by app (all those Chrome helpers collapse into one line)
- **Condensed sensor summary** — CPU die, power delivery, SSD, battery, and fan RPM where present
- **Two display modes** — right-click to switch between temperature-only (minimal footprint) and the full readout
- **°C / °F** toggle, **configurable refresh** (2s / 5s / 10s / 30s), and **launch at login**
- **No Dock icon, no window** — it lives entirely in the menu bar
- **Private by design** — everything is read locally from the OS. No network, no telemetry, no account.

## Install

### Download

Grab the latest `StatsMenu.dmg` from [Releases](../../releases), open it, and drag StatsMenu to Applications.

Because the app isn't yet signed with an Apple Developer ID, macOS Gatekeeper will ask on first launch. Either:

- **Right-click** the app → **Open** → **Open**, or
- run `xattr -d com.apple.quarantine /Applications/StatsMenu.app`

This is a one-time step per machine.

### Build from source

No Xcode required — just the Command Line Tools (`xcode-select --install`) and their Swift toolchain.

```sh
make run          # build, bundle, and launch
make print        # dump one sample of every metric to the terminal (no UI)
make dmg          # build a universal (Apple Silicon + Intel) .dmg installer
```

## Compatibility

- **Apple Silicon (M1/M2/M3+):** fully supported — temperature, CPU, RAM, and fans.
- **Intel Macs:** CPU, RAM, and fans work; temperature sensor coverage is currently limited (Intel exposes temps through a different interface — contributions welcome).

## How it works

- **Temperature** is read via Apple's private IOHID event-system sensors — the same approach used by open-source tools like Stats and macmon. No root or extra permissions needed.
- **Fans** come from the SMC (System Management Controller) over public IOKit calls.
- **CPU / RAM** use the standard Mach kernel APIs (`host_processor_info`, `host_statistics64`), with memory computed the way Activity Monitor's "Memory Used" is.
- **Top processes** use `libproc` resource-usage deltas between refreshes.

Because temperature relies on a private (undocumented) API, a future macOS release could change it. If a reading disappears after an update, that's the likely cause — please open an issue.

## Contributing

Issues and pull requests are welcome, especially:

- Intel Mac temperature sensor support (SMC keys)
- Testing on hardware the maintainer doesn't have (Mac mini/Studio/Pro fan layouts, various chip generations)

## License

[MIT](LICENSE) — free to use, modify, and distribute.

A notarized, ready-to-run build is available for a few dollars for those who'd rather not compile it themselves — it supports development and saves you the Gatekeeper dance. The source here is, and remains, free.
