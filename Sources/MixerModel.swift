import AppKit
import Combine
import CoreAudio
import Darwin

/// Fast-changing meter values live in their own objects, so only the meters redraw 20×/s
/// (not every view that shows the mixer — that made the Settings window flicker).
final class ChannelLevel: ObservableObject {
    @Published var meter: Float = 0
    @Published var clipping = false
}

final class BusLevels: ObservableObject {
    @Published var monitor: Float = 0
    @Published var stream: Float = 0
}

/// A mixer channel: an app (possibly several helper processes) or the microphone.
final class Channel: ObservableObject, Identifiable {
    enum Kind { case app, mic }

    let id: String
    let kind: Kind
    /// The input device an input (mic) channel records from.
    let deviceUID: String?
    @Published var name: String
    @Published var icon: NSImage
    /// Fader: level into your headphones mix.
    @Published var monitorLevel: Double
    /// Send knob: level into the stream mix.
    @Published var streamLevel: Double
    @Published var monitorMuted: Bool
    @Published var streamMuted: Bool
    @Published var isPlaying = false
    @Published var error: String?
    let level = ChannelLevel()
    /// Output devices for this channel only (nil = follow the default output).
    @Published var outputOverride: [String]?
    /// Patched into Mixer Stream (the STREAM fader sets how loud).
    @Published var toStream: Bool

    var processObjects: [AudioObjectID] = []
    var lastActive = Date.distantPast
    var io: ChannelIO?
    var failedAt: Date?
    var clipHoldUntil = Date.distantPast
    var builtSignature = ""

    init(id: String, kind: Kind, name: String, icon: NSImage, prefs: ChannelPrefs, deviceUID: String? = nil) {
        self.id = id
        self.kind = kind
        self.deviceUID = deviceUID
        self.name = name
        self.icon = icon
        monitorLevel = prefs.monitor
        streamLevel = prefs.stream
        monitorMuted = prefs.monitorMuted
        streamMuted = prefs.streamMuted
        outputOverride = prefs.outputs
        toStream = prefs.toStream
    }

    var prefs: ChannelPrefs {
        return ChannelPrefs(monitor: monitorLevel, stream: streamLevel,
                            monitorMuted: monitorMuted, streamMuted: streamMuted, outputs: outputOverride,
                            toStream: toStream)
    }
}

