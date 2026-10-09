<img src="Resources/icon-512.png" alt="" width="120" align="right">

# Vitals

CPU, memory and swap, network, disk, and temperature in one compact macOS menu-bar item. Local-only, with no dependencies or update checker.

**Requires:** Apple Silicon, macOS 14+, and the Xcode Swift toolchain.

## Features

- Click for per-core load, memory breakdown, warnings, and top processes.
- Interactive 5-minute or 1-hour charts: hover to inspect, click to pin, drag or use arrow keys to explore, and press Escape to release.
- Shrinks to fit crowded menu bars, pauses during sleep, and reduces sampling in Low Power Mode.
- Right-click to edit configuration, toggle **Start at Login**, or quit.

History stays in memory for the current session. Temperature availability varies by Mac; its sensors use a private Apple API.

## Install

```sh
git clone https://github.com/Abdulshakur24/mac-vitals.git
cd mac-vitals
./Scripts/build.sh
```

Builds, signs, installs to `/Applications`, and launches Vitals. Use `./Scripts/build.sh --no-install` to build only. The app lives in the menu bar, with no Dock icon.

## Configure

Edit `~/.config/vitals/config.json`. Changes apply immediately.

```json
{
  "menuBar": ["cpu", "memory", "network", "temperature"],
  "sampleInterval": 1,
  "thresholds": { "cpu": 0.7, "diskFree": 0.1, "temperature": 90 }
}
```

Add `disk` to show disk activity. Reorder metrics to change their order; remove them to hide them. Earlier entries get priority when space is limited. Omitted settings use defaults.

## Development

```sh
swift test
swift run Vitals --probe
```

`--probe` prints a snapshot of all metrics without opening the app.

[MIT license](LICENSE).
