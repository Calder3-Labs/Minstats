import AppKit
import MinStatsProtocol
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // An LSUIElement app never gets a main menu — but ⌘V/⌘C/⌘X/⌘A/⌘Z
        // still ROUTE through NSApp.mainMenu's key equivalents, so without
        // this invisible Edit menu, paste into any text field (the webhook
        // endpoint, most painfully) only works via right-click.
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu

        statusBar = StatusBarController()
        if CommandLine.arguments.contains("--debug-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [statusBar] in
                statusBar?.togglePopover()
            }
        }
        // The pairing sheet is only reachable from the right-click menu, which
        // can't be driven from a script — so it needs its own way in to be
        // verifiable at all.
        if CommandLine.arguments.contains("--debug-pairing") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [statusBar] in
                statusBar?.showPairing()
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
    private let deviceID = AgentIdentity.deviceID()
    private let clients: ClientStore
    private let auth: Auth
    private var server: StatsServer?
    private var pairingWindow: NSWindow?
    private var alertsWindow: NSWindow?

    override init() {
        clients = ClientStore(deviceID: deviceID)
        auth = Auth(deviceID: deviceID, store: clients)
        super.init()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: DetailView(model: model))
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateTitle()
        // Off by default: no listener until the owner opts in via the menu, so
        // a fresh install exposes nothing on the network.
        if model.phonePairingEnabled {
            startAgent()
        }
    }

    /// The agent serves the sample the menu bar already took, so it costs no
    /// extra sampling. /stats needs a valid signature, so listening is not the
    /// same as exposing anything — but it only runs when phone pairing is on.
    private func startAgent() {
        let server = StatsServer(
            auth: auth, deviceID: deviceID,
            snapshot: { [model] in model.snapshot() },
            alertConfig: { [model] in model.alerts.configDTO() },
            setAlertConfig: { [model] dto in model.alerts.apply(dto) }
        )
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("MinStats agent failed to start: \(error.localizedDescription)")
        }
    }

    /// Re-arming observation: renders the title, then re-registers for
    /// the next change to any @Observable property this reads.
    private func updateTitle() {
        withObservationTracking {
            guard let button = statusItem.button else { return }
            // Compact mode draws the number and a tiny cold→hot bar as one
            // centered image (echoing the panel); extended stays plain text.
            if model.menuBarMode == .compact {
                statusItem.length = NSStatusItem.variableLength
                button.attributedTitle = NSAttributedString(string: "")
                button.image = Self.compactImage(
                    text: model.compactTemperatureText,
                    fraction: model.temperatureFraction
                )
                button.imagePosition = .imageOnly
            } else {
                let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                button.image = nil
                button.imagePosition = .noImage
                // Fixed item length (sized to the worst-case title) is what
                // keeps the menu bar from shifting; the title itself is
                // unpadded so the gaps between temp/CPU/RAM stay even. The
                // string can't deliver both — padding it evened the width by
                // making the gaps lopsided.
                statusItem.length = ceil(
                    (model.menuTitleTemplate as NSString)
                        .size(withAttributes: [.font: font]).width
                ) + 8   // the button's own horizontal insets
                button.attributedTitle = NSAttributedString(
                    string: model.menuTitle,
                    attributes: [.font: font]
                )
            }
            // Compact mode is an image with no text, and the padded extended
            // title reads awkwardly — give VoiceOver a clean spoken summary.
            button.setAccessibilityLabel(model.voiceOverSummary)
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
        let phonePairing = NSMenuItem(title: "Enable Phone Pairing", action: #selector(togglePhonePairing), keyEquivalent: "")
        phonePairing.state = model.phonePairingEnabled ? .on : .off
        // A state-aware subtitle (macOS 14+) so anyone scanning the menu — the
        // privacy-conscious especially — sees what this does without toggling
        // it: off means nothing is on the network; on means a paired phone can
        // read stats and quit apps.
        if #available(macOS 14.4, *) {
            phonePairing.subtitle = model.phonePairingEnabled
                ? "On — a paired iPhone can view stats & quit apps"
                : "Off — nothing on this Mac is shared on your network"
        }
        let alerts = NSMenuItem(title: "Alerts…", action: #selector(showAlerts), keyEquivalent: "")
        for item in [compact, extended, fahrenheit, launchAtLogin, alerts, phonePairing] { item.target = self }

        menu.addItem(compact)
        menu.addItem(extended)
        menu.addItem(.separator())
        menu.addItem(fahrenheit)
        menu.addItem(launchAtLogin)
        menu.addItem(alerts)
        menu.addItem(.separator())
        menu.addItem(phonePairing)
        // Pairing only makes sense once the agent is listening, so it appears
        // only when phone pairing is enabled.
        if model.phonePairingEnabled {
            let pair = NSMenuItem(title: "Pair or Revoke iPhone…", action: #selector(showPairing), keyEquivalent: "")
            pair.target = self
            menu.addItem(pair)
        }
        menu.addItem(.separator())
        // No action → auto-disabled: a label, not a control. agentVersion is
        // the single version truth (also /health and the bundle's Info.plist),
        // so what the menu says is what the wire reports.
        menu.addItem(NSMenuItem(title: "MinStats \(SystemInfo.agentVersion)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit MinStats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // With a menu attached, performClick pops it synchronously and
        // skips the button action; detach after so left click stays ours.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func showPairing() {
        // Fresh offer per pairing session: whatever QR the last session
        // displayed (or someone photographed) is dead from here on.
        clients.rotateUnclaimed()
        let host = (SystemInfo.computerName)
            .replacingOccurrences(of: " ", with: "-") + ".local"
        // The URL is built per client slot: when a phone claims the offered
        // slot (or a pairing is revoked), the store changes and the view
        // re-derives a fresh QR. altHosts re-evaluates then too, so a tunnel
        // that came up since the window opened is captured.
        let view = PairingView(
            store: clients,
            deviceName: SystemInfo.computerName,
            pairingURL: { [auth] client in
                auth.pairingURL(
                    for: client,
                    host: host,
                    port: MinStatsProtocolVersion.defaultPort,
                    name: SystemInfo.computerName,
                    altHosts: SystemInfo.reachableHosts()
                )
            },
            onRevokeAll: { [weak self] in
                guard let self else { return }
                // Full trust reset (TLS plan step 7): secrets AND identity.
                // Bounce the listener so it serves the fresh cert — the view
                // re-derives the QR from the store change, and the pairing
                // link's pin comes from the new identity.
                self.clients.revokeAll()
                AgentIdentity.resetTLSIdentity()
                // restart(), not stop()+start(): the port releases
                // asynchronously and an immediate rebind loses the race.
                self.server?.restart()
            }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Phone Pairing"
        window.styleMask = NSWindow.StyleMask([.titled, .closable])
        window.isReleasedWhenClosed = false
        window.center()
        pairingWindow = window
        bringToFront(window)
    }

    /// Brings a window reliably to the foreground. This is a menu-bar (accessory)
    /// app, so plain `NSApp.activate()` often leaves the window *behind* whatever
    /// app was frontmost — `orderFrontRegardless()` forces it above other apps'
    /// windows on open, and `makeKeyAndOrderFront` makes it take keyboard input.
    private func bringToFront(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    @objc func showAlerts() {
        let view = AlertsView(monitor: model.alerts, model: model)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Alerts"
        window.styleMask = NSWindow.StyleMask([.titled, .closable])
        window.isReleasedWhenClosed = false
        window.center()
        alertsWindow = window
        bringToFront(window)
    }

    /// Opt in/out of the phone-facing agent. Enabling starts the listener;
    /// disabling stops it (releasing the port and Bonjour) so the Mac goes back
    /// to exposing nothing on the network.
    @objc private func togglePhonePairing() {
        if model.phonePairingEnabled {
            // Turning OFF is always safe — no confirmation. Stop the listener and
            // Bonjour so the Mac goes back to exposing nothing on the network.
            model.phonePairingEnabled = false
            server?.stop()
            server = nil
            pairingWindow?.close()
            pairingWindow = nil
        } else {
            // Turning ON opens a network listener and lets a paired phone quit
            // your apps — spell that out and require an explicit accept, so no
            // one enables remote control without understanding what it grants.
            guard confirmEnablePhonePairing() else { return }
            model.phonePairingEnabled = true
            startAgent()
        }
    }

    /// The "what am I allowing?" gate for phone pairing. Returns true only if the
    /// owner explicitly accepts.
    private func confirmEnablePhonePairing() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Enable Phone Pairing?"
        alert.informativeText = """
            This starts a listener on your local network so an iPhone you pair can \
            see this Mac's temperature, CPU, memory, and processes — and quit or \
            restart your apps.

            Nothing connects until you pair a phone with a one-time code. Quit and \
            restart commands work only over your private network (home Wi-Fi or \
            your own VPN), never the public internet. Turn this off anytime to \
            stop sharing completely.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
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
