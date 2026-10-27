// See CoreServicesMacExtras.h.
#import "AKShimPrivate.h"
#import "AppKitShim/CoreServicesMacExtras.h"

#pragma mark Apple Event C API (inert: nothing is ever sent or received on iOS)

OSErr AECreateDesc(DescType typeCode, const void *dataPtr, Size dataSize, AEDesc *result) {
  if (!result) return AKParamErr;
  result->descriptorType = typeCode;
  result->dataHandle = (dataPtr && dataSize > 0) ? (void *)CFBridgingRetain([NSData dataWithBytes:dataPtr length:(NSUInteger)dataSize]) : NULL;
  return noErr;
}

OSErr AEDisposeDesc(AEDesc *desc) {
  if (!desc) return AKParamErr;
  if (desc->dataHandle) CFRelease(desc->dataHandle);
  desc->descriptorType = typeNull;
  desc->dataHandle = NULL;
  return noErr;
}

OSErr AECreateAppleEvent(AEEventClass eventClass, AEEventID eventID, const AEAddressDesc *target,
                         AEReturnID returnID, AETransactionID transactionID, AppleEvent *result) {
  if (!result) return AKParamErr;
  result->descriptorType = 'aevt';
  result->dataHandle = (void *)CFBridgingRetain([NSMutableDictionary dictionary]); // keyed parameters
  return noErr;
}

OSErr AEBuildAppleEvent(AEEventClass eventClass, AEEventID eventID, DescType addressType, const void *addressData,
                        Size addressLength, AEReturnID returnID, AETransactionID transactionID, AppleEvent *result,
                        void *error, const char *format, ...) {
  return AECreateAppleEvent(eventClass, eventID, NULL, returnID, transactionID, result);
}

OSErr AEPutParamDesc(AppleEvent *event, AEKeyword key, const AEDesc *desc) {
  if (!event || !desc || event->descriptorType != 'aevt' || !event->dataHandle) return AKParamErr;
  NSMutableDictionary *params = (__bridge NSMutableDictionary *)event->dataHandle;
  NSData *data = desc->dataHandle ? (__bridge NSData *)desc->dataHandle : [NSData data];
  params[@(key)] = @[ @(desc->descriptorType), data ];
  return noErr;
}

OSErr AEGetParamDesc(const AppleEvent *event, AEKeyword key, DescType desiredType, AEDesc *result) {
  if (!event || !result || event->descriptorType != 'aevt' || !event->dataHandle) return AKParamErr;
  NSArray *entry = ((__bridge NSMutableDictionary *)event->dataHandle)[@(key)];
  if (!entry) return errAEDescNotFound;
  NSData *data = entry[1];
  return AECreateDesc((DescType)[entry[0] unsignedIntValue], data.bytes, (Size)data.length, result);
}

OSErr AEInstallEventHandler(AEEventClass eventClass, AEEventID eventID, AEEventHandlerUPP handler,
                            SRefCon refcon, Boolean isSysHandler) { return noErr; } // never invoked
OSErr AERemoveEventHandler(AEEventClass eventClass, AEEventID eventID, AEEventHandlerUPP handler, Boolean isSysHandler) { return noErr; }
OSErr AESendMessage(const AppleEvent *event, AppleEvent *reply, AESendMode sendMode, long timeout) { return errAEEventNotHandled; }

#pragma mark FSRef <-> path

// An FSRef is 80 opaque bytes: a tag, then an index into this table of paths.
static const UInt32 AKFSRefTag = 'AKFR';
static NSMutableArray<NSString *> *gFSRefPaths;

static NSString *AKPathForFSRef(const FSRef *ref) {
  if (!ref) return nil;
  UInt32 tag, index;
  memcpy(&tag, ref->hidden, 4);
  memcpy(&index, ref->hidden + 4, 4);
  if (tag != AKFSRefTag) return nil;
  @synchronized (NSFileManager.class) { return index < gFSRefPaths.count ? gFSRefPaths[index] : nil; }
}

static void AKFillFSRef(FSRef *ref, NSString *path) {
  UInt32 index;
  @synchronized (NSFileManager.class) {
    if (!gFSRefPaths) gFSRefPaths = [NSMutableArray array];
    NSUInteger existing = [gFSRefPaths indexOfObject:path];
    if (existing == NSNotFound) { [gFSRefPaths addObject:path]; existing = gFSRefPaths.count - 1; }
    index = (UInt32)existing;
  }
  memset(ref->hidden, 0, sizeof ref->hidden);
  memcpy(ref->hidden, &AKFSRefTag, 4);
  memcpy(ref->hidden + 4, &index, 4);
}

