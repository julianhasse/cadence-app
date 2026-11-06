import AppKit
import Combine
import SwiftUI

/// Opens a keyword search in the Spotify app (or the web player). Fallback when no API credentials are set.
enum SpotifySearch {
    private static let allowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    @MainActor
    static func search(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let encoded = q.addingPercentEncoding(withAllowedCharacters: allowed) else { return }
        let url = PlayerManager.shared.isInstalled(.spotify)
            ? URL(string: "spotify:search:\(encoded)")
            : URL(string: "https://open.spotify.com/search/\(encoded)")
        if let url { NSWorkspace.shared.open(url) }
        SearchHistory.add(q)
    }
}

/// Last few searches, most recent first.
enum SearchHistory {
    private static let key = "spotifySearchHistory"
    static var items: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func add(_ query: String) {
        var list = items.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        list.insert(query, at: 0)
        UserDefaults.standard.set(Array(list.prefix(5)), forKey: key)
    }
}

final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Floating Spotify browser: live search, artist and album pages, click to play.
@MainActor
final class SearchPanelController: NSWindowController, NSWindowDelegate {
    private let browser = SpotifyBrowser.shared
    private var cancellables = Set<AnyCancellable>()
    private let hosting: NSHostingView<SearchView>

    init() {
        let panel = SearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: SearchView.width, height: 56),
            // Non-activating: the panel takes keyboard focus without Cadence having to become
            // the active app first (which macOS may delay or refuse when triggered from the menu bar).
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        hosting = NSHostingView(rootView: SearchView(browser: SpotifyBrowser.shared, onClose: {}))
        if #available(macOS 13.3, *) {
            // The hidden title bar would otherwise be added to fittingSize as a safe-area inset.
            hosting.safeAreaRegions = []
        }
        panel.contentView = hosting
        super.init(window: panel)
        panel.delegate = self
        hosting.rootView = SearchView(browser: browser) { [weak self] in self?.close() }

        // Playing a song briefly activates Spotify; keep the browser open and take focus back afterwards.
        NotificationCenter.default.publisher(for: PlayerManager.spotifyFocusWillChange)
            .sink { [weak self] _ in self?.holdOpenUntil = Date().addingTimeInterval(12) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: PlayerManager.spotifyFocusRestored)
            .sink { [weak self] _ in
                guard let self, let panel = self.window, panel.isVisible else { return }
                self.holdOpenUntil = Date().addingTimeInterval(0.5)
                panel.orderFrontRegardless()
                panel.makeKey()
            }
            .store(in: &cancellables)

        browser.$expanded
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.fitToContent(animate: true) } }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Focus changes during the first moments after showing (menu closing, app switching) are ignored.
    private var shownAt = Date.distantPast
    /// While set in the future, losing focus does not close the panel (Spotify is being sent back).
    private var holdOpenUntil = Date.distantPast

    func show(prefill: String = "") {
        // Called from a menu item, the menu is still tracking; wait until it has closed.
        DispatchQueue.main.async { [weak self] in self?.present(prefill: prefill) }
    }

    private func present(prefill: String) {
        guard let panel = window else { return }
        browser.prepareForShow(prefill: prefill)
        hosting.rootView = SearchView(browser: browser) { [weak self] in self?.close() }
        if !panel.isVisible {
            let screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame
            if let screen {
                panel.setFrameTopLeftPoint(NSPoint(x: screen.midX - SearchView.width / 2, y: screen.maxY - screen.height * 0.12))
            }
        }
        fitToContent(animate: false)
        shownAt = Date()
        panel.orderFrontRegardless()
        panel.makeKey()
        // SwiftUI settles its layout one run-loop pass later; measure and refocus again then.
        DispatchQueue.main.async { [weak self] in
            self?.fitToContent(animate: false)
            self?.window?.makeKey()
        }
    }

    /// Resizes to the SwiftUI content while keeping the top edge in place.
    private func fitToContent(animate: Bool) {
        guard let panel = window else { return }
        hosting.layoutSubtreeIfNeeded()
        let height = hosting.fittingSize.height
        var frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: animate && panel.isVisible)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard Date().timeIntervalSince(shownAt) > 0.6 else {
            window?.makeKey()
            return
        }
        if Date() < holdOpenUntil { return }
        // Keep the browser open while a context menu from inside it is showing.
        if let key = NSApp.keyWindow, key.parent === window { return }
        close()
    }
}

// MARK: - Views

