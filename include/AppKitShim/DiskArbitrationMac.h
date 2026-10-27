// DiskArbitration — macOS's disk and volume notifications (mount, eject, disk appeared).
// iOS apps have no access to disks: sessions and callback registration work, but no disk
// ever appears, and operations on a disk report that it isn't there.
#import <CoreFoundation/CoreFoundation.h>
#import <MacTypes.h>

typedef struct __DASession *DASessionRef;
typedef struct __DADisk *DADiskRef;
typedef struct __DADissenter *DADissenterRef;
typedef int32_t DAReturn;
typedef uint32_t DADiskClaimOptions;
typedef uint32_t DADiskUnmountOptions;
typedef uint32_t DADiskEjectOptions;

enum {
  kDAReturnSuccess = 0,
  kDAReturnError = (int32_t)0xF8DA0001,
  kDAReturnBusy = (int32_t)0xF8DA0002,
  kDAReturnBadArgument = (int32_t)0xF8DA0003,
  kDAReturnNotFound = (int32_t)0xF8DA0005,
  kDAReturnUnsupported = (int32_t)0xF8DA0008,
};

typedef void (*DADiskAppearedCallback)(DADiskRef disk, void *context);
typedef void (*DADiskDisappearedCallback)(DADiskRef disk, void *context);
typedef void (*DADiskDescriptionChangedCallback)(DADiskRef disk, CFArrayRef keys, void *context);
typedef void (*DADiskUnmountCallback)(DADiskRef disk, DADissenterRef dissenter, void *context);
typedef void (*DADiskEjectCallback)(DADiskRef disk, DADissenterRef dissenter, void *context);
typedef void (*DADiskClaimCallback)(DADiskRef disk, DADissenterRef dissenter, void *context);
typedef DADissenterRef (*DADiskClaimReleaseCallback)(DADiskRef disk, void *context);

extern const CFStringRef kDADiskDescriptionDeviceModelKey;
extern const CFStringRef kDADiskDescriptionDeviceRevisionKey;
extern const CFStringRef kDADiskDescriptionDeviceVendorKey;
extern const CFStringRef kDADiskDescriptionMediaBSDNameKey;
extern const CFStringRef kDADiskDescriptionMediaRemovableKey;
extern const CFStringRef kDADiskDescriptionMediaSizeKey;
extern const CFStringRef kDADiskDescriptionMediaUUIDKey;
extern const CFStringRef kDADiskDescriptionVolumeNameKey;
extern const CFStringRef kDADiskDescriptionVolumePathKey;
extern const CFStringRef kDADiskDescriptionVolumeUUIDKey;
extern const CFDictionaryRef kDADiskDescriptionMatchVolumeMountable;
extern const CFArrayRef kDADiskDescriptionWatchVolumePath;

extern DASessionRef DASessionCreate(CFAllocatorRef allocator) CF_RETURNS_RETAINED;
extern void DASessionScheduleWithRunLoop(DASessionRef session, CFRunLoopRef runLoop, CFStringRef runLoopMode);
extern void DASessionUnscheduleFromRunLoop(DASessionRef session, CFRunLoopRef runLoop, CFStringRef runLoopMode);

extern void DARegisterDiskAppearedCallback(DASessionRef session, CFDictionaryRef match, DADiskAppearedCallback callback, void *context);
extern void DARegisterDiskDisappearedCallback(DASessionRef session, CFDictionaryRef match, DADiskDisappearedCallback callback, void *context);
extern void DARegisterDiskDescriptionChangedCallback(DASessionRef session, CFDictionaryRef match, CFArrayRef watch,
                                                     DADiskDescriptionChangedCallback callback, void *context);

extern DADiskRef DADiskCreateFromBSDName(CFAllocatorRef allocator, DASessionRef session, const char *name) CF_RETURNS_RETAINED;
extern CFDictionaryRef DADiskCopyDescription(DADiskRef disk) CF_RETURNS_RETAINED;
extern DADiskRef DADiskCopyWholeDisk(DADiskRef disk) CF_RETURNS_RETAINED;
extern uint32_t DADiskCopyIOMedia(DADiskRef disk);
extern void DADiskUnmount(DADiskRef disk, DADiskUnmountOptions options, DADiskUnmountCallback callback, void *context);
extern void DADiskEject(DADiskRef disk, DADiskEjectOptions options, DADiskEjectCallback callback, void *context);
extern void DADiskClaim(DADiskRef disk, DADiskClaimOptions options, DADiskClaimReleaseCallback release, void *releaseContext,
                        DADiskClaimCallback callback, void *callbackContext);
extern void DADiskUnclaim(DADiskRef disk);

extern DADissenterRef DADissenterCreate(CFAllocatorRef allocator, DAReturn status, CFStringRef string) CF_RETURNS_RETAINED;
extern DAReturn DADissenterGetStatus(DADissenterRef dissenter);
extern CFStringRef DADissenterGetStatusString(DADissenterRef dissenter);
