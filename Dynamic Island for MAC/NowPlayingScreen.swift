//
//  NowPlayingScreen.swift
//  Dynamic Island for MAC
//
//  A full-screen "Now Playing" view in the style of the iPhone lock screen:
//  player on the left half, lyrics on the right half, blurred cover behind.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Controller

/// Owns the full-screen window: puts it above everything, closes it on
/// Enter / Esc, and hands focus back to whatever the user was doing.
final class NowPlayingScreenController {
    /// Called as the screen opens and closes, so the island can step aside.
    var onShow: () -> Void = {}
    var onHide: () -> Void = {}

    var isShowing: Bool { window != nil }

    private let nowPlaying: NowPlayingModel
    /// Kept for the whole app session, so lyrics are cached between openings.
    private let lyrics = LyricsModel()
    private var window: NowPlayingWindow?
    /// The app that was in front, so focus goes back there on close.
    private var previousApp: NSRunningApplication?

    init(nowPlaying: NowPlayingModel) {
        self.nowPlaying = nowPlaying
    }

    func toggle() {
        isShowing ? hide() : show()
    }

    func show() {
        guard window == nil, let screen = NSScreen.main else { return }

        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost == NSRunningApplication.current ? nil : frontmost

        let window = NowPlayingWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.setFrame(screen.frame, display: false)
        // Above the menu bar, the Dock and full-screen apps, like a screen saver.
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.onDismiss = { [weak self] in self?.hide() }
        window.onTogglePlayback = { [weak self] in self?.nowPlaying.togglePlayPause() }
        window.contentView = NSHostingView(rootView: NowPlayingScreenView(nowPlaying: nowPlaying, lyrics: lyrics))
        window.alphaValue = 0

        // The app has no Dock icon, so it has to be activated explicitly to
        // receive the keyboard — otherwise Enter and Esc go to the app behind.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            window.animator().alphaValue = 1
        }
        // Tuck the pointer away; moving the mouse brings it back for clicking.
        NSCursor.setHiddenUntilMouseMoves(true)

        self.window = window
        nowPlaying.refreshSystemVolume()
        onShow()
    }

    func hide() {
        guard let window else { return }
        self.window = nil

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            window.animator().alphaValue = 0
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            window.orderOut(nil)
        }

        previousApp?.activate(options: [])
        previousApp = nil
        onHide()
    }
}

/// Borderless windows refuse keyboard focus by default; this one takes it so
/// it can hear Enter, Esc and Space.
private final class NowPlayingWindow: NSWindow {
    var onDismiss: () -> Void = {}
    var onTogglePlayback: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape:
            onDismiss()
        case kVK_Space:
            onTogglePlayback()
        default:
            super.keyDown(with: event)
        }
    }

    /// Esc can arrive as a "cancel" action instead of a raw key press.
    override func cancelOperation(_ sender: Any?) {
        onDismiss()
    }
}

// MARK: - View

struct NowPlayingScreenView: View {
    @ObservedObject var nowPlaying: NowPlayingModel
    @ObservedObject var lyrics: LyricsModel
    /// Drag position on the progress bar, in seconds, while scrubbing.
    @State private var scrubPosition: Double?

