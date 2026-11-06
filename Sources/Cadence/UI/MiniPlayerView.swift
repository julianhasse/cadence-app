import AppKit
import SwiftUI

/// Root of the floating mini player. Switches between themes.
struct MiniPlayerView: View {
    @ObservedObject private var player = PlayerManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var hovering = false

    var body: some View {
        let scale = settings.playerSize.scale
        let size = MiniPlayerWindowController.contentSize(theme: settings.theme, size: settings.playerSize)
        ZStack {
            WindowDragArea()
            content(scale: scale)
        }
        .frame(width: size.width, height: size.height)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10 * scale, style: .continuous))
        .environment(\.colorScheme, .dark)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private func content(scale: CGFloat) -> some View {
        if let snap = player.snapshot {
            let ctx = PlayerContext(
                snap: snap, artwork: player.artwork, tint: tint, scale: scale,
                showControls: settings.controlsVisibility == .always || hovering,
                showVolume: settings.showVolumeSlider,
                timeDisplay: settings.timeDisplay
            )
            switch settings.theme {
            case .cover: CoverTheme(ctx: ctx)
            case .card: CardTheme(ctx: ctx)
            case .strip: StripTheme(ctx: ctx)
            }
        } else {
            EmptyStateView(scale: scale, denied: player.permissionDenied)
        }
    }

    private var tint: Color {
        if settings.useArtworkColor, let c = player.artworkColor { return Color(nsColor: c) }
        return Color(nsColor: settings.accentColor)
    }
}

struct PlayerContext {
    let snap: PlayerSnapshot
    let artwork: NSImage?
    let tint: Color
    let scale: CGFloat
    let showControls: Bool
    let showVolume: Bool
    let timeDisplay: TimeDisplay
}

// MARK: - Themes

/// Square artwork; title and controls fade in over it.
struct CoverTheme: View {
    let ctx: PlayerContext

    var body: some View {
        ZStack(alignment: .bottom) {
            ArtworkView(image: ctx.artwork, scale: ctx.scale)
            VStack(spacing: 6 * ctx.scale) {
                if ctx.showControls {
                    TransportControls(ctx: ctx, size: 22)
                        .padding(.bottom, 4 * ctx.scale)
                        .transition(.opacity)
                    if ctx.showVolume {
                        VolumeSlider(volume: ctx.snap.volume, tint: ctx.tint, scale: ctx.scale)
                            .padding(.horizontal, 16 * ctx.scale)
                            .transition(.opacity)
                    }
                }
                TrackLabels(track: ctx.snap.track, scale: ctx.scale, alignment: .center)
                ProgressBar(snap: ctx.snap, tint: ctx.tint, scale: ctx.scale)
            }
            .padding(12 * ctx.scale)
            .frame(maxWidth: .infinity)
            .background(Color(white: 0.08).allowsHitTesting(false))
        }
        .animation(.easeInOut(duration: 0.15), value: ctx.showControls)
    }
}

/// Artwork on top, a control panel below.
struct CardTheme: View {
    let ctx: PlayerContext

    var body: some View {
        VStack(spacing: 0) {
            ArtworkView(image: ctx.artwork, scale: ctx.scale)
                .frame(height: 220 * ctx.scale)
                .clipped()
            VStack(spacing: 6 * ctx.scale) {
                TrackLabels(track: ctx.snap.track, scale: ctx.scale, alignment: .center)
                ProgressBar(snap: ctx.snap, tint: ctx.tint, scale: ctx.scale)
                TimeLabels(snap: ctx.snap, scale: ctx.scale, mode: ctx.timeDisplay)
                TransportControls(ctx: ctx, size: 18)
                if ctx.showVolume {
                    VolumeSlider(volume: ctx.snap.volume, tint: ctx.tint, scale: ctx.scale)
                        .padding(.horizontal, 8 * ctx.scale)
                }
            }
            .padding(.horizontal, 12 * ctx.scale)
            .padding(.vertical, 8 * ctx.scale)
            .frame(maxHeight: .infinity)
            .background(ctx.tint.opacity(0.18).allowsHitTesting(false))
        }
    }
}

/// Wide horizontal strip over blurred artwork.
struct StripTheme: View {
    let ctx: PlayerContext

    var body: some View {
        ZStack {
            Color(white: 0.08)
                .allowsHitTesting(false)
            HStack(spacing: 10 * ctx.scale) {
                ArtworkView(image: ctx.artwork, scale: ctx.scale)
                    .frame(width: 68 * ctx.scale, height: 68 * ctx.scale)
                    .clipShape(RoundedRectangle(cornerRadius: 6 * ctx.scale))
                VStack(alignment: .leading, spacing: 5 * ctx.scale) {
                    if ctx.showControls {
                        TransportControls(ctx: ctx, size: 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TrackLabels(track: ctx.snap.track, scale: ctx.scale, alignment: .leading)
                    }
                    ProgressBar(snap: ctx.snap, tint: ctx.tint, scale: ctx.scale)
                    if ctx.showControls && ctx.showVolume {
                        // On hover the time labels make room for the volume slider.
                        VolumeSlider(volume: ctx.snap.volume, tint: ctx.tint, scale: ctx.scale)
                    } else {
                        TimeLabels(snap: ctx.snap, scale: ctx.scale, mode: ctx.timeDisplay)
                    }
                }
            }
            .padding(12 * ctx.scale)
        }
    }
}

// MARK: - Components

struct ArtworkView: View {
    let image: NSImage?
    let scale: CGFloat

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        LinearGradient(colors: [Color(white: 0.25), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
                        Image(systemName: "music.note")
                            .font(.system(size: min(geo.size.width, geo.size.height) * 0.3))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
    }
}

struct TrackLabels: View {
    let track: Track
    let scale: CGFloat
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(track.title)
                .font(.system(size: 13 * scale, weight: .semibold))
            Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — "))
                .font(.system(size: 11 * scale))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
        .allowsHitTesting(false)
    }
}

struct TransportControls: View {
    let ctx: PlayerContext
    let size: CGFloat
    private var player: PlayerManager { .shared }

