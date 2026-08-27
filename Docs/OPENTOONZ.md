# OpenToonz ignores pen pressure

OpenToonz 1.7.1 on macOS 26 does not vary stroke weight with pen pressure, while other
applications on the same machine and the same driver do. The evidence below places the
fault in OpenToonz rather than in the driver or in Qt.

Recorded with PenBridge driving a `SZ PING-IT [T501]`, brush tool with `Pressure`
enabled and `Size` set to a genuine minimum/maximum range.

## Other applications, same driver, same session

| Application | Toolkit | Pressure |
|---|---|---|
| HuePaint | AppKit, arm64 | works |
| MediBang Paint Pro | Qt 5.5.1 | works |
| FireAlpaca 2 | Qt 5.4.1 | no response |
| OpenToonz 1.7.1 | Qt 5.15.2 | no response |

Qt applications are not uniformly affected, and the Qt version does not order the
results, so this is not a toolkit-wide gap.

## What Qt receives

Run with Qt's own tablet logging enabled:

```sh
QT_LOGGING_RULES="qt.qpa.input.tablet*=true" \
  /Applications/OpenToonz.app/Contents/MacOS/OpenToonz
```

Proximity arrives and the device is registered:

```
qt.qpa.input.tablet: proximity change on tablet 26641: current tool 0 type 1 unique ID 150104081
```

Tablet events arrive with correct button state and pressure:

```
qt.qpa.input.tablet: event on tablet 26641 with tool 0 type 1 unique ID 150104081
  pos  276.0,  136.9 root pos  881.0,  467.9 buttons 0x1 pressure 0.62 tilt 0, 0 rotation   0.00
```

Over one ten-second drawing session, 2230 tablet events:

| | |
|---|---|
| events with `buttons 0x1` (tip down) | 792 |
| distinct pressure values | continuous from 0.00 to **0.80** |
| device ID | 26641, consistent between proximity and points |
| unique ID | 150104081 (`0x08F26811`), matching the tablet's vendor and product |

Qt's platform plugin therefore constructs `QTabletEvent`s carrying the correct pressure
and delivers them to the application. Whatever discards the pressure is above that
layer, inside OpenToonz.

## Reproducing the measurement

`penbridge-cli nsprobe` opens a window that draws strokes weighted by
`NSEvent.pressure`, and counts the event kinds an application receives. It is a useful
control: if strokes vary there and not in the application under test, the driver has
done its part.

## Caveat

Pressure is delivered on both standalone `NSEventTypeTabletPoint` events and mouse
events carrying tablet data, as real hardware does. Qt calls its tablet handler for
both, so each sample appears twice in the log above. That duplication does not affect
the pressure values, which are correct in every event; whether sending only one of the
two kinds would change OpenToonz's behaviour has not been tested.
