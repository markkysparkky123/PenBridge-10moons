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
| 2 | HID (3) | 1 interrupt IN | Vendor configuration channel **and a mouse with a wheel** |

**Interface 2 is not only the configuration channel**, and assuming it is costs more than
it sounds. It also declares an ordinary mouse — buttons, X, Y and a wheel — and that is
where the scroll buttons report. See [Interface 2](#interface-2--report-descriptor) below.

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
| bit 1 | 1 | Barrel switch — **declared, never sent**; see below |
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

### The barrel switch is declared but never sent

The descriptor declares a barrel switch on bit 1, and the pen has two side buttons, so the
obvious reading is that they are the same thing. They are not. Pressing either button —
hovering or with the tip down — leaves the flags byte at `0xC0` or `0xC1` and sends a
*keyboard* report instead: `+` is Ctrl+Y, `−` is Ctrl+Z, indistinguishable in form from
the buttons on the case.

Across every measured session bit 1 has never been set. A driver offering to turn the
barrel switch into a right-click therefore has nothing to act on, however correct its
code, and looks broken for a reason that is not in the driver at all.

The bit is left decoded, since it costs nothing and another unit may well wire it.

### No tilt

The descriptor contains no `X Tilt` (`0x3D`) or `Y Tilt` (`0x3E`) usages. This hardware
does not sense tilt, and no driver can add it. The vendor's own binary carries unused
`Tilt`/`TiltMap` symbols, which is a sign of shared code across several models rather
than a feature of this one.

## Report ID 2 — express keys

A standard boot-keyboard layout: one modifier bitmap byte, one reserved byte, then an
array of five key usages. Most of the tablet's buttons are wired to fixed shortcuts in
firmware and arrive as ordinary keystrokes.

Measured on a unit with buttons down the right edge, each pressed once, captured with
`penbridge-cli buttons`:

| Report | Key | Marked on the case |
|---|---|---|
| `00 00 08` | `E` | `E` |
| `00 00 05` | `B` | `B` |
| `01 00 56` | Ctrl + Keypad − | `CTRL-` |
| `01 00 57` | Ctrl + Keypad + | `CTRL+` |
| `00 00 2F` | `[` | `[` |
| `00 00 30` | `]` | `]` |
| `00 00 2C` | Space | |
| `01 00 00` | Ctrl alone | |
| `04 00 00` | Alt alone | |
| `08 00 07` | Cmd + `D` | |

A photo-editing default set — brush, eraser, brush size, zoom. Each button sends a
distinct code, so they can be told apart.

**The pen's two side buttons arrive here too**, on the same report as the buttons on the
case:

| Report | Key | Marked on the pen |
|---|---|---|
| `01 00 1C` | Ctrl + `Y` | `+` |
| `01 00 1D` | Ctrl + `Z` | `−` |

Note what is **not** in this table: the two scroll buttons. They send nothing at all on
this interface. See below.

That accounts for every button on the unit: twelve on the case — ten keyboard, two scroll
— and two on the pen.

### Ctrl+Z will suspend whatever is in your terminal

Worth stating because it costs an afternoon otherwise. A terminal turns Ctrl+Z into
SIGTSTP, so pressing that button suspends any diagnostic running in the foreground —
`penbridge-cli dump` stops dead, looking exactly like the tablet having gone silent. It
has not; the shell says `zsh: suspended` and `fg` brings it back. `penbridge-cli buttons`
ignores the signal for this reason.

## Report ID 4 — the touch strip

Touch fields along the bottom edge, sending consumer-control usages. Each press is one
16-bit usage, little-endian; releasing sends `00 00`. Measured:

| Report | Usage | Meaning |
|---|---|---|
| `E2 00` | `0x00E2` | Mute |
| `EA 00` | `0x00EA` | Volume Down |
| `E9 00` | `0x00E9` | Volume Up |
| `83 01` | `0x0183` | Media Player |
| `CD 00` | `0x00CD` | Play/Pause |
| `B6 00` | `0x00B6` | Previous Track |
| `B5 00` | `0x00B5` | Next Track |
| `23 02` | `0x0223` | Browser Home |
| `92 01` | `0x0192` | Calculator |

Nothing to do with drawing. macOS turns these into `NX_SYSDEFINED` events of subtype 8
(`NX_SUBTYPE_AUX_CONTROL_BUTTONS`) rather than key presses, which is why a suppressor
watching only the keyboard leaves them working.

Three of them — Media Player, Browser Home and Calculator — produced no event at all on
the machine this was measured on, though the tablet reported them normally.

## Interface 2 — report descriptor

```
06a0ff0901a10185069508753f150026ff00090119002aff008100c0
05010902a10185030901a1000509190129081500250195087501810205011581257f750895030930093109388106c0c0
```

| Report ID | Direction | Meaning |
|---|---|---|
| 6 | Input | Vendor page `0xFFA0`, 63-byte blocks — the configuration channel |
| 3 | Input | **Mouse: 8 buttons, X, Y and Wheel** |

## Report ID 3 — the scroll buttons

The two buttons that scroll are not keys and not consumer controls. They are a **mouse
wheel**, declared on this second interface as a textbook Generic Desktop mouse:

```
05 01 09 02  a1 01        Usage Page (Generic Desktop), Usage (Mouse), Collection
85 03                     Report ID 3
  09 01 a1 00             Usage (Pointer), Collection (Physical)
  05 09 19 01 29 08       Usage Page (Button), Usage Minimum 1, Maximum 8
  15 00 25 01 95 08 75 01 81 02       8 buttons, one bit each
  05 01 15 81 25 7f 75 08 95 03       three signed bytes, −127…127
  09 30 09 31 09 38 81 06             X, Y, Wheel — relative
```

Four payload bytes: a button bitmap, then X, Y and wheel as signed bytes. Pressing scroll
up sends `00 00 00 01`, scroll down `00 00 00 FF`. macOS's own mouse driver turns these
into ordinary scroll events, so the buttons work with no driver at all.

**This is the trap.** The interface's `DeviceUsagePairs` are `{0xFFA0,1}`, `{0x01,2}` and
`{0x01,1}` — **no digitizer usage anywhere on it**. A driver that finds tablets by their
digitizer usage, which is the correct and portable way to do it, never opens this
interface and never sees these buttons. They are then indistinguishable from buttons the
driver has no idea about: the scroll plainly happens, and the driver swears nothing was
pressed.

Matching it on its own is not an option either — that would mean opening every mouse on
the machine. PenBridge matches such devices, but adopts one only after a device with the
same vendor and product has turned up carrying a pen. A real mouse never passes that test,
and the ordering between a device's interfaces is not guaranteed, so candidates are held
aside until the pen appears. See `TabletAuxInterface`.

The vendor's own configuration file gives these two buttons the identifiers `FE` and `FD`,
which are not valid HID keyboard usages (those stop at `0xE7`) — its way of naming buttons
that do not arrive through the keyboard report.

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
