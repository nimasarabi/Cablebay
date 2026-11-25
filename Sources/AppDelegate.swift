import AppKit
import Combine
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { return true }
}

/// The menu bar dropdown: a borderless panel pinned under the status item. Unlike NSPopover it
/// re-anchors its top edge every time the content changes size, so it can't slide off the top of the screen.
final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { return true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var menuPanel: MenuBarPanel?
    private var menuHost: NSView?
    private var menuMonitors: [Any] = []
    private var menuClosedAt = Date.distantPast
    private var panel: FloatingPanel?
    private var settingsWindow: NSWindow?
    private var scrollMonitor: Any?
    private var menuScrollMonitor: Any?
    private var dragMonitor: Any?
    private var panelDrag: (mouse: NSPoint, origin: NSPoint)?
    private var cancellables = Set<AnyCancellable>()

    private let settings = AppSettings.shared
    private let devices = DeviceManager()
    private lazy var mixer = MixerModel(devices: devices, settings: settings)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "Cablebay")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Keep the menu bar dropdown sized to its content and pinned under the icon.
        let refitMenu: () -> Void = { [weak self] in DispatchQueue.main.async { self?.fitMenuPanel() } }
        mixer.$appChannels.sink { _ in refitMenu() }.store(in: &cancellables)
        mixer.$inputChannels.sink { _ in refitMenu() }.store(in: &cancellables)
        mixer.$streamDeviceInstalled.sink { _ in refitMenu() }.store(in: &cancellables)
        mixer.$extraOutputs.sink { _ in refitMenu() }.store(in: &cancellables)
        mixer.$micEnabled.sink { _ in refitMenu() }.store(in: &cancellables)
        settings.$panelSize.sink { _ in refitMenu() }.store(in: &cancellables)
        settings.$panelShowsRouting.sink { _ in refitMenu() }.store(in: &cancellables)
        settings.$hiddenInMenu.sink { _ in refitMenu() }.store(in: &cancellables)
        devices.$outputs.sink { _ in refitMenu() }.store(in: &cancellables)
        devices.$inputs.sink { _ in refitMenu() }.store(in: &cancellables)
        devices.$defaultInput.sink { _ in refitMenu() }.store(in: &cancellables) // the Mixer Stream tip comes and goes
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.closeMenuPanel() }

        settings.$panelVisible
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in visible ? self?.showPanel() : self?.hidePanel() }
            .store(in: &cancellables)
        settings.$panelOnTop
            .receive(on: DispatchQueue.main)
            .sink { [weak self] onTop in self?.panel?.level = onTop ? .floating : .normal }
            .store(in: &cancellables)
    }

    /// Opening the app again (Finder, Spotlight, `open`) brings the mixer panel back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.panelVisible = true
        panel?.orderFrontRegardless()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        mixer.shutdown()
    }

    /// The mixer surface. The floating panel and the menu bar dropdown show the same controls.
    private func makeMixerView(inMenu: Bool) -> HardwareMixerView {
        return HardwareMixerView(model: mixer, devices: devices, settings: settings, inMenu: inMenu,
                                 openSettings: { [weak self] in self?.openSettings() },
                                 close: { [weak self] in
                                     if inMenu { self?.closeMenuPanel() } else { self?.settings.panelVisible = false }
                                 })
    }

    /// Point of a mouse event in SwiftUI's top-left coordinates of the window's content view.
    private static func contentPoint(_ event: NSEvent, in view: NSView) -> CGPoint {
        let local = view.convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x, y: view.isFlipped ? local.y : view.bounds.height - local.y)
    }

    // MARK: Status item

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closeMenuPanel()
            showMenu()
        } else {
            toggleMenuPanel()
        }
    }

    // MARK: Menu bar dropdown

    private func toggleMenuPanel() {
        if let p = menuPanel, p.isVisible {
            closeMenuPanel()
            return
        }
        guard Date().timeIntervalSince(menuClosedAt) > 0.25 else { return } // the same click just closed it
        let p = menuPanel ?? makeMenuPanel()
        menuPanel = p
        fitMenuPanel()
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        installMenuMonitors()
    }

    private func makeMenuPanel() -> MenuBarPanel {
        let p = MenuBarPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        // The mixer draws its own rounded body, so the window itself stays clear.
        let host = NSHostingView(rootView: makeMixerView(inMenu: true))
        p.contentView = host
        menuHost = host
        // Mouse wheel over a fader moves it, as in the floating panel.
        menuScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak p] event in
            guard let p = p, event.window === p, let view = p.contentView else { return event }
            return ScrollTargets.handle(AppDelegate.contentPoint(event, in: view), event, scope: ControlScope.menu) ? nil : event
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: p,
                                               queue: .main) { [weak self] _ in self?.anchorMenuPanel() }
        return p
    }

    /// Sizes the dropdown to its content, then pins it under the icon.
    private func fitMenuPanel() {
        guard let p = menuPanel, let host = menuHost else { return }
        let size = host.fittingSize
        if size.width > 10, size.height > 10, size != p.frame.size { p.setContentSize(size) }
        anchorMenuPanel()
    }

    /// Top edge just under the menu bar, centred on the icon, kept inside the screen.
    private func anchorMenuPanel() {
        guard let p = menuPanel, let button = statusItem.button, let bw = button.window else { return }
        let icon = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (bw.screen ?? NSScreen.main)?.visibleFrame ?? icon
        let size = p.frame.size
        let top = min(icon.minY, visible.maxY) - 4
        let x = max(visible.minX + 8, min(icon.midX - size.width / 2, visible.maxX - size.width - 8))
        let origin = NSPoint(x: x.rounded(), y: (top - size.height).rounded())
        if p.frame.origin != origin { p.setFrameOrigin(origin) }
        p.invalidateShadow()
    }

    private func installMenuMonitors() {
        removeMenuMonitors()
        // A click in another app or on the desktop closes it.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                     handler: { [weak self] _ in self?.closeMenuPanel() }) {
            menuMonitors.append(g)
        }
        // So does a click in the mixer panel or Settings, and Esc.
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            guard let self = self, let p = self.menuPanel, p.isVisible else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 && event.window === p { self.closeMenuPanel(); return nil }
                return event
            }
            if let w = event.window, w !== p, w === self.panel || w === self.settingsWindow { self.closeMenuPanel() }
            return event
        }) {
            menuMonitors.append(l)
        }
    }

    private func removeMenuMonitors() {
        menuMonitors.forEach { NSEvent.removeMonitor($0) }
        menuMonitors = []
    }

    private func closeMenuPanel() {
        guard let p = menuPanel, p.isVisible else { return }
        p.orderOut(nil)
        removeMenuMonitors()
        menuClosedAt = Date()
    }

    private func showMenu() {
        let menu = NSMenu()
        let panelItem = NSMenuItem(title: settings.panelVisible ? "Hide Floating Panel" : "Show Floating Panel",
                                   action: #selector(togglePanelFromMenu), keyEquivalent: "")
        panelItem.target = self
        menu.addItem(panelItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Cablebay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func togglePanelFromMenu() { settings.panelVisible.toggle() }
    @objc private func openSettingsFromMenu() { openSettings() }

    // MARK: Floating panel

    private func showPanel() {
        if panel == nil {
            let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isMovableByWindowBackground = false
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.level = settings.panelOnTop ? .floating : .normal
            p.delegate = self
            let host = NSHostingController(rootView: makeMixerView(inMenu: false))
            host.sizingOptions = [.preferredContentSize]
            p.contentViewController = host
            p.setContentSize(host.view.fittingSize)
            if !p.setFrameUsingName("VolumeMixerHardwarePanel"), let screen = NSScreen.main {
                let f = screen.visibleFrame
                p.setFrameTopLeftPoint(NSPoint(x: f.maxX - p.frame.width - 24, y: f.maxY - 24))
            }
            p.setFrameAutosaveName("VolumeMixerHardwarePanel")
            panel = p
            PanelWindow.window = p
            installPanelHelpers(p, host: host)
        }
        closeMenuPanel()
        panel?.orderFrontRegardless()
    }

    /// Mouse-wheel control of faders/knobs, and keeping the panel sized to its content.
    private func installPanelHelpers(_ p: FloatingPanel, host: NSViewController) {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak p] event in
            guard let p = p, event.window === p, let view = p.contentView else { return event }
            return ScrollTargets.handle(AppDelegate.contentPoint(event, in: view), event, scope: ControlScope.panel) ? nil : event
        }

        // Drag the panel from anywhere that isn't a slider, button or chip.
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self, weak p] event in
            guard let self = self, let p = p, event.window === p, let view = p.contentView else { return event }
            switch event.type {
            case .leftMouseDown:
                let point = AppDelegate.contentPoint(event, in: view)
                self.panelDrag = PanelWindow.isOverControl(point) ? nil : (NSEvent.mouseLocation, p.frame.origin)
            case .leftMouseDragged:
                if let start = self.panelDrag {
                    let mouse = NSEvent.mouseLocation
                    p.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                             y: start.origin.y + mouse.y - start.mouse.y))
                    return nil
                }
            default:
                self.panelDrag = nil
            }
            return event
        }

        let refit: () -> Void = { [weak p, weak host] in
            guard let p = p, let host = host else { return }
            DispatchQueue.main.async {
                let size = host.view.fittingSize
                guard size.width > 10, size.height > 10, size != p.frame.size else { return }
                let top = p.frame.maxY
                p.setFrame(NSRect(x: p.frame.minX, y: top - size.height, width: size.width, height: size.height),
                           display: true, animate: false)
            }
        }
        settings.$panelSize.sink { _ in refit() }.store(in: &cancellables)
        settings.$panelShowsRouting.sink { _ in refit() }.store(in: &cancellables)
        settings.$panelShowsMacSound.sink { _ in refit() }.store(in: &cancellables)
        mixer.$extraOutputs.sink { _ in refit() }.store(in: &cancellables)
        devices.$inputs.sink { _ in refit() }.store(in: &cancellables)
        devices.$defaultInput.sink { _ in refit() }.store(in: &cancellables)
        mixer.$appChannels.sink { _ in refit() }.store(in: &cancellables)
        mixer.$micEnabled.sink { _ in refit() }.store(in: &cancellables)
        mixer.$inputChannels.sink { _ in refit() }.store(in: &cancellables)
        devices.$outputs.sink { _ in refit() }.store(in: &cancellables)
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === panel, settings.panelVisible {
            settings.panelVisible = false
        }
    }

    // MARK: Settings window

    private func openSettings() {
        closeMenuPanel()
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, mixer: mixer, watch: SettingsMixerWatch(mixer: mixer, devices: devices),
                                    ui: SettingsUIState())
            let host = NSHostingController(rootView: view)
            // A fixed-size window: letting SwiftUI resize it on every update made the text re-wrap and flicker.
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.title = "Cablebay Settings"
            w.styleMask = [.titled, .closable]
            w.setContentSize(SettingsView.windowSize)
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
