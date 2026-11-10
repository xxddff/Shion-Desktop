import AppKit
import Carbon.HIToolbox

/// The ⌥Space window's shortcut, registered with the system by Shion itself, exclusively
/// (`kEventHotKeyExclusive`). Registered the usual, shared way, a combination another app holds
/// exclusively is accepted all the same and then never delivered; exclusively, it is refused
/// (`eventHotKeyExistsErr`), so Settings can say the shortcut is taken, and an app that holds it
/// shared does not take the key away from Shion. KeyboardShortcuts registers shared and does not
/// say when a registration fails, so only its recorder is used (ShortcutSettings.swift).
///
/// What cannot be seen from here: an app that takes the keys before the system's hot keys (an
/// event tap, as some launchers use) leaves the registration standing and the key never comes.
final class GlobalHotKey {
    enum State: Equatable {
        /// Not registered: no shortcut, a screenshot run, or Settings recording a new one.
        case off
        case registered
        /// Another app holds the combination.
        case taken
        case failed(Int32)
    }

    private(set) var state: State = .off
    private let pressed: () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Tells this registration's presses from any other in the process.
    nonisolated static let signature: OSType = 0x5148_4B59

    init(pressed: @escaping () -> Void) {
        self.pressed = pressed
    }

    /// Registers `keyCode` with `modifiers` (Carbon's values, as KeyboardShortcuts keeps them)
    /// in place of whatever was registered before.
    @discardableResult
    func register(keyCode: Int, modifiers: Int) -> State {
        unregister()
        installHandler()
        var registered: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            EventHotKeyID(signature: Self.signature, id: 1),
            GetEventDispatcherTarget(),
            OptionBits(kEventHotKeyExclusive),
            &registered
        )
        if status == OSStatus(noErr), let registered {
            hotKey = registered
            state = .registered
        } else if status == OSStatus(eventHotKeyExistsErr) {
            state = .taken
        } else {
            state = .failed(status)
        }
        return state
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        hotKey = nil
        state = .off
    }

    fileprivate func firePressed() {
        pressed()
    }

    private func installHandler() {
        guard handler == nil, let dispatcher = GetEventDispatcherTarget() else { return }
        var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var installed: EventHandlerRef?
        let status = InstallEventHandler(dispatcher, globalHotKeyEvent, 1, &kind, Unmanaged.passUnretained(self).toOpaque(), &installed)
        if status == OSStatus(noErr) {
            handler = installed
        }
    }
}

/// Carbon's callback for a pressed hot key: ours by its signature, on the main thread, where
/// Carbon delivers its events.
nonisolated private func globalHotKeyEvent(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData, Thread.isMainThread else {
        return OSStatus(eventNotHandledErr)
    }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &id
    )
    guard status == OSStatus(noErr), id.signature == GlobalHotKey.signature else {
        return OSStatus(eventNotHandledErr)
    }
    let address = UInt(bitPattern: userData)
    MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        Unmanaged<GlobalHotKey>.fromOpaque(pointer).takeUnretainedValue().firePressed()
    }
    return OSStatus(noErr)
}
