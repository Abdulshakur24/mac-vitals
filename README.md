<img src="Resources/icon-512.png" alt="" width="120" align="right">

# Vitals

CPU, memory and swap, network, disk, and temperature in one compact macOS menu-bar item. Local-only, with no dependencies or update checker.

**Requires:** Apple Silicon, macOS 14+, and the Xcode Swift toolchain.

## Features

- Click for per-core load, memory breakdown, warnings, and top apps ranked by CPU or memory.
- App totals combine helpers from the same app bundle. Expand a row to inspect its processes and PIDs, or select **All** to include system services and command-line tools. Show five entries or expand the full list.
- Interactive 5-minute or 1-hour charts: hover to inspect, click to pin, drag or use arrow keys to explore, and press Escape to release.
- Shrinks to fit crowded menu bars, pauses during sleep, and reduces sampling in Low Power Mode.
- Right-click to edit configuration, toggle **Start at Login**, or quit.

History stays in memory for the current session. Temperature availability varies by Mac; its sensors use a private Apple API.

App CPU uses one core as 100%, so multithreaded apps can exceed 100%. App memory is summed resident memory and can count shared pages more than once. Process readings run only while the panel is open; reopening starts a fresh CPU interval.

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