    var body: some View {
        GeometryReader { geometry in
            // Sized off whichever runs out first, so the column never needs to
            // scroll on short or narrow displays.
            let artSize = min(geometry.size.width * 0.30, geometry.size.height * 0.46)

            ZStack {
                AlbumBackdrop(image: nowPlaying.albumArt, trackKey: nowPlaying.title + nowPlaying.artist)

                VStack(spacing: 0) {
                    clock
                        .padding(.top, max(28, geometry.size.height * 0.05))

                    // Two equal halves: player left, lyrics right.
                    HStack(spacing: 0) {
                        playerColumn(artSize: artSize)
                            .frame(width: geometry.size.width / 2)

                        LyricsView(lyrics: lyrics, nowPlaying: nowPlaying)
                            .padding(.leading, 30)
                            .frame(width: geometry.size.width / 2)
                    }
                    .frame(maxHeight: .infinity)

                    Text("Press Enter to close")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.bottom, 22)
                }
            }
        }
        .ignoresSafeArea()
        // Fetch lyrics whenever the track changes while the screen is open.
        .task(id: nowPlaying.title + "\u{1F}" + nowPlaying.artist) {
            await lyrics.load(
                title: nowPlaying.title,
                artist: nowPlaying.artist,
                album: nowPlaying.album,
                duration: nowPlaying.duration
            )
        }
    }

    // MARK: Clock

    private var clock: some View {
        TimelineView(.everyMinute) { context in
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 40, weight: .bold))
                    .monospacedDigit()
                Text(context.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.system(size: 32))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .foregroundStyle(.white)
        }
    }

    // MARK: Player (left half)

    private func playerColumn(artSize: CGFloat) -> some View {
        VStack(spacing: 26) {
            artwork(size: artSize)

            controlsCard
                .frame(width: artSize)
        }
    }

    private func artwork(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.1))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.3, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                )

            if let albumArt = nowPlaying.albumArt {
                Image(nsImage: albumArt)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
    }

    /// Track details and controls in one glass card, like the iPhone's.
    private var controlsCard: some View {
        VStack(spacing: 18) {
            trackDetails
            progressRow
            transportControls
            volumeRow
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .glassPanel(cornerRadius: 28)
    }

    @ViewBuilder
    private var trackDetails: some View {
        VStack(spacing: 4) {
            if nowPlaying.permissionDenied {
                Text("Automation access needed")
                    .font(.system(size: 20, weight: .semibold))
                Text("System Settings › Privacy & Security › Automation")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
            } else if nowPlaying.hasTrack {
                Text(nowPlaying.title)
                    .font(.system(size: 22, weight: .semibold))
                Text(nowPlaying.artist)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Text("Nothing playing")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .lineLimit(1)
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { nowPlaying.activatePlayer() }
    }

    @ViewBuilder
    private var progressRow: some View {
        if nowPlaying.duration > 0 {
            HStack(spacing: 10) {
                Text(formatTime(displayedPosition))
                    .frame(minWidth: 36, alignment: .leading)

                ScrubBar(
                    fraction: min(1, max(0, displayedPosition / nowPlaying.duration)),
                    onScrub: { scrubPosition = $0 * nowPlaying.duration },
                    onCommit: { fraction in
                        nowPlaying.seek(to: fraction * nowPlaying.duration)
                        scrubPosition = nil
                    }
                )

                Text("-" + formatTime(max(0, nowPlaying.duration - displayedPosition)))
                    .frame(minWidth: 40, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var displayedPosition: Double {
        scrubPosition ?? nowPlaying.position
    }

    private var transportControls: some View {
        HStack(spacing: 30) {
            screenButton("backward.fill", symbolSize: 17, diameter: 46, action: nowPlaying.previousTrack)
            screenButton(
                nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                symbolSize: 24,
                diameter: 60,
                tint: nowPlaying.accentColor?.opacity(0.5),
                action: nowPlaying.togglePlayPause
            )
            screenButton("forward.fill", symbolSize: 17, diameter: 46, action: nowPlaying.nextTrack)
        }
        .glassContainer(spacing: 10)
        .disabled(nowPlaying.activeSource == nil)
        .opacity(nowPlaying.activeSource == nil ? 0.35 : 1)
    }

    private func screenButton(
        _ symbol: String,
        symbolSize: CGFloat,
        diameter: CGFloat,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
                .glassCircle(tint: tint)
        }
        .buttonStyle(.plain)
    }

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
            ScrubBar(
                fraction: nowPlaying.systemVolume / 100,
                onScrub: { nowPlaying.setSystemVolume($0 * 100) },
                onCommit: { nowPlaying.setSystemVolume($0 * 100) }
            )
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.55))
    }

}

// MARK: - Backdrop

/// The cover art blown up and heavily blurred, fading between tracks.
private struct AlbumBackdrop: View {
    var image: NSImage?
    var trackKey: String

    var body: some View {
        ZStack {
            Color.black

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .blur(radius: 80)
                    .scaleEffect(1.3)
                    .saturation(1.3)
                    .id(trackKey)
                    .transition(.opacity)
            }

            // Keeps white text readable over bright covers.
            Color.black.opacity(0.35)
        }
        .clipped()
        .animation(.easeInOut(duration: 0.8), value: trackKey)
    }
}

// MARK: - Helpers

private func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, secs)
        : String(format: "%d:%02d", minutes, secs)
}

extension View {
    /// A Liquid Glass card on macOS 26, frosted material before that.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(.black.opacity(0.2)), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}
