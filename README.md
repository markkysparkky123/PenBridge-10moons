# PenBridge

An open-source macOS driver for cheap USB graphics tablets, built natively for Apple
Silicon.

It exists because the tablet it was written for — a **10moons (天敏) 1060Plus**, USB
`08F2:6811` — ships with an Intel-only driver that its vendor stopped supporting at
macOS 10.13. That driver runs on Apple Silicon today only through Rosetta 2, which is
being wound down. PenBridge does the same job as a native `arm64` build, from source
you can read.

**Status: working, young.** Verified on real hardware against four drawing applications:
the cursor tracks, clicks land, and pressure gets through. The tablet's own buttons keep
their firmware shortcuts — see below for why that is harder than it looks.

## What works

- Absolute cursor positioning from the pen
- 2048 pressure levels, delivered as proper tablet events so drawing applications see them
- Tip, barrel and eraser switches
- Proportional area mapping, so a circle drawn on the tablet is a circle on screen
- Rotation in 90° steps
- Adjustable pen feel (pressure curve)
- Per-tablet calibration, because the descriptor's declared ranges are not the truth
- Choosing the active area by tapping two corners
- Starts at login
- Hot-plug

## Application compatibility

Pressure is delivered three ways at once, because applications disagree about where to
look for it: proximity events, standalone `NSEventTypeTabletPoint` events, and mouse
events carrying tablet data in their subtype. That is what a real tablet produces.

Tested on macOS 26:

| Application | Toolkit | Pressure |
|---|---|---|
| `penbridge-cli nsprobe` | AppKit | works |
| HuePaint | AppKit | works |
| MediBang Paint Pro | Qt 5.5 | works |
| OpenToonz 1.7.1 | Qt 5.15 | works |
| FireAlpaca 2 | Qt 5.4 | works |

Two of these looked at first like the driver failing, and neither was the same problem.

**FireAlpaca** was a brush setting inside the application. Its Qt log showed pressure
arriving at 0.82 across 2315 strokes the whole time. Before concluding the driver is at
fault, check that the brush is actually configured to vary with pressure — the usual
trap is a size set as a **range** with both ends on the same value, which cannot change
no matter what pressure arrives.

**OpenToonz** was the driver, but not in a way any single event could show. Applications
track the pen through proximity events and are strict about the sequence: an "entered"
must be matched by a "left". Every individual event carried correct pressure; the order
they arrived in was wrong. See [Docs/OPENTOONZ.md](Docs/OPENTOONZ.md).

If you find a real incompatibility, `penbridge-cli nsprobe` produces the evidence worth
attaching to a bug report: it shows the event counts and pressure values an application
is being sent.

## What does not, and will not

**Tilt.** The hardware does not sense it. No driver can add it — see
[Docs/PROTOCOL.md](Docs/PROTOCOL.md).

**Remapping the tablet's buttons** is not implemented, and the reason is worth stating
because the obvious approaches do not work.

The buttons send fixed shortcuts from firmware — brush, eraser, brush size, zoom, pan,
colour picker — and macOS acts on them before this driver sees anything. Seizing the
device does not stop that: `IOHIDDeviceOpen` with `kIOHIDOptionsTypeSeizeDevice` reports
success while the volume keeps changing, because the system's HID driver runs in a
DriverKit process of its own.

The vendor's driver manages it by writing a new key table into the tablet, through the
vendor-defined configuration channel — it contains no event tap at all, so it cannot be
doing anything else. That is the right mechanism: the device then sends what you asked
for, with nothing to intercept and nothing to go wrong when the driver is not running.
The format of those writes has not been decoded. Doing so means capturing the vendor
driver's `IOHIDDeviceSetReport` calls, and acting on it means writing to the device,
which is the one operation here that could leave a tablet needing the vendor's own
software to recover. Contributions welcome; see [Docs/PROTOCOL.md](Docs/PROTOCOL.md) for
what the buttons currently send.

There is an opt-in **Ignore the tablet's own buttons** switch that discards what the
buttons send rather than replacing it, for anyone who finds the firmware shortcuts get in
the way. It covers all three kinds, which is worth spelling out because they are three
genuinely different mechanisms and covering two of them looks identical to covering all:

| Buttons | What they send | What macOS makes of it |
|---|---|---|
| Down the side | keystrokes | key events |
| The touch strip | consumer-control usages | media keys (`NX_SYSDEFINED`) |
| Scroll | a **mouse wheel**, on a second HID interface | scroll events |

