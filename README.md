# PenBridge

An open-source macOS driver for cheap USB graphics tablets, built natively for Apple
Silicon.

It exists because the tablet it was written for — a `SZ PING-IT [T501]`, sold under
various names — ships with an Intel-only driver that its vendor stopped supporting at
macOS 10.13. That driver runs on Apple Silicon today only through Rosetta 2, which is
being wound down. PenBridge does the same job as a native `arm64` build, from source
you can read.

**Status: early.** The pen protocol is decoded and covered by tests; cursor control,
pressure and the menu-bar UI are implemented. It has not yet been through a full
hardware verification pass. Expect rough edges.

## What works

- Absolute cursor positioning from the pen
- 2048 pressure levels, delivered as proper tablet events so drawing applications see them
- Tip, barrel and eraser switches
- Proportional area mapping, so a circle drawn on the tablet is a circle on screen
- Rotation in 90° steps
- Adjustable pen feel (pressure curve)
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
| FireAlpaca 2 | Qt 5.4 | no response |
| OpenToonz 1.7.1 | Qt 5.15 | no response |

Both Qt and AppKit applications read the pen correctly, so an application that ignores
pressure is not evidence that the driver is failing — check its own settings first.

The usual culprit is a brush whose size is configured as a **range**, with the minimum
and maximum set to the same value. Pressure then varies a quantity that cannot change,
and the setting that enables it looks correctly switched on. OpenToonz's Brush tool
options are like this: `Size` has separate minimum and maximum handles.

If you find a real incompatibility, `penbridge-cli nsprobe` produces the evidence worth
attaching to a bug report: it shows the event counts and pressure values an application
is being sent.

## What does not, and will not

**Tilt.** The hardware does not sense it. No driver can add it — see
[Docs/PROTOCOL.md](Docs/PROTOCOL.md).

**Remapping the express keys** is not implemented yet. The buttons send fixed
keyboard shortcuts from firmware; intercepting and substituting them is possible but not
done.

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
APP=build/PenBridge.app/Contents/MacOS/penbridge-cli

$APP info        # detected tablets, parsed descriptor, pen layout
$APP dump        # raw HID reports with a decoded breakdown
$APP calibrate   # track the true min/max of X, Y and pressure as you move the pen
$APP probe       # log the tablet events any driver is posting
```

`calibrate` matters more than it sounds. Tablets routinely disagree with the range they
declare in their own descriptor; if yours does, the cursor will stop short of the screen
edge. Trace all four physical edges of the active area and watch for the numbers to
settle.

`probe` is for comparing drivers. Run it while another driver is active to see exactly
which event fields reach applications — useful when one drawing app sees pressure and
another does not.

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
