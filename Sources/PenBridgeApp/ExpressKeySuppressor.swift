import AppKit
import CoreGraphics
import TabletCore

/// Swallows the events the tablet's own buttons generate.
///
/// The tablet's buttons are wired to fixed actions in firmware, and macOS turns them into
/// ordinary input events before any of this code runs. Seizing the device does not prevent
/// that — the system's HID driver keeps generating them — so the only way to take the
/// buttons over is to recognise the resulting events and discard them.
///
/// The buttons do not all produce the same kind of event, and they do not all arrive by
/// the same route. Most send keystrokes. The touch strip sends consumer-control usages,
/// which become media keys. The scroll buttons send a *mouse wheel*, on a second HID
/// interface that carries no digitizer usage at all — see `MouseReportLayout`.
///
/// Each of those is a separate thing to recognise, and missing one is invisible: the
/// feature looks like it works until someone presses the button it does not cover.
///
/// **This can swallow real input if it gets the recognition wrong**, so the conditions are
/// deliberately narrow. An event is discarded only when all of these hold:
///
/// * the tablet is connected and suppression is switched on,
/// * the event came from hardware rather than from another program,
/// * a matching tablet button report accounts for it — see `handle`.
///
/// Anything else passes through untouched. The correlation works because this driver reads
/// the tablet's reports directly, ahead of the event the system will synthesise from the
/// same press.
final class ExpressKeySuppressor {

    /// How long after a tablet button report a matching event is still attributed to it.
    /// Long enough to cover the system's own processing, short enough that a coincidental
    /// event is unlikely to land inside it.
    private let window: TimeInterval = 0.05

    /// An upper bound on how long a consumer button is believed to be held without any
    /// further word from the tablet. A release report that never arrives — the tablet
    /// unplugged mid-press, a report lost — would otherwise disable scrolling entirely
    /// until the app is restarted, which is a far worse failure than one stray scroll.
    private let holdLimit: TimeInterval = 10

    private struct PendingPress {
        let usage: UInt8
        let modifiers: UInt8
        let at: Date
    }

    /// A turn of the tablet's scroll wheel, waiting for the event macOS will make of it.
    /// Matched by direction, which is the one thing the two have in common.
    private struct PendingWheel {
        let isUp: Bool
        let at: Date
    }

    /// Written from the HID thread and read from the main run loop's tap callback,
    /// so every access is guarded.
    private var pending: [PendingPress] = []
    private var pendingWheel: [PendingWheel] = []
    /// Whether a consumer-control button is currently down, and when we last heard about
    /// it. Scroll is not a single event: macOS emits a stream of them for as long as the
    /// button is held, so this is tracked as a state rather than as a timed window the way
    /// keystrokes are.
    private var consumerHeld = false
    private var consumerAt = Date.distantPast
    private var tabletConnected = false
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Reported for anything actually discarded, so the behaviour is observable rather
    /// than a silent hole in the user's input.
    var onSuppressed: ((String) -> Void)?

    var isRunning: Bool { tap != nil }

    /// Whether a tablet is attached at all. Nothing is ever discarded without one: the
    /// keyboard and the trackpad are the user's, and a driver with no tablet in front of
    /// it has no business touching them.
    var isTabletConnected: Bool {
        get { lock.withLock { tabletConnected } }
        set {
            lock.withLock {
                tabletConnected = newValue
                if !newValue {
                    pending.removeAll()
                    pendingWheel.removeAll()
                    consumerHeld = false
                    consumerAt = .distantPast
                }
            }
        }
    }

    /// Records a button press seen on the tablet's own HID stream.
    func note(_ event: TabletButtonEvent) {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        pending.removeAll { now.timeIntervalSince($0.at) > window }

        switch event {
        case .keyboard(let key):
            guard !key.isRelease else { return }
            // A modifier-only press has no key usage of its own; record it as usage 0 so a
            // bare flagsChanged event can still be matched.
            let usages = key.usages.isEmpty ? [0] : key.usages
            for usage in usages {
                pending.append(PendingPress(usage: usage, modifiers: key.modifiers, at: now))
            }

        case .consumer(let consumer):
            // Every report refreshes the timestamp, so a device that repeats while a
            // button is held keeps the hold alive rather than ageing out of it.
            consumerAt = now
            consumerHeld = !consumer.isRelease

        case .wheel(let mouse):
            pendingWheel.removeAll { now.timeIntervalSince($0.at) > window }
            guard mouse.wheel != 0 else { return }
            pendingWheel.append(PendingWheel(isUp: mouse.wheel > 0, at: now))
        }
    }

