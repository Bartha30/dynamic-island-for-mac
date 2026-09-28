//
//  Settings.swift
//  Dynamic Island for MAC
//

import AppKit
import Combine
import ServiceManagement
import SwiftUI

// MARK: - Stored settings

/// User preferences, saved between launches.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Minutes of inactivity before the Now Playing screen opens; 0 is off.
    static let idleOptions = [0, 1, 2, 5, 10, 15, 30, 45, 60]
    /// How far behind the audio the player's reported position runs, tuned
    /// by ear on a MacBook Air with Spotify.
    static let defaultLyricsLatency = 0.25

    @Published var idleMinutes: Int {
        didSet { UserDefaults.standard.set(idleMinutes, forKey: Keys.idleMinutes) }
    }

    /// Added to the playback position when choosing the sung line. Higher
    /// shows every song's lyrics earlier.
    @Published var lyricsLatency: Double {
        didSet { UserDefaults.standard.set(lyricsLatency, forKey: Keys.lyricsLatency) }
    }

    private enum Keys {
        static let idleMinutes = "IdleMinutes"
        static let lyricsLatency = "LyricsLatency"
    }

    private init() {
        let defaults = UserDefaults.standard
        idleMinutes = defaults.object(forKey: Keys.idleMinutes) as? Int ?? 5
        lyricsLatency = defaults.object(forKey: Keys.lyricsLatency) as? Double ?? Self.defaultLyricsLatency
    }
}

/// The system Login Items list (System Settings › General › Login Items).
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
                // macOS sometimes wants the user to approve it first.
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else {
                try service.unregister()
            }
        } catch {
            print("Launch at Login change failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Window

/// A plain window rather than SwiftUI's `Settings` scene, which an app with
/// no Dock icon or main menu has no reliable way to open.
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            hosting.sizingOptions = [.preferredContentSize]

            let window = NSWindow(contentViewController: hosting)
            window.title = "Dynamic Island Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section {
                Picker("Show after idle", selection: $settings.idleMinutes) {
                    ForEach(AppSettings.idleOptions, id: \.self) { minutes in
                        Text(idleLabel(minutes)).tag(minutes)
                    }
                }

                Text("Opens the Now Playing screen when you haven't used your Mac for this long while music is playing. While music plays the display stays awake; when it stops, your Mac sleeps as usual. You can always open it with ⌥⌘L.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Now Playing Screen")
            }

            Section {
                HStack(spacing: 10) {
                    Text("Later")
                        .foregroundStyle(.secondary)
                    Slider(value: $settings.lyricsLatency, in: -0.5...1.0, step: 0.05)
                    Text("Earlier")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text(latencyLabel)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Default") {
                        settings.lyricsLatency = AppSettings.defaultLyricsLatency
                    }
                    .disabled(abs(settings.lyricsLatency - AppSettings.defaultLyricsLatency) < 0.001)
                }

                Text("Shifts the lyrics for every song. If only one song is off, press [ or ] on the Now Playing screen while it plays instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Lyrics Timing")
            }

            Section {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        // Also fires when the window refreshes the toggle
                        // from the system on opening; only act on real changes.
                        guard enabled != LaunchAtLogin.isEnabled else { return }
                        LaunchAtLogin.setEnabled(enabled)
                    }
            } header: {
                Text("General")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    private func idleLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "Off"
        case 1: return "1 minute"
        case 60: return "1 hour"
        default: return "\(minutes) minutes"
        }
    }

    private var latencyLabel: String {
        let value = settings.lyricsLatency
        let isDefault = abs(value - AppSettings.defaultLyricsLatency) < 0.001
        return String(format: "%+.2f s", value) + (isDefault ? " (default)" : "")
    }
}
