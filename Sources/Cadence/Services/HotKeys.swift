import AppKit
import Carbon.HIToolbox

enum ShortcutAction: String, CaseIterable, Identifiable {
    case playPause, next, previous, toggleMiniPlayer, love, showSong, searchSpotify
    var id: String { rawValue }
    var hotKeyID: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }
    var title: String {
        switch self {
        case .playPause: return "Play / Pause"
        case .next: return "Next track"
        case .previous: return "Previous track"
        case .toggleMiniPlayer: return "Show / hide mini player"
        case .love: return "Love current track"
        case .showSong: return "Show song notification"
        case .searchSpotify: return "Search Spotify"
        }
    }
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// `NSEvent.ModifierFlags` raw value (device-independent subset).
    var modifiers: UInt
    var keyLabel: String

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifierFlags.contains(.command) { m |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { m |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { m |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    var displayString: String {
        var s = ""
        if modifierFlags.contains(.control) { s += "⌃" }
        if modifierFlags.contains(.option) { s += "⌥" }
        if modifierFlags.contains(.shift) { s += "⇧" }
        if modifierFlags.contains(.command) { s += "⌘" }
        return s + keyLabel
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue
        keyLabel = Self.label(for: event)
    }

    private static func label(for event: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
            kVK_F11: "F11", kVK_F12: "F12", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        if let s = special[Int(event.keyCode)] { return s }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

/// Global hotkeys via Carbon `RegisterEventHotKey` (works without Accessibility permission).
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    fileprivate var handlers: [UInt32: () -> Void] = [:]
    private var installed = false
    private let signature: OSType = 0x43_44_4E_43 // "CDNC"

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr else { return status }
            let id = hotKey.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.shared.handlers[id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(_ action: ShortcutAction, _ shortcut: Shortcut?, handler: @escaping () -> Void) {
        unregister(action)
        guard let shortcut else { return }
        installIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: action.hotKeyID)
        if RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr,
           let ref {
            refs[action.hotKeyID] = ref
            handlers[action.hotKeyID] = handler
        }
    }

    func unregister(_ action: ShortcutAction) {
        if let ref = refs.removeValue(forKey: action.hotKeyID) { UnregisterEventHotKey(ref) }
        handlers[action.hotKeyID] = nil
    }
}
