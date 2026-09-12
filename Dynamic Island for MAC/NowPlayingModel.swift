//
//  NowPlayingModel.swift
//  Dynamic Island for MAC
//
//  Created by Bryan Arthawijaya on 12/09/26.
//

import AppKit
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Polls whichever supported player is running for its current track.
///
/// MediaRemote — the private framework most "now playing" apps used to read —
/// stopped vending track info to third-party processes in macOS 15.4, so this
/// asks Spotify and Music directly over AppleScript instead.
@MainActor
final class NowPlayingModel: ObservableObject {
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var albumArt: NSImage?
    @Published private(set) var isPlaying = false

    /// Set once a poll comes back with error -1743. The user has to grant
    /// Automation access in System Settings before we can read anything, so the
    /// pill surfaces this instead of sitting empty forever.
    @Published private(set) var permissionDenied = false

    /// True when a player is running and has a track loaded (playing or paused).
    var hasTrack: Bool { !title.isEmpty }

    private var pollTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    /// Identifies the loaded track so we only refetch artwork when it changes.
    private var artworkKey: String?

    private let pollInterval: Duration = .seconds(1)

    deinit {
        pollTask?.cancel()
        artworkTask?.cancel()
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(1))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        artworkTask?.cancel()
        artworkTask = nil
    }

    // MARK: - Polling

    /// One poll cycle. The AppleScript runs off the main actor; only the
    /// resulting snapshot comes back to update published state.
    private func poll() async {
        let snapshot = await Task.detached(priority: .utility) {
            NowPlayingQuery.currentSnapshot()
        }.value
        apply(snapshot)
    }

    private func apply(_ snapshot: NowPlayingQuery.Snapshot) {
        permissionDenied = snapshot.permissionDenied

        // Neither player running, nothing loaded, or we were denied access:
        // clear out rather than leaving a stale track on screen.
        guard let track = snapshot.track else {
            title = ""
            artist = ""
            isPlaying = false
            artworkKey = nil
            artworkTask?.cancel()
            artworkTask = nil
            albumArt = nil
            return
        }

        title = track.title
        artist = track.artist
        isPlaying = track.isPlaying

        let key = "\(track.source.rawValue)\u{1F}\(track.title)\u{1F}\(track.artist)"
        guard key != artworkKey else { return }
        artworkKey = key
        loadArtwork(for: track.source, key: key)
    }

    // MARK: - Artwork

    private func loadArtwork(for source: NowPlayingQuery.Source, key: String) {
        artworkTask?.cancel()
        albumArt = nil
        artworkTask = Task { [weak self] in
            let data = await Task.detached(priority: .utility) { () -> Data? in
                guard let full = NowPlayingQuery.artworkData(for: source) else { return nil }
                // Cover art comes back far larger than the pill needs (Music
                // hands over 1200x1200). Shrink it here, off the main actor, so
                // we neither decode nor retain the full-size bitmap all day.
                return NowPlayingQuery.thumbnailData(from: full) ?? full
            }.value
            guard !Task.isCancelled, let self else { return }
            // A newer track may have landed while we were fetching.
            guard self.artworkKey == key else { return }
            self.albumArt = data.flatMap(NSImage.init(data:))
        }
    }
}

// MARK: - AppleScript bridge

