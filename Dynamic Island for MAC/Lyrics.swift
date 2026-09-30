//
//  Lyrics.swift
//  Dynamic Island for MAC
//
//  Time-synced lyrics from LRCLIB (lrclib.net), a free, open lyrics database.
//  Spotify and Music keep their own lyrics private, so this is the source.
//

import Combine
import SwiftUI

// MARK: - Data

nonisolated struct LyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    /// Seconds from the start of the track.
    let time: Double
    let text: String
}

// MARK: - Model

/// Loads lyrics for the current track and remembers them, so reopening the
/// screen or replaying a song never asks the server twice.
@MainActor
final class LyricsModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case synced([LyricLine])
        case plain([String])
        case instrumental
        case notFound
        case failed
    }

    @Published private(set) var state: State = .idle

    /// A timing correction for the current song only, in seconds. Positive
    /// shows lines earlier. Lyrics files are timed by hand by different
    /// people, so an occasional song runs a little early or late; the user
    /// fixes it once with [ and ] and it is remembered for that song.
    @Published private(set) var songOffset: Double = 0
    /// When `songOffset` last changed, to briefly show its value on screen.
    @Published private(set) var songOffsetChangedAt: Date?

    private static let offsetsKey = "LyricsSongOffsets"

    private var cache: [String: State] = [:]
    private var currentKey: String?
    private var lastRequest: (title: String, artist: String, album: String, duration: Double)?

    func load(title: String, artist: String, album: String, duration: Double) async {
        guard !title.isEmpty else {
            currentKey = nil
            songOffset = 0
            state = .idle
            return
        }

        let key = "\(artist)\u{1F}\(title)".lowercased()
        currentKey = key
        lastRequest = (title, artist, album, duration)
        songOffset = Self.savedOffsets()[key] ?? 0

        if let cached = cache[key] {
            state = cached
            return
        }

        state = .loading
        let result: State
        do {
            switch try await LyricsClient.fetch(title: title, artist: artist, album: album, duration: duration) {
            case .synced(let lines): result = .synced(lines)
            case .plain(let lines): result = .plain(lines)
            case .instrumental: result = .instrumental
            case .notFound: result = .notFound
            }
        } catch {
            result = .failed
        }

        // The screen closed or the track changed while we were waiting.
        guard !Task.isCancelled, currentKey == key else { return }
        // Network failures are not remembered, so the next attempt retries.
        if result != .failed { cache[key] = result }
        state = result
    }

    /// Shifts the current song's lyrics by `delta` seconds (positive: earlier)
    /// and saves it for next time.
    func nudge(by delta: Double) {
        guard let key = currentKey else { return }
        let value = ((songOffset + delta) * 10).rounded() / 10
        songOffset = min(5, max(-5, value))

        var offsets = Self.savedOffsets()
        offsets[key] = songOffset == 0 ? nil : songOffset
        UserDefaults.standard.set(offsets, forKey: Self.offsetsKey)
        songOffsetChangedAt = Date()
    }

    private static func savedOffsets() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: offsetsKey) as? [String: Double] ?? [:]
    }

    func retry() {
        guard let request = lastRequest else { return }
        Task {
            await load(title: request.title, artist: request.artist, album: request.album, duration: request.duration)
        }
    }
}

// MARK: - LRCLIB client