The last one is the reason this took two attempts. Those buttons are not keys at all: the
tablet publishes a second HID interface that declares an ordinary mouse, and no digitizer
usage appears anywhere on it. A driver that finds tablets by their digitizer usage — the
correct way to do it — never opens that interface, so those buttons are invisible to it
while working perfectly. See [Docs/PROTOCOL.md](Docs/PROTOCOL.md).

Your own mouse and trackpad are unaffected: a scroll is discarded only when the tablet's
wheel turned the same way a moment earlier.

## Requirements

- macOS 13 or later
- Xcode 15 or later (Xcode 26 to open `Package.swift` directly)

## Building

```sh
git clone <this repository>
cd PenBridge
./Scripts/build-app.sh
open ~/Applications/PenBridge.app
```

The build installs to `~/Applications` rather than leaving the app in `build/`, because
LaunchServices will not start an app from a volume mounted `nosuid` — which most
external drives are. It reports that as a launch timeout (`-1712`) rather than as a
permissions problem, so an app sitting in a checkout on an external disk simply appears
to be broken. Set `NO_INSTALL=1` to skip the install step.

Or open `Package.swift` in Xcode and run the `PenBridgeApp` scheme.

The build is not code-signed with an Apple Developer ID, because this project does not
have one. If you move the `.app` to another Mac, Gatekeeper will refuse it until you
right-click the app and choose **Open**, or run:

```sh
xattr -dr com.apple.quarantine /path/to/PenBridge.app
```

Building it yourself is the recommended route, and the reason the sources are here.

### If you plan to rebuild

Run this once, before your first build:

```sh
./Scripts/make-signing-cert.sh
```

Without it the app is ad-hoc signed, which means macOS identifies it by the hash of its
contents:

```
designated => cdhash H"776db06f..."
```

That hash changes on every build, and privacy grants are attached to it — so macOS asks
for Input Monitoring and Accessibility again after **every single rebuild**, and the
permissions you already granted appear to be ignored. The script creates a local
self-signed certificate so the app is identified by bundle ID and certificate instead,
which survives rebuilds.

It touches only your own keychain, changes nothing for anyone else, and can be undone by
deleting the certificate in Keychain Access.

## Permissions

macOS requires two grants, and neither fails loudly — without them the tablet simply
does nothing:

| Permission | Why |
|---|---|
| **Input Monitoring** | to read the pen's HID reports |
| **Accessibility** | to move the cursor and deliver clicks |

Both are requested on first launch. Grant them in
**System Settings → Privacy & Security**, then quit and reopen PenBridge — macOS only
applies these to a freshly launched process.

## Diagnostics

A command-line tool ships inside the bundle. It is the fastest way to find out what your
tablet is actually doing.

```sh
APP=~/Applications/PenBridge.app/Contents/MacOS/penbridge-cli

$APP info               # detected tablets, parsed descriptor, pen layout
$APP dump               # raw HID reports with a decoded breakdown
$APP pressure           # live pressure meter: raw, configured band, mapped output
$APP calibrate --apply  # measure the tablet's true limits and write them to the config
$APP buttons            # what each tablet button sends, and what macOS makes of it
$APP probe              # log the tablet events any driver is posting
$APP nsprobe            # draw in a window; shows what an application actually receives
```

`calibrate` matters more than it sounds. Tablets routinely disagree with the range they
declare in their own descriptor; if yours does, the cursor will stop short of the screen
edge. Trace all four physical edges of the active area and watch for the numbers to
settle.

`buttons` answers "why does this button do nothing / do the wrong thing". It shows the
report the tablet sent and the event macOS made of it side by side, watching at two levels
of the event stack, and on exit prints a table of button against effect. Your own typing
and mouse are listed separately, so there is no need to keep your hands off the keyboard
while using it. A button with a report but no event, or an event with no report, is the
interesting case — that is what found the scroll buttons hiding on a second interface.

`probe` is for comparing drivers. Run it while another driver is active to see exactly
which event fields reach applications — useful when one drawing app sees pressure and
another does not.

`nsprobe` opens a window and draws strokes weighted by the pressure it receives. If the
stroke varies there but not in the application you care about, the driver has done its
part; if it does not vary there either, the driver has not.

## Other tablets

PenBridge matches any device claiming a HID digitizer usage and reads its layout from
the device's own report descriptor, so there is a reasonable chance it will pick up a
tablet it has never seen. If yours works, or nearly works, please open an issue with the
output of `penbridge-cli info`.

## How this was built

The protocol was derived from the descriptors the tablet publishes to the operating
system, read out of the I/O Registry and decoded against the USB HID 1.11
specification, then confirmed against live reports. That is ordinary interoperability
work. No vendor code was disassembled or reused, and no vendor binaries or assets are
distributed here.

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with, endorsed by, or derived from any tablet manufacturer.
