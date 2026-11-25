import AppKit
import Combine

struct ChannelPrefs {
    var monitor: Double
    var stream: Double
    var monitorMuted: Bool
    var streamMuted: Bool
    /// Per-channel output devices (UIDs). nil = follow the default output.
    var outputs: [String]? = nil
    /// Whether the channel is patched into Mixer Stream.
    var toStream: Bool = true
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var launchAtLogin: Bool {
        didSet { LaunchAtLogin.setEnabled(launchAtLogin) }
    }
    @Published var panelVisible: Bool {
        didSet { defaults.set(panelVisible, forKey: "panelVisible") }
    }
    /// Show the floating mixer panel every time the app starts (off: start in the menu bar only).
    @Published var openPanelAtLaunch: Bool {
        didSet { defaults.set(openPanelAtLaunch, forKey: "openPanelAtLaunch") }
    }
    @Published var panelOnTop: Bool {
        didSet { defaults.set(panelOnTop, forKey: "panelOnTop") }
    }
    @Published var rememberVolumes: Bool {
        didSet {
            defaults.set(rememberVolumes, forKey: "rememberVolumes")
            if !rememberVolumes { clearChannelPrefs() }
        }
    }
    @Published var showIdleApps: Bool {
        didSet { defaults.set(showIdleApps, forKey: "showIdleApps") }
    }
    /// Mouse-wheel / trackpad speed on sliders (1 = 1% per wheel notch).
    @Published var scrollSpeed: Double {
        didSet { defaults.set(scrollSpeed, forKey: "scrollSpeed") }
    }
    /// Mixer panel size: 0 small, 1 medium, 2 large.
    @Published var panelSize: Int {
        didSet { defaults.set(panelSize, forKey: "panelSize") }
    }
    @Published var panelShowsRouting: Bool {
        didSet {
            defaults.set(panelShowsRouting, forKey: "panelShowsRouting")
            if panelShowsRouting { panelShowsMacSound = false }
        }
    }
    /// Keep the output / input you picked when macOS switches to a device that just connected.
    @Published var holdDevices: Bool {
        didSet { defaults.set(holdDevices, forKey: "holdDevices") }
    }
    /// Devices (UIDs) left out of the patch bay in the floating panel / the menu bar dropdown.
    @Published var hiddenInPanel: [String] {
        didSet { defaults.set(hiddenInPanel, forKey: "hiddenInPanel") }
    }
    @Published var hiddenInMenu: [String] {
        didSet { defaults.set(hiddenInMenu, forKey: "hiddenInMenu") }
    }
    @Published var panelShowsMacSound = false {
        didSet { if panelShowsMacSound { panelShowsRouting = false } }
    }

    private init() {
        RenameMigration.run()
        defaults.register(defaults: [
            "panelVisible": false,
            "openPanelAtLaunch": true,
            "panelOnTop": true,
            "rememberVolumes": true,
            "showIdleApps": false,
            "panelSize": 0,
            "scrollSpeed": 1.0,
            "panelShowsRouting": false,
            "holdDevices": true,
        ])
        launchAtLogin = LaunchAtLogin.isEnabled
        let openAtLaunch = defaults.bool(forKey: "openPanelAtLaunch")
        openPanelAtLaunch = openAtLaunch
        panelVisible = openAtLaunch
        panelOnTop = defaults.bool(forKey: "panelOnTop")
        rememberVolumes = defaults.bool(forKey: "rememberVolumes")
        showIdleApps = defaults.bool(forKey: "showIdleApps")
        panelSize = defaults.integer(forKey: "panelSize")
        scrollSpeed = defaults.double(forKey: "scrollSpeed")
        panelShowsRouting = defaults.bool(forKey: "panelShowsRouting")
        holdDevices = defaults.bool(forKey: "holdDevices")
        hiddenInPanel = defaults.stringArray(forKey: "hiddenInPanel") ?? []
        hiddenInMenu = defaults.stringArray(forKey: "hiddenInMenu") ?? []
        if launchAtLogin { LaunchAtLogin.setEnabled(true) } // refresh path if the app moved
    }

