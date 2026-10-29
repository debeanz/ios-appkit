// The rest of macOS-only CoreServices: the Apple Event C API, the classic File Manager
// (FSRef/FSSpec), Launch Services and Spotlight. iOS has none of it. Opening a URL through
// Launch Services really opens it (via UIApplication); path<->FSRef conversion works; the
// rest (Apple Events, login items, Spotlight, trashing, default-handler changes) reports
// that the macOS-only facility isn't available.
#import <CoreFoundation/CoreFoundation.h>
#import <MacTypes.h>

#pragma mark Apple Event C API (inert)

typedef ResType DescType; // AEDataModel.h is macOS-only
typedef struct AEDesc { DescType descriptorType; void *dataHandle; } AEDesc;
typedef AEDesc AEDescList;
typedef AEDesc AERecord;
typedef AEDesc AppleEvent;
typedef AEDesc AEAddressDesc;
typedef FourCharCode AEEventClass;
typedef FourCharCode AEEventID;
typedef FourCharCode AEKeyword;
typedef SInt32 AESendMode;
typedef SInt16 AESendPriority;
typedef SInt32 AEReturnID;
typedef SInt32 AETransactionID;
typedef OSErr (*AEEventHandlerProcPtr)(const AppleEvent *event, AppleEvent *reply, SRefCon handlerRefcon);
typedef AEEventHandlerProcPtr AEEventHandlerUPP;

enum { typeNull = 'null', kAutoGenerateReturnID = -1, kAnyTransactionID = 0,
       kAEDefaultTimeout = -1, kAENormalPriority = 0x00000000, errAEEventNotHandled = -1708,
       errAEDescNotFound = -1701 };

// Power: a game's "the user is active" nudge against idle sleep, accepted and ignored.
extern OSErr UpdateSystemActivity(UInt8 activity);

extern OSErr AECreateDesc(DescType typeCode, const void *dataPtr, Size dataSize, AEDesc *result);
extern OSErr AEDisposeDesc(AEDesc *theAEDesc);
extern OSErr AECreateAppleEvent(AEEventClass eventClass, AEEventID eventID, const AEAddressDesc *target,
                                AEReturnID returnID, AETransactionID transactionID, AppleEvent *result);
extern OSErr AEBuildAppleEvent(AEEventClass eventClass, AEEventID eventID, DescType addressType,
                               const void *addressData, Size addressLength, AEReturnID returnID,
                               AETransactionID transactionID, AppleEvent *result, void *error, const char *format, ...);
extern OSErr AEPutParamDesc(AppleEvent *event, AEKeyword key, const AEDesc *desc);
extern OSErr AEGetParamDesc(const AppleEvent *event, AEKeyword key, DescType desiredType, AEDesc *result);
extern OSErr AEInstallEventHandler(AEEventClass eventClass, AEEventID eventID, AEEventHandlerUPP handler,
                                   SRefCon handlerRefcon, Boolean isSysHandler);
extern OSErr AERemoveEventHandler(AEEventClass eventClass, AEEventID eventID, AEEventHandlerUPP handler, Boolean isSysHandler);
extern OSErr AESendMessage(const AppleEvent *event, AppleEvent *reply, AESendMode sendMode, long timeOutInTicks);

#pragma mark Classic File Manager

typedef struct FSRef { UInt8 hidden[80]; } FSRef;
typedef struct FSSpec { SInt16 vRefNum; UInt32 parID; UInt8 name[256]; } FSSpec;
typedef SInt16 FSVolumeRefNum;
typedef UInt32 FSCatalogInfoBitmap;
typedef struct HFSUniStr255 { UInt16 length; UniChar unicode[255]; } HFSUniStr255;
typedef struct FSCatalogInfo { UInt16 nodeFlags; UInt8 reserved[140]; } FSCatalogInfo;
typedef struct FSVolumeInfo { UInt8 reserved[180]; } FSVolumeInfo;

enum { kFSCatInfoNone = 0x00000000, kFSCatInfoNodeFlags = 0x00000040, fnfErr = -43, nsvErr = -35 };

extern OSStatus FSPathMakeRef(const UInt8 *path, FSRef *ref, Boolean *isDirectory);
extern OSStatus FSRefMakePath(const FSRef *ref, UInt8 *path, UInt32 maxPathSize);
extern OSStatus FSGetCatalogInfo(const FSRef *ref, FSCatalogInfoBitmap whichInfo, FSCatalogInfo *catalogInfo,
                                 HFSUniStr255 *outName, FSSpec *fsSpec, FSRef *parentRef);
extern OSStatus FSGetVolumeInfo(FSVolumeRefNum volume, UInt32 volumeIndex, FSVolumeRefNum *actualVolume,
                                UInt32 whichInfo, FSVolumeInfo *info, HFSUniStr255 *volumeName, FSRef *rootDirectory);
extern OSStatus FSMoveObjectToTrashSync(const FSRef *source, FSRef *target, UInt32 options);
extern CFStringRef FSCreateStringFromHFSUniStr(CFAllocatorRef alloc, const HFSUniStr255 *uniStr) CF_RETURNS_RETAINED;

