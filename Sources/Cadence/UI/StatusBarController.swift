import AppKit
import Combine

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.imagePosition = .imageLeading
        PlayerManager.shared.$snapshot
            .sink { [weak self] in self?.update($0) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .settingsChanged)
            .sink { [weak self] _ in self?.update(PlayerManager.shared.snapshot) }
            .store(in: &cancellables)
    }

    deinit {
        NSStatusBar.system.removeStatusItem(item)
    }

    private func update(_ snap: PlayerSnapshot?) {
        guard let button = item.button else { return }
        let symbol = snap?.state == .playing ? "music.note" : "music.note.list"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Cadence")
        let settings = AppSettings.shared
        if settings.showTitleInMenuBar, let snap {
            var title = "\(snap.track.artist) – \(snap.track.title)"
            let limit = max(10, settings.menuBarTitleLength)
            if title.count > limit { title = String(title.prefix(limit - 1)) + "…" }
            button.title = " " + title
        } else {
            button.title = ""
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        MenuBuilder.populate(menu, anchor: item.button)
    }
}
