import Carbon.HIToolbox
import Foundation

/// 全局快捷键 ⌥Space，基于 Carbon RegisterEventHotKey（沙盒兼容、零依赖）。
/// 可变状态仅在主线程（注册/注销）与 Carbon 回调（主线程事件循环）访问。
final class HotKeyManager: @unchecked Sendable {
    private let handler: @MainActor @Sendable () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init(handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
    }

    @discardableResult
    func register() -> Bool {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, refcon -> OSStatus in
                guard let refcon else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.handleHotKey()
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard installStatus == noErr else { return false }

        // 签名 'BBBD'
        let hotKeyID = EventHotKeyID(signature: 0x4242_4244, id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return registerStatus == noErr
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private func handleHotKey() {
        let handler = self.handler
        Task { @MainActor in handler() }
    }

    deinit {
        unregister()
    }
}
