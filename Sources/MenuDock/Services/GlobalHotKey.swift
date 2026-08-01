import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut, registered with Carbon's `RegisterEventHotKey`.
///
/// ## Why Carbon, in 2026
///
/// This is the deprecated-looking API that is nonetheless the right one. The alternative —
/// `NSEvent.addGlobalMonitorForEvents` — requires Accessibility permission, because it is a
/// keylogger with a polite interface: it sees *every* keystroke in every app. `RegisterEventHotKey`
/// asks the window server to deliver one specific combination and nothing else, needs no
/// permission at all, and is what the shortcut recorder in every Mac app still uses. Apple has
/// never shipped a modern replacement.
///
/// The consequence for MenuDock is worth stating plainly: recalling the clipboard with ⌘⇧V works
/// out of the box, and only *auto-pasting* — synthesising a keystroke into another app — needs the
/// user to grant anything. See ``ClipboardPaster``.
@MainActor
final class GlobalHotKey {

    /// Fired on each press of the registered combination.
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private let identifier: UInt32

    /// Live hot keys by identifier, because the Carbon callback is a plain C function pointer
    /// with nowhere to hang an object reference.
    private static var registry: [UInt32: GlobalHotKey] = [:]
    private static var nextIdentifier: UInt32 = 1
    private static var handlerRef: EventHandlerRef?

    /// Four-character signature identifying this app's hot keys to the Carbon event system.
    private static let signature: OSType = 0x4D_44_4B_31  // 'MDK1'

    init() {
        identifier = Self.nextIdentifier
        Self.nextIdentifier += 1
    }

    isolated deinit {
        unregister()
    }

    // MARK: - Registration

    /// Registers the combination, replacing any previous one. Returns `false` if the system
    /// refused — almost always because another app already owns that shortcut.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        Self.installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else { return false }
        hotKeyRef = reference
        Self.registry[identifier] = self
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        Self.registry.removeValue(forKey: identifier)
    }

    var isRegistered: Bool { hotKeyRef != nil }

    // MARK: - Dispatch

    /// Installed once for the process. Carbon delivers every hot key through this one handler,
    /// which fans out by identifier.
    private static func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }

                // Carbon dispatches on the main run loop, so this is already the main actor —
                // and it has to stay that way. Hopping through a `Task` would put the panel's
                // appearance a run loop turn behind the keystroke, which is exactly the kind of
                // lag that makes a hold-to-cycle shortcut feel unreliable.
                MainActor.assumeIsolated {
                    GlobalHotKey.registry[hotKeyID.id]?.onPress?()
                }
                return noErr
            },
            1,
            &spec,
            nil,
            &handlerRef
        )
    }
}

// MARK: - Key codes

nonisolated extension GlobalHotKey {
    /// Virtual key code for `V`. A physical position, not a character, so this is the same key on
    /// a Dvorak or AZERTY layout — which is what a shortcut should be.
    static let keyV = UInt32(kVK_ANSI_V)

    static let commandShift = UInt32(cmdKey | shiftKey)

    /// How the combination is written in menus and settings.
    static let recallDisplayName = "⌘⇧V"
}