    var body: some View {
        HStack(spacing: 18 * ctx.scale) {
            button("backward.fill", size * 0.8) { player.previous() }
            button(ctx.snap.state == .playing ? "pause.fill" : "play.fill", size) { player.playPause() }
            button("forward.fill", size * 0.8) { player.next() }
            button(ctx.snap.track.loved ? "heart.fill" : "heart", size * 0.7) {
                player.setLoved(!ctx.snap.track.loved)
            }
            .foregroundStyle(ctx.snap.track.loved ? ctx.tint : .white)
        }
        .foregroundStyle(.white)
    }

    private func button(_ symbol: String, _ pt: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: pt * ctx.scale, weight: .semibold))
                .frame(width: pt * ctx.scale * 1.6, height: pt * ctx.scale * 1.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ProgressBar: View {
    let snap: PlayerSnapshot
    let tint: Color
    let scale: CGFloat
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            GeometryReader { geo in
                let fraction = dragFraction ?? currentFraction(at: timeline.date)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(tint).frame(width: geo.size.width * fraction)
                }
                .frame(height: 4 * scale)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { dragFraction = min(1, max(0, $0.location.x / geo.size.width)) }
                        .onEnded { _ in
                            if let f = dragFraction, snap.track.duration > 0 {
                                PlayerManager.shared.seek(to: f * snap.track.duration)
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { dragFraction = nil }
                        }
                )
            }
        }
        .frame(height: 12 * scale)
    }

    private func currentFraction(at date: Date) -> Double {
        guard snap.track.duration > 0 else { return 0 }
        return min(1, snap.position(at: date) / snap.track.duration)
    }
}

/// Horizontal volume slider for the active player. Click the speaker icon to mute or unmute.
struct VolumeSlider: View {
    let volume: Int
    let tint: Color
    let scale: CGFloat
    @State private var dragValue: Double?

    private var fraction: Double { dragValue ?? Double(volume) / 100 }

    var body: some View {
        HStack(spacing: 6 * scale) {
            Button {
                PlayerManager.shared.toggleMute()
            } label: {
                Image(systemName: Self.symbol(for: fraction))
                    .font(.system(size: 10 * scale, weight: .semibold))
                    .frame(width: 16 * scale, height: 12 * scale, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.75))
            .help(volume == 0 ? "Unmute" : "Mute")

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(tint).frame(width: geo.size.width * fraction)
                }
                .frame(height: 3 * scale)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let f = min(1, max(0, g.location.x / max(1, geo.size.width)))
                            dragValue = f
                            PlayerManager.shared.setVolume(Int((f * 100).rounded()))
                        }
                        .onEnded { _ in
                            // Hold the dragged value until the next poll confirms it.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dragValue = nil }
                        }
                )
            }
        }
        .frame(height: 12 * scale)
    }

    static func symbol(for fraction: Double) -> String {
        switch fraction {
        case ..<0.01: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

struct TimeLabels: View {
    let snap: PlayerSnapshot
    let scale: CGFloat
    let mode: TimeDisplay

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let pos = snap.position(at: timeline.date)
            HStack {
                Text(Self.format(pos))
                Spacer()
                if snap.track.duration > 0 {
                    Text(mode == .remaining ? "-" + Self.format(snap.track.duration - pos) : Self.format(snap.track.duration))
                }
            }
            .font(.system(size: 10 * scale).monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
        .allowsHitTesting(false)
    }

    static func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct EmptyStateView: View {
    let scale: CGFloat
    let denied: PlayerKind?
    private var player: PlayerManager { .shared }

    var body: some View {
        VStack(spacing: 8 * scale) {
            Image(systemName: denied == nil ? "music.note" : "lock.fill")
                .font(.system(size: 26 * scale))
                .foregroundStyle(.white.opacity(0.5))
                .allowsHitTesting(false)
            if let denied {
                Text("Allow Cadence to control \(denied.displayName) in System Settings › Privacy & Security › Automation.")
                    .font(.system(size: 11 * scale))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.8))
                    .allowsHitTesting(false)
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else {
                Text("Nothing playing")
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .allowsHitTesting(false)
                HStack {
                    ForEach(PlayerKind.allCases.filter { player.isInstalled($0) }) { kind in
                        Button(kind.displayName) { player.open(kind) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(12 * scale)
    }
}

/// Transparent AppKit view behind the SwiftUI content: drags the window, opens the player on double-click.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                MainActor.assumeIsolated { PlayerManager.shared.activatePlayer() }
                return
            }
            if !AppSettings.shared.lockPosition {
                window?.performDrag(with: event)
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            MainActor.assumeIsolated { MenuBuilder.populate(menu, anchor: self) }
            return menu
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}
