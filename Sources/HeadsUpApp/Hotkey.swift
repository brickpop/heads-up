import Carbon.HIToolbox

/// A system-wide shortcut, registered with Carbon's `RegisterEventHotKey`.
/// It needs no Accessibility permission, and it reports whether registration
/// worked: `eventHotKeyExistsErr` when the shortcut is already registered. Whether
/// that also comes back when another app holds it is checked on the Mac in slice 1.
///
/// One `Hotkey` lives as long as the app, so it never unregisters (slice 1 adds teardown).
@MainActor
final class Hotkey {
    struct RegistrationError: Error {
        let status: OSStatus
    }

    /// "HUUP": tells our hotkey events apart from other Carbon events.
    private static let signature: OSType = 0x4855_5550

    private let action: @MainActor () -> Void
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    /// Registers the shortcut, or throws with Carbon's status.
    /// `keyCode` is a virtual key code (`kVK_…`), `modifiers` Carbon flags (`optionKey`, `cmdKey`…).
    init(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) throws(RegistrationError) {
        self.action = action

        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotkey = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers application events on the main thread.
                MainActor.assumeIsolated { hotkey.action() }
                return noErr
            },
            1,
            &pressed,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard status == noErr else { throw RegistrationError(status: status) }

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr else {
            RemoveEventHandler(handler)
            throw RegistrationError(status: status)
        }
    }
}
