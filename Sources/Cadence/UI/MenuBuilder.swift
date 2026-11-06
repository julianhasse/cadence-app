import AppKit

/// Menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", on: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        state = on ? .on : .off
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

/// "Look up" destinations for the current song. Add entries here to extend the menu.
struct LookupProvider {
    enum Query { case artistTitle, artistAlbum, artist }
    let name: String
    let template: String
    let query: Query

    func url(for track: Track) -> URL? {
        let q: String
        switch query {
        case .artistTitle: q = "\(track.artist) \(track.title)"
        case .artistAlbum: q = track.album.isEmpty ? "\(track.artist) \(track.title)" : "\(track.artist) \(track.album)"
        case .artist: q = track.artist
        }
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?"))) ?? q
        return URL(string: template.replacingOccurrences(of: "{q}", with: encoded))
    }

    static let all: [LookupProvider] = [
        .init(name: "Last.fm", template: "https://www.last.fm/search?q={q}", query: .artistTitle),
        .init(name: "Genius (lyrics)", template: "https://genius.com/search?q={q}", query: .artistTitle),
        .init(name: "Wikipedia", template: "https://en.wikipedia.org/w/index.php?search={q}", query: .artist),
        .init(name: "Discogs", template: "https://www.discogs.com/search/?q={q}", query: .artistAlbum),
        .init(name: "Bandcamp", template: "https://bandcamp.com/search?q={q}", query: .artistAlbum),
        .init(name: "Songkick (concerts)", template: "https://www.songkick.com/search?query={q}", query: .artist),
        .init(name: "Pitchfork", template: "https://pitchfork.com/search/?query={q}", query: .artistAlbum),
        .init(name: "Metacritic", template: "https://www.metacritic.com/search/{q}/?category=10", query: .artistAlbum),
        .init(name: "YouTube", template: "https://www.youtube.com/results?search_query={q}", query: .artistTitle),
    ]
}

/// Builds the shared menu used by the status item and the mini player's context menu.
@MainActor
enum MenuBuilder {
    static func populate(_ menu: NSMenu, anchor: NSView?) {
        menu.autoenablesItems = false
        let player = PlayerManager.shared
        let settings = AppSettings.shared
        let snap = player.snapshot
        let app = NSApp.delegate as? AppDelegate

        if let snap {
            let header = NSMenuItem()
            header.attributedTitle = NSAttributedString(string: snap.track.title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            header.isEnabled = false
            menu.addItem(header)
            let detail = [snap.track.artist, snap.track.album].filter { !$0.isEmpty }.joined(separator: " — ")
            if !detail.isEmpty {
                let item = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        } else {
            let item = NSMenuItem(title: "Nothing Playing", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(snap?.state == .playing ? "Pause" : "Play") { player.playPause() })
        menu.addItem(ClosureMenuItem("Next Track", enabled: snap != nil) { player.next() })
        menu.addItem(ClosureMenuItem("Previous Track", enabled: snap != nil) { player.previous() })
        if let snap {
            menu.addItem(ClosureMenuItem(snap.track.loved ? "Unlove Track" : "Love Track") { player.setLoved(!snap.track.loved) })
            let volume = NSMenuItem()
            volume.view = VolumeMenuView(volume: snap.volume)
            menu.addItem(volume)
        }
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem("Search Spotify…", key: "f") { app?.showSearch() })
        let browser = SpotifyBrowser.shared
        if !browser.lastTracks.isEmpty {
            let results = NSMenuItem(title: "Results: \(browser.lastTitle)", action: nil, keyEquivalent: "")
            let resultsMenu = NSMenu()
            let nowPlaying = snap?.kind == .spotify ? snap?.track.id : nil
            for track in browser.lastTracks {
                let item = ClosureMenuItem("\(track.name) — \(track.artistNames)", on: track.uri == nowPlaying) {
                    browser.play(track, context: browser.lastContext)
                }
                item.toolTip = track.album?.name
                resultsMenu.addItem(item)
            }
            resultsMenu.addItem(.separator())
            resultsMenu.addItem(ClosureMenuItem("Show in Search Window…") { app?.showSearch() })
            results.submenu = resultsMenu
            menu.addItem(results)
        }
        if let snap {
            menu.addItem(ClosureMenuItem("Search Spotify for “\(snap.track.artist)”") {
                SpotifySearch.search(snap.track.artist)
            })
        }
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(settings.miniPlayerVisible ? "Hide Mini Player" : "Show Mini Player") {
            app?.toggleMiniPlayer()
        })

        let source = NSMenuItem(title: "Player", action: nil, keyEquivalent: "")
        let sourceMenu = NSMenu()
        for pref in PlayerPreference.allCases {
            sourceMenu.addItem(ClosureMenuItem(pref.title, on: settings.playerPreference == pref) {
                settings.playerPreference = pref
                player.refresh()
            })
        }
        sourceMenu.addItem(.separator())
        for kind in PlayerKind.allCases where player.isInstalled(kind) {
            sourceMenu.addItem(ClosureMenuItem("Open \(kind.displayName)") { player.open(kind) })
        }
        source.submenu = sourceMenu
        menu.addItem(source)

        if let snap {
            let lookup = NSMenuItem(title: "Look Up", action: nil, keyEquivalent: "")
            let lookupMenu = NSMenu()
            for provider in LookupProvider.all {
                lookupMenu.addItem(ClosureMenuItem(provider.name) {
                    if let url = provider.url(for: snap.track) { NSWorkspace.shared.open(url) }
                })
            }
            lookup.submenu = lookupMenu
            menu.addItem(lookup)

            let share = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
            let shareMenu = NSMenu()
            shareMenu.addItem(ClosureMenuItem("Copy Song Info") { Sharing.copy(snap) })
            if let anchor {
                shareMenu.addItem(ClosureMenuItem("Share…") {
                    DispatchQueue.main.async { Sharing.share(snap, from: anchor) }
                })
            }
            share.submenu = shareMenu
            menu.addItem(share)
        }
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem("Settings…", key: ",") { app?.showPreferences() })
        menu.addItem(ClosureMenuItem("About Cadence") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        })
        menu.addItem(ClosureMenuItem("Quit Cadence", key: "q") { NSApp.terminate(nil) })
    }
}

