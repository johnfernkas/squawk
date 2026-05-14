import AppKit
import SwiftUI
import UserNotifications

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var aboutWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var globalKeyMonitor: Any?
    let monitor = MCPMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }

        setupStatusItem()
        setupPopover()

        monitor.onStatusChange = { [weak self] in
            self?.updateStatusIcon()
        }

        monitor.loadConfig()
        monitor.startPolling()
        monitor.startFileWatching()
        setupGlobalHotkey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stopPolling()
        monitor.stopFileWatching()
        if let monitor = globalKeyMonitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }
        let image = NSImage(
            systemSymbolName: "antenna.radiowaves.left.and.right.circle.fill",
            accessibilityDescription: "Squawk")
        button.image = image
        button.action = #selector(statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 500)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(monitor: monitor))
        self.popover = popover
    }

    // MARK: - Actions

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            monitor.popoverOpenCount += 1
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let aboutItem = NSMenuItem(title: "About Squawk", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Squawk", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openAbout() {
        if let aboutWindow, aboutWindow.isVisible {
            aboutWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Squawk"
        window.contentView = NSHostingView(rootView: AboutView())
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.aboutWindow = window
    }

    @objc private func openSettings() {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Squawk Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Global Hotkey

    private func setupGlobalHotkey() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains([.command, .shift]),
                  event.charactersIgnoringModifiers?.lowercased() == "m" else { return }
            DispatchQueue.main.async { self?.togglePopover() }
        }
    }

    // MARK: - Status Icon

    func updateStatusIcon() {
        guard let button = statusItem?.button else { return }

        let symbolName: String
        let isTemplate: Bool
        let tintColor: NSColor?

        if monitor.servers.isEmpty {
            symbolName = "antenna.radiowaves.left.and.right.circle"
            isTemplate = true
            tintColor = nil
        } else if monitor.overallHealthy {
            symbolName = "antenna.radiowaves.left.and.right.circle"
            isTemplate = true
            tintColor = nil
        } else if monitor.allDown {
            symbolName = "antenna.radiowaves.left.and.right.slash.circle.fill"
            isTemplate = false
            tintColor = .systemRed
        } else {
            symbolName = "antenna.radiowaves.left.and.right.circle"
            isTemplate = false
            tintColor = .systemYellow
        }

        let sizeConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let config: NSImage.SymbolConfiguration
        if monitor.allDown {
            // White antenna on red filled circle
            config = sizeConfig.applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed]))
        } else if let tintColor {
            // Single tint color for outline variant
            config = sizeConfig.applying(NSImage.SymbolConfiguration(paletteColors: [tintColor]))
        } else {
            config = sizeConfig
        }

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Squawk")?
            .withSymbolConfiguration(config)
        {
            image.isTemplate = isTemplate
            button.image = image
        }

        animateStatusIcon()
    }

    private func animateStatusIcon() {
        guard let button = statusItem?.button,
              let imageView = button.subviews.compactMap({ $0 as? NSImageView }).first
        else { return }

        imageView.removeAllSymbolEffects()

        if monitor.allDown {
            imageView.addSymbolEffect(.pulse.wholeSymbol, options: .repeating)
        }
    }
}
