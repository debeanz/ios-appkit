// CoreAudio's Mac hardware calls (AudioObject*, AudioHardware*PropertyListener, AudioDeviceDuck).
//
// Steam's libraries (steamclient, steamui, vgui2_s, SDL3, steamwebrtc) ask CoreAudio which
// audio devices there are and listen for changes. iOS has these functions, but an app isn't
// meant to call them: the first call starts iOS's audio hardware layer inside the app, with
// its plug-ins, and the Bluetooth one then kept an XPC thread about a quarter busy for as
// long as Steam ran (one of the things that made the phone warm). Its answers weren't usable
// either ('nope' to the device list, so Steam settled on "Null_Device").
//
// So these are answered here, without starting anything. To Steam's code the system object has
// no devices and no default ones; listeners are accepted and never called, nothing can be set.
// Sound itself doesn't come this way (the interface's sounds play in its web pages).
//
// A game's code (a Mac game Steam started, MacPrograms.m) sees one output device instead: the
// iPhone's sound output, stereo at 48 kHz, the default one. Mac sound engines pick a device
// before they play anything - FMOD (Unity), SDL, OpenAL Soft, Godot - and play nothing without
// one ("FMOD failed to initialize any audio devices"). Their output unit or audio queue is
// iOS's, which plays wherever iOS routes sound (GameAudio.m lets them choose this device).
// tools/lib-routes.js routes CoreAudio through the shim so both bind to these first.
//
// No CoreAudio headers here: the definitions only have to match the Mac signatures.
#import <CoreFoundation/CoreFoundation.h>
#import <stdbool.h>
#import <stdint.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>

typedef int32_t AKOSStatus;
typedef uint32_t AKAudioObjectID;
typedef struct { uint32_t mSelector, mScope, mElement; } AKAudioPropertyAddress;
typedef AKOSStatus (*AKAudioListenerProc)(AKAudioObjectID, uint32_t, const AKAudioPropertyAddress *, void *);
typedef struct { double mMinimum, mMaximum; } AKAudioValueRange;
typedef struct {
  double mSampleRate;
  uint32_t mFormatID, mFormatFlags, mBytesPerPacket, mFramesPerPacket, mBytesPerFrame, mChannelsPerFrame, mBitsPerChannel, mReserved;
} AKStreamDescription;
typedef struct { uint32_t mNumberChannels, mDataByteSize; void *mData; } AKAudioBuffer;

bool AKAddressIsInGame(const void *address);   // MacPrograms.m

#define FOURCC(a, b, c, d) ((uint32_t)(a) << 24 | (uint32_t)(b) << 16 | (uint32_t)(c) << 8 | (uint32_t)(d))
enum {
  kSystemObject = 1,
  kDevice = 0x41,   // AKGameAudioDevice, AKGameAudioStream (AKShimPrivate.h)
  kStream = 0x42,
  // The system object's
  kDevices = FOURCC('d', 'e', 'v', '#'),
  kDefaultInput = FOURCC('d', 'I', 'n', ' '),
  kDefaultOutput = FOURCC('d', 'O', 'u', 't'),
  kDefaultSystemOutput = FOURCC('s', 'O', 'u', 't'),
  kTranslateUIDToDevice = FOURCC('u', 'i', 'd', 'd'),
  kOwnedObjects = FOURCC('o', 'w', 'n', 'd'),
  kRunLoop = FOURCC('r', 'n', 'l', 'p'),
  kInitingOrExiting = FOURCC('i', 'n', 'o', 't'),
  // Any object's
  kClass = FOURCC('c', 'l', 'a', 's'),
  kBaseClass = FOURCC('b', 'c', 'l', 's'),
  kName = FOURCC('l', 'n', 'a', 'm'),
  kManufacturer = FOURCC('l', 'm', 'a', 'k'),
  // The device's
  kDeviceName = FOURCC('n', 'a', 'm', 'e'),
  kDeviceManufacturer = FOURCC('m', 'a', 'k', 'r'),
  kDeviceUID = FOURCC('u', 'i', 'd', ' '),
  kModelUID = FOURCC('m', 'u', 'i', 'd'),
  kTransportType = FOURCC('t', 'r', 'a', 'n'),
  kIsAlive = FOURCC('l', 'i', 'v', 'n'),
  kIsRunning = FOURCC('g', 'o', 'i', 'n'),
  kIsRunningSomewhere = FOURCC('g', 'o', 'n', 'e'),
  kCanBeDefault = FOURCC('d', 'f', 'l', 't'),
  kCanBeSystemDefault = FOURCC('s', 'f', 'l', 't'),
  kIsHidden = FOURCC('h', 'i', 'd', 'n'),
  kLatency = FOURCC('l', 't', 'n', 'c'),
  kSafetyOffset = FOURCC('s', 'a', 'f', 't'),
  kClockDomain = FOURCC('c', 'l', 'k', 'd'),
  kStreams = FOURCC('s', 't', 'm', '#'),
  kStreamConfiguration = FOURCC('s', 'l', 'a', 'y'),
  kNominalSampleRate = FOURCC('n', 's', 'r', 't'),
  kAvailableSampleRates = FOURCC('n', 's', 'r', '#'),
  kBufferFrameSize = FOURCC('f', 's', 'i', 'z'),
  kBufferFrameSizeRange = FOURCC('f', 's', 'z', '#'),
  kHogMode = FOURCC('o', 'i', 'n', 'k'),
  kPreferredStereo = FOURCC('d', 'c', 'h', '2'),
  kVolumeScalar = FOURCC('v', 'o', 'l', 'm'),
  kMute = FOURCC('m', 'u', 't', 'e'),
  // The stream's
  kDirection = FOURCC('s', 'd', 'i', 'r'),
  kTerminalType = FOURCC('t', 'e', 'r', 'm'),
  kStartingChannel = FOURCC('s', 'c', 'h', 'n'),
  kVirtualFormat = FOURCC('s', 'f', 'm', 't'),
  kPhysicalFormat = FOURCC('p', 'f', 't', ' '),
  // Scopes
  kScopeInput = FOURCC('i', 'n', 'p', 't'),
};
static const AKOSStatus kUnknownProperty = (AKOSStatus)FOURCC('w', 'h', 'o', '?');
static const AKOSStatus kBadObject = (AKOSStatus)FOURCC('!', 'o', 'b', 'j');
static const AKOSStatus kUnsupported = (AKOSStatus)FOURCC('u', 'n', 'o', 'p');
static const AKOSStatus kBadSize = (AKOSStatus)FOURCC('!', 's', 'i', 'z');
static const AKOSStatus kIllegalOperation = (AKOSStatus)FOURCC('n', 'o', 'p', 'e');

