//
//  ContentView.swift
//  Dynamic Island for MAC
//
//  Created by Bryan Arthawijaya on 12/09/26.
//

import Combine
import SwiftUI

/// The island's outer size in each state. Shared with `AppDelegate`, which
/// needs it to know where clicks should land on the island and where they
/// should pass through to whatever is underneath.
enum IslandMetrics {
    static let collapsedSize = CGSize(width: 300, height: 36)
    static let expandedSize = CGSize(width: 450, height: 160)
}

/// State the app delegate and the view both touch: the delegate collapses the
/// island on outside clicks and reads its size for click-through.
final class IslandState: ObservableObject {
    @Published var isExpanded = false
}

struct ContentView: View {
    @StateObject private var nowPlaying = NowPlayingModel()
    @ObservedObject var island: IslandState
    /// Where the user is dragging the progress bar to, in seconds. Non-nil only
    /// mid-drag; while set, it replaces the polled position on screen so the
    /// bar follows the finger instead of snapping back every tick.
    @State private var scrubPosition: Double?
    @Namespace private var pill

    private enum Metrics {
        // Outer sizes live in `IslandMetrics` at the top of this file.
        /// Leaves 6pt above and below inside the 36pt pill.
        static let collapsedArtwork: CGFloat = 24
        static let expandedArtwork: CGFloat = 92

        /// The notch is 32pt tall on this class of display, so expanded content
        /// starts below it — otherwise the title sits behind the cutout and
        /// reads as cropped.
        static let expandedTopPadding: CGFloat = 36
        static let expandedBottomPadding: CGFloat = 12
        static let expandedSidePadding: CGFloat = 20
        /// Gap between the artwork and the column that fills the rest of the row.
        static let expandedColumnGap: CGFloat = 16
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // One shape that grows, rather than two that cross-fade, so the
                // pill reads as the same object changing size.
                RoundedRectangle(cornerRadius: island.isExpanded ? 34 : 17, style: .continuous)
                    .fill(Color.black)
                    .overlay { ambientGlow }
                    .clipShape(RoundedRectangle(cornerRadius: island.isExpanded ? 34 : 17, style: .continuous))
                    .animation(.easeInOut(duration: 0.6), value: nowPlaying.accentColor)
                    .onTapGesture { toggleExpanded() }

