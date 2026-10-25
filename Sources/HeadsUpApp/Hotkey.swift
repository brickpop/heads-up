import Carbon.HIToolbox
import HeadsUpCore

/// The wake shortcut, registered with Carbon's `RegisterEventHotKey`. It needs no
/// Accessibility permission, and it reports whether registration worked:
/// `eventHotKeyExistsErr` when the shortcut is already registered. Whether that also
/// comes back when another app holds it is the slice 1 CEO check.
///
/// One application event handler serves every registration and dispatches by
/// `EventHotKeyID`, so re-recording the shortcut never stacks handlers, and a press of a
/// shortcut that was replaced does nothing. A new shortcut is registered before the old
/// one is released, so a failure leaves the old one working.
@MainActor
final class CarbonHotkeyRegistrar: HotkeyRegistrar {
    /// "HUUP": tells our hotkey events apart from other Carbon events.
    nonisolated private static let signature: OSType = 0x4855_5550

    private struct Registration {
        let id: UInt32
        let shortcut: Shortcut
        let ref: EventHotKeyRef
        var pressed: @MainActor () -> Void
    }

    private var handler: EventHandlerRef?
    private var current: Registration?
    private var lastID: UInt32 = 0

    func register(_ shortcut: Shortcut, pressed: @escaping @MainActor () -> Void) -> HotkeyStatus {
        // The same keys again (Try Again): keep the registration, take the new action.
        if current?.shortcut == shortcut {
            current?.pressed = pressed
            return .ok(shortcut)
        }
        let installed = installHandler()
        guard installed == noErr else { return .failed(installed) }

        lastID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode, Self.carbonModifiers(shortcut.modifiers),
            EventHotKeyID(signature: Self.signature, id: lastID), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            return status == OSStatus(eventHotKeyExistsErr) ? .taken : .failed(status)
        }
        if let old = current {
            UnregisterEventHotKey(old.ref)
        }
        current = Registration(id: lastID, shortcut: shortcut, ref: ref, pressed: pressed)
        return .ok(shortcut)
    }

    /// Releases the shortcut and the event handler. The app calls it when it quits.
    func invalidate() {
        if let current { UnregisterEventHotKey(current.ref) }
        current = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func dispatch(_ id: UInt32) {
        guard let current, current.id == id else { return }
        current.pressed()
    }

    /// Installs the one event handler for hotkey presses, the first time only.
    private func installHandler() -> OSStatus {
        guard handler == nil else { return noErr }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let read = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard read == noErr, hotKeyID.signature == CarbonHotkeyRegistrar.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let registrar = Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers application events on the main thread.
                MainActor.assumeIsolated { registrar.dispatch(hotKeyID.id) }
                return noErr
            },
            1,
            &spec,
            // The registrar lives until invalidate() removes this handler, so an unretained pointer is safe.
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }

    private static func carbonModifiers(_ modifiers: Shortcut.Modifiers) -> UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        return UInt32(flags)
    }
}
