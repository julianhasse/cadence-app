import AppKit

enum ScriptError: Error {
    case notPermitted
    case notRunning
    case failed(Int, String)
}

/// Executes AppleScript. Not thread-safe: use from a single serial queue.
final class AppleScriptRunner: @unchecked Sendable {
    private var cache: [String: NSAppleScript] = [:]

    func run(_ source: String, cache shouldCache: Bool = true) -> Result<NSAppleEventDescriptor, ScriptError> {
        let script: NSAppleScript
        if let cached = cache[source] {
            script = cached
        } else {
            guard let s = NSAppleScript(source: source) else { return .failure(.failed(-1, "Invalid script")) }
            var compileError: NSDictionary?
            s.compileAndReturnError(&compileError)
            if let e = compileError { return .failure(Self.error(from: e)) }
            if shouldCache { cache[source] = s }
            script = s
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let e = error { return .failure(Self.error(from: e)) }
        return .success(result)
    }

    private static func error(from dict: NSDictionary) -> ScriptError {
        let code = dict[NSAppleScript.errorNumber] as? Int ?? -1
        switch code {
        case -1743: return .notPermitted
        case -600: return .notRunning
        default: return .failed(code, dict[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(code)")
        }
    }
}

/// Talks to Apple Music or Spotify over Apple Events.
/// Every script is guarded with `is running` so polling never launches a player.
final class ScriptablePlayer: @unchecked Sendable {
    let kind: PlayerKind
    private let runner: AppleScriptRunner
    private static let separator = "\u{1E}"

    init(kind: PlayerKind, runner: AppleScriptRunner) {
        self.kind = kind
        self.runner = runner
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: kind.bundleID).isEmpty
    }

    private func wrap(_ body: String) -> String {
        """
        if application id "\(kind.bundleID)" is running then
            tell application id "\(kind.bundleID)"
                \(body)
            end tell
        end if
        return ""
        """
    }

    // MARK: - State

    private var snapshotScript: String {
        let durationExpr = kind == .spotify ? "(duration of t) / 1000" : "duration of t"
        let idExpr = kind == .spotify ? "id of t" : "persistent ID of t"
        let lovedExpr = kind == .music
            ? "if («class pLov» of t) then set lv to \"1\""
            : "set lv to \"0\""
        let artExpr = kind == .spotify ? "set au to artwork url of t" : "set au to \"\""
        return wrap("""
            set sep to character id 30
            set ps to player state as string
            if ps is "stopped" then return "stopped"
            try
                set t to current track
            on error
                return "stopped"
            end try
            set nm to ""
            set ar to ""
            set al to ""
            set d to 0
            set tid to ""
            set lv to "0"
            set au to ""
            try
                set nm to name of t
            end try
            try
                set ar to artist of t
            end try
            try
                set al to album of t
            end try
            try
                set d to \(durationExpr)
            end try
            try
                set tid to \(idExpr)
            end try
            try
                \(lovedExpr)
            end try
            try
                \(artExpr)
            end try
            set pp to 0
            try
                set pp to player position
            end try
            set vol to 0
            try
                set vol to sound volume
            end try
            return ps & sep & nm & sep & ar & sep & al & sep & d & sep & pp & sep & tid & sep & lv & sep & vol & sep & au
            """)
    }

    func snapshot() -> Result<PlayerSnapshot?, ScriptError> {
        switch runner.run(snapshotScript) {
        case .failure(let e): return .failure(e)
        case .success(let desc):
            let raw = desc.stringValue ?? ""
            if raw.isEmpty { return .failure(.notRunning) }
            if raw == "stopped" { return .success(nil) }
            let f = raw.components(separatedBy: Self.separator)
            guard f.count >= 10 else { return .success(nil) }
            let state: PlaybackState = f[0] == "playing" ? .playing : .paused
            let track = Track(
                id: f[6],
                title: f[1],
                artist: f[2],
                album: f[3],
                duration: Self.number(f[4]),
                artworkURL: f[9].isEmpty ? nil : URL(string: f[9]),
                loved: f[7] == "1"
            )
            guard !(track.title.isEmpty && track.artist.isEmpty) else { return .success(nil) }
            return .success(PlayerSnapshot(
                kind: kind, state: state, track: track,
                position: Self.number(f[5]), volume: Int(Self.number(f[8])),
                capturedAt: Date()
            ))
        }
    }

    /// AppleScript formats reals using the user's locale and may use exponent notation.
    private static func number(_ s: String) -> Double {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    // MARK: - Artwork

    /// Embedded artwork bytes (Apple Music). Spotify exposes a URL instead, see `Track.artworkURL`.
    func artworkData() -> Data? {
        guard kind == .music else { return nil }
        let script = wrap("""
            try
                return raw data of artwork 1 of current track
            end try
            try
                return data of artwork 1 of current track
            end try
            """)
        guard case .success(let desc) = runner.run(script) else { return nil }
        let data = desc.data
        return data.isEmpty ? nil : data
    }

    // MARK: - Commands

    @discardableResult
    private func command(_ body: String, cache: Bool = true) -> Bool {
        if case .success = runner.run(wrap(body), cache: cache) { return true }
        return false
    }

    func playPause() { command("playpause") }
    func next() { command("next track") }
    func previous() { command("previous track") }

    func seek(to seconds: Double) {
        command("set player position to \(String(format: "%.2f", max(0, seconds)))", cache: false)
    }

    func setVolume(_ volume: Int) {
        command("set sound volume to \(min(100, max(0, volume)))", cache: false)
    }

    /// Plays a Spotify URI (track, album, artist or playlist), optionally inside a context such as its album.
    /// URIs are validated so nothing but a well-formed `spotify:<type>:<id>` reaches the script.
    func play(uri: String, context: String?) {
        guard kind == .spotify, Self.isSpotifyURI(uri) else { return }
        var body = "play track \"\(uri)\""
        if let context, Self.isSpotifyURI(context) { body += " in context \"\(context)\"" }
        command(body, cache: false)
    }

    static func isSpotifyURI(_ s: String) -> Bool {
        s.range(of: #"^spotify:(track|album|artist|playlist|episode|show):[A-Za-z0-9]{1,64}$"#, options: .regularExpression) != nil
    }

    /// Only Apple Music exposes a scriptable "favorite"; Spotify loves go through Last.fm.
    func setLoved(_ loved: Bool) {
        guard kind == .music else { return }
        command("set «class pLov» of current track to \(loved ? "true" : "false")", cache: false)
    }
}