const char *const AKGameAudioDeviceUID = "AppKitShim:GameOutput";

// What the device runs at: the iPhone's own rate, and the buffer a game last asked for (its
// output unit asks iOS for the same; GameAudio.m).
static const double kSampleRate = 48000;
static _Atomic uint32_t gBufferFrames = 512;
void AKGameAudioSetBufferFrames(uint32_t frames);

static void noteFirstCall(void) {
  static int told;
  if (!__atomic_exchange_n(&told, 1, __ATOMIC_RELAXED))
    fprintf(stderr, "[AppKitShim] CoreAudio hardware queries answered by the shim: no Mac audio devices for Steam, "
                    "the iPhone's sound output for its games\n");
}

static void noteGameCall(void) {
  static int told;
  if (!__atomic_exchange_n(&told, 1, __ATOMIC_RELAXED))
    fprintf(stderr, "[AppKitShim] game audio: its code asked CoreAudio for devices: one output, the iPhone's (stereo, 48 kHz)\n");
}

static AKStreamDescription streamFormat(void) {
  // 32-bit float, interleaved, packed: kAudioFormatLinearPCM with kAudioFormatFlagIsFloat | IsPacked.
  return (AKStreamDescription){ kSampleRate, FOURCC('l', 'p', 'c', 'm'), 1 | 8, 8, 1, 8, 2, 32, 0 };
}

// Each property's value, written to `out` (*size bytes of room; NULL asks only its size). A
// CFString is a new one, as CoreAudio's are; the caller releases it.
typedef struct { uint8_t bytes[64]; } AKValue;

static CFStringRef text(const char *s) { return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8); }

