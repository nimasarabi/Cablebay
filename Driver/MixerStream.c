// Mixer Stream — a 2-channel loopback audio device (AudioServerPlugIn).
// Whatever is played to "Mixer Stream" comes back out of its input, so other apps
// (OBS, Zoom, Discord…) can record the Cablebay stream mix as a microphone.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <dispatch/dispatch.h>

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device = 2,
    kObjectID_StreamInput = 3,
    kObjectID_StreamOutput = 4,
};

#define kDeviceUID       "VolumeMixerStream_UID"
#define kDeviceModelUID  "VolumeMixerStream_ModelUID"
#define kDeviceName      "Mixer Stream"
#define kManufacturer    "Cablebay"
#define kChannels        2
#define kRingFrames      16384

static const Float64 kSampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
#define kNumSampleRates (sizeof(kSampleRates) / sizeof(kSampleRates[0]))

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 0;
static Float64 gSampleRate = 48000.0;
static UInt32 gIOCount = 0;
static Float64 gHostTicksPerFrame = 0.0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gNumberTimeStamps = 0;
static Boolean gInputActive = true;
static Boolean gOutputActive = true;

static Float32 gRing[kRingFrames * kChannels];
static _Atomic Float64 gRunStart = 0;   // first sample time of the current contiguous write run
static _Atomic Float64 gWriteEnd = 0;   // sample time just after the last written frame

// MARK: - Forward declarations

static HRESULT  MS_QueryInterface(void*, REFIID, LPVOID*);
static ULONG    MS_AddRef(void*);
static ULONG    MS_Release(void*);
static OSStatus MS_Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus MS_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus MS_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus MS_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus MS_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus MS_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus MS_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static Boolean  MS_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus MS_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus MS_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus MS_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus MS_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
static OSStatus MS_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus MS_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus MS_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus MS_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus MS_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus MS_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus MS_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    MS_QueryInterface, MS_AddRef, MS_Release,
    MS_Initialize, MS_CreateDevice, MS_DestroyDevice,
    MS_AddDeviceClient, MS_RemoveDeviceClient,
    MS_PerformDeviceConfigurationChange, MS_AbortDeviceConfigurationChange,
    MS_HasProperty, MS_IsPropertySettable, MS_GetPropertyDataSize, MS_GetPropertyData, MS_SetPropertyData,
    MS_StartIO, MS_StopIO, MS_GetZeroTimeStamp,
    MS_WillDoIOOperation, MS_BeginIOOperation, MS_DoIOOperation, MS_EndIOOperation
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// MARK: - Factory

void* MixerStream_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);
void* MixerStream_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    (void)allocator;
    if (CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

// MARK: - IUnknown

static HRESULT MS_QueryInterface(void* driver, REFIID uuid, LPVOID* outInterface) {
    if (driver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        ++gRefCount;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = 0;
    }
    CFRelease(requested);
    return result;
}

static ULONG MS_AddRef(void* driver) {
    if (driver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG r = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

static ULONG MS_Release(void* driver) {
    if (driver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) --gRefCount;
    ULONG r = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

// MARK: - Basic operations

static void UpdateTiming(void) {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    Float64 hostClockFrequency = 1.0e9 * (Float64)info.denom / (Float64)info.numer;
    gHostTicksPerFrame = hostClockFrequency / gSampleRate;
}

static OSStatus MS_Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    if (driver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = host;
    UpdateTiming();
    memset(gRing, 0, sizeof(gRing));
    return 0;
}

static OSStatus MS_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* c, AudioObjectID* out) {
    (void)d; (void)desc; (void)c; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus MS_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) {
    (void)d; (void)id;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus MS_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* c) {
    (void)c;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (id != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}

static OSStatus MS_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* c) {
    (void)c;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (id != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}

static OSStatus MS_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void* info) {
    (void)info;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (id != kObjectID_Device) return kAudioHardwareBadDeviceError;
    Float64 rate = (Float64)action;
    Boolean valid = false;
    for (UInt32 i = 0; i < kNumSampleRates; ++i) if (kSampleRates[i] == rate) valid = true;
    if (!valid) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&gStateMutex);
    gSampleRate = rate;
    UpdateTiming();
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus MS_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void* info) {
    (void)action; (void)info;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (id != kObjectID_Device) return kAudioHardwareBadDeviceError;
    return 0;
}

// MARK: - Property helpers

static AudioStreamBasicDescription MakeFormat(Float64 rate) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof(f));
    f.mSampleRate = rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = kChannels * sizeof(Float32);
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = kChannels * sizeof(Float32);
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

static Boolean IsStream(AudioObjectID id) {
    return id == kObjectID_StreamInput || id == kObjectID_StreamOutput;
}

static UInt32 DeviceStreams(AudioObjectPropertyScope scope, AudioObjectID* out) {
    UInt32 n = 0;
    if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeInput) out[n++] = kObjectID_StreamInput;
    if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeOutput) out[n++] = kObjectID_StreamOutput;
    return n;
}