/// Menu row with a speaker button (mute toggle) and a live volume slider.
final class VolumeMenuView: NSView {
    private let slider: NSSlider
    private let icon = NSButton()

    init(volume: Int) {
        slider = NSSlider(value: Double(volume), minValue: 0, maxValue: 100, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 28))

        icon.isBordered = false
        icon.bezelStyle = .regularSquare
        icon.imagePosition = .imageOnly
        icon.target = self
        icon.action = #selector(toggleMute)
        icon.frame = NSRect(x: 18, y: 4, width: 22, height: 20)
        addSubview(icon)

        slider.target = self
        slider.action = #selector(changed)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.frame = NSRect(x: 44, y: 4, width: 180, height: 20)
        slider.autoresizingMask = [.width]
        addSubview(slider)
        updateIcon()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateIcon() {
        let name = VolumeSlider.symbol(for: slider.doubleValue / 100)
        icon.image = NSImage(systemSymbolName: name, accessibilityDescription: "Volume")
        icon.toolTip = slider.doubleValue < 1 ? "Unmute" : "Mute"
    }

    @objc private func changed() {
        MainActor.assumeIsolated { PlayerManager.shared.setVolume(Int(slider.doubleValue.rounded())) }
        updateIcon()
    }

    @objc private func toggleMute() {
        MainActor.assumeIsolated {
            PlayerManager.shared.toggleMute()
            slider.doubleValue = Double(PlayerManager.shared.snapshot?.volume ?? 0)
        }
        updateIcon()
    }
}

@MainActor
enum Sharing {
    static func text(for snap: PlayerSnapshot) -> String {
        var s = "♫ \(snap.track.title) — \(snap.track.artist)"
        if !snap.track.album.isEmpty { s += " (\(snap.track.album))" }
        if let url = snap.track.webURL { s += "\n\(url.absoluteString)" }
        return s
    }

    static func copy(_ snap: PlayerSnapshot) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(for: snap), forType: .string)
    }

    static func share(_ snap: PlayerSnapshot, from view: NSView) {
        var items: [Any] = [text(for: snap)]
        if let art = PlayerManager.shared.artwork { items.append(art) }
        NSSharingServicePicker(items: items).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}
