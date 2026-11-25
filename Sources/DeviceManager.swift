import Combine
import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    var transport: UInt32 = 0

    /// SF Symbol matching the device kind, like the menu bar Sound control.
    func symbol(input: Bool) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods") { return "airpods" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: return "display"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return input ? "headphones" : "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return "iphone"
        case kAudioDeviceTransportTypeUSB: return input ? "mic" : "hifispeaker"
        case kAudioDeviceTransportTypeAggregate: return "square.stack.3d.up"
        default: return input ? "mic" : "speaker.wave.2"
        }
    }
}

/// Lists input/output devices, tracks the defaults, and exposes their volume.
final class DeviceManager: ObservableObject {
    @Published private(set) var outputs: [AudioDevice] = []
    @Published private(set) var inputs: [AudioDevice] = []
    @Published private(set) var defaultOutput: AudioDeviceID = 0
    @Published private(set) var defaultInput: AudioDeviceID = 0

    @Published private(set) var outputVolume: Double = 0
    @Published private(set) var outputMuted = false
    @Published private(set) var outputVolumeSettable = false
    @Published private(set) var outputMuteSettable = false
    @Published private(set) var inputVolume: Double = 0
    @Published private(set) var inputVolumeSettable = false

    /// Fires when the default output device switches (taps must be rebuilt).
    let defaultOutputChanged = PassthroughSubject<Void, Never>()
    /// When each output / input showed up (keys "out:UID", "in:UID"). macOS likes to switch the default
    /// to a device that just connected — Bluetooth often several seconds after it appears.
    private var appearedAt: [String: Date] = [:]
    /// When a device last went away. macOS picks a fallback default right after that.
    private(set) var lastRemoval = Date.distantPast
    private var loaded = false

    private typealias Listener = (obj: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)
    private var outputVolumeListeners: [Listener] = []
    private var inputVolumeListeners: [Listener] = []

