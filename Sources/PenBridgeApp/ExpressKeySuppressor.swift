import AppKit
import CoreGraphics
import TabletCore

/// Swallows the keystrokes the tablet's own buttons generate.
///
/// The tablet's buttons are wired to fixed shortcuts in firmware, and macOS turns them
/// into ordinary key events before any of this code runs. Seizing the device does not
/// prevent that — the system's HID driver keeps generating them — so the only way to
/// take the buttons over is to recognise the resulting keystrokes and discard them.
///
/// **This can swallow real typing if it gets the recognition wrong**, so the conditions
/// are deliberately narrow. An event is discarded only when all of these hold:
///
/// * a tablet button report arrived within `window` before it,
/// * the virtual key code matches the HID usage that report carried,
/// * the tablet is connected and suppression is switched on.
///
/// Anything else passes through untouched. The correlation works because this driver
/// reads the tablet's reports directly, ahead of the event the system will synthesise
/// from the same press.
final class ExpressKeySuppressor {

    /// How long after a tablet button report a matching keystroke is still attributed
    /// to it. Long enough to cover the system's own processing, short enough that a
    /// coincidental keystroke is unlikely to land inside it.
    private let window: TimeInterval = 0.05

    private struct PendingPress {
        let usage: UInt8
        let modifiers: UInt8
        let at: Date
    }

    /// Written from the HID thread and read from the main run loop's tap callback,
    /// so every access is guarded.
    private var pending: [PendingPress] = []
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Reported for anything actually discarded, so the behaviour is observable rather
    /// than a silent hole in the user's keyboard.
    var onSuppressed: ((String) -> Void)?

    var isRunning: Bool { tap != nil }

    /// Records a button press seen on the tablet's own HID stream.
    func noteExpressKey(_ event: ExpressKeyEvent) {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        pending.removeAll { now.timeIntervalSince($0.at) > window }
        guard !event.isRelease else { return }

        // A modifier-only press has no key usage of its own; record it as usage 0 so a
        // bare flagsChanged event can still be matched.
        let usages = event.usages.isEmpty ? [0] : event.usages
        for usage in usages {
            pending.append(PendingPress(usage: usage, modifiers: event.modifiers, at: now))
        }
    }

    func start() {
        guard tap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let suppressor = Unmanaged<ExpressKeySuppressor>
                    .fromOpaque(context).takeUnretainedValue()
                return suppressor.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        lock.lock()
        pending.removeAll()
        lock.unlock()
    }

    private func handle(
        proxy: CGEventTapProxy, type: CGEventType, event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that takes too long to respond, or when input is
        // otherwise disrupted. Re-enabling is the caller's job; the alternative is a
        // tap that silently stops working.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let virtualKey = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        pending.removeAll { now.timeIntervalSince($0.at) > window }

        guard let index = pending.firstIndex(where: { press in
            if press.usage == 0 {
                // Modifier-only button: match the flags change it produced.
                return type == .flagsChanged
            }
            return HIDKeyCodes.matches(usage: press.usage, virtualKey: virtualKey)
        }) else {
            return Unmanaged.passUnretained(event)
        }

        let press = pending[index]
        // Keep the entry for the release that follows, but not past the window.
        if type == .keyUp || type == .flagsChanged {
            pending.remove(at: index)
        }

        // Reported off the lock and off this callback: the tap has a deadline, and
        // macOS disables it if a handler takes too long.
        let name = HIDKeyCodes.name(usage: press.usage, modifiers: press.modifiers)
        DispatchQueue.main.async { [weak self] in self?.onSuppressed?(name) }
        return nil
    }
}
