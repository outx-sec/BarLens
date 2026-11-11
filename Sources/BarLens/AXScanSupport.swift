import ApplicationServices
import Foundation

/// Shared by the main-thread operation owner and its background AX reader.
final class AXScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

enum AXScanFailure: Error, Equatable {
    case cancelled
    case timedOut
    case permissionDenied
    case unavailable
    case readFailed(Int32)

    var description: String {
        switch self {
        case .cancelled: return tr("扫描已取消。", "Scan cancelled.")
        case .timedOut: return tr("菜单栏读取超时，请稍后重试。", "Menu bar read timed out; please try again.")
        case .permissionDenied: return tr("需要辅助功能权限才能读取菜单栏。", "Accessibility permission is required to read the menu bar.")
        case .unavailable: return tr("菜单栏尚未准备好，请稍后重试。", "Menu bar is not ready yet; please try again.")
        case .readFailed(let code): return tr("暂时无法读取菜单栏（\(code)）。", "Unable to read the menu bar (\(code)).")
        }
    }
}

/// A monotonic deadline bounds the whole sweep, including its optional labels.
/// The AX timeout is set for every element, since descendant elements do not
/// inherit the application element's timeout.
final class AXReadBudget {
    private let deadline: TimeInterval
    private let now: () -> TimeInterval
    private let cancellation: AXScanCancellation

    init(seconds: TimeInterval, cancellation: AXScanCancellation,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        self.deadline = now() + seconds
        self.cancellation = cancellation
    }

    var failure: AXScanFailure? {
        if cancellation.isCancelled { return .cancelled }
        return now() >= deadline ? .timedOut : nil
    }

    func check() throws {
        if let failure { throw failure }
    }

    var nextCallTimeout: Float { Float(max(0.001, min(0.15, deadline - now()))) }

    func attribute(_ element: AXUIElement, _ name: String,
                   optional: Bool = false) throws -> CFTypeRef? {
        try check()
        AXUIElementSetMessagingTimeout(element, nextCallTimeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        try check()
        if error == .success { return value }
        if optional && (error == .noValue || error == .attributeUnsupported) { return nil }
        throw AXScanFailure.readFailed(error.rawValue)
    }

    func element(_ parent: AXUIElement, _ attribute: String) throws -> AXUIElement {
        guard let value = try self.attribute(parent, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { throw AXScanFailure.unavailable }
        return value as! AXUIElement
    }

    func children(_ element: AXUIElement) throws -> [AXUIElement] {
        guard let value = try attribute(element, kAXChildrenAttribute as String),
              let children = value as? [AXUIElement] else { throw AXScanFailure.unavailable }
        return children
    }

    func string(_ element: AXUIElement, _ name: String) throws -> String? {
        try attribute(element, name, optional: true) as? String
    }

    func bool(_ element: AXUIElement, _ name: String) throws -> Bool? {
        guard let raw = try attribute(element, name, optional: true) else { return nil }
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        return nil
    }

    func int(_ element: AXUIElement, _ name: String) throws -> Int? {
        guard let raw = try attribute(element, name, optional: true) else { return nil }
        if let i = raw as? Int { return i }
        if let n = raw as? NSNumber { return n.intValue }
        return nil
    }

    /// Optional labels do not determine whether an item exists. Unlike a
    /// failed geometry/tree read, missing metadata must not discard its owner.
    /// Cancellation and the sweep deadline still stop all further work.
    static func optionalValue<T>(_ read: () throws -> T?) throws -> T? {
        do { return try read() }
        catch AXScanFailure.cancelled { throw AXScanFailure.cancelled }
        catch AXScanFailure.timedOut { throw AXScanFailure.timedOut }
        catch { return nil }
    }

    static func optionalMetadata(_ read: () throws -> String?) throws -> String? {
        try optionalValue(read)
    }
}

/// All AX work runs off the main queue, and canceled generations cannot deliver
/// callbacks. This also gives tests a way to simulate a slow third-party app.
final class AXScanWorker {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func perform<Value>(cancellation: AXScanCancellation,
                        work: @escaping () -> Value,
                        completion: @escaping (Value) -> Void) {
        queue.async {
            guard !cancellation.isCancelled else { return }
            let result = work()
            DispatchQueue.main.async {
                guard !cancellation.isCancelled else { return }
                completion(result)
            }
        }
    }
}
