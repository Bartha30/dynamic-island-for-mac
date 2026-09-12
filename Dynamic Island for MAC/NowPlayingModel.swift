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
import SwiftUI
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
    @Published private(set) var album = ""
    @Published private(set) var albumArt: NSImage?

    /// Dominant colour of the current cover, used to tint the collapsed
    /// indicator. Nil for artwork with no usable colour (greyscale sleeves), in
    /// which case the view falls back to white.
    @Published private(set) var accentColor: Color?
    @Published private(set) var isPlaying = false

    /// Playback position and track length in seconds. `duration` is 0 when the
    /// player would not report it, which is the signal to hide the progress bar.
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0

    /// The player the current track actually came from, and therefore the one
    /// transport commands and `activate` are aimed at. Resolved by the same poll
    /// that produced the title and artist, so the controls can never end up
    /// driving a different app than the one on screen.
    @Published private(set) var activeSource: NowPlayingQuery.Source?

    /// System output volume, 0...100.
    @Published private(set) var systemVolume: Double = 50

    /// Set once a poll comes back with error -1743. The user has to grant
    /// Automation access in System Settings before we can read anything, so the
    /// pill surfaces this instead of sitting empty forever.
    @Published private(set) var permissionDenied = false

    /// True when a player is running and has a track loaded (playing or paused).
    var hasTrack: Bool { !title.isEmpty }

    private var pollTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
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
            album = ""
            isPlaying = false
            position = 0
            duration = 0
            activeSource = nil
            artworkKey = nil
            artworkTask?.cancel()
            artworkTask = nil
            albumArt = nil
            accentColor = nil
            return
        }

        title = track.title
        artist = track.artist
        album = track.album
        isPlaying = track.isPlaying
        position = max(0, track.position)
        duration = max(0, track.duration)
        activeSource = track.source

        // Deliberately keyed on the track only: position changes every tick and
        // must never trigger an artwork refetch.
        let key = "\(track.source.rawValue)\u{1F}\(track.title)\u{1F}\(track.artist)"
        guard key != artworkKey else { return }
        artworkKey = key
        loadArtwork(for: track.source, key: key)
    }

    // MARK: - Transport

    func togglePlayPause() { send(.playPause) }
    func nextTrack() { send(.next) }
    func previousTrack() { send(.previous) }

    /// Brings the player that owns the current track to the front.
    func activatePlayer() {
        guard let source = activeSource else { return }
        Task.detached(priority: .userInitiated) {
            NowPlayingQuery.activate(source)
        }
    }

    private func send(_ command: NowPlayingQuery.PlaybackCommand) {
        // No active source means no player is running or nothing is loaded, so
        // there is nothing meaningful to send the command to.
        guard let source = activeSource else { return }
        Task { [weak self] in
            await Task.detached(priority: .userInitiated) {
                NowPlayingQuery.send(command, to: source)
            }.value
            // Players react far faster than the next scheduled tick; refresh now
            // so the button does not appear to lag behind the audio.
            try? await Task.sleep(for: .milliseconds(150))
            await self?.poll()
        }
    }

    // MARK: - System volume

    /// Reads the current system output volume. Called on launch and whenever the
    /// slider comes back on screen, rather than every tick — it is a second
    /// subprocess per poll for a value that is only visible when expanded.
    func refreshSystemVolume() {
        Task { [weak self] in
            let value = await Task.detached(priority: .utility) {
                NowPlayingQuery.systemVolume()
            }.value
            guard let self, let value, self.volumeTask == nil else { return }
            self.systemVolume = value
        }
    }

    func setSystemVolume(_ value: Double) {
        // Move the slider immediately; the system catches up a beat later.
        systemVolume = value
        volumeTask?.cancel()
        volumeTask = Task { [weak self] in
            // Dragging emits continuously. Only the value the drag settles on
            // needs to reach the system, so collapse the burst into one call.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .userInitiated) {
                NowPlayingQuery.setSystemVolume(value)
            }.value
            self?.volumeTask = nil
        }
    }

    // MARK: - Artwork

    private func loadArtwork(for source: NowPlayingQuery.Source, key: String) {
        artworkTask?.cancel()
        albumArt = nil
        accentColor = nil
        // Keyed on the track, so this whole path runs once per track rather than
        // once per poll -- the accent colour is derived here and then cached in
        // `accentColor` until the track changes.
        artworkTask = Task { [weak self] in
            let payload = await Task.detached(priority: .utility) {
                () -> (data: Data?, accent: NowPlayingQuery.AccentColor?) in
                guard let full = NowPlayingQuery.artworkData(for: source) else { return (nil, nil) }
                // Cover art comes back far larger than the pill needs (Music
                // hands over 1200x1200). Shrink it here, off the main actor, so
                // we neither decode nor retain the full-size bitmap all day.
                let thumbnail = NowPlayingQuery.thumbnailData(from: full) ?? full
                return (thumbnail, NowPlayingQuery.dominantColor(from: thumbnail))
            }.value
            guard !Task.isCancelled, let self else { return }
            // A newer track may have landed while we were fetching.
            guard self.artworkKey == key else { return }
            self.albumArt = payload.data.flatMap(NSImage.init(data:))
            self.accentColor = payload.accent.map {
                Color(red: $0.red, green: $0.green, blue: $0.blue)
            }
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
        var album: String
        var isPlaying: Bool
        /// Seconds, or -1 when the player would not report it.
        var position: Double
        var duration: Double
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

    /// Text fields now sit between other fields, so a tab inside a track name
    /// would shift everything after it. This is unlikely enough in metadata to
    /// be safe as a delimiter.
    private static let fieldSeparator = "<|>"

    /// Returns the six fields below joined by `fieldSeparator`, or an empty
    /// string when stopped / nothing loaded. Only ever sent to an app we already
    /// know is running — `tell application` would otherwise launch it.
    ///
    /// Position and duration are coerced to whole seconds inside AppleScript:
    /// reals stringify with the decimal separator of the user's locale, which
    /// would not parse back reliably, and second precision is all a progress bar
    /// polled once a second can show anyway.
    private static func trackScript(for source: Source) -> String {
        // Spotify reports track length in milliseconds, Music in seconds.
        let durationExpression = source == .spotify
            ? "((duration of current track) / 1000) as integer"
            : "(duration of current track) as integer"

        return """
        tell application "\(source.rawValue)"
            if player state is stopped then return ""
            try
                set trackName to name of current track
                set trackArtist to artist of current track
            on error
                return ""
            end try
            set trackAlbum to ""
            try
                set trackAlbum to album of current track
            end try
            set pos to -1
            try
                set pos to (player position) as integer
            end try
            set dur to -1
            try
                set dur to \(durationExpression)
            end try
            return (player state as text) & "\(fieldSeparator)" & trackName ¬
                & "\(fieldSeparator)" & trackArtist & "\(fieldSeparator)" & trackAlbum ¬
                & "\(fieldSeparator)" & (pos as text) & "\(fieldSeparator)" & (dur as text)
        end tell
        """
    }

    private static func parseTrack(_ output: String, source: Source) -> Track? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fields = trimmed.components(separatedBy: fieldSeparator)
        guard fields.count == 6 else { return nil }

        let title = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        return Track(
            source: source,
            title: title,
            artist: fields[2].trimmingCharacters(in: .whitespacesAndNewlines),
            album: fields[3].trimmingCharacters(in: .whitespacesAndNewlines),
            // Music also reports "fast forwarding" / "rewinding"; both are audible.
            isPlaying: fields[0] != "paused",
            position: Double(fields[4].trimmingCharacters(in: .whitespaces)) ?? -1,
            duration: Double(fields[5].trimmingCharacters(in: .whitespaces)) ?? -1
        )
    }

    // MARK: Transport

    /// Spotify and Music happen to share these verbs, so one script covers both.
    enum PlaybackCommand: String {
        case playPause = "playpause"
        case next = "next track"
        case previous = "previous track"
    }

    static func send(_ command: PlaybackCommand, to source: Source) {
        _ = runScript("tell application \"\(source.rawValue)\" to \(command.rawValue)")
    }

    static func activate(_ source: Source) {
        _ = runScript("tell application \"\(source.rawValue)\" to activate")
    }

    // MARK: System volume

    /// `get volume settings` and `set volume` are Standard Additions commands
    /// handled inside osascript itself, not Apple Events aimed at another app,
    /// so they work without any additional Automation permission.
    static func systemVolume() -> Double? {
        guard case .success(let output) = runScript("output volume of (get volume settings)"),
              let value = Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        // Reported as -1 when the current output device cannot report a level.
        return value < 0 ? nil : Double(value)
    }

    static func setSystemVolume(_ value: Double) {
        let level = min(100, max(0, Int(value.rounded())))
        _ = runScript("set volume output volume \(level)")
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

    struct AccentColor {
        var red: Double
        var green: Double
        var blue: Double
    }

    /// Picks a tint for the collapsed indicator by binning the cover's pixels by
    /// hue and taking the heaviest bin, weighting each pixel by saturation and
    /// brightness so a small vivid detail outweighs a large muddy background.
    ///
    /// Decodes at 32x32, so it costs very little — and it runs once per track,
    /// not once per poll, because it hangs off the artwork fetch.
    static func dominantColor(from data: Data, sampleSize: Int = 32) -> AccentColor? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: sampleSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0
        else { return nil }

        let width = image.width
        let height = image.height
        let byteCount = width * height * 4

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0, count: byteCount)

        guard let context = CGContext(
            data: buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let binCount = 12
        var weights = [Double](repeating: 0, count: binCount)
        var sums = [(red: Double, green: Double, blue: Double)](
            repeating: (0, 0, 0), count: binCount
        )

        for offset in stride(from: 0, to: byteCount, by: 4) {
            let red = Double(buffer[offset]) / 255
            let green = Double(buffer[offset + 1]) / 255
            let blue = Double(buffer[offset + 2]) / 255
            let colour = hsb(red: red, green: green, blue: blue)

            // Near-black, near-white and washed-out pixels describe the sleeve's
            // background far more often than its character.
            guard colour.brightness > 0.15, colour.saturation > 0.2 else { continue }

            let weight = colour.saturation * colour.brightness
            let bin = min(binCount - 1, Int(colour.hue) / (360 / binCount))
            weights[bin] += weight
            sums[bin].red += red * weight
            sums[bin].green += green * weight
            sums[bin].blue += blue * weight
        }

        // Every pixel filtered out: a greyscale sleeve has no accent to offer.
        guard let bin = weights.indices.max(by: { weights[$0] < weights[$1] }),
              weights[bin] > 0
        else { return nil }

        let total = weights[bin]
        let average = hsb(
            red: sums[bin].red / total,
            green: sums[bin].green / total,
            blue: sums[bin].blue / total
        )

        // The pill behind it is black, so guarantee the tint reads against it.
        let boosted = rgb(
            hue: average.hue,
            saturation: max(average.saturation, 0.55),
            brightness: max(average.brightness, 0.75)
        )
        return AccentColor(red: boosted.red, green: boosted.green, blue: boosted.blue)
    }

    private static func hsb(
        red: Double, green: Double, blue: Double
    ) -> (hue: Double, saturation: Double, brightness: Double) {
        let highest = max(red, green, blue)
        let lowest = min(red, green, blue)
        let delta = highest - lowest

        var hue = 0.0
        if delta > 0 {
            if highest == red {
                hue = 60 * (((green - blue) / delta).truncatingRemainder(dividingBy: 6))
            } else if highest == green {
                hue = 60 * (((blue - red) / delta) + 2)
            } else {
                hue = 60 * (((red - green) / delta) + 4)
            }
        }
        if hue < 0 { hue += 360 }

        return (hue, highest == 0 ? 0 : delta / highest, highest)
    }

    private static func rgb(
        hue: Double, saturation: Double, brightness: Double
    ) -> (red: Double, green: Double, blue: Double) {
        let chroma = brightness * saturation
        let second = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let base = brightness - chroma

        let components: (Double, Double, Double)
        switch hue {
        case ..<60: components = (chroma, second, 0)
        case ..<120: components = (second, chroma, 0)
        case ..<180: components = (0, chroma, second)
        case ..<240: components = (0, second, chroma)
        case ..<300: components = (second, 0, chroma)
        default: components = (chroma, 0, second)
        }

        return (components.0 + base, components.1 + base, components.2 + base)
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