// Like the Mac's, only existing objects get an FSRef.
OSStatus FSPathMakeRef(const UInt8 *path, FSRef *ref, Boolean *isDirectory) {
  if (!path || !ref) return AKParamErr;
  NSString *p = [NSString stringWithUTF8String:(const char *)path];
  BOOL dir = NO;
  if (!p || ![NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&dir]) return fnfErr;
  AKFillFSRef(ref, p.stringByStandardizingPath);
  if (isDirectory) *isDirectory = dir;
  return noErr;
}

OSStatus FSRefMakePath(const FSRef *ref, UInt8 *path, UInt32 maxPathSize) {
  NSString *p = AKPathForFSRef(ref);
  if (!p) return fnfErr;
  if (!path || ![p getCString:(char *)path maxLength:maxPathSize encoding:NSUTF8StringEncoding]) return AKParamErr;
  return noErr;
}

OSStatus FSGetCatalogInfo(const FSRef *ref, FSCatalogInfoBitmap whichInfo, FSCatalogInfo *info,
                          HFSUniStr255 *outName, FSSpec *fsSpec, FSRef *parentRef) {
  NSString *p = AKPathForFSRef(ref);
  if (!p) return fnfErr;
  if (info) {
    memset(info, 0, sizeof *info);
    BOOL dir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&dir];
    if (dir) info->nodeFlags = 0x0010; // kFSNodeIsDirectoryMask
  }
  if (outName) {
    NSString *name = p.lastPathComponent;
    NSUInteger n = MIN(name.length, (NSUInteger)255);
    outName->length = (UInt16)n;
    [name getCharacters:outName->unicode range:NSMakeRange(0, n)];
  }
  if (fsSpec) memset(fsSpec, 0, sizeof *fsSpec);
  if (parentRef) AKFillFSRef(parentRef, p.stringByDeletingLastPathComponent);
  return noErr;
}

// Volumes are numbered on the Mac; an iOS app's container has no volume list to walk.
OSStatus FSGetVolumeInfo(FSVolumeRefNum volume, UInt32 volumeIndex, FSVolumeRefNum *actualVolume,
                         UInt32 whichInfo, FSVolumeInfo *info, HFSUniStr255 *volumeName, FSRef *rootDirectory) {
  return nsvErr;
}

// No Trash on iOS: the object is removed, which is what moving it to the Trash and emptying it does.
OSStatus FSMoveObjectToTrashSync(const FSRef *source, FSRef *target, UInt32 options) {
  NSString *p = AKPathForFSRef(source);
  if (!p) return fnfErr;
  if (![NSFileManager.defaultManager removeItemAtPath:p error:nil]) return AKParamErr;
  if (target) memset(target->hidden, 0, sizeof target->hidden);
  return noErr;
}

CFStringRef FSCreateStringFromHFSUniStr(CFAllocatorRef alloc, const HFSUniStr255 *uniStr) {
  if (!uniStr) return NULL;
  return CFStringCreateWithCharacters(alloc, uniStr->unicode, MIN(uniStr->length, (UInt16)255));
}

#pragma mark Launch Services

// Opening a URL really opens it, through UIApplication (as NSWorkspace does).
OSStatus LSOpenCFURLRef(CFURLRef inURL, CFURLRef *outLaunchedURL) {
  if (!inURL) return AKParamErr;
  NSURL *url = (__bridge NSURL *)inURL;
  if (outLaunchedURL) *outLaunchedURL = NULL;
  dispatch_async(dispatch_get_main_queue(), ^{ [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil]; });
  return noErr;
}

OSStatus LSOpenFromURLSpec(const LSLaunchURLSpec *spec, CFURLRef *outLaunchedURL) {
  if (!spec) return AKParamErr;
  if (outLaunchedURL) *outLaunchedURL = NULL;
  NSArray *items = (__bridge NSArray *)spec->itemURLs;
  if (items.count == 0 && spec->appURL) return LSOpenCFURLRef(spec->appURL, NULL);
  for (NSURL *u in items) LSOpenCFURLRef((__bridge CFURLRef)u, NULL);
  return noErr;
}

