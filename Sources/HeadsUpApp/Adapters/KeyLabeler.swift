import Carbon.HIToolbox
import HeadsUpCore

/// Keycap labels from the current keyboard layout, so ⌥Q reads ⌥A on a French keyboard.
/// It calls `onChange` when the user switches input source.
@MainActor
final class KeyLabeler {
    private var observer: NSObjectProtocol?

    init(onChange: @escaping @MainActor () -> Void) {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }

    /// The label for `keyCode`: a name for keys that type no character, else the character
    /// the current layout types for it, in capitals.
    func label(for keyCode: UInt32) -> String {
        if let name = KeyNames.name(keyCode) { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "?" }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buffer -> String in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return "?" }
            var deadKeys: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return "?" }
            return String(utf16CodeUnits: characters, count: length).uppercased()
        }
    }
}
