import Foundation

extension Notification.Name {
    static let iosDeviceListChanged = Notification.Name("BettaryIOSDeviceListChanged")
}

private func amDeviceNotification(_ info: UnsafeMutableRawPointer?, _ context: UnsafeMutableRawPointer?) {
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .iosDeviceListChanged, object: nil)
    }
}

/// Thin binding to the system's MobileDevice framework — the same channel
/// Finder uses to talk to a connected iPhone or iPad. It is loaded at run time
/// so the app still launches if the framework is missing or changes.
final class MobileDeviceLib {
    static let shared = MobileDeviceLib()

    typealias Dev = UnsafeMutableRawPointer
    typealias Conn = UnsafeMutableRawPointer
    typealias NotifyCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

    let createDeviceList: @convention(c) () -> Unmanaged<CFArray>?
    let connect: @convention(c) (Dev) -> Int32
    let disconnect: @convention(c) (Dev) -> Int32
    let isPaired: @convention(c) (Dev) -> Int32
    let validatePairing: @convention(c) (Dev) -> Int32
    let startSession: @convention(c) (Dev) -> Int32
    let stopSession: @convention(c) (Dev) -> Int32
    let copyIdentifier: @convention(c) (Dev) -> Unmanaged<CFString>?
    let copyValue: @convention(c) (Dev, CFString?, CFString?) -> Unmanaged<AnyObject>?
    let interfaceType: @convention(c) (Dev) -> Int32
    let startService: @convention(c) (Dev, CFString, CFDictionary?, UnsafeMutablePointer<Conn?>) -> Int32
    let send: @convention(c) (Conn, UnsafeRawPointer, Int) -> Int
    let receive: @convention(c) (Conn, UnsafeMutableRawPointer, Int) -> Int
    let invalidate: @convention(c) (Conn) -> Void
    let pair: (@convention(c) (Dev) -> Int32)?
    private let subscribe: (@convention(c) (NotifyCallback, UInt32, UInt32, UnsafeMutableRawPointer?,
                                             UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32)?
    private var subscription: UnsafeMutableRawPointer?

    private init?() {
        let paths = [
            "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",
            "/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",
        ]
        var handle: UnsafeMutableRawPointer?
        for p in paths where handle == nil { handle = dlopen(p, RTLD_NOW) }
        guard let h = handle else { return nil }
        func sym<T>(_ name: String) -> T? {
            dlsym(h, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard
            let createDeviceList: @convention(c) () -> Unmanaged<CFArray>? = sym("AMDCreateDeviceList"),
            let connect: @convention(c) (Dev) -> Int32 = sym("AMDeviceConnect"),
            let disconnect: @convention(c) (Dev) -> Int32 = sym("AMDeviceDisconnect"),
            let isPaired: @convention(c) (Dev) -> Int32 = sym("AMDeviceIsPaired"),
            let validatePairing: @convention(c) (Dev) -> Int32 = sym("AMDeviceValidatePairing"),
            let startSession: @convention(c) (Dev) -> Int32 = sym("AMDeviceStartSession"),
            let stopSession: @convention(c) (Dev) -> Int32 = sym("AMDeviceStopSession"),
            let copyIdentifier: @convention(c) (Dev) -> Unmanaged<CFString>? = sym("AMDeviceCopyDeviceIdentifier"),
            let copyValue: @convention(c) (Dev, CFString?, CFString?) -> Unmanaged<AnyObject>? = sym("AMDeviceCopyValue"),
            let interfaceType: @convention(c) (Dev) -> Int32 = sym("AMDeviceGetInterfaceType"),
            let startService: @convention(c) (Dev, CFString, CFDictionary?, UnsafeMutablePointer<Conn?>) -> Int32
                = sym("AMDeviceSecureStartService"),
            let send: @convention(c) (Conn, UnsafeRawPointer, Int) -> Int = sym("AMDServiceConnectionSend"),
            let receive: @convention(c) (Conn, UnsafeMutableRawPointer, Int) -> Int = sym("AMDServiceConnectionReceive"),
            let invalidate: @convention(c) (Conn) -> Void = sym("AMDServiceConnectionInvalidate")
        else { return nil }
        self.createDeviceList = createDeviceList
        self.connect = connect
        self.disconnect = disconnect
        self.isPaired = isPaired
        self.validatePairing = validatePairing
        self.startSession = startSession
        self.stopSession = stopSession
        self.copyIdentifier = copyIdentifier
        self.copyValue = copyValue
        self.interfaceType = interfaceType
        self.startService = startService
        self.send = send
        self.receive = receive
        self.invalidate = invalidate
        self.pair = sym("AMDevicePair")
        self.subscribe = sym("AMDeviceNotificationSubscribe")
    }

    /// Posts `.iosDeviceListChanged` on attach/detach. Call once from the main thread.
    func startNotifications() {
        guard subscription == nil, let subscribe else { return }
        _ = subscribe(amDeviceNotification, 0, 0, nil, &subscription)
    }

    func string(_ dev: Dev, domain: String? = nil, key: String) -> String? {
        copyValue(dev, domain as CFString?, key as CFString)?.takeRetainedValue() as? String
    }

    func dictionary(_ dev: Dev, domain: String) -> [String: Any]? {
        copyValue(dev, domain as CFString, nil)?.takeRetainedValue() as? [String: Any]
    }

    /// One length-prefixed property-list round trip on a lockdown service.
    func request(_ conn: Conn, _ dict: [String: Any]) -> [String: Any]? {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else {
            return nil
        }
        var len = UInt32(data.count).bigEndian
        let sentHeader = withUnsafeBytes(of: &len) { send(conn, $0.baseAddress!, 4) }
        let sentBody = data.withUnsafeBytes { send(conn, $0.baseAddress!, data.count) }
        guard sentHeader == 4, sentBody == data.count else { return nil }

        func read(_ n: Int) -> Data? {
            var buf = Data(count: n)
            var got = 0
            while got < n {
                let r = buf.withUnsafeMutableBytes { receive(conn, $0.baseAddress! + got, n - got) }
                if r <= 0 { return nil }
                got += r
            }
            return buf
        }
        guard let header = read(4) else { return nil }
        let size = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard size > 0, size < 32 << 20, let body = read(size) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: body, options: [], format: nil)) as? [String: Any]
    }
}
