import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
        if CommandLine.arguments.contains("--debug-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [statusBar] in
                statusBar?.togglePopover()
            }
        }
    }
}

/// AppKit-hosted status item: left click toggles the SwiftUI detail
/// popover, right click shows a context menu (display mode, unit, quit).
/// MenuBarExtra can't distinguish clicks, hence the manual hosting.
@MainActor
final class StatusBarController: NSObject {
    private let model = StatsModel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    override init() {
        super.init()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: DetailView(model: model))
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateTitle()
    }

    /// Re-arming observation: renders the title, then re-registers for
    /// the next change to any @Observable property menuTitle reads.
    private func updateTitle() {
        withObservationTracking {
            statusItem.button?.attributedTitle = NSAttributedString(
                string: model.menuTitle,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
            )
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateTitle() }
        }
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
            constrainPopoverBelowMenuBar()
        }
    }

    /// Keeps the panel's top edge inside the screen's visible frame so
    /// the menu bar / notch never clips the headline.
    private func constrainPopoverBelowMenuBar() {
        guard let window = popover.contentViewController?.view.window,
              let screen = window.screen ?? NSScreen.main else { return }
        var frame = window.frame
        let top = screen.visibleFrame.maxY
        if frame.maxY > top {
            frame.origin.y = top - frame.height
            window.setFrame(frame, display: true)
        }
        if CommandLine.arguments.contains("--debug-popover") {
            let line = "popover: \(window.frame) visible: \(screen.visibleFrame) screen: \(screen.frame)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let compact = NSMenuItem(title: "Temperature Only", action: #selector(useCompactMode), keyEquivalent: "")
        compact.state = model.menuBarMode == .compact ? .on : .off
        let extended = NSMenuItem(title: "Temperature, CPU & Memory", action: #selector(useExtendedMode), keyEquivalent: "")
        extended.state = model.menuBarMode == .extended ? .on : .off
        let fahrenheit = NSMenuItem(title: "Use Fahrenheit", action: #selector(toggleFahrenheit), keyEquivalent: "")
        fahrenheit.state = model.useFahrenheit ? .on : .off
        let launchAtLogin = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        for item in [compact, extended, fahrenheit, launchAtLogin] { item.target = self }

        menu.addItem(compact)
        menu.addItem(extended)
        menu.addItem(.separator())
        menu.addItem(fahrenheit)
        menu.addItem(launchAtLogin)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit StatsMenu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // With a menu attached, performClick pops it synchronously and
        // skips the button action; detach after so left click stays ours.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func useCompactMode() { model.menuBarMode = .compact }
    @objc private func useExtendedMode() { model.menuBarMode = .extended }
    @objc private func toggleFahrenheit() { model.useFahrenheit.toggle() }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Launch at login toggle failed: \(error.localizedDescription)")
        }
    }
}