                if island.isExpanded {
                    expandedContent.transition(.opacity)
                } else {
                    collapsedContent.transition(.opacity)
                }
            }
            .frame(
                width: island.isExpanded ? IslandMetrics.expandedSize.width : IslandMetrics.collapsedSize.width,
                height: island.isExpanded ? IslandMetrics.expandedSize.height : IslandMetrics.collapsedSize.height
            )

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            nowPlaying.start()
            nowPlaying.refreshSystemVolume()
        }
    }

    private func toggleExpanded() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            island.isExpanded.toggle()
        }
        // Collapsing mid-drag unmounts the bar before the drag can end.
        scrubPosition = nil
        // The slider is only on screen while expanded, so this is where the
        // system value is worth re-reading.
        if island.isExpanded { nowPlaying.refreshSystemVolume() }
    }

    /// A soft wash of the cover's colour rising from behind the artwork. Kept
    /// low and to the left so the top edge stays black and still blends into
    /// the physical notch.
    @ViewBuilder
    private var ambientGlow: some View {
        if island.isExpanded, let accent = nowPlaying.accentColor {
            RadialGradient(
                colors: [accent.opacity(0.34), accent.opacity(0.10), .clear],
                center: UnitPoint(x: 0.12, y: 0.9),
                startRadius: 0,
                endRadius: 300
            )
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Collapsed

    /// Artwork and a playing indicator pushed to opposite ends, so both sit
    /// clear of the physical notch between them. A tap anywhere expands,
    /// including on the artwork, which would otherwise be the only target and
    /// would leave no way to open the panel.
    private var collapsedContent: some View {
        HStack(spacing: 0) {
            artwork(size: Metrics.collapsedArtwork, cornerRadius: 5)

            Spacer(minLength: 12)

            Group {
                if nowPlaying.permissionDenied {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange.opacity(0.9))
                } else if nowPlaying.isPlaying {
                    EqualizerBars(color: nowPlaying.accentColor ?? .white.opacity(0.85))
                } else {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 14)
        }
        .padding(.horizontal, 14)
        // The artwork and indicator sit in front of the black shape and would
        // otherwise swallow the tap, so the whole row takes it and expands.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { toggleExpanded() }
    }

    // MARK: - Expanded

    /// Artwork on the left; to its right, a left-aligned column of track
    /// details, progress, then controls with volume tucked on the same row.
    private var expandedContent: some View {
        HStack(alignment: .center, spacing: Metrics.expandedColumnGap) {
            artwork(size: Metrics.expandedArtwork, cornerRadius: 18)
                // The cover casts light in its own colour onto the panel.
                .shadow(color: (nowPlaying.accentColor ?? .black).opacity(0.45), radius: 14, y: 4)
                .onTapGesture { nowPlaying.activatePlayer() }

            VStack(alignment: .leading, spacing: 9) {
                trackHeader

                progressRow

                HStack(spacing: 12) {
                    transportControls
                    Spacer(minLength: 0)
                    volumeControl
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Metrics.expandedSidePadding)
        .padding(.top, Metrics.expandedTopPadding)
        .padding(.bottom, Metrics.expandedBottomPadding)
    }

    @ViewBuilder
    private var trackHeader: some View {
        if nowPlaying.permissionDenied {
            VStack(alignment: .leading, spacing: 3) {
                Text("Automation access needed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Allow this app to control Spotify and Music in System Settings › Privacy & Security › Automation.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if nowPlaying.hasTrack {
            HStack(alignment: .top, spacing: 10) {
                // Tapping the track, like tapping the artwork, jumps to the player.
                VStack(alignment: .leading, spacing: 2) {
                    Text(nowPlaying.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { nowPlaying.activatePlayer() }

                Spacer(minLength: 0)

                if nowPlaying.isPlaying {
                    EqualizerBars(color: nowPlaying.accentColor ?? .white.opacity(0.85), scale: 1.4)
                        .padding(.top, 2)
                }
            }
        } else {
            Text("Nothing playing")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var subtitle: String {
        [nowPlaying.artist, nowPlaying.album]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    // MARK: - Progress

    /// Elapsed and remaining time sit either side of the bar on one line,
    /// rather than on a row of their own underneath.
    @ViewBuilder
    private var progressRow: some View {
        // Hidden rather than shown empty when the player reports no duration.
        if nowPlaying.duration > 0 {
            HStack(spacing: 8) {
                Text(timeString(displayedPosition))
                    .frame(minWidth: 30, alignment: .leading)

                ScrubBar(
                    fraction: progressFraction,
                    onScrub: { scrubPosition = $0 * nowPlaying.duration },
                    onCommit: { fraction in
                        nowPlaying.seek(to: fraction * nowPlaying.duration)
                        scrubPosition = nil
                    }
                )

                Text("-" + timeString(max(0, nowPlaying.duration - displayedPosition)))
                    .frame(minWidth: 34, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .medium))
            // Monospaced digits stop the labels twitching as numbers change.
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    /// The drag position while scrubbing, otherwise what the player reports.
    private var displayedPosition: Double {
        scrubPosition ?? nowPlaying.position
    }

    private var progressFraction: Double {
        guard nowPlaying.duration > 0 else { return 0 }
        return min(1, max(0, displayedPosition / nowPlaying.duration))
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    // MARK: - Controls

    /// Liquid Glass buttons on macOS 26; plain translucent circles before that.
    /// Play/pause is larger and tinted with the cover's colour.
    private var transportControls: some View {
        HStack(spacing: 12) {
            transportButton("backward.fill", symbolSize: 11, diameter: 28, action: nowPlaying.previousTrack)
            transportButton(
                nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                symbolSize: 15,
                diameter: 34,
                tint: nowPlaying.accentColor?.opacity(0.5),
                action: nowPlaying.togglePlayPause
            )
            transportButton("forward.fill", symbolSize: 11, diameter: 28, action: nowPlaying.nextTrack)
        }
        .glassContainer(spacing: 8)
        .disabled(nowPlaying.activeSource == nil)
        .opacity(nowPlaying.activeSource == nil ? 0.35 : 1)
    }

    private func transportButton(
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

    /// Same bar as the progress scrubber, so the two read as one design.
    private var volumeControl: some View {
        HStack(spacing: 7) {
            Image(systemName: volumeSymbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 16, alignment: .leading)

            ScrubBar(
                fraction: nowPlaying.systemVolume / 100,
                onScrub: { nowPlaying.setSystemVolume($0 * 100) },
                onCommit: { nowPlaying.setSystemVolume($0 * 100) }
            )
        }
        .frame(width: 120)
    }

    private var volumeSymbol: String {
        switch nowPlaying.systemVolume {
        case ..<1: return "speaker.slash.fill"
        case ..<34: return "speaker.wave.1.fill"
        case ..<67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    // MARK: - Artwork

    /// Shared between both states so `matchedGeometryEffect` can fly the same
    /// artwork between the thumbnail and the full-size cover.
    private func artwork(size: CGFloat, cornerRadius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.12))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                )

            if let albumArt = nowPlaying.albumArt {
                Image(nsImage: albumArt)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        )
        .matchedGeometryEffect(id: "artwork", in: pill)
    }
}

// MARK: - Scrub bar

/// A thin draggable bar with a round handle, used for both song position and
/// volume. Click anywhere to jump; drag to scrub. `onScrub` fires throughout
/// the drag and `onCommit` once on release, both with a 0...1 fraction.
private struct ScrubBar: View {
    var fraction: Double
    var onScrub: (Double) -> Void
    var onCommit: (Double) -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let filled = CGFloat(min(1, max(0, fraction)))
            let knobSize: CGFloat = isDragging ? 13 : 9

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))

                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: width * filled)

                Circle()
                    .fill(Color.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.35), radius: 1.5)
                    .offset(x: width * filled - knobSize / 2)
            }
            // Thickens while held so it is obvious the bar has been grabbed.
            .frame(height: isDragging ? 6 : 4)
            .animation(.easeOut(duration: 0.15), value: isDragging)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            // Zero minimum distance so a plain click jumps as well as a drag.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        onScrub(Self.clampedFraction(atX: value.location.x, width: width))
                    }
                    .onEnded { value in
                        isDragging = false
                        onCommit(Self.clampedFraction(atX: value.location.x, width: width))
                    }
            )
        }
        // A 4pt bar is too thin to grab, so the touch area is 16pt tall. The
        // negative padding hands the extra 12pt back to the layout, which has
        // no room to spare below the notch.
        .frame(height: 16)
        .padding(.vertical, -6)
    }

    private static func clampedFraction(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(1, max(0, x / width)))
    }
}

// MARK: - Liquid Glass

private extension View {
    /// Groups glass shapes so they are rendered together and can blend into
    /// each other when close. No-op before macOS 26.
    @ViewBuilder
    func glassContainer(spacing: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    /// Liquid Glass circle behind a control on macOS 26, falling back to a
    /// translucent fill on older systems so the app still runs there.
    @ViewBuilder
    func glassCircle(tint: Color?) -> some View {
        if #available(macOS 26.0, *) {
            let glass: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            self.glassEffect(glass.interactive(), in: Circle())
        } else {
            self.background(Circle().fill((tint ?? .white).opacity(0.16)))
        }
    }
}

// MARK: - Equalizer

/// Three bars breathing at slightly different rates — a "something is playing"
/// cue. `scale` enlarges it for the expanded panel.
///
/// Only ever mounted while playback is active, so a plain `onAppear` is enough
/// to start it and unmounting is what stops it.
private struct EqualizerBars: View {
    var color: Color
    var scale: CGFloat = 1

    @State private var animating = false

    private let bars: [(height: CGFloat, duration: Double)] = [
        (6, 0.50), (11, 0.62), (8, 0.44),
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 2 * scale) {
            ForEach(bars.indices, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 2 * scale, height: (animating ? bars[index].height : 3) * scale)
                    .animation(
                        .easeInOut(duration: bars[index].duration).repeatForever(autoreverses: true),
                        value: animating
                    )
            }
        }
        .frame(height: 12 * scale)
        .onAppear { animating = true }
    }
}

#Preview {
    ContentView(island: IslandState())
        .frame(width: 560, height: 220)
}
