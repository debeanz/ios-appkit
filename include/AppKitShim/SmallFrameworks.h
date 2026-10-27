// The long tail: one or two symbols each from frameworks that are mostly present on iOS.
// Each is backed by its iOS counterpart where one exists, and otherwise reports that the
// macOS-only feature isn't available (external GPUs, Wi-Fi control, classic Bluetooth,
// screen capture, force feedback, directory services).
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#pragma mark Metal — external GPU removal (never happens on iOS)

typedef NSString *MTLDeviceNotificationName; // macOS-only in Metal's headers
typedef void (^MTLDeviceNotificationHandler)(id<MTLDevice> device, MTLDeviceNotificationName name);
extern MTLDeviceNotificationName const MTLDeviceWasRemovedNotification;
extern MTLDeviceNotificationName const MTLDeviceRemovalRequestedNotification;
// Returns the one built-in GPU; the observer never fires (iOS GPUs aren't removable).
extern NSArray<id<MTLDevice>> *MTLCopyAllDevicesWithObserver(id<NSObject> *observer, MTLDeviceNotificationHandler handler);

#pragma mark CoreText

// Font families, answered from the iOS CoreText that exists.
extern CFArrayRef CTFontCollectionCreateMatchingFontDescriptorsForFamily(CTFontCollectionRef collection,
                                                                         CFStringRef familyName, CFDictionaryRef options) CF_RETURNS_RETAINED;
// CTFontGetPlatformFont is declared (unavailable) by iOS CoreText itself, returning an ATS
// font reference; SmallFrameworks.m defines it under that exact symbol and returns 0 (none).

#pragma mark QuartzCore — CAOpenGLLayer (no desktop GL on iOS)

// Exists so layer code that references the class links; it draws nothing (Metal is used).
@interface CAOpenGLLayer : CALayer
@property (nonatomic, getter=isAsynchronous) BOOL asynchronous;
@end

#pragma mark CoreFoundation / IOKit

extern NSString *const NSURLTagNamesKey;
// The display info dictionary macOS builds from an IOKit display service; iOS exposes none.
extern CFDictionaryRef IODisplayCreateInfoDictionary(uint32_t framebuffer, uint32_t options) CF_RETURNS_RETAINED;

#pragma mark VideoToolbox

// Registers pro-video decoders (ProRes workflows); nothing to register on iOS.
extern void VTRegisterProfessionalVideoWorkflowVideoDecoders(void);

#pragma mark CoreWLAN — Wi-Fi control (not available to iOS apps)

@interface CWWiFiClient : NSObject
@property (class, readonly, strong) CWWiFiClient *sharedWiFiClient;
- (id)interface;                                   // no controllable interface: nil
- (NSArray<NSString *> *)interfaceNames;           // nil
@end

#pragma mark SecurityInterface / LocalAuthenticationEmbeddedUI — AppKit/panels (no iOS UI)

@interface SFCertificatePanel : NSObject
+ (SFCertificatePanel *)sharedCertificatePanel;
- (NSInteger)runModalForCertificates:(NSArray *)certificates showGroup:(BOOL)showGroup;
@end

@interface LAAuthenticationView : NSObject  // a macOS NSView; unavailable here
@end

#pragma mark SafariServices

@interface SFUniversalLink : NSObject
- (instancetype)initWithWebpageURL:(NSURL *)url;
@property (nonatomic, readonly, copy) NSURL *webpageURL;
@property (nonatomic, readonly, copy) NSURL *applicationURL;
@property (nonatomic, getter=isEnabled) BOOL enabled;
@end

#pragma mark OpenDirectory — directory services (not available to iOS apps)

extern NSString *const kODRecordTypeUsers;
extern NSString *const kODAttributeTypeRecordName;
extern NSString *const kODAttributeTypeAllAttributes;
extern NSString *const kODAttributeTypeAltSecurityIdentities;
extern NSString *const kODAttributeTypeMetaRecordName;

@interface ODSession : NSObject
@property (class, readonly, strong) ODSession *defaultSession;
@end

@interface ODNode : NSObject
+ (instancetype)nodeWithSession:(ODSession *)session name:(NSString *)nodeName error:(NSError **)error;
+ (instancetype)nodeWithSession:(ODSession *)session type:(uint32_t)nodeType error:(NSError **)error;
@end

