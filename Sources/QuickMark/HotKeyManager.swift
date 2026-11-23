import Carbon.HIToolbox
import Foundation

/// Global hotkey via Carbon's RegisterEventHotKey.
/// Does not need Accessibility permission.
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void
    private(set) var isRegistered = false

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in manager.action() }
            return noErr
        }, 1, &eventType, userData, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x514D_524B), id: 1) // 'QMRK'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        isRegistered = (status == noErr)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
