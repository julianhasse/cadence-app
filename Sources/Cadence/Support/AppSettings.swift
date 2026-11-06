import AppKit
import Combine

extension Notification.Name {
    static let settingsChanged = Notification.Name("CadenceSettingsChanged")
}

enum PlayerPreference: String, CaseIterable, Identifiable {
    case automatic, music, spotify
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .music: return "Apple Music"
        case .spotify: return "Spotify"
        }
    }
    var kind: PlayerKind? {
        switch self {
        case .automatic: return nil
        case .music: return .music
        case .spotify: return .spotify
        }
    }
}

enum PlayerTheme: String, CaseIterable, Identifiable {
    case cover, card, strip
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cover: return "Cover"
        case .card: return "Card"
        case .strip: return "Strip"
        }
    }
}

enum PlayerSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scale: CGFloat {
        switch self {
        case .small: return 0.8
        case .medium: return 1.0
        case .large: return 1.3
        }
    }
}

enum TimeDisplay: String, CaseIterable, Identifiable {
    case elapsed, remaining
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum ControlsVisibility: String, CaseIterable, Identifiable {
    case hover, always
    var id: String { rawValue }
    var title: String { self == .hover ? "On hover" : "Always" }
}

/// UserDefaults-backed settings. Every write publishes `objectWillChange` and posts `.settingsChanged`.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    private func value<T>(_ key: String, _ fallback: T) -> T {
        defaults.object(forKey: key) as? T ?? fallback
    }

    private func store(_ key: String, _ value: Any?) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .settingsChanged, object: key)
    }

    private func enumValue<E: RawRepresentable>(_ key: String, _ fallback: E) -> E where E.RawValue == String {
        E(rawValue: value(key, fallback.rawValue)) ?? fallback
    }

    // MARK: General
    var playerPreference: PlayerPreference {
        get { enumValue("playerPreference", .automatic) }
        set { store("playerPreference", newValue.rawValue) }
    }
    var showDockIcon: Bool { get { value("showDockIcon", false) } set { store("showDockIcon", newValue) } }
    var showMenuBarIcon: Bool { get { value("showMenuBarIcon", true) } set { store("showMenuBarIcon", newValue) } }
    var showTitleInMenuBar: Bool { get { value("showTitleInMenuBar", false) } set { store("showTitleInMenuBar", newValue) } }
    var menuBarTitleLength: Int { get { value("menuBarTitleLength", 40) } set { store("menuBarTitleLength", newValue) } }

    // MARK: Mini player
    var miniPlayerVisible: Bool { get { value("miniPlayerVisible", true) } set { store("miniPlayerVisible", newValue) } }
    var hideWhenNoPlayer: Bool { get { value("hideWhenNoPlayer", false) } set { store("hideWhenNoPlayer", newValue) } }
    var alwaysOnTop: Bool { get { value("alwaysOnTop", true) } set { store("alwaysOnTop", newValue) } }
    var showOnAllSpaces: Bool { get { value("showOnAllSpaces", true) } set { store("showOnAllSpaces", newValue) } }
    var lockPosition: Bool { get { value("lockPosition", false) } set { store("lockPosition", newValue) } }

    // MARK: Appearance
    var theme: PlayerTheme { get { enumValue("theme", .card) } set { store("theme", newValue.rawValue) } }
    var playerSize: PlayerSize { get { enumValue("playerSize", .medium) } set { store("playerSize", newValue.rawValue) } }
    var timeDisplay: TimeDisplay { get { enumValue("timeDisplay", .elapsed) } set { store("timeDisplay", newValue.rawValue) } }
    var controlsVisibility: ControlsVisibility {
        get { enumValue("controlsVisibility", .hover) }
        set { store("controlsVisibility", newValue.rawValue) }
    }
    var showVolumeSlider: Bool { get { value("showVolumeSlider", true) } set { store("showVolumeSlider", newValue) } }
    var opacity: Double { get { value("opacity", 1.0) } set { store("opacity", newValue) } }
    var useArtworkColor: Bool { get { value("useArtworkColor", true) } set { store("useArtworkColor", newValue) } }
    var accentHex: String { get { value("accentHex", "#FF2D55") } set { store("accentHex", newValue) } }
    var accentColor: NSColor {
        get { NSColor(hex: accentHex) ?? .systemPink }
        set { accentHex = newValue.hexString }
    }

    // MARK: Notifications
    var notificationsEnabled: Bool { get { value("notificationsEnabled", false) } set { store("notificationsEnabled", newValue) } }
    var notifyOnlyInBackground: Bool {
        get { value("notifyOnlyInBackground", true) }
        set { store("notifyOnlyInBackground", newValue) }
    }

    // MARK: Last.fm
    var scrobblingEnabled: Bool { get { value("scrobblingEnabled", true) } set { store("scrobblingEnabled", newValue) } }
    var sendNowPlaying: Bool { get { value("sendNowPlaying", true) } set { store("sendNowPlaying", newValue) } }
    /// Fraction of a track that must play before it is scrobbled (Last.fm minimum is 0.5, capped at 4 minutes).
    var scrobbleThreshold: Double { get { value("scrobbleThreshold", 0.5) } set { store("scrobbleThreshold", newValue) } }
    var lastfmAPIKey: String {
        get { value("lastfmAPIKey", "").trimmed }
        set { store("lastfmAPIKey", newValue.trimmed) }
    }
    var lastfmUsername: String { get { value("lastfmUsername", "") } set { store("lastfmUsername", newValue) } }
    /// The shared secret lives in the Keychain, not UserDefaults.
    var lastfmAPISecret: String {
        get { (Keychain.get(account: "lastfm.secret") ?? "").trimmed }
        set { objectWillChange.send(); Keychain.set(newValue.trimmed, account: "lastfm.secret") }
    }

    // MARK: Spotify Web API (search)
    var spotifyClientID: String {
        get { value("spotifyClientID", "").trimmed }
        set { store("spotifyClientID", newValue.trimmed) }
    }
    var spotifyClientSecret: String {
        get { (Keychain.get(account: "spotify.secret") ?? "").trimmed }
        set { objectWillChange.send(); Keychain.set(newValue.trimmed, account: "spotify.secret") }
    }

    // MARK: Shortcuts
    func shortcut(for action: ShortcutAction) -> Shortcut? {
        guard let data = defaults.data(forKey: "shortcut.\(action.rawValue)") else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) {
        store("shortcut.\(action.rawValue)", shortcut.flatMap { try? JSONEncoder().encode($0) })
    }
}

extension String {
    /// Credentials copied from web dashboards often carry stray spaces or line breaks.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
