// The long tail. See SmallFrameworks.h. Each symbol uses its iOS counterpart where one
// exists, and otherwise reports that the macOS-only feature isn't available.
#import "AKShimPrivate.h"
#import "AppKitShim/SmallFrameworks.h"

#pragma mark Metal

MTLDeviceNotificationName const MTLDeviceWasRemovedNotification = @"MTLDeviceWasRemovedNotification";
MTLDeviceNotificationName const MTLDeviceRemovalRequestedNotification = @"MTLDeviceRemovalRequestedNotification";

// One built-in, non-removable GPU; the observer is never signalled.
NSArray<id<MTLDevice>> *MTLCopyAllDevicesWithObserver(id<NSObject> *observer, MTLDeviceNotificationHandler handler) {
  if (observer) *observer = nil;
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  return device ? @[ device ] : @[];
}

#pragma mark CoreText

CFArrayRef CTFontCollectionCreateMatchingFontDescriptorsForFamily(CTFontCollectionRef collection, CFStringRef family, CFDictionaryRef options) {
  CFArrayRef all = CTFontCollectionCreateMatchingFontDescriptors(collection);
  if (!all) return NULL;
  CFMutableArrayRef matching = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
  for (CFIndex i = 0; i < CFArrayGetCount(all); i++) {
    CTFontDescriptorRef d = CFArrayGetValueAtIndex(all, i);
    CFStringRef name = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute);
    if (name && family && CFStringCompare(name, family, 0) == kCFCompareEqualTo) CFArrayAppendValue(matching, d);
    if (name) CFRelease(name);
  }
  CFRelease(all);
  return matching;
}

// Returns an ATS font reference (a 32-bit number); ATS doesn't exist on iOS, so there's never
// one: 0, with the font's descriptor as the out-attribute. Named through an asm label because
// the iOS header already declares this function as unavailable.
uint32_t AKCTFontGetPlatformFont(CTFontRef font, CTFontDescriptorRef *descriptor) __asm__("_CTFontGetPlatformFont");
uint32_t AKCTFontGetPlatformFont(CTFontRef font, CTFontDescriptorRef *descriptor) {
  if (descriptor) *descriptor = font ? CTFontCopyFontDescriptor(font) : NULL;
  return 0;
}

#pragma mark QuartzCore

@implementation CAOpenGLLayer
@end

#pragma mark CoreFoundation / IOKit

NSString *const NSURLTagNamesKey = @"NSURLTagNamesKey";
CFDictionaryRef IODisplayCreateInfoDictionary(uint32_t framebuffer, uint32_t options) { return NULL; }

#pragma mark VideoToolbox

void VTRegisterProfessionalVideoWorkflowVideoDecoders(void) {}

#pragma mark CoreWLAN

@implementation CWWiFiClient
+ (CWWiFiClient *)sharedWiFiClient {
  static CWWiFiClient *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [CWWiFiClient new]; });
  return shared;
}
- (id)interface { return nil; }
- (NSArray<NSString *> *)interfaceNames { return nil; }
@end

#pragma mark SecurityInterface / LocalAuthenticationEmbeddedUI

@implementation SFCertificatePanel
+ (SFCertificatePanel *)sharedCertificatePanel { return [SFCertificatePanel new]; }
- (NSInteger)runModalForCertificates:(NSArray *)certificates showGroup:(BOOL)showGroup { return 0; } // NSModalResponseCancel
@end

@implementation LAAuthenticationView
@end

#pragma mark SafariServices

@implementation SFUniversalLink
- (instancetype)initWithWebpageURL:(NSURL *)url {
  if ((self = [super init])) { _webpageURL = [url copy]; _enabled = NO; }
  return self;
}
@end

#pragma mark OpenDirectory

NSString *const kODRecordTypeUsers = @"dsRecTypeStandard:Users";
NSString *const kODAttributeTypeRecordName = @"dsAttrTypeStandard:RecordName";
NSString *const kODAttributeTypeAllAttributes = @"dsAttributesAll";
NSString *const kODAttributeTypeAltSecurityIdentities = @"dsAttrTypeStandard:AltSecurityIdentities";
NSString *const kODAttributeTypeMetaRecordName = @"dsAttrTypeStandard:AppleMetaRecordName";

// iOS apps can't reach directory services, so a node can't be opened.
static NSError *AKUnsupportedDirectoryError(void) {
  return [NSError errorWithDomain:@"com.apple.OpenDirectory" code:-14008 userInfo:@{ NSLocalizedDescriptionKey: @"Directory services are not available" }];
}

@implementation ODSession
+ (ODSession *)defaultSession {
  static ODSession *session;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ session = [ODSession new]; });
  return session;
}
@end

@implementation ODNode
+ (instancetype)nodeWithSession:(ODSession *)session name:(NSString *)nodeName error:(NSError **)error {
  if (error) *error = AKUnsupportedDirectoryError();
  return nil;
}
+ (instancetype)nodeWithSession:(ODSession *)session type:(uint32_t)nodeType error:(NSError **)error {
  if (error) *error = AKUnsupportedDirectoryError();
  return nil;
}
@end