    init() {
        reloadDevices()
        reloadDefaults()
        _ = listen(kSystemObject, addr(kAudioHardwarePropertyDevices)) { [weak self] in
            self?.reloadDevices()
            self?.reloadDefaults()
        }
        // A default can move to a device whose input or output side only just came up (AirPods), so refresh the lists too.
        _ = listen(kSystemObject, addr(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
            self?.reloadDevices()
            self?.reloadDefaults()
        }
        _ = listen(kSystemObject, addr(kAudioHardwarePropertyDefaultInputDevice)) { [weak self] in
            self?.reloadDevices()
            self?.reloadDefaults()
        }
    }

    /// True when this device's output (or input) side connected within the last `seconds`,
    /// or isn't in the list yet at all.
    func connectedRecently(_ uid: String, input: Bool, within seconds: TimeInterval) -> Bool {
        let key = (input ? "in:" : "out:") + uid
        let known = input ? inputs.contains { $0.uid == uid } : outputs.contains { $0.uid == uid }
        guard known else { return true }
        return appearedAt[key].map { Date().timeIntervalSince($0) < seconds } ?? false
    }

    var defaultOutputUID: String? {
        if let d = outputs.first(where: { $0.id == defaultOutput }) { return d.uid }
        return CA.getString(defaultOutput, addr(kAudioDevicePropertyDeviceUID))
    }

    // MARK: Device lists

    private func reloadDevices() {
        var outs: [AudioDevice] = []
        var ins: [AudioDevice] = []
        for id in CA.getIDs(kSystemObject, addr(kAudioHardwarePropertyDevices)) {
            guard let uid = CA.getString(id, addr(kAudioDevicePropertyDeviceUID)) else { continue }
            let name = CA.getString(id, addr(kAudioObjectPropertyName)) ?? uid
            if name.hasPrefix("CADefaultDeviceAggregate") || name.hasPrefix("VolumeMixer") || name.hasPrefix("Cablebay") { continue }
            let transport: UInt32 = CA.get(id, addr(kAudioDevicePropertyTransportType), default: 0)
            let device = AudioDevice(id: id, uid: uid, name: name, transport: transport)
            if CA.channelCount(id, scope: kOutputScope) > 0 { outs.append(device) }
            if CA.channelCount(id, scope: kInputScope) > 0 { ins.append(device) }
        }
        let before = Set(outputs.map { "out:" + $0.uid } + inputs.map { "in:" + $0.uid })
        let after = Set(outs.map { "out:" + $0.uid } + ins.map { "in:" + $0.uid })
        if loaded {
            let now = Date()
            for key in after.subtracting(before) { appearedAt[key] = now }
            if !before.subtracting(after).isEmpty { lastRemoval = now }
        }
        loaded = true
        if outs != outputs { outputs = outs }
        if ins != inputs { inputs = ins }
    }

    private func reloadDefaults() {
        let out: AudioDeviceID = CA.get(kSystemObject, addr(kAudioHardwarePropertyDefaultOutputDevice), default: 0)
        let inp: AudioDeviceID = CA.get(kSystemObject, addr(kAudioHardwarePropertyDefaultInputDevice), default: 0)

        if out != defaultOutput {
            let hadPrevious = defaultOutput != 0
            defaultOutput = out
            outputVolumeListeners = rewire(outputVolumeListeners, device: out, scope: kOutputScope)
            if hadPrevious { defaultOutputChanged.send() }
        }
        if inp != defaultInput {
            defaultInput = inp
            inputVolumeListeners = rewire(inputVolumeListeners, device: inp, scope: kInputScope)
        }
        reloadVolumes()
    }

    func setDefaultOutput(_ id: AudioDeviceID) {
        CA.set(kSystemObject, addr(kAudioHardwarePropertyDefaultOutputDevice), id)
    }

    func setDefaultInput(_ id: AudioDeviceID) {
        CA.set(kSystemObject, addr(kAudioHardwarePropertyDefaultInputDevice), id)
    }

    // MARK: Volume

    private typealias Target = (device: AudioObjectID, address: AudioObjectPropertyAddress)

    /// Devices without their own volume (Multi-Output, some aggregates) are controlled through their sub-devices.
    private func controlDevices(_ device: AudioDeviceID) -> [AudioObjectID] {
        let subs = CA.getIDs(device, addr(kAudioAggregateDevicePropertyActiveSubDeviceList))
        return subs.isEmpty ? [device] : [device] + subs
    }

    private func ownVolumeAddresses(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> [AudioObjectPropertyAddress] {
        if scope == kOutputScope {
            let virtual = addr(CAConst.virtualMainVolume, scope, 0)
            if CA.has(device, virtual) { return [virtual] }
        }
        let main = addr(kAudioDevicePropertyVolumeScalar, scope, 0)
        if CA.has(device, main) { return [main] }
        return [1, 2].map { addr(kAudioDevicePropertyVolumeScalar, scope, $0) }.filter { CA.has(device, $0) }
    }

    private func volumeTargets(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> [Target] {
        let own = ownVolumeAddresses(device, scope: scope)
        if !own.isEmpty { return own.map { (device, $0) } }
        return controlDevices(device).dropFirst().flatMap { sub in
            ownVolumeAddresses(sub, scope: scope).filter { CA.isSettable(sub, $0) }.map { (sub, $0) }
        }
    }

    private func muteTargets(_ device: AudioDeviceID) -> [Target] {
        let own = addr(kAudioDevicePropertyMute, kOutputScope, 0)
        if CA.has(device, own) { return [(device, own)] }
        return controlDevices(device).dropFirst().filter { CA.has($0, own) && CA.isSettable($0, own) }.map { ($0, own) }
    }

    private func readVolume(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> (Double, Bool) {
        let targets = volumeTargets(device, scope: scope)
        guard !targets.isEmpty else { return (0, false) }
        let values = targets.map { Double(CA.get($0.device, $0.address, default: Float32(0))) }
        let settable = targets.contains { CA.isSettable($0.device, $0.address) }
        return (values.max() ?? 0, settable)
    }

    private func reloadVolumes() {
        let (ov, os) = readVolume(defaultOutput, scope: kOutputScope)
        let mutes = muteTargets(defaultOutput)
        let muted = !mutes.isEmpty && mutes.allSatisfy { CA.get($0.device, $0.address, default: UInt32(0)) != 0 }
        let muteSettable = mutes.contains { CA.isSettable($0.device, $0.address) }
        let (iv, isSettable) = readVolume(defaultInput, scope: kInputScope)

        if abs(outputVolume - ov) > 0.001 { outputVolume = ov }
        if outputVolumeSettable != os { outputVolumeSettable = os }
        if outputMuted != muted { outputMuted = muted }
        if outputMuteSettable != muteSettable { outputMuteSettable = muteSettable }
        if abs(inputVolume - iv) > 0.001 { inputVolume = iv }
        if inputVolumeSettable != isSettable { inputVolumeSettable = isSettable }
    }

    func setOutputVolume(_ value: Double) {
        outputVolume = value
        for t in volumeTargets(defaultOutput, scope: kOutputScope) {
            CA.set(t.device, t.address, Float32(value))
        }
        if outputMuted && value > 0 { setOutputMuted(false) }
    }

    func setOutputMuted(_ muted: Bool) {
        outputMuted = muted
        for t in muteTargets(defaultOutput) {
            CA.set(t.device, t.address, UInt32(muted ? 1 : 0))
        }
    }

    func setInputVolume(_ value: Double) {
        inputVolume = value
        for t in volumeTargets(defaultInput, scope: kInputScope) {
            CA.set(t.device, t.address, Float32(value))
        }
    }

    // MARK: Listeners

    private func listen(_ obj: AudioObjectID, _ address: AudioObjectPropertyAddress,
                        _ handler: @escaping () -> Void) -> Listener? {
        var a = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(obj, &a, DispatchQueue.main, block) == noErr else { return nil }
        return (obj, address, block)
    }

    private func rewire(_ old: [Listener], device: AudioDeviceID, scope: AudioObjectPropertyScope) -> [Listener] {
        for l in old {
            var a = l.address
            AudioObjectRemovePropertyListenerBlock(l.obj, &a, DispatchQueue.main, l.block)
        }
        guard device != 0 else { return [] }
        var addresses = [
            addr(kAudioDevicePropertyVolumeScalar, scope, 0),
            addr(kAudioDevicePropertyVolumeScalar, scope, 1),
            addr(kAudioDevicePropertyVolumeScalar, scope, 2),
            addr(kAudioDevicePropertyMute, scope, 0),
        ]
        if scope == kOutputScope { addresses.append(addr(CAConst.virtualMainVolume, scope, 0)) }
        return controlDevices(device).flatMap { dev in
            addresses.filter { CA.has(dev, $0) }.compactMap { a in
                listen(dev, a) { [weak self] in self?.reloadVolumes() }
            }
        }
    }
}
