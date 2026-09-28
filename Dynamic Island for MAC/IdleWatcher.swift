//
//  IdleWatcher.swift
//  Dynamic Island for MAC
//

import AppKit
import CoreGraphics
import IOKit.pwr_mgt

/// Opens the Now Playing screen once the Mac has sat untouched for the chosen
/// time while music plays, and keeps the display awake only while that is
/// useful: music playing and the feature switched on.
final class IdleWatcher {
    private let nowPlaying: NowPlayingModel
    private let screen: NowPlayingScreenController
    private let settings = AppSettings.shared

    private var loop: Task<Void, Never>?
    private var assertionID: IOPMAssertionID = 0
    private var keepsDisplayAwake = false

    init(nowPlaying: NowPlayingModel, screen: NowPlayingScreenController) {
        self.nowPlaying = nowPlaying
        self.screen = screen
    }

    func start() {
        guard loop == nil else { return }
        // Every two seconds is plenty for a timer measured in minutes.
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.check()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        setKeepsDisplayAwake(false)
    }

    private func check() {
        // Music not playing means the user isn't using this, so the Mac is
        // left to sleep on its normal schedule.
        let featureInUse = settings.idleMinutes > 0 || screen.isShowing
        setKeepsDisplayAwake(featureInUse && nowPlaying.isPlaying)

        guard settings.idleMinutes > 0,
              nowPlaying.isPlaying,
              !screen.isShowing,
              !Self.isScreenLocked
        else { return }

        if Self.secondsSinceLastInput >= Double(settings.idleMinutes * 60) {
            screen.show()
        }
    }

    /// Time since the last key press, click, scroll or mouse movement.
    /// Reading this needs no Accessibility permission.
    private static var secondsSinceLastInput: Double {
        // ~0 is "any input event".
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Opening over the lock screen would only greet the user after they
    /// unlock, so it waits.
    private static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func setKeepsDisplayAwake(_ awake: Bool) {
        guard awake != keepsDisplayAwake else { return }

        if awake {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Music is playing with the Now Playing screen enabled" as CFString,
                &assertionID
            )
            keepsDisplayAwake = result == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(assertionID)
            keepsDisplayAwake = false
        }
    }
}