    func start() {
        guard tap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
            // The media keys the touch strip sends arrive as NX_SYSDEFINED, which
            // `CGEventType` has no case for. Its raw value is stable and documented in
            // IOLLEvent.h.
            | (1 << Self.systemDefinedEventType)

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
        lock.withLock {
            pending.removeAll()
            pendingWheel.removeAll()
            consumerHeld = false
            consumerAt = .distantPast
        }
    }

    /// `NX_SYSDEFINED`.
    private static let systemDefinedEventType: UInt32 = 14
    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS` — the subtype media keys arrive under. Other
    /// system-defined events (window server bookkeeping, mouse subtypes) share the type
    /// and must not be touched.
    private static let auxControlSubtype: Int16 = 8

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

        // Events another program posted are never the tablet's, whatever else lines up.
        // Hardware events report no originating process.
        guard event.getIntegerValueField(.eventSourceUnixProcessID) == 0 else {
            return Unmanaged.passUnretained(event)
        }

        let discarded: String?
        switch type.rawValue {
        case CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue,
             CGEventType.flagsChanged.rawValue:
            discarded = matchKeystroke(type: type, event: event)
        case CGEventType.scrollWheel.rawValue:
            discarded = matchScroll(event)
        case Self.systemDefinedEventType:
            guard NSEvent(cgEvent: event)?.subtype.rawValue == Self.auxControlSubtype else {
                return Unmanaged.passUnretained(event)
            }
            discarded = matchConsumer(named: "media key")
        default:
            discarded = nil
        }

        guard let discarded else { return Unmanaged.passUnretained(event) }

        // Reported off the tap callback: it has a deadline, and macOS disables it if a
        // handler takes too long.
        DispatchQueue.main.async { [weak self] in self?.onSuppressed?(discarded) }
        return nil
    }

    /// Matches a keystroke against the tablet button reports seen just before it, and
    /// returns a name for it when it is the tablet's.
    private func matchKeystroke(type: CGEventType, event: CGEvent) -> String? {
        let virtualKey = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        lock.lock()
        defer { lock.unlock() }
        guard tabletConnected else { return nil }

        let now = Date()
        pending.removeAll { now.timeIntervalSince($0.at) > window }

        guard let index = pending.firstIndex(where: { press in
            if press.usage == 0 {
                // Modifier-only button: match the flags change it produced.
                return type == .flagsChanged
            }
            return HIDKeyCodes.matches(usage: press.usage, virtualKey: virtualKey)
        }) else {
            return nil
        }

        let press = pending[index]
        // Keep the entry for the release that follows, but not past the window.
        if type == .keyUp || type == .flagsChanged {
            pending.remove(at: index)
        }
        return HIDKeyCodes.name(usage: press.usage, modifiers: press.modifiers)
    }

    /// Matches a scroll event against the tablet's own wheel reports.
    ///
    /// This one can be matched properly rather than guessed at: the tablet's report says
    /// which way its wheel turned, and so does the event. A scroll in the other direction,
    /// or one with no tablet report behind it, is the user's mouse or trackpad and is left
    /// alone.
    private func matchScroll(_ event: CGEvent) -> String? {
        let delta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        guard delta != 0 else { return nil }

        lock.lock()
        defer { lock.unlock() }
        guard tabletConnected else { return nil }

        let now = Date()
        pendingWheel.removeAll { now.timeIntervalSince($0.at) > window }
        guard let index = pendingWheel.firstIndex(where: { $0.isUp == (delta > 0) }) else {
            // Some tablets send scrolling as a consumer usage instead of a wheel, and
            // those carry no direction to match on.
            return matchConsumerLocked(named: "scroll")
        }
        pendingWheel.remove(at: index)
        return "scroll \(delta > 0 ? "up" : "down")"
    }

    /// Whether a consumer-control button on the tablet accounts for the event in hand.
    ///
    /// Unlike a keystroke there is nothing in a scroll or media event tying it to a
    /// particular usage, so the test is whether one of those buttons is down at all. That
    /// is why the hold is tracked precisely: while nothing is pressed on the tablet, the
    /// user's own trackpad and keyboard scroll and skip tracks as they always did.
    private func matchConsumer(named name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard tabletConnected else { return nil }
        return matchConsumerLocked(named: name)
    }

    /// The body of `matchConsumer`, for callers that already hold the lock.
    private func matchConsumerLocked(named name: String) -> String? {
        let elapsed = Date().timeIntervalSince(consumerAt)
        if consumerHeld && elapsed > holdLimit {
            // A release we never heard. Give scrolling back rather than staying wrong.
            consumerHeld = false
            return nil
        }
        // A button still down, or one just let go: macOS delivers the last of its events
        // slightly after the release report reaches us.
        guard consumerHeld || elapsed <= window else { return nil }
        return name
    }
}