    // MARK: Per-channel memory

    func prefs(for key: String) -> ChannelPrefs? {
        guard rememberVolumes,
              let all = defaults.dictionary(forKey: "channelPrefs") as? [String: [String: Any]],
              let p = all[key] else { return nil }
        return ChannelPrefs(monitor: p["m"] as? Double ?? 1,
                            stream: p["s"] as? Double ?? 1,
                            monitorMuted: p["mm"] as? Bool ?? false,
                            streamMuted: p["sm"] as? Bool ?? false,
                            outputs: p["o"] as? [String],
                            toStream: p["st"] as? Bool ?? true)
    }

    func save(_ prefs: ChannelPrefs, for key: String) {
        guard rememberVolumes else { return }
        var all = defaults.dictionary(forKey: "channelPrefs") as? [String: [String: Any]] ?? [:]
        var entry: [String: Any] = ["m": prefs.monitor, "s": prefs.stream, "mm": prefs.monitorMuted, "sm": prefs.streamMuted,
                                    "st": prefs.toStream]
        if let o = prefs.outputs { entry["o"] = o }
        all[key] = entry
        defaults.set(all, forKey: "channelPrefs")
    }

    /// Show or hide a device in the floating panel (`panel`) or the menu bar dropdown.
    func setShown(_ shown: Bool, _ uid: String, panel: Bool) {
        var list = panel ? hiddenInPanel : hiddenInMenu
        list.removeAll { $0 == uid }
        if !shown { list.append(uid) }
        if panel { hiddenInPanel = list } else { hiddenInMenu = list }
    }

    func isShown(_ uid: String, panel: Bool) -> Bool {
        return !(panel ? hiddenInPanel : hiddenInMenu).contains(uid)
    }

    func clearChannelPrefs() {
        defaults.removeObject(forKey: "channelPrefs")
    }
}

/// Cablebay used to be called Volume Mixer. The first time it runs, it takes over Volume Mixer's
/// settings (levels, routing, panel position…) and its login item.
enum RenameMigration {
    static let oldBundleID = "local.volumemixer.app"
    static let oldLaunchAgentLabel = "local.volumemixer.launcher"
    static var oldLaunchAgent: URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(oldLaunchAgentLabel).plist")
    }

    static func run() {
        let defaults = UserDefaults.standard
        guard let newID = Bundle.main.bundleIdentifier, newID != oldBundleID,
              !defaults.bool(forKey: "carriedOverFromVolumeMixer") else { return }
        if let old = defaults.persistentDomain(forName: oldBundleID), !old.isEmpty {
            var merged = defaults.persistentDomain(forName: newID) ?? [:]
            for (key, value) in old where merged[key] == nil { merged[key] = value }
            defaults.setPersistentDomain(merged, forName: newID)
        }
        defaults.set(true, forKey: "carriedOverFromVolumeMixer")
        if FileManager.default.fileExists(atPath: oldLaunchAgent.path) {
            try? FileManager.default.removeItem(at: oldLaunchAgent)
            LaunchAtLogin.setEnabled(true)
        }
    }
}

