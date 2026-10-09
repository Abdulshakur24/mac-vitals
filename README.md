<img src="Resources/icon-512.png" alt="" width="120" align="right">

# Vitals

A personal system monitor for the macOS menu bar. Built as a replacement for
iStat Menus and Stats, with the parts that made those tiresome left out: one
compact status item instead of several, no preferences window, no update
checker, and no network code at all.

Written for a MacBook Air M4 on macOS 26. Should work on any Apple Silicon Mac
running macOS 14+, though the temperature sensor names were only verified on
this one.

## What it shows

**Menu bar** — a single item with CPU (sparkline + load), memory used, network
throughput up and down, and CPU die temperature. Which metrics appear, and in
what order, comes from the config file.

The readout gives ground when the menu bar runs short of space rather than
disappearing whole, which is what macOS does to a status item that no longer
fits. Ornament goes first — the CPU sparkline, the decimal on memory, the units
on the network rates — and only then whole metrics, always from the least
important end. It takes the space back as soon as there is room for it.

**Popover** — click the item for a compact attention summary, per-core P/E load
bars, five-minute or one-hour history, memory breakdown with the system pressure
status and swap used, disk capacity and throughput, temperature summaries, and
the top five processes by CPU and by memory. An Activity Monitor shortcut opens
the system app for further investigation. The panel scrolls on smaller displays.

History uses timestamped five-second peak buckets, bounded to roughly one hour
per metric. The same real-time axis is used at every sampling rate, including
Low Power Mode. Gaps break the lines after sleep or missing samples. The menu-bar
CPU graph covers the last minute. Memory history shows **used RAM / physical
RAM**, not an approximation of Activity Monitor's memory pressure graph. Upload
and download share one scale, with its maximum printed below the chart.

Hover over a history chart for a crosshair, timestamp, and peak values. Click to
pin the reading, or drag to scrub; click again, use the clear button, or press
Escape to release it. Click a chart and use the left/right arrow keys to step
through recorded samples. Network inspection shows download and upload together.
Sleep gaps report “No sample.” Pinned values stay fixed while sampling continues;
changing the history window or aging out of the window clears the pin.
Charts do not take keyboard focus when the panel opens. The panel uses AppKit's
native popover background and a standard segmented history picker, with system
appearance rather than a custom glass effect or opacity setting.

**Needs attention** reports low disk space immediately, elevated memory pressure
after ten seconds, and high overall CPU after fifteen seconds. Critical memory
pressure and serious/critical macOS thermal states appear immediately. CPU and
disk conditions use the configured thresholds; temperature's configured limit
colors the menu-bar temperature. Thermal state is checked independently of the
private temperature sensors. Sleep interrupts pending warnings. Recent events
are retained for the session, limited to twenty events and one hour after an
event ends. History and events stay in memory; nothing is uploaded or written
to disk, and there are no notification permissions or additional timers.

Right-click for the config file, a launch-at-login toggle, and quit.

## Build and install

Needs an Apple Silicon Mac on macOS 14 or later and the Swift toolchain that
comes with Xcode. Nothing else — no package manager, no dependencies, and the
build resolves nothing from the network.

```sh
git clone https://github.com/Abdulshakur24/mac-vitals.git
cd mac-vitals
./Scripts/build.sh              # build, bundle, sign, install to /Applications, launch
./Scripts/build.sh --no-install # build the .app only, leaving /Applications alone
```

To look at the numbers without installing anything, build with SwiftPM and run
the probe described below:

```sh
swift build && ./.build/debug/Vitals --probe
```

The bundle is signed ad-hoc, which is all a locally built app needs — it never
crosses a quarantine boundary, so Gatekeeper is not involved. Uninstalling is
`rm -rf /Applications/Vitals.app` plus `~/.config/vitals` if you want the
config gone too.

The app has no Dock tile and no window; once it launches, it is the status item
in the menu bar.

## Configuration

`~/.config/vitals/config.json`, created on first launch. Saving it applies the
change immediately; there is no restart and no settings UI.

```json
{
  "menuBar": ["cpu", "memory", "network", "temperature"],
  "sampleInterval": 1,
  "thresholds": { "cpu": 0.7, "diskFree": 0.1, "temperature": 90 }
}
```

`menuBar` accepts `cpu`, `memory`, `network`, `disk`, and `temperature`.
Reordering the array reorders the readout; removing an entry hides it.
Temperature sampling also stops when it is hidden and the popover is closed;
CPU, memory, network, and disk continue to support history and attention.
Sampling intervals and thresholds are bounded on load. Any key may be left out
and takes its default, and a metric name the app does not know is skipped rather
than failing the file. Malformed JSON, or a value of the wrong type, keeps the
last valid configuration (or the default at startup). Threshold changes
apply to both the menu bar and popover immediately.

