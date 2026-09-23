import Carbon.HIToolbox
import Foundation

/// System-wide shortcuts that work while another app is frontmost.
///
/// Hardware media keys are already handled by `NowPlaying`; these cover keyboards that
/// have no media row. The modifier combination is deliberately obscure so it does not
/// collide with anything else the user has bound.
@MainActor
enum GlobalHotkeys {
    private static var refs: [EventHotKeyRef] = []

    private enum Action: UInt32 {
        case playPause = 1, next = 2, previous = 3
    }

    /// ⌃⌥⌘Space, ⌃⌥⌘→, ⌃⌥⌘←
    static func install() {
        guard AppSettings.shared.globalShortcuts else { return }
        registerAll()
    }

    /// Turned on and off from Settings.
    static func setEnabled(_ enabled: Bool) {
        if enabled {
            registerAll()
        } else {
            refs.forEach { UnregisterEventHotKey($0) }
            refs.removeAll()
        }
    }

    private static var handlerInstalled = false

    private static func registerAll() {
        guard refs.isEmpty else { return }
        installHandler()
        register(kVK_Space, .playPause)
        register(kVK_RightArrow, .next)
        register(kVK_LeftArrow, .previous)
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            // Carbon delivers hot keys on the main thread.
            MainActor.assumeIsolated { GlobalHotkeys.perform(id.id) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private static func register(_ keyCode: Int, _ action: Action) {
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let id = EventHotKeyID(signature: OSType(0x59544D4B), id: action.rawValue)  // 'YTMK'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
        } else {
            Log.write("hotkey \(action) not registered (status \(status)) — probably already taken")
        }
    }

    private static func perform(_ raw: UInt32) {
        let player = PlayerController.shared
        switch Action(rawValue: raw) {
        case .playPause: player.toggle()
        case .next: player.next()
        case .previous: player.previous()
        case nil: break
        }
    }
}
