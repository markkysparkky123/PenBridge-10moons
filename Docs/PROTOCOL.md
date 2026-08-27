# 10moons 1060Plus tablet protocol

Sold as a **10moons (天敏) 1060Plus**, made by 惠州市新启点软件有限公司
(Huizhou Xinqidian Software). Retail brand and OEM are different companies, as usual at
this price.

Everything here was read off the device itself — its USB and HID descriptors, as
published to the operating system — and confirmed against live reports. No vendor
software was disassembled to produce it.

If you have a different tablet, `penbridge-cli info` prints the same table for whatever
is plugged in. Pull requests documenting other models are welcome.

## USB

| | |
|---|---|
| Vendor ID | `0x08F2` |
| Product ID | `0x6811` |
| Board revision | VER 2.0, 5 V DC below 0.5 A |
| Product string | `[T501] Driver Inside Tablet` — see below |
| Serial string | `Internal CDROM ` |
| Device release | `bcdDevice` 6404 |
| USB version | 1.10, Full Speed (12 Mbit/s) |

**Identify these tablets by vendor and product ID, not by their strings.** The
manufacturer string this unit reports has been observed to change between sessions,
naming different companies for the same physical device. Whether that comes from the
firmware or from how macOS caches descriptors is unclear, but either way the strings are
not something to match on. PenBridge does not: it matches any device claiming the HID
digitizer usage and reads the layout from the descriptor.

Composite device with three interfaces:

| Interface | Class | Endpoints | Purpose |
|---|---|---|---|
| 0 | Mass Storage (8 / 6 / 80) | 2 | Emulated CD-ROM holding the vendor installers |
| 1 | HID (3) | 1 interrupt IN | Pen, express keys, consumer control |
| 2 | HID (3) | 1 interrupt IN | Vendor configuration channel |

The CD-ROM interface is the "driver inside" gimmick — the tablet presents a read-only
disc so Windows can autorun the installer. It is irrelevant to operating the pen and can
be ignored. **No mode switch is needed:** the HID interfaces are present from the moment
the device enumerates, and the pen reports as soon as it is in range.

## Interface 1 — report descriptor

```
06a0ff0901a10185010902150025ff750895078102150025019540750105081901294091020900
150026ff00750895078508b102c005010906a1018502050719e029e715002501750195088102
95017508810195057501050819012905910295017503910195057508150025650507190029
658100c0050d0901a10185050920a100094209440945093c15002501750195048102750195
028101093275019501810281010501093075109501a4550d6513350046401f2600108102
093146dc142600108102b4050d093026ff0746ff0755006611e175108102c0c0050c0901
a101850419002a3c021500263c02950175108100c0
```

It declares four top-level collections:

| Report ID | Direction | Size | Meaning |
|---|---|---|---|
| 1, 8 | Input / Feature | 7 bytes | Vendor page `0xFFA0` configuration channel |
| 2 | Input | 8 bytes | Keyboard — how the express keys deliver shortcuts |
| 4 | Input | 2 bytes | Consumer control, usage `0…0x23C` |
| 5 | Input | 7 bytes | **The pen** |

## Report ID 5 — pen

Seven bytes of payload, following the report-ID byte.

| Offset | Size | Field |
|---|---|---|
| bit 0 | 1 | Tip switch |
| bit 1 | 1 | Barrel switch |
| bit 2 | 1 | Eraser |
| bit 3 | 1 | Invert (pen held upside down) |
| bits 4–5 | 2 | padding |
| bit 6 | 1 | In range |
| bit 7 | 1 | padding |
| bytes 1–2 | 16 | X, unsigned little-endian |
| bytes 3–4 | 16 | Y, unsigned little-endian |
| bytes 5–6 | 16 | Tip pressure, unsigned little-endian |

Ranges and geometry, as declared:

| | Logical | Physical |
|---|---|---|
| X | 0…4096 | 8.000 in = 203.2 mm |
| Y | 0…4096 | 5.340 in = 135.6 mm |
| Pressure | 0…2047 (2048 levels) | — |

Physical extents come from `Physical Maximum` 8000 and 5340 combined with
`Unit Exponent` −3 on the inch unit, so the active area is **203.2 × 135.6 mm**,
roughly 3:2 (1.498:1).

Note that the two axes share a logical range but not a physical one: one logical unit
is 0.0496 mm horizontally and 0.0331 mm vertically. Any aspect-ratio arithmetic has to
be done in millimetres, or circles come out as ellipses.

### No tilt

The descriptor contains no `X Tilt` (`0x3D`) or `Y Tilt` (`0x3E`) usages. This hardware
does not sense tilt, and no driver can add it. The vendor's own binary carries unused
`Tilt`/`TiltMap` symbols, which is a sign of shared code across several models rather
than a feature of this one.

