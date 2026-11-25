import CoreAudio
import Foundation

/// Runtime binding for the macOS 14.2+ process-tap API.
enum TapAPI {
    typealias CreateFn = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<AudioObjectID>) -> OSStatus
    typealias DestroyFn = @convention(c) (AudioObjectID) -> OSStatus

    private static let handle = dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio", RTLD_NOW)

    static let create: CreateFn? = {
        guard let h = handle, let sym = dlsym(h, "AudioHardwareCreateProcessTap") else { return nil }
        return unsafeBitCast(sym, to: CreateFn.self)
    }()

    static let destroy: DestroyFn? = {
        guard let h = handle, let sym = dlsym(h, "AudioHardwareDestroyProcessTap") else { return nil }
        return unsafeBitCast(sym, to: DestroyFn.self)
    }()

    static var isAvailable: Bool {
        return create != nil && destroy != nil && NSClassFromString("CATapDescription") != nil
    }

    /// Stereo mixdown of the given process objects, muted while we tap it.
    static func makeDescription(processes: [AudioObjectID], uuid: UUID) -> NSObject? {
        guard let cls = NSClassFromString("CATapDescription") as? NSObject.Type else { return nil }
        let d = cls.init()
        func set(_ value: Any, _ key: String) {
            let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
            if d.responds(to: NSSelectorFromString(setter)) { d.setValue(value, forKey: key) }
        }
        set(processes.map { NSNumber(value: $0) }, "processes")
        set(false, "exclusive")
        set(true, "mixdown")
        set(false, "mono")
        set(true, "privateTap")
        set(2, "muteBehavior") // CATapMutedWhenTapped
        set(uuid as NSUUID, "UUID")
        set("Cablebay", "name")
        return d
    }
}

struct TapError: Error, CustomStringConvertible {
    let step: String
    let status: OSStatus
    var description: String { return status == -1 ? step : "\(step) failed (\(status))" }
}

enum ChannelSource {
    case processes([AudioObjectID])   // an app's audio, captured with a process tap
    case inputDevice(uid: String)     // a microphone / input device
}

/// One mixer channel: captures a source and plays it to the headphone (monitor) bus
/// and the stream bus at independent levels, through a private aggregate device.
final class ChannelIO {
    static let monitorBit: UInt8 = 1
    static let streamBit: UInt8 = 2
    private static let maxBuffers = 64

