// DiskArbitration over nothing: an iOS app sees no disks. Sessions and callback
// registration are real objects, so code that watches for disks runs; no disk ever appears,
// and operations on one report kDAReturnNotFound. See DiskArbitrationMac.h.
#import "AKShimPrivate.h"
#import "AppKitShim/DiskArbitrationMac.h"

const CFStringRef kDADiskDescriptionDeviceModelKey = CFSTR("DADeviceModel");
const CFStringRef kDADiskDescriptionDeviceRevisionKey = CFSTR("DADeviceRevision");
const CFStringRef kDADiskDescriptionDeviceVendorKey = CFSTR("DADeviceVendor");
const CFStringRef kDADiskDescriptionMediaBSDNameKey = CFSTR("DAMediaBSDName");
const CFStringRef kDADiskDescriptionMediaRemovableKey = CFSTR("DAMediaRemovable");
const CFStringRef kDADiskDescriptionMediaSizeKey = CFSTR("DAMediaSize");
const CFStringRef kDADiskDescriptionMediaUUIDKey = CFSTR("DAMediaUUID");
const CFStringRef kDADiskDescriptionVolumeNameKey = CFSTR("DAVolumeName");
const CFStringRef kDADiskDescriptionVolumePathKey = CFSTR("DAVolumePath");
const CFStringRef kDADiskDescriptionVolumeUUIDKey = CFSTR("DAVolumeUUID");

// Match/watch markers: opaque sentinels the caller only ever passes back to DiskArbitration.
const CFDictionaryRef kDADiskDescriptionMatchVolumeMountable = (CFDictionaryRef)CFSTR("DAMatchVolumeMountable");
const CFArrayRef kDADiskDescriptionWatchVolumePath = (CFArrayRef)CFSTR("DAWatchVolumePath");

#pragma mark Sessions

@interface AKDASession : NSObject
@end
@implementation AKDASession
@end

DASessionRef DASessionCreate(CFAllocatorRef allocator) {
  return (DASessionRef)CFBridgingRetain([AKDASession new]);
}

void DASessionScheduleWithRunLoop(DASessionRef session, CFRunLoopRef runLoop, CFStringRef mode) {}
void DASessionUnscheduleFromRunLoop(DASessionRef session, CFRunLoopRef runLoop, CFStringRef mode) {}

// Callbacks are retained by the (real) session but never fire: no disk appears, disappears
// or changes on iOS.
void DARegisterDiskAppearedCallback(DASessionRef session, CFDictionaryRef match, DADiskAppearedCallback callback, void *context) {}
void DARegisterDiskDisappearedCallback(DASessionRef session, CFDictionaryRef match, DADiskDisappearedCallback callback, void *context) {}
void DARegisterDiskDescriptionChangedCallback(DASessionRef session, CFDictionaryRef match, CFArrayRef watch,
                                              DADiskDescriptionChangedCallback callback, void *context) {}

#pragma mark Disks

// No BSD disk node is reachable, so a disk can't be created from one.
DADiskRef DADiskCreateFromBSDName(CFAllocatorRef allocator, DASessionRef session, const char *name) { return NULL; }
CFDictionaryRef DADiskCopyDescription(DADiskRef disk) { return NULL; }
DADiskRef DADiskCopyWholeDisk(DADiskRef disk) { return NULL; }
uint32_t DADiskCopyIOMedia(DADiskRef disk) { return 0; }

static void AKReportNotFound(DADiskRef disk, void (*callback)(DADiskRef, DADissenterRef, void *), void *context) {
  if (!callback) return;
  DADissenterRef dissenter = DADissenterCreate(kCFAllocatorDefault, kDAReturnNotFound, CFSTR("No such disk"));
  callback(disk, dissenter, context);
  if (dissenter) CFRelease(dissenter);
}

void DADiskUnmount(DADiskRef disk, DADiskUnmountOptions options, DADiskUnmountCallback callback, void *context) {
  AKReportNotFound(disk, callback, context);
}

void DADiskEject(DADiskRef disk, DADiskEjectOptions options, DADiskEjectCallback callback, void *context) {
  AKReportNotFound(disk, callback, context);
}

void DADiskClaim(DADiskRef disk, DADiskClaimOptions options, DADiskClaimReleaseCallback release, void *releaseContext,
                 DADiskClaimCallback callback, void *callbackContext) {
  AKReportNotFound(disk, callback, callbackContext);
}

void DADiskUnclaim(DADiskRef disk) {}

#pragma mark Dissenters

@interface AKDADissenter : NSObject
@property (nonatomic) DAReturn status;
@property (nonatomic, copy) NSString *string;
@end
@implementation AKDADissenter
@end

DADissenterRef DADissenterCreate(CFAllocatorRef allocator, DAReturn status, CFStringRef string) {
  AKDADissenter *d = [AKDADissenter new];
  d.status = status;
  d.string = (__bridge NSString *)string;
  return (DADissenterRef)CFBridgingRetain(d);
}

DAReturn DADissenterGetStatus(DADissenterRef dissenter) {
  return dissenter ? ((__bridge AKDADissenter *)(void *)dissenter).status : kDAReturnBadArgument;
}

CFStringRef DADissenterGetStatusString(DADissenterRef dissenter) {
  return dissenter ? (__bridge CFStringRef)((__bridge AKDADissenter *)(void *)dissenter).string : NULL;
}
