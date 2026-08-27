import Foundation
import IOKit
import IOKit.hid

/// A tablet that has been opened and whose descriptor has been parsed.
public final class TabletDevice {
    public let device: IOHIDDevice
    public let vendorID: Int
    public let productID: Int
    public let name: String
    public let layout: PenReportLayout
    public let fields: [HIDReportField]

    /// Buffer handed to IOKit for input reports; must outlive the callback registration.
    let buffer: UnsafeMutablePointer<UInt8>
    let bufferSize: Int

    init?(device: IOHIDDevice) {
        func property<T>(_ key: String, as: T.Type) -> T? {
            IOHIDDeviceGetProperty(device, key as CFString) as? T
        }

        guard
            let descriptorData = property(kIOHIDReportDescriptorKey, as: Data.self),
            case let descriptor = [UInt8](descriptorData),
            case let fields = HIDReportDescriptor.parse(descriptor),
            let layout = PenReportLayout(fields: fields)
        else { return nil }

        self.device = device
        self.fields = fields
        self.layout = layout
        self.vendorID = property(kIOHIDVendorIDKey, as: Int.self) ?? 0
        self.productID = property(kIOHIDProductIDKey, as: Int.self) ?? 0
        self.name = property(kIOHIDProductKey, as: String.self) ?? "Unknown tablet"

        // +1 covers the report-ID byte, which macOS may or may not include.
        self.bufferSize = max(property(kIOHIDMaxInputReportSizeKey, as: Int.self) ?? 0, layout.payloadSize + 1)
        self.buffer = .allocate(capacity: bufferSize)
        self.buffer.initialize(repeating: 0, count: bufferSize)
    }

    deinit {
        buffer.deinitialize(count: bufferSize)
        buffer.deallocate()
    }

    public var identifier: String {
        String(format: "%@ (%04X:%04X)", name, vendorID, productID)
    }

    /// Report IDs the descriptor declares as Feature reports, with their payload sizes.
    public var featureReports: [(id: UInt8, size: Int)] {
        var sizes: [UInt8: Int] = [:]
        for field in fields where field.kind == .feature {
            sizes[field.reportID] = max(sizes[field.reportID] ?? 0, field.bitOffset + field.bitSize)
        }
        return sizes.sorted { $0.key < $1.key }.map { ($0.key, ($0.value + 7) / 8) }
    }

    /// Reads one Feature report from the device.
    ///
    /// These are the vendor's configuration channel. Reading is safe and tells us what
    /// state the tablet believes it is in; nothing here ever writes to the device.
    public func readFeatureReport(id: UInt8, size: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: size + 1)
        var length = CFIndex(buffer.count)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(id), pointer.baseAddress!, &length)
        }
        guard result == kIOReturnSuccess, length > 0 else { return nil }
        return Array(buffer.prefix(Int(length)))
    }
}

/// Discovers graphics tablets, opens them, and streams their raw input reports.
///
/// Runs on its own thread with a dedicated run loop, so the caller never has to keep
/// a `CFRunLoop` spinning on the main thread.
public final class TabletDeviceMonitor {

    public struct Match: Sendable {
        public let vendorID: Int?
        public let productID: Int?

        public init(vendorID: Int? = nil, productID: Int? = nil) {
            self.vendorID = vendorID
            self.productID = productID
        }

        /// Any device claiming the digitizer/pen usage. Casting this wide lets the
        /// driver pick up models we have never seen, as long as they speak standard HID.
        public static let anyDigitizer = Match()
    }

    /// Called when a tablet is connected and successfully parsed.
    public var onAttach: ((TabletDevice) -> Void)?
    /// Called when a tablet goes away.
    public var onDetach: ((TabletDevice) -> Void)?
    /// Called for every input report, with the payload already stripped of its report-ID byte.
    public var onReport: ((TabletDevice, UInt8, [UInt8]) -> Void)?

    /// Diagnostic messages about opening devices — surfaced by the CLI so a silent
    /// failure to receive reports can be told apart from a pen that is simply not there.
    public var onLog: ((String) -> Void)?

    /// Take the device exclusively, stopping macOS's own HID driver from also acting
    /// on it.
    ///
    /// Without this the system's generic HID driver keeps generating its own plain
    /// mouse events from the same pen, interleaved with the tablet events posted here.
    /// Applications that track a tablet stroke see ordinary mouse movement arrive
    /// mid-stroke and fall back to treating the pen as a mouse.
    ///
    /// Changing this after a device is open takes effect immediately.
    public var seizeDevice = false {
        didSet { if seizeDevice != oldValue { reopenDevices() } }
    }

    private let manager: IOHIDManager
    /// Keyed by object identity. `IOHIDDevice` is a CoreFoundation type whose equality
    /// is not identity-based, so using it directly as a dictionary key lets the same
    /// physical device register twice.
    private var devices: [ObjectIdentifier: TabletDevice] = [:]
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    public init(matching matches: [Match] = [.anyDigitizer]) {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // One criterion per requested match, not one per usage. IOKit tests a device
        // against every dictionary and fires the matching callback for each one that
        // hits, so listing Pen, Digitizer and Stylus separately reports the same
        // tablet several times. Matching the digitizer usage *page* alone covers all
        // three, and interfaces that only carry vendor collections are filtered out
        // later anyway, when the descriptor turns out to have no pen report.
        let criteria: [[String: Any]] = matches.map { match in
            var dict: [String: Any] = [kIOHIDDeviceUsagePageKey: kHIDPage_Digitizer]
            if let vendorID = match.vendorID { dict[kIOHIDVendorIDKey] = vendorID }
            if let productID = match.productID { dict[kIOHIDProductIDKey] = productID }
            return dict
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, criteria as CFArray)
    }

