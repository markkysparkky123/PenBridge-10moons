# PING-IT T501 tablet protocol

Everything here was read off the device itself — its USB and HID descriptors, as
published to the operating system — and confirmed against live reports. No vendor
software was disassembled to produce it.

If you have a different tablet, `penbridge-cli info` prints the same table for whatever
is plugged in. Pull requests documenting other models are welcome.

## USB

| | |
|---|---|
| Vendor ID | `0x08F2` (`SZ PING-IT INC.`) |
| Product ID | `0x6811` |
| Product string | `[T501] Driver Inside Tablet` |
| Serial string | `Internal CDROM ` |
| Device release | `bcdDevice` 6404 |
| USB version | 1.10, Full Speed (12 Mbit/s) |

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
and arrive as ordinary keystrokes. Remapping them therefore means intercepting this
report and substituting different events, not reconfiguring the device.

## Reports 1 and 8 — vendor channel

Vendor-defined usage page `0xFFA0`, seven data bytes, with report ID 1 as Input and
report ID 8 as a Feature report. Interface 2 exposes a second vendor channel on report
ID 6 in 63-byte blocks.

The vendor driver writes here via `IOHIDDeviceSetReport`, presumably to store settings
on the device. **PenBridge never writes to these reports.** The pen streams report 5
without any initialization, so nothing needs to be sent to the tablet to make it work.

## Observed behaviour

Anything in this section is empirical rather than declared, and can differ between units.

Measured on one unit over 1901 samples, tracing all four edges of the drawing area and
pressing firmly in the centre:

| Property | Declared | Measured |
|---|---|---|
| X range | 0…4096 | **0…4095** |
| Y range | 0…4096 | **0…4095** |
| Pressure | 0…2047 | **5…1685** |

Two things worth knowing:

**The declared maximum is one too high.** The hardware never emits 4096 on either axis.
Mapping against the declared range leaves the last fraction of a pixel unreachable —
harmless in itself, but it is a reminder that the descriptor is a claim, not a
measurement.

**A firm press only reaches 82% of the pressure scale.** With a straight-through
pressure curve the pen can never produce full pressure, so brushes never reach their
maximum width or opacity no matter how hard you press. This is the single most
noticeable difference a calibration makes, and it is why `PressureCurve` carries an
upper threshold. `penbridge-cli calibrate --apply` sets it from the measurement.

Both figures come from one unit and one hand. Other tablets — and other people —
will differ, which is why they live in the config rather than in the source.

### The device can wedge

After the vendor driver is killed, the tablet may stop emitting pen reports until it is
unplugged and reconnected. It enumerates and opens normally in that state, so it looks
like a software fault when it is not. If the pen goes silent, replug the cable before
looking anywhere else.
