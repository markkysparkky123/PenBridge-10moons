# OpenToonz and pen pressure — resolved

**Resolved.** OpenToonz 1.7.1 responds to pressure correctly once the driver sends a
complete proximity cycle. The cause was on this side: proximity was being re-announced
with a bare "entered" and no matching "left", a sequence real hardware never produces.
OpenToonz resets its tablet state on `TabletLeaveProximity`, so it was left holding a
registration it believed was already active and ignored the pressure it was being sent.

It took three attempts to fix, and the first two are worth recording because each looked
complete and was not.

1. **Re-announce when the frontmost application changes.** Fixed switching away and
   back. Did not fix restarting the driver.
2. **Withdraw the pen before its first announcement, and on shutdown.** Fixed restarting
   the driver. Did not fix restarting the application: the one full cycle had already
   been spent, so an application launched later still received a bare "entered". Pulling
   the USB cable remained the only reliable cure, because a disconnect is what finally
   produces the withdrawal an application is waiting for.
3. **Announce a full leave/enter cycle on every approach of the pen.** This is the fix.

The first two attempts share a mistake: both tried to work out *when* a re-announcement
was needed. Applications learn about the pen from these events alone and can start at
any moment — between two strokes, while the pen rests beside the tablet, long after the
driver did. A withdrawal nobody is registered for is ignored, so announcing in full
every time costs one extra event and removes the question entirely.

The menu carries a **Re-announce pen to applications** item for anything that still ends
up out of step.

The investigation below is kept because the measurements are useful in their own right,
and because it shows how the driver's output was verified independently of any one
application.

## The original symptom

OpenToonz did not vary stroke weight with pen pressure, while other applications on the
same machine and the same driver did.

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
and delivers them to the application.

At the time, that was read as putting the fault inside OpenToonz. It was the right
measurement and the wrong conclusion: every individual event was correct, but the
*sequence* they arrived in was not, and a log of individual events cannot show that.
The malformed proximity cycle above was the actual cause.

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
