import AppKit
import Combine

/// Detects the active music player, polls its state and forwards transport commands.
@MainActor
final class PlayerManager: ObservableObject {
    static let shared = PlayerManager()

    @Published private(set) var snapshot: PlayerSnapshot?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var artworkColor: NSColor?
    /// Set when macOS denied Automation access to a running player.
    @Published private(set) var permissionDenied: PlayerKind?

    /// Fires once per new track (after the first poll that sees it).
    let trackChanged = PassthroughSubject<PlayerSnapshot, Never>()
    /// Fires after every poll, including when nothing is playing.
    let didPoll = PassthroughSubject<PlayerSnapshot?, Never>()

    private let queue = DispatchQueue(label: "cadence.player-scripting", qos: .userInitiated)
    private let runner = AppleScriptRunner()
    private lazy var players: [PlayerKind: ScriptablePlayer] = Dictionary(
        uniqueKeysWithValues: PlayerKind.allCases.map { ($0, ScriptablePlayer(kind: $0, runner: runner)) }
    )
    private var timer: Timer?
    private var refreshInFlight = false
    private var refreshQueued = false
    private var lastActive: PlayerKind?
    private var currentKey: String?

    private init() {}

    func start() {
        let center = DistributedNotificationCenter.default()
        for kind in PlayerKind.allCases {
            center.addObserver(forName: kind.changeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 0.2
        refresh()
    }

    // MARK: - Polling

    func refresh() {
        guard !refreshInFlight else { refreshQueued = true; return }
        refreshInFlight = true
        let preference = AppSettings.shared.playerPreference.kind
        let last = lastActive
        let players = self.players
        queue.async {
            var results: [PlayerSnapshot] = []
            var denied: PlayerKind?
            var paused: [PlayerKind] = []
            for kind in PlayerKind.allCases {
                guard let player = players[kind], player.isRunning else { continue }
                if let preference, preference != kind { continue }
                switch player.snapshot() {
                case .success(let snap?): results.append(snap)
                case .success(nil): paused.append(kind)
                case .failure(.notPermitted): denied = kind
                case .failure: break
                }
            }
            let chosen = Self.choose(results, last: last)
            Task { @MainActor in self.apply(chosen, denied: denied) }
        }
    }

    nonisolated private static func choose(_ snaps: [PlayerSnapshot], last: PlayerKind?) -> PlayerSnapshot? {
        let playing = snaps.filter { $0.state == .playing }
        if let p = playing.first(where: { $0.kind == last }) ?? playing.first { return p }
        return snaps.first(where: { $0.kind == last }) ?? snaps.first
    }

    private func apply(_ snap: PlayerSnapshot?, denied: PlayerKind?) {
        refreshInFlight = false
        if permissionDenied != denied { permissionDenied = denied }
        if let snap {
            if snap.state == .playing || lastActive == nil { lastActive = snap.kind }
            if snap.trackKey != currentKey {
                currentKey = snap.trackKey
                artwork = nil
                artworkColor = nil
                loadArtwork(for: snap)
                snapshot = snap
                trackChanged.send(snap)
            } else {
                snapshot = snap
            }
        } else if snapshot != nil {
            snapshot = nil
            currentKey = nil
            artwork = nil
            artworkColor = nil
        }
        didPoll.send(snapshot)
        if refreshQueued {
            refreshQueued = false
            refresh()
        }
    }

    private func loadArtwork(for snap: PlayerSnapshot) {
        let key = snap.trackKey
        let player = players[snap.kind]
        queue.async {
            let data = player?.artworkData()
            Task { @MainActor in
                var image = data.flatMap(NSImage.init(data:))
                if image == nil { image = await ArtworkFetcher.fetch(for: snap.track) }
                guard self.currentKey == key else { return }
                self.artwork = image
                self.artworkColor = image?.averageColor?.tintAdjusted
            }
        }
    }

    // MARK: - Commands

    /// The player commands go to: the active one, else the preferred/any running one.
    private var targetPlayer: ScriptablePlayer? {
        if let kind = snapshot?.kind { return players[kind] }
        if let kind = AppSettings.shared.playerPreference.kind { return players[kind] }
        if let last = lastActive, players[last]?.isRunning == true { return players[last] }
        return PlayerKind.allCases.compactMap { players[$0] }.first { $0.isRunning }
    }

    private func perform(_ action: @escaping @Sendable (ScriptablePlayer) -> Void) {
        guard let player = targetPlayer else {
            launchPreferredPlayer()
            return
        }
        queue.async {
            action(player)
            Task { @MainActor in self.refresh() }
        }
    }

    func playPause() { perform { $0.playPause() } }
    func next() { perform { $0.next() } }
    func previous() { perform { $0.previous() } }
    func seek(to seconds: Double) { perform { $0.seek(to: seconds) } }

    // MARK: Volume

    private var volumeInFlight = false
    private var pendingVolume: Int?
    private var volumeBeforeMute: Int?

    /// Sets the player's volume (0–100). Calls are coalesced so dragging a slider
    /// never queues more than one AppleScript behind the one currently running.
    func setVolume(_ volume: Int) {
        let v = min(100, max(0, volume))
        if var s = snapshot, s.volume != v {
            s.volume = v
            snapshot = s
        }
        if v > 0 { volumeBeforeMute = nil }
        guard let player = targetPlayer else { return }
        if volumeInFlight {
            pendingVolume = v
            return
        }
        volumeInFlight = true
        queue.async {
            player.setVolume(v)
            Task { @MainActor in
                self.volumeInFlight = false
                if let next = self.pendingVolume {
                    self.pendingVolume = nil
                    self.setVolume(next)
                }
            }
        }
    }

    func toggleMute() {
        guard let current = snapshot?.volume else { return }
        if current > 0 {
            volumeBeforeMute = current
            setVolume(0)
        } else {
            setVolume(volumeBeforeMute ?? 50)
        }
    }

    func setLoved(_ loved: Bool) {
        guard let snap = snapshot else { return }
        perform { $0.setLoved(loved) }
        if LastFMClient.shared.isAuthenticated {
            Task { try? await LastFMClient.shared.love(snap.track, loved: loved) }
        }
        if snap.kind == .spotify {
            // Spotify has no scriptable "like"; remember Last.fm love locally so the UI reflects it.
            var s = snap
            s.track.loved = loved
            snapshot = s
        }
    }

    /// Plays a Spotify URI without bringing Spotify to the front, launching it in the background if needed.
    func playSpotify(uri: String, context: String? = nil) {
        guard let player = players[.spotify] else { return }
        lastActive = .spotify
        keepSpotifyInBackground()
        let play = { [queue] in
            queue.async {
                player.play(uri: uri, context: context)
                Task { @MainActor in self.refresh() }
            }
        }
        if player.isRunning {
            play()
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: PlayerKind.spotify.bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            Task { @MainActor in
                // Spotify needs a moment after launch before it accepts Apple Events.
                for _ in 0..<20 where !player.isRunning {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                play()
            }
        }
    }

    static let spotifyFocusWillChange = Notification.Name("CadenceSpotifyFocusWillChange")
    static let spotifyFocusRestored = Notification.Name("CadenceSpotifyFocusRestored")

    private var focusObserver: NSObjectProtocol?

    /// Spotify raises its window whenever it is asked to play a URI, and its AppleScript has no
    /// option to prevent that. Remember what was in front, and put it back once Spotify activates:
    /// hide Spotify again if it had no visible window, then re-activate the previous app.
    private func keepSpotifyInBackground() {
        let spotifyID = PlayerKind.spotify.bundleID
        let previous = NSWorkspace.shared.frontmostApplication
        guard previous?.bundleIdentifier != spotifyID else { return } // user is already in Spotify
        let spotify = NSRunningApplication.runningApplications(withBundleIdentifier: spotifyID).first
        let wasVisible = spotify.map { !$0.isHidden && Self.hasOnScreenWindow(pid: $0.processIdentifier) } ?? false

        NotificationCenter.default.post(name: Self.spotifyFocusWillChange, object: nil)
        if let focusObserver { NSWorkspace.shared.notificationCenter.removeObserver(focusObserver) }

        let restore: (NSRunningApplication) -> Void = { app in
            if !wasVisible { app.hide() }
            if let previous, !previous.isTerminated, previous.bundleIdentifier != Bundle.main.bundleIdentifier {
                previous.activate(options: [])
            }
            // Give the window server a moment, then let the search window take focus back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NotificationCenter.default.post(name: Self.spotifyFocusRestored, object: nil)
            }
        }

        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == spotifyID else { return }
            restore(app)
        }
        // Stop watching after a while (longer when Spotify still has to launch).
        let timeout: TimeInterval = spotify == nil ? 12 : 4
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, let observer = self.focusObserver else { return }
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.focusObserver = nil
            NotificationCenter.default.post(name: Self.spotifyFocusRestored, object: nil)
        }
    }

    /// Whether the app has a normal window on screen (needs no Screen Recording permission).
    private static func hasOnScreenWindow(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return list.contains {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }
    }

    func activatePlayer() {
        let kind = snapshot?.kind ?? AppSettings.shared.playerPreference.kind ?? lastActive ?? .music
        open(kind)
    }

    func launchPreferredPlayer() {
        open(AppSettings.shared.playerPreference.kind ?? lastActive ?? .music)
    }

    func open(_ kind: PlayerKind) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func isInstalled(_ kind: PlayerKind) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.bundleID) != nil
    }
}