struct SearchView: View {
    static let width: CGFloat = 580
    @ObservedObject var browser: SpotifyBrowser
    @ObservedObject private var player = PlayerManager.shared
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if browser.expanded {
                Divider()
                Group {
                    if let error = browser.error {
                        MessageView(symbol: "exclamationmark.triangle", text: error)
                    } else {
                        switch browser.currentPage {
                        case .artist(let a): ArtistPage(browser: browser, artist: a, nowPlaying: nowPlayingURI)
                        case .album(let al): AlbumPage(browser: browser, album: al, nowPlaying: nowPlayingURI)
                        case nil: ResultsPage(browser: browser, nowPlaying: nowPlayingURI)
                        }
                    }
                }
                .frame(height: 470)
                Divider()
                footer
            } else if !browser.hasCredentials {
                Divider()
                SetupHint()
            } else if !SearchHistory.items.isEmpty {
                Divider()
                recent
            }
        }
        .frame(width: Self.width)
        .ignoresSafeArea()
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: browser.focusToken) { _ in DispatchQueue.main.async { focused = true } }
        .onExitCommand {
            if browser.currentPage != nil { browser.back() } else { onClose() }
        }
    }

    private var nowPlayingURI: String? {
        guard let snap = player.snapshot, snap.kind == .spotify else { return nil }
        return snap.track.id
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            if browser.currentPage != nil {
                Button(action: browser.back) {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Back (Esc)")
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            TextField("Search Spotify", text: $browser.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($focused)
                .onSubmit(submit)
            if browser.loading {
                ProgressView().controlSize(.small)
            }
            if !browser.query.isEmpty {
                Button { browser.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    private func submit() {
        if browser.hasCredentials {
            browser.playFirst()
        } else {
            SpotifySearch.search(browser.query)
            onClose()
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent").font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 2)
            ForEach(SearchHistory.items, id: \.self) { item in
                HoverRow {
                    Label(item, systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } action: {
                    if browser.hasCredentials { browser.query = item } else { SpotifySearch.search(item); onClose() }
                }
            }
        }
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack {
            Text("Return plays the first song · Esc goes back")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Open in Spotify") {
                SpotifySearch.search(browser.query)
                onClose()
            }
            .buttonStyle(.link)
            .font(.caption)
            .disabled(browser.query.isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
    }
}

private struct ResultsPage: View {
    @ObservedObject var browser: SpotifyBrowser
    let nowPlaying: String?

    var body: some View {
        if let r = browser.results {
            if r.isEmpty {
                MessageView(symbol: "magnifyingglass", text: "No results for “\(browser.query)”")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !r.artistList.isEmpty {
                            SectionTitle("Artists")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 14) {
                                    ForEach(r.artistList.prefix(8)) { artist in
                                        Tile(title: artist.name, subtitle: "Artist", imageURL: artist.images?.smallest, circle: true) {
                                            browser.open(artist)
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                        if !r.trackList.isEmpty {
                            SectionTitle("Songs")
                            VStack(spacing: 0) {
                                ForEach(r.trackList) { track in
                                    TrackRow(track: track, browser: browser, isPlaying: track.uri == nowPlaying)
                                }
                            }
                        }
                        if !r.albumList.isEmpty {
                            SectionTitle("Albums")
                            AlbumStrip(albums: r.albumList, browser: browser)
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
        } else {
            MessageView(symbol: "music.magnifyingglass", text: browser.loading ? "Searching…" : "Type to search Spotify")
        }
    }
}

private struct ArtistPage: View {
    @ObservedObject var browser: SpotifyBrowser
    let artist: SpotifyArtist
    let nowPlaying: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Thumb(url: artist.images?.largest, size: 72, circle: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(artist.name).font(.system(size: 22, weight: .bold))
                        if let genres = artist.genres, !genres.isEmpty {
                            Text(genres.prefix(3).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    PlayButton { browser.play(uri: artist.uri) }
                }
                .padding(.horizontal, 16)

                if !browser.artistTop.isEmpty {
                    SectionTitle("Popular")
                    VStack(spacing: 0) {
                        ForEach(Array(browser.artistTop.enumerated()), id: \.element.id) { index, track in
                            TrackRow(track: track, browser: browser, isPlaying: track.uri == nowPlaying,
                                     number: index + 1, context: track.album?.uri)
                        }
                    }
                }
                if !browser.artistAlbums.isEmpty {
                    SectionTitle("Albums & Singles")
                    AlbumStrip(albums: browser.artistAlbums, browser: browser)
                }
            }
            .padding(.vertical, 12)
        }
    }
}

private struct AlbumPage: View {
    @ObservedObject var browser: SpotifyBrowser
    let album: SpotifyAlbum
    let nowPlaying: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Thumb(url: album.images?.largest, size: 96)
                    VStack(alignment: .leading, spacing: 4) {
                        Text((album.albumType ?? "album").capitalized).font(.caption).foregroundStyle(.secondary)
                        Text(album.name).font(.system(size: 20, weight: .bold)).lineLimit(2)
                        HStack(spacing: 4) {
                            ForEach(album.artists, id: \.id) { a in
                                Button(a.name) { browser.open(a) }.buttonStyle(.link)
                            }
                            if !album.year.isEmpty { Text("· \(album.year)").foregroundStyle(.secondary) }
                        }
                        .font(.callout)
                    }
                    Spacer()
                    PlayButton { browser.play(uri: album.uri) }
                }
                .padding(.horizontal, 16)

                VStack(spacing: 0) {
                    ForEach(browser.albumTracks) { track in
                        TrackRow(track: track, browser: browser, isPlaying: track.uri == nowPlaying,
                                 number: track.trackNumber, context: album.uri, showArtwork: false)
                    }
                }
            }
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Components

private struct TrackRow: View {
    let track: SpotifyTrack
    @ObservedObject var browser: SpotifyBrowser
    let isPlaying: Bool
    var number: Int? = nil
    var context: String? = nil
    var showArtwork = true

    var body: some View {
        HoverRow {
            HStack(spacing: 10) {
                if let number {
                    Group {
                        if isPlaying {
                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor)
                        } else {
                            Text("\(number)").foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: 20)
                }
                if showArtwork {
                    Thumb(url: track.album?.images?.smallest, size: 34)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isPlaying ? Color.accentColor : .primary)
                    HStack(spacing: 4) {
                        if track.explicit == true {
                            Text("E").font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.4)))
                        }
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer()
                Text(TimeLabels.format(Double(track.durationMs) / 1000))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } action: {
            browser.play(track, context: context)
        }
        .contextMenu {
            Button("Play") { browser.play(track, context: context) }
            if let artist = track.artists.first {
                Button("Go to \(artist.name)") { browser.open(artist) }
            }
            if let album = track.album {
                Button("Go to Album") { browser.open(album) }
            }
            Divider()
            Button("Copy Song Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(track.webURL?.absoluteString ?? track.uri, forType: .string)
            }
        }
    }

    private var subtitle: String {
        if showArtwork, let album = track.album { return "\(track.artistNames) · \(album.name)" }
        return track.artistNames
    }
}

private struct AlbumStrip: View {
    let albums: [SpotifyAlbum]
    @ObservedObject var browser: SpotifyBrowser

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(albums) { album in
                    Tile(title: album.name, subtitle: [album.year, album.artists.first?.name ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                         imageURL: album.images?.smallest, circle: false) {
                        browser.open(album)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct Tile: View {
    let title: String
    let subtitle: String
    let imageURL: URL?
    let circle: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: circle ? .center : .leading, spacing: 4) {
                Thumb(url: imageURL, size: 96, circle: circle)
                    .scaleEffect(hovering ? 1.04 : 1)
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 96)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

private struct HoverRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }
}

private struct Thumb: View {
    let url: URL?
    let size: CGFloat
    var circle = false

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: circle ? "person.fill" : "music.note")
                        .font(.system(size: size * 0.35))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4)))
    }
}

private struct PlayButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.green))
        }
        .buttonStyle(.plain)
        .help("Play")
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 13, weight: .bold)).padding(.horizontal, 16)
    }
}

private struct MessageView: View {
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SetupHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("To see results here, add a Spotify Client ID and Secret in Settings › Spotify.")
                Text("Until then, Return opens the search in the Spotify app.")
                    .foregroundStyle(.secondary)
                Button("Open Spotify Settings…") {
                    (NSApp.delegate as? AppDelegate)?.showPreferences()
                }
                .buttonStyle(.link)
            }
            .font(.callout)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension Array where Element == SpotifyImage {
    var smallest: URL? { self.min { ($0.width ?? 0) < ($1.width ?? 0) }?.url ?? first?.url }
    /// Prefers a ~300 px image over the 640 px original.
    var largest: URL? {
        (filter { ($0.width ?? 0) >= 160 }.min { ($0.width ?? 0) < ($1.width ?? 0) } ?? first)?.url
    }
}
