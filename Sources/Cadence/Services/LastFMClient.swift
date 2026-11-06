import CryptoKit
import Foundation

struct LastFMError: LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { message }
    /// Codes after which retrying the same request is pointless (bad auth, bad params, suspended key).
    var isPermanent: Bool { [4, 6, 9, 10, 13, 26].contains(code) }
}

struct ScrobbleEntry: Codable, Equatable {
    var artist: String
    var title: String
    var album: String
    var duration: Int
    var timestamp: Int
}

/// Minimal Last.fm Web API 2.0 client (mobile-session auth, now playing, scrobble, love).
final class LastFMClient: @unchecked Sendable {
    static let shared = LastFMClient()
    private let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    private var apiKey: String { AppSettings.shared.lastfmAPIKey }
    private var apiSecret: String { AppSettings.shared.lastfmAPISecret }
    var sessionKey: String? { Keychain.get(account: "lastfm.session") }

    var hasCredentials: Bool { !apiKey.isEmpty && !apiSecret.isEmpty }
    var isAuthenticated: Bool { hasCredentials && sessionKey != nil }

    // MARK: Auth

    func login(username: String, password: String) async throws -> String {
        let json = try await call("auth.getMobileSession", ["username": username, "password": password], authenticated: false)
        guard let session = json["session"] as? [String: Any], let key = session["key"] as? String else {
            throw LastFMError(code: -1, message: "Unexpected response from Last.fm")
        }
        Keychain.set(key, account: "lastfm.session")
        return session["name"] as? String ?? username
    }

    func logout() {
        Keychain.set(nil, account: "lastfm.session")
    }

    // MARK: Track methods

    func updateNowPlaying(_ track: Track) async throws {
        var p = ["artist": track.artist, "track": track.title]
        if !track.album.isEmpty { p["album"] = track.album }
        if track.duration > 0 { p["duration"] = String(Int(track.duration)) }
        _ = try await call("track.updateNowPlaying", p)
    }

    func scrobble(_ entries: [ScrobbleEntry]) async throws {
        var p: [String: String] = [:]
        for (i, e) in entries.prefix(50).enumerated() {
            p["artist[\(i)]"] = e.artist
            p["track[\(i)]"] = e.title
            p["timestamp[\(i)]"] = String(e.timestamp)
            if !e.album.isEmpty { p["album[\(i)]"] = e.album }
            if e.duration > 0 { p["duration[\(i)]"] = String(e.duration) }
        }
        _ = try await call("track.scrobble", p)
    }

    func love(_ track: Track, loved: Bool) async throws {
        _ = try await call(loved ? "track.love" : "track.unlove", ["artist": track.artist, "track": track.title])
    }

    func userInfo() async throws -> [String: Any] {
        let json = try await call("user.getInfo", [:])
        return json["user"] as? [String: Any] ?? [:]
    }

    // MARK: Transport

    private func call(_ method: String, _ params: [String: String], authenticated: Bool = true) async throws -> [String: Any] {
        guard hasCredentials else { throw LastFMError(code: -1, message: "Add your Last.fm API key and secret first.") }
        var p = params
        p["method"] = method
        p["api_key"] = apiKey
        if authenticated {
            guard let sk = sessionKey else { throw LastFMError(code: 9, message: "Not signed in to Last.fm.") }
            p["sk"] = sk
        }
        p["api_sig"] = signature(for: p)
        p["format"] = "json"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(p).utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LastFMError(code: -1, message: "Invalid response from Last.fm")
        }
        if let code = json["error"] as? Int {
            throw LastFMError(code: code, message: json["message"] as? String ?? "Last.fm error \(code)")
        }
        return json
    }

    /// md5(sorted key+value pairs + secret), excluding `format` and `callback`.
    private func signature(for params: [String: String]) -> String {
        let base = params.keys.sorted().map { $0 + (params[$0] ?? "") }.joined() + apiSecret
        return Insecure.MD5.hash(data: Data(base.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func formEncode(_ params: [String: String]) -> String {
        params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}