nonisolated enum LyricsClient {
    nonisolated enum Result {
        case synced([LyricLine])
        case plain([String])
        case instrumental
        case notFound
    }

    nonisolated private struct Record: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    nonisolated enum ClientError: Error {
        case badResponse
    }

    /// LRCLIB asks apps to identify themselves.
    private static let userAgent = "DynamicIslandForMac/1.1 (https://github.com/Bartha30/dynamic-island-for-mac)"

    static func fetch(title: String, artist: String, album: String, duration: Double) async throws -> Result {
        // An exact match needs all four details; it is the most accurate
        // because it picks the right version (album cut, radio edit, …).
        if duration > 0, !album.isEmpty,
           let record = try await getExact(title: title, artist: artist, album: album, duration: duration),
           let result = interpret(record) {
            return result
        }

        // Otherwise search, preferring timed lyrics and the closest length.
        let candidates = try await search(title: title, artist: artist)
        let best = candidates
            .filter { interpret($0) != nil }
            .min { rank($0, duration: duration) < rank($1, duration: duration) }

        // Timestamps made for a different cut of the song (radio edit, video
        // version with a longer intro…) would drift further out of sync as it
        // plays, so show those words without timing instead.
        if let best, duration > 0, let recordDuration = best.duration,
           abs(recordDuration - duration) > 5,
           case .synced(let lines)? = interpret(best) {
            return .plain(lines.map(\.text))
        }
        return best.flatMap(interpret) ?? .notFound
    }

    private static func rank(_ record: Record, duration: Double) -> Double {
        let hasSynced = !(record.syncedLyrics ?? "").isEmpty
        let lengthGap = duration > 0 ? abs((record.duration ?? 0) - duration) : 0
        return (hasSynced ? 0 : 10_000) + lengthGap
    }

    private static func interpret(_ record: Record) -> Result? {
        if record.instrumental == true { return .instrumental }
        if let synced = record.syncedLyrics, !synced.isEmpty {
            let lines = parseSynced(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = record.plainLyrics, !plain.isEmpty {
            return .plain(plain.components(separatedBy: .newlines))
        }
        return nil
    }

    // MARK: Requests

    private static func getExact(title: String, artist: String, album: String, duration: Double) async throws -> Record? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
        ]
        let (data, status) = try await request(components.url!)
        if status == 404 { return nil }
        guard status == 200 else { throw ClientError.badResponse }
        return try JSONDecoder().decode(Record.self, from: data)
    }

    private static func search(title: String, artist: String) async throws -> [Record] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        let (data, status) = try await request(components.url!)
        guard status == 200 else { throw ClientError.badResponse }
        return try JSONDecoder().decode([Record].self, from: data)
    }

    private static func request(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: LRC parsing

    /// Parses `[mm:ss.xx]text` lines. A line can carry several timestamps
    /// (a repeated chorus); tags like `[ar:Artist]` are skipped.
    static func parseSynced(_ text: String) -> [LyricLine] {
        var entries: [(time: Double, text: String)] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(rawLine)
            var times: [Double] = []

            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = parseTimestamp(tag) { times.append(time) }
                rest = rest[rest.index(after: close)...]
            }

            let words = rest.trimmingCharacters(in: .whitespaces)
            for time in times { entries.append((time, words)) }
        }

        return entries
            .sorted { $0.time < $1.time }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
    }

    private static func parseTimestamp(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1])
        else { return nil }
        return minutes * 60 + seconds
    }
}

// MARK: - View

/// The right half of the Now Playing screen.
struct LyricsView: View {
    @ObservedObject var lyrics: LyricsModel
    @ObservedObject var nowPlaying: NowPlayingModel

    var body: some View {
        Group {
            switch lyrics.state {
            case .synced(let lines):
                // Ticks ten times a second between the once-a-second player
                // polls, so a line lights up when it is sung, not up to a
                // second late.
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    SyncedLyricsList(
                        lines: lines,
                        current: currentIndex(in: lines, at: nowPlaying.livePosition(at: context.date)),
                        // Where the line really starts in this song, less a
                        // hair so its first word isn't clipped.
                        onSelect: { nowPlaying.seek(to: max(0, $0.time - lyrics.songOffset - 0.1)) }
                    )
                }

            case .plain(let lines):
                PlainLyricsList(lines: lines)

            case .loading:
                message(icon: nil, title: "Finding lyrics…")

            case .instrumental:
                message(icon: "music.note", title: "Instrumental")

            case .notFound:
                message(icon: "text.badge.xmark", title: "No lyrics found for this song")

            case .failed:
                VStack(spacing: 14) {
                    message(icon: "wifi.exclamationmark", title: "Couldn't load lyrics",
                            detail: "Check your internet connection or VPN.")
                    Button("Try Again") { lyrics.retry() }
                        .buttonStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .glassPanel(cornerRadius: 14)
                }

            case .idle:
                message(icon: "quote.bubble", title: "Play a song to see its lyrics")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { offsetBadge }
    }

    /// The line whose own timestamp has most recently passed.
    ///
    /// `lyricsLatency` (Settings, default 0.25s) is how far behind the audio
    /// the player's reported position runs: the same for every song on a
    /// given Mac, unlike the lyrics files. It is the only global adjustment;
    /// everything else comes from each song's own timestamps, plus its saved
    /// correction if the user made one. Read on every tick, so moving the
    /// slider takes effect immediately.
    private func currentIndex(in lines: [LyricLine], at position: Double) -> Int? {
        let heard = position + AppSettings.shared.lyricsLatency + lyrics.songOffset
        return lines.lastIndex { $0.time <= heard }
    }

    /// Shown for a moment after [ or ], so the user can see what changed.
    private var offsetBadge: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let visible = lyrics.songOffsetChangedAt.map { context.date.timeIntervalSince($0) < 1.8 } ?? false
            Group {
                if visible {
                    Text(offsetDescription)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .glassPanel(cornerRadius: 14)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: visible)
        }
        .padding(.bottom, 12)
    }

