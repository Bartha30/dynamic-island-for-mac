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

    private var cache: [String: State] = [:]
    private var currentKey: String?
    private var lastRequest: (title: String, artist: String, album: String, duration: Double)?

    func load(title: String, artist: String, album: String, duration: Double) async {
        guard !title.isEmpty else {
            currentKey = nil
            state = .idle
            return
        }

        let key = "\(artist)\u{1F}\(title)".lowercased()
        currentKey = key
        lastRequest = (title, artist, album, duration)

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
                        // A hair before the line, so its first word isn't clipped.
                        onSelect: { nowPlaying.seek(to: max(0, $0.time - 0.1)) }
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
    }

    /// How early a line lights up. The highlight animation takes a moment
    /// to read as "on", so starting it slightly early makes it land with the
    /// voice rather than a beat behind it.
    private static let leadTime = 0.65

    /// The last line whose start time has passed, allowing for `leadTime`.
    private func currentIndex(in lines: [LyricLine], at position: Double) -> Int? {
        lines.lastIndex { $0.time <= position + Self.leadTime }
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
            .scaleEffect(isCurrent ? 1 : 0.96, anchor: .leading)
            // A soft crossfade between lines rather than a hard switch.
            .animation(.easeInOut(duration: 0.45), value: isCurrent)
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
            // A slow, even glide with no bounce at the end.
            withAnimation(.easeInOut(duration: 0.8)) {
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