static AKOSStatus answer(bool game, AKAudioObjectID object, const AKAudioPropertyAddress *a, uint32_t qualifierSize,
                         const void *qualifier, uint32_t *size, void *out) {
  if (!a) return kUnknownProperty;
  bool input = a->mScope == kScopeInput;
  AKValue v;
  memset(&v, 0, sizeof v);
  uint32_t n = 0;
  CFStringRef string = NULL;
#define PUT(type, value) do { type _x = (value); memcpy(v.bytes, &_x, sizeof _x); n = sizeof _x; } while (0)
  if (object == kSystemObject) {
    switch (a->mSelector) {
      case kDevices: case kOwnedObjects:
        if (game) PUT(uint32_t, kDevice);
        break;
      case kDefaultOutput: case kDefaultSystemOutput: PUT(uint32_t, game ? kDevice : 0); break;
      case kDefaultInput: PUT(uint32_t, 0); break;   // no microphone (it would need the user's permission)
      case kTranslateUIDToDevice: {
        uint32_t found = 0;
        if (game && qualifier && qualifierSize >= sizeof(CFStringRef)) {
          CFStringRef uid = *(const CFStringRef *)qualifier;
          char chars[64];
          if (uid && CFStringGetCString(uid, chars, sizeof chars, kCFStringEncodingUTF8) && !strcmp(chars, AKGameAudioDeviceUID)) found = kDevice;
        }
        PUT(uint32_t, found);
        break;
      }
      case kClass: PUT(uint32_t, FOURCC('a', 's', 'y', 's')); break;
      case kInitingOrExiting: PUT(uint32_t, 0); break;
      case kRunLoop: if (!game) return kUnknownProperty; PUT(CFRunLoopRef, NULL); break;
      default: return kUnknownProperty;
    }
  } else if (game && object == kDevice) {
    switch (a->mSelector) {
      case kClass: PUT(uint32_t, FOURCC('a', 'd', 'e', 'v')); break;
      case kBaseClass: PUT(uint32_t, FOURCC('a', 'o', 'b', 'j')); break;
      case kName: string = text("iPhone"); break;
      case kManufacturer: string = text("Apple Inc."); break;
      case kDeviceName: n = 7; memcpy(v.bytes, "iPhone", 7); break;
      case kDeviceManufacturer: n = 11; memcpy(v.bytes, "Apple Inc.", 11); break;
      case kDeviceUID: string = text(AKGameAudioDeviceUID); break;
      case kModelUID: string = text("AppKitShim:GameOutputModel"); break;
      case kTransportType: PUT(uint32_t, FOURCC('b', 'l', 't', 'n')); break;   // built in
      case kIsAlive: case kCanBeDefault: case kCanBeSystemDefault: PUT(uint32_t, !input); break;
      case kIsRunning: case kIsRunningSomewhere: case kIsHidden: case kClockDomain: PUT(uint32_t, 0); break;
      case kLatency: case kSafetyOffset: PUT(uint32_t, 0); break;
      case kOwnedObjects: case kStreams: if (!input) PUT(uint32_t, kStream); break;
      case kStreamConfiguration: {
        // AudioBufferList: its count, then (8-aligned) one stereo buffer for output, none for input.
        uint32_t buffers = input ? 0 : 1;
        memcpy(v.bytes, &buffers, 4);
        AKAudioBuffer b = { 2, 0, NULL };
        if (buffers) memcpy(v.bytes + 8, &b, sizeof b);
        n = 8 + buffers * (uint32_t)sizeof b;
        break;
      }
      case kNominalSampleRate: PUT(double, kSampleRate); break;
      case kAvailableSampleRates: PUT(AKAudioValueRange, ((AKAudioValueRange){ kSampleRate, kSampleRate })); break;
      case kBufferFrameSize: PUT(uint32_t, gBufferFrames); break;
      case kBufferFrameSizeRange: PUT(AKAudioValueRange, ((AKAudioValueRange){ 64, 4096 })); break;
      case kHogMode: PUT(int32_t, -1); break;
      case kPreferredStereo: { uint32_t ch[2] = { 1, 2 }; memcpy(v.bytes, ch, 8); n = 8; break; }
      case kVolumeScalar: if (input) return kUnknownProperty; PUT(float, 1.0f); break;
      case kMute: if (input) return kUnknownProperty; PUT(uint32_t, 0); break;
      default: return kUnknownProperty;
    }
  } else if (game && object == kStream) {
    switch (a->mSelector) {
      case kClass: PUT(uint32_t, FOURCC('a', 's', 't', 'r')); break;
      case kBaseClass: PUT(uint32_t, FOURCC('a', 'o', 'b', 'j')); break;
      case kDirection: PUT(uint32_t, 0); break;   // output
      case kTerminalType: PUT(uint32_t, FOURCC('s', 'p', 'k', 'r')); break;
      case kStartingChannel: PUT(uint32_t, 1); break;
      case kLatency: PUT(uint32_t, 0); break;
      case kIsAlive: PUT(uint32_t, 1); break;
      case kVirtualFormat: case kPhysicalFormat: PUT(AKStreamDescription, streamFormat()); break;
      default: return kUnknownProperty;
    }
  } else {
    return kBadObject;
  }
#undef PUT
  if (string) {
    n = sizeof string;
    memcpy(v.bytes, &string, n);
  }
  if (out && *size < n) {
    if (string) CFRelease(string);
    return kBadSize;
  }
  if (out) memcpy(out, v.bytes, n);   // the string, if one, is the caller's now
  else if (string) CFRelease(string);
  *size = n;
  return 0;
}