// Other apps' bundles aren't visible to an iOS app.
CFArrayRef LSCopyApplicationURLsForBundleIdentifier(CFStringRef bundleID, CFErrorRef *error) {
  if (error) *error = (CFErrorRef)CFBridgingRetain([NSError errorWithDomain:NSOSStatusErrorDomain code:kLSApplicationNotFoundErr userInfo:nil]);
  return NULL;
}

OSStatus LSCopyKindStringForRef(const FSRef *ref, CFStringRef *outKindString) {
  NSString *p = AKPathForFSRef(ref);
  if (!p || !outKindString) return AKParamErr;
  BOOL dir = NO;
  [NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&dir];
  *outKindString = (CFStringRef)CFBridgingRetain(dir ? @"Folder" : @"Document");
  return noErr;
}

OSStatus LSRegisterURL(CFURLRef inURL, Boolean inUpdate) { return noErr; }
OSStatus LSRegisterFSRef(const FSRef *ref, Boolean inUpdate) { return noErr; }

// iOS apps can't change which app handles a scheme or type; that's the user's choice in Settings.
OSStatus LSSetDefaultHandlerForURLScheme(CFStringRef scheme, CFStringRef bundleID) { return kLSUnknownErr; }
OSStatus LSSetDefaultRoleHandlerForContentType(CFStringRef type, LSRolesMask role, CFStringRef bundleID) { return kLSUnknownErr; }

#pragma mark Shared file lists (none on iOS)

const CFStringRef kLSSharedFileListSessionLoginItems = CFSTR("com.apple.LSSharedFileList.SessionLoginItems");
const CFStringRef kLSSharedFileListLoginItemHidden = CFSTR("com.apple.loginitem.HideOnLaunch");
const LSSharedFileListItemRef kLSSharedFileListItemBeforeFirst = (LSSharedFileListItemRef)1;
const LSSharedFileListItemRef kLSSharedFileListItemLast = (LSSharedFileListItemRef)2;

LSSharedFileListRef LSSharedFileListCreate(CFAllocatorRef allocator, CFStringRef listType, CFTypeRef options) { return NULL; }

CFArrayRef LSSharedFileListCopySnapshot(LSSharedFileListRef list, UInt32 *outSeed) {
  if (outSeed) *outSeed = 0;
  return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
}

LSSharedFileListItemRef LSSharedFileListInsertItemURL(LSSharedFileListRef list, LSSharedFileListItemRef after, CFStringRef name,
                                                      void *icon, CFURLRef url, CFDictionaryRef props, CFArrayRef clear) { return NULL; }
LSSharedFileListItemRef LSSharedFileListInsertItemFSRef(LSSharedFileListRef list, LSSharedFileListItemRef after, CFStringRef name,
                                                        void *icon, const FSRef *ref, CFDictionaryRef props, CFArrayRef clear) { return NULL; }
OSStatus LSSharedFileListItemRemove(LSSharedFileListRef list, LSSharedFileListItemRef item) { return fnfErr; }
CFStringRef LSSharedFileListItemCopyDisplayName(LSSharedFileListItemRef item) { return NULL; }
OSStatus LSSharedFileListItemResolve(LSSharedFileListItemRef item, UInt32 flags, CFURLRef *outURL, FSRef *outRef) { return fnfErr; }
CFURLRef LSSharedFileListItemCopyResolvedURL(LSSharedFileListItemRef item, UInt32 flags, CFErrorRef *error) { return NULL; }
CFTypeRef LSSharedFileListItemCopyProperty(LSSharedFileListItemRef item, CFStringRef propertyName) { return NULL; }

#pragma mark Spotlight

const CFStringRef kMDItemWhereFroms = CFSTR("kMDItemWhereFroms");
MDItemRef MDItemCreate(CFAllocatorRef allocator, CFStringRef path) { return NULL; } // no Spotlight index
void MDItemSetAttribute(MDItemRef item, CFStringRef name, CFTypeRef value) {}

#pragma mark Private

Boolean _CSCheckFixDisable(void) { return false; }
void _LSSetApplicationLaunchServicesServerConnectionStatus(uint64_t flags, void *unused) {}
const CFStringRef _kLSOpenOptionBackgroundLaunchKey = CFSTR("LSOpenOptionBackgroundLaunchKey");
