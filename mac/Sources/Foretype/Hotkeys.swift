import Carbon

/// Global hotkeys through Carbon's RegisterEventHotKey: no event tap has to stay active, and
/// the system routes the key to us even when another app is frontmost.
///   Ctrl + key above Tab           suggest here even where Foretype normally stays quiet
///   Ctrl+Opt+Cmd + key above Tab   snooze suggestions in the current app for 5 minutes
final class Hotkeys {
    enum Action: UInt32 {
        case forceSuggest = 1
        case snoozeApp = 2
    }

    /// Main thread.
    var onAction: ((Action) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    func register(keyAboveTab: UInt32) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
            if let action = Action(rawValue: id.id) { hotkeys.onAction?(action) }
            return noErr
        }, 1, &spec, me, &handler)
        add(keyAboveTab, modifiers: UInt32(controlKey), action: .forceSuggest)
        add(keyAboveTab, modifiers: UInt32(controlKey | optionKey | cmdKey), action: .snoozeApp)
    }

    private func add(_ key: UInt32, modifiers: UInt32, action: Action) {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4654_5950), id: action.rawValue) // "FTYP"
        if RegisterEventHotKey(key, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
        } else {
            Log.debug("hotkey \(action) could not be registered (taken by another app?)")
        }
    }
}
