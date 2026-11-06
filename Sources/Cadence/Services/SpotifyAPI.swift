import Foundation

// MARK: - Models (subset of the Spotify Web API objects)

struct SpotifyImage: Decodable, Hashable {
    let url: URL
    let width: Int?
}

struct SpotifyArtistRef: Decodable, Hashable {
    let id: String
    let name: String
    let uri: String
}

struct SpotifyArtist: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let images: [SpotifyImage]?
    let genres: [String]?

    var ref: SpotifyArtistRef { SpotifyArtistRef(id: id, name: name, uri: uri) }
}

struct SpotifyAlbum: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let images: [SpotifyImage]?
    let artists: [SpotifyArtistRef]
    let releaseDate: String?
    let albumType: String?
    let totalTracks: Int?

    var year: String { String((releaseDate ?? "").prefix(4)) }
}

struct SpotifyTrack: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let durationMs: Int
    let artists: [SpotifyArtistRef]
    let album: SpotifyAlbum?
    let explicit: Bool?
    let trackNumber: Int?

    var artistNames: String { artists.map(\.name).joined(separator: ", ") }
    var webURL: URL? { URL(string: "https://open.spotify.com/track/\(id)") }
}

struct SpotifyPaging<T: Decodable>: Decodable {
    /// Spotify occasionally returns `null` entries; they are dropped.
    let items: [T?]
    var values: [T] { items.compactMap { $0 } }
}

struct SpotifySearchResults: Decodable {
    let tracks: SpotifyPaging<SpotifyTrack>?
    let artists: SpotifyPaging<SpotifyArtist>?
    let albums: SpotifyPaging<SpotifyAlbum>?

    var trackList: [SpotifyTrack] { tracks?.values ?? [] }
    var artistList: [SpotifyArtist] { artists?.values ?? [] }
    var albumList: [SpotifyAlbum] { albums?.values ?? [] }
    var isEmpty: Bool { trackList.isEmpty && artistList.isEmpty && albumList.isEmpty }
}

struct SpotifyError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Client

/// Spotify Web API catalogue access using the Client Credentials flow.
/// Search and browsing need only an app's Client ID and Secret; no user login is involved.
/// Playback goes through the desktop app's AppleScript (`PlayerManager.playSpotify`).
actor SpotifyAPI {
    static let shared = SpotifyAPI()

    private var token: String?
    private var expiry = Date.distantPast
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    nonisolated static var hasCredentials: Bool {
        !AppSettings.shared.spotifyClientID.isEmpty && !AppSettings.shared.spotifyClientSecret.isEmpty
    }

    /// Two-letter market so results are playable in the user's country.
    private var market: String {
        let region = Locale.current.region?.identifier ?? "US"
        return region.count == 2 ? region : "US"
    }

    func resetToken() {
        token = nil
        expiry = .distantPast
    }

    // MARK: Endpoints

    func search(_ query: String, limit: Int = 10) async throws -> SpotifySearchResults {
        try await get("search", ["q": query, "type": "track,artist,album", "limit": String(limit), "market": market])
    }

    func artistTopTracks(_ artistID: String) async throws -> [SpotifyTrack] {
        struct Response: Decodable { let tracks: [SpotifyTrack] }
        let r: Response = try await get("artists/\(artistID)/top-tracks", ["market": market])
        return r.tracks
    }

    func artistAlbums(_ artistID: String) async throws -> [SpotifyAlbum] {
        let r: SpotifyPaging<SpotifyAlbum> = try await get(
            "artists/\(artistID)/albums", ["include_groups": "album,single", "limit": "20", "market": market]
        )
        // Drop duplicate editions (same title).
        var seen = Set<String>()
        return r.values.filter { seen.insert($0.name.lowercased()).inserted }
    }

    func albumTracks(_ albumID: String) async throws -> [SpotifyTrack] {
        let r: SpotifyPaging<SpotifyTrack> = try await get("albums/\(albumID)/tracks", ["limit": "50", "market": market])
        return r.values
    }

    // MARK: Transport

    private func accessToken() async throws -> String {
        if let token, Date() < expiry { return token }
        let id = AppSettings.shared.spotifyClientID
        let secret = AppSettings.shared.spotifyClientSecret
        guard !id.isEmpty, !secret.isEmpty else {
            throw SpotifyError(message: "Add your Spotify Client ID and Secret in Settings › Spotify.")
        }
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("Basic " + Data("\(id):\(secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let detail = json?["error_description"] as? String ?? json?["error"] as? String ?? "HTTP \(status)"
            throw SpotifyError(message: "Spotify sign-in failed: \(detail)")
        }
        struct TokenResponse: Decodable { let accessToken: String; let expiresIn: Int }
        let t = try decoder.decode(TokenResponse.self, from: data)
        token = t.accessToken
        expiry = Date().addingTimeInterval(TimeInterval(t.expiresIn - 60))
        return t.accessToken
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String], retry: Bool = true) async throws -> T {
        var components = URLComponents(string: "https://api.spotify.com/v1/\(path)")!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200:
            return try decoder.decode(T.self, from: data)
        case 401 where retry:
            resetToken()
            return try await get(path, query, retry: false)
        case 429:
            let wait = http?.value(forHTTPHeaderField: "Retry-After") ?? "a few"
            throw SpotifyError(message: "Spotify rate limit reached. Try again in \(wait) seconds.")
        default:
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            throw SpotifyError(message: message ?? "Spotify request failed (HTTP \(http?.statusCode ?? 0)).")
        }
    }
}
