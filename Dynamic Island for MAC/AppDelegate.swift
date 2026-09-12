//
//  AppDelegate.swift
//  Dynamic Island for MAC
//
//  Created by Bryan Arthawijaya on 12/09/26.
//

import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { return }

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
        panel.contentView = NotchHostingView(rootView: ContentView())

        panel.orderFrontRegardless()
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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
