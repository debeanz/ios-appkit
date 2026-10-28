// CoreAudio's Mac hardware calls (AudioObject*, AudioHardware*PropertyListener, AudioDeviceDuck).
//
// Steam's libraries (steamclient, steamui, vgui2_s, SDL3, steamwebrtc) ask CoreAudio which
// audio devices there are and listen for changes. iOS has these functions, but an app isn't
// meant to call them: the first call starts iOS's audio hardware layer inside the app, with
// its plug-ins, and the Bluetooth one then kept an XPC thread about a quarter busy for as
// long as Steam ran (one of the things that made the phone warm). Its answers weren't usable
// either ('nope' to the device list, so Steam settled on "Null_Device").
//
// So these are answered here, without starting anything: the system object has no devices
// and no default ones, listeners are accepted and never called, nothing can be set. Sound
// itself doesn't come this way (the interface's sounds play in its web pages). tools/
// lib-routes.js routes CoreAudio through the shim so the client binds to these first.
//
// No CoreAudio headers here: the definitions only have to match the Mac signatures.
#import <stdint.h>
#import <stdio.h>

typedef int32_t AKOSStatus;
typedef uint32_t AKAudioObjectID;
typedef struct { uint32_t mSelector, mScope, mElement; } AKAudioPropertyAddress;
typedef AKOSStatus (*AKAudioListenerProc)(AKAudioObjectID, uint32_t, const AKAudioPropertyAddress *, void *);

#define FOURCC(a, b, c, d) ((uint32_t)(a) << 24 | (uint32_t)(b) << 16 | (uint32_t)(c) << 8 | (uint32_t)(d))
enum {
  kSystemObject = 1,
  kDevices = FOURCC('d', 'e', 'v', '#'),
  kDefaultInput = FOURCC('d', 'I', 'n', ' '),
  kDefaultOutput = FOURCC('d', 'O', 'u', 't'),
  kDefaultSystemOutput = FOURCC('s', 'O', 'u', 't'),
  kTranslateUIDToDevice = FOURCC('u', 'i', 'd', 'd'),
  kOwnedObjects = FOURCC('o', 'w', 'n', 'd'),
};
static const AKOSStatus kUnknownProperty = (AKOSStatus)FOURCC('w', 'h', 'o', '?');
static const AKOSStatus kBadObject = (AKOSStatus)FOURCC('!', 'o', 'b', 'j');
static const AKOSStatus kUnsupported = (AKOSStatus)FOURCC('u', 'n', 'o', 'p');
static const AKOSStatus kBadSize = (AKOSStatus)FOURCC('!', 's', 'i', 'z');

static void noteFirstCall(void) {
  static int told;
  if (!__atomic_exchange_n(&told, 1, __ATOMIC_RELAXED))
    fprintf(stderr, "[AppKitShim] CoreAudio hardware queries answered by the shim: no Mac audio devices on iOS\n");
}

// The size of a property's value, or 0 if the system object doesn't have it. Devices: an
// empty list; the defaults and UID lookups: one object ID, kAudioObjectUnknown.
static uint32_t sizeOf(AKAudioObjectID object, const AKAudioPropertyAddress *a, AKOSStatus *error) {
  *error = 0;
  if (object != kSystemObject) { *error = kBadObject; return 0; }
  switch (a ? a->mSelector : 0) {
    case kDevices: case kOwnedObjects: return 0;
    case kDefaultInput: case kDefaultOutput: case kDefaultSystemOutput: case kTranslateUIDToDevice: return sizeof(AKAudioObjectID);
    default: *error = kUnknownProperty; return 0;
  }
}

AKOSStatus AudioObjectGetPropertyDataSize(AKAudioObjectID object, const AKAudioPropertyAddress *address,
                                         uint32_t qualifierSize, const void *qualifier, uint32_t *outSize) {
  noteFirstCall();
  AKOSStatus error;
  uint32_t size = sizeOf(object, address, &error);
  if (outSize) *outSize = size;
  return error;
}

AKOSStatus AudioObjectGetPropertyData(AKAudioObjectID object, const AKAudioPropertyAddress *address, uint32_t qualifierSize,
                                     const void *qualifier, uint32_t *ioSize, void *outData) {
  noteFirstCall();
  AKOSStatus error;
  uint32_t size = sizeOf(object, address, &error);
  if (error) return error;
  if (!ioSize || *ioSize < size) return kBadSize;
  if (size) *(AKAudioObjectID *)outData = 0;   // kAudioObjectUnknown
  *ioSize = size;
  return 0;
}

uint8_t AudioObjectHasProperty(AKAudioObjectID object, const AKAudioPropertyAddress *address) {
  noteFirstCall();
  AKOSStatus error;
  sizeOf(object, address, &error);
  return error == 0;
}

AKOSStatus AudioObjectIsPropertySettable(AKAudioObjectID object, const AKAudioPropertyAddress *address, uint8_t *outSettable) {
  AKOSStatus error;
  sizeOf(object, address, &error);
  if (outSettable) *outSettable = 0;
  return error;
}

AKOSStatus AudioObjectSetPropertyData(AKAudioObjectID object, const AKAudioPropertyAddress *address, uint32_t qualifierSize,
                                     const void *qualifier, uint32_t size, const void *data) {
  return kUnsupported;
}

// Nothing ever changes, so a listener is never called.
AKOSStatus AudioObjectAddPropertyListener(AKAudioObjectID object, const AKAudioPropertyAddress *address,
                                         AKAudioListenerProc listener, void *clientData) {
  noteFirstCall();
  return object == kSystemObject ? 0 : kBadObject;
}

AKOSStatus AudioObjectRemovePropertyListener(AKAudioObjectID object, const AKAudioPropertyAddress *address,
                                            AKAudioListenerProc listener, void *clientData) {
  return 0;
}

AKOSStatus AudioHardwareAddPropertyListener(uint32_t property, void *listener, void *clientData) { return 0; }
AKOSStatus AudioHardwareRemovePropertyListener(uint32_t property, void *listener) { return 0; }

AKOSStatus AudioDeviceDuck(AKAudioObjectID device, float duckedLevel, const void *startTime, float rampDuration) { return 0; }
