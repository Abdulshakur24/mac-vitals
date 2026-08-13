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

**Popover** — click the item for per-core P/E load bars, 60-second sparklines
for every metric, memory breakdown, disk capacity and throughput, all
temperature sensors, and the top five processes by CPU and by memory.

Right-click for the config file, a launch-at-login toggle, and quit.

## Build and install

```sh
./Scripts/build.sh              # build, bundle, sign, install to /Applications, launch
./Scripts/build.sh --no-install # build the .app only
```

Requires the Swift toolchain from Xcode. The bundle is signed ad-hoc, which is
all a locally built app needs — it never crosses a quarantine boundary, so
Gatekeeper is not involved.

## Configuration

`~/.config/vitals/config.json`, created on first launch. Saving it applies the
change immediately; there is no restart and no settings UI.

```json
{
  "menuBar": ["cpu", "memory", "network", "temperature"],
  "sampleInterval": 2,
  "thresholds": { "cpu": 0.7, "diskFree": 0.1, "temperature": 90 }
}
```

`menuBar` accepts `cpu`, `memory`, `network`, `disk`, and `temperature`.
Reordering the array reorders the readout; removing an entry hides it and stops
that sampler. Values are bounded on load, so a typo degrades to the default
rather than producing a broken or battery-hungry app.

The order is also the order of importance. On a crowded menu bar the readout is
cut back from the end of the list, so the first entry is both the leftmost and
the last one to go — one list to edit rather than two.

## Checking the numbers

`Vitals --probe` prints one round of every sampler to stdout and exits, which
is how each metric was validated against the system's own tools:

| Metric | Cross-checked against |
|---|---|
| CPU, memory | Activity Monitor, `vm_stat` |
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

**Network counters are effectively 32-bit.** `if_msghdr2` declares `ifi_ibytes`
as `u_int64_t`, but the value it carries is truncated to 32 bits and wraps every
4 GB. Deltas are corrected for the wrap, and totals are accumulated since launch
rather than read from the counter, since a since-boot total cannot be recovered
from a wrapped value.

**Process CPU times are not nanoseconds.** `ri_user_time` and `ri_system_time`
are documented as nanoseconds but are actually mach absolute time units. On this
M4 the timebase is 125/3, so treating them as nanoseconds under-reports CPU by
about 42x. Verified against a single-core busy loop: 99.4% with the conversion,
2.4% without.

**Some processes report a version as their name.** Anything installed under a
versioned directory has an executable named after the version, so both name
fields report e.g. `2.1.218`. When the name starts with a digit the sampler
falls back to `argv[0]`, which is what `ps` displays.

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
saves. Measured idle, untouched for five minutes:

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
  walks 40+ HID services, runs at a fifth of the base rate.
- Snapshots are `Equatable` and views only redraw on material change, so an
  idle machine produces no rendering work.
- Fixed per-metric widths and monospaced digits, so the status item resizes
  only when it changes shape to fit the space, never because a number gained a
  digit, and so it never drags the rest of the menu bar sideways on a tick.
- Fitting the readout to the space costs a window frame read and a walk of a
  couple of dozen precomputed widths, on the sample that is already happening.
  It does not get a timer of its own.