The order is also the order of importance. On a crowded menu bar the readout is
cut back from the end of the list, so the first entry is both the leftmost and
the last one to go — one list to edit rather than two.

## Checking the numbers

`Vitals --probe` prints one round of every sampler to stdout and exits, which
is how each metric was validated against the system's own tools:

| Metric | Cross-checked against |
|---|---|
| CPU, memory | Activity Monitor, `vm_stat` |
| Swap | `sysctl vm.swapusage` |
| Network | `netstat -ibn` deltas over the same window |
| Disk | `ioreg -r -c IOBlockStorageDriver`, `df -h /` |
| Temperature | response to sustained load |
| Processes | `top`, and a single-core busy loop as ground truth |

## Notes on the awkward parts

**Temperature uses a private API.** There is no public way to read die
temperature on Apple Silicon; `powermetrics` needs root, which a background app
should not hold. `ThermalSampler` resolves six `IOHIDEventSystem` symbols with
`dlsym` rather than linking them, so if a future macOS removes them the
temperature readout disappears and everything else keeps working. Sensor naming
is not stable across machines — this M4 reports `PMU tdie8`, while other Macs
use SMC-style keys like `Tp09`. Both are handled. `tcal` sensors are excluded:
they are calibration references that read ~52°C at idle and would otherwise
dominate the maximum.

**A status item with no room left says nothing about it.** macOS neither clips
nor shrinks an item it cannot fit — it stops drawing it, while `isVisible`,
`alphaValue` and `occlusionState` all keep reporting a healthy item. The
window's frame keeps growing leftward, past the notch and off the screen, so
there is nothing to observe but the geometry. `StatusItemFit` measures it: the
item's right edge is fixed by whatever sits to its right — verified unmoved
across lengths from 60 to 2400 points — and the left limit is the right edge of
the notch, since no status item is ever placed beside or left of it. On a
display without a notch the limit is the frontmost app's menu titles, which
there is no public way to locate, so a generous allowance is assumed instead.

Not all of the space beside the notch is placeable, and `auxiliaryTopRightArea`
does not say so. macOS keeps a gap after the notch that it will not put a
status item in — measured at 18 to 22 points on this M4 by pinning the layout
to a fixed width and reading back whether the window server drew it: x=966
refused, x=970 drawn, against a reported edge of x=948. Taking that reported
edge at face value is a quiet way to lose the readout altogether: the
arithmetic says a layout fits, macOS declines to draw it, and because the sums
go on agreeing with themselves the ladder never steps down. `notchClearance`
is what keeps the fit inside the space that measurement says exists rather
than the space the API reports.

**The arithmetic gets a second opinion.** A clearance measured on one Mac is
still a model, and a model can be wrong in the one direction it cannot see:
believing a layout fits that macOS then refuses to draw. Nothing about that
state corrects itself — the item stays gone until something else on the menu
bar changes, which can be days.

So the model does not get the last word. `kCGWindowIsOnscreen` does report the
truth about our own row in the window list, undrawn included, and it is read on
the same pass that measures the space, so it costs nothing extra. A width the
window server would not draw is recorded and caps the ladder, and the cap is
held against the space the other items are holding rather than against our own
budget — that number does not move when the readout changes shape, so a
refusal survives our own resizes and is dropped only when the menu bar it was
made on is genuinely gone.

Every rung of the ladder can be looked at without waiting for a full menu bar,
including the refusal path, which otherwise needs a menu bar with no room left
in it and a neighbour macOS is unwilling to drop instead:

```sh
VITALS_FIT_AVAILABLE=130 /Applications/Vitals.app/Contents/MacOS/Vitals
VITALS_FIT_DEBUG=1 /Applications/Vitals.app/Contents/MacOS/Vitals  # log each change
VITALS_FIT_UNDRAWN=1 /Applications/Vitals.app/Contents/MacOS/Vitals # claim every refusal
```

With the last of these the readout walks the whole ladder down and stops at the
bottom rung rather than churning: `146 → 140 → 114 → 111 → 100 → 74 → 66 → 40`,
one refusal recorded per rung.

**Network counters can wrap or reset.** Some machines return a 32-bit value
through `if_msghdr2`'s 64-bit fields. Deltas are tracked per interface identity
(index and last-change timestamp), with fresh baselines after wake, disconnect,
or replacement. A backwards value is accepted as a single wrap only near the
32-bit boundary and within a conservative link-rate budget. Unknown speeds and
ambiguous long intervals are rebaselined instead, so totals can undercount those
intervals. A reset near the wrap boundary with unchanged identity is inherently
indistinguishable from a wrap with this API. Native 64-bit forward counters work
without truncation. Session totals cover observed transfers since launch.