@interface ODQuery : NSObject
- (NSArray *)resultsAllowingPartial:(BOOL)allowPartial error:(NSError **)error;
@end

@interface ODRecord : NSObject
@property (nonatomic, readonly, copy) NSString *recordName;
- (NSArray *)valuesForAttribute:(NSString *)attribute error:(NSError **)error;
@end

#pragma mark IOBluetooth — classic Bluetooth (iOS uses CoreBluetooth instead)

extern int IOBluetoothPreferenceSetControllerPowerState(int powered);

@interface IOBluetoothHostController : NSObject
+ (IOBluetoothHostController *)defaultController;
@property (nonatomic, readonly) uint8_t powerState;
@end

@interface IOBluetoothDevice : NSObject
+ (NSArray *)pairedDevices;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *addressString;
@end

@interface IOBluetoothDeviceInquiry : NSObject
- (int)start;
- (int)stop;
@end

@interface IOBluetoothSDPUUID : NSObject
+ (instancetype)uuid16:(uint16_t)uuid16;
@end

@interface IOBluetoothSDPServiceRecord : NSObject
@end

@interface IOBluetoothL2CAPChannel : NSObject
@end

@interface IOBluetoothRFCOMMChannel : NSObject
@end

#pragma mark ScreenCaptureKit — screen capture (not available to iOS apps)

extern NSErrorDomain const SCStreamErrorDomain;
extern NSString *const SCStreamFrameInfoScaleFactor;
extern NSString *const SCStreamFrameInfoContentScale;
extern NSString *const SCStreamFrameInfoContentRect;

@interface SCShareableContent : NSObject
+ (void)getShareableContentWithCompletionHandler:(void (^)(SCShareableContent *content, NSError *error))completionHandler;
@property (nonatomic, readonly, copy) NSArray *displays;
@property (nonatomic, readonly, copy) NSArray *windows;
@property (nonatomic, readonly, copy) NSArray *applications;
@end

@interface SCContentFilter : NSObject
@end
@interface SCStreamConfiguration : NSObject
@end
@interface SCStream : NSObject
@end
@interface SCScreenshotManager : NSObject
@end

#pragma mark ForceFeedback — rumble (not exposed to iOS apps)

typedef int32_t AKFFReturn; // HRESULT-style status
typedef void *FFDeviceObjectReference;
typedef void *FFEffectObjectReference;

enum { AKFF_OK = 0, AKFFERR_NOINTERFACE = (int32_t)0x80000004, AKFFERR_UNSUPPORTED = (int32_t)0x80000006 };

extern uint32_t FFIsForceFeedback(uint32_t device);
extern AKFFReturn FFCreateDevice(uint32_t device, FFDeviceObjectReference *outDevice);
extern AKFFReturn FFReleaseDevice(FFDeviceObjectReference device);
extern AKFFReturn FFDeviceGetForceFeedbackCapabilities(FFDeviceObjectReference device, void *outCapabilities);
extern AKFFReturn FFDeviceGetForceFeedbackProperty(FFDeviceObjectReference device, uint32_t property, void *outValue, uint32_t size);
extern AKFFReturn FFDeviceSetForceFeedbackProperty(FFDeviceObjectReference device, uint32_t property, void *value);
extern AKFFReturn FFDeviceSendForceFeedbackCommand(FFDeviceObjectReference device, uint32_t command);
extern AKFFReturn FFDeviceCreateEffect(FFDeviceObjectReference device, CFUUIDRef uuidRef, const void *effectDefinition,
                                       FFEffectObjectReference *outEffect);
extern AKFFReturn FFDeviceReleaseEffect(FFDeviceObjectReference device, FFEffectObjectReference effect);
extern AKFFReturn FFEffectStart(FFEffectObjectReference effect, uint32_t iterations, uint32_t flags);
extern AKFFReturn FFEffectStop(FFEffectObjectReference effect);
extern AKFFReturn FFEffectSetParameters(FFEffectObjectReference effect, const void *effectParams, uint32_t flags);
extern AKFFReturn FFEffectGetEffectStatus(FFEffectObjectReference effect, uint32_t *outStatus);
