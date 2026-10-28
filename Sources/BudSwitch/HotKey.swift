import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Carbon hot keys don't need Accessibility permission.
@MainActor
final class HotKey {
    private let action: () -> Void
    private var hotKey: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            MainActor.assumeIsolated {
                Unmanaged<HotKey>.fromOpaque(context!).takeUnretainedValue().action()
            }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), nil)
        RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x4264_5377), id: 1),  // "BdSw"
            GetApplicationEventTarget(), 0, &hotKey)
    }
}