    private var offsetDescription: String {
        let offset = lyrics.songOffset
        if offset == 0 { return "Lyrics timing: original" }
        return String(format: "Lyrics %.1fs %@ for this song", abs(offset), offset > 0 ? "earlier" : "later")
    }

    private func message(icon: String?, title: String, detail: String? = nil) -> some View {
        VStack(spacing: 12) {
            if let icon {
                Image(systemName: icon).font(.system(size: 32))
            } else {
                ProgressView().controlSize(.small)
            }
            Text(title).font(.system(size: 20, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 14))
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white.opacity(0.5))
    }
}

/// Apple Music-style list: the sung line is bright, the rest dim and softly
/// blurred, and the list glides so the current line sits a third of the way
/// down. Click any line to jump there.
private struct SyncedLyricsList: View {
    let lines: [LyricLine]
    let current: Int?
    let onSelect: (LyricLine) -> Void

    /// The line under the pointer, lit up to show it can be clicked.
    @State private var hoveredLine: Int?

    /// Seconds since the previous line began: the song's pace right now.
    /// Fast lines get quicker animations so the list settles between them
    /// instead of never catching up; slow songs keep the full, soft timing.
    private var pace: Double {
        guard let current, current > 0 else { return 4 }
        return max(0, lines[current].time - lines[current - 1].time)
    }

    private var glideDuration: Double { min(1.0, max(0.5, pace * 0.6)) }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(lines) { line in
                            lineView(line)
                                .id(line.id)
                        }
                    }
                    // Room above and below so the first and last lines can
                    // still reach the reading position.
                    .padding(.vertical, geometry.size.height * 0.4)
                    .padding(.trailing, 60)
                }
                .onAppear { scroll(proxy, animated: false) }
                .onChange(of: current) { _ in scroll(proxy, animated: true) }
            }
        }
        // Fade lines out at the top and bottom edges.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.15),
                    .init(color: .black, location: 0.8),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func lineView(_ line: LyricLine) -> some View {
        let distance = abs(line.id - (current ?? -1))
        let isCurrent = line.id == current
        let isHovered = line.id == hoveredLine

        return Text(line.text.isEmpty ? "♪" : line.text)
            .font(.system(size: 30, weight: .bold))
            .foregroundStyle(.white.opacity(isCurrent ? 1 : (isHovered ? 0.7 : 0.32)))
            .blur(radius: isCurrent || isHovered ? 0 : min(2.5, Double(distance) * 0.6))
            .scaleEffect(isCurrent ? 1 : 0.985, anchor: .leading)
            // The new line brightens on a fast-starting curve, so it reads as
            // "on" right as the voice starts but without a hard pop; the old
            // line fades out slowly.
            .animation(isCurrent ? Animation.easeOut(duration: 0.45) : Animation.easeInOut(duration: 0.8), value: isCurrent)
            // Every other line re-blurs and re-dims as the current line moves
            // away from it; animating that stops the whole list jumping at once.
            .animation(.easeInOut(duration: 0.8), value: distance)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    hoveredLine = line.id
                } else if hoveredLine == line.id {
                    hoveredLine = nil
                }
            }
            .onTapGesture { onSelect(line) }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        let target = current ?? 0
        let anchor = UnitPoint(x: 0, y: 0.35)
        if animated {
            // A spring with no bounce, paced by the gap between this song's
            // lines. Unlike a fixed curve, a spring keeps its momentum when the
            // next line arrives mid-glide and simply bends towards it, so fast
            // songs flow instead of stopping and restarting.
            withAnimation(.spring(response: glideDuration, dampingFraction: 1.0)) {
                proxy.scrollTo(target, anchor: anchor)
            }
        } else {
            proxy.scrollTo(target, anchor: anchor)
        }
    }
}

/// Lyrics without timing: shown whole and scrollable, with a small note.
private struct PlainLyricsList: View {
    let lines: [String]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text("These lyrics aren't synced to the song")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.bottom, 8)

                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(.vertical, 80)
            .padding(.trailing, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