    /// Starts discovery on a background run loop. Returns immediately.
    public func start() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.runLoop = CFRunLoopGetCurrent()

            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(self.manager, deviceAttached, context)
            IOHIDManagerRegisterDeviceRemovalCallback(self.manager, deviceDetached, context)
            IOHIDManagerScheduleWithRunLoop(
                self.manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue
            )
            let opened = IOHIDManagerOpen(self.manager, IOOptionBits(kIOHIDOptionsTypeNone))
            if opened != kIOReturnSuccess {
                self.onLog?("IOHIDManagerOpen failed: \(Self.describe(opened))")
            }

            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 1.0, false)
            }
        }
        thread.name = "PenBridge.HID"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    public func stop() {
        thread?.cancel()
        if let runLoop { CFRunLoopWakeUp(runLoop) }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Closes and reopens every attached device so a change of open options applies
    /// without waiting for the tablet to be unplugged.
    private func reopenDevices() {
        for (_, tablet) in devices {
            let options = IOOptionBits(
                seizeDevice ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone
            )
            IOHIDDeviceClose(tablet.device, IOOptionBits(kIOHIDOptionsTypeNone))
            let result = IOHIDDeviceOpen(tablet.device, options)
            if result == kIOReturnSuccess {
                onLog?("reopened \(tablet.identifier)\(seizeDevice ? " (seized)" : "")")
            } else {
                onLog?("could not reopen \(tablet.identifier): \(Self.describe(result))")
            }
        }
    }

    // MARK: - Callback plumbing

    fileprivate func handleAttach(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        guard devices[key] == nil else { return }
        guard let tablet = TabletDevice(device: device) else {
            // Expected for the tablet's other HID interfaces: they carry vendor
            // collections with no pen report, and there is nothing to drive there.
            return
        }
        devices[key] = tablet

        let options = IOOptionBits(seizeDevice ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone)
        let result = IOHIDDeviceOpen(device, options)
        if result != kIOReturnSuccess {
            onLog?("IOHIDDeviceOpen failed for \(tablet.identifier): \(Self.describe(result))")
        } else {
            onLog?("opened \(tablet.identifier)\(seizeDevice ? " (seized)" : "")"
                + ", input buffer \(tablet.bufferSize) bytes")
        }
        IOHIDDeviceRegisterInputReportCallback(
            device,
            tablet.buffer,
            tablet.bufferSize,
            reportReceived,
            Unmanaged.passUnretained(self).toOpaque()
        )
        // Devices found through a scheduled manager are usually scheduled with it, but
        // input *report* callbacks only fire on a run loop the device itself is attached
        // to. Doing it explicitly costs nothing and removes a silent failure mode.
        if let runLoop {
            IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        }
        onAttach?(tablet)
    }

    fileprivate func handleDetach(_ device: IOHIDDevice) {
        guard let tablet = devices.removeValue(forKey: ObjectIdentifier(device)) else { return }
        if let runLoop {
            IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        }
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        onDetach?(tablet)
    }

    fileprivate func handleReport(
        _ device: IOHIDDevice, reportID: UInt32, buffer: UnsafeMutablePointer<UInt8>, length: Int
    ) {
        guard let tablet = devices[ObjectIdentifier(device)], length > 0 else { return }
        let raw = [UInt8](UnsafeBufferPointer(start: buffer, count: length))
        let (id, payload) = Self.normalize(raw, reportID: UInt8(truncatingIfNeeded: reportID))
        onReport?(tablet, id, payload)
    }

    /// macOS is inconsistent about whether the report-ID byte is included in the
    /// delivered buffer. When the first byte repeats the ID IOKit gave us separately,
    /// it is the prefix and gets stripped.
    static func normalize(_ raw: [UInt8], reportID: UInt8) -> (UInt8, [UInt8]) {
        if reportID != 0, let first = raw.first, first == reportID {
            return (reportID, Array(raw.dropFirst()))
        }
        return (reportID, raw)
    }

    /// Turns the common IOKit failures into something a user can act on.
    static func describe(_ result: IOReturn) -> String {
        switch result {
        case kIOReturnNotPermitted, kIOReturnNotPrivileged:
            return "not permitted — Input Monitoring is probably not granted to this program"
        case kIOReturnExclusiveAccess:
            return "exclusive access — another driver already owns the device"
        case kIOReturnNotOpen:
            return "device not open"
        case kIOReturnNoDevice:
            return "no such device"
        default:
            return String(format: "IOReturn 0x%08X", UInt32(bitPattern: result))
        }
    }
}

private func deviceAttached(
    _ context: UnsafeMutableRawPointer?, _ result: IOReturn,
    _ sender: UnsafeMutableRawPointer?, _ device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<TabletDeviceMonitor>.fromOpaque(context).takeUnretainedValue().handleAttach(device)
}

private func deviceDetached(
    _ context: UnsafeMutableRawPointer?, _ result: IOReturn,
    _ sender: UnsafeMutableRawPointer?, _ device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<TabletDeviceMonitor>.fromOpaque(context).takeUnretainedValue().handleDetach(device)
}

private func reportReceived(
    _ context: UnsafeMutableRawPointer?, _ result: IOReturn, _ sender: UnsafeMutableRawPointer?,
    _ type: IOHIDReportType, _ reportID: UInt32,
    _ report: UnsafeMutablePointer<UInt8>, _ reportLength: CFIndex
) {
    guard let context, let sender else { return }
    let monitor = Unmanaged<TabletDeviceMonitor>.fromOpaque(context).takeUnretainedValue()
    let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
    monitor.handleReport(device, reportID: reportID, buffer: report, length: reportLength)
}