static Boolean MS_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a) {
    (void)pid;
    if (d != gDriverRef || a == NULL) return false;
    switch (id) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBoxList: case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyDeviceList: case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        }
        return false;
    case kObjectID_Device:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning: case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyNominalSampleRate: case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden: case kAudioDevicePropertyZeroTimeStampPeriod: case kAudioDevicePropertyStreams:
            return true;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyPreferredChannelsForStereo: case kAudioDevicePropertyPreferredChannelLayout:
            return a->mScope == kAudioObjectPropertyScopeInput || a->mScope == kAudioObjectPropertyScopeOutput;
        }
        return false;
    case kObjectID_StreamInput:
    case kObjectID_StreamOutput:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects: case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType: case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        }
        return false;
    }
    return false;
}

static OSStatus MS_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a, Boolean* out) {
    if (d != gDriverRef || a == NULL || out == NULL) return kAudioHardwareIllegalOperationError;
    if (!MS_HasProperty(d, id, pid, a)) return kAudioHardwareUnknownPropertyError;
    *out = false;
    if (id == kObjectID_Device && a->mSelector == kAudioDevicePropertyNominalSampleRate) *out = true;
    if (IsStream(id) && (a->mSelector == kAudioStreamPropertyIsActive ||
                         a->mSelector == kAudioStreamPropertyVirtualFormat ||
                         a->mSelector == kAudioStreamPropertyPhysicalFormat)) *out = true;
    return 0;
}

// Computes the property size, and fills outData when it is non-NULL.
static OSStatus GetProperty(AudioObjectID id, const AudioObjectPropertyAddress* a,
                            UInt32 qualSize, const void* qual,
                            UInt32 inSize, UInt32* outSize, void* outData) {
#define RETURN_VALUE(TYPE, VALUE) do { \
        *outSize = sizeof(TYPE); \
        if (outData) { if (inSize < sizeof(TYPE)) return kAudioHardwareBadPropertySizeError; *(TYPE*)outData = (VALUE); } \
        return 0; } while (0)

    switch (id) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: RETURN_VALUE(CFStringRef, CFSTR(kManufacturer));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: RETURN_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioPlugInPropertyBoxList: *outSize = 0; return 0;
        case kAudioPlugInPropertyTranslateUIDToBox: RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID result = kAudioObjectUnknown;
            if (qualSize == sizeof(CFStringRef) && qual != NULL) {
                CFStringRef uid = *(const CFStringRef*)qual;
                if (uid && CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo) result = kObjectID_Device;
            }
            RETURN_VALUE(AudioObjectID, result);
        }
        case kAudioPlugInPropertyResourceBundle: RETURN_VALUE(CFStringRef, CFSTR(""));
        }
        break;

    case kObjectID_Device:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjectID_PlugIn);
        case kAudioObjectPropertyName: RETURN_VALUE(CFStringRef, CFSTR(kDeviceName));
        case kAudioObjectPropertyManufacturer: RETURN_VALUE(CFStringRef, CFSTR(kManufacturer));
        case kAudioDevicePropertyDeviceUID: RETURN_VALUE(CFStringRef, CFSTR(kDeviceUID));
        case kAudioDevicePropertyModelUID: RETURN_VALUE(CFStringRef, CFSTR(kDeviceModelUID));
        case kAudioDevicePropertyTransportType: RETURN_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: RETURN_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioDevicePropertyClockDomain: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: RETURN_VALUE(UInt32, gIOCount > 0 ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyLatency: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyIsHidden: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_VALUE(UInt32, kRingFrames);
        case kAudioDevicePropertyNominalSampleRate: RETURN_VALUE(Float64, gSampleRate);
        case kAudioObjectPropertyControlList: *outSize = 0; return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            AudioObjectID ids[2];
            UInt32 n = DeviceStreams(a->mScope, ids);
            UInt32 count = outData ? (inSize / sizeof(AudioObjectID) < n ? inSize / sizeof(AudioObjectID) : n) : n;
            if (outData) memcpy(outData, ids, count * sizeof(AudioObjectID));
            *outSize = count * sizeof(AudioObjectID);
            return 0;
        }
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            UInt32 n = kNumSampleRates;
            if (outData && inSize / sizeof(AudioValueRange) < n) n = inSize / sizeof(AudioValueRange);
            if (outData) {
                AudioValueRange* r = (AudioValueRange*)outData;
                for (UInt32 i = 0; i < n; ++i) { r[i].mMinimum = kSampleRates[i]; r[i].mMaximum = kSampleRates[i]; }
            }
            *outSize = n * sizeof(AudioValueRange);
            return 0;
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            *outSize = 2 * sizeof(UInt32);
            if (outData) {
                if (inSize < *outSize) return kAudioHardwareBadPropertySizeError;
                ((UInt32*)outData)[0] = 1;
                ((UInt32*)outData)[1] = 2;
            }
            return 0;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription));
            *outSize = size;
            if (outData) {
                if (inSize < size) return kAudioHardwareBadPropertySizeError;
                AudioChannelLayout* l = (AudioChannelLayout*)outData;
                memset(l, 0, size);
                l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                l->mNumberChannelDescriptions = kChannels;
                l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
                l->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            }
            return 0;
        }
        }
        break;

    case kObjectID_StreamInput:
    case kObjectID_StreamOutput: {
        Boolean isInput = (id == kObjectID_StreamInput);
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects: *outSize = 0; return 0;
        case kAudioStreamPropertyIsActive: RETURN_VALUE(UInt32, (isInput ? gInputActive : gOutputActive) ? 1 : 0);
        case kAudioStreamPropertyDirection: RETURN_VALUE(UInt32, isInput ? 1 : 0);
        case kAudioStreamPropertyTerminalType:
            RETURN_VALUE(UInt32, isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency: RETURN_VALUE(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            RETURN_VALUE(AudioStreamBasicDescription, MakeFormat(gSampleRate));
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            UInt32 n = kNumSampleRates;
            if (outData && inSize / sizeof(AudioStreamRangedDescription) < n) n = inSize / sizeof(AudioStreamRangedDescription);
            if (outData) {
                AudioStreamRangedDescription* r = (AudioStreamRangedDescription*)outData;
                for (UInt32 i = 0; i < n; ++i) {
                    r[i].mFormat = MakeFormat(kSampleRates[i]);
                    r[i].mSampleRateRange.mMinimum = kSampleRates[i];
                    r[i].mSampleRateRange.mMaximum = kSampleRates[i];
                }
            }
            *outSize = n * sizeof(AudioStreamRangedDescription);
            return 0;
        }
        }
        break;
    }
    }
    return kAudioHardwareUnknownPropertyError;
