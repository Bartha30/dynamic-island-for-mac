//
//  ContentView.swift
//  Dynamic Island for MAC
//
//  Created by Bryan Arthawijaya on 12/09/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var nowPlaying = NowPlayingModel()

    /// The pill sits at its resting size until there is something to say.
    private var pillWidth: CGFloat {
        if nowPlaying.permissionDenied { return 320 }
        return nowPlaying.hasTrack ? 340 : 220
    }

    var body: some View {
        VStack {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black)

                pillContent
                    .padding(.horizontal, 14)
            }
            .frame(width: pillWidth, height: 36)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: pillWidth)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .onAppear { nowPlaying.start() }
    }

    @ViewBuilder
    private var pillContent: some View {
        if nowPlaying.permissionDenied {
            Text("Allow Automation access in System Settings")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        } else if nowPlaying.hasTrack {
            HStack(spacing: 8) {
                Image(systemName: nowPlaying.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text(nowPlaying.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if !nowPlaying.artist.isEmpty {
                        Text(nowPlaying.artist)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 380, height: 160)
}