/// Launch at login through a per-user LaunchAgent (works with an ad-hoc signed app).
enum LaunchAtLogin {
    static let label = "local.cablebay.launcher"
    static var plistURL: URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        let url = plistURL
        if enabled {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
            ]
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            (plist as NSDictionary).write(to: url, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Installs the "Mixer Stream" virtual audio device (needs an admin password, asked by macOS).
enum DriverInstaller {
    static let bundleName = "MixerStream.driver"
    static let installedPath = "/Library/Audio/Plug-Ins/HAL/\(bundleName)"

    static var isInstalled: Bool {
        return FileManager.default.fileExists(atPath: installedPath)
    }

    static var bundledURL: URL? {
        return Bundle.main.url(forResource: "MixerStream", withExtension: "driver")
    }

    /// Returns an error message, or nil on success.
    static func install() -> String? {
        guard let src = bundledURL else { return "The driver is missing from the app bundle." }
        let dst = shellQuote(installedPath)
        return runAsAdmin("""
            /bin/mkdir -p /Library/Audio/Plug-Ins/HAL && \
            /bin/rm -rf \(dst) && \
            /bin/cp -R \(shellQuote(src.path)) \(dst) && \
            /usr/sbin/chown -R root:wheel \(dst) && \
            /usr/bin/killall -9 coreaudiod
            """)
    }

    static func uninstall() -> String? {
        return runAsAdmin("/bin/rm -rf \(shellQuote(installedPath)) && /usr/bin/killall -9 coreaudiod")
    }

    static func runAsAdmin(_ command: String) -> String? {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let e = error {
            if (e[NSAppleScript.errorNumber] as? Int) == -128 { return "Cancelled." }
            return e[NSAppleScript.errorMessage] as? String ?? "Unknown error"
        }
        return nil
    }

    /// Core Audio restarts after (un)installing, so start a fresh copy of the app.
    static func relaunch() {
        let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 3; /usr/bin/open '\(path)'"]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// Quotes a string for /bin/sh.
func shellQuote(_ s: String) -> String {
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Removes Cablebay completely: the app, the Mixer Stream driver, settings, the login item,
/// caches and the privacy permissions macOS stored for it. Leftovers from Volume Mixer (its old name) go too.
enum Uninstaller {
    static var bundleID: String { return Bundle.main.bundleIdentifier ?? "local.cablebay.app" }
    static var bundleIDs: [String] { return [bundleID, RenameMigration.oldBundleID] }
    static let oldAppPath = "/Applications/Volume Mixer.app"

    /// Everything in your home folder that belongs to the app.
    static var userItems: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var items = [LaunchAtLogin.plistURL.path, RenameMigration.oldLaunchAgent.path,
                     "\(home)/Library/Application Support/Cablebay",
                     "\(home)/Library/Application Support/Volume Mixer"]
        for id in bundleIDs {
            items += [
                "\(home)/Library/Preferences/\(id).plist",
                "\(home)/Library/Caches/\(id)",
                "\(home)/Library/HTTPStorages/\(id)",
                "\(home)/Library/HTTPStorages/\(id).binarycookies",
                "\(home)/Library/Saved Application State/\(id).savedState",
                "\(home)/Library/WebKit/\(id)",
                "\(home)/Library/Application Support/\(id)",
            ]
        }
        return items
    }

    /// Step 1 (asks for your password): delete the driver and the app, restart Core Audio.
    /// Returns an error message, or nil on success.
    static func removeAppAndDriver() -> String? {
        var commands = ["/bin/rm -rf \(shellQuote(DriverInstaller.installedPath))"]
        let app = Bundle.main.bundlePath
        if app.hasSuffix(".app") { commands.append("/bin/rm -rf \(shellQuote(app))") }
        if app != oldAppPath { commands.append("/bin/rm -rf \(shellQuote(oldAppPath))") }
        commands.append("/usr/bin/killall -9 coreaudiod")
        return DriverInstaller.runAsAdmin(commands.joined(separator: "; ") + "; true")
    }

    /// Step 2: once this process has quit, delete settings, caches, the login item and permissions.
    static func removeUserDataAfterQuit() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let uid = "$(/usr/bin/id -u)"
        let perID = bundleIDs.map(shellQuote).map { id in
            "/usr/bin/defaults delete \(id) 2>/dev/null\n/usr/bin/tccutil reset All \(id) >/dev/null 2>&1"
        }.joined(separator: "\n")
        let script = """
            while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
            /bin/launchctl bootout gui/\(uid)/\(LaunchAtLogin.label) 2>/dev/null
            /bin/launchctl bootout gui/\(uid)/\(RenameMigration.oldLaunchAgentLabel) 2>/dev/null
            \(perID)
            /bin/rm -rf \(userItems.map(shellQuote).joined(separator: " "))
            true
            """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
    }
}