Rates sum all active, non-loopback interfaces, which may count VPN traffic at
both the tunnel and physical interface. The displayed interface is the one with
the largest **current delta**, not the largest lifetime byte counter.

**Process CPU times are not nanoseconds.** `ri_user_time` and `ri_system_time`
are documented as nanoseconds but are actually mach absolute time units. On this
M4 the timebase is 125/3, so treating them as nanoseconds under-reports CPU by
about 42x. Verified against a single-core busy loop: 99.4% with the conversion,
2.4% without.

**Some processes report a version as their name.** Anything installed under a
versioned directory has an executable named after the version, so both name
fields report e.g. `2.1.218`. When the name starts with a digit the sampler
falls back to `argv[0]`, which is what `ps` displays.

**The icon is drawn square on purpose.** `Scripts/make-icon.sh` renders it from
`make-icon.swift` and packs `Resources/Vitals.icns`; the artwork has no rounded
corners of its own. macOS 26 masks a legacy `.icns` into the system squircle
itself, so art that draws its own gets composited inside the system container
and comes out as an icon within an icon on a light plate. Drawing the squircle
at full canvas size does not fix it either — it is a slightly different curve
from the system's, and the gap shows as a pale fringe along the edges. A plain
filled square is the only version the mask lands on cleanly. On macOS 14 and
15, which do no masking, the icon is a square.

It is also not one drawing scaled down. At 16pt the mark gets about ten usable
pixels of width, so below 64 the complex collapses to a single spike and the
bloom is dropped, which would otherwise be grey haze at that size.

## Launch at login

Enabled by default via the status item's right-click menu, or from a terminal:

```sh
/Applications/Vitals.app/Contents/MacOS/Vitals --enable-login
/Applications/Vitals.app/Contents/MacOS/Vitals --login-status
/Applications/Vitals.app/Contents/MacOS/Vitals --disable-login
```

This registers with `SMAppService`, so it appears under System Settings →
General → Login Items and survives reboots. If registration is refused or lands
in `requiresApproval`, the app falls back to a `~/Library/LaunchAgents` plist,
which needs no signature or approval.

## Keeping it cheap

The whole point was to not be another monitor that costs more battery than it
saves. The original version measured idle, untouched for five minutes (these figures
are a baseline, not a measurement of the history/attention update):

**0.59% of one core** — 0.06% of this 10-core machine — with resident memory
flat at ~48 MB over repeated runs.

Getting there took profiling rather than guessing. Two things dominated, and
neither was a sampler:

1. A retained `NSHostingController` kept re-evaluating the entire popover's
   body on every tick while the popover was off screen.
2. A `isDetailVisible` boolean, set on open and cleared on close, got stuck
   true — so the app walked the whole process table every two seconds forever,
   which also grew RSS by ~14 MB every few minutes. It is now derived from
   `popover.isShown` instead, which cannot desynchronise.

The remaining cost is almost entirely the temperature sensors, which is
irreducible: reading them means one IOKit event copy per sensor.

- One timer for the entire app, with a tolerance of half the interval so macOS
  coalesces its wakeups with other system timers.
- Sampling stops on sleep and on display sleep, and resumes on wake.
- Top processes are only sampled while the popover is open. Temperature, which
  walks 40+ HID services, is read every 16 seconds (32 in Low Power Mode)
  whatever the base rate is.
- Timestamped history advances on the existing tick. History storage and recent
  event counts are bounded.
- Fixed per-metric widths and monospaced digits, so the status item resizes
  only when it changes shape to fit the space, never because a number gained a
  digit, and so it never drags the rest of the menu bar sideways on a tick.
- Fitting the readout to the space costs a round trip to the window server,
  which profiling showed was the most expensive thing a tick did. So it is
  measured at most every five seconds on ordinary ticks. It is measured on every
  tick after a layout change or while the item is not being drawn, and
  immediately when an app activates or a display or Space changes. It does not
  get a timer of its own.

## Regression checks

```sh
swift test
swift run Vitals --probe
./Scripts/build.sh --no-install
```

Tests cover threshold validation, timestamped retention and peak aggregation,
chart inspection and pinned readings, sleep gaps, network wraps/resets/reconnections,
and sustained attention events.
For optional offscreen light/dark popover renders without changing the installed
application:

```sh
VITALS_RENDER_DIR="$PWD/.build/previews" swift test --filter PreviewTests
```
