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
            // Compact mode draws the number and a tiny cold→hot bar as one
            // centered image (echoing the panel); extended stays plain text.
            if model.menuBarMode == .compact {
                button.attributedTitle = NSAttributedString(string: "")
                button.image = Self.compactImage(
                    text: model.compactTemperatureText,
                    fraction: model.temperatureFraction
                )
                button.imagePosition = .imageOnly
            } else {
                button.image = nil
                button.imagePosition = .noImage
                button.attributedTitle = NSAttributedString(
                    string: model.menuTitle,
                    attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
                )
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateTitle() }
        }
    }

    /// Compact menu bar content: the number centered over a 26×3 cold→hot
    /// gradient bar, composed as one image so both share a center. Text and
    /// track use semantic colors resolved at draw time, so they adapt to
    /// the menu bar's light/dark appearance.
    private static func compactImage(text: String, fraction: Double?) -> NSImage {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let barWidth: CGFloat = 26
        let barHeight: CGFloat = 3
        let gap: CGFloat = 3
        let width = ceil(max(textSize.width, barWidth))
        let height: CGFloat = 22
        let clamped = fraction.map { min(max($0, 0), 1) }

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let groupHeight = textSize.height + gap + barHeight
            let bottom = ((height - groupHeight) / 2).rounded()

            let barRect = NSRect(x: (width - barWidth) / 2, y: bottom, width: barWidth, height: barHeight)
            let radius = barHeight / 2
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius).fill()
            if let fraction = clamped, fraction > 0 {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(
                    roundedRect: NSRect(x: barRect.minX, y: barRect.minY, width: barRect.width * fraction, height: barHeight),
                    xRadius: radius, yRadius: radius
                ).addClip()
                NSGradient(colorsAndLocations:
                    (NSColor(red: 0.35, green: 0.62, blue: 0.92, alpha: 1), 0.0),
                    (NSColor(red: 0.98, green: 0.66, blue: 0.25, alpha: 1), 0.5),
                    (NSColor(red: 0.90, green: 0.30, blue: 0.28, alpha: 1), 1.0)
                )?.draw(in: barRect, angle: 0)
                NSGraphicsContext.restoreGraphicsState()
            }

            (text as NSString).draw(
                at: NSPoint(x: (width - textSize.width) / 2, y: bottom + barHeight + gap),
                withAttributes: [.font: font, .foregroundColor: NSColor.labelColor]
            )
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
