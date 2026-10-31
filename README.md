<img src="Resources/icon-512.png" alt="" width="120" align="right">

# Vitals

A local-only macOS menu-bar monitor for CPU, memory, network, disk, and temperature. No dependencies or update checker.

**Requires:** Apple Silicon, macOS 14+, and the Xcode Swift toolchain.

## Features

- Top apps by CPU or memory, with grouped helpers and expandable process details. Select **All** to include system services and command-line tools.
- Quit apps from the row’s actions menu, or Force Quit with confirmation.
- Per-core load, memory breakdown, swap, and sustained warnings.
- Interactive 5-minute or 1-hour charts with hover, pinning, and keyboard navigation.
- Shrinks to fit crowded menu bars, pauses during sleep, and reduces sampling in Low Power Mode.
- Right-click to edit configuration, toggle **Start at Login**, or quit.

100% app CPU equals one busy core. Resident memory totals may count shared pages more than once. Process scans run only while the panel is open.

The last hour of charts and warnings survives relaunches, stored locally in `~/Library/Application Support/Vitals/history.json`. Temperature availability varies by Mac and uses a private Apple API.

## Install

```sh
git clone https://github.com/Abdulshakur24/mac-vitals.git
cd mac-vitals
./Scripts/build.sh
```

Builds, signs, installs to `/Applications`, and launches Vitals. Add `--no-install` to build only.

## Configure

Edit `~/.config/vitals/config.json`. Changes apply immediately.

```json
{
  "menuBar": ["cpu", "memory", "network", "temperature"],
  "sampleInterval": 1,
  "thresholds": { "cpu": 0.7, "diskFree": 0.1, "temperature": 90 }
}
```

Add `disk` for free disk space as a percentage; remove metrics to hide them. Earlier entries get priority when space is limited. Omitted settings use defaults.

## Development

```sh
swift test
swift run Vitals --probe
```

`--probe` prints a snapshot of all metrics without opening the app.

[MIT license](LICENSE).
