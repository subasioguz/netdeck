import Darwin
import Foundation
import IOKit
import IOKit.serial

/// Raw 8N1 serial console (USB-serial adapters show up as /dev/cu.*).
public final class SerialTransport: Transport, @unchecked Sendable {
    public let path: String
    public let baud: Int
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "netdeck.serial.read")

    public init(path: String, baud: Int = 9600) {
        self.path = path
        self.baud = baud
    }

    public var displayName: String { "\(path) @ \(baud)" }

    /// Lists candidate serial devices (USB adapters first).
    public static func availablePorts() -> [String] {
        allPorts()
            .filter { !$0.contains("Bluetooth") && !$0.contains("debug-console") }
            .sorted { a, b in
                let au = a.contains("usb"), bu = b.contains("usb")
                return au != bu ? au : a < b
            }
    }

    /// USB serial adapters visible right now (nothing is opened).
    public static func usbAdapterPorts() -> [String] {
        usbAdapters(in: allPorts())
    }

    /// The USB-serial adapters among callout paths: FTDI/Prolific ("usbserial"), CDC-ACM ("usbmodem"),
    /// Silicon Labs CP210x ("SLAB_USBtoUART") and WCH CH34x ("wchusbserial").
    public static func usbAdapters(in paths: [String]) -> [String] {
        let prefixes = ["cu.usbserial", "cu.usbmodem", "cu.SLAB", "cu.wchusbserial"]
        return paths.filter { p in prefixes.contains { (p as NSString).lastPathComponent.hasPrefix($0) } }.sorted()
    }

    /// Callout devices (/dev/cu.*) from the IOKit registry, which the App Sandbox allows, plus a /dev
    /// listing where that is readable.
    static func allPorts() -> [String] {
        let fromDev = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.") }.map { "/dev/" + $0 }
        return Array(Set((ioKitPorts() ?? []) + fromDev))
    }

    /// `kIOCalloutDeviceKey` of every `IOSerialBSDClient`. Nil when the registry can't be queried.
    static func ioKitPorts() -> [String]? {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var paths: [String] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            let value = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)
            if let path = value?.takeRetainedValue() as? String { paths.append(path) }
        }
        return paths
    }

    public func open(
        onData: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (String?) -> Void
    ) throws {
        lock.lock(); defer { lock.unlock() }
        guard fd < 0 else { return }
        let f = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else { throw TransportError.openFailed(Self.errnoText()) }
        if ioctl(f, TIOCEXCL) != 0 {
            Darwin.close(f)
            throw TransportError.openFailed(t("The port is in use by another app."))
        }
        var tio = termios()
        guard tcgetattr(f, &tio) == 0 else {
            Darwin.close(f)
            throw TransportError.openFailed(Self.errnoText())
        }
        cfmakeraw(&tio)
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tio.c_cflag &= ~tcflag_t(CSIZE | PARENB | CSTOPB | CRTSCTS)
        tio.c_cflag |= tcflag_t(CS8)
        cfsetspeed(&tio, speed_t(baud))
        guard tcsetattr(f, TCSANOW, &tio) == 0 else {
            Darwin.close(f)
            throw TransportError.openFailed(Self.errnoText())
        }
        tcflush(f, TCIOFLUSH)
        fd = f

        let src = DispatchSource.makeReadSource(fileDescriptor: f, queue: queue)
        src.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(f, &buf, buf.count)
            if n > 0 {
                onData(Data(buf[0..<n]))
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                let reason = n == 0 ? t("The serial connection closed.") : Self.errnoText()
                self?.close()
                onClose(reason)
            }
        }
        src.setCancelHandler { Darwin.close(f) }
        source = src
        src.resume()
    }

    public func send(_ data: Data) throws {
        lock.lock(); let f = fd; lock.unlock()
        guard f >= 0 else { throw TransportError.notOpen }
        try data.withUnsafeBytes { raw in
            guard var p = raw.baseAddress else { return }
            var remaining = raw.count
            var stalls = 0
            while remaining > 0 {
                let n = Darwin.write(f, p, remaining)
                if n > 0 {
                    p += n
                    remaining -= n
                    stalls = 0
                } else if errno == EAGAIN || errno == EINTR {
                    stalls += 1
                    if stalls > 500 { throw TransportError.writeFailed(t("Timed out")) }
                    usleep(2_000)
                } else {
                    throw TransportError.writeFailed(Self.errnoText())
                }
            }
        }
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { return }
        source?.cancel()
        source = nil
        fd = -1
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }
}
