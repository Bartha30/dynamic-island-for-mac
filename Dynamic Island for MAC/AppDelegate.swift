//
//  AppDelegate.swift
//  Dynamic Island for MAC
//
//  Created by Bryan Arthawijaya on 12/09/26.
//

import Carbon.HIToolbox
import Cocoa
import Combine
import ServiceManagement
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var panel: NSPanel!

    private let island = IslandState()
    /// One model shared by the island and the full-screen view, so both show
    /// the same track and only one set of player polling runs.
    private let nowPlaying = NowPlayingModel()
    private var nowPlayingScreen: NowPlayingScreenController!
    private var hotKey: GlobalHotKey?
    /// Hidden from the menu, as opposed to stepping aside for the full screen.
    private var islandHiddenByUser = false
    private var statusItem: NSStatusItem!
    private var hostingView: NotchHostingView<ContentView>!
    private var eventMonitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { return }

        // Bigger than the island in either state: SwiftUI cannot draw outside
        // its window, so the window has to have room for the expanded size.
        let panelSize = NSSize(width: 560, height: 220)
        let screenFrame = screen.frame
        let origin = NSPoint(
            x: screenFrame.origin.x + (screenFrame.width - panelSize.width) / 2,
            y: screenFrame.origin.y + screenFrame.height - panelSize.height
        )

        panel = NotchPanel(
            contentRect: NSRect(origin: origin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .mainMenu + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true
        hostingView = NotchHostingView(rootView: ContentView(nowPlaying: nowPlaying, island: island))
        hostingView.onMouseMoved = { [weak self] in self?.updateMousePassthrough() }
        panel.contentView = hostingView

        panel.orderFrontRegardless()

        nowPlaying.start()
        setUpStatusItem()
        setUpNowPlayingScreen()
        startMouseTracking()
        updateMousePassthrough()
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventMonitors.forEach(NSEvent.removeMonitor)
    }

    // MARK: - Click-through

    /// The window is much larger than the island, and a window swallows every
    /// click inside it even where it is transparent. So the window ignores the
    /// mouse entirely unless the pointer is over the island itself, letting
    /// clicks around it fall through to the menu bar and apps underneath.
    private func startMouseTracking() {
        // Watching mouse movement needs no special permission (only watching
        // the keyboard does). Global sees moves over other apps; local sees
        // moves over our own window while it is taking the mouse.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            self?.updateMousePassthrough()
        }) {
            eventMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            self?.updateMousePassthrough()
            return event
        }) {
            eventMonitors.append(monitor)
        }

        // A click that lands anywhere else collapses the expanded island, the
        // way the iPhone's does. Clicks on the island itself are local, so they
        // never arrive here.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.collapseIfExpanded()
        }) {
            eventMonitors.append(monitor)
        }

        // The island's size changes when it expands or collapses, so the
        // clickable area has to be re-checked even if the mouse stays still.
        // @Published fires before the value changes, hence the hop.
        island.$isExpanded
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateMousePassthrough() }
            }
            .store(in: &cancellables)
    }

    private func updateMousePassthrough() {
        guard let panel, panel.isVisible else { return }
        let overIsland = islandFrameOnScreen().contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == overIsland {
            panel.ignoresMouseEvents = !overIsland
        }
    }

    /// Where the island currently sits on screen: centred horizontally in the
    /// window and pinned to its top edge, matching the SwiftUI layout.
    private func islandFrameOnScreen() -> NSRect {
        let size = island.isExpanded ? IslandMetrics.expandedSize : IslandMetrics.collapsedSize
        let frame = panel.frame
        return NSRect(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func collapseIfExpanded() {
        guard island.isExpanded else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            island.isExpanded = false
        }
    }

    // MARK: - Now Playing screen

    private func setUpNowPlayingScreen() {
        nowPlayingScreen = NowPlayingScreenController(nowPlaying: nowPlaying)

        // The island steps aside while the full screen is up, and comes back
        // afterwards — unless the user had hidden it themselves.
        nowPlayingScreen.onShow = { [weak self] in
            guard let self else { return }
            self.island.isExpanded = false
            self.panel.orderOut(nil)
        }
        nowPlayingScreen.onHide = { [weak self] in
            guard let self, !self.islandHiddenByUser else { return }
            self.panel.orderFrontRegardless()
            self.updateMousePassthrough()
        }

        island.openNowPlayingScreen = { [weak self] in
            self?.nowPlayingScreen.show()
        }

        // ⌥⌘L from any app. Nil if another app already uses that shortcut.
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.nowPlayingScreen.toggle()
        }
    }

    @objc private func openNowPlayingScreen() {
        nowPlayingScreen.show()
    }

    // MARK: - Menu bar

    /// The app has no Dock icon or menu of its own, so this icon is the only
    /// way to hide the island or quit.
    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Dynamic Island")
            // Template images take the menu bar's colour in light and dark mode.
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // On notched MacBooks a crowded menu bar hides extra icons behind the
        // notch, so the same menu is also on a right-click of the island.
        hostingView.rightClickMenu = menu
    }

    /// Rebuilt every time it opens, so titles and checkmarks are never stale.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let screen = NSMenuItem(
            title: "Now Playing Screen",
            action: #selector(openNowPlayingScreen),
            keyEquivalent: "l"
        )
        // Shown in the menu as ⌥⌘L to advertise the shortcut.
        screen.keyEquivalentModifierMask = [.command, .option]
        screen.target = self
        menu.addItem(screen)

        menu.addItem(.separator())

        let visibility = NSMenuItem(
            title: islandHiddenByUser ? "Show Island" : "Hide Island",
            action: #selector(toggleIslandVisibility),
            keyEquivalent: ""
        )
        visibility.target = self
        menu.addItem(visibility)

        let login = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Dynamic Island",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)
    }

    @objc private func toggleIslandVisibility() {
        islandHiddenByUser.toggle()
        if islandHiddenByUser {
            island.isExpanded = false
            panel.orderOut(nil)
        } else if !nowPlayingScreen.isShowing {
            panel.orderFrontRegardless()
            updateMousePassthrough()
        }
    }

    /// Uses the system Login Items list (System Settings › General › Login
    /// Items), so the user can also switch it off there.
    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                // macOS sometimes wants the user to approve it first.
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            print("Launch at Login change failed: \(error.localizedDescription)")
        }
    }
}

/// A borderless window cannot become key by default, which leaves the panel
/// unable to take clicks at all.
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The app is an accessory and the panel is non-activating, so it is never the
/// active app — meaning every click is a "first mouse" click. Without this, the
/// first click on any control is spent activating the window instead of being
/// delivered, and tap-to-expand would need a second click to register.
private final class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// Called whenever the pointer moves over, or leaves, the window.
    var onMouseMoved: (() -> Void)?
    /// Shown when the island is right-clicked.
    var rightClickMenu: NSMenu?
    private var moveTracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// macOS normally only reports mouse movement to the active window, which
    /// this never is. `.activeAlways` gets the reports anyway, so the window
    /// notices the pointer leaving the island and can go back to letting
    /// clicks through.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let moveTracking { removeTrackingArea(moveTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        moveTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMoved?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let rightClickMenu else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(rightClickMenu, with: event, for: self)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseMoved?()
    }
}