/// Finds which visible app owns an audio process (e.g. "Google Chrome Helper" -> Chrome).
enum ProcessResolver {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    static func regularApp(_ pid: pid_t) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { return nil }
        return app
    }

    static func owner(pid: pid_t, bundleID: String?) -> NSRunningApplication? {
        if let app = regularApp(pid) { return app }
        if let fn = responsibleFn {
            let r = fn(pid)
            if r > 0, r != pid, let app = regularApp(r) { return app }
        }
        if let bundle = bundleID {
            var parts = bundle.split(separator: ".").map(String.init)
            let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            while parts.count > 2 {
                parts.removeLast()
                let candidate = parts.joined(separator: ".")
                if let app = running.first(where: { $0.bundleIdentifier == candidate }) { return app }
            }
        }
        return nil
    }

    static func path(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// The mixing engine: every app playing audio (and any inputs you pick) becomes a channel,
/// mixed into a Headphones bus (the output devices you picked) and a Stream bus (the Mixer Stream device).
final class MixerModel: ObservableObject {
    static let streamDeviceUID = "VolumeMixerStream_UID"

    @Published private(set) var appChannels: [Channel] = []
    /// One channel per input device you mix in (e.g. the MacBook mic and the AirPods mic at once).
    @Published private(set) var inputChannels: [Channel] = []
    let tapsSupported = TapAPI.isAvailable

    /// Inputs on/off (the mic button). Which inputs are mixed is `mixInputUIDs`.
    @Published var micEnabled: Bool {
        didSet {
            defaults.set(micEnabled, forKey: "micEnabled")
            if micEnabled && mixInputUIDs.isEmpty, let uid = fallbackInputUID { mixInputUIDs = [uid] }
            syncInputs()
        }
    }
    /// Input devices mixed in as channels (UIDs), in the order you picked them.
    @Published var mixInputUIDs: [String] { didSet { defaults.set(mixInputUIDs, forKey: "mixInputs"); syncInputs() } }
    @Published var monitorMaster: Double { didSet { defaults.set(monitorMaster, forKey: "monitorMaster"); pushAllGains() } }
    @Published var streamMaster: Double { didSet { defaults.set(streamMaster, forKey: "streamMaster"); pushAllGains() } }
    @Published var monitorMasterMuted: Bool { didSet { defaults.set(monitorMasterMuted, forKey: "monitorMasterMuted"); pushAllGains() } }
    @Published var streamMasterMuted: Bool { didSet { defaults.set(streamMasterMuted, forKey: "streamMasterMuted"); pushAllGains() } }

    /// True when you picked Mixer Stream as the Mac output / input on purpose.
    private var streamChosenAsOutput: Bool {
        get { defaults.bool(forKey: "streamChosenAsOutput") }
        set { defaults.set(newValue, forKey: "streamChosenAsOutput") }
    }
    private var streamChosenAsInput: Bool {
        get { defaults.bool(forKey: "streamChosenAsInput") }
        set { defaults.set(newValue, forKey: "streamChosenAsInput") }
    }
    /// The output / input you picked last. Held when macOS switches to a device that just connected.
    private var preferredOutputUID: String? {
        get { defaults.string(forKey: "preferredOutput") }
        set { defaults.set(newValue, forKey: "preferredOutput") }
    }
    private var preferredInputUID: String? {
        get { defaults.string(forKey: "preferredInput") }
        set { defaults.set(newValue, forKey: "preferredInput") }
    }
    private var seenOutputUID: String?
    private var seenInputUID: String?

    /// Devices that play your mix *in addition to* the Mac output (UIDs).
    @Published var extraOutputs: [String] { didSet { defaults.set(extraOutputs, forKey: "extraOutputs"); poll() } }

    /// Id of the "All apps" tile on the patch bay.
    static let allAppsID = "__allapps__"
    /// Where all apps play (and new apps start), set from the "All apps" tile. nil = the Mac output.
    @Published var allAppsOutputs: [String]? { didSet { defaults.set(allAppsOutputs, forKey: "allAppsOutputs"); poll() } }
    /// Whether new apps start patched into Mixer Stream.
    @Published var allAppsToStream: Bool { didSet { defaults.set(allAppsToStream, forKey: "allAppsToStream") } }

    let meters = BusLevels()
    @Published private(set) var streamDeviceInstalled = false

    private var entries: [String: Channel] = [:]
    private var inputEntries: [String: Channel] = [:]   // by device UID
    private let devices: DeviceManager
    private let settings: AppSettings
    private let defaults = UserDefaults.standard
    private var timers: [Timer] = []
    private var cancellables = Set<AnyCancellable>()
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init(devices: DeviceManager, settings: AppSettings) {
        self.devices = devices
        self.settings = settings
        defaults.register(defaults: [
            "micEnabled": false, "monitorMaster": 1.0, "streamMaster": 1.0,
            "monitorMasterMuted": false, "streamMasterMuted": false,
        ])
        micEnabled = defaults.bool(forKey: "micEnabled")
        monitorMaster = defaults.double(forKey: "monitorMaster")
        streamMaster = defaults.double(forKey: "streamMaster")
        monitorMasterMuted = defaults.bool(forKey: "monitorMasterMuted")
        streamMasterMuted = defaults.bool(forKey: "streamMasterMuted")
        extraOutputs = defaults.stringArray(forKey: "extraOutputs") ?? []
        allAppsOutputs = defaults.stringArray(forKey: "allAppsOutputs")
        allAppsToStream = defaults.object(forKey: "allAppsToStream") as? Bool ?? true
        if let saved = defaults.stringArray(forKey: "mixInputs") {
            mixInputUIDs = saved
        } else if let old = defaults.string(forKey: "micInputUID") {
            mixInputUIDs = [old] // the single mic choice of earlier versions
        } else {
            mixInputUIDs = []
        }
        if micEnabled && mixInputUIDs.isEmpty, let uid = fallbackInputUID { mixInputUIDs = [uid] }

        settings.$showIdleApps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshVisible() }
            .store(in: &cancellables)
        // Undo an automatic device switch right away, before much audio goes to the wrong place.
        devices.$defaultOutput.merge(with: devices.$defaultInput)
            .dropFirst(2)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.holdChosenDevices() }
            .store(in: &cancellables)

        poll()
        let pollTimer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.poll() }
        let meterTimer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in self?.updateMeters() }
        for t in [pollTimer, meterTimer] { RunLoop.main.add(t, forMode: .common) }
        timers = [pollTimer, meterTimer]
    }

    var allChannels: [Channel] {
        return inputChannels + appChannels
    }

    /// Every channel object, shown or not.
    private var allEntries: [Channel] {
        return Array(entries.values) + Array(inputEntries.values)
    }

    // MARK: Routing

    /// Real output devices (everything except Mixer Stream).
    var outputDevices: [AudioDevice] {
        return devices.outputs.filter { $0.uid != MixerModel.streamDeviceUID }
    }

    /// The Mac's output device, exactly as picked (can be Mixer Stream).
    var macOutputUID: String? { return devices.defaultOutputUID }

    var allOutputs: [AudioDevice] { return devices.outputs }
    var allInputs: [AudioDevice] { return devices.inputs }
    var macOutputName: String { return devices.outputs.first { $0.id == devices.defaultOutput }?.name ?? "None" }
    var macInputName: String { return devices.inputs.first { $0.id == devices.defaultInput }?.name ?? "None" }

    var macInputUID: String? {
        return devices.inputs.first { $0.id == devices.defaultInput }?.uid
            ?? CA.getString(devices.defaultInput, addr(kAudioDevicePropertyDeviceUID))
    }

    /// Where your mix plays: only the devices you picked (the Mac output plus any extras).
    /// Never a fallback speaker, and never Mixer Stream — the stream gets the STREAM faders instead.
    var monitorDestinationUIDs: [String] {
        let available = Set(outputDevices.map { $0.uid })
        if let all = allAppsOutputs { return all.filter { available.contains($0) } }
        var list: [String] = []
        for uid in (macOutputUID.map { [$0] } ?? []) + extraOutputs where available.contains(uid) && !list.contains(uid) {
            list.append(uid)
        }
        return list
    }

    var streamDestinationUIDs: [String] {
        return streamDeviceInstalled ? [MixerModel.streamDeviceUID] : []
    }

    /// Make a device the Mac's output (like the menu bar Sound control).
    func selectOutput(_ uid: String) {
        guard let dev = devices.outputs.first(where: { $0.uid == uid }) else { return }
        streamChosenAsOutput = uid == MixerModel.streamDeviceUID
        preferredOutputUID = uid
        outputSwitchedByMac = false
        extraOutputs.removeAll { $0 == uid }
        devices.setDefaultOutput(dev.id)
        poll()
    }

    // MARK: Patching (routing board)

    /// True when this source is patched to this output (a device, or Mixer Stream).
    func isConnected(_ ch: Channel, _ uid: String) -> Bool {
        if uid == MixerModel.streamDeviceUID { return streamDeviceInstalled && ch.toStream }
        return monitorUIDs(for: ch).contains(uid)
    }

    /// Patch / unpatch a source to an output. Patching makes it audible there:
    /// it unmutes that side and lifts its fader if it was at zero.
    func toggleConnection(_ ch: Channel, _ uid: String) {
        if uid == MixerModel.streamDeviceUID {
            ch.toStream.toggle()
            if ch.toStream {
                if ch.streamMuted { ch.streamMuted = false }
                if ch.streamLevel < 0.01 { ch.streamLevel = 1 }
            }
        } else {
            var current = monitorUIDs(for: ch)
            if let i = current.firstIndex(of: uid) {
                current.remove(at: i)
            } else {
                current.append(uid)
                if ch.monitorMuted { ch.monitorMuted = false }
                if ch.monitorLevel < 0.01 { ch.monitorLevel = 1 }
            }
            ch.outputOverride = current
        }
        changed(ch)
        objectWillChange.send()
        poll()
    }

    /// Patch from a dragged cable: connects (never disconnects).
    func connect(_ ch: Channel, _ uid: String) {
        if !isConnected(ch, uid) { toggleConnection(ch, uid) }
    }

    /// Every app channel, shown or idle.
    private var allApps: [Channel] { return Array(entries.values) }

    /// How many of the apps on screen are patched to this output, out of how many.
    func allAppsConnection(_ uid: String) -> (connected: Int, total: Int) {
        let apps = appChannels
        return (apps.filter { isConnected($0, uid) }.count, apps.count)
    }

    /// "All apps" tile: connect every app to this output, or — when they all are — disconnect them all.
    /// New apps follow the same patch.
    func toggleAllApps(_ uid: String, connectOnly: Bool = false) {
        let (connected, total) = allAppsConnection(uid)
        let target = total == 0 ? !(uid == MixerModel.streamDeviceUID ? allAppsToStream : monitorDestinationUIDs.contains(uid))
                                : connected < total
        if connectOnly && !target { return }
        if uid == MixerModel.streamDeviceUID {
            allAppsToStream = target
            for ch in allApps {
                ch.toStream = target
                if target {
                    if ch.streamMuted { ch.streamMuted = false }
                    if ch.streamLevel < 0.01 { ch.streamLevel = 1 }
                }
                changed(ch)
            }
        } else {
            var list = monitorDestinationUIDs
            if target { if !list.contains(uid) { list.append(uid) } } else { list.removeAll { $0 == uid } }
            for ch in allApps {
                ch.outputOverride = nil
                if target {
                    if ch.monitorMuted { ch.monitorMuted = false }
                    if ch.monitorLevel < 0.01 { ch.monitorLevel = 1 }
                }
                changed(ch)
            }
            allAppsOutputs = list
            // Keep the Mac's own output on one of them, so the volume keys and sound outside the mixer follow.
            if let first = list.first, !(macOutputUID.map { list.contains($0) } ?? false) {
                selectOutput(first)
            }
        }
        objectWillChange.send()
        poll()
    }

    /// Mixer Stream for this channel, when it's installed and the channel is patched to it.
    func streamUIDs(for ch: Channel) -> [String] {
        return streamDeviceInstalled && ch.toStream ? [MixerModel.streamDeviceUID] : []
    }

    /// Also play your mix on this device, alongside the Mac output.
    func toggleExtraOutput(_ uid: String) {
        guard uid != macOutputUID else { return }
        if extraOutputs.contains(uid) { extraOutputs.removeAll { $0 == uid } } else { extraOutputs.append(uid) }
    }

    /// Make a device the Mac's input (like the menu bar Sound control).
    func selectInput(_ uid: String) {
        guard let dev = devices.inputs.first(where: { $0.uid == uid }) else { return }
        streamChosenAsInput = uid == MixerModel.streamDeviceUID
        preferredInputUID = uid
        inputSwitchedByMac = false
        devices.setDefaultInput(dev.id)
        poll()
    }

    /// Real input devices (everything except Mixer Stream).
    var inputDevices: [AudioDevice] {
        return devices.inputs.filter { $0.uid != MixerModel.streamDeviceUID }
    }

    /// True when this input is mixed in right now.
    func isMixing(_ uid: String) -> Bool {
        return micEnabled && mixInputUIDs.contains(uid)
    }

    /// Tick / untick an input in the mix. Ticking one also turns inputs on.
    func toggleMixInput(_ uid: String) {
        if !micEnabled {
            if !mixInputUIDs.contains(uid) { mixInputUIDs.append(uid) }
            micEnabled = true
        } else if let i = mixInputUIDs.firstIndex(of: uid) {
            mixInputUIDs.remove(at: i)
            if mixInputUIDs.isEmpty { micEnabled = false }
        } else {
            mixInputUIDs.append(uid)
        }
    }

    /// The input to start with when you turn inputs on: the Mac input, else the built-in mic.
    private var fallbackInputUID: String? {
        let real = inputDevices
        if let uid = macInputUID, real.contains(where: { $0.uid == uid }) { return uid }
        return (real.first { $0.transport == kAudioDeviceTransportTypeBuiltIn } ?? real.first)?.uid
    }

    func deviceName(_ uid: String) -> String {
        return devices.outputs.first { $0.uid == uid }?.name
            ?? devices.inputs.first { $0.uid == uid }?.name ?? uid
    }

    /// Where a channel's YOU side goes: its own patch, or the default output.
    func monitorUIDs(for ch: Channel) -> [String] {
        if let chosen = ch.outputOverride {
            let available = Set(outputDevices.map { $0.uid })
            let present = chosen.filter { available.contains($0) }
            if !present.isEmpty || chosen.isEmpty { return present }
        }
        return monitorDestinationUIDs
    }

    func toggleOutput(_ ch: Channel, _ uid: String) {
        var current = ch.outputOverride ?? monitorDestinationUIDs
        if let i = current.firstIndex(of: uid) { current.remove(at: i) } else { current.append(uid) }
        ch.outputOverride = current
        changed(ch)
        poll()
    }

    func setOutputs(_ ch: Channel, _ uids: [String]) {
        ch.outputOverride = uids
        changed(ch)
        poll()
    }

    func followHeadphones(_ ch: Channel) {
        ch.outputOverride = nil
        changed(ch)
        objectWillChange.send()
        poll()
    }

    // MARK: Holding the devices you picked

    /// macOS moves the default output / input to whatever just connected (headphones, AirPods, a USB mic),
    /// and to a fallback when a device goes away. Such a switch is automatic: with "Keep my devices" on it is
    /// undone, and the device you picked comes back as soon as it's connected again.
    /// Any other switch (Cablebay, Control Center, Sound settings) is your choice and becomes the one held.
    private static let newDeviceWindow: TimeInterval = 15
    private static let removalWindow: TimeInterval = 4
    private var outputSwitchedByMac = false
    private var inputSwitchedByMac = false
    private var lastOutputHold = Date.distantPast
    private var lastInputHold = Date.distantPast

    private func holdChosenDevices() {
        let now = Date()
        let stream = MixerModel.streamDeviceUID
        let afterRemoval = now.timeIntervalSince(devices.lastRemoval) < MixerModel.removalWindow
        let hold = settings.holdDevices

        // Output
        let out = devices.defaultOutputUID
        if out != seenOutputUID {
            let byMac = seenOutputUID != nil && out.map {
                devices.connectedRecently($0, input: false, within: MixerModel.newDeviceWindow) || afterRemoval
            } ?? true
            if let out = out, !byMac || !hold {
                if seenOutputUID != nil && !byMac { streamChosenAsOutput = out == stream }
                if out != stream || streamChosenAsOutput { preferredOutputUID = out }
            }
            outputSwitchedByMac = byMac && hold
            if byMac { NSLog("Cablebay: macOS switched output to %@", out ?? "nothing") }
            seenOutputUID = out
        }
        if let want = preferredOutputUID, want == out { outputSwitchedByMac = false }
        if hold, outputSwitchedByMac, let want = preferredOutputUID, want != out,
           now.timeIntervalSince(lastOutputHold) > 0.7,
           let dev = devices.outputs.first(where: { $0.uid == want }) {
            NSLog("Cablebay: holding output on %@", dev.name)
            lastOutputHold = now
            devices.setDefaultOutput(dev.id)
        }

        // Input
        let inp = macInputUID
        if inp != seenInputUID {
            let byMac = seenInputUID != nil && inp.map {
                devices.connectedRecently($0, input: true, within: MixerModel.newDeviceWindow) || afterRemoval
            } ?? true
            if let inp = inp, !byMac || !hold {
                if seenInputUID != nil && !byMac { streamChosenAsInput = inp == stream }
                if inp != stream || streamChosenAsInput { preferredInputUID = inp }
            }
            inputSwitchedByMac = byMac && hold
            if byMac { NSLog("Cablebay: macOS switched input to %@", inp ?? "nothing") }
            seenInputUID = inp
        }
        if let want = preferredInputUID, want == inp { inputSwitchedByMac = false }
        if hold, inputSwitchedByMac, let want = preferredInputUID, want != inp,
           now.timeIntervalSince(lastInputHold) > 0.7,
           let dev = devices.inputs.first(where: { $0.uid == want }) {
            NSLog("Cablebay: holding input on %@", dev.name)
            lastInputHold = now
            devices.setDefaultInput(dev.id)
        }
    }

    /// Mixer Stream as the Mac's default output means you hear nothing, and as the default input
    /// your calls would carry the stream mix. If either happens without you picking it, move it back.
    private func keepMacDefaultsOffStream() {
        let stream = MixerModel.streamDeviceUID
        if devices.defaultOutputUID == stream, !streamChosenAsOutput {
            let real = outputDevices
            let target = [preferredOutputUID].compactMap { $0 }.first { uid in real.contains { $0.uid == uid } }
                ?? extraOutputs.first { uid in real.contains { $0.uid == uid } }
                ?? (real.first { $0.transport == kAudioDeviceTransportTypeBuiltIn } ?? real.first)?.uid
            if let uid = target, let dev = real.first(where: { $0.uid == uid }) {
                NSLog("Cablebay: Mac output was Mixer Stream, moving it to %@", dev.name)
                devices.setDefaultOutput(dev.id)
            }
        }
        if macInputUID == stream, !streamChosenAsInput {
            let real = inputDevices
            let preferred = real.first { $0.uid == preferredInputUID }
            if let dev = preferred ?? real.first(where: { $0.transport == kAudioDeviceTransportTypeBuiltIn }) ?? real.first {
                NSLog("Cablebay: Mac input was Mixer Stream, moving it to %@", dev.name)
                devices.setDefaultInput(dev.id)
            }
        }
    }

    /// Before the driver is removed: put the Mac output and input back on real devices.
    func leaveStreamDevice() {
        streamChosenAsOutput = false
        streamChosenAsInput = false
        keepMacDefaultsOffStream()
    }

    private func routeSignature(for ch: Channel) -> String {
        var parts = monitorUIDs(for: ch) + ["|"] + streamUIDs(for: ch)
        if ch.kind == .mic { parts += ["|", ch.deviceUID ?? ""] }
        return parts.joined(separator: ",")
    }

    // MARK: Channel actions

    func changed(_ ch: Channel) {
        push(ch)
        settings.save(ch.prefs, for: ch.id)
    }

    func resetAll() {
        settings.clearChannelPrefs()
        for ch in allEntries {
            ch.monitorLevel = ch.kind == .mic ? 0 : 1
            ch.streamLevel = 1
            ch.monitorMuted = false
            ch.streamMuted = false
            push(ch)
        }
    }

    func shutdown() {
        for ch in allEntries {
            ch.io?.invalidate()
            ch.io = nil
        }
    }

    /// Slider position -> gain. 100% is unity (the app's own volume); 80% ≈ -3 dB, 50% ≈ -9 dB.
    static func taper(_ v: Double) -> Double { return pow(max(0, min(1, v)), 1.5) }

    private func gains(_ ch: Channel) -> (Float, Float) {
        let t = MixerModel.taper
        let m = (ch.monitorMuted || monitorMasterMuted) ? 0 : t(ch.monitorLevel) * t(monitorMaster)
        let s = (ch.streamMuted || !ch.toStream || streamMasterMuted) ? 0 : t(ch.streamLevel) * t(streamMaster)
        return (Float(m), Float(s))
    }

    /// A channel's mute button silences it everywhere (outputs and stream).
    func isMuted(_ ch: Channel) -> Bool {
        return ch.monitorMuted && (ch.streamMuted || !streamDeviceInstalled)
    }

    func toggleMute(_ ch: Channel) {
        let mute = !isMuted(ch)
        ch.monitorMuted = mute
        ch.streamMuted = mute
        changed(ch)
    }

    private func push(_ ch: Channel) {
        let (m, s) = gains(ch)
        ch.io?.setGains(monitor: m, stream: s)
    }

    private func pushAllGains() {
        for ch in allEntries { push(ch) }
    }

    // MARK: Building channel IO

    private func build(_ ch: Channel) {
        // The old path keeps running (and keeps the app's tap muted) until the new one is really playing,
        // so re-patching never lets the app leak straight to the default output for a moment.
        let old = ch.io
        ch.io = nil
        defer { if let old = old { MixerModel.retire(old, replacedBy: ch.io) } }
        let source: ChannelSource
        switch ch.kind {
        case .app:
            guard !ch.processObjects.isEmpty else { return }
            source = .processes(ch.processObjects)
        case .mic:
            guard let uid = ch.deviceUID, uid != MixerModel.streamDeviceUID else { return }
            source = .inputDevice(uid: uid)
        }
        let (m, s) = gains(ch)
        ch.builtSignature = routeSignature(for: ch)
        let monitor = monitorUIDs(for: ch)
        let stream = streamUIDs(for: ch)
        var silent: [String] = []
        if monitor.isEmpty && stream.isEmpty {
            // An input patched nowhere stays closed (no mic in use).
            if ch.kind == .mic {
                if ch.error != nil { ch.error = nil }
                return
            }
            // An app patched nowhere must still be tapped, or macOS would play it straight to the speakers.
            // It runs into a real output at zero volume.
            let real = outputDevices
            guard let quiet = real.first(where: { $0.uid == macOutputUID })?.uid ?? real.first?.uid else { return }
            silent = [quiet]
        }
        do {
            ch.io = try ChannelIO(source: source, monitorUIDs: monitor, streamUIDs: stream, silentUIDs: silent,
                                  monitorGain: m, streamGain: s, fadeIn: old != nil)
            if ch.error != nil { ch.error = nil }
            ch.failedAt = nil
        } catch {
            ch.error = "\(error)"
            ch.failedAt = Date()
            NSLog("Cablebay: channel %@ failed: %@", ch.name, "\(error)")
        }
    }

    /// Stops a channel's old audio path once its replacement is rendering. `AudioDeviceStart` returns before the
    /// first buffer is read, and an app's tap only mutes it while someone reads the tap; stopping the old path
    /// straight away left a few milliseconds where the app played through the default output.
    /// The new path fades in over its first buffer while the old one fades out, so the handover is a crossfade.
    private static func retire(_ old: ChannelIO, replacedBy new: ChannelIO?, waited: TimeInterval = 0) {
        guard let new = new else { old.invalidate(); return }
        if new.hasRendered || waited >= 0.5 {
            old.setGains(monitor: 0, stream: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { old.invalidate() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) {
            retire(old, replacedBy: new, waited: waited + 0.005)
        }
    }

    private func makeInputChannel(_ uid: String) -> Channel {
        let dev = devices.inputs.first { $0.uid == uid }
        let name = dev?.name ?? uid
        let icon = NSImage(systemSymbolName: dev?.symbol(input: true) ?? "mic.fill", accessibilityDescription: name)
            ?? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: name) ?? NSImage()
        let id = "__mic__:" + uid
        // Inputs start out of your own ears (no echo of yourself) and fully in the stream.
        let prefs = settings.prefs(for: id)
            ?? ChannelPrefs(monitor: 0, stream: 1, monitorMuted: false, streamMuted: false, outputs: [], toStream: true)
        return Channel(id: id, kind: .mic, name: name, icon: icon, prefs: prefs, deviceUID: uid)
    }

    /// Keeps one running channel per picked input that is connected. Unplugged inputs drop out
    /// and come back when they reconnect; nothing falls back to another microphone.
    private func syncInputs() {
        let present = Set(inputDevices.map { $0.uid })
        let wanted = micEnabled ? mixInputUIDs.filter { present.contains($0) } : []
        for (uid, ch) in inputEntries where !wanted.contains(uid) {
            ch.io?.invalidate()
            ch.io = nil
            inputEntries.removeValue(forKey: uid)
        }
        var list: [Channel] = []
        let now = Date()
        for uid in wanted {
            let ch = inputEntries[uid] ?? makeInputChannel(uid)
            inputEntries[uid] = ch
            let stale = ch.io != nil && ch.builtSignature != routeSignature(for: ch)
            let retry = ch.io == nil && (ch.failedAt.map { now.timeIntervalSince($0) > 5 } ?? true)
            if stale || retry { build(ch) }
            list.append(ch)
        }
        if list.map({ $0.id }) != inputChannels.map({ $0.id }) { inputChannels = list }
    }

    // MARK: Polling

    func poll() {
        let installed = devices.outputs.contains { $0.uid == MixerModel.streamDeviceUID }
        if installed != streamDeviceInstalled { streamDeviceInstalled = installed }
        holdChosenDevices()
        keepMacDefaultsOffStream()

        // Rebuild any channel whose destinations changed.
        for ch in entries.values where ch.io != nil && ch.builtSignature != routeSignature(for: ch) {
            build(ch)
        }
        syncInputs()
        pollApps()
    }

    private func pollApps() {
        struct Group {
            var app: NSRunningApplication?
            var name: String
            var path: String?
            var objects: [AudioObjectID] = []
            var playing = false
        }
        var groups: [String: Group] = [:]

        for obj in CA.getIDs(kSystemObject, addr(CAConst.processObjectList)) {
            let pid: pid_t = CA.get(obj, addr(CAConst.processPID), default: pid_t(-1))
            guard pid > 0, pid != ownPID else { continue }
            let playing = CA.get(obj, addr(CAConst.processIsRunningOutput), default: UInt32(0)) != 0
            let bundle = CA.getString(obj, addr(CAConst.processBundleID))

            let key: String
            var group: Group
            if let owner = ProcessResolver.owner(pid: pid, bundleID: bundle) {
                key = owner.bundleIdentifier ?? "pid:\(owner.processIdentifier)"
                group = groups[key] ?? Group(app: owner, name: owner.localizedName ?? key, path: owner.bundleURL?.path)
            } else {
                let fallbackKey = (bundle?.isEmpty == false) ? bundle! : "pid:\(pid)"
                guard playing || entries[fallbackKey] != nil else { continue }
                key = fallbackKey
                let path = ProcessResolver.path(pid)
                let name = path.map { ($0 as NSString).lastPathComponent } ?? bundle ?? "PID \(pid)"
                group = groups[key] ?? Group(app: nil, name: name, path: path)
            }
            group.objects.append(obj)
            group.playing = group.playing || playing
            groups[key] = group
        }

        let now = Date()
        for (key, group) in groups {
            let ch: Channel
            if let existing = entries[key] {
                ch = existing
            } else {
                let icon = group.app?.icon
                    ?? group.path.map { NSWorkspace.shared.icon(forFile: $0) }
                    ?? NSImage(named: NSImage.applicationIconName)!
                let prefs = settings.prefs(for: key)
                    ?? ChannelPrefs(monitor: 1, stream: 1, monitorMuted: false, streamMuted: false, toStream: allAppsToStream)
                ch = Channel(id: key, kind: .app, name: group.name, icon: icon, prefs: prefs)
                entries[key] = ch
            }

            let objects = group.objects.sorted()
            if ch.processObjects != objects {
                ch.processObjects = objects
                if ch.io != nil { build(ch) }
            }
            if ch.isPlaying != group.playing { ch.isPlaying = group.playing }
            if group.playing { ch.lastActive = now }

            // Route the app through the mixer as soon as it plays.
            if ch.io == nil && group.playing && tapsSupported {
                let canRetry = ch.failedAt.map { now.timeIntervalSince($0) > 5 } ?? true
                if canRetry { build(ch) }
            }
        }

        for key in Array(entries.keys) where groups[key] == nil {
            entries[key]?.io?.invalidate()
            entries[key]?.io = nil
            entries.removeValue(forKey: key)
        }
        refreshVisible()
    }

    private func refreshVisible() {
        let now = Date()
        let list = entries.values
            .filter { settings.showIdleApps || $0.isPlaying || now.timeIntervalSince($0.lastActive) < 10 }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if list.map({ $0.id }) != appChannels.map({ $0.id }) {
            appChannels = list
        }
    }

    // MARK: Meters

    private static func decay(_ old: Float, _ new: Float) -> Float {
        let v = max(new, old * 0.82)
        return v < 0.0005 ? 0 : v
    }

    private func updateMeters() {
        var monitorPeak: Float = 0
        var streamPeak: Float = 0
        let now = Date()
        for ch in allChannels {
            var source: Float = 0
            if let io = ch.io {
                let (src, mon, str) = io.takePeaks()
                source = src
                monitorPeak = max(monitorPeak, mon)
                streamPeak = max(streamPeak, str)
            }
            let lv = ch.level
            let level = MixerModel.decay(lv.meter, source)
            if abs(level - lv.meter) > 0.002 || (level == 0 && lv.meter != 0) { lv.meter = level }
            if source >= 0.99 { ch.clipHoldUntil = now.addingTimeInterval(1) }
            let clip = now < ch.clipHoldUntil
            if clip != lv.clipping { lv.clipping = clip }
        }
        let m = MixerModel.decay(meters.monitor, monitorPeak)
        let s = MixerModel.decay(meters.stream, streamPeak)
        if abs(m - meters.monitor) > 0.002 || (m == 0 && meters.monitor != 0) { meters.monitor = m }
        if abs(s - meters.stream) > 0.002 || (s == 0 && meters.stream != 0) { meters.stream = s }
    }
}
