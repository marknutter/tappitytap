import Foundation
import Carbon
import AppKit

// Carbon-based global hotkey. Unlike NSEvent.addGlobalMonitorForEvents, this
// path doesn't require the Accessibility permission — it goes through the
// HIToolbox hotkey registry, which any app can use for fixed-shortcut bindings.
//
// The handler closure is captured here; the Carbon C callback gets a pointer
// to `self` and fans out to it.

final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let callback: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback

        let signature: OSType = 0x54415054     // 'TAPT'
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, _, userData) -> OSStatus in
                guard let userData else { return noErr }
                let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { me.callback() }
                return noErr
            },
            1, &eventType, selfPtr, &handlerRef
        )

        RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetEventDispatcherTarget(), 0, &hotKeyRef
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