#undef RETURN_VALUE
}

static OSStatus MS_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
                                       UInt32 qualSize, const void* qual, UInt32* outSize) {
    (void)pid;
    if (d != gDriverRef || a == NULL || outSize == NULL) return kAudioHardwareIllegalOperationError;
    return GetProperty(id, a, qualSize, qual, 0, outSize, NULL);
}

static OSStatus MS_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
                                   UInt32 qualSize, const void* qual, UInt32 inSize, UInt32* outSize, void* outData) {
    (void)pid;
    if (d != gDriverRef || a == NULL || outSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    return GetProperty(id, a, qualSize, qual, inSize, outSize, outData);
}

static OSStatus RequestRate(Float64 rate) {
    Boolean valid = false;
    for (UInt32 i = 0; i < kNumSampleRates; ++i) if (kSampleRates[i] == rate) valid = true;
    if (!valid) return kAudioDeviceUnsupportedFormatError;
    if (rate == gSampleRate || gHost == NULL) return 0;
    // Must not call back into the host from inside SetPropertyData: that can deadlock coreaudiod.
    AudioServerPlugInHostRef host = gHost;
    UInt64 action = (UInt64)rate;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        host->RequestDeviceConfigurationChange(host, kObjectID_Device, action, NULL);
    });
    return 0;
}

