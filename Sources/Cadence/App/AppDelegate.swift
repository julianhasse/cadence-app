import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let notifier = SongNotifier()
    private let scrobbler = Scrobbler()
    private var statusBar: StatusBarController?
    private var miniPlayer: MiniPlayerWindowController!
    private var preferences: PreferencesWindowController?
    private var cancellables = Set<AnyCancellable>()

    /// Text fields get ⌘X/⌘C/⌘V/⌘A/⌘Z via the main menu's key equivalents, so even a
    /// menu-bar app needs an Edit menu; without it, pasting into Settings fields does nothing.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Cadence", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(ClosureMenuItem("Settings…", key: ",") { [weak self] in self?.showPreferences() })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Cadence", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Cadence", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        // Load stored secrets off the main thread; any Keychain prompt then never blocks the UI.
        Keychain.preload {
            Task { @MainActor in
                AppSettings.shared.objectWillChange.send()
                ScrobbleQueue.shared.flush()
            }
        }
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )

        let player = PlayerManager.shared
        player.start()
        miniPlayer = MiniPlayerWindowController()
        scrobbler.start()
        notifier.start()
        player.trackChanged
            .sink { [weak self] in self?.notifier.trackChanged($0) }
            .store(in: &cancellables)

        applyChromeSettings()
        applyShortcuts()
        NotificationCenter.default.publisher(for: .settingsChanged)
            .sink { [weak self] note in
                guard let self, let key = note.object as? String else { return }
                if ["showDockIcon", "showMenuBarIcon"].contains(key) { self.applyChromeSettings() }
                if key.hasPrefix("shortcut.") { self.applyShortcuts() }
            }
            .store(in: &cancellables)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPreferences()
        return true
    }

    // MARK: - Chrome

    private func applyChromeSettings() {
        let s = AppSettings.shared
        if !s.showDockIcon && !s.showMenuBarIcon { s.showMenuBarIcon = true }
        NSApp.setActivationPolicy(s.showDockIcon ? .regular : .accessory)
        if s.showMenuBarIcon {
            if statusBar == nil { statusBar = StatusBarController() }
        } else {
            statusBar = nil
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        MenuBuilder.populate(menu, anchor: nil)
        return menu
    }

    // MARK: - Actions

    func toggleMiniPlayer() { miniPlayer.toggle() }

    func showPreferences() {
        if preferences == nil { preferences = PreferencesWindowController() }
        NSApp.activate(ignoringOtherApps: true)
        preferences?.showWindow(nil)
        preferences?.window?.makeKeyAndOrderFront(nil)
    }

    private func perform(_ action: ShortcutAction) {
        let player = PlayerManager.shared
        switch action {
        case .playPause: player.playPause()
        case .next: player.next()
        case .previous: player.previous()
        case .toggleMiniPlayer: toggleMiniPlayer()
        case .love:
            if let snap = player.snapshot { player.setLoved(!snap.track.loved) }
        case .showSong:
            if let snap = player.snapshot { notifier.post(snap) }
        case .searchSpotify:
            showSearch()
        }
    }

    private var search: SearchPanelController?

    func showSearch(prefill: String = "") {
        if search == nil { search = SearchPanelController() }
        search?.show(prefill: prefill)
    }

    private func applyShortcuts() {
        for action in ShortcutAction.allCases {
            HotKeyCenter.shared.register(action, AppSettings.shared.shortcut(for: action)) { [weak self] in
                self?.perform(action)
            }
        }
    }

    // MARK: - URL scheme (cadence://playpause, next, previous, love, toggle, show, hide, settings)

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string), let command = url.host?.lowercased() else { return }
        let s = AppSettings.shared
        switch command {
        case "playpause": perform(.playPause)
        case "next": perform(.next)
        case "previous": perform(.previous)
        case "love": perform(.love)
        case "toggle": toggleMiniPlayer()
        case "show": s.miniPlayerVisible = true; miniPlayer.updateVisibility()
        case "hide": s.miniPlayerVisible = false; miniPlayer.updateVisibility()
        case "settings", "preferences": showPreferences()
        case "search":
            // cadence://search?q=keyword searches immediately; cadence://search opens the search field.
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value ?? ""
            if q.isEmpty { showSearch() } else { SpotifySearch.search(q) }
        default: break
        }
    }
}
