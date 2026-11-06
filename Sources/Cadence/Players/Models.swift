import Foundation

enum PlayerKind: String, CaseIterable, Codable, Identifiable {
    case music
    case spotify

    var id: String { rawValue }

    var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }

    var displayName: String {
        switch self {
        case .music: return "Apple Music"
        case .spotify: return "Spotify"
        }
    }

    /// Distributed notification each player posts when its state or track changes.
    var changeNotification: Notification.Name {
        switch self {
        case .music: return Notification.Name("com.apple.Music.playerInfo")
        case .spotify: return Notification.Name("com.spotify.client.PlaybackStateChanged")
        }
    }
}

enum PlaybackState: String {
    case playing
    case paused
}

struct Track: Equatable {
    var id: String
    var title: String
    var artist: String
    var album: String
    /// Seconds. 0 when unknown (e.g. radio streams).
    var duration: Double
    var artworkURL: URL?
    var loved: Bool

    /// Public web link for the track when one is known (Spotify only).
    var webURL: URL? {
        let parts = id.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify" else { return nil }
        return URL(string: "https://open.spotify.com/\(parts[1])/\(parts[2])")
    }
}

struct PlayerSnapshot: Equatable {
    var kind: PlayerKind
    var state: PlaybackState
    var track: Track
    var position: Double
    var volume: Int
    var capturedAt: Date

    var trackKey: String {
        let ident = track.id.isEmpty ? "\(track.artist)|\(track.title)" : track.id
        return "\(kind.rawValue):\(ident)"
    }

    /// Position extrapolated to `date`, so the UI can animate smoothly between polls.
    func position(at date: Date) -> Double {
        guard state == .playing else { return position }
        let p = position + date.timeIntervalSince(capturedAt)
        return track.duration > 0 ? min(p, track.duration) : p
    }
}
