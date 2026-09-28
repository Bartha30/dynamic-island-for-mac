//
//  GlobalHotKey.swift
//  Dynamic Island for MAC
//

import Carbon.HIToolbox

/// A keyboard shortcut that works no matter which app is in front.
///
/// Uses Carbon's hot-key API rather than watching every key press, because
/// watching the keyboard needs Accessibility permission and this does not.
nonisolated final class GlobalHotKey {
    private let action: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// `keyCode` is a `kVK_…` constant; `modifiers` combines `cmdKey`,
    /// `optionKey`, `controlKey` and `shiftKey`. Returns nil if another app
    /// already owns the same shortcut.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()

        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers hot keys on the main thread.
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            },
            1,
            &eventType,
            context,
            &handlerRef
        )
        guard installed == noErr else { return nil }

        // 'DILY' — any four characters unique to this app.
        let id = EventHotKeyID(signature: OSType(0x4449_4C59), id: 1)
        let registered = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
