//
//  ContentView.swift
//  Dynamic Island for MAC
//
//  Created by Bryan Arthawijaya on 12/09/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var nowPlaying = NowPlayingModel()
    @State private var isExpanded = false
    @Namespace private var pill

    private enum Metrics {
        static let collapsedSize = CGSize(width: 360, height: 35)
        static let expandedSize = CGSize(width: 510, height: 160)
        /// Leaves 5.5pt above and below inside the 35pt pill.
        static let collapsedArtwork: CGFloat = 24
        static let expandedArtwork: CGFloat = 100

        /// The notch is 32pt tall on this class of display, so expanded content
        /// starts below it — otherwise the title sits behind the cutout and
        /// reads as cropped.
        static let expandedTopPadding: CGFloat = 36
        static let expandedBottomPadding: CGFloat = 10
        static let expandedSidePadding: CGFloat = 20
        /// Gap between the artwork and the column that fills the rest of the row.
        static let expandedColumnGap: CGFloat = 18
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // One shape that grows, rather than two that cross-fade, so the
                // pill reads as the same object changing size.
                RoundedRectangle(cornerRadius: isExpanded ? 34 : 17, style: .continuous)
                    .fill(Color.black)
                    .onTapGesture { toggleExpanded() }

                if isExpanded {
                    expandedContent.transition(.opacity)
                } else {
                    collapsedContent.transition(.opacity)
                }
            }
            .frame(
                width: isExpanded ? Metrics.expandedSize.width : Metrics.collapsedSize.width,
                height: isExpanded ? Metrics.expandedSize.height : Metrics.collapsedSize.height
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
            isExpanded.toggle()
        }
        // The slider is only on screen while expanded, so this is where the
        // system value is worth re-reading.
        if isExpanded { nowPlaying.refreshSystemVolume() }
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
    }

    // MARK: - Expanded

    /// Artwork pinned left with everything else filling the rest of the row out
    /// to the right edge. Text centres itself within that remaining space rather
    /// than on the panel as a whole, which is what previously left the right
    /// side empty.
    private var expandedContent: some View {
        HStack(spacing: Metrics.expandedColumnGap) {
            artwork(size: Metrics.expandedArtwork, cornerRadius: 16)
                .onTapGesture { nowPlaying.activatePlayer() }

            VStack(spacing: 4) {
                trackDetails

                progressBar

                transportControls

                volumeSlider
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Metrics.expandedSidePadding)
        .padding(.top, Metrics.expandedTopPadding)
        .padding(.bottom, Metrics.expandedBottomPadding)
    }

    @ViewBuilder
    private var trackDetails: some View {
        if nowPlaying.permissionDenied {
            VStack(spacing: 3) {
                Text("Automation access needed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Allow this app to control Spotify and Music in System Settings › Privacy & Security › Automation.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        } else if nowPlaying.hasTrack {
            // Tapping the track, like tapping the artwork, jumps to the player.
            VStack(spacing: 2) {
                Text(nowPlaying.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { nowPlaying.activatePlayer() }
        } else {
            Text("Nothing playing")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity)
        }
    }

    private var subtitle: String {
        [nowPlaying.artist, nowPlaying.album]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    // MARK: - Progress

    @ViewBuilder
    private var progressBar: some View {
        // Hidden rather than shown empty when the player reports no duration,
        // so the row below does not jump as tracks change.
        if nowPlaying.duration > 0 {
            VStack(spacing: 6) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.18))

                        Capsule()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: geometry.size.width * progressFraction)
                    }
                }
                .frame(height: 4)

                HStack {
                    Text(timeString(nowPlaying.position))
                    Spacer(minLength: 8)
                    Text("-" + timeString(max(0, nowPlaying.duration - nowPlaying.position)))
                }
                .font(.system(size: 11, weight: .medium))
                // Monospaced digits stop the labels twitching as numbers change.
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var progressFraction: CGFloat {
        guard nowPlaying.duration > 0 else { return 0 }
        return min(1, max(0, CGFloat(nowPlaying.position / nowPlaying.duration)))
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    // MARK: - Controls

    private var transportControls: some View {
        // Scaled back from the 220pt panel: four stacked rows plus 32pt of notch
        // clearance leave roughly 114pt, which a 44pt button row overruns.
        HStack(spacing: 24) {
            transportButton("backward.fill", size: 13, target: 24, action: nowPlaying.previousTrack)
            transportButton(
                nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                size: 18,
                target: 28,
                action: nowPlaying.togglePlayPause
            )
            transportButton("forward.fill", size: 13, target: 24, action: nowPlaying.nextTrack)
        }
        .disabled(nowPlaying.activeSource == nil)
        .opacity(nowPlaying.activeSource == nil ? 0.35 : 1)
    }

    private func transportButton(
        _ symbol: String,
        size: CGFloat,
        target: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: target, height: target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var volumeSlider: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))

            Slider(
                value: Binding(
                    get: { nowPlaying.systemVolume },
                    set: { nowPlaying.setSystemVolume($0) }
                ),
                in: 0...100
            )
            .controlSize(.small)
            .tint(.white.opacity(0.85))

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
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

/// Three bars breathing at slightly different rates — a "something is playing"
/// cue for the collapsed pill, where there is no room for text.
///
/// Only ever mounted while playback is active, so a plain `onAppear` is enough
/// to start it and unmounting is what stops it.
private struct EqualizerBars: View {
    var color: Color

    @State private var animating = false

    private let bars: [(height: CGFloat, duration: Double)] = [
        (6, 0.50), (11, 0.62), (8, 0.44),
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(bars.indices, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: animating ? bars[index].height : 3)
                    .animation(
                        .easeInOut(duration: bars[index].duration).repeatForever(autoreverses: true),
                        value: animating
                    )
            }
        }
        .frame(height: 12)
        .onAppear { animating = true }
    }
}

#Preview {
    ContentView()
        .frame(width: 560, height: 220)
}
