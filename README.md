# PenBridge

An open-source macOS driver for cheap USB graphics tablets, built natively for Apple
Silicon.

It exists because the tablet it was written for — a `SZ PING-IT [T501]`, sold under
various names — ships with an Intel-only driver that its vendor stopped supporting at
macOS 10.13. That driver runs on Apple Silicon today only through Rosetta 2, which is
being wound down. PenBridge does the same job as a native `arm64` build, from source
you can read.

**Status: working, young.** Verified on real hardware: the cursor tracks, clicks land,
and pressure reaches drawing applications. Area mapping is not yet adjustable beyond
proportions and rotation, and the tablet's own buttons cannot be remapped.

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
APP=~/Applications/PenBridge.app/Contents/MacOS/penbridge-cli

$APP info               # detected tablets, parsed descriptor, pen layout
$APP dump               # raw HID reports with a decoded breakdown
$APP pressure           # live pressure meter: raw, configured band, mapped output
$APP calibrate --apply  # measure the tablet's true limits and write them to the config
$APP probe              # log the tablet events any driver is posting
$APP nsprobe            # draw in a window; shows what an application actually receives
```

`calibrate` matters more than it sounds. Tablets routinely disagree with the range they
declare in their own descriptor; if yours does, the cursor will stop short of the screen
edge. Trace all four physical edges of the active area and watch for the numbers to
settle.

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
