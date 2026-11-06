import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController {
    init() {
        let hosting = NSHostingController(rootView: PreferencesView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Cadence Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 460))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPane().tabItem { Label("General", systemImage: "gearshape") }
            AppearancePane().tabItem { Label("Appearance", systemImage: "paintpalette") }
            NotificationsPane().tabItem { Label("Notifications", systemImage: "bell") }
            SpotifyPane().tabItem { Label("Spotify", systemImage: "magnifyingglass") }
            LastFMPane().tabItem { Label("Last.fm", systemImage: "dot.radiowaves.left.and.right") }
            ShortcutsPane().tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject private var s = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Show Dock icon", isOn: $s.showDockIcon)
                    .disabled(!s.showMenuBarIcon)
                Toggle("Show menu bar icon", isOn: $s.showMenuBarIcon)
                    .disabled(!s.showDockIcon)
                Toggle("Show song title in menu bar", isOn: $s.showTitleInMenuBar)
                    .disabled(!s.showMenuBarIcon)
            }
            Section("Player") {
                Picker("Control", selection: $s.playerPreference) {
                    ForEach(PlayerPreference.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Mini player") {
                Toggle("Show mini player", isOn: $s.miniPlayerVisible)
                Toggle("Hide when nothing is playing", isOn: $s.hideWhenNoPlayer)
                Toggle("Keep on top of other windows", isOn: $s.alwaysOnTop)
                Toggle("Show on all Spaces", isOn: $s.showOnAllSpaces)
                Toggle("Lock position", isOn: $s.lockPosition)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

struct AppearancePane: View {
    @ObservedObject private var s = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $s.theme) {
                    ForEach(PlayerTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Size", selection: $s.playerSize) {
                    ForEach(PlayerSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Controls", selection: $s.controlsVisibility) {
                    ForEach(ControlsVisibility.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Volume slider (scroll over the player to adjust)", isOn: $s.showVolumeSlider)
                Picker("Time", selection: $s.timeDisplay) {
                    ForEach(TimeDisplay.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Opacity") {
                    Slider(value: $s.opacity, in: 0.3...1)
                }
            }
            Section("Color") {
                Toggle("Tint from artwork", isOn: $s.useArtworkColor)
                ColorPicker("Accent color", selection: Binding(
                    get: { Color(nsColor: s.accentColor) },
                    set: { s.accentColor = NSColor($0) }
                ), supportsOpacity: false)
                .disabled(s.useArtworkColor)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Notifications

struct NotificationsPane: View {
    @ObservedObject private var s = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show a notification when the song changes", isOn: $s.notificationsEnabled)
                    .onChange(of: s.notificationsEnabled) { enabled in
                        if enabled { (NSApp.delegate as? AppDelegate)?.notifier.requestAuthorization() }
                    }
                Toggle("Only when the player is in the background", isOn: $s.notifyOnlyInBackground)
                    .disabled(!s.notificationsEnabled)
            }
            Section {
                Button("Send Test Notification") {
                    if let snap = PlayerManager.shared.snapshot {
                        (NSApp.delegate as? AppDelegate)?.notifier.post(snap)
                    }
                }
                .disabled(PlayerManager.shared.snapshot == nil)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Spotify

struct SpotifyPane: View {
    @ObservedObject private var s = AppSettings.shared
    @State private var secret = AppSettings.shared.spotifyClientSecret
    @State private var status: String?
    @State private var ok = false
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                TextField("Client ID", text: $s.spotifyClientID)
                SecureField("Client Secret", text: $secret)
                    .onChange(of: secret) {
                        s.spotifyClientSecret = $0
                        Task { await SpotifyAPI.shared.resetToken() }
                    }
                HStack {
                    if testing { ProgressView().controlSize(.small) }
                    if let status {
                        Label(status, systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(ok ? .green : .red)
                            .font(.caption)
                    }
                    Spacer()
                    Button("Test Connection", action: test)
                        .disabled(testing || s.spotifyClientID.isEmpty || secret.isEmpty)
                }
            } header: {
                Text("Spotify Web API")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Used only to search and browse the catalogue inside Cadence. Playback goes to the Spotify app.")
                    Text("1. Go to developer.spotify.com/dashboard and choose Create app.")
                    Text("2. Use any name, set the redirect URI to cadence://callback and tick Web API.")
                    Text("3. Copy the Client ID and Client Secret from the app's settings into the fields above.")
                    Link("Open Spotify Developer Dashboard",
                         destination: URL(string: "https://developer.spotify.com/dashboard")!)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func test() {
        testing = true
        status = nil
        Task { @MainActor in
            await SpotifyAPI.shared.resetToken()
            do {
                let r = try await SpotifyAPI.shared.search("Miles Davis", limit: 1)
                ok = !r.isEmpty
                status = ok ? "Connected" : "Connected, but the test search returned nothing"
            } catch {
                ok = false
                status = error.localizedDescription
            }
            testing = false
        }
    }
}

// MARK: - Last.fm

struct LastFMPane: View {
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var queue = ScrobbleQueue.shared
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var signedIn = LastFMClient.shared.isAuthenticated
    @State private var secret = AppSettings.shared.lastfmAPISecret

    var body: some View {
        Form {
            Section {
                TextField("API key", text: $s.lastfmAPIKey)
                SecureField("Shared secret", text: $secret)
                    .onChange(of: secret) { s.lastfmAPISecret = $0 }
                Link("Get an API key at last.fm/api/account/create",
                     destination: URL(string: "https://www.last.fm/api/account/create")!)
                    .font(.caption)
            } header: {
                Text("API credentials")
            }

            Section("Account") {
                if signedIn {
                    HStack {
                        Text("Signed in as **\(s.lastfmUsername)**")
                        Spacer()
                        Button("Sign Out") {
                            LastFMClient.shared.logout()
                            signedIn = false
                        }
                    }
                } else {
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                    HStack {
                        if busy { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Sign In", action: signIn)
                            .disabled(busy || username.isEmpty || password.isEmpty || !LastFMClient.shared.hasCredentials)
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }

            Section("Scrobbling") {
                Toggle("Scrobble played tracks", isOn: $s.scrobblingEnabled)
                Toggle("Update “Now Playing”", isOn: $s.sendNowPlaying)
                LabeledContent("Scrobble after \(Int(s.scrobbleThreshold * 100))% of a track") {
                    Slider(value: $s.scrobbleThreshold, in: 0.5...0.95, step: 0.05)
                }
                HStack {
                    Text(queue.pending.isEmpty ? "No scrobbles waiting" : "\(queue.pending.count) scrobble(s) waiting")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Send Now") { queue.flush() }.disabled(queue.pending.isEmpty || !signedIn)
                }
                if let last = queue.lastScrobble {
                    Text("Last scrobbled: \(last.artist) – \(last.title)").font(.caption).foregroundStyle(.secondary)
                }
                if let err = queue.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func signIn() {
        busy = true
        error = nil
        Task { @MainActor in
            do {
                let name = try await LastFMClient.shared.login(username: username, password: password)
                s.lastfmUsername = name
                password = ""
                signedIn = true
                ScrobbleQueue.shared.flush()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsPane: View {
    @ObservedObject private var s = AppSettings.shared

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(shortcut: Binding(
                            get: { s.shortcut(for: action) },
                            set: { s.setShortcut($0, for: action) }
                        ))
                        .frame(width: 150, height: 24)
                    }
                }
            } footer: {
                Text("Click a field and press a key combination. Press Delete to clear, Esc to cancel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut?

    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton()
        b.onChange = { shortcut = $0 }
        b.shortcut = shortcut
        return b
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.onChange = { shortcut = $0 }
        nsView.shortcut = shortcut
    }
}

final class RecorderButton: NSButton {
    var onChange: ((Shortcut?) -> Void)?
    var shortcut: Shortcut? { didSet { refresh() } }
    private var recording = false { didSet { refresh() } }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(startRecording)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    @objc private func startRecording() {
        recording = true
        window?.makeFirstResponder(self)
    }

    private func refresh() {
        title = recording ? "Type shortcut…" : (shortcut?.displayString ?? "Record Shortcut")
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        handle(event)
    }

    private func handle(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: // Esc
            recording = false
        case 51, 117: // Delete, Forward Delete
            onChange?(nil)
            recording = false
        default:
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let isFunctionKey = (96...122).contains(Int(event.keyCode))
            guard !mods.isEmpty || isFunctionKey else { NSSound.beep(); return }
            onChange?(Shortcut(event: event))
            recording = false
        }
    }
}