/// Everything that talks to the players.
///
/// Explicitly `nonisolated`: the target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without this the blocking
/// `osascript` calls below would hop back onto the main actor and stall the
/// panel for as long as a player takes to answer.
nonisolated enum NowPlayingQuery {
    enum Source: String {
        case spotify = "Spotify"
        case music = "Music"

        var bundleIdentifier: String {
            switch self {
            case .spotify: return "com.spotify.client"
            case .music: return "com.apple.Music"
            }
        }
    }

    struct Track {
        var source: Source
        var title: String
        var artist: String
        var isPlaying: Bool
    }

    struct Snapshot {
        /// nil when no player is running, nothing is loaded, or access was denied.
        var track: Track?
        var permissionDenied = false
    }

    /// Spotify wins if both are running, on the assumption that the app you
    /// launched most recently is the one you are listening to. Cheap enough to
    /// re-evaluate every second.
    private static func runningSources() -> [Source] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return [Source.spotify, .music].filter { running.contains($0.bundleIdentifier) }
    }

    static func currentSnapshot() -> Snapshot {
        var deniedAnywhere = false

        for source in runningSources() {
            switch runScript(trackScript(for: source)) {
            case .success(let output):
                guard let track = parseTrack(output, source: source) else { continue }
                return Snapshot(track: track)
            case .failure(.permissionDenied):
                deniedAnywhere = true
            case .failure:
                // App quit mid-poll, was busy launching, or returned something
                // we could not read — try the next one and pick it up next tick.
                continue
            }
        }

        return Snapshot(track: nil, permissionDenied: deniedAnywhere)
    }

    // MARK: Scripts

    /// Returns "<player state>\t<name>\t<artist>", or an empty string when
    /// stopped / nothing loaded. Only ever sent to an app we already know is
    /// running — `tell application` would otherwise launch it.
    private static func trackScript(for source: Source) -> String {
        """
        tell application "\(source.rawValue)"
            if player state is stopped then return ""
            try
                set trackName to name of current track
                set trackArtist to artist of current track
                return (player state as text) & tab & trackName & tab & trackArtist
            on error
                return ""
            end try
        end tell
        """
    }

    private static func parseTrack(_ output: String, source: Source) -> Track? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // maxSplits keeps tabs inside an artist name from splitting the field.
        let fields = trimmed.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }

        let title = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        return Track(
            source: source,
            title: title,
            artist: String(fields[2]).trimmingCharacters(in: .whitespacesAndNewlines),
            // Music also reports "fast forwarding" / "rewinding"; both are audible.
            isPlaying: String(fields[0]) != "paused"
        )
    }

    // MARK: Artwork

    /// Returns encoded image bytes rather than an `NSImage`, since `NSImage`
    /// only became `Sendable` in macOS 14 and this crosses an actor boundary.
    static func artworkData(for source: Source) -> Data? {
        switch source {
        case .spotify:
            // Spotify hands back a URL rather than image data.
            guard case .success(let output) = runScript(spotifyArtworkScript()) else { return nil }
            let urlString = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else { return nil }
            return try? Data(contentsOf: url)

        case .music:
            // Music vends raw bytes, which survive the trip out of osascript far
            // better through a temp file than as text.
            let path = NSTemporaryDirectory().appending("dynamic-island-artwork")
            defer { try? FileManager.default.removeItem(atPath: path) }
            guard case .success(let output) = runScript(musicArtworkScript(path: path)),
                  output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else { return nil }
            return FileManager.default.contents(atPath: path)
        }
    }

    /// Downsamples encoded image bytes to a pill-sized PNG. ImageIO decodes
    /// straight to the thumbnail, so the full-size bitmap never materialises.
    static func thumbnailData(from data: Data, maxPixelSize: Int = 128) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return output as Data
    }

    private static func spotifyArtworkScript() -> String {
        """
        tell application "Spotify"
            if player state is stopped then return ""
            try
                return artwork url of current track
            on error
                return ""
            end try
        end tell
        """
    }

    private static func musicArtworkScript(path: String) -> String {
        """
        tell application "Music"
            if player state is stopped then return ""
            try
                if (count of artworks of current track) is 0 then return ""
                set artData to raw data of artwork 1 of current track
            on error
                return ""
            end try
        end tell
        set outFile to (POSIX file "\(path)")
        try
            set fileRef to open for access outFile with write permission
            set eof fileRef to 0
            write artData to fileRef
            close access fileRef
        on error
            try
                close access outFile
            end try
            return ""
        end try
        return "ok"
        """
    }

    // MARK: osascript

    enum ScriptError: Error {
        case permissionDenied
        case failed(String)
        case timedOut
    }

    /// Runs through `osascript` in a subprocess rather than `NSAppleScript`.
    /// `NSAppleScript` has to run on the main thread, and a player that is busy
    /// or wedged would freeze the panel with it; a subprocess we can just kill.
    private static func runScript(_ source: String, timeout: TimeInterval = 3) -> Result<String, ScriptError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failure(.failed(error.localizedDescription))
        }

        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        // Output is a line or two, so it cannot fill the pipe buffer and deadlock.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let timedOut = killer.isCancelled == false && process.terminationReason == .uncaughtSignal
        killer.cancel()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self)
            // -1743 is "not authorized to send Apple events", i.e. the user has
            // not granted (or has revoked) Automation access for this app.
            if message.contains("-1743") || message.localizedCaseInsensitiveContains("not authorized") {
                return .failure(.permissionDenied)
            }
            return .failure(timedOut ? .timedOut : .failed(message))
        }

        return .success(String(decoding: outData, as: UTF8.self))
    }
}
