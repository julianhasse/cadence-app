import Combine
import Foundation

/// Persistent queue of scrobbles; entries survive offline periods and relaunches.
@MainActor
final class ScrobbleQueue: ObservableObject {
    static let shared = ScrobbleQueue()

    @Published private(set) var pending: [ScrobbleEntry] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastScrobble: ScrobbleEntry?
    private var flushing = false

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cadence", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending-scrobbles.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let entries = try? JSONDecoder().decode([ScrobbleEntry].self, from: data) {
            pending = entries
        }
    }

    func add(_ entry: ScrobbleEntry) {
        pending.append(entry)
        save()
        flush()
    }

    func flush() {
        guard !flushing, !pending.isEmpty, LastFMClient.shared.isAuthenticated else { return }
        flushing = true
        let batch = Array(pending.prefix(50))
        Task {
            do {
                try await LastFMClient.shared.scrobble(batch)
                pending.removeFirst(min(batch.count, pending.count))
                lastScrobble = batch.last
                lastError = nil
                save()
                flushing = false
                flush()
            } catch let error as LastFMError where error.isPermanent && error.code != 9 {
                // The batch itself is rejected; drop it rather than retrying forever.
                pending.removeFirst(min(batch.count, pending.count))
                lastError = error.localizedDescription
                save()
                flushing = false
            } catch {
                lastError = error.localizedDescription
                flushing = false
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pending) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Applies Last.fm scrobbling rules to the polled player state.
/// A track is scrobbled once it is longer than 30 s and has played for
/// `scrobbleThreshold` of its length or 4 minutes, whichever comes first.
@MainActor
final class Scrobbler {
    private var cancellables = Set<AnyCancellable>()
    private var currentKey: String?
    private var track: Track?
    private var startedAt = Date()
    private var played: TimeInterval = 0
    private var lastTick: Date?
    private var lastPosition: Double = 0
    private var scrobbled = false
    private var retryTimer: Timer?

    func start() {
        PlayerManager.shared.didPoll
            .sink { [weak self] in self?.handle($0) }
            .store(in: &cancellables)
        retryTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            Task { @MainActor in ScrobbleQueue.shared.flush() }
        }
        ScrobbleQueue.shared.flush()
    }

    private func handle(_ snap: PlayerSnapshot?) {
        let now = Date()
        guard let snap else { lastTick = nil; return }
        let settings = AppSettings.shared

        let restarted = scrobbled && snap.position < 5 && lastPosition > 30
        if snap.trackKey != currentKey || restarted {
            currentKey = snap.trackKey
            track = snap.track
            startedAt = now.addingTimeInterval(-max(0, snap.position))
            played = 0
            scrobbled = false
            lastTick = now
            lastPosition = snap.position
            if snap.state == .playing, settings.scrobblingEnabled, settings.sendNowPlaying,
               LastFMClient.shared.isAuthenticated {
                let t = snap.track
                Task { try? await LastFMClient.shared.updateNowPlaying(t) }
            }
            return
        }

        if snap.state == .playing, let last = lastTick {
            played += min(now.timeIntervalSince(last), 5)
        }
        lastTick = now
        lastPosition = snap.position

        guard settings.scrobblingEnabled, !scrobbled, let track, track.duration > 30 else { return }
        let threshold = min(track.duration * max(0.5, settings.scrobbleThreshold), 240)
        guard played >= threshold else { return }
        scrobbled = true
        guard LastFMClient.shared.hasCredentials else { return }
        ScrobbleQueue.shared.add(ScrobbleEntry(
            artist: track.artist, title: track.title, album: track.album,
            duration: Int(track.duration), timestamp: Int(startedAt.timeIntervalSince1970)
        ))
    }
}