static OSStatus MS_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
                                   UInt32 qualSize, const void* qual, UInt32 inSize, const void* inData) {
    (void)pid; (void)qualSize; (void)qual;
    if (d != gDriverRef || a == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;

    if (id == kObjectID_Device && a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return RequestRate(*(const Float64*)inData);
    }
    if (IsStream(id)) {
        if (a->mSelector == kAudioStreamPropertyIsActive) {
            if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gStateMutex);
            if (id == kObjectID_StreamInput) gInputActive = *(const UInt32*)inData != 0;
            else gOutputActive = *(const UInt32*)inData != 0;
            pthread_mutex_unlock(&gStateMutex);
            if (gHost) {
                AudioServerPlugInHostRef host = gHost;
                AudioObjectID object = id;
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    AudioObjectPropertyAddress changed = { kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                    host->PropertiesChanged(host, object, 1, &changed);
                });
            }
            return 0;
        }
        if (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat) {
            if (inSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            const AudioStreamBasicDescription* f = (const AudioStreamBasicDescription*)inData;
            if (f->mFormatID != kAudioFormatLinearPCM || f->mChannelsPerFrame != kChannels || f->mBitsPerChannel != 32 ||
                !(f->mFormatFlags & kAudioFormatFlagIsFloat)) return kAudioDeviceUnsupportedFormatError;
            return RequestRate(f->mSampleRate);
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

// MARK: - IO

static OSStatus MS_StartIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    (void)client;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (id != kObjectID_Device) return kAudioHardwareBadDeviceError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount == 0) {
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
        memset(gRing, 0, sizeof(gRing));
        atomic_store(&gRunStart, 0);
        atomic_store(&gWriteEnd, 0);
    }
    ++gIOCount;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus MS_StopIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    (void)client;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (id != kObjectID_Device) return kAudioHardwareBadDeviceError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount > 0) --gIOCount;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus MS_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client,
                                    Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)client;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (id != kObjectID_Device) return kAudioHardwareBadDeviceError;
    pthread_mutex_lock(&gStateMutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerRing = gHostTicksPerFrame * (Float64)kRingFrames;
    UInt64 next = gAnchorHostTime + (UInt64)((Float64)(gNumberTimeStamps + 1) * ticksPerRing);
    if (now >= next) ++gNumberTimeStamps;
    *outSampleTime = (Float64)(gNumberTimeStamps * kRingFrames);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gNumberTimeStamps * ticksPerRing);
    *outSeed = 1;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus MS_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op,
                                     Boolean* outWillDo, Boolean* outInPlace) {
    (void)client;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (id != kObjectID_Device) return kAudioHardwareBadDeviceError;
    Boolean will = (op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix);
    if (outWillDo) *outWillDo = will;
    if (outInPlace) *outInPlace = true;
    return 0;
}

static OSStatus MS_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, UInt32 frames,
                                    const AudioServerPlugInIOCycleInfo* info) {
    (void)client; (void)op; (void)frames; (void)info;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (id != kObjectID_Device) return kAudioHardwareBadDeviceError;
    return 0;
}

static OSStatus MS_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, UInt32 frames,
                                  const AudioServerPlugInIOCycleInfo* info) {
    (void)client; (void)op; (void)frames; (void)info;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (id != kObjectID_Device) return kAudioHardwareBadDeviceError;
    return 0;
}

static OSStatus MS_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, AudioObjectID stream, UInt32 client, UInt32 op,
                                 UInt32 frames, const AudioServerPlugInIOCycleInfo* info, void* mainBuffer, void* secondary) {
    (void)client; (void)secondary;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (id != kObjectID_Device) return kAudioHardwareBadDeviceError;
    if (mainBuffer == NULL || info == NULL) return 0;
    Float32* buf = (Float32*)mainBuffer;

    if (op == kAudioServerPlugInIOOperationWriteMix && stream == kObjectID_StreamOutput) {
        Float64 start = info->mOutputTime.mSampleTime;
        if (start < 0) return 0; // casting a negative time to UInt64 is undefined
        if (start != atomic_load(&gWriteEnd)) atomic_store(&gRunStart, start); // discontinuity: new run
        if (frames > kRingFrames) { // keep only the newest ring's worth so the copy can't overrun gRing
            UInt32 skip = frames - kRingFrames;
            buf += (size_t)skip * kChannels;
            start += skip;
            frames = kRingFrames;
        }
        UInt64 pos = (UInt64)start % kRingFrames;
        UInt32 first = frames < kRingFrames - pos ? frames : (UInt32)(kRingFrames - pos);
        memcpy(&gRing[pos * kChannels], buf, first * kChannels * sizeof(Float32));
        if (frames > first) memcpy(gRing, buf + first * kChannels, (frames - first) * kChannels * sizeof(Float32));
        atomic_store(&gWriteEnd, start + frames);
    } else if (op == kAudioServerPlugInIOOperationReadInput && stream == kObjectID_StreamInput) {
        Float64 start = info->mInputTime.mSampleTime;
        Float64 runStart = atomic_load(&gRunStart);
        Float64 writeEnd = atomic_load(&gWriteEnd);
        Float64 validFrom = runStart > writeEnd - kRingFrames ? runStart : writeEnd - kRingFrames;
        for (UInt32 f = 0; f < frames; ++f) {
            Float64 t = start + f;
            if (t >= validFrom && t < writeEnd && t >= 0) {
                UInt64 pos = (UInt64)t % kRingFrames;
                buf[f * kChannels] = gRing[pos * kChannels];
                buf[f * kChannels + 1] = gRing[pos * kChannels + 1];
            } else {
                buf[f * kChannels] = 0;
                buf[f * kChannels + 1] = 0;
            }
        }
    }
    return 0;
}