#define GAME_CALLER AKAddressIsInGame(__builtin_return_address(0))

AKOSStatus AudioObjectGetPropertyDataSize(AKAudioObjectID object, const AKAudioPropertyAddress *address,
                                         uint32_t qualifierSize, const void *qualifier, uint32_t *outSize) {
  noteFirstCall();
  bool game = GAME_CALLER;
  if (game) noteGameCall();
  uint32_t size = 0;
  AKOSStatus error = answer(game, object, address, qualifierSize, qualifier, &size, NULL);
  if (outSize) *outSize = error ? 0 : size;
  return error;
}

AKOSStatus AudioObjectGetPropertyData(AKAudioObjectID object, const AKAudioPropertyAddress *address, uint32_t qualifierSize,
                                     const void *qualifier, uint32_t *ioSize, void *outData) {
  noteFirstCall();
  bool game = GAME_CALLER;
  if (game) noteGameCall();
  if (!ioSize) return kBadSize;
  return answer(game, object, address, qualifierSize, qualifier, ioSize, outData);
}

uint8_t AudioObjectHasProperty(AKAudioObjectID object, const AKAudioPropertyAddress *address) {
  noteFirstCall();
  uint32_t size = 0;
  return answer(GAME_CALLER, object, address, 0, NULL, &size, NULL) == 0;
}

// A game may set the device's rate (to the one it runs at), buffer size and hog mode, and the
// system's run loop for notifications (none come).
static bool settable(bool game, AKAudioObjectID object, uint32_t selector) {
  if (!game) return false;
  if (object == kSystemObject) return selector == kRunLoop;
  if (object == kDevice) return selector == kNominalSampleRate || selector == kBufferFrameSize || selector == kHogMode;
  if (object == kStream) return selector == kVirtualFormat || selector == kPhysicalFormat;
  return false;
}

AKOSStatus AudioObjectIsPropertySettable(AKAudioObjectID object, const AKAudioPropertyAddress *address, uint8_t *outSettable) {
  bool game = GAME_CALLER;
  uint32_t size = 0;
  AKOSStatus error = answer(game, object, address, 0, NULL, &size, NULL);
  if (outSettable) *outSettable = !error && settable(game, object, address->mSelector);
  return error;
}

AKOSStatus AudioObjectSetPropertyData(AKAudioObjectID object, const AKAudioPropertyAddress *address, uint32_t qualifierSize,
                                     const void *qualifier, uint32_t size, const void *data) {
  bool game = GAME_CALLER;
  if (!address || !settable(game, object, address->mSelector)) return kUnsupported;
  switch (address->mSelector) {
    case kNominalSampleRate:   // the rate it has; its output unit converts any other
      return size >= sizeof(double) && *(const double *)data == kSampleRate ? 0 : kIllegalOperation;
    case kBufferFrameSize:
      if (size < 4) return kBadSize;
      AKGameAudioSetBufferFrames(*(const uint32_t *)data);
      return 0;
    default:
      return 0;
  }
}

uint32_t AKGameAudioBufferFrames(void) { return gBufferFrames; }
void AKGameAudioSetBufferFrames(uint32_t frames) { gBufferFrames = frames < 64 ? 64 : frames > 4096 ? 4096 : frames; }

// Nothing ever changes, so a listener is never called.
AKOSStatus AudioObjectAddPropertyListener(AKAudioObjectID object, const AKAudioPropertyAddress *address,
                                         AKAudioListenerProc listener, void *clientData) {
  noteFirstCall();
  return object == kSystemObject || (GAME_CALLER && (object == kDevice || object == kStream)) ? 0 : kBadObject;
}

AKOSStatus AudioObjectRemovePropertyListener(AKAudioObjectID object, const AKAudioPropertyAddress *address,
                                            AKAudioListenerProc listener, void *clientData) {
  return 0;
}

AKOSStatus AudioObjectAddPropertyListenerBlock(AKAudioObjectID object, const AKAudioPropertyAddress *address, void *queue, void *block) {
  noteFirstCall();
  return object == kSystemObject || (GAME_CALLER && (object == kDevice || object == kStream)) ? 0 : kBadObject;
}

AKOSStatus AudioObjectRemovePropertyListenerBlock(AKAudioObjectID object, const AKAudioPropertyAddress *address, void *queue, void *block) {
  return 0;
}

AKOSStatus AudioHardwareAddPropertyListener(uint32_t property, void *listener, void *clientData) { return 0; }
AKOSStatus AudioHardwareRemovePropertyListener(uint32_t property, void *listener) { return 0; }

AKOSStatus AudioDeviceDuck(AKAudioObjectID device, float duckedLevel, const void *startTime, float rampDuration) { return 0; }
