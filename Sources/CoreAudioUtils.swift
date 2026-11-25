import CoreAudio
import Foundation

/// Four-character code helper ("prs#" -> UInt32).
func fourCC(_ s: String) -> UInt32 {
    return s.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

/// Selectors introduced after the macOS 11 SDK this project is compiled against.
enum CAConst {
    static let processObjectList: AudioObjectPropertySelector = fourCC("prs#") // kAudioHardwarePropertyProcessObjectList
    static let processPID: AudioObjectPropertySelector = fourCC("ppid")        // kAudioProcessPropertyPID
    static let processBundleID: AudioObjectPropertySelector = fourCC("pbid")   // kAudioProcessPropertyBundleID
    static let processIsRunningOutput: AudioObjectPropertySelector = fourCC("piro") // kAudioProcessPropertyIsRunningOutput
    static let tapFormat: AudioObjectPropertySelector = fourCC("tfmt")         // kAudioTapPropertyFormat
    static let virtualMainVolume: AudioObjectPropertySelector = fourCC("vmvc") // kAudioHardwareServiceDeviceProperty_VirtualMainVolume
}

let kSystemObject = AudioObjectID(kAudioObjectSystemObject)
let kGlobal = AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal)
let kOutputScope = AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput)
let kInputScope = AudioObjectPropertyScope(kAudioDevicePropertyScopeInput)

func addr(_ selector: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kGlobal,
          _ element: AudioObjectPropertyElement = 0) -> AudioObjectPropertyAddress {
    return AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

enum CA {
    static func has(_ obj: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        return AudioObjectHasProperty(obj, &a)
    }

    static func isSettable(_ obj: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(obj, &a, &settable) == noErr && settable.boolValue
    }

    static func get<T>(_ obj: AudioObjectID, _ address: AudioObjectPropertyAddress, default def: T) -> T {
        var a = address
        var value = def
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value)
        return status == noErr ? value : def
    }

    @discardableResult
    static func set<T>(_ obj: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var a = address
        var v = value
        let size = UInt32(MemoryLayout<T>.size)
        return AudioObjectSetPropertyData(obj, &a, 0, nil, size, &v)
    }

    static func getIDs(_ obj: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var a = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func getString(_ obj: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var a = address
        var ref: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) { ptr in
            AudioObjectGetPropertyData(obj, &a, 0, nil, &size, ptr)
        }
        guard status == noErr, let value = ref else { return nil }
        return value.takeRetainedValue() as String
    }

    static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
