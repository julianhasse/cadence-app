import AppKit
import Combine
import SwiftUI

final class MiniPlayerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that supplies the shared context menu on right-click.
final class PlayerHostingView: NSHostingView<MiniPlayerView> {
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        MainActor.assumeIsolated { MenuBuilder.populate(menu, anchor: self) }
        return menu
    }
}

@MainActor
final class MiniPlayerWindowController: NSWindowController {
    private var cancellables = Set<AnyCancellable>()

    static func contentSize(theme: PlayerTheme, size: PlayerSize, volume: Bool = AppSettings.shared.showVolumeSlider) -> NSSize {
        let s = size.scale
        switch theme {
        case .cover: return NSSize(width: 220 * s, height: 220 * s)
        case .card: return NSSize(width: 220 * s, height: (220 + 104 + (volume ? 20 : 0)) * s)
        case .strip: return NSSize(width: 340 * s, height: 92 * s)
        }
    }

    init() {
        let settings = AppSettings.shared
        let size = Self.contentSize(theme: settings.theme, size: settings.playerSize)
        let panel = MiniPlayerPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = PlayerHostingView(rootView: MiniPlayerView())
        super.init(window: panel)

        if !panel.setFrameUsingName("CadenceMiniPlayer") {
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24))
            }
        }
        panel.setFrameAutosaveName("CadenceMiniPlayer")
        applySettings()
        installScrollMonitor()

        NotificationCenter.default.publisher(for: .settingsChanged)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)
        PlayerManager.shared.$snapshot
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateVisibility() }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var scrollMonitor: Any?
    private var scrollAccumulator: CGFloat = 0

    /// Scrolling anywhere over the mini player changes the volume in 2% steps.
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window, AppSettings.shared.showVolumeSlider,
                  let volume = PlayerManager.shared.snapshot?.volume else { return event }
            let delta = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
            self.scrollAccumulator += delta
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 6 : 1
            guard abs(self.scrollAccumulator) >= threshold else { return nil }
            let steps = Int(self.scrollAccumulator / threshold)
            self.scrollAccumulator -= CGFloat(steps) * threshold
            PlayerManager.shared.setVolume(volume + steps * 2)
            return nil
        }
    }

    private func applySettings() {
        guard let panel = window else { return }
        let s = AppSettings.shared
        panel.level = s.alwaysOnTop ? .floating : .normal
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        behavior.insert(s.showOnAllSpaces ? .canJoinAllSpaces : .managed)
        panel.collectionBehavior = behavior
        panel.alphaValue = CGFloat(min(1, max(0.2, s.opacity)))

        // Resize keeping the top-left corner fixed.
        let newSize = Self.contentSize(theme: s.theme, size: s.playerSize)
        var frame = panel.frame
        if frame.size != newSize {
            frame.origin.y += frame.height - newSize.height
            frame.size = newSize
            panel.setFrame(frame, display: true, animate: false)
        }
        updateVisibility()
    }

    func updateVisibility() {
        guard let panel = window else { return }
        let s = AppSettings.shared
        let hasPlayer = PlayerManager.shared.snapshot != nil
        if s.miniPlayerVisible && (hasPlayer || !s.hideWhenNoPlayer) {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    func toggle() {
        AppSettings.shared.miniPlayerVisible.toggle()
        updateVisibility()
    }
}
