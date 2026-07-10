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
    /// the next change to any @Observable property this reads.
    private func updateTitle() {
        withObservationTracking {
            guard let button = statusItem.button else { return }
            button.attributedTitle = NSAttributedString(
                string: model.menuTitle,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
            )
            // Compact mode carries a tiny cold→hot bar under the number,
            // echoing the panel; extended mode stays plain text.
            if model.menuBarMode == .compact, let fraction = model.temperatureFraction {
                button.image = Self.temperatureBarImage(fraction: fraction)
                button.imagePosition = .imageBelow
                button.imageHugsTitle = true
            } else {
                button.image = nil
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateTitle() }
        }
    }

    /// A 26×3 rounded bar: faint track with a fixed cold→hot gradient
    /// revealed up to `fraction`. Semantic track color resolves against
    /// the menu bar's appearance at draw time, so it adapts light/dark.
    private static func temperatureBarImage(fraction: Double) -> NSImage {
        let clamped = min(max(fraction, 0), 1)
        let image = NSImage(size: NSSize(width: 26, height: 3), flipped: false) { rect in
            let radius = rect.height / 2
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            let fillWidth = rect.width * clamped
            guard fillWidth > 0.5 else { return true }
            NSBezierPath(
                roundedRect: NSRect(x: 0, y: 0, width: fillWidth, height: rect.height),
                xRadius: radius, yRadius: radius
            ).addClip()
            NSGradient(colorsAndLocations:
                (NSColor(red: 0.35, green: 0.62, blue: 0.92, alpha: 1), 0.0),
                (NSColor(red: 0.98, green: 0.66, blue: 0.25, alpha: 1), 0.5),
                (NSColor(red: 0.90, green: 0.30, blue: 0.28, alpha: 1), 1.0)
            )?.draw(in: rect, angle: 0)
            return true
        }
        image.isTemplate = false
        return image
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