    /// Shared with the IO thread:
    /// 0 monitor gain target · 1 monitor gain now · 2 stream gain target · 3 stream gain now
    /// 4 source peak · 5 monitor-out peak · 6 stream-out peak · 7 set to 1 once audio has rendered
    let ctl = UnsafeMutablePointer<Float>.allocate(capacity: 8)
    private let masks = UnsafeMutablePointer<UInt8>.allocate(capacity: ChannelIO.maxBuffers)
    private let chanBase = UnsafeMutablePointer<Int32>.allocate(capacity: ChannelIO.maxBuffers)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "cablebay.channel.io", qos: .userInteractive)
    private var invalidated = false

    /// `silentUIDs` are run at zero volume: they only keep the tap (and so the app's mute) alive.
    init(source: ChannelSource, monitorUIDs: [String], streamUIDs: [String], silentUIDs: [String] = [],
         monitorGain: Float, streamGain: Float, fadeIn: Bool = false) throws {
        ctl.initialize(repeating: 0, count: 8)
        // With fadeIn the gains ramp up from silence over the first buffer (a crossfade with the path it replaces).
        ctl[0] = monitorGain; ctl[1] = fadeIn ? 0 : monitorGain
        ctl[2] = streamGain; ctl[3] = fadeIn ? 0 : streamGain
        masks.initialize(repeating: 0, count: ChannelIO.maxBuffers)
        chanBase.initialize(repeating: 0, count: ChannelIO.maxBuffers)

        // Destinations, expanded to physical devices (aggregates can't nest).
        var outputs: [String] = []
        var maskFor: [String: UInt8] = [:]
        func add(_ uid: String, _ bit: UInt8) {
            for sub in ChannelIO.physicalOutputs(for: uid).subs {
                if maskFor[sub] == nil { outputs.append(sub) }
                maskFor[sub, default: 0] |= bit
            }
        }
        monitorUIDs.forEach { add($0, ChannelIO.monitorBit) }
        streamUIDs.forEach { add($0, ChannelIO.streamBit) }
        silentUIDs.forEach { add($0, 0) }
        guard !outputs.isEmpty else { throw TapError(step: "No output device", status: -1) }

        var subs = outputs
        var sourceDevice: String?
        if case .inputDevice(let uid) = source {
            sourceDevice = uid
            subs.removeAll { $0 == uid }
            subs.insert(uid, at: 0) // its input channels come first
        }
        // The clock device plays untouched; every other output is drift-compensated (resampled) to follow it.
        // The stream is what your audience hears, so when this channel feeds Mixer Stream, Mixer Stream is the
        // clock and your own outputs (speakers, AirPods…) do the resampling instead.
        let streamSubs = streamUIDs.flatMap { ChannelIO.physicalOutputs(for: $0).subs }
        let mainUID = streamSubs.first(where: { outputs.contains($0) }) ?? outputs[0]

        // Process tap for app channels.
        var tapUUID: UUID?
        var tapChannels = 0
        if case .processes(let objects) = source {
            guard TapAPI.isAvailable, let create = TapAPI.create else {
                throw TapError(step: "Audio taps need macOS 14.2+", status: -1)
            }
            let uuid = UUID()
            guard let desc = TapAPI.makeDescription(processes: objects, uuid: uuid) else {
                throw TapError(step: "CATapDescription unavailable", status: -1)
            }
            var tap = AudioObjectID(kAudioObjectUnknown)
            let status = create(Unmanaged.passUnretained(desc).toOpaque(), &tap)
            guard status == noErr else { throw TapError(step: "Create tap", status: status) }
            tapID = tap
            tapUUID = uuid
            let format = CA.get(tap, addr(CAConst.tapFormat), default: AudioStreamBasicDescription())
            tapChannels = max(1, Int(format.mChannelsPerFrame))
        }

        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Cablebay Channel",
            kAudioAggregateDeviceUIDKey: "cablebay.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: mainUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subs.map {
                [kAudioSubDeviceUIDKey: $0,
                 kAudioSubDeviceDriftCompensationKey: $0 != mainUID,
                 kAudioSubDeviceDriftCompensationQualityKey: kAudioAggregateDriftCompensationMaxQuality]
            },
        ]
        if let uuid = tapUUID {
            description["tapautostart"] = true
            description["taps"] = [["uid": uuid.uuidString, "drift": true]]
        }

        var agg = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg)
        guard status == noErr else { invalidate(); throw TapError(step: "Create aggregate device", status: status) }
        aggregateID = agg

        // Map each output buffer to its bus and to its channel index inside its device.
        var buffer = 0
        var inputChannelsBeforeTap = 0
        for uid in subs {
            guard let dev = ChannelIO.deviceID(for: uid) else { continue }
            inputChannelsBeforeTap += CA.channelCount(dev, scope: kInputScope)
            var channel: Int32 = 0
            for stream in CA.getIDs(dev, addr(kAudioDevicePropertyStreams, kOutputScope)) {
                let fmt = CA.get(stream, addr(kAudioStreamPropertyVirtualFormat), default: AudioStreamBasicDescription())
                if buffer < ChannelIO.maxBuffers {
                    masks[buffer] = maskFor[uid] ?? 0
                    chanBase[buffer] = channel
                }
                channel += Int32(max(1, fmt.mChannelsPerFrame))
                buffer += 1
            }
        }
        let bufferCount = min(buffer, ChannelIO.maxBuffers)

        let sourceStart: Int
        let sourceCount: Int
        if tapUUID != nil {
            sourceStart = inputChannelsBeforeTap
            sourceCount = min(2, tapChannels)
        } else {
            sourceStart = 0
            let dev = sourceDevice.flatMap { ChannelIO.deviceID(for: $0) } ?? 0
            sourceCount = min(2, CA.channelCount(dev, scope: kInputScope))
            guard sourceCount > 0 else { invalidate(); throw TapError(step: "Input device has no channels", status: -1) }
        }

        let ctl = self.ctl, masks = self.masks, chanBase = self.chanBase
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, agg, queue) { _, input, _, output, _ in
            ChannelIO.render(input: input, output: output, sourceStart: sourceStart, sourceCount: sourceCount,
                             masks: masks, chanBase: chanBase, bufferCount: bufferCount, ctl: ctl)
        }
        guard status == noErr else { invalidate(); throw TapError(step: "Create IOProc", status: status) }
        // Only run the input streams we actually read. Otherwise macOS also opens the microphones of the
        // output devices — which drops Bluetooth headphones (AirPods) into low-quality headset mode.
        ChannelIO.useOnlyInputChannels(agg, proc: ioProcID, from: sourceStart, count: sourceCount)
        status = AudioDeviceStart(agg, ioProcID)
        guard status == noErr else { invalidate(); throw TapError(step: "Start device", status: status) }
    }

    /// True once the IO thread has rendered at least one buffer, i.e. the tap is really being read.
    var hasRendered: Bool { return ctl[7] != 0 }

    func setGains(monitor: Float, stream: Float) {
        ctl[0] = monitor
        ctl[2] = stream
    }

    /// Returns (source, monitor-out, stream-out) peaks since the last call.
    func takePeaks() -> (Float, Float, Float) {
        let p = (ctl[4], ctl[5], ctl[6])
        ctl[4] = 0; ctl[5] = 0; ctl[6] = 0
        return p
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        if aggregateID != kAudioObjectUnknown {
            if let proc = ioProcID {
                AudioDeviceStop(aggregateID, proc)
                AudioDeviceDestroyIOProcID(aggregateID, proc)
                ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            _ = TapAPI.destroy?(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    deinit {
        invalidate()
        queue.sync {}
        ctl.deallocate()
        masks.deallocate()
        chanBase.deallocate()
    }

    // MARK: Device helpers

    private static func useOnlyInputChannels(_ device: AudioObjectID, proc: AudioDeviceIOProcID?, from start: Int, count: Int) {
        guard let proc = proc else { return }
        let streams = CA.getIDs(device, addr(kAudioDevicePropertyStreams, kInputScope))
        guard !streams.isEmpty else { return }
        let size = MemoryLayout<AudioHardwareIOProcStreamUsage>.size + MemoryLayout<UInt32>.size * streams.count
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { raw.deallocate() }
        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(streams.count)
        let flags = raw.advanced(by: MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!)
            .assumingMemoryBound(to: UInt32.self)
        var channel = 0
        for (i, stream) in streams.enumerated() {
            let fmt = CA.get(stream, addr(kAudioStreamPropertyVirtualFormat), default: AudioStreamBasicDescription())
            let n = max(1, Int(fmt.mChannelsPerFrame))
            let used = channel < start + count && channel + n > start
            flags[i] = used ? 1 : 0
            channel += n
        }
        var a = addr(kAudioDevicePropertyIOProcStreamUsage, kInputScope)
        let status = AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(size), raw)
        if status != noErr { NSLog("Cablebay: stream usage not set (%d)", status) }
    }

    static func deviceID(for uid: String) -> AudioObjectID? {
        for id in CA.getIDs(kSystemObject, addr(kAudioHardwarePropertyDevices))
            where CA.getString(id, addr(kAudioDevicePropertyDeviceUID)) == uid { return id }
        return nil
    }

    /// For an aggregate / multi-output device: its clock device and active sub-devices. Otherwise the device itself.
    static func physicalOutputs(for uid: String) -> (main: String, subs: [String]) {
        guard let device = deviceID(for: uid) else { return (uid, [uid]) }
        let subs = CA.getIDs(device, addr(kAudioAggregateDevicePropertyActiveSubDeviceList))
            .filter { CA.channelCount($0, scope: kOutputScope) > 0 }
            .compactMap { CA.getString($0, addr(kAudioDevicePropertyDeviceUID)) }
        guard !subs.isEmpty else { return (uid, [uid]) }
        let clock = CA.getString(device, addr(kAudioAggregateDevicePropertyMainSubDevice)) ?? ""
        return (subs.contains(clock) ? clock : subs[0], subs)
    }

    // MARK: Real-time render (no allocation, no locks)

    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               sourceStart: Int, sourceCount: Int,
                               masks: UnsafeMutablePointer<UInt8>,
                               chanBase: UnsafeMutablePointer<Int32>,
                               bufferCount: Int,
                               ctl: UnsafeMutablePointer<Float>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        // Find the left/right source channels.
        var lPtr: UnsafeMutablePointer<Float>? = nil
        var lStride = 1, lOff = 0, lFrames = 0
        var rPtr: UnsafeMutablePointer<Float>? = nil
        var rStride = 1, rOff = 0, rFrames = 0
        let rWant = sourceStart + (sourceCount > 1 ? 1 : 0)
        var acc = 0
        for b in 0..<inList.count {
            let buf = inList[b]
            let n = max(1, Int(buf.mNumberChannels))
            if lPtr == nil && sourceStart >= acc && sourceStart < acc + n {
                lPtr = buf.mData?.assumingMemoryBound(to: Float.self)
                lStride = n; lOff = sourceStart - acc; lFrames = Int(buf.mDataByteSize) / (4 * n)
            }
            if rPtr == nil && rWant >= acc && rWant < acc + n {
                rPtr = buf.mData?.assumingMemoryBound(to: Float.self)
                rStride = n; rOff = rWant - acc; rFrames = Int(buf.mDataByteSize) / (4 * n)
            }
            acc += n
        }

        let m1 = ctl[0], m0 = ctl[1], s1 = ctl[2], s0 = ctl[3]
        ctl[1] = m1
        ctl[3] = s1
        ctl[7] = 1

        var peak: Float = 0
        if let l = lPtr { for f in 0..<lFrames { peak = max(peak, abs(l[f * lStride + lOff])) } }
        if let r = rPtr { for f in 0..<rFrames { peak = max(peak, abs(r[f * rStride + rOff])) } }
        ctl[4] = max(ctl[4], peak)
        ctl[5] = max(ctl[5], peak * m1)
        ctl[6] = max(ctl[6], peak * s1)

        for b in 0..<outList.count {
            let ob = outList[b]
            guard let raw = ob.mData else { continue }
            let od = raw.assumingMemoryBound(to: Float.self)
            let och = max(1, Int(ob.mNumberChannels))
            let oframes = Int(ob.mDataByteSize) / (4 * och)
            let mask: UInt8 = b < bufferCount ? masks[b] : ChannelIO.monitorBit
            let base = b < bufferCount ? Int(chanBase[b]) : 0

            var g0: Float = 0, g1: Float = 0
            if mask & ChannelIO.monitorBit != 0 { g0 = m0; g1 = m1 }
            if mask & ChannelIO.streamBit != 0 { g0 = max(g0, s0); g1 = max(g1, s1) }
            if lPtr == nil || (g0 == 0 && g1 == 0) {
                memset(raw, 0, Int(ob.mDataByteSize))
                continue
            }

            for c in 0..<och {
                let deviceChannel = base + c
                var src: UnsafeMutablePointer<Float>? = nil
                var st = 1, off = 0, fr = 0
                if deviceChannel == 0 || (deviceChannel == 1 && rPtr == nil) {
                    src = lPtr; st = lStride; off = lOff; fr = lFrames
                } else if deviceChannel == 1 {
                    src = rPtr; st = rStride; off = rOff; fr = rFrames
                }
                let frames = min(oframes, fr)
                var f = 0
                if let s = src, frames > 0 {
                    let step = (g1 - g0) / Float(frames)
                    var g = g0
                    while f < frames {
                        od[f * och + c] = s[f * st + off] * g
                        g += step
                        f += 1
                    }
                }
                while f < oframes {
                    od[f * och + c] = 0
                    f += 1
                }
            }
        }
    }
}