#pragma mark Launch Services

typedef OptionBits LSRolesMask;
typedef OptionBits LSRequestedInfo;
typedef OptionBits LSAcceptanceFlags;
typedef UInt32 LSLaunchFlags;
typedef struct LSLaunchURLSpec { CFURLRef appURL; CFArrayRef itemURLs; const void *passThruParams; LSLaunchFlags launchFlags; void *asyncRefCon; } LSLaunchURLSpec;
typedef struct LSItemInfoRecord { UInt32 flags; OSType filetype; OSType creator; CFStringRef extension; CFStringRef iconFileName; CFStringRef kindID; } LSItemInfoRecord;

enum { kLSRolesAll = 0xFFFFFFFF, kLSRequestAllInfo = 0xFFFFFFFF, kLSUnknownType = 0, kLSUnknownCreator = 0,
       kLSApplicationNotFoundErr = -10814, kLSUnknownErr = -10810 };

extern OSStatus LSOpenCFURLRef(CFURLRef inURL, CFURLRef *outLaunchedURL);
extern OSStatus LSOpenFromURLSpec(const LSLaunchURLSpec *inLaunchSpec, CFURLRef *outLaunchedURL);
extern CFArrayRef LSCopyApplicationURLsForBundleIdentifier(CFStringRef bundleID, CFErrorRef *error) CF_RETURNS_RETAINED;
extern OSStatus LSCopyKindStringForRef(const FSRef *ref, CFStringRef *outKindString);
extern OSStatus LSRegisterURL(CFURLRef inURL, Boolean inUpdate);
extern OSStatus LSRegisterFSRef(const FSRef *ref, Boolean inUpdate);
extern OSStatus LSSetDefaultHandlerForURLScheme(CFStringRef scheme, CFStringRef bundleID);
extern OSStatus LSSetDefaultRoleHandlerForContentType(CFStringRef contentType, LSRolesMask role, CFStringRef bundleID);

// Shared file lists: login items and recent items. iOS has neither.
typedef struct OpaqueLSSharedFileListRef *LSSharedFileListRef;
typedef struct OpaqueLSSharedFileListItemRef *LSSharedFileListItemRef;
extern const CFStringRef kLSSharedFileListSessionLoginItems;
extern const CFStringRef kLSSharedFileListLoginItemHidden;
extern const LSSharedFileListItemRef kLSSharedFileListItemBeforeFirst;
extern const LSSharedFileListItemRef kLSSharedFileListItemLast;

extern LSSharedFileListRef LSSharedFileListCreate(CFAllocatorRef allocator, CFStringRef listType, CFTypeRef options) CF_RETURNS_RETAINED;
extern CFArrayRef LSSharedFileListCopySnapshot(LSSharedFileListRef list, UInt32 *outSeed) CF_RETURNS_RETAINED;
extern LSSharedFileListItemRef LSSharedFileListInsertItemURL(LSSharedFileListRef list, LSSharedFileListItemRef after,
                                                             CFStringRef displayName, void *icon, CFURLRef url,
                                                             CFDictionaryRef properties, CFArrayRef propertiesToClear) CF_RETURNS_RETAINED;
extern LSSharedFileListItemRef LSSharedFileListInsertItemFSRef(LSSharedFileListRef list, LSSharedFileListItemRef after,
                                                               CFStringRef displayName, void *icon, const FSRef *ref,
                                                               CFDictionaryRef properties, CFArrayRef propertiesToClear) CF_RETURNS_RETAINED;
extern OSStatus LSSharedFileListItemRemove(LSSharedFileListRef list, LSSharedFileListItemRef item);
extern CFStringRef LSSharedFileListItemCopyDisplayName(LSSharedFileListItemRef item) CF_RETURNS_RETAINED;
extern OSStatus LSSharedFileListItemResolve(LSSharedFileListItemRef item, UInt32 flags, CFURLRef *outURL, FSRef *outRef);
extern CFURLRef LSSharedFileListItemCopyResolvedURL(LSSharedFileListItemRef item, UInt32 flags, CFErrorRef *error) CF_RETURNS_RETAINED;
extern CFTypeRef LSSharedFileListItemCopyProperty(LSSharedFileListItemRef item, CFStringRef propertyName) CF_RETURNS_RETAINED;

#pragma mark Spotlight

typedef struct __MDItem *MDItemRef;
extern const CFStringRef kMDItemWhereFroms;
extern MDItemRef MDItemCreate(CFAllocatorRef allocator, CFStringRef path) CF_RETURNS_RETAINED;
extern void MDItemSetAttribute(MDItemRef item, CFStringRef name, CFTypeRef value);

#pragma mark Private

extern Boolean _CSCheckFixDisable(void);
extern void _LSSetApplicationLaunchServicesServerConnectionStatus(uint64_t flags, void *unused);
extern const CFStringRef _kLSOpenOptionBackgroundLaunchKey;