## Report ID 2 — express keys

A standard boot-keyboard layout: one modifier bitmap byte, one reserved byte, then an
array of five key usages. The tablet's buttons are wired to fixed shortcuts in firmware
and arrive as ordinary keystrokes.

Measured on a unit with 12 buttons down the left edge, pressed in order:

| # | Report | Key |
|---|---|---|
| 1 | `00 00 08` | `E` |
| 2 | `00 00 05` | `B` |
| 3 | `01 00 56` | Ctrl + Keypad − |
| 4 | `01 00 57` | Ctrl + Keypad + |
| 5 | `00 00 2F` | `[` |
| 6 | `00 00 30` | `]` |
| 7 | `00 00 2B` | Tab |
| 8 | `00 00 2C` | Space |
| 9 | `01 00 00` | Ctrl alone |
| 10 | `04 00 00` | Alt alone |
| 11 | `08 00 07` | Cmd + `D` |

A photo-editing default set. Each button sends a distinct code, so they can be told
apart.

## Report ID 4 — the touch strip

Ten touch fields along the top edge, sending consumer-control usages: Mute (`0x00E2`),
Volume Down (`0x00EA`), Volume Up (`0x00E9`), Media Player (`0x0183`), Play/Pause
(`0x00CD`), Previous Track (`0x00B6`), Next Track (`0x00B5`), Browser Home (`0x0223`)
and Calculator (`0x0192`). Nothing to do with drawing.

## Seizing the device does not suppress these

`IOHIDDeviceOpen` with `kIOHIDOptionsTypeSeizeDevice` succeeds — the log reports
`opened … (seized)` — and macOS **still** acts on the express keys: volume changes, the
calculator opens, brush shortcuts fire in whatever application is frontmost.

The system's HID event driver (`AppleUserHIDEventDriver`) runs in a DriverKit process
and keeps generating events regardless of which userspace client holds the device.
Seizing is therefore not a way to take over a tablet's buttons on a current macOS, which
matters because it is the obvious approach and it looks like it worked.

Remapping the express keys consequently needs the generated events intercepted and
swallowed after the fact, not prevented at the source.

## Reports 1 and 8 — vendor channel

Vendor-defined usage page `0xFFA0`, seven data bytes, with report ID 1 as Input and
report ID 8 as a Feature report. Interface 2 exposes a second vendor channel on report
ID 6 in 63-byte blocks.

The vendor driver writes here via `IOHIDDeviceSetReport`, presumably to store settings
on the device. **PenBridge never writes to these reports.** The pen streams report 5
without any initialization, so nothing needs to be sent to the tablet to make it work.

## Observed behaviour

Anything in this section is empirical rather than declared, and can differ between units.

Measured on one unit across several runs, tracing all four edges of the drawing area and
pressing in the centre:

| Property | Declared | Measured |
|---|---|---|
| X range | 0…4096 | **0…4095** |
| Y range | 0…4096 | **0…4095** |
| Pressure | 0…2047 | **15…2005** |

**The declared maximum is one too high.** The hardware never emits 4096 on either axis.
Mapping against the declared range leaves the last fraction of a pixel unreachable —
harmless in itself, but a reminder that the descriptor is a claim, not a measurement.

**The pressure sensor is good.** It responds smoothly and proportionally to force across
almost the whole declared range. An earlier revision of this document reported a ceiling
of 1685, about 82% of scale, and treated it as a property of the hardware. It was not:
it was a calibration run where the pen was not pressed as hard as it is during actual
drawing. Setting the ceiling from that measurement made every heavier press map to full
pressure, so strokes jumped straight to maximum weight — a fault introduced by the
measurement, not found by it.

The lesson generalises: when calibrating pressure, press as hard as you ever will, and
treat a measured ceiling well below the declared maximum as suspect rather than as fact.
`penbridge-cli pressure` shows saturation live, and `calibrate --apply` now warns when
the ceiling it is about to write looks too low.

These figures come from one unit and one hand, which is why they live in the config
rather than in the source.

### An undocumented status bit

Bit 7 of the flags byte is declared as padding but is set in every report observed while
the pen is in range (`0xC0` hovering, `0xC1` with the tip down). Its meaning is unknown.
It is ignored, and reserved bits like this are worth leaving alone rather than guessing at.

### The device can wedge

After the vendor driver is killed, the tablet may stop emitting pen reports until it is
unplugged and reconnected. It enumerates and opens normally in that state, so it looks
like a software fault when it is not. If the pen goes silent, replug the cable before
looking anywhere else.