@implementation ODQuery
- (NSArray *)resultsAllowingPartial:(BOOL)allowPartial error:(NSError **)error {
  if (error) *error = AKUnsupportedDirectoryError();
  return nil;
}
@end

@implementation ODRecord
- (NSArray *)valuesForAttribute:(NSString *)attribute error:(NSError **)error {
  if (error) *error = AKUnsupportedDirectoryError();
  return nil;
}
@end

#pragma mark IOBluetooth

// iOS uses CoreBluetooth; classic IOBluetooth has no controller here.
int IOBluetoothPreferenceSetControllerPowerState(int powered) { return -1; }

@implementation IOBluetoothHostController
+ (IOBluetoothHostController *)defaultController { return nil; }
- (uint8_t)powerState { return 0; } // powered off
@end

@implementation IOBluetoothDevice
+ (NSArray *)pairedDevices { return @[]; }
@end

@implementation IOBluetoothDeviceInquiry
- (int)start { return -1; } // kIOReturnUnsupported-style failure
- (int)stop { return 0; }
@end

@implementation IOBluetoothSDPUUID
+ (instancetype)uuid16:(uint16_t)uuid16 { return [self new]; }
@end

@implementation IOBluetoothSDPServiceRecord
@end
@implementation IOBluetoothL2CAPChannel
@end
@implementation IOBluetoothRFCOMMChannel
@end

#pragma mark ScreenCaptureKit

NSErrorDomain const SCStreamErrorDomain = @"com.apple.ScreenCaptureKit.SCStreamErrorDomain";
NSString *const SCStreamFrameInfoScaleFactor = @"SCStreamFrameInfoScaleFactor";
NSString *const SCStreamFrameInfoContentScale = @"SCStreamFrameInfoContentScale";
NSString *const SCStreamFrameInfoContentRect = @"SCStreamFrameInfoContentRect";

@implementation SCShareableContent
// iOS apps can't enumerate or capture the screen; the request fails.
+ (void)getShareableContentWithCompletionHandler:(void (^)(SCShareableContent *, NSError *))handler {
  if (!handler) return;
  NSError *error = [NSError errorWithDomain:SCStreamErrorDomain code:-3801 userInfo:@{ NSLocalizedDescriptionKey: @"Screen capture is not available" }];
  dispatch_async(dispatch_get_main_queue(), ^{ handler(nil, error); });
}
- (NSArray *)displays { return @[]; }
- (NSArray *)windows { return @[]; }
- (NSArray *)applications { return @[]; }
@end

@implementation SCContentFilter
@end
@implementation SCStreamConfiguration
@end
@implementation SCStream
@end
@implementation SCScreenshotManager
@end

#pragma mark ForceFeedback

// No force-feedback interface is exposed to iOS apps (controller rumble goes through
// GameController's haptics instead), so every device query reports none.
uint32_t FFIsForceFeedback(uint32_t device) { return AKFFERR_NOINTERFACE; }
AKFFReturn FFCreateDevice(uint32_t device, FFDeviceObjectReference *outDevice) { if (outDevice) *outDevice = NULL; return AKFFERR_NOINTERFACE; }
AKFFReturn FFReleaseDevice(FFDeviceObjectReference device) { return AKFF_OK; }
AKFFReturn FFDeviceGetForceFeedbackCapabilities(FFDeviceObjectReference device, void *outCapabilities) { return AKFFERR_NOINTERFACE; }
AKFFReturn FFDeviceGetForceFeedbackProperty(FFDeviceObjectReference device, uint32_t property, void *outValue, uint32_t size) { return AKFFERR_NOINTERFACE; }
AKFFReturn FFDeviceSetForceFeedbackProperty(FFDeviceObjectReference device, uint32_t property, void *value) { return AKFFERR_NOINTERFACE; }
AKFFReturn FFDeviceSendForceFeedbackCommand(FFDeviceObjectReference device, uint32_t command) { return AKFFERR_NOINTERFACE; }
AKFFReturn FFDeviceCreateEffect(FFDeviceObjectReference device, CFUUIDRef uuidRef, const void *effectDefinition, FFEffectObjectReference *outEffect) {
  if (outEffect) *outEffect = NULL;
  return AKFFERR_NOINTERFACE;
}
AKFFReturn FFDeviceReleaseEffect(FFDeviceObjectReference device, FFEffectObjectReference effect) { return AKFF_OK; }
AKFFReturn FFEffectStart(FFEffectObjectReference effect, uint32_t iterations, uint32_t flags) { return AKFFERR_NOINTERFACE; }
AKFFReturn FFEffectStop(FFEffectObjectReference effect) { return AKFFERR_NOINTERFACE; }
AKFFReturn FFEffectSetParameters(FFEffectObjectReference effect, const void *effectParams, uint32_t flags) { return AKFFERR_NOINTERFACE; }
AKFFReturn FFEffectGetEffectStatus(FFEffectObjectReference effect, uint32_t *outStatus) { if (outStatus) *outStatus = 0; return AKFFERR_NOINTERFACE; }
