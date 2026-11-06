import Foundation

/// State for the in-app Spotify browser: live search, artist and album pages, back navigation.
/// Shared so the menu bar can list the most recently shown songs.
@MainActor
final class SpotifyBrowser: ObservableObject {
    static let shared = SpotifyBrowser()

    enum Page: Hashable {
        case artist(SpotifyArtist)
        case album(SpotifyAlbum)
    }

    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    @Published private(set) var results: SpotifySearchResults?
    @Published private(set) var stack: [Page] = []
    @Published private(set) var artistTop: [SpotifyTrack] = []
    @Published private(set) var artistAlbums: [SpotifyAlbum] = []
    @Published private(set) var albumTracks: [SpotifyTrack] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    /// True when the window should show the results area.
    @Published private(set) var expanded = false
    /// Changes every time the panel is shown so the view can refocus the search field.
    @Published private(set) var focusToken = UUID()

    /// Songs most recently on screen, with a title, for the menu bar submenu.
    @Published private(set) var lastTracks: [SpotifyTrack] = []
    @Published private(set) var lastTitle = ""

    private var searchTask: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?
    private var loadedArtistID: String?
    private var loadedAlbumID: String?

    var currentPage: Page? { stack.last }
    var hasCredentials: Bool { SpotifyAPI.hasCredentials }

    func prepareForShow(prefill: String) {
        if !prefill.isEmpty {
            query = prefill
        }
        error = nil
        updateExpanded()
        focusToken = UUID()
    }

    // MARK: Search

    private func scheduleSearch() {
        searchTask?.cancel()
        stack = []
        error = nil
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        updateExpanded()
        guard !q.isEmpty, hasCredentials else {
            results = nil
            loading = false
            return
        }
        loading = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // debounce typing
            guard !Task.isCancelled else { return }
            do {
                let r = try await SpotifyAPI.shared.search(q)
                guard !Task.isCancelled else { return }
                results = r
                remember(r.trackList, title: "“\(q)”")
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    // MARK: Navigation

    func open(_ artist: SpotifyArtist) {
        stack.append(.artist(artist))
        loadCurrentPage()
    }

    func open(_ ref: SpotifyArtistRef) {
        // Search results only carry a reference; images/genres are filled in when available.
        open(SpotifyArtist(id: ref.id, name: ref.name, uri: ref.uri, images: nil, genres: nil))
    }

    func open(_ album: SpotifyAlbum) {
        stack.append(.album(album))
        loadCurrentPage()
    }

    func back() {
        guard !stack.isEmpty else { return }
        stack.removeLast()
        loadCurrentPage()
        updateExpanded()
    }

    private func loadCurrentPage() {
        updateExpanded()
        pageTask?.cancel()
        error = nil
        switch currentPage {
        case .artist(let artist):
            guard loadedArtistID != artist.id else {
                remember(artistTop, title: artist.name)
                return
            }
            artistTop = []
            artistAlbums = []
            loading = true
            pageTask = Task {
                do {
                    async let top = SpotifyAPI.shared.artistTopTracks(artist.id)
                    async let albums = SpotifyAPI.shared.artistAlbums(artist.id)
                    let (t, a) = try await (top, albums)
                    guard !Task.isCancelled else { return }
                    artistTop = t
                    artistAlbums = a
                    loadedArtistID = artist.id
                    remember(t, title: artist.name)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                }
                loading = false
            }
        case .album(let album):
            guard loadedAlbumID != album.id else {
                remember(albumTracks, title: album.name)
                return
            }
            albumTracks = []
            loading = true
            pageTask = Task {
                do {
                    let t = try await SpotifyAPI.shared.albumTracks(album.id)
                    guard !Task.isCancelled else { return }
                    albumTracks = t
                    loadedAlbumID = album.id
                    remember(t, title: album.name, album: album)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                }
                loading = false
            }
        case nil:
            loading = false
            if let r = results { remember(r.trackList, title: "“\(query)”") }
        }
    }

    // MARK: Playback

    func play(_ track: SpotifyTrack, context: String? = nil) {
        PlayerManager.shared.playSpotify(uri: track.uri, context: context ?? track.album?.uri)
        recordHistory()
    }

    func play(uri: String) {
        PlayerManager.shared.playSpotify(uri: uri)
        recordHistory()
    }

    /// Plays the first song on the current page (Return key).
    func playFirst() {
        switch currentPage {
        case .artist(let a): if let t = artistTop.first { play(t, context: a.uri) } else { play(uri: a.uri) }
        case .album(let al): if let t = albumTracks.first { play(t, context: al.uri) } else { play(uri: al.uri) }
        case nil: if let t = results?.trackList.first { play(t) }
        }
    }

    private func recordHistory() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { SearchHistory.add(q) }
    }

    // MARK: Helpers

    private func remember(_ tracks: [SpotifyTrack], title: String, album: SpotifyAlbum? = nil) {
        guard !tracks.isEmpty else { return }
        lastTracks = Array(tracks.prefix(15))
        lastTitle = title
        lastContext = album?.uri
    }

    /// Album URI to play menu items in, when the remembered songs came from an album page.
    private(set) var lastContext: String?

    private func updateExpanded() {
        let value = hasCredentials && (!query.trimmingCharacters(in: .whitespaces).isEmpty || !stack.isEmpty)
        if value != expanded { expanded = value }
    }
}
